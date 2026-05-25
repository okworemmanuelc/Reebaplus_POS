import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../../helpers/dispatch_test_utils.dart';

/// Seeds staff (FK target for `voided_by` / `performed_by`), a customer +
/// wallet, and a single `wallet_transactions` row that the test will void.
/// Returns ids needed by the test body.
Future<({String staffId, String txnId, String walletId})> _seedVoidFixtures(
  AppDatabase db,
  String businessId,
) async {
  final staffId = UuidV7.generate();
  final customerId = UuidV7.generate();
  final walletId = UuidV7.generate();
  final txnId = UuidV7.generate();

  await db.into(db.users).insert(
        UsersCompanion.insert(
          id: Value(staffId),
          businessId: businessId,
          name: 'Void Staff',
          pin: '0000',
        ),
      );
  await db.into(db.customers).insert(
        CustomersCompanion.insert(
          id: Value(customerId),
          businessId: businessId,
          name: 'Voidable Vivian',
        ),
      );
  await db.into(db.customerWallets).insert(
        CustomerWalletsCompanion.insert(
          id: Value(walletId),
          businessId: businessId,
          customerId: customerId,
        ),
      );
  await db.into(db.walletTransactions).insert(
        WalletTransactionsCompanion.insert(
          id: Value(txnId),
          businessId: businessId,
          walletId: walletId,
          customerId: customerId,
          type: 'credit',
          amountKobo: 50000,
          signedAmountKobo: 50000,
          referenceType: 'topup_cash',
          performedBy: Value(staffId),
        ),
      );
  return (staffId: staffId, txnId: txnId, walletId: walletId);
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

  group('WalletTransactionsDao.voidTransaction dispatch', () {
    test('flag OFF: enqueues two upsert rows, no domain envelope', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.void_wallet_txn', on: false);
      final fx = await _seedVoidFixtures(db, businessId);

      await db.walletTransactionsDao.voidTransaction(
        transactionId: fx.txnId,
        voidedBy: fx.staffId,
        reason: 'wrong amount',
      );

      // Local: original is now voided + a compensating row was inserted.
      final all = await db.select(db.walletTransactions).get();
      expect(all, hasLength(2));
      final original = all.firstWhere((r) => r.id == fx.txnId);
      expect(original.voidedAt, isNotNull);
      final compensating = all.firstWhere((r) => r.id != fx.txnId);
      expect(compensating.referenceType, 'void');
      expect(compensating.signedAmountKobo, -50000);

      // Queue: two wallet_transactions upserts, no domain envelope.
      final pending = await getPendingQueue(db);
      final actionTypes = pending.map((r) => r.actionType).toList();
      expect(actionTypes, [
        'wallet_transactions:upsert',
        'wallet_transactions:upsert',
      ]);
    });

    test('flag ON: one envelope with thin payload + ids match local rows',
        () async {
      await setFlag(db, 'feature.domain_rpcs_v2.void_wallet_txn', on: true);
      final fx = await _seedVoidFixtures(db, businessId);

      await db.walletTransactionsDao.voidTransaction(
        transactionId: fx.txnId,
        voidedBy: fx.staffId,
        reason: 'duplicate entry',
      );

      // Local mirrors are present.
      final all = await db.select(db.walletTransactions).get();
      expect(all, hasLength(2));
      final compensating = all.firstWhere((r) => r.id != fx.txnId);

      // Queue: exactly one envelope.
      final pending = await getPendingQueue(db);
      expect(pending, hasLength(1));
      expect(pending.first.actionType, 'domain:pos_void_wallet_txn');

      final payload = decodePayload(pending.first);
      expect(payload['p_business_id'], businessId);
      expect(payload['p_actor_id'], fx.staffId);
      expect(payload['p_original_id'], fx.txnId);
      // Idempotency key: server replay must recognise this is the same
      // compensating row already mirrored locally.
      expect(payload['p_compensating_id'], compensating.id);
      expect(payload['p_void_reason'], 'duplicate entry');
    });

    test('already voided: early-returns with no enqueues, no extra row',
        () async {
      await setFlag(db, 'feature.domain_rpcs_v2.void_wallet_txn', on: true);
      final fx = await _seedVoidFixtures(db, businessId);

      // Pre-void the txn so the DAO hits the early-return branch.
      await (db.update(db.walletTransactions)
            ..where((t) => t.id.equals(fx.txnId)))
          .write(WalletTransactionsCompanion(
        voidedAt: Value(DateTime.now()),
        voidedBy: Value(fx.staffId),
        voidReason: const Value('preset'),
      ));

      await db.walletTransactionsDao.voidTransaction(
        transactionId: fx.txnId,
        voidedBy: fx.staffId,
        reason: 'already done',
      );

      final all = await db.select(db.walletTransactions).get();
      expect(all, hasLength(1),
          reason: 'no compensating row when original is already voided');

      final pending = await getPendingQueue(db);
      expect(pending, isEmpty,
          reason: 'no envelope must land for an already-voided txn');
    });

    test('missing original: silent no-op, no enqueues', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.void_wallet_txn', on: true);
      final fx = await _seedVoidFixtures(db, businessId);

      await db.walletTransactionsDao.voidTransaction(
        transactionId: UuidV7.generate(), // doesn't exist
        voidedBy: fx.staffId,
        reason: 'ghost void',
      );

      final pending = await getPendingQueue(db);
      expect(pending, isEmpty);
    });
  });
}
