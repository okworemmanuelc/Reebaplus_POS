// van_close_test.dart
//
// #145 (PRD #139 as amended by #161 / ADR 0019 decision 3, van-sales spec §5.5,
// §6, §7, §9.4) — reconcile and close: the trip's last write.
//
// The pure math is pinned in `van_trip_position_test.dart`. What this file
// tests is everything the math CANNOT see:
//
//   · the close artifact is PERSISTED, so a report reads it instead of
//     re-deriving van P&L (ADR 0019 decision 3 — the rejected alternative is
//     "compute van profit at report time");
//   · two vans loading the same product get identical per-trip COGS regardless
//     of close order (the claim ADR 0019 says is "deterministic and two-van safe
//     by construction", and the one most likely to rot);
//   · a residual does not block close, and carries on the DRIVER's cross-trip
//     balance rather than the run's;
//   · a road sale that syncs after close posts the compensating pair, flags the
//     trip restated and writes ONE audit row — audited, never prompted;
//   · the close-vs-outbox barrier has an honest signal behind it (what the UI
//     does with that signal is van_close_barrier_test.dart's job).
//
// In-memory Drift via bootstrapTestDb(); same style as van_returns_test.dart.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

const _loadPrice = 1150000; // ₦11,500
const _unitCost = 1000000; // ₦10,000

