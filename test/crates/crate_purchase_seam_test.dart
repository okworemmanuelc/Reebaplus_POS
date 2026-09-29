import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/crates/crate_ledger_movement_types.dart';
import 'package:reebaplus_pos/core/crates/manufacturer_crate_position.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';

/// #294 — Buy crates through the Crate Pool seam
/// (`CratePoolDao.recordCratePurchase`). Pins what reaches the database: one
/// store-stamped, attributed `purchase` row that raises that store's Empties
/// Pool and carries the price paid, and — Rule A, profit 0 — nothing else.
void main() {
  const businessId = 'biz-1';
  const userId = 'user-1';
  const manufacturerId = 'mfr-1';
  const storeA = 'store-1';
  const storeB = 'store-2';

  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    db.businessIdResolver = () => businessId;
    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(id: const Value(businessId), name: 'Biz'),
        );
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: const Value(userId),
            businessId: businessId,
            name: 'U',
            pin: '1234',
          ),
        );
    for (final id in const [storeA, storeB]) {
      await db.into(db.stores).insert(
            StoresCompanion.insert(
              id: Value(id),
              businessId: businessId,
              name: id,
            ),
          );
    }
    await db.into(db.manufacturers).insert(
          ManufacturersCompanion.insert(
            id: const Value(manufacturerId),
            businessId: businessId,
            name: 'Mfr',
            depositAmountKobo: const Value(150000),
          ),
        );
  });

  tearDown(() => db.close());

  Future<void> buy(
    int quantity, {
    String store = storeA,
    int pricePerCrateKobo = 120000,
  }) =>
      db.cratePoolDao.recordCratePurchase(
        manufacturerId: manufacturerId,
        storeId: store,
        performedBy: userId,
        quantity: quantity,
        pricePerCrateKobo: pricePerCrateKobo,
      );

  Future<int> pool({String? store}) async =>
      (await db.cratePoolDao
              .watchEmptiesPoolByManufacturer(storeId: store)
              .first)[manufacturerId] ??
      0;

  /// Row count of every table in the database, read from `sqlite_master` so a
  /// money table added later is covered without editing this test.
  Future<Map<String, int>> rowCounts() async {
    final tables = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name NOT LIKE 'sqlite_%'",
        )
        .get();
    return {
      for (final t in tables)
        t.read<String>('name'): (await db
                .customSelect(
                  'SELECT COUNT(*) AS c FROM "${t.read<String>('name')}"',
                )
                .getSingle())
            .read<int>('c'),
    };
  }

  test('raises the chosen store\'s warehouse count by the quantity bought, '
      'and no other store\'s', () async {
    await buy(5);

    expect(await pool(store: storeA), 5);
    expect(await pool(store: storeB), 0);
    expect(await pool(), 5, reason: 'All Stores = the sum of the stores');
    expect(
      await db.storeCrateBalancesDao.getBalance(
        storeId: storeA,
        manufacturerId: manufacturerId,
      ),
      5,
      reason: 'the local per-store projection follows the ledger',
    );
  });

  test('the movement is a store-stamped, attributed purchase carrying the '
      'price paid', () async {
    await buy(3, store: storeB, pricePerCrateKobo: 90000);

    final row = (await db.select(db.crateLedger).get()).single;
    expect(row.movementType, kCrateMovementPurchase);
    expect(row.quantityDelta, 3);
    expect(row.storeId, storeB);
    expect(row.performedBy, userId);
    expect(row.ratePerCrateKobo, 90000);
    expect(row.customerId, isNull);
    expect(row.manufacturerId, manufacturerId);
  });

  test('Rule A: writes no wallet, expense, supplier-account, write-off or '
      'profit row — only the crate row and its local projections', () async {
    final before = await rowCounts();
    await buy(4);
    final after = await rowCounts();

    final changed = {
      for (final name in after.keys)
        if (after[name] != before[name]) name,
    };
    expect(
      changed,
      {'crate_ledger', 'store_crate_balances', 'sync_queue'},
      reason: 'a purchase is cash out and crate in, profit 0 (Rule A)',
    );

    final queued = await db.select(db.syncQueue).get();
    expect(
      queued.map((q) => q.actionType.split(':').first).toSet(),
      {'crate_ledger', 'manufacturers'},
      reason: 'only the crate row and the pool scalar go to the cloud',
    );
  });

  test('History labels it as a purchase', () async {
    await buy(2);

    final history = await db.cratePoolDao
        .watchManufacturerCrateMovements(manufacturerId)
        .first;
    expect(history.single.movementType, kCrateMovementPurchase);
    expect(history.single.movementLabel, labelForCrateMovement('purchase'));
    expect(history.single.movementLabel, 'Purchased');
  });

  test('a purchase is not a count: the next count is still the Opening Count',
      () async {
    await buy(6);
    await db.cratePoolDao.recordManualCountCorrection(
      manufacturerId: manufacturerId,
      storeId: storeA,
      performedBy: userId,
      countedEmpties: 6,
    );

    final types = (await db.select(db.crateLedger).get())
        .map((r) => r.movementType)
        .toList();
    expect(types, [kCrateMovementPurchase, kCrateMovementOpeningCount]);
  });

  test('zero or negative quantity, or a negative price, is rejected and '
      'writes nothing', () async {
    await expectLater(buy(0), throwsArgumentError);
    await expectLater(buy(-2), throwsArgumentError);
    await expectLater(buy(1, pricePerCrateKobo: -1), throwsArgumentError);

    expect(await db.select(db.crateLedger).get(), isEmpty);
    expect(await db.select(db.syncQueue).get(), isEmpty);
    expect(await pool(), 0);
  });
}
