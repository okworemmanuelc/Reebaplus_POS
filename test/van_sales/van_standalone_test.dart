// van_standalone_test.dart
//
// #748 — a driver is a plain name (a `van_drivers` row, no sign-in) and each
// driver's debt is their own. A van can load with no driver at all.
//
// Covers: the full no-driver flow, two drivers on one van keeping separate
// balances, one driver on two vans holding one balance, assigning a driver to a
// no-driver trip moving its debt without editing a ledger amount, the money
// fixture (same trip, with and without a driver, same figures), and the
// van-return reason for no driver (old reasons still parse).
//
// NOTE: written for #748 but NOT executed in the authoring session (owner
// instruction: no tests run).

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/crates/van_return_empties.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/van_sales/driver_directory.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late String warehouseId;
  late String vanA;
  late String vanB;
  late String managerId;
  late String productId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    warehouseId = UuidV7.generate();
    vanA = UuidV7.generate();
    vanB = UuidV7.generate();
    managerId = UuidV7.generate();
    productId = UuidV7.generate();

    await db.into(db.stores).insert(
      StoresCompanion.insert(
        id: Value(warehouseId),
        businessId: businessId,
        name: 'Main Warehouse',
      ),
    );
    for (final (id, name) in [(vanA, 'Van A'), (vanB, 'Van B')]) {
      await db.into(db.stores).insert(
        StoresCompanion.insert(
          id: Value(id),
          businessId: businessId,
          name: name,
          kind: const Value(kStoreKindVan),
        ),
      );
    }
    await db.into(db.users).insert(
      UsersCompanion.insert(
        id: Value(managerId),
        businessId: businessId,
        name: 'Manager Mo',
        pin: '1111',
      ),
    );
    await db.into(db.products).insert(
      ProductsCompanion.insert(
        id: Value(productId),
        businessId: businessId,
        name: 'Star 60cl',
        retailerPriceKobo: const Value(5000),
      ),
    );
    await db.inventoryDao.adjustStock(
      productId,
      warehouseId,
      500,
      'opening',
      managerId,
      trackCost: false,
    );
    await db.costBatchesDao.recordInflowBatch(
      productId: productId,
      storeId: warehouseId,
      quantity: 500,
      costKobo: 1000,
    );
  });

  tearDown(() async => db.close());

  Future<String> load(
    String van,
    int qty, {
    String? driver,
  }) async {
    final r = await db.vanTripsDao.dispatchLoad(
      vanStoreId: van,
      vanDriverId: driver,
      sourceStoreId: warehouseId,
      performedBy: managerId,
      dispatchEventId: UuidV7.generate(),
      lines: [
        VanLoadLine(productId: productId, quantity: qty, loadPriceKobo: 5000),
      ],
    );
    return r.tripId;
  }

  Future<void> closeFully(String tripId) async {
    await db.vanTripsDao.closeTrip(tripId: tripId, performedBy: managerId);
  }

  test('no driver at all: load, restock, return, payment, write-off, close',
      () async {
    final tripId = await load(vanA, 10);
    final trip = (await db.vanTripsDao.getTrip(tripId))!;
    expect(trip.vanDriverId, isNull);
    expect(trip.driverUserId, isNull);

    await db.vanTripsDao.restockTrip(
      tripId: tripId,
      lines: [
        VanLoadLine(productId: productId, quantity: 2, loadPriceKobo: 5000),
      ],
      performedBy: managerId,
      dispatchEventId: UuidV7.generate(),
    );
    // 12 loaded at 5000 = 60000 owed.
    expect(await db.driverLedgerDao.getNoDriverBalanceKobo(vanA), -60000);

    await db.vanTripsDao.recordReturn(
      tripId: tripId,
      lines: [
        VanReturnLine(
          productId: productId,
          quantity: 2,
          condition: kVanReturnConditionGood,
        ),
      ],
      performedBy: managerId,
    );
    expect(await db.driverLedgerDao.getNoDriverBalanceKobo(vanA), -50000);

    await db.vanTripsDao.recordDriverPayment(
      tripId: tripId,
      amountKobo: 20000,
      method: 'cash',
      performedBy: managerId,
    );
    expect(await db.driverLedgerDao.getNoDriverBalanceKobo(vanA), -30000);

    await db.vanTripsDao.postWriteOff(
      tripId: tripId,
      type: kDriverLedgerTypeShortageWriteoff,
      amountKobo: 30000,
      performedBy: managerId,
    );
    expect(await db.driverLedgerDao.getNoDriverBalanceKobo(vanA), 0);

    await closeFully(tripId);
    expect((await db.vanTripsDao.getTrip(tripId))!.status, kVanTripStatusClosed);

    // Every row carries the van, none carries a user.
    final rows = await db.select(db.driverLedgerEntries).get();
    expect(rows, isNotEmpty);
    for (final r in rows) {
      expect(r.vanStoreId, vanA);
      expect(r.driverUserId, isNull);
    }
  });

  test('one open trip per van is still enforced with no driver', () async {
    await load(vanA, 5);
    await expectLater(
      load(vanA, 5),
      throwsA(isA<VanTripAlreadyOpenException>()),
    );
  });

  test('two drivers on the same van keep separate balances', () async {
    final dao = db.vanDriversDao;
    final ada = await dao.addDriver(name: 'Ada');
    final bayo = await dao.addDriver(name: 'Bayo');

    final t1 = await load(vanA, 10, driver: ada); // Ada owes 50000
    await db.vanTripsDao.recordDriverPayment(
      tripId: t1,
      amountKobo: 10000,
      method: 'cash',
      performedBy: managerId,
    );
    await closeFully(t1);
    final t2 = await load(vanA, 4, driver: bayo); // Bayo owes 20000

    expect(await db.driverLedgerDao.getBalanceKobo(ada), -40000);
    expect(await db.driverLedgerDao.getBalanceKobo(bayo), -20000,
        reason: 'a new driver never inherits the last driver\'s debt');
    expect(await db.driverLedgerDao.getNoDriverBalanceKobo(vanA), 0);
    expect(t2, isNotEmpty);
  });

  test('one driver on two vans holds ONE balance', () async {
    final ada = await db.vanDriversDao.addDriver(name: 'Ada');
    await load(vanA, 10, driver: ada); // 50000
    await load(vanB, 6, driver: ada); // 30000
    // The per-driver "one open trip" rule would stop this; the owner's rule is
    // per van. Both trips are Ada's, so her balance is the sum.
    expect(await db.driverLedgerDao.getBalanceKobo(ada), -80000);
    final all = await db.driverLedgerDao.watchAllBalances().first;
    expect(all.byDriver[ada], -80000);
  });

  test('assigning a driver to a no-driver trip moves the debt, no amount edited',
      () async {
    final tripId = await load(vanA, 10);
    final before = await db.driverLedgerDao.entriesForTrip(tripId);
    expect(await db.driverLedgerDao.getNoDriverBalanceKobo(vanA), -50000);

    final ada = await db.vanDriversDao.addDriver(name: 'Ada');
    await db.vanTripsDao.assignTripDriver(tripId, ada);

    expect(await db.driverLedgerDao.getBalanceKobo(ada), -50000);
    expect(await db.driverLedgerDao.getNoDriverBalanceKobo(vanA), 0);

    final after = await db.driverLedgerDao.entriesForTrip(tripId);
    expect(
      [for (final e in after) (e.id, e.signedAmountKobo)],
      [for (final e in before) (e.id, e.signedAmountKobo)],
      reason: 'ledger rows are untouched; ownership resolves through the trip',
    );

    // And back to nobody.
    await db.vanTripsDao.assignTripDriver(tripId, null);
    expect(await db.driverLedgerDao.getBalanceKobo(ada), 0);
    expect(await db.driverLedgerDao.getNoDriverBalanceKobo(vanA), -50000);
  });

  test('the Drivers list: removed driver who owes stays, settled one goes',
      () async {
    final dao = db.vanDriversDao;
    final owing = await dao.addDriver(name: 'Owes Money');
    final clean = await dao.addDriver(name: 'All Square');
    await load(vanA, 10, driver: owing);
    await dao.removeDriver(owing);
    await dao.removeDriver(clean);

    final rows = await dao.watchEvery().first;
    final balances = await db.driverLedgerDao.watchAllBalances().first;
    final list = buildDriversList(
      drivers: rows,
      balancesKobo: balances.byDriver,
    );
    expect(list.map((e) => e.driverId), [owing]);
    expect(list.single.isFormerDriver, isTrue);
    expect(list.single.balanceKobo, -50000);
  });

  test('settlement figures are identical with and without a driver', () async {
    final ada = await db.vanDriversDao.addDriver(name: 'Ada');

    Future<Map<String, int>> run(String van, String? driver) async {
      final tripId = await load(van, 10, driver: driver);
      await db.vanTripsDao.recordReturn(
        tripId: tripId,
        lines: [
          VanReturnLine(
            productId: productId,
            quantity: 2,
            condition: kVanReturnConditionGood,
          ),
        ],
        performedBy: managerId,
      );
      await db.vanTripsDao.recordDriverPayment(
        tripId: tripId,
        amountKobo: 20000,
        method: 'cash',
        performedBy: managerId,
      );
      await db.vanTripsDao.postWriteOff(
        tripId: tripId,
        type: kDriverLedgerTypeShortageWriteoff,
        amountKobo: 5000,
        performedBy: managerId,
      );
      final closed = await db.vanTripsDao.closeTrip(
        tripId: tripId,
        performedBy: managerId,
      );
      final t = closed.trip;
      return {
        'balance': await db.driverLedgerDao.balanceForTrip(t),
        'tripBalance': await db.driverLedgerDao.getTripBalanceKobo(tripId),
        'cogs': t.cogsKobo,
        'recovered': t.recoveredKobo,
        'unremitted': t.unremittedKobo,
        'shortageWriteoff': t.shortageWriteoffKobo,
        'profit': t.profitKobo,
        'closedWithBalance': t.closedWithBalance ? 1 : 0,
      };
    }

    final withDriver = await run(vanA, ada);
    final noDriver = await run(vanB, null);
    expect(noDriver, withDriver);
    // 50000 load - 10000 return - 20000 paid - 5000 written off.
    expect(withDriver['balance'], -15000);
  });

  test('van-return reason: no driver in new rows, old rows still parse', () {
    final fresh = vanReturnEmptiesReason(tripId: 'trip-1');
    expect(fresh, 'van_return:trip-1');
    final p = parseVanReturnEmptiesReason(fresh)!;
    expect(p.tripId, 'trip-1');
    expect(p.driverUserId, isNull);

    final old = parseVanReturnEmptiesReason('van_return:trip-1:driver-9')!;
    expect(old.tripId, 'trip-1');
    expect(old.driverUserId, 'driver-9');

    expect(parseVanReturnEmptiesReason('van_return:'), isNull);
    expect(parseVanReturnEmptiesReason('van_return:a:b:c'), isNull);
    expect(parseVanReturnEmptiesReason('something else'), isNull);
  });
}
