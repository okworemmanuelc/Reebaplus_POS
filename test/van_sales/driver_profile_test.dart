// driver_profile_test.dart
//
// #146 (PRD #139 as amended by #161 / ADR 0019, van-sales spec §9.5, §11) —
// the driver profile's feeds and the offboarding guard.
//
// What the pure `driver_directory_test.dart` cannot see, and this file pins:
//
//   · the OFFBOARDING GUARD (spec §9.5 #20) — an open trip is a hard block, a
//     non-zero balance needs a deliberate acknowledgement, and a driver can
//     never acknowledge their own debt away;
//   · balance and history are CROSS-TRIP and running: the profile's figure is
//     the same `Σ signed_amount_kobo` the hub and the reconcile screen show,
//     over every trip the driver ever ran;
//   · trips are ordered and filtered by OPENING date, and carry
//     closed-with-balance and restated on the row itself;
//   · the crate tab's numbers are the trip's own shell memo columns, for an
//     open trip and a closed one alike, and they agree with the position the
//     reconcile screen computes (spec §11);
//   · the period selector scopes the HISTORY and leaves the balance alone.
//
// In-memory Drift via bootstrapTestDb(); same style as van_close_test.dart.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';

import '../helpers/dispatch_test_utils.dart';

const _loadPrice = 1150000; // ₦11,500
const _unitCost = 1000000; // ₦10,000

