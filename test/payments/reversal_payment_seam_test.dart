// reversal_payment_seam_test.dart
//
// #169 / PRD #155 — the compensating-payment-row seam
// (`PaymentTransactionsDao.postReversalPayment`). Pins the behavior every
// money-correction slice depends on:
//   1. the ORIGINAL row is left untouched (no in-place void, no edit);
//   2. the reversal lands on its OWN created_at day (the correction day),
//      never the original's;
//   3. it copies the original's single typed reference (so the exactly-one
//      CHECK holds) and inherits/overrides store_id;
//   4. the reversal is enqueued for sync as a normal payment_transactions row.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

Future<({String storeId, String staffId, String orderId})> _seed(
  AppDatabase db,
  String businessId, {
  String? storeId,
}) async {
  final theStoreId = storeId ?? UuidV7.generate();
  await db.into(db.stores).insert(
        StoresCompanion.insert(
          id: Value(theStoreId),
          businessId: businessId,
          name: 'Main',
        ),
      );
  final staffId = UuidV7.generate();
  await db.into(db.users).insert(
        UsersCompanion.insert(
          id: Value(staffId),
          businessId: businessId,
          name: 'Cashier',
          pin: '0000',
        ),
      );
  final orderId = UuidV7.generate();
  await db.into(db.orders).insert(
        OrdersCompanion.insert(
          id: Value(orderId),
          businessId: businessId,
          orderNumber: 'ORD-000001-AAAAAA',
          totalAmountKobo: 100000,
          netAmountKobo: 100000,
          paymentType: 'cash',
          status: 'completed',
          storeId: Value(theStoreId),
        ),
      );
  return (storeId: theStoreId, staffId: staffId, orderId: orderId);
}

Future<PaymentTransactionData> _insertOriginal(
  AppDatabase db,
  String businessId, {
  required String orderId,
  required String staffId,
  required String storeId,
  required DateTime createdAt,
  int amountKobo = 100000,
}) async {
  final id = UuidV7.generate();
  await db.into(db.paymentTransactions).insert(
        PaymentTransactionsCompanion.insert(
          id: Value(id),
          businessId: businessId,
          storeId: Value(storeId),
          amountKobo: amountKobo,
          method: 'cash',
          type: 'sale',
          orderId: Value(orderId),
          performedBy: Value(staffId),
          createdAt: Value(createdAt),
          lastUpdatedAt: Value(createdAt),
        ),
      );
  return (db.select(db.paymentTransactions)..where((p) => p.id.equals(id)))
      .getSingle();
}

void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
  });

  tearDown(() => db.close());

  test(
      'reversal leaves the original untouched and lands on its OWN created_at day',
      () async {
    final f = await _seed(db, businessId);
    final saleDay = DateTime(2026, 7, 20, 10, 30);
    final cancelDay = DateTime(2026, 7, 24, 15, 0);

    final original = await _insertOriginal(
      db,
      businessId,
      orderId: f.orderId,
      staffId: f.staffId,
      storeId: f.storeId,
      createdAt: saleDay,
    );

    final reversal = await db.paymentTransactionsDao.postReversalPayment(
      original: original,
      reversalType: 'refund',
      performedBy: f.staffId,
      reason: 'order_cancelled',
      at: cancelDay,
    );

    // Reversal is its own row, on the cancel day.
    expect(reversal.id, isNot(original.id));
    expect(reversal.type, 'refund');
    expect(reversal.createdAt, cancelDay,
        reason: 'reversal must land on its own creation day, not the sale day');
    expect(reversal.amountKobo, original.amountKobo,
        reason: 'amount defaults to the original amount');
    expect(reversal.method, original.method);
    expect(reversal.orderId, f.orderId,
        reason: 'copies the original single typed reference (order_id)');
    expect(reversal.storeId, f.storeId,
        reason: 'store_id inherits from the original when not overridden');
    expect(reversal.voidReason, 'order_cancelled');
    expect(reversal.voidedAt, isNull,
        reason: 'the reversal is a live compensating entry, not a voided row');

    // Original is byte-for-byte unchanged — never voided, never re-dated.
    final originalNow =
        await (db.select(db.paymentTransactions)..where((p) => p.id.equals(original.id)))
            .getSingle();
    expect(originalNow.createdAt, saleDay);
    expect(originalNow.voidedAt, isNull);
    expect(originalNow.type, 'sale');
    expect(originalNow.amountKobo, original.amountKobo);
  });

  test('reversal is enqueued as a payment_transactions upsert', () async {
    final f = await _seed(db, businessId);
    final original = await _insertOriginal(
      db,
      businessId,
      orderId: f.orderId,
      staffId: f.staffId,
      storeId: f.storeId,
      createdAt: DateTime(2026, 7, 20),
    );

    final reversal = await db.paymentTransactionsDao.postReversalPayment(
      original: original,
      reversalType: 'refund',
      performedBy: f.staffId,
    );

    final pending = await getPendingQueue(db);
    final reversalRows = pending
        .where((r) => r.actionType == 'payment_transactions:upsert')
        .map(decodePayload)
        .where((p) => p['id'] == reversal.id)
        .toList();
    expect(reversalRows, hasLength(1),
        reason: 'the reversal row must sync so peers converge');
    expect(reversalRows.single['type'], 'refund');
    expect(reversalRows.single['store_id'], f.storeId,
        reason: 'store_id serializes to snake_case on push');
  });

  test('store_id and amount can be overridden explicitly', () async {
    final f = await _seed(db, businessId);
    final otherStore = UuidV7.generate();
    await db.into(db.stores).insert(
          StoresCompanion.insert(
            id: Value(otherStore),
            businessId: businessId,
            name: 'Branch',
          ),
        );
    final original = await _insertOriginal(
      db,
      businessId,
      orderId: f.orderId,
      staffId: f.staffId,
      storeId: f.storeId,
      createdAt: DateTime(2026, 7, 20),
      amountKobo: 100000,
    );

    final reversal = await db.paymentTransactionsDao.postReversalPayment(
      original: original,
      reversalType: 'refund',
      performedBy: f.staffId,
      amountKobo: 40000,
      storeId: otherStore,
    );

    expect(reversal.amountKobo, 40000);
    expect(reversal.storeId, otherStore);
  });
}
