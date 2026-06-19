import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';

/// §3.13 — per-supplier empty-crate tracking (the supplier-side mirror of the
/// customer crate ledger). A `received` movement (+) means we now owe the
/// supplier empties; a `returned` movement (−) reduces it. Balance = SUM(delta).
/// The ledger is append-only; the balance cache is reconcilable from it.
void main() {
  late AppDatabase db;
  late SupplierCrateLedgerDao dao;
  const businessId = 'biz-crate';
  const userId = 'user-1';
  const supplierA = 'sup-a';
  const supplierB = 'sup-b';
  const mfrX = 'mfr-x';
  const mfrY = 'mfr-y';

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    dao = db.supplierCrateLedgerDao;
    db.businessIdResolver = () => businessId;
    await db
        .into(db.businesses)
        .insert(BusinessesCompanion.insert(
          id: const Value(businessId),
          name: 'Test Biz',
        ));
    await db.into(db.users).insert(UsersCompanion.insert(
          id: const Value(userId),
          businessId: businessId,
          name: 'Staff',
          pin: '000000',
        ));
    for (final entry in {mfrX: 50000, mfrY: 30000}.entries) {
      await db.into(db.manufacturers).insert(ManufacturersCompanion.insert(
            id: Value(entry.key),
            businessId: businessId,
            name: 'Mfr ${entry.key}',
            depositAmountKobo: Value(entry.value),
          ));
    }
    for (final s in [supplierA, supplierB]) {
      await db.into(db.suppliers).insert(
            SuppliersCompanion.insert(
              id: Value(s),
              businessId: businessId,
              name: s,
            ),
          );
    }
  });

  tearDown(() => db.close());

  test('receipt increments what we owe; return nets it back toward zero',
      () async {
    await dao.recordCrateReceiptFromSupplier(
      supplierId: supplierA,
      manufacturerId: mfrX,
      quantity: 100,
      performedBy: userId,
    );
    expect(await dao.watchHistory(supplierA).first, hasLength(1));

    var balances =
        await db.supplierCrateBalancesDao.watchBySupplier(supplierA).first;
    expect(balances.single.balance, 100); // we owe 100 empties

    await dao.recordCrateReturnToSupplier(
      supplierId: supplierA,
      manufacturerId: mfrX,
      quantity: 80,
      performedBy: userId,
    );
    balances =
        await db.supplierCrateBalancesDao.watchBySupplier(supplierA).first;
    expect(balances.single.balance, 20); // returned 80 → owe 20

    // Two append-only ledger rows (one received, one returned).
    final ledger = await db.select(db.supplierCrateLedger).get();
    expect(ledger.length, 2);
    expect(ledger.where((r) => r.movementType == 'received').single.quantityDelta,
        100);
    expect(ledger.where((r) => r.movementType == 'returned').single.quantityDelta,
        -80);
  });

  test('returning more than received yields a crate credit (negative balance)',
      () async {
    await dao.recordCrateReceiptFromSupplier(
      supplierId: supplierA,
      manufacturerId: mfrX,
      quantity: 10,
      performedBy: userId,
    );
    await dao.recordCrateReturnToSupplier(
      supplierId: supplierA,
      manufacturerId: mfrX,
      quantity: 15,
      performedBy: userId,
    );
    final balances =
        await db.supplierCrateBalancesDao.watchBySupplier(supplierA).first;
    expect(balances.single.balance, -5); // supplier owes us 5
  });

  test('balances are scoped per (supplier, manufacturer)', () async {
    await dao.recordCrateReceiptFromSupplier(
      supplierId: supplierA,
      manufacturerId: mfrX,
      quantity: 40,
      performedBy: userId,
    );
    await dao.recordCrateReceiptFromSupplier(
      supplierId: supplierA,
      manufacturerId: mfrY,
      quantity: 25,
      performedBy: userId,
    );
    await dao.recordCrateReceiptFromSupplier(
      supplierId: supplierB,
      manufacturerId: mfrX,
      quantity: 7,
      performedBy: userId,
    );

    final aBalances =
        await db.supplierCrateBalancesDao.watchBySupplier(supplierA).first;
    expect(aBalances, hasLength(2));
    expect(
      aBalances.firstWhere((b) => b.manufacturerId == mfrX).balance,
      40,
    );
    expect(
      aBalances.firstWhere((b) => b.manufacturerId == mfrY).balance,
      25,
    );
    // Deposit rate is carried through for the refundable-value display.
    expect(
      aBalances.firstWhere((b) => b.manufacturerId == mfrX).depositRateKobo,
      50000,
    );

    final bBalances =
        await db.supplierCrateBalancesDao.watchBySupplier(supplierB).first;
    expect(bBalances.single.balance, 7);

    expect(await db.supplierCrateBalancesDao.watchTotalOwed(supplierA).first, 65);
    expect(await db.supplierCrateBalancesDao.watchTotalOwed(supplierB).first, 7);
  });

  test('deposit held = deposits paid on receipts − refunds on returns',
      () async {
    await dao.recordCrateReceiptFromSupplier(
      supplierId: supplierA,
      manufacturerId: mfrX,
      quantity: 100,
      performedBy: userId,
      depositPaidKobo: 50000,
    );
    await dao.recordCrateReceiptFromSupplier(
      supplierId: supplierA,
      manufacturerId: mfrX,
      quantity: 50,
      performedBy: userId,
      depositPaidKobo: 25000,
    );
    expect(await dao.watchDepositHeldKobo(supplierA).first, 75000);

    await dao.recordCrateReturnToSupplier(
      supplierId: supplierA,
      manufacturerId: mfrX,
      quantity: 60,
      performedBy: userId,
      depositRefundedKobo: 30000,
    );
    // 75,000 paid − 30,000 refunded = 45,000 still held by the supplier.
    expect(await dao.watchDepositHeldKobo(supplierA).first, 45000);
  });

  test('movement totals track cumulative received + sent-back (not net)',
      () async {
    await dao.recordCrateReceiptFromSupplier(
      supplierId: supplierA,
      manufacturerId: mfrX,
      quantity: 100,
      performedBy: userId,
    );
    await dao.recordCrateReceiptFromSupplier(
      supplierId: supplierA,
      manufacturerId: mfrY,
      quantity: 20,
      performedBy: userId,
    );
    await dao.recordCrateReturnToSupplier(
      supplierId: supplierA,
      manufacturerId: mfrX,
      quantity: 30,
      performedBy: userId,
    );
    await dao.recordCrateReturnToSupplier(
      supplierId: supplierA,
      manufacturerId: mfrX,
      quantity: 10,
      performedBy: userId,
    );

    final totals = await dao.watchMovementTotals(supplierA).first;
    expect(totals.received, 120); // 100 + 20
    expect(totals.returned, 40); // 30 + 10 sent back (gross, not net)
    // Net owed is still received − returned across manufacturers.
    expect(
      await db.supplierCrateBalancesDao.watchTotalOwed(supplierA).first,
      80,
    );
  });

  test('the supplier crate ledger is append-only (delete is rejected)',
      () async {
    await dao.recordCrateReceiptFromSupplier(
      supplierId: supplierA,
      manufacturerId: mfrX,
      quantity: 5,
      performedBy: userId,
    );
    final row = await db.select(db.supplierCrateLedger).getSingle();
    await expectLater(
      (db.delete(db.supplierCrateLedger)..where((t) => t.id.equals(row.id)))
          .go(),
      throwsA(anything),
    );
  });
}