void main() {
  late AppDatabase db;
  late String businessId;
  late String warehouseId;
  late String vanA;
  late String vanB;
  late String driverId;
  late String managerId;
  late String productId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;

    warehouseId = UuidV7.generate();
    vanA = UuidV7.generate();
    vanB = UuidV7.generate();
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
    for (final (id, name) in [(vanA, 'Van 1'), (vanB, 'Van 2')]) {
      await db
          .into(db.stores)
          .insert(
            StoresCompanion.insert(
              id: Value(id),
              businessId: businessId,
              name: name,
              kind: const Value(kStoreKindVan),
            ),
          );
    }
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

  Future<void> stockWithBatch(String store, int qty) async {
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
      costKobo: _unitCost,
    );
  }

  Future<String> loadVan({
    required String van,
    int qty = 100,
    int shellsOut = 0,
    DateTime? at,
  }) async {
    final r = await db.vanTripsDao.dispatchLoad(
      vanStoreId: van,
      driverUserId: driverId,
      sourceStoreId: warehouseId,
      lines: [
        VanLoadLine(
          productId: productId,
          quantity: qty,
          loadPriceKobo: _loadPrice,
          shellsOut: shellsOut,
        ),
      ],
      performedBy: managerId,
      dispatchEventId: UuidV7.generate(),
      dispatchedAt: at,
    );
    return r.tripId;
  }

  var orderSeq = 0;

  /// Rings [qty] units on the van — the shape the driver terminal produces.
  Future<String> ringSale({required String storeId, int qty = 10}) async {
    final id = UuidV7.generate();
    final total = qty * _loadPrice;
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
          unitPriceKobo: _loadPrice,
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

  // ── §9.5 #20 — the offboarding guard ──────────────────────────────────────

  group('offboarding guard', () {
    test('a driver with nothing outstanding may be offboarded', () async {
      final check = await db.vanTripsDao.checkDriverOffboarding(driverId);
      expect(check.isClear, isTrue);
      expect(check.requiresAcknowledgement, isFalse);
      await db.vanTripsDao.assertDriverOffboardable(
        driverId,
        driverName: 'Driver Dan',
      );
    });

    test('an OPEN trip is a hard block that no acknowledgement clears',
        () async {
      await stockWithBatch(warehouseId, 200);
      final tripId = await loadVan(van: vanA);

      final check = await db.vanTripsDao.checkDriverOffboarding(driverId);
      expect(check.hasOpenTrip, isTrue);
      expect(check.openTrip!.id, tripId);
      expect(check.isHardBlocked, isTrue);
      expect(check.requiresAcknowledgement, isFalse);

      // Even WITH the acknowledgement flag: a van on the road is a van on the
      // road.
      await expectLater(
        db.vanTripsDao.assertDriverOffboardable(
          driverId,
          driverName: 'Driver Dan',
          acknowledgedBalance: true,
        ),
        throwsA(
          isA<DriverOffboardingBlockedException>()
              .having((e) => e.canAcknowledge, 'canAcknowledge', isFalse)
              .having((e) => e.openTripId, 'openTripId', tripId)
              .having((e) => e.message, 'message', contains('still out on a trip')),
        ),
      );
    });

    test('a non-zero balance blocks UNLESS it is acknowledged', () async {
      await stockWithBatch(warehouseId, 200);
      final tripId = await loadVan(van: vanA, qty: 100);
      await ringSale(storeId: vanA, qty: 100);
      // Close with a residual: the driver took 100 units and handed in nothing.
      await db.vanTripsDao.closeTrip(tripId: tripId, performedBy: managerId);

      final check = await db.vanTripsDao.checkDriverOffboarding(driverId);
      expect(check.hasOpenTrip, isFalse);
      expect(check.balanceKobo, -100 * _loadPrice);
      expect(check.requiresAcknowledgement, isTrue);

      await expectLater(
        db.vanTripsDao.assertDriverOffboardable(
          driverId,
          driverName: 'Driver Dan',
        ),
        throwsA(
          isA<DriverOffboardingBlockedException>()
              .having((e) => e.canAcknowledge, 'canAcknowledge', isTrue)
              .having((e) => e.balanceKobo, 'balanceKobo', -100 * _loadPrice),
        ),
      );

      // Acknowledged, it goes through — and the debt is NOT cleared by it.
      await db.vanTripsDao.assertDriverOffboardable(
        driverId,
        driverName: 'Driver Dan',
        acknowledgedBalance: true,
      );
      expect(
        await db.driverLedgerDao.getBalanceKobo(driverId),
        -100 * _loadPrice,
      );
    });

    test('a driver CANNOT acknowledge their own debt away (self-resign)',
        () async {
      await stockWithBatch(warehouseId, 200);
      final tripId = await loadVan(van: vanA, qty: 100);
      await db.vanTripsDao.closeTrip(tripId: tripId, performedBy: managerId);

      await expectLater(
        db.vanTripsDao.assertDriverOffboardable(
          driverId,
          driverName: 'Driver Dan',
          acknowledgedBalance: true, // ignored on the self-service path
          selfService: true,
        ),
        throwsA(
          isA<DriverOffboardingBlockedException>()
              .having((e) => e.canAcknowledge, 'canAcknowledge', isFalse)
              .having((e) => e.message, 'message', contains('You still owe')),
        ),
      );
    });

    test('a settled-then-written-off driver may leave', () async {
      await stockWithBatch(warehouseId, 200);
      final tripId = await loadVan(van: vanA, qty: 100);
      await db.vanTripsDao.postWriteOff(
        tripId: tripId,
        type: kDriverLedgerTypeShortageWriteoff,
        amountKobo: 100 * _loadPrice,
        performedBy: managerId,
        reason: 'goodwill',
      );
      await db.vanTripsDao.closeTrip(tripId: tripId, performedBy: managerId);

      final check = await db.vanTripsDao.checkDriverOffboarding(driverId);
      expect(check.balanceKobo, 0);
      expect(check.isClear, isTrue);
    });
  });

  // ── Balance and history, across trips ─────────────────────────────────────

  group('cross-trip balance and history', () {
    test('the balance is the running sum of every trip, and the history '
        'explains it line by line', () async {
      await stockWithBatch(warehouseId, 400);

      // Trip 1 — load 100, return 40 good, remit ₦300,000, close.
      final t1 = await loadVan(van: vanA, qty: 100);
      await db.vanTripsDao.recordReturn(
        tripId: t1,
        lines: [
          VanReturnLine(
            productId: productId,
            quantity: 40,
            condition: kVanReturnConditionGood,
          ),
        ],
        performedBy: managerId,
      );
      await db.vanTripsDao.recordDriverPayment(
        tripId: t1,
        amountKobo: 30000000,
        method: 'cash',
        performedBy: managerId,
      );
      await db.vanTripsDao.closeTrip(tripId: t1, performedBy: managerId);

      // Trip 2 — a DIFFERENT van, load 50, remit ₦100,000, still open.
      final t2 = await loadVan(van: vanB, qty: 50);
      await db.vanTripsDao.recordDriverPayment(
        tripId: t2,
        amountKobo: 10000000,
        method: 'transfer',
        performedBy: managerId,
      );

      const expected =
          -(100 * _loadPrice) + (40 * _loadPrice) + 30000000 // trip 1
          -
          (50 * _loadPrice) +
          10000000; // trip 2

      final balance = await db.driverLedgerDao.getBalanceKobo(driverId);
      expect(balance, expected);

      // The history is the SAME number, one row at a time — which is the whole
      // point of showing it: a balance nobody can reconstruct is a rumour.
      final history = await db.driverLedgerDao.watchHistory(driverId).first;
      expect(
        history.fold<int>(0, (sum, e) => sum + e.signedAmountKobo),
        balance,
      );
      // Both trips, every event type, on one axis.
      expect(history.map((e) => e.tripId).toSet(), {t1, t2});
      expect(history.map((e) => e.type).toSet(), {
        kDriverLedgerTypeLoad,
        kDriverLedgerTypeReturnGood,
        kDriverLedgerTypePaymentCash,
        kDriverLedgerTypePaymentTransfer,
      });
      // Newest first.
      for (var i = 1; i < history.length; i++) {
        expect(
          history[i - 1].createdAt.isBefore(history[i].createdAt),
          isFalse,
        );
      }
    });

    test('a residual from a closed trip carries onto the driver, not the run',
        () async {
      await stockWithBatch(warehouseId, 400);
      final t1 = await loadVan(van: vanA, qty: 100);
      await ringSale(storeId: vanA, qty: 100);
      await db.vanTripsDao.closeTrip(tripId: t1, performedBy: managerId);

      // The TRIP's own net and the DRIVER's balance are the same here…
      expect(await db.driverLedgerDao.getTripBalanceKobo(t1), -115000000);
      expect(await db.driverLedgerDao.getBalanceKobo(driverId), -115000000);

      // …until a second run makes them diverge. The profile shows the driver's.
      final t2 = await loadVan(van: vanB, qty: 20);
      expect(await db.driverLedgerDao.getTripBalanceKobo(t2), -23000000);
      expect(await db.driverLedgerDao.getBalanceKobo(driverId), -138000000);
    });
  });

  // ── Trips tab ─────────────────────────────────────────────────────────────

  group('trips tab', () {
    test('trips are ordered by OPENING date, newest first', () async {
      await stockWithBatch(warehouseId, 400);
      final old = await loadVan(
        van: vanA,
        qty: 10,
        at: DateTime(2026, 1, 5, 8),
      );
      await db.vanTripsDao.closeTrip(tripId: old, performedBy: managerId);
      final recent = await loadVan(
        van: vanA,
        qty: 10,
        at: DateTime(2026, 3, 9, 8),
      );

      final trips = await db.vanTripsDao.watchTripsForDriver(driverId).first;
      expect(trips.map((t) => t.id), [recent, old]);
    });

    test('another driver\'s trips never appear', () async {
      final otherDriver = UuidV7.generate();
      await db
          .into(db.users)
          .insert(
            UsersCompanion.insert(
              id: Value(otherDriver),
              businessId: businessId,
              name: 'Other Olu',
              pin: '2222',
            ),
          );
      await stockWithBatch(warehouseId, 400);
      final mine = await loadVan(van: vanA, qty: 10);
      await db.vanTripsDao.dispatchLoad(
        vanStoreId: vanB,
        driverUserId: otherDriver,
        sourceStoreId: warehouseId,
        lines: [
          VanLoadLine(
            productId: productId,
            quantity: 10,
            loadPriceKobo: _loadPrice,
          ),
        ],
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
      );

      final trips = await db.vanTripsDao.watchTripsForDriver(driverId).first;
      expect(trips.map((t) => t.id), [mine]);
    });

    test('a row carries closed-with-balance and restated on the trip itself',
        () async {
      await stockWithBatch(warehouseId, 400);
      final tripId = await loadVan(van: vanA, qty: 100);
      // Close with a residual: nothing sold, nothing returned, nothing remitted.
      await db.vanTripsDao.closeTrip(tripId: tripId, performedBy: managerId);

      var trips = await db.vanTripsDao.watchTripsForDriver(driverId).first;
      expect(trips.single.status, kVanTripStatusClosed);
      expect(trips.single.closedWithBalance, isTrue);
      expect(trips.single.restatedAt, isNull);
      // The net the row shows for a closed trip is the persisted artifact.
      expect(trips.single.profitKobo, trips.single.recoveredKobo - trips.single.cogsKobo);

      // A road sale the driver's device only syncs after close (spec §9.4 #15)
      // — it arrives as a pulled row, not as a local checkout, so it is
      // inserted the way a pull would.
      final lateId = UuidV7.generate();
      const lateTotal = 10 * _loadPrice;
      await db
          .into(db.orders)
          .insert(
            OrdersCompanion.insert(
              id: Value(lateId),
              businessId: businessId,
              orderNumber: 'ORD-LATE',
              totalAmountKobo: lateTotal,
              netAmountKobo: lateTotal,
              amountPaidKobo: const Value(lateTotal),
              paymentType: 'cash',
              status: 'pending',
              storeId: Value(vanA),
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
              storeId: vanA,
              quantity: 10,
              unitPriceKobo: _loadPrice,
              totalKobo: lateTotal,
            ),
          );

      final drift = await db.vanTripsDao.restateClosedTrip(tripId);
      expect(drift, isNot(0));

      trips = await db.vanTripsDao.watchTripsForDriver(driverId).first;
      expect(trips.single.restatedAt, isNotNull);
      expect(trips.single.restatedReason, isNotNull);
    });

    test('an OPEN trip has no artifact, so the row shows the live position',
        () async {
      await stockWithBatch(warehouseId, 400);
      final tripId = await loadVan(van: vanA, qty: 100);

      final trips = await db.vanTripsDao.watchTripsForDriver(driverId).first;
      expect(trips.single.status, kVanTripStatusOpen);
      expect(trips.single.profitKobo, 0);
      expect(trips.single.closedAt, isNull);

      final position = await db.vanTripsDao.positionForTrip(tripId);
      expect(position.outstandingKobo, 100 * _loadPrice);
      expect(position.outstandingKobo, -position.balanceKobo);
    });
  });

  // ── Sales tab ─────────────────────────────────────────────────────────────

  group('sales tab', () {
    test('every road sale across every trip, with its lines, newest first',
        () async {
      await stockWithBatch(warehouseId, 400);
      final t1 = await loadVan(van: vanA, qty: 100);
      final first = await ringSale(storeId: vanA, qty: 5);
      final second = await ringSale(storeId: vanA, qty: 7);
      await db.vanTripsDao.closeTrip(tripId: t1, performedBy: managerId);
      await loadVan(van: vanB, qty: 50);
      final third = await ringSale(storeId: vanB, qty: 3);

      final sales = await db.vanTripsDao
          .watchSalesWithItemsForDriver(driverId)
          .first;
      expect(sales.map((s) => s.order.id).toSet(), {first, second, third});
      // Newest first.
      expect(sales.first.order.id, third);
      // Lines came along, so a row can open its receipt without a second read.
      expect(sales.every((s) => s.items.isNotEmpty), isTrue);
      expect(
        sales.firstWhere((s) => s.order.id == second).items.single.item.quantity,
        7,
      );
      // The road is walk-in only — no customer to join (spec §16).
      expect(sales.every((s) => s.customer == null), isTrue);
    });

    test('an ordinary shop sale is never in a driver\'s van sales', () async {
      await stockWithBatch(warehouseId, 400);
      await loadVan(van: vanA, qty: 10);
      await stockWithBatch(warehouseId, 50);
      await ringSale(storeId: warehouseId, qty: 2); // a shop till sale

      final sales = await db.vanTripsDao
          .watchSalesWithItemsForDriver(driverId)
          .first;
      expect(sales, isEmpty);
    });
  });

  // ── Crate tab (§11) ───────────────────────────────────────────────────────

  group('crate tab', () {
    test('shells out / back come off the trip memo columns, open or closed, '
        'and agree with the position', () async {
      await stockWithBatch(warehouseId, 400);

      // An OPEN trip: 100 shells out, 65 back.
      final open = await loadVan(van: vanA, qty: 100, shellsOut: 100);
      await db.vanTripsDao.recordReturn(
        tripId: open,
        lines: [
          VanReturnLine(
            productId: productId,
            quantity: 40,
            condition: kVanReturnConditionGood,
            shellsBack: 65,
          ),
        ],
        performedBy: managerId,
      );

      var trips = await db.vanTripsDao.watchTripsForDriver(driverId).first;
      var row = trips.firstWhere((t) => t.id == open);
      expect(row.status, kVanTripStatusOpen);
      expect(row.shellsOut, 100);
      expect(row.shellsBack, 65);
      expect(row.shellsOut - row.shellsBack, 35);

      // The reconcile screen's position reads the SAME two columns, so the two
      // surfaces cannot disagree.
      final position = await db.vanTripsDao.positionForTrip(open);
      expect(position.shellsOut, row.shellsOut);
      expect(position.shellsBack, row.shellsBack);
      expect(position.shellsDifference, 35);

      // Now CLOSE it: the memo survives on the trip row unchanged.
      await db.vanTripsDao.closeTrip(tripId: open, performedBy: managerId);
      trips = await db.vanTripsDao.watchTripsForDriver(driverId).first;
      row = trips.firstWhere((t) => t.id == open);
      expect(row.status, kVanTripStatusClosed);
      expect(row.shellsOut, 100);
      expect(row.shellsBack, 65);
    });

    test('a restock ACCUMULATES shells rather than restating the run',
        () async {
      await stockWithBatch(warehouseId, 400);
      final tripId = await loadVan(van: vanA, qty: 50, shellsOut: 50);
      await db.vanTripsDao.restockTrip(
        tripId: tripId,
        lines: [
          VanLoadLine(
            productId: productId,
            quantity: 30,
            loadPriceKobo: _loadPrice,
            shellsOut: 30,
          ),
        ],
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
      );

      final trips = await db.vanTripsDao.watchTripsForDriver(driverId).first;
      expect(trips.single.shellsOut, 80);
      expect(trips.single.shellsBack, 0);
    });

    test('the memo is COUNTS only — no crate ledger, no deposit money',
        () async {
      await stockWithBatch(warehouseId, 400);
      final tripId = await loadVan(van: vanA, qty: 100, shellsOut: 100);
      await db.vanTripsDao.recordReturn(
        tripId: tripId,
        lines: [
          VanReturnLine(
            productId: productId,
            quantity: 100,
            condition: kVanReturnConditionGood,
            shellsBack: 60,
          ),
        ],
        performedBy: managerId,
      );

      // 40 shells never came back. The driver is SETTLED all the same — v1
      // states the loss and deliberately does not value it (spec §11).
      expect(await db.driverLedgerDao.getBalanceKobo(driverId), 0);
      expect(await db.select(db.crateLedger).get(), isEmpty);
    });
  });

  // ── The period selector ───────────────────────────────────────────────────

  group('period scoping', () {
    test('the period filters the HISTORY and leaves the balance alone',
        () async {
      await stockWithBatch(warehouseId, 400);

      // A trip from a year ago, and one from today.
      final oldTrip = await loadVan(
        van: vanA,
        qty: 30,
        at: DateTime.now().subtract(const Duration(days: 400)),
      );
      await db.vanTripsDao.closeTrip(
        tripId: oldTrip,
        performedBy: managerId,
      );
      final todayTrip = await loadVan(van: vanB, qty: 10);

      final trips = await db.vanTripsDao.watchTripsForDriver(driverId).first;
      expect(trips.length, 2);

      // Filtered by OPENING date, the way the Trips tab does it.
      final thisMonth = [
        for (final t in trips)
          if (isDateInPeriod(t.openedAt, 'This Month')) t,
      ];
      expect(thisMonth.map((t) => t.id), [todayTrip]);

      final toDate = [
        for (final t in trips)
          if (isDateInPeriod(t.openedAt, 'To Date')) t,
      ];
      expect(toDate.length, 2);

      // The ledger filters on activity_date, same rule.
      final history = await db.driverLedgerDao.watchHistory(driverId).first;
      final periodLedger = [
        for (final e in history)
          if (isDateInPeriod(e.activityDate, 'This Month')) e,
      ];
      expect(periodLedger.length, 1);
      expect(periodLedger.single.tripId, todayTrip);

      // …and the BALANCE is the whole story regardless. A period sum would be
      // -₦115,000 here; the driver actually owes both loads.
      expect(
        periodLedger.fold<int>(0, (s, e) => s + e.signedAmountKobo),
        -10 * _loadPrice,
      );
      expect(
        await db.driverLedgerDao.getBalanceKobo(driverId),
        -40 * _loadPrice,
      );
    });
  });
}