void main() {
  late AppDatabase db;
  late String businessId;
  late String warehouseId;
  late String vanId;
  late String driverId;
  late String managerId;
  late String productId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;

    warehouseId = UuidV7.generate();
    vanId = UuidV7.generate();
    driverId = UuidV7.generate();
    managerId = UuidV7.generate();
    productId = UuidV7.generate();

    await db
        .into(db.stores)
        .insert(
          StoresCompanion.insert(
            id: Value(warehouseId),
            businessId: businessId,
            name: 'Main Warehouse',
          ),
        );
    await db
        .into(db.stores)
        .insert(
          StoresCompanion.insert(
            id: Value(vanId),
            businessId: businessId,
            name: 'Van 1',
            kind: const Value(kStoreKindVan),
          ),
        );
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: Value(driverId),
            businessId: businessId,
            name: 'Driver Dan',
            pin: '0000',
          ),
        );
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: Value(managerId),
            businessId: businessId,
            name: 'Manager Mo',
            pin: '1111',
          ),
        );
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: Value(productId),
            businessId: businessId,
            name: 'Star 60cl',
            retailerPriceKobo: const Value(_loadPrice),
          ),
        );
  });

  tearDown(() async => db.close());

  Future<void> stockWithBatch(
    String store,
    int qty,
    int unitCostKobo, {
    DateTime? receivedAt,
  }) async {
    await db.inventoryDao.adjustStock(
      productId,
      store,
      qty,
      'opening',
      managerId,
      trackCost: false,
    );
    await db.costBatchesDao.recordInflowBatch(
      productId: productId,
      storeId: store,
      quantity: qty,
      costKobo: unitCostKobo,
      receivedAt: receivedAt,
    );
  }

  Future<String> loadVan({
    required String van,
    required String driver,
    int qty = 100,
    int loadPriceKobo = _loadPrice,
    int shellsOut = 0,
  }) async {
    final r = await db.vanTripsDao.dispatchLoad(
      vanStoreId: van,
      driverUserId: driver,
      sourceStoreId: warehouseId,
      lines: [
        VanLoadLine(
          productId: productId,
          quantity: qty,
          loadPriceKobo: loadPriceKobo,
          shellsOut: shellsOut,
        ),
      ],
      performedBy: managerId,
      dispatchEventId: UuidV7.generate(),
    );
    return r.tripId;
  }

  var orderSeq = 0;

  /// Rings [qty] units on the van — the shape the driver terminal produces.
  Future<String> ringSale({
    required String storeId,
    int qty = 10,
    int unitPriceKobo = _loadPrice,
  }) async {
    final id = UuidV7.generate();
    final total = qty * unitPriceKobo;
    await db.ordersDao.createOrder(
      order: OrdersCompanion.insert(
        id: Value(id),
        businessId: businessId,
        orderNumber: 'ORD-${(++orderSeq).toString().padLeft(6, '0')}',
        totalAmountKobo: total,
        netAmountKobo: total,
        amountPaidKobo: Value(total),
        paymentType: 'cash',
        status: 'pending',
        staffId: Value(driverId),
        storeId: Value(storeId),
      ),
      items: [
        OrderItemsCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: businessId,
          orderId: id,
          productId: Value(productId),
          storeId: storeId,
          quantity: qty,
          unitPriceKobo: unitPriceKobo,
          totalKobo: total,
        ),
      ],
      amountPaidKobo: total,
      totalAmountKobo: total,
      staffId: driverId,
      storeId: storeId,
    );
    return id;
  }

  Future<VanTripData> trip(String id) =>
      (db.select(db.vanTrips)..where((t) => t.id.equals(id))).getSingle();

  Future<List<ActivityLogData>> logsFor(String action) =>
      (db.select(db.activityLogs)
            ..where((l) => l.action.equals(action)))
          .get();

  group('close persists the artifact (ADR 0019 decision 3)', () {
    test('the spec §6.3 trip closes with the artifact tied to the kobo',
        () async {
      // Mon: 200 @ ₦10,000 in the warehouse; load 100 @ ₦11,500 + 100 shells.
      await stockWithBatch(warehouseId, 200, _unitCost);
      final tripId = await loadVan(
        van: vanId,
        driver: driverId,
        shellsOut: 100,
      );

      // Tue + Wed: sell 60, restock 40, sell 30.
      await ringSale(storeId: vanId, qty: 60);
      await db.vanTripsDao.restockTrip(
        tripId: tripId,
        lines: [
          VanLoadLine(
            productId: productId,
            quantity: 40,
            loadPriceKobo: _loadPrice,
          ),
        ],
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
      );
      await ringSale(storeId: vanId, qty: 30);

      // Thu: 45 good back (65 shells), 3 damaged, remit ₦900,000.
      await db.vanTripsDao.recordReturn(
        tripId: tripId,
        lines: [
          VanReturnLine(
            productId: productId,
            quantity: 45,
            condition: kVanReturnConditionGood,
            shellsBack: 65,
          ),
          VanReturnLine(
            productId: productId,
            quantity: 3,
            condition: kVanReturnConditionDamaged,
          ),
        ],
        performedBy: managerId,
      );
      await db.vanTripsDao.recordDriverPayment(
        tripId: tripId,
        amountKobo: 90000000,
        method: 'cash',
        performedBy: managerId,
      );

      final result = await db.vanTripsDao.closeTrip(
        tripId: tripId,
        performedBy: managerId,
      );

      // The position ties out before anything is written.
      expect(result.position.tiesOut, isTrue);
      expect(result.position.outstandingKobo, 19250000); // ₦192,500

      // And the ROW carries the whole artifact — this is what #147 reads.
      final row = result.trip;
      expect(row.status, kVanTripStatusClosed);
      expect(row.closedAt, isNotNull);
      expect(row.closedBy, managerId);
      expect(row.closedWithBalance, isTrue);
      expect(row.cogsKobo, 95000000); // ₦950,000
      expect(row.recoveredKobo, 141750000); // ₦1,417,500
      expect(row.unremittedKobo, 13500000); // ₦135,000
      expect(row.shortageLossKobo, 2000000); // ₦20,000 at COST
      expect(row.damageLossKobo, 3000000); // ₦30,000 at COST
      expect(row.profitKobo, 46750000); // ₦467,500
      expect(row.shellsOut, 100);
      expect(row.shellsBack, 65);

      // A report needs NO re-derivation: profit is readable straight off the
      // row and equals recovered − cogs.
      expect(row.profitKobo, row.recoveredKobo - row.cogsKobo);
    });

    test('a settled trip closes at balance 0 and is not flagged', () async {
      await stockWithBatch(warehouseId, 20, _unitCost);
      final tripId = await loadVan(van: vanId, driver: driverId, qty: 10);
      await ringSale(storeId: vanId, qty: 6);
      await db.vanTripsDao.recordReturn(
        tripId: tripId,
        lines: [
          VanReturnLine(
            productId: productId,
            quantity: 4,
            condition: kVanReturnConditionGood,
          ),
        ],
        performedBy: managerId,
      );
      await db.vanTripsDao.recordDriverPayment(
        tripId: tripId,
        amountKobo: 6 * _loadPrice,
        method: 'cash',
        performedBy: managerId,
      );

      final result = await db.vanTripsDao.closeTrip(
        tripId: tripId,
        performedBy: managerId,
      );

      expect(result.position.isSettled, isTrue);
      expect(result.trip.closedWithBalance, isFalse);
      expect(
        await db.driverLedgerDao.getBalanceKobo(driverId),
        0,
        reason: 'a perfectly reconciled trip leaves the driver owing nothing',
      );
    });

    test('close is allowed with a residual and it follows the DRIVER',
        () async {
      await stockWithBatch(warehouseId, 20, _unitCost);
      final tripId = await loadVan(van: vanId, driver: driverId, qty: 10);
      await ringSale(storeId: vanId, qty: 6); // 4 go missing, nothing remitted

      final result = await db.vanTripsDao.closeTrip(
        tripId: tripId,
        performedBy: managerId,
      );

      expect(result.trip.status, kVanTripStatusClosed);
      expect(result.closedWithBalance, isTrue);
      expect(result.position.outstandingKobo, 10 * _loadPrice);
      // Spec §9.4 #14 — the residual carries forward on the CROSS-TRIP balance.
      expect(
        await db.driverLedgerDao.getBalanceKobo(driverId),
        -10 * _loadPrice,
      );
      expect(
        await db.driverLedgerDao.getTripBalanceKobo(tripId),
        -10 * _loadPrice,
      );
    });

    test('close clears the van of the goods that never came back', () async {
      // The shortage is stock the van's inventory row still carries. Left
      // behind it is phantom company stock (van stock counts on All Stores,
      // spec §4.1) while the artifact's COGS already treats it as gone.
      await stockWithBatch(warehouseId, 20, _unitCost);
      final tripId = await loadVan(van: vanId, driver: driverId, qty: 10);
      await ringSale(storeId: vanId, qty: 6);

      expect(
        await db.stockLedgerDao.getCurrentStock(productId, vanId),
        4,
        reason: 'before close the missing units are still on the van',
      );

      await db.vanTripsDao.closeTrip(tripId: tripId, performedBy: managerId);

      expect(await db.stockLedgerDao.getCurrentStock(productId, vanId), 0);
      final adj =
          await (db.select(db.stockAdjustments)
                ..where((a) => a.reason.equals(kVanCloseShortageReason)))
              .get();
      expect(adj, hasLength(1));
      expect(adj.single.quantityDiff, -4);
      expect(
        adj.single.valueKobo,
        4 * _unitCost,
        reason: 'the loss basis is the SNAPSHOTTED cost, never the load price',
      );
    });

    test('a closed trip refuses every in-place edit', () async {
      await stockWithBatch(warehouseId, 20, _unitCost);
      final tripId = await loadVan(van: vanId, driver: driverId, qty: 10);
      await db.vanTripsDao.closeTrip(tripId: tripId, performedBy: managerId);

      // Spec §9.4 #16 — corrections are compensating entries, never edits.
      expect(
        () => db.vanTripsDao.closeTrip(
          tripId: tripId,
          performedBy: managerId,
        ),
        throwsA(isA<VanTripNotOpenException>()),
      );
      expect(
        () => db.vanTripsDao.postWriteOff(
          tripId: tripId,
          type: kDriverLedgerTypeShortageWriteoff,
          amountKobo: 100,
          performedBy: managerId,
        ),
        throwsA(isA<VanTripNotOpenException>()),
      );
      expect(
        () => db.vanTripsDao.recordDriverPayment(
          tripId: tripId,
          amountKobo: 100,
          method: 'cash',
          performedBy: managerId,
        ),
        throwsA(isA<VanTripNotOpenException>()),
      );
      expect(
        () => db.vanTripsDao.recordReturn(
          tripId: tripId,
          lines: [
            VanReturnLine(
              productId: productId,
              quantity: 1,
              condition: kVanReturnConditionGood,
            ),
          ],
          performedBy: managerId,
        ),
        throwsA(isA<VanTripNotOpenException>()),
      );
    });
  });

  group('write-offs are dual-valued (spec §5.5)', () {
    test('a write-off credits the driver at LOAD PRICE', () async {
      await stockWithBatch(warehouseId, 20, _unitCost);
      final tripId = await loadVan(van: vanId, driver: driverId, qty: 10);
      await ringSale(storeId: vanId, qty: 6);
      await db.vanTripsDao.recordDriverPayment(
        tripId: tripId,
        amountKobo: 6 * _loadPrice,
        method: 'cash',
        performedBy: managerId,
      );

      await db.vanTripsDao.postWriteOff(
        tripId: tripId,
        type: kDriverLedgerTypeShortageWriteoff,
        amountKobo: 4 * _loadPrice,
        performedBy: managerId,
        reason: 'Stolen off the back of the van',
      );

      final entries = await db.driverLedgerDao.entriesForTrip(tripId);
      final wo = entries.singleWhere(
        (e) => e.type == kDriverLedgerTypeShortageWriteoff,
      );
      expect(wo.signedAmountKobo, 4 * _loadPrice, reason: 'a CREDIT');
      expect(wo.referenceType, kDriverLedgerRefTrip);
      expect(wo.referenceNote, 'Stolen off the back of the van');

      final result = await db.vanTripsDao.closeTrip(
        tripId: tripId,
        performedBy: managerId,
      );
      expect(result.trip.closedWithBalance, isFalse);
      expect(result.trip.shortageWriteoffKobo, 4 * _loadPrice);
      // And the COMPANY loss stays at COST — booking load price would
      // overstate it by the margin never earned.
      expect(result.trip.shortageLossKobo, 4 * _unitCost);
      // Profit is untouched by the forgiveness: the units are inside consumed,
      // so their cost is already in COGS (the double-count guard).
      expect(result.trip.profitKobo, 6 * _loadPrice - 10 * _unitCost);
    });

    test('only the two write-off types are accepted', () async {
      await stockWithBatch(warehouseId, 20, _unitCost);
      final tripId = await loadVan(van: vanId, driver: driverId, qty: 10);
      expect(
        () => db.vanTripsDao.postWriteOff(
          tripId: tripId,
          type: kDriverLedgerTypePaymentCash,
          amountKobo: 100,
          performedBy: managerId,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('two-van determinism (spec §13, ADR 0019 decision 1)', () {
    test('interleaved loads and closes give identical per-trip COGS', () async {
      // One product, two vans, two cost layers at different prices. The claim:
      // each trip's COGS depends only on ITS OWN lots' snapshots, so the order
      // the trips close in cannot change either answer. If van cost ever came
      // from the batch queue instead of the snapshot, this test goes red.
      final van2 = UuidV7.generate();
      final driver2 = UuidV7.generate();
      await db
          .into(db.stores)
          .insert(
            StoresCompanion.insert(
              id: Value(van2),
              businessId: businessId,
              name: 'Van 2',
              kind: const Value(kStoreKindVan),
            ),
          );
      await db
          .into(db.users)
          .insert(
            UsersCompanion.insert(
              id: Value(driver2),
              businessId: businessId,
              name: 'Driver Dee',
              pin: '2222',
            ),
          );

      // Layer 1: 10 @ ₦10,000. Layer 2: 10 @ ₦12,000.
      await stockWithBatch(
        warehouseId,
        10,
        _unitCost,
        receivedAt: DateTime(2026, 7, 1),
      );
      await stockWithBatch(
        warehouseId,
        10,
        1200000,
        receivedAt: DateTime(2026, 7, 2),
      );

      // Van 1 loads first and drains the cheap layer; van 2 loads second.
      final trip1 = await loadVan(van: vanId, driver: driverId, qty: 10);
      final trip2 = await loadVan(van: van2, driver: driver2, qty: 10);

      // Close them in the "wrong" order: van 2 first.
      final closed2 = await db.vanTripsDao.closeTrip(
        tripId: trip2,
        performedBy: managerId,
      );
      final closed1 = await db.vanTripsDao.closeTrip(
        tripId: trip1,
        performedBy: managerId,
      );

      expect(
        closed1.trip.cogsKobo,
        10 * _unitCost,
        reason: 'van 1 drew the ₦10,000 layer at dispatch and keeps it',
      );
      expect(
        closed2.trip.cogsKobo,
        10 * 1200000,
        reason: 'van 2 drew the ₦12,000 layer and keeps it',
      );

      // And each lot carries the snapshot the close read, so the answer is
      // reconstructible from the row rather than from a replay.
      final lots1 = await db.vanTripsDao.lotsForTrip(trip1);
      final lots2 = await db.vanTripsDao.lotsForTrip(trip2);
      expect(lots1.single.unitCostKobo, _unitCost);
      expect(lots2.single.unitCostKobo, 1200000);
    });
  });

  group('post-close restatement (spec §9.4 #15)', () {
    test('a late road sale posts the compensating pair and flags the trip',
        () async {
      await stockWithBatch(warehouseId, 20, _unitCost);
      final tripId = await loadVan(van: vanId, driver: driverId, qty: 10);
      await ringSale(storeId: vanId, qty: 6);
      await db.vanTripsDao.recordDriverPayment(
        tripId: tripId,
        amountKobo: 6 * _loadPrice,
        method: 'cash',
        performedBy: managerId,
      );
      final closed = await db.vanTripsDao.closeTrip(
        tripId: tripId,
        performedBy: managerId,
      );
      expect(closed.trip.unremittedKobo, 0);
      expect(closed.trip.shortageLossKobo, 4 * _unitCost);
      final balanceAtClose = await db.driverLedgerDao.getBalanceKobo(driverId);

      // Friday: the driver's device finally syncs the 4 crates they rang on
      // Thursday. The order lands against a CLOSED trip.
      final lateId = UuidV7.generate();
      const total = 4 * _loadPrice;
      await db
          .into(db.orders)
          .insert(
            OrdersCompanion.insert(
              id: Value(lateId),
              businessId: businessId,
              orderNumber: 'ORD-LATE',
              totalAmountKobo: total,
              netAmountKobo: total,
              amountPaidKobo: const Value(total),
              paymentType: 'cash',
              status: 'pending',
              storeId: Value(vanId),
              vanTripId: Value(tripId),
            ),
          );
      await db
          .into(db.orderItems)
          .insert(
            OrderItemsCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              orderId: lateId,
              productId: Value(productId),
              storeId: vanId,
              quantity: 4,
              unitPriceKobo: _loadPrice,
              totalKobo: total,
            ),
          );

      final restated = await db.vanTripsDao.restateClosedTrip(tripId);
      expect(restated, 4 * _loadPrice);

      final row = await trip(tripId);
      expect(row.restatedAt, isNotNull);
      expect(row.restatedReason, contains('after this trip was closed'));
      expect(
        row.unremittedKobo,
        4 * _loadPrice,
        reason: 'the units are road takings now, not shortage',
      );
      expect(row.shortageLossKobo, 0);
      expect(
        row.profitKobo,
        closed.trip.profitKobo,
        reason: 'a sale moves neither COGS nor recovered value',
      );

      // The pair nets to zero on the balance — it exists for the trail.
      final pair =
          (await db.driverLedgerDao.entriesForTrip(tripId))
              .where((e) => e.type == kDriverLedgerTypeRestatement)
              .toList();
      expect(pair, hasLength(2));
      expect(pair.fold<int>(0, (s, e) => s + e.signedAmountKobo), 0);
      expect(
        await db.driverLedgerDao.getBalanceKobo(driverId),
        balanceAtClose,
      );

      // ONE rolled-up audit row — informed, not interrogated.
      expect(await logsFor('van.trip.restated'), hasLength(1));
    });

    test('restating twice is a no-op', () async {
      await stockWithBatch(warehouseId, 20, _unitCost);
      final tripId = await loadVan(van: vanId, driver: driverId, qty: 10);
      await db.vanTripsDao.closeTrip(tripId: tripId, performedBy: managerId);

      final lateId = UuidV7.generate();
      const total = 3 * _loadPrice;
      await db
          .into(db.orders)
          .insert(
            OrdersCompanion.insert(
              id: Value(lateId),
              businessId: businessId,
              orderNumber: 'ORD-LATE-2',
              totalAmountKobo: total,
              netAmountKobo: total,
              amountPaidKobo: const Value(total),
              paymentType: 'cash',
              status: 'pending',
              storeId: Value(vanId),
              vanTripId: Value(tripId),
            ),
          );
      await db
          .into(db.orderItems)
          .insert(
            OrderItemsCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              orderId: lateId,
              productId: Value(productId),
              storeId: vanId,
              quantity: 3,
              unitPriceKobo: _loadPrice,
              totalKobo: total,
            ),
          );

      expect(await db.vanTripsDao.restateClosedTrip(tripId), 3 * _loadPrice);
      expect(
        await db.vanTripsDao.restateClosedTrip(tripId),
        0,
        reason: 'the drift is measured against the artifact it just rewrote',
      );
      expect(await logsFor('van.trip.restated'), hasLength(1));
    });

    test('the sweep only touches trips that actually drifted', () async {
      await stockWithBatch(warehouseId, 20, _unitCost);
      final tripId = await loadVan(van: vanId, driver: driverId, qty: 10);
      await db.vanTripsDao.closeTrip(tripId: tripId, performedBy: managerId);

      expect(await db.vanTripsDao.restateClosedTripsWithLateSales(), 0);
      expect(await logsFor('van.trip.restated'), isEmpty);
    });

    test('an OPEN trip is never restated — it has no artifact yet', () async {
      await stockWithBatch(warehouseId, 20, _unitCost);
      final tripId = await loadVan(van: vanId, driver: driverId, qty: 10);
      await ringSale(storeId: vanId, qty: 6);
      expect(await db.vanTripsDao.restateClosedTrip(tripId), 0);
    });
  });

  group('the close-vs-outbox barrier (spec §7.4 / §9.4)', () {
    test('a road sale still in the outbox is counted as pending', () async {
      await stockWithBatch(warehouseId, 20, _unitCost);
      final tripId = await loadVan(van: vanId, driver: driverId, qty: 10);
      final orderId = await ringSale(storeId: vanId, qty: 6);

      // No envelope in the queue → nothing pending (the v1 path owns its own
      // header, so an absent envelope means "confirmed").
      expect(await db.vanTripsDao.pendingSaleEnvelopeCountForTrip(tripId), 0);

      // Now put an un-synced v2 envelope for that order into the outbox — the
      // exact durable state `SyncDao.saleEnvelopeState` classifies as pending.
      await db
          .into(db.syncQueue)
          .insert(
            SyncQueueCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              actionType: 'domain:pos_record_sale_v2',
              payload: '{"p_order_id":"$orderId"}',
            ),
          );

      expect(
        await db.vanTripsDao.pendingSaleEnvelopeCountForTrip(tripId),
        1,
        reason:
            'Confirm & close is DISABLED while a road sale has not reached the '
            'cloud (#208 item 5) — you do not assign blame from an incomplete '
            'picture. What the barrier does with this count is pinned in '
            'van_close_barrier_test.dart; this is the honest signal under it',
      );
    });
  });

  group('stale open trips (spec §9.4 #17)', () {
    test('a trip out longer than the window is nagged about', () async {
      await stockWithBatch(warehouseId, 40, _unitCost);
      final fresh = await loadVan(van: vanId, driver: driverId, qty: 10);

      expect(await db.vanTripsDao.staleOpenTrips(), isEmpty);

      // Backdate it past the window.
      await (db.update(db.vanTrips)..where((t) => t.id.equals(fresh))).write(
        VanTripsCompanion(
          openedAt: Value(
            DateTime.now().subtract(
              const Duration(days: kVanStaleTripDays + 1),
            ),
          ),
        ),
      );
      final stale = await db.vanTripsDao.staleOpenTrips();
      expect(stale, hasLength(1));
      expect(stale.single.id, fresh);

      // A closed trip never nags, however old.
      await db.vanTripsDao.closeTrip(tripId: fresh, performedBy: managerId);
      expect(await db.vanTripsDao.staleOpenTrips(), isEmpty);
    });
  });
}
