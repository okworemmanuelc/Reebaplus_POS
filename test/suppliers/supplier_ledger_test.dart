import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

/// §21 Supplier Accounts ledger — balance netting, per-store scope (§21.11),
/// and CEO void/reversal (§21.7, Section 10). Append-only: a void marks the
/// original and appends an opposite-sign compensating row; the balance is the
/// signed sum of every row.
void main() {
  late AppDatabase db;
  late String businessId;
  late String supplierId;
  const storeA = 'store-a';
  const storeB = 'store-b';

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    businessId = UuidV7.generate();
    db.businessIdResolver = () => businessId;
    await db.into(db.businesses).insert(
      BusinessesCompanion.insert(id: Value(businessId), name: 'Test Biz'),
    );
    // store_id and voided_by carry FKs (§21.11 / §21.7) — seed the referenced
    // rows so inserts and the void UPDATE satisfy the constraints.
    for (final s in [storeA, storeB]) {
      await db.into(db.stores).insert(
        StoresCompanion.insert(id: Value(s), businessId: businessId, name: s),
      );
    }
    await db.into(db.users).insert(
      UsersCompanion.insert(
        id: const Value('ceo-1'),
        businessId: businessId,
        name: 'CEO',
        pin: '000000',
      ),
    );
    supplierId = await db.catalogDao.insertSupplier(
      SuppliersCompanion.insert(businessId: businessId, name: 'SAB'),
    );
  });

  tearDown(() => db.close());

  Future<String> insertEntry({
    required int signedAmountKobo,
    required String type,
    required String referenceType,
    String? storeId,
  }) async {
    final id = UuidV7.generate();
    await db
        .into(db.supplierLedgerEntries)
        .insert(
          SupplierLedgerEntriesCompanion.insert(
            id: Value(id),
            businessId: businessId,
            supplierId: supplierId,
            storeId: Value(storeId),
            type: type,
            amountKobo: signedAmountKobo.abs(),
            signedAmountKobo: signedAmountKobo,
            referenceType: referenceType,
            activityDate: DateTime.now(),
          ),
        );
    return id;
  }

  test('balance = SUM(payments) − SUM(invoices); negative = we owe', () async {
    // Invoice 5,000 (debit) then pay 2,000 (credit) → owe 3,000.
    await insertEntry(
      signedAmountKobo: -5000,
      type: 'debit',
      referenceType: 'invoice',
    );
    await insertEntry(
      signedAmountKobo: 2000,
      type: 'credit',
      referenceType: 'payment_cash',
    );
    expect(await db.supplierLedgerDao.getBalanceKobo(supplierId), -3000);
  });

  test('balance is store-scoped (§21.11)', () async {
    await insertEntry(
      signedAmountKobo: -5000,
      type: 'debit',
      referenceType: 'invoice',
      storeId: storeA,
    );
    await insertEntry(
      signedAmountKobo: 2000,
      type: 'credit',
      referenceType: 'payment_cash',
      storeId: storeB,
    );
    expect(
      await db.supplierLedgerDao.getBalanceKobo(supplierId, storeId: storeA),
      -5000,
    );
    expect(
      await db.supplierLedgerDao.getBalanceKobo(supplierId, storeId: storeB),
      2000,
    );
    // All Stores aggregate.
    expect(await db.supplierLedgerDao.getBalanceKobo(supplierId), -3000);
  });

  test('void appends a compensating row and restores the balance', () async {
    final invoiceId = await insertEntry(
      signedAmountKobo: -5000,
      type: 'debit',
      referenceType: 'invoice',
      storeId: storeA,
    );
    expect(await db.supplierLedgerDao.getBalanceKobo(supplierId), -5000);

    final didVoid = await db.supplierLedgerDao.voidEntry(
      entryId: invoiceId,
      voidedBy: 'ceo-1',
      reason: 'wrong amount',
    );
    expect(didVoid, isTrue);

    // Compensating +5,000 row nets the invoice → balance back to 0.
    expect(await db.supplierLedgerDao.getBalanceKobo(supplierId), 0);

    // Reversal carries the original store (§21.7 / Section 10.7) and nets it.
    expect(
      await db.supplierLedgerDao.getBalanceKobo(supplierId, storeId: storeA),
      0,
    );

    // Original is kept (not deleted) and now marked voided.
    final original = await (db.select(db.supplierLedgerEntries)
          ..where((t) => t.id.equals(invoiceId)))
        .getSingle();
    expect(original.voidedAt, isNotNull);
  });

  test('double-void is a no-op (Section 10.11)', () async {
    final paymentId = await insertEntry(
      signedAmountKobo: 2000,
      type: 'credit',
      referenceType: 'payment_cash',
    );
    final first = await db.supplierLedgerDao.voidEntry(
      entryId: paymentId,
      voidedBy: 'ceo-1',
      reason: 'first',
    );
    final second = await db.supplierLedgerDao.voidEntry(
      entryId: paymentId,
      voidedBy: 'ceo-1',
      reason: 'second',
    );
    expect(first, isTrue);
    expect(second, isFalse);
    // Only one compensating row was appended (original + one reversal).
    final all = await db.supplierLedgerDao.watchAllHistory().first;
    expect(all.where((e) => e.referenceType == 'void').length, 1);
    expect(await db.supplierLedgerDao.getBalanceKobo(supplierId), 0);
  });
}
