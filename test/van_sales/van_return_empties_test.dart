// van_return_empties_test.dart
//
// #726 — empties that come back on a van reach the SOURCE warehouse pool, and
// crates that never come home show as LOST at close without touching money.
//
//   · the pool rises by the EMPTIES returned, for the right manufacturer, and the
//     ledger row names the trip and the driver
//   · unsold FULL crates are the line quantity — never empties, never lost
//   · a retried return credits once
//   · balance / outstanding / COGS / profit are identical with and without shells

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/crates/van_return_empties.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late String warehouseId;
  late String vanId;
  late String driverId;
  late String managerId;

  const starBrand = 'mfr-star';
  const gulderBrand = 'mfr-gulder';
  const starRate = 180000;
  const gulderRate = 250000;
  late String starProduct;
  late String gulderProduct;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
        .write(const BusinessesCompanion(type: Value('Bar')));

    warehouseId = UuidV7.generate();
    vanId = UuidV7.generate();
    driverId = UuidV7.generate();
    managerId = UuidV7.generate();
    starProduct = UuidV7.generate();
    gulderProduct = UuidV7.generate();

    await db.into(db.stores).insert(StoresCompanion.insert(
          id: Value(warehouseId),
          businessId: businessId,
          name: 'Main Warehouse',
        ));
    await db.into(db.stores).insert(StoresCompanion.insert(
          id: Value(vanId),
          businessId: businessId,
          name: 'Van 1',
          kind: const Value(kStoreKindVan),
        ));
    for (final u in [(driverId, 'Driver Dan'), (managerId, 'Manager Mo')]) {
      await db.into(db.users).insert(UsersCompanion.insert(
            id: Value(u.$1),
            businessId: businessId,
            name: u.$2,
            pin: '0000',
          ));
    }
    await db.into(db.manufacturers).insert(ManufacturersCompanion.insert(
          id: const Value(starBrand),
          businessId: businessId,
          name: 'Star',
          depositAmountKobo: const Value(starRate),
        ));
    await db.into(db.manufacturers).insert(ManufacturersCompanion.insert(
          id: const Value(gulderBrand),
          businessId: businessId,
          name: 'Gulder',
          depositAmountKobo: const Value(gulderRate),
        ));
    for (final p in [
      (starProduct, 'Star 60cl', starBrand),
      (gulderProduct, 'Gulder 60cl', gulderBrand),
    ]) {
      await db.into(db.products).insert(ProductsCompanion.insert(
            id: Value(p.$1),
            businessId: businessId,
            name: p.$2,
            retailerPriceKobo: const Value(1150000),
            manufacturerId: Value(p.$3),
            unit: const Value('Bottle'),
            trackEmpties: const Value(true),
          ));
      await db.inventoryDao.adjustStock(
        p.$1,
        warehouseId,
        200,
        'opening',
        managerId,
        trackCost: false,
      );
      await db.costBatchesDao.recordInflowBatch(
        productId: p.$1,
        storeId: warehouseId,
        quantity: 200,
        costKobo: 1000000,
      );
    }
  });

  tearDown(() async => db.close());

  Future<String> load() async {
    final r = await db.vanTripsDao.dispatchLoad(
      vanStoreId: vanId,
      vanDriverId: driverId,
      sourceStoreId: warehouseId,
      performedBy: managerId,
      dispatchEventId: UuidV7.generate(),
      lines: [
        VanLoadLine(
          productId: starProduct,
          quantity: 100,
          loadPriceKobo: 1150000,
          shellsOut: 100,
        ),
        VanLoadLine(
          productId: gulderProduct,
          quantity: 50,
          loadPriceKobo: 1150000,
          shellsOut: 50,
        ),
      ],
    );
    return r.tripId;
  }

  Future<Map<String, double>> pool() =>
      db.cratePoolDao.watchEmptiesPoolByManufacturer(storeId: warehouseId).first;

  List<VanReturnLine> returnLines({String? starEvent, String? gulderEvent}) => [
        VanReturnLine(
          productId: starProduct,
          quantity: 20, // unsold FULL crates
          condition: kVanReturnConditionGood,
          shellsBack: 70, // empties
          eventId: starEvent,
        ),
        VanReturnLine(
          productId: gulderProduct,
          quantity: 50,
          condition: kVanReturnConditionGood,
          shellsBack: 0,
          eventId: gulderEvent,
        ),
      ];

  test('pool rises by the empties for the right manufacturer, linked to the '
      'trip and driver; full crates are not empties', () async {
    final tripId = await load();
    expect(await pool(), isEmpty);

    await db.vanTripsDao.recordReturn(
      tripId: tripId,
      performedBy: managerId,
      lines: returnLines(),
    );

    final p = await pool();
    expect(p[starBrand], 70, reason: 'empties only, not the 20 full crates');
    expect(p[gulderBrand], isNull, reason: '0 empties writes no pool row');

    final rows = await (db.select(db.crateLedger)
          ..where((l) => l.reason.like('$kVanReturnEmptiesReasonPrefix%')))
        .get();
    expect(rows, hasLength(1));
    expect(rows.single.storeId, warehouseId);
    expect(rows.single.movementType, 'adjusted');
    expect(rows.single.manufacturerId, starBrand);
    final link = parseVanReturnEmptiesReason(rows.single.reason)!;
    expect(link.tripId, tripId);
    expect(link.driverUserId, isNull, reason: '#748: the reason names the trip only');
  });

  test('a retried return credits the warehouse once', () async {
    final tripId = await load();
    final starEvent = UuidV7.generate();
    final gulderEvent = UuidV7.generate();
    for (var i = 0; i < 2; i++) {
      await db.vanTripsDao.recordReturn(
        tripId: tripId,
        performedBy: managerId,
        lines: returnLines(starEvent: starEvent, gulderEvent: gulderEvent),
      );
    }
    expect((await pool())[starBrand], 70);
    final rows = await (db.select(db.crateLedger)
          ..where((l) => l.reason.like('$kVanReturnEmptiesReasonPrefix%')))
        .get();
    expect(rows, hasLength(1));
  });

  test('the same return replayed by sync mints the same ledger id', () async {
    final tripId = await load();
    final starEvent = UuidV7.generate();
    await db.vanTripsDao.recordReturn(
      tripId: tripId,
      performedBy: managerId,
      lines: [
        VanReturnLine(
          productId: starProduct,
          quantity: 1,
          condition: kVanReturnConditionGood,
          shellsBack: 5,
          eventId: starEvent,
        ),
      ],
    );
    final row = (await (db.select(db.crateLedger)
              ..where((l) => l.reason.like('$kVanReturnEmptiesReasonPrefix%')))
            .get())
        .single;
    expect(
      row.id,
      UuidV7.deterministic('crate_pool:van_return:$starEvent'),
    );
  });

  test('lost crates = out - (empties + unsold full), valued at the deposit '
      'rate; unsold full crates are not lost', () async {
    final tripId = await load();
    await db.vanTripsDao.recordReturn(
      tripId: tripId,
      performedBy: managerId,
      lines: returnLines(),
    );
    final pos = await db.vanTripsDao.positionForTrip(tripId);
    // Star: 100 out, 70 empties + 20 full back = 90 -> 10 lost.
    // Gulder: 50 out, 50 full back -> 0 lost.
    expect(pos.shellsLostUnits, 10);
    expect(pos.shellsLostValueKobo, 10 * starRate);
    expect(pos.shellLosses.single.manufacturerId, starBrand);
  });

  test('money is identical with and without lost crates', () async {
    final tripId = await load();
    await db.vanTripsDao.recordReturn(
      tripId: tripId,
      performedBy: managerId,
      lines: returnLines(),
    );
    final withShells = await db.vanTripsDao.positionForTrip(tripId);
    expect(withShells.shellsLostUnits, greaterThan(0));

    // Same trip, shells never recorded going out.
    await (db.update(db.vanTripLots)).write(
      const VanTripLotsCompanion(shellsOut: Value(0)),
    );
    await (db.update(db.vanTrips)).write(
      const VanTripsCompanion(shellsOut: Value(0)),
    );
    final without = await db.vanTripsDao.positionForTrip(tripId);
    expect(without.shellsLostUnits, 0);

    expect(without.balanceKobo, withShells.balanceKobo);
    expect(without.outstandingKobo, withShells.outstandingKobo);
    expect(without.cogsKobo, withShells.cogsKobo);
    expect(without.profitKobo, withShells.profitKobo);
    expect(without.recoveredKobo, withShells.recoveredKobo);
    expect(withShells.tieOutDeltaKobo, 0);
  });

  test('a business that does not track crates credits no pool', () async {
    await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
        .write(const BusinessesCompanion(type: Value('Supermarket')));
    final tripId = await load();
    await db.vanTripsDao.recordReturn(
      tripId: tripId,
      performedBy: managerId,
      lines: returnLines(),
    );
    expect(await pool(), isEmpty);
    expect((await db.vanTripsDao.positionForTrip(tripId)).shellsLostUnits, 0);
  });
}
