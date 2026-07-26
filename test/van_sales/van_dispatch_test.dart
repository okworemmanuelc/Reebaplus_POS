// van_dispatch_test.dart
//
// #141 (PRD #139 / ADR 0019, van-sales spec §4.2–§4.4, §5.2, §7.1, §9.1) — the
// dispatch transaction: the one place where a van load's five effects have to
// happen together or not at all.
//
// ADR 0019's consequence note is why this file exists:
//   "van_trip_lots.unit_cost_kobo is load-bearing. If a dispatch ever writes a
//    lot without drawing the source batches down, that trip's COGS is silently
//    wrong and nothing downstream will catch it."
//
// So the assertions here are deliberately about the SEAMS between subsystems —
// batch coverage vs. physical stock, lot snapshot vs. what was drawn, ledger
// balance vs. loaded value — not about any single write in isolation.
//
// In-memory Drift via bootstrapTestDb(); costing-suite style
// (test/costing/inflow_batch_creation_test.dart).

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
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
  late String productId;

  /// Seeds a business with a warehouse, a van, a driver, a manager and one
  /// product. Nothing is stocked — each test decides its own opening position,
  /// because "what the batches held when the van drove off" is precisely what
  /// most of these tests are about.
  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;

    warehouseId = UuidV7.generate();
    vanId = UuidV7.generate();
    driverId = UuidV7.generate();
    managerId = UuidV7.generate();
    productId = UuidV7.generate();

    await db.into(db.stores).insert(
          StoresCompanion.insert(
            id: Value(warehouseId),
            businessId: businessId,
            name: 'Main Warehouse',
          ),
        );
    await db.into(db.stores).insert(
          StoresCompanion.insert(
            id: Value(vanId),
            businessId: businessId,
            name: 'Van 1',
            kind: const Value(kStoreKindVan),
          ),
        );
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: Value(driverId),
            businessId: businessId,
            name: 'Driver Dan',
            pin: '0000',
          ),
        );
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
            retailerPriceKobo: const Value(1150000),
          ),
        );
  });

  tearDown(() async => db.close());

  /// Puts [qty] units of [product] into [store] AND opens a matching FIFO cost
  /// batch at [unitCostKobo] — i.e. the physical and the costed position agree,
  /// which is the only sane starting point for a coverage assertion.
  ///
  /// [unitCostKobo] 0 seeds an UNCOSTED layer (a real state: stock received
  /// before anyone recorded a buying price).
  Future<void> stockWithBatch(
    String store,
    int qty,
    int unitCostKobo, {
    String? product,
    DateTime? receivedAt,
  }) async {
    final p = product ?? productId;
    await db.inventoryDao.adjustStock(
      p,
      store,
      qty,
      'opening',
      managerId,
      trackCost: false,
    );
    await db.costBatchesDao.recordInflowBatch(
      productId: p,
      storeId: store,
      quantity: qty,
      costKobo: unitCostKobo,
      receivedAt: receivedAt,
    );
  }

  Future<int> onHand(String store, {String? product}) async {
    final row = await (db.select(db.inventory)
          ..where((t) =>
              t.productId.equals(product ?? productId) &
              t.storeId.equals(store) &
              t.businessId.equals(businessId)))
        .getSingleOrNull();
    return row?.quantity ?? 0;
  }

  /// Total units still covered by cost batches at [store] — the figure that has
  /// to keep matching physical stock, or the warehouse is holding "phantom
  /// coverage" for goods that drove away (the exact break ADR 0019 fixes).
  Future<int> batchUnits(String store, {String? product}) async {
    final batches = await db.costBatchesDao
        .queueFor(product ?? productId, store);
    return batches.fold<int>(0, (sum, b) => sum + b.qtyRemaining);
  }

  /// Total kobo still covered by cost batches at [store].
  Future<int> batchValueKobo(String store, {String? product}) async {
    final batches = await db.costBatchesDao
        .queueFor(product ?? productId, store);
    return batches.fold<int>(
      0,
      (sum, b) => sum + b.qtyRemaining * b.costKobo,
    );
  }

  Future<List<DriverLedgerEntryData>> ledgerRows() {
    return (db.select(db.driverLedgerEntries)
          ..orderBy([(t) => OrderingTerm(expression: t.createdAt)]))
        .get();
  }

  // ═══ The happy path, seam by seam ═══════════════════════════════════════

  group('dispatchLoad — the five effects are one transaction', () {
    test('writes the lot, the ledger debit, the stock move and the batch '
        'draw-down together', () async {
      // 200 @ ₦10,000 cost in the warehouse (the spec §6.3 worked trip).
      await stockWithBatch(warehouseId, 200, 1000000);

      final result = await db.vanTripsDao.dispatchLoad(
        vanStoreId: vanId,
        driverUserId: driverId,
        sourceStoreId: warehouseId,
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
        lines: [
          VanLoadLine(
            productId: productId,
            quantity: 100,
            loadPriceKobo: 1150000,
            shellsOut: 100,
          ),
        ],
      );

      // 1. A trip was opened, on the right three axes.
      final trip = await db.vanTripsDao.getTrip(result.tripId);
      expect(trip, isNotNull);
      expect(trip!.status, kVanTripStatusOpen);
      expect(trip.vanStoreId, vanId);
      expect(trip.driverUserId, driverId);
      expect(trip.sourceStoreId, warehouseId);
      expect(trip.openedBy, managerId);
      expect(trip.closedAt, isNull);
      // The shell memo rolled up onto the trip (counting only — no money).
      expect(trip.shellsOut, 100);
      // Close artifact untouched while open.
      expect(trip.profitKobo, 0);
      expect(trip.cogsKobo, 0);

      // 2. One priced lot, carrying BOTH prices.
      expect(result.lots, hasLength(1));
      final lot = result.lots.single;
      expect(lot.quantity, 100);
      expect(lot.qtyRemaining, 100, reason: 'nothing returned yet');
      expect(lot.loadPriceKobo, 1150000);
      expect(lot.shellsOut, 100);

      // 3. THE SNAPSHOT: the lot's unit cost is what the batches actually gave
      //    up, not what the product's scalar happens to say today.
      expect(lot.unitCostKobo, 1000000);

      // 4. The stock physically moved.
      expect(await onHand(warehouseId), 100);
      expect(await onHand(vanId), 100);

      // 5. The driver was debited the FULL load-price value.
      expect(result.totalLoadValueKobo, 100 * 1150000);
      expect(await db.driverLedgerDao.getBalanceKobo(driverId), -115000000);
    });

    test('the derived balance equals the negative of total loaded value '
        'immediately after dispatch (the #141 acceptance criterion)', () async {
      await stockWithBatch(warehouseId, 500, 900000);

      final second = UuidV7.generate();
      await db.into(db.products).insert(
            ProductsCompanion.insert(
              id: Value(second),
              businessId: businessId,
              name: 'Gulder 60cl',
            ),
          );
      await stockWithBatch(warehouseId, 300, 800000, product: second);

      final result = await db.vanTripsDao.dispatchLoad(
        vanStoreId: vanId,
        driverUserId: driverId,
        sourceStoreId: warehouseId,
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
        lines: [
          VanLoadLine(
            productId: productId,
            quantity: 100,
            loadPriceKobo: 1150000,
          ),
          VanLoadLine(
            productId: second,
            quantity: 40,
            loadPriceKobo: 1000000,
          ),
        ],
      );

      const expected = 100 * 1150000 + 40 * 1000000;
      expect(result.totalLoadValueKobo, expected);
      expect(await db.driverLedgerDao.getBalanceKobo(driverId), -expected);
      // And the per-trip slice agrees with the cross-trip balance on trip one.
      expect(
        await db.driverLedgerDao.getTripBalanceKobo(result.tripId),
        -expected,
      );
    });

    test('the ledger debit is typed `load`, references its lot, and is signed '
        'negative', () async {
      await stockWithBatch(warehouseId, 50, 500000);

      final result = await db.vanTripsDao.dispatchLoad(
        vanStoreId: vanId,
        driverUserId: driverId,
        sourceStoreId: warehouseId,
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
        lines: [
          VanLoadLine(productId: productId, quantity: 10, loadPriceKobo: 700000),
        ],
      );

      final rows = await ledgerRows();
      expect(rows, hasLength(1));
      final entry = rows.single;
      expect(entry.type, kDriverLedgerTypeLoad);
      expect(entry.referenceType, kDriverLedgerRefLot);
      expect(entry.referenceId, result.lots.single.id);
      expect(entry.tripId, result.tripId);
      expect(entry.driverUserId, driverId);
      expect(entry.amountKobo, 7000000, reason: 'magnitude is positive');
      expect(entry.signedAmountKobo, -7000000, reason: 'a load is a DEBIT');
      expect(entry.performedBy, managerId);
      expect(entry.voidedAt, isNull);
    });
  });

  // ═══ Cost travels with the load (ADR 0019 decision 1) ═══════════════════

  group('cost travels with the load', () {
    test('warehouse batch coverage after a load equals what physically '
        'remains — no phantom coverage for goods that drove away', () async {
      await stockWithBatch(warehouseId, 200, 1000000);
      expect(await batchUnits(warehouseId), 200);

      await db.vanTripsDao.dispatchLoad(
        vanStoreId: vanId,
        driverUserId: driverId,
        sourceStoreId: warehouseId,
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
        lines: [
          VanLoadLine(
            productId: productId,
            quantity: 100,
            loadPriceKobo: 1150000,
          ),
        ],
      );

      expect(await onHand(warehouseId), 100);
      expect(await batchUnits(warehouseId), 100,
          reason: 'coverage must track physical stock, not lag behind it');
      expect(await batchValueKobo(warehouseId), 100 * 1000000);
    });

    test('NO cost batch is created on the van store — the lot snapshot is the '
        'van\'s only cost truth', () async {
      await stockWithBatch(warehouseId, 200, 1000000);

      await db.vanTripsDao.dispatchLoad(
        vanStoreId: vanId,
        driverUserId: driverId,
        sourceStoreId: warehouseId,
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
        lines: [
          VanLoadLine(
            productId: productId,
            quantity: 100,
            loadPriceKobo: 1150000,
          ),
        ],
      );

      // The van holds the goods…
      expect(await onHand(vanId), 100);
      // …and NOT a second cost queue for them. A van-side queue would put the
      // same units in two places and make per-trip COGS depend on the order
      // offline sales sync (ADR 0019, rejected alternative 1).
      final vanBatches =
          await (db.select(db.costBatches)..where((b) => b.storeId.equals(vanId)))
              .get();
      expect(vanBatches, isEmpty);
    });

    test('a load spanning two batches at different costs snapshots the BLENDED '
        'per-unit cost of what it actually drew', () async {
      // Oldest layer 60 @ ₦1,000; newer 100 @ ₦2,000. Loading 100 takes all 60
      // of the old + 40 of the new = 60,000 + 80,000 = 140,000 → 1,400/unit.
      final older = DateTime(2026, 1, 1);
      final newer = DateTime(2026, 2, 1);
      await stockWithBatch(warehouseId, 60, 1000, receivedAt: older);
      await stockWithBatch(warehouseId, 100, 2000, receivedAt: newer);

      final result = await db.vanTripsDao.dispatchLoad(
        vanStoreId: vanId,
        driverUserId: driverId,
        sourceStoreId: warehouseId,
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
        lines: [
          VanLoadLine(productId: productId, quantity: 100, loadPriceKobo: 5000),
        ],
      );

      expect(result.lots.single.unitCostKobo, 1400);
      // Oldest-first: the ₦1,000 layer is exhausted, 60 of the ₦2,000 remain.
      expect(await batchUnits(warehouseId), 60);
      expect(await batchValueKobo(warehouseId), 60 * 2000);
    });

    test('an uncosted source yields unit_cost_kobo == 0 and is FLAGGED, never '
        'a phantom cost', () async {
      // Stock received before anyone recorded a buying price.
      await stockWithBatch(warehouseId, 100, 0);

      final result = await db.vanTripsDao.dispatchLoad(
        vanStoreId: vanId,
        driverUserId: driverId,
        sourceStoreId: warehouseId,
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
        lines: [
          VanLoadLine(productId: productId, quantity: 40, loadPriceKobo: 900000),
        ],
      );

      expect(result.lots.single.unitCostKobo, 0);
      // Surfaced, not swallowed: the caller puts this in the Uncosted
      // transparency bucket so it can't silently become free goods (§9.1 #2).
      expect(result.uncostedProductIds, [productId]);
      // The load still happened in full — uncosted is allowed, not blocked.
      expect(await onHand(vanId), 40);
      expect(await db.driverLedgerDao.getBalanceKobo(driverId), -36000000);
    });

    test('a product with NO batch at all loads at cost 0 rather than inventing '
        'one from the product\'s scalar price', () async {
      // Physical stock, no cost batch anywhere — the pre-FIFO migration state.
      await db.inventoryDao.adjustStock(
        productId,
        warehouseId,
        30,
        'opening',
        managerId,
        trackCost: false,
      );
      // The product carries a scalar buying price that must NOT leak in.
      await (db.update(db.products)..where((p) => p.id.equals(productId)))
          .write(const ProductsCompanion(buyingPriceKobo: Value(999999)));

      final result = await db.vanTripsDao.dispatchLoad(
        vanStoreId: vanId,
        driverUserId: driverId,
        sourceStoreId: warehouseId,
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
        lines: [
          VanLoadLine(productId: productId, quantity: 30, loadPriceKobo: 1200000),
        ],
      );

      expect(result.lots.single.unitCostKobo, 0);
      expect(result.uncostedProductIds, [productId]);
    });

    test('two vans loading the same product get per-trip COGS that depends '
        'only on their own lots (order-independent)', () async {
      final van2 = UuidV7.generate();
      final driver2 = UuidV7.generate();
      await db.into(db.stores).insert(
            StoresCompanion.insert(
              id: Value(van2),
              businessId: businessId,
              name: 'Van 2',
              kind: const Value(kStoreKindVan),
            ),
          );
      await db.into(db.users).insert(
            UsersCompanion.insert(
              id: Value(driver2),
              businessId: businessId,
              name: 'Driver Ada',
              pin: '2222',
            ),
          );

      final older = DateTime(2026, 1, 1);
      final newer = DateTime(2026, 2, 1);
      await stockWithBatch(warehouseId, 100, 1000, receivedAt: older);
      await stockWithBatch(warehouseId, 100, 3000, receivedAt: newer);

      // Van 1 loads first and takes the cheap layer.
      final t1 = await db.vanTripsDao.dispatchLoad(
        vanStoreId: vanId,
        driverUserId: driverId,
        sourceStoreId: warehouseId,
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
        lines: [
          VanLoadLine(productId: productId, quantity: 100, loadPriceKobo: 5000),
        ],
      );
      // Van 2 loads second and gets the expensive one.
      final t2 = await db.vanTripsDao.dispatchLoad(
        vanStoreId: van2,
        driverUserId: driver2,
        sourceStoreId: warehouseId,
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
        lines: [
          VanLoadLine(productId: productId, quantity: 100, loadPriceKobo: 5000),
        ],
      );

      // Each trip's cost is fixed at ITS dispatch and cannot be restated by the
      // other's close, whatever order the two trips are reconciled in.
      expect(t1.lots.single.unitCostKobo, 1000);
      expect(t2.lots.single.unitCostKobo, 3000);
      expect(await batchUnits(warehouseId), 0);
    });
  });

  // ═══ Idempotency (spec §7.1) ════════════════════════════════════════════

  group('dispatch is idempotent on dispatch_event_id', () {
    test('dispatching TWICE with the same key debits the driver ONCE',
        () async {
      await stockWithBatch(warehouseId, 200, 1000000);
      final key = UuidV7.generate();
      final lines = [
        VanLoadLine(
          productId: productId,
          quantity: 100,
          loadPriceKobo: 1150000,
        ),
      ];

      final first = await db.vanTripsDao.dispatchLoad(
        vanStoreId: vanId,
        driverUserId: driverId,
        sourceStoreId: warehouseId,
        performedBy: managerId,
        dispatchEventId: key,
        lines: lines,
      );
      expect(first.alreadyApplied, isFalse);

      // The retry after a timeout / the double-tap.
      final second = await db.vanTripsDao.dispatchLoad(
        vanStoreId: vanId,
        driverUserId: driverId,
        sourceStoreId: warehouseId,
        performedBy: managerId,
        dispatchEventId: key,
        lines: lines,
      );

      expect(second.alreadyApplied, isTrue);
      expect(second.tripId, first.tripId, reason: 'same trip, not a new one');
      expect(second.totalLoadValueKobo, first.totalLoadValueKobo);

      // THE assertion: one debit, not two.
      expect(await ledgerRows(), hasLength(1));
      expect(await db.driverLedgerDao.getBalanceKobo(driverId), -115000000);
      // And nothing moved twice either.
      expect(await onHand(warehouseId), 100);
      expect(await onHand(vanId), 100);
      expect(await batchUnits(warehouseId), 100);
      final lots = await db.vanTripsDao.lotsForTrip(first.tripId);
      expect(lots, hasLength(1));
    });

    test('a replay reconstructs the original result from the lots alone (so it '
        'survives the app being killed mid-retry)', () async {
      await stockWithBatch(warehouseId, 100, 0); // uncosted, to check the flag
      final key = UuidV7.generate();
      final first = await db.vanTripsDao.dispatchLoad(
        vanStoreId: vanId,
        driverUserId: driverId,
        sourceStoreId: warehouseId,
        performedBy: managerId,
        dispatchEventId: key,
        lines: [
          VanLoadLine(productId: productId, quantity: 25, loadPriceKobo: 400000),
        ],
      );

      final replay = await db.vanTripsDao.dispatchLoad(
        vanStoreId: vanId,
        driverUserId: driverId,
        sourceStoreId: warehouseId,
        performedBy: managerId,
        dispatchEventId: key,
        lines: [
          VanLoadLine(productId: productId, quantity: 25, loadPriceKobo: 400000),
        ],
      );

      expect(replay.lots.single.id, first.lots.single.id);
      expect(replay.uncostedProductIds, [productId],
          reason: 'the uncosted flag is rebuilt from the lot, not remembered');
    });

    test('duplicate product lines in ONE dispatch collapse into one lot',
        () async {
      await stockWithBatch(warehouseId, 100, 1000);

      final result = await db.vanTripsDao.dispatchLoad(
        vanStoreId: vanId,
        driverUserId: driverId,
        sourceStoreId: warehouseId,
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
        lines: [
          VanLoadLine(productId: productId, quantity: 10, loadPriceKobo: 5000),
          VanLoadLine(productId: productId, quantity: 15, loadPriceKobo: 6000),
        ],
      );

      // One lot of 25 at the LAST price the manager typed.
      expect(result.lots, hasLength(1));
      expect(result.lots.single.quantity, 25);
      expect(result.lots.single.loadPriceKobo, 6000);
      expect(result.totalLoadValueKobo, 25 * 6000);
      expect(await ledgerRows(), hasLength(1));
    });
  });

  // ═══ One open trip per van AND per driver (spec §4.2) ═══════════════════

  group('one open trip per van and per driver', () {
    Future<String> loadTheVan({String? van, String? driver}) async {
      final result = await db.vanTripsDao.dispatchLoad(
        vanStoreId: van ?? vanId,
        driverUserId: driver ?? driverId,
        sourceStoreId: warehouseId,
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
        lines: [
          VanLoadLine(productId: productId, quantity: 10, loadPriceKobo: 5000),
        ],
      );
      return result.tripId;
    }

    test('a second open trip on the SAME VAN is blocked with a clear message',
        () async {
      await stockWithBatch(warehouseId, 100, 1000);
      final firstTrip = await loadTheVan();

      final otherDriver = UuidV7.generate();
      await db.into(db.users).insert(
            UsersCompanion.insert(
              id: Value(otherDriver),
              businessId: businessId,
              name: 'Driver Bola',
              pin: '3333',
            ),
          );

      await expectLater(
        loadTheVan(driver: otherDriver),
        throwsA(
          isA<VanTripAlreadyOpenException>()
              .having((e) => e.onVan, 'onVan', isTrue)
              .having((e) => e.openTripId, 'openTripId', firstTrip)
              .having((e) => e.message, 'message',
                  contains('already out on a trip')),
        ),
      );

      // Nothing leaked from the rejected attempt.
      expect(await ledgerRows(), hasLength(1));
      expect(await onHand(vanId), 10);
    });

    test('a second open trip for the SAME DRIVER (on another van) is blocked',
        () async {
      await stockWithBatch(warehouseId, 100, 1000);
      final firstTrip = await loadTheVan();

      final van2 = UuidV7.generate();
      await db.into(db.stores).insert(
            StoresCompanion.insert(
              id: Value(van2),
              businessId: businessId,
              name: 'Van 2',
              kind: const Value(kStoreKindVan),
            ),
          );

      await expectLater(
        loadTheVan(van: van2),
        throwsA(
          isA<VanTripAlreadyOpenException>()
              .having((e) => e.onVan, 'onVan', isFalse)
              .having((e) => e.openTripId, 'openTripId', firstTrip),
        ),
      );
      expect(await ledgerRows(), hasLength(1));
      expect(await onHand(van2), 0);
    });

    test('a CLOSED trip frees both the van and the driver', () async {
      await stockWithBatch(warehouseId, 100, 1000);
      final firstTrip = await loadTheVan();

      await (db.update(db.vanTrips)..where((t) => t.id.equals(firstTrip)))
          .write(VanTripsCompanion(
        status: const Value(kVanTripStatusClosed),
        closedAt: Value(DateTime.now()),
      ));

      final secondTrip = await loadTheVan();
      expect(secondTrip, isNot(firstTrip));
      expect(await ledgerRows(), hasLength(2));
      // The residual follows the DRIVER across trips.
      expect(await db.driverLedgerDao.getBalanceKobo(driverId), -100000);
    });

    test('openTripForVan / openTripForDriver see only the OPEN one', () async {
      await stockWithBatch(warehouseId, 100, 1000);
      final tripId = await loadTheVan();

      expect((await db.vanTripsDao.openTripForVan(vanId))?.id, tripId);
      expect((await db.vanTripsDao.openTripForDriver(driverId))?.id, tripId);

      await (db.update(db.vanTrips)..where((t) => t.id.equals(tripId)))
          .write(VanTripsCompanion(
        status: const Value(kVanTripStatusClosed),
        closedAt: Value(DateTime.now()),
      ));

      expect(await db.vanTripsDao.openTripForVan(vanId), isNull);
      expect(await db.vanTripsDao.openTripForDriver(driverId), isNull);
    });
  });

  // ═══ Guards and refusals ════════════════════════════════════════════════

  group('guards', () {
    test('an overload is refused by the existing stock guard and leaves NO '
        'trip, lot, ledger row or half-moved stock', () async {
      await stockWithBatch(warehouseId, 10, 1000);

      await expectLater(
        db.vanTripsDao.dispatchLoad(
          vanStoreId: vanId,
          driverUserId: driverId,
          sourceStoreId: warehouseId,
          performedBy: managerId,
          dispatchEventId: UuidV7.generate(),
          lines: [
            VanLoadLine(productId: productId, quantity: 50, loadPriceKobo: 5000),
          ],
        ),
        throwsA(isA<InsufficientStockException>()),
      );

      // The whole dispatch rolled back — this is the "both or neither" rule.
      expect(await db.select(db.vanTrips).get(), isEmpty);
      expect(await db.select(db.vanTripLots).get(), isEmpty);
      expect(await ledgerRows(), isEmpty);
      expect(await onHand(warehouseId), 10);
      expect(await onHand(vanId), 0);
      expect(await batchUnits(warehouseId), 10);
    });

    test('a partial multi-line overload rolls the WHOLE load back', () async {
      final second = UuidV7.generate();
      await db.into(db.products).insert(
            ProductsCompanion.insert(
              id: Value(second),
              businessId: businessId,
              name: 'Gulder 60cl',
            ),
          );
      await stockWithBatch(warehouseId, 100, 1000);
      await stockWithBatch(warehouseId, 5, 2000, product: second);

      await expectLater(
        db.vanTripsDao.dispatchLoad(
          vanStoreId: vanId,
          driverUserId: driverId,
          sourceStoreId: warehouseId,
          performedBy: managerId,
          dispatchEventId: UuidV7.generate(),
          lines: [
            // This line is fine…
            VanLoadLine(productId: productId, quantity: 20, loadPriceKobo: 5000),
            // …this one is not.
            VanLoadLine(productId: second, quantity: 50, loadPriceKobo: 5000),
          ],
        ),
        throwsA(isA<InsufficientStockException>()),
      );

      expect(await db.select(db.vanTrips).get(), isEmpty);
      expect(await ledgerRows(), isEmpty);
      expect(await onHand(warehouseId), 100,
          reason: 'the good line must not stay committed');
      expect(await onHand(vanId), 0);
      expect(await batchUnits(warehouseId), 100,
          reason: 'the good line\'s batch draw must roll back too');
    });

    test('a van cannot load from itself, and an empty load is refused',
        () async {
      await expectLater(
        db.vanTripsDao.dispatchLoad(
          vanStoreId: vanId,
          driverUserId: driverId,
          sourceStoreId: vanId,
          performedBy: managerId,
          dispatchEventId: UuidV7.generate(),
          lines: [
            VanLoadLine(productId: productId, quantity: 1, loadPriceKobo: 1),
          ],
        ),
        throwsA(isA<ArgumentError>()),
      );

      await expectLater(
        db.vanTripsDao.dispatchLoad(
          vanStoreId: vanId,
          driverUserId: driverId,
          sourceStoreId: warehouseId,
          performedBy: managerId,
          dispatchEventId: UuidV7.generate(),
          lines: const [],
        ),
        throwsA(isA<ArgumentError>()),
      );

      // Zero-quantity lines collapse away to nothing, which is also an empty
      // load — not a trip with no goods on it.
      await expectLater(
        db.vanTripsDao.dispatchLoad(
          vanStoreId: vanId,
          driverUserId: driverId,
          sourceStoreId: warehouseId,
          performedBy: managerId,
          dispatchEventId: UuidV7.generate(),
          lines: [
            VanLoadLine(productId: productId, quantity: 0, loadPriceKobo: 5000),
          ],
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(await db.select(db.vanTrips).get(), isEmpty);
    });

    test('a van load leg cannot be cancelled through the generic transfer '
        'cancel (spec §7.2)', () async {
      // A van load writes no stock_transfers header of its own, so construct
      // the case the guard exists for: a transfer that names a van endpoint.
      await stockWithBatch(warehouseId, 50, 1000);
      final transferId = await db.stockTransferDao.createTransfer(
        fromStoreId: warehouseId,
        toStoreId: vanId,
        productId: productId,
        quantity: 10,
        initiatedBy: managerId,
      );

      await expectLater(
        db.stockTransferDao.cancelTransfer(
          transferId: transferId,
          cancelledBy: managerId,
        ),
        throwsA(
          isA<VanLegNotCancellableException>().having(
            (e) => e.message,
            'message',
            allOf(contains('return'), isNot(contains('Exception'))),
          ),
        ),
      );

      // The refusal changed nothing.
      final header = await (db.select(db.stockTransfers)
            ..where((t) => t.id.equals(transferId)))
          .getSingle();
      expect(header.status, 'in_transit');
    });

    test('a normal store-to-store transfer still cancels fine', () async {
      final otherStore = UuidV7.generate();
      await db.into(db.stores).insert(
            StoresCompanion.insert(
              id: Value(otherStore),
              businessId: businessId,
              name: 'Branch 2',
            ),
          );
      await stockWithBatch(warehouseId, 50, 1000);

      final transferId = await db.stockTransferDao.createTransfer(
        fromStoreId: warehouseId,
        toStoreId: otherStore,
        productId: productId,
        quantity: 10,
        initiatedBy: managerId,
      );
      await db.stockTransferDao.cancelTransfer(
        transferId: transferId,
        cancelledBy: managerId,
      );

      final header = await (db.select(db.stockTransfers)
            ..where((t) => t.id.equals(transferId)))
          .getSingle();
      expect(header.status, 'cancelled');
    });
  });

  // ═══ Load-below-cost warning (spec §9.1 #1) ═════════════════════════════

  group('load-below-cost warning', () {
    test('names the underwater products and NOTHING else — the cost figure is '
        'never in the return value', () async {
      final second = UuidV7.generate();
      await db.into(db.products).insert(
            ProductsCompanion.insert(
              id: Value(second),
              businessId: businessId,
              name: 'Gulder 60cl',
            ),
          );
      await stockWithBatch(warehouseId, 100, 1000000); // costs ₦10,000
      await stockWithBatch(warehouseId, 100, 500000, product: second);

      final below = await db.vanTripsDao.productsPricedBelowCost(
        sourceStoreId: warehouseId,
        lines: [
          // Priced UNDER the ₦10,000 cost — underwater.
          VanLoadLine(productId: productId, quantity: 10, loadPriceKobo: 900000),
          // Priced over its ₦5,000 cost — fine.
          VanLoadLine(productId: second, quantity: 10, loadPriceKobo: 800000),
        ],
      );

      // A Set<String> of ids: a caller cannot leak a number it was never given.
      expect(below, {productId});
    });

    test('a price exactly AT cost is not "below" cost', () async {
      await stockWithBatch(warehouseId, 100, 1000000);
      final below = await db.vanTripsDao.productsPricedBelowCost(
        sourceStoreId: warehouseId,
        lines: [
          VanLoadLine(
            productId: productId,
            quantity: 10,
            loadPriceKobo: 1000000,
          ),
        ],
      );
      expect(below, isEmpty);
    });

    test('an UNCOSTED product is never "below cost" — that is a different '
        'disclosure', () async {
      await stockWithBatch(warehouseId, 100, 0);
      final below = await db.vanTripsDao.productsPricedBelowCost(
        sourceStoreId: warehouseId,
        lines: [
          VanLoadLine(productId: productId, quantity: 10, loadPriceKobo: 1),
        ],
      );
      expect(below, isEmpty);
    });

    test('peeking does NOT draw the queue down (safe on every keystroke)',
        () async {
      await stockWithBatch(warehouseId, 100, 1000000);
      for (var i = 0; i < 5; i++) {
        await db.vanTripsDao.productsPricedBelowCost(
          sourceStoreId: warehouseId,
          lines: [
            VanLoadLine(
              productId: productId,
              quantity: 40,
              loadPriceKobo: 100,
            ),
          ],
        );
      }
      expect(await batchUnits(warehouseId), 100);
      expect(await batchValueKobo(warehouseId), 100 * 1000000);
    });

    test('the blended cost across two layers is what the warning compares '
        'against', () async {
      final older = DateTime(2026, 1, 1);
      final newer = DateTime(2026, 2, 1);
      await stockWithBatch(warehouseId, 60, 1000, receivedAt: older);
      await stockWithBatch(warehouseId, 100, 2000, receivedAt: newer);
      // Drawing 100 blends to 1,400/unit.

      expect(
        await db.vanTripsDao.productsPricedBelowCost(
          sourceStoreId: warehouseId,
          lines: [
            VanLoadLine(
              productId: productId,
              quantity: 100,
              loadPriceKobo: 1399,
            ),
          ],
        ),
        {productId},
      );
      expect(
        await db.vanTripsDao.productsPricedBelowCost(
          sourceStoreId: warehouseId,
          lines: [
            VanLoadLine(
              productId: productId,
              quantity: 100,
              loadPriceKobo: 1400,
            ),
          ],
        ),
        isEmpty,
      );
    });
  });

  // ═══ Sync ═══════════════════════════════════════════════════════════════

  group('sync', () {
    test('every van row a dispatch writes is enqueued for push', () async {
      await stockWithBatch(warehouseId, 200, 1000000);

      final result = await db.vanTripsDao.dispatchLoad(
        vanStoreId: vanId,
        driverUserId: driverId,
        sourceStoreId: warehouseId,
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
        lines: [
          VanLoadLine(
            productId: productId,
            quantity: 100,
            loadPriceKobo: 1150000,
            shellsOut: 100,
          ),
        ],
      );

      final queued = await getPendingQueue(db);
      final tables = queued.map((r) => r.actionType).toSet();
      expect(tables, containsAll(<String>{
        'van_trips:upsert',
        'van_trip_lots:upsert',
        'driver_ledger_entries:upsert',
      }));

      // The trip is pushed AFTER the shell roll-up, not as a stub a peer would
      // briefly see with shells_out 0.
      final tripPushes =
          queued.where((r) => r.actionType == 'van_trips:upsert').toList();
      expect(tripPushes, hasLength(1));
      final payload = decodePayload(tripPushes.single);
      expect(payload['id'], result.tripId);
      expect(payload['shells_out'], 100);
      expect(payload['status'], kVanTripStatusOpen);
      // Explicit id + business_id, per the synced-write invariant — the cloud
      // must never mint a different id for a row this device already holds.
      expect(payload['business_id'], businessId);
      expect(payload['van_store_id'], vanId);
      expect(payload['driver_user_id'], driverId);
      expect(payload['source_store_id'], warehouseId);
    });

    test('the enqueued lot carries the cost snapshot and the idempotency key',
        () async {
      await stockWithBatch(warehouseId, 200, 1000000);
      final key = UuidV7.generate();

      await db.vanTripsDao.dispatchLoad(
        vanStoreId: vanId,
        driverUserId: driverId,
        sourceStoreId: warehouseId,
        performedBy: managerId,
        dispatchEventId: key,
        lines: [
          VanLoadLine(
            productId: productId,
            quantity: 100,
            loadPriceKobo: 1150000,
            shellsOut: 100,
          ),
        ],
      );

      final lotPush = (await getPendingQueue(db))
          .firstWhere((r) => r.actionType == 'van_trip_lots:upsert');
      final payload = decodePayload(lotPush);
      expect(payload['dispatch_event_id'], key);
      expect(payload['unit_cost_kobo'], 1000000);
      expect(payload['load_price_kobo'], 1150000);
      expect(payload['qty_remaining'], 100);
      expect(payload['shells_out'], 100);
    });
  });

  // ═══ The ledger read surface #144/#145/#146 build on ════════════════════

  group('DriverLedgerDao', () {
    test('watchAllBalancesKobo keys by driver and nets across trips', () async {
      final driver2 = UuidV7.generate();
      final van2 = UuidV7.generate();
      await db.into(db.users).insert(
            UsersCompanion.insert(
              id: Value(driver2),
              businessId: businessId,
              name: 'Driver Ada',
              pin: '2222',
            ),
          );
      await db.into(db.stores).insert(
            StoresCompanion.insert(
              id: Value(van2),
              businessId: businessId,
              name: 'Van 2',
              kind: const Value(kStoreKindVan),
            ),
          );
      await stockWithBatch(warehouseId, 200, 1000);

      await db.vanTripsDao.dispatchLoad(
        vanStoreId: vanId,
        driverUserId: driverId,
        sourceStoreId: warehouseId,
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
        lines: [
          VanLoadLine(productId: productId, quantity: 10, loadPriceKobo: 5000),
        ],
      );
      await db.vanTripsDao.dispatchLoad(
        vanStoreId: van2,
        driverUserId: driver2,
        sourceStoreId: warehouseId,
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
        lines: [
          VanLoadLine(productId: productId, quantity: 4, loadPriceKobo: 5000),
        ],
      );

      final balances = await db.driverLedgerDao.watchAllBalancesKobo().first;
      expect(balances[driverId], -50000);
      expect(balances[driver2], -20000);
    });

    test('a credit reduces what the driver owes (the #144 seam)', () async {
      await stockWithBatch(warehouseId, 100, 1000);
      final result = await db.vanTripsDao.dispatchLoad(
        vanStoreId: vanId,
        driverUserId: driverId,
        sourceStoreId: warehouseId,
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
        lines: [
          VanLoadLine(productId: productId, quantity: 10, loadPriceKobo: 5000),
        ],
      );
      expect(await db.driverLedgerDao.getBalanceKobo(driverId), -50000);

      await db.driverLedgerDao.postEntry(
        driverUserId: driverId,
        tripId: result.tripId,
        type: kDriverLedgerTypePaymentCash,
        amountKobo: 30000,
        isCredit: true,
        referenceType: kDriverLedgerRefPayment,
        referenceId: UuidV7.generate(),
        activityDate: DateTime.now(),
        performedBy: managerId,
        paymentMethod: 'cash',
      );

      expect(await db.driverLedgerDao.getBalanceKobo(driverId), -20000);
    });

    test('voiding appends an opposite-sign compensating row; the original is '
        'marked, never edited or deleted', () async {
      await stockWithBatch(warehouseId, 100, 1000);
      await db.vanTripsDao.dispatchLoad(
        vanStoreId: vanId,
        driverUserId: driverId,
        sourceStoreId: warehouseId,
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
        lines: [
          VanLoadLine(productId: productId, quantity: 10, loadPriceKobo: 5000),
        ],
      );
      final original = (await ledgerRows()).single;

      final applied = await db.driverLedgerDao.voidEntry(
        entryId: original.id,
        voidedBy: managerId,
        reason: 'loaded the wrong van',
      );
      expect(applied, isTrue);

      final rows = await ledgerRows();
      expect(rows, hasLength(2), reason: 'a compensating row was APPENDED');
      final comp = rows.firstWhere((r) => r.id != original.id);
      expect(comp.type, kDriverLedgerTypeVoid);
      expect(comp.referenceType, kDriverLedgerRefEntry);
      expect(comp.referenceId, original.id);
      expect(comp.signedAmountKobo, -original.signedAmountKobo);

      // The original survives, marked.
      final reread = rows.firstWhere((r) => r.id == original.id);
      expect(reread.voidedAt, isNotNull);
      expect(reread.voidReason, 'loaded the wrong van');
      expect(reread.amountKobo, original.amountKobo);

      // Net effect: the debt is gone. (Voided rows are NOT filtered out of the
      // sum — the pair already nets to zero; filtering too would double-reverse.)
      expect(await db.driverLedgerDao.getBalanceKobo(driverId), 0);

      // A double-void is a no-op.
      expect(
        await db.driverLedgerDao.voidEntry(
          entryId: original.id,
          voidedBy: managerId,
          reason: 'again',
        ),
        isFalse,
      );
      expect(await ledgerRows(), hasLength(2));
    });

    test('postEntry refuses a negative magnitude', () async {
      await expectLater(
        db.driverLedgerDao.postEntry(
          driverUserId: driverId,
          type: kDriverLedgerTypePaymentCash,
          amountKobo: -1,
          isCredit: true,
          referenceType: kDriverLedgerRefPayment,
          activityDate: DateTime.now(),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
