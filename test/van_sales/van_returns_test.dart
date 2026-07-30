// van_returns_test.dart
//
// #143 (PRD #139 / ADR 0019, van-sales spec §4.5, §5.2, §5.5, §7.3, §9.3) —
// restocks and returns: the mid-run half of a trip.
//
// The assertions here are about the SEAMS the return crosses, because that is
// where this slice can silently lose money:
//
//   · a good return has to put COST back, not just quantity — ADR 0019 decision
//     1. If the units re-enter the warehouse with no cost batch, their next sale
//     books zero COGS and the margin on that sale is pure fiction. So the tests
//     assert end-to-end THROUGH drawDownSale, not just that a batch row exists.
//   · a return spanning two lots must create one batch PER SEGMENT at each
//     segment's own cost. A blended average would be invisible at the total and
//     wrong on every subsequent partial sale.
//   · a damaged return must book the loss at the SNAPSHOTTED cost. The van store
//     deliberately holds no cost batches, so the naive path books 0 and the loss
//     vanishes.
//   · the cursor and the over-return block are what make the forced physical
//     count (spec §7.3) a control rather than a formality.
//
// In-memory Drift via bootstrapTestDb(); same style as van_dispatch_test.dart.

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
            retailerPriceKobo: const Value(1150000),
          ),
        );
  });

  tearDown(() async => db.close());

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
    final row =
        await (db.select(db.inventory)..where(
              (t) =>
                  t.productId.equals(product ?? productId) &
                  t.storeId.equals(store) &
                  t.businessId.equals(businessId),
            ))
            .getSingleOrNull();
    return row?.quantity ?? 0;
  }

  Future<List<CostBatchData>> queue(String store, {String? product}) {
    return db.costBatchesDao.queueFor(product ?? productId, store);
  }

  Future<List<DriverLedgerEntryData>> ledgerRows() {
    return (db.select(db.driverLedgerEntries)
          ..orderBy([(t) => OrderingTerm(expression: t.createdAt)]))
        .get();
  }

  /// Loads [qty] onto a fresh trip at [loadPriceKobo], returning the trip id.
  Future<String> loadVan({
    required int qty,
    required int loadPriceKobo,
    String? product,
  }) async {
    final r = await db.vanTripsDao.dispatchLoad(
      vanStoreId: vanId,
      driverUserId: driverId,
      sourceStoreId: warehouseId,
      performedBy: managerId,
      dispatchEventId: UuidV7.generate(),
      lines: [
        VanLoadLine(
          productId: product ?? productId,
          quantity: qty,
          loadPriceKobo: loadPriceKobo,
        ),
      ],
    );
    return r.tripId;
  }

  // ═══ Good returns: FIFO credit + re-batch at snapshot cost ═══════════════

  group('good return — credit at the oldest lot, re-batch at its cost', () {
    test('credits at the load price, restores sellable warehouse stock, and '
        'creates a warehouse batch at the LOT\'s snapshotted cost', () async {
      // The spec §6.3 worked trip: 200 @ ₦10,000 cost, load 100 @ ₦11,500.
      await stockWithBatch(warehouseId, 200, 1000000);
      final tripId = await loadVan(qty: 100, loadPriceKobo: 1150000);
      expect(await db.driverLedgerDao.getBalanceKobo(driverId), -115000000);
      // The warehouse queue was drawn down by the load: 100 left.
      expect(await onHand(warehouseId), 100);

      final result = await db.vanTripsDao.recordReturn(
        tripId: tripId,
        performedBy: managerId,
        lines: [
          VanReturnLine(
            productId: productId,
            quantity: 45,
            condition: kVanReturnConditionGood,
            shellsBack: 45,
          ),
        ],
      );

      // 1. The credit is 45 × the load price, not the retail tier or the cost.
      expect(result.totalCreditKobo, 45 * 1150000);
      expect(
        await db.driverLedgerDao.getBalanceKobo(driverId),
        -115000000 + 45 * 1150000,
      );

      // 2. The goods are physically back in the warehouse and off the van.
      expect(await onHand(warehouseId), 145);
      expect(await onHand(vanId), 55);

      // 3. THE POINT: they carry the cost they left with. One new batch, at the
      //    lot's snapshot — not at 0, and not at today's scalar.
      final batches = await queue(warehouseId);
      final returned = batches.where((b) => b.qtyRemaining == 45).toList();
      expect(returned, hasLength(1));
      expect(returned.single.costKobo, 1000000);

      // 4. The cursor moved, so the same units cannot be returned twice.
      final lot = (await db.vanTripsDao.lotsForTrip(tripId)).single;
      expect(lot.quantity, 100, reason: 'the lot itself is immutable');
      expect(lot.qtyRemaining, 55);

      // 5. The event row carries BOTH money legs, snapshotted.
      final events = await db.vanTripsDao.returnsForTrip(tripId);
      expect(events, hasLength(1));
      expect(events.single.condition, kVanReturnConditionGood);
      expect(events.single.quantity, 45);
      expect(events.single.creditKobo, 45 * 1150000);
      expect(events.single.costKobo, 45 * 1000000);
      expect(events.single.shellsBack, 45);
      expect(events.single.recordedBy, managerId);
      // The write-only crate seam is untouched by v1 UI — NULL, not 0.
      expect(events.single.crateShells, isNull);

      // 6. The shell memo rolled onto the trip (counting only).
      expect((await db.vanTripsDao.getTrip(tripId))!.shellsBack, 45);
    });

    test('SELLING the returned units afterwards books REAL COGS, not zero '
        '(the whole reason the re-batch exists)', () async {
      // Warehouse holds exactly what it loaded — after the load it is EMPTY, so
      // any later sale can only draw from the batch the return created.
      await stockWithBatch(warehouseId, 100, 1000000);
      final tripId = await loadVan(qty: 100, loadPriceKobo: 1150000);
      expect(await queue(warehouseId), isEmpty, reason: 'load drained it');

      await db.vanTripsDao.recordReturn(
        tripId: tripId,
        performedBy: managerId,
        lines: [
          VanReturnLine(
            productId: productId,
            quantity: 40,
            condition: kVanReturnConditionGood,
          ),
        ],
      );

      // Sell 10 of the returned units out of the warehouse.
      final cogs = await db.costBatchesDao.drawDownSale([
        SaleCostLine(
          index: 0,
          productId: productId,
          storeId: warehouseId,
          quantity: 10,
        ),
      ]);

      expect(
        cogs[0],
        1000000,
        reason: 'without the re-batch this line would cost 0 and show pure '
            'margin — the exact break ADR 0019 decision 1 closes',
      );
    });

    test('a return spanning TWO lots at different costs creates one batch PER '
        'SEGMENT at each segment\'s own cost — never a blend', () async {
      // Two warehouse layers so the two loads snapshot different costs.
      final older = DateTime(2026, 1, 1);
      final newer = DateTime(2026, 2, 1);
      await stockWithBatch(warehouseId, 60, 1000, receivedAt: older);
      await stockWithBatch(warehouseId, 60, 3000, receivedAt: newer);

      // Lot A: 60 @ cost 1,000, load price 5,000.
      final tripId = await loadVan(qty: 60, loadPriceKobo: 5000);
      // Lot B (restock): 60 @ cost 3,000, load price 8,000.
      await db.vanTripsDao.restockTrip(
        tripId: tripId,
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
        lines: [
          VanLoadLine(productId: productId, quantity: 60, loadPriceKobo: 8000),
        ],
      );
      expect(await queue(warehouseId), isEmpty);

      // Return 80: 60 from lot A + 20 from lot B.
      final result = await db.vanTripsDao.recordReturn(
        tripId: tripId,
        performedBy: managerId,
        lines: [
          VanReturnLine(
            productId: productId,
            quantity: 80,
            condition: kVanReturnConditionGood,
          ),
        ],
      );

      // Two segments, each at its OWN figures.
      expect(result.consumed, hasLength(2));
      expect(result.consumed[0].quantity, 60);
      expect(result.consumed[0].unitCostKobo, 1000);
      expect(result.consumed[0].loadPriceKobo, 5000);
      expect(result.consumed[1].quantity, 20);
      expect(result.consumed[1].unitCostKobo, 3000);
      expect(result.consumed[1].loadPriceKobo, 8000);

      // The credit is the per-segment sum, oldest first.
      expect(result.totalCreditKobo, 60 * 5000 + 20 * 8000);

      // TWO batches, asserted INDIVIDUALLY — a blended average would total the
      // same (60×1,000 + 20×3,000 = 120,000) while pricing every later partial
      // sale wrong.
      final batches = await queue(warehouseId)
        ..sort((a, b) => a.costKobo.compareTo(b.costKobo));
      expect(batches, hasLength(2));
      expect(batches[0].qtyRemaining, 60);
      expect(batches[0].costKobo, 1000);
      expect(batches[1].qtyRemaining, 20);
      expect(batches[1].costKobo, 3000);

      // And the cursor drained the OLD lot first.
      final lots = await db.vanTripsDao.lotsForTrip(tripId);
      expect(lots[0].qtyRemaining, 0);
      expect(lots[1].qtyRemaining, 40);
    });

    test('an item loaded at two prices credits at the OLDEST lot\'s price '
        'first (spec §9.3 #10)', () async {
      await stockWithBatch(warehouseId, 200, 1000);
      final tripId = await loadVan(qty: 50, loadPriceKobo: 5000);
      await db.vanTripsDao.restockTrip(
        tripId: tripId,
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
        lines: [
          // A restock at a HIGHER price. A "latest price wins" rule would credit
          // 30 × 9,000; FIFO credits 30 × 5,000.
          VanLoadLine(productId: productId, quantity: 50, loadPriceKobo: 9000),
        ],
      );

      final r = await db.vanTripsDao.recordReturn(
        tripId: tripId,
        performedBy: managerId,
        lines: [
          VanReturnLine(
            productId: productId,
            quantity: 30,
            condition: kVanReturnConditionGood,
          ),
        ],
      );

      expect(r.totalCreditKobo, 30 * 5000);
      expect(r.consumed, hasLength(1));
      expect(r.consumed.single.loadPriceKobo, 5000);
    });

    test('the ledger credit is typed return_good, references the EVENT, and is '
        'signed positive', () async {
      await stockWithBatch(warehouseId, 100, 1000);
      final tripId = await loadVan(qty: 20, loadPriceKobo: 5000);

      final r = await db.vanTripsDao.recordReturn(
        tripId: tripId,
        performedBy: managerId,
        lines: [
          VanReturnLine(
            productId: productId,
            quantity: 5,
            condition: kVanReturnConditionGood,
          ),
        ],
      );

      final credit = (await ledgerRows()).last;
      expect(credit.type, kDriverLedgerTypeReturnGood);
      expect(credit.referenceType, kDriverLedgerRefReturn);
      expect(credit.referenceId, r.events.single.id);
      expect(credit.tripId, tripId);
      expect(credit.amountKobo, 25000);
      expect(credit.signedAmountKobo, 25000, reason: 'a return is a CREDIT');
      expect(credit.performedBy, managerId);
    });

    test('an UNCOSTED lot returns as an uncosted batch — 0, never invented',
        () async {
      await stockWithBatch(warehouseId, 100, 0);
      final tripId = await loadVan(qty: 40, loadPriceKobo: 900000);

      await db.vanTripsDao.recordReturn(
        tripId: tripId,
        performedBy: managerId,
        lines: [
          VanReturnLine(
            productId: productId,
            quantity: 10,
            condition: kVanReturnConditionGood,
          ),
        ],
      );

      // The load left 60 uncosted units behind; the return adds a SECOND layer
      // of 10, also uncosted. Neither invents a cost from the product scalar.
      final batches = await queue(warehouseId);
      expect(batches, hasLength(2));
      expect(batches.map((b) => b.qtyRemaining), [60, 10]);
      expect(batches.every((b) => b.costKobo == 0), isTrue);
      expect((await db.vanTripsDao.returnsForTrip(tripId)).single.costKobo, 0);
    });
  });

  // ═══ Damaged returns (spec §5.5) ═════════════════════════════════════════

  group('damaged return — no credit, loss at SNAPSHOTTED cost', () {
    test('posts no credit, never re-enters sellable stock, and books the loss '
        'at cost rather than load price', () async {
      // Cost ₦10,000, load price ₦11,500 — the two are deliberately different
      // so booking the wrong one is visible.
      await stockWithBatch(warehouseId, 100, 1000000);
      final tripId = await loadVan(qty: 100, loadPriceKobo: 1150000);
      final balanceBefore = await db.driverLedgerDao.getBalanceKobo(driverId);
      final ledgerBefore = (await ledgerRows()).length;

      final r = await db.vanTripsDao.recordReturn(
        tripId: tripId,
        performedBy: managerId,
        lines: [
          VanReturnLine(
            productId: productId,
            quantity: 3,
            condition: kVanReturnConditionDamaged,
          ),
        ],
      );

      // 1. NO credit, and the driver's balance does not move: they still owe.
      expect(r.totalCreditKobo, 0);
      expect(r.events.single.creditKobo, 0);
      expect(await db.driverLedgerDao.getBalanceKobo(driverId), balanceBefore);
      expect(
        (await ledgerRows()).length,
        ledgerBefore,
        reason: 'a damaged return writes NO driver-ledger row at all',
      );

      // 2. The units left the van and did NOT arrive at the warehouse.
      expect(await onHand(vanId), 97);
      expect(await onHand(warehouseId), 0);
      // …and created no sellable cost batch there either.
      expect(await queue(warehouseId), isEmpty);

      // 3. The loss is booked at the SNAPSHOTTED COST (3 × ₦10,000 = ₦30,000),
      //    not at load price (which would be ₦34,500 and overstate it by the
      //    margin the business never earned).
      expect(r.events.single.costKobo, 3 * 1000000);
      final adj =
          await (db.select(db.stockAdjustments)
                ..where((a) => a.reason.equals(kVanReturnDamageReason)))
              .get();
      expect(adj, hasLength(1));
      expect(adj.single.storeId, vanId);
      expect(adj.single.quantityDiff, -3);
      expect(
        adj.single.valueKobo,
        3 * 1000000,
        reason: 'load price (₦34,500) would overstate the loss — spec §5.5',
      );
      expect(adj.single.unitCostKobo, 1000000);
    });

    test('the loss is NOT drawn from the van store\'s (empty) cost queue — a '
        'naive draw-down would book it at 0', () async {
      await stockWithBatch(warehouseId, 50, 700000);
      final tripId = await loadVan(qty: 20, loadPriceKobo: 900000);
      // The van holds goods and, by design, no cost batches at all (ADR 0019).
      expect(await queue(vanId), isEmpty);

      await db.vanTripsDao.recordReturn(
        tripId: tripId,
        performedBy: managerId,
        lines: [
          VanReturnLine(
            productId: productId,
            quantity: 4,
            condition: kVanReturnConditionDamaged,
          ),
        ],
      );

      final adj =
          await (db.select(db.stockAdjustments)
                ..where((a) => a.reason.equals(kVanReturnDamageReason)))
              .getSingle();
      expect(adj.valueKobo, 4 * 700000);
      expect(adj.valueKobo, isNot(0));
    });

    test('damaged units still draw the cursor, so they cannot come back a '
        'second time as "good"', () async {
      await stockWithBatch(warehouseId, 100, 1000);
      final tripId = await loadVan(qty: 10, loadPriceKobo: 5000);

      await db.vanTripsDao.recordReturn(
        tripId: tripId,
        performedBy: managerId,
        lines: [
          VanReturnLine(
            productId: productId,
            quantity: 10,
            condition: kVanReturnConditionDamaged,
          ),
        ],
      );
      expect((await db.vanTripsDao.lotsForTrip(tripId)).single.qtyRemaining, 0);

      await expectLater(
        db.vanTripsDao.recordReturn(
          tripId: tripId,
          performedBy: managerId,
          lines: [
            VanReturnLine(
              productId: productId,
              quantity: 1,
              condition: kVanReturnConditionGood,
            ),
          ],
        ),
        throwsA(isA<VanOverReturnException>()),
      );
      expect(await db.driverLedgerDao.getBalanceKobo(driverId), -50000);
    });

    test('a mixed return in ONE call keeps the two conditions apart', () async {
      await stockWithBatch(warehouseId, 100, 1000000);
      final tripId = await loadVan(qty: 100, loadPriceKobo: 1150000);

      final r = await db.vanTripsDao.recordReturn(
        tripId: tripId,
        performedBy: managerId,
        lines: [
          VanReturnLine(
            productId: productId,
            quantity: 45,
            condition: kVanReturnConditionGood,
          ),
          VanReturnLine(
            productId: productId,
            quantity: 3,
            condition: kVanReturnConditionDamaged,
          ),
        ],
      );

      expect(r.events, hasLength(2));
      expect(r.totalCreditKobo, 45 * 1150000, reason: 'good units only');
      expect(r.totalCostKobo, 48 * 1000000, reason: 'both draw a cost basis');
      expect(await onHand(warehouseId), 45, reason: 'damaged never arrive');
      expect(await onHand(vanId), 52);

      final totals = await db.vanTripsDao.returnTotalsForTrip(tripId);
      expect(totals.goodUnits, 45);
      expect(totals.goodCreditKobo, 45 * 1150000);
      expect(totals.goodCostKobo, 45 * 1000000);
      expect(totals.damagedUnits, 3);
      expect(totals.damagedCostKobo, 3 * 1000000);
    });
  });

  // ═══ Forced physical count + the over-return block (§7.3 / §9.3 #11) ═════

  group('forced physical count', () {
    test('returning MORE than is still out is rejected and nothing is written',
        () async {
      await stockWithBatch(warehouseId, 100, 1000);
      final tripId = await loadVan(qty: 20, loadPriceKobo: 5000);

      await expectLater(
        db.vanTripsDao.recordReturn(
          tripId: tripId,
          performedBy: managerId,
          lines: [
            VanReturnLine(
              productId: productId,
              quantity: 21,
              condition: kVanReturnConditionGood,
            ),
          ],
        ),
        throwsA(
          isA<VanOverReturnException>()
              .having((e) => e.requested, 'requested', 21)
              .having((e) => e.stillOut, 'stillOut', 20)
              .having((e) => e.message, 'message', contains('cannot return')),
        ),
      );

      // Nothing leaked: no event, no credit, no stock move, no cursor movement.
      expect(await db.vanTripsDao.returnsForTrip(tripId), isEmpty);
      expect(await db.driverLedgerDao.getBalanceKobo(driverId), -100000);
      expect(await onHand(vanId), 20);
      expect(await onHand(warehouseId), 80);
      expect((await db.vanTripsDao.lotsForTrip(tripId)).single.qtyRemaining, 20);
    });

    test('over-returning a SECOND time (after a partial return) is rejected on '
        'the remaining cursor, not the original load', () async {
      await stockWithBatch(warehouseId, 100, 1000);
      final tripId = await loadVan(qty: 20, loadPriceKobo: 5000);
      await db.vanTripsDao.recordReturn(
        tripId: tripId,
        performedBy: managerId,
        lines: [
          VanReturnLine(
            productId: productId,
            quantity: 15,
            condition: kVanReturnConditionGood,
          ),
        ],
      );

      await expectLater(
        db.vanTripsDao.recordReturn(
          tripId: tripId,
          performedBy: managerId,
          lines: [
            VanReturnLine(
              productId: productId,
              quantity: 6,
              condition: kVanReturnConditionGood,
            ),
          ],
        ),
        throwsA(
          isA<VanOverReturnException>().having((e) => e.stillOut, 'stillOut', 5),
        ),
      );
    });

    test('returning a product that never went out is rejected', () async {
      final other = UuidV7.generate();
      await db
          .into(db.products)
          .insert(
            ProductsCompanion.insert(
              id: Value(other),
              businessId: businessId,
              name: 'Gulder 60cl',
            ),
          );
      await stockWithBatch(warehouseId, 100, 1000);
      final tripId = await loadVan(qty: 10, loadPriceKobo: 5000);

      await expectLater(
        db.vanTripsDao.recordReturn(
          tripId: tripId,
          performedBy: managerId,
          lines: [
            VanReturnLine(
              productId: other,
              quantity: 1,
              condition: kVanReturnConditionGood,
            ),
          ],
        ),
        throwsA(
          isA<VanOverReturnException>().having((e) => e.stillOut, 'stillOut', 0),
        ),
      );
    });

    test('the DAO exposes no system-suggested quantity — the only read is a '
        'documented CEILING, and the form never consults it', () async {
      await stockWithBatch(warehouseId, 100, 1000);
      final tripId = await loadVan(qty: 30, loadPriceKobo: 5000);

      // `unitsStillOutForTrip` exists purely so the block above can say by how
      // much a count is wrong. It is deliberately NOT a "return everything"
      // helper: nothing returns a pre-filled VanReturnLine, and there is no
      // `returnAllRemaining`-style call on the DAO at all.
      final ceiling = await db.vanTripsDao.unitsStillOutForTrip(tripId);
      expect(ceiling[productId], 30);

      // Recording is only ever driven by a typed count.
      await db.vanTripsDao.recordReturn(
        tripId: tripId,
        performedBy: managerId,
        lines: [
          VanReturnLine(
            productId: productId,
            quantity: 7,
            condition: kVanReturnConditionGood,
          ),
        ],
      );
      expect(
        (await db.vanTripsDao.unitsStillOutForTrip(tripId))[productId],
        23,
      );
    });

    test('a return against a CLOSED trip is refused (spec §9.3 #13)', () async {
      await stockWithBatch(warehouseId, 100, 1000);
      final tripId = await loadVan(qty: 10, loadPriceKobo: 5000);
      await (db.update(db.vanTrips)..where((t) => t.id.equals(tripId))).write(
        VanTripsCompanion(
          status: const Value(kVanTripStatusClosed),
          closedAt: Value(DateTime.now()),
        ),
      );

      await expectLater(
        db.vanTripsDao.recordReturn(
          tripId: tripId,
          performedBy: managerId,
          lines: [
            VanReturnLine(
              productId: productId,
              quantity: 1,
              condition: kVanReturnConditionGood,
            ),
          ],
        ),
        throwsA(isA<VanTripNotOpenException>()),
      );
    });

    test('an empty / degenerate return and an unknown condition are refused',
        () async {
      await stockWithBatch(warehouseId, 100, 1000);
      final tripId = await loadVan(qty: 10, loadPriceKobo: 5000);

      await expectLater(
        db.vanTripsDao.recordReturn(
          tripId: tripId,
          performedBy: managerId,
          lines: const [],
        ),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        db.vanTripsDao.recordReturn(
          tripId: tripId,
          performedBy: managerId,
          lines: [
            VanReturnLine(
              productId: productId,
              quantity: 0,
              condition: kVanReturnConditionGood,
            ),
          ],
        ),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        db.vanTripsDao.recordReturn(
          tripId: tripId,
          performedBy: managerId,
          lines: [
            VanReturnLine(
              productId: productId,
              quantity: 1,
              condition: 'wet',
            ),
          ],
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(await db.vanTripsDao.returnsForTrip(tripId), isEmpty);
    });

    test('a return is idempotent on the line ids the caller minted', () async {
      await stockWithBatch(warehouseId, 100, 1000);
      final tripId = await loadVan(qty: 20, loadPriceKobo: 5000);
      final eventId = UuidV7.generate();
      final lines = [
        VanReturnLine(
          productId: productId,
          quantity: 5,
          condition: kVanReturnConditionGood,
          eventId: eventId,
        ),
      ];

      final first = await db.vanTripsDao.recordReturn(
        tripId: tripId,
        performedBy: managerId,
        lines: lines,
      );
      expect(first.alreadyApplied, isFalse);

      final second = await db.vanTripsDao.recordReturn(
        tripId: tripId,
        performedBy: managerId,
        lines: lines,
      );
      expect(second.alreadyApplied, isTrue);

      // ONE credit, one event, one cursor move — the double-tap changed nothing.
      expect(await db.vanTripsDao.returnsForTrip(tripId), hasLength(1));
      expect(await db.driverLedgerDao.getBalanceKobo(driverId), -75000);
      expect((await db.vanTripsDao.lotsForTrip(tripId)).single.qtyRemaining, 15);
      expect(await onHand(warehouseId), 85);
    });
  });

  // ═══ Restock (the same dispatch, onto an open trip) ══════════════════════

  group('restock', () {
    test('creates a NEW priced lot, moves stock, debits the driver, and is its '
        'own dated event', () async {
      await stockWithBatch(warehouseId, 200, 1000000);
      final tripId = await loadVan(qty: 100, loadPriceKobo: 1150000);

      final r = await db.vanTripsDao.restockTrip(
        tripId: tripId,
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
        lines: [
          VanLoadLine(
            productId: productId,
            quantity: 40,
            loadPriceKobo: 1150000,
            shellsOut: 40,
          ),
        ],
      );

      expect(r.tripId, tripId, reason: 'no second trip is opened');
      expect(r.alreadyApplied, isFalse);

      // A SECOND lot, not a mutation of the first (spec §4.3).
      final lots = await db.vanTripsDao.lotsForTrip(tripId);
      expect(lots, hasLength(2));
      expect(lots[0].quantity, 100);
      expect(lots[1].quantity, 40);
      expect(lots[1].qtyRemaining, 40);
      // Cost travelled with THIS load too.
      expect(lots[1].unitCostKobo, 1000000);

      // Stock moved and the batches were drawn down again.
      expect(await onHand(warehouseId), 60);
      expect(await onHand(vanId), 140);
      expect(await queue(warehouseId), hasLength(1));
      expect((await queue(warehouseId)).single.qtyRemaining, 60);

      // The driver was debited for the restock, typed `restock`.
      expect(
        await db.driverLedgerDao.getBalanceKobo(driverId),
        -(140 * 1150000),
      );
      final debit = (await ledgerRows()).last;
      expect(debit.type, kDriverLedgerTypeRestock);
      expect(debit.referenceType, kDriverLedgerRefLot);
      expect(debit.referenceId, lots[1].id);
      expect(debit.signedAmountKobo, -(40 * 1150000));

      // The shell memo ACCUMULATED rather than being restated.
      expect((await db.vanTripsDao.getTrip(tripId))!.shellsOut, 40);
    });

    test('is idempotent on dispatch_event_id — a double-tap debits once',
        () async {
      await stockWithBatch(warehouseId, 200, 1000);
      final tripId = await loadVan(qty: 10, loadPriceKobo: 5000);
      final key = UuidV7.generate();
      final lines = [
        VanLoadLine(productId: productId, quantity: 20, loadPriceKobo: 5000),
      ];

      final first = await db.vanTripsDao.restockTrip(
        tripId: tripId,
        performedBy: managerId,
        dispatchEventId: key,
        lines: lines,
      );
      final second = await db.vanTripsDao.restockTrip(
        tripId: tripId,
        performedBy: managerId,
        dispatchEventId: key,
        lines: lines,
      );

      expect(second.alreadyApplied, isTrue);
      expect(second.lots.single.id, first.lots.single.id);
      expect(await db.vanTripsDao.lotsForTrip(tripId), hasLength(2));
      expect(await db.driverLedgerDao.getBalanceKobo(driverId), -150000);
      expect(await onHand(vanId), 30);
    });

    test('an overload rolls the whole restock back and leaves the trip as it '
        'was', () async {
      await stockWithBatch(warehouseId, 30, 1000);
      final tripId = await loadVan(qty: 10, loadPriceKobo: 5000);

      await expectLater(
        db.vanTripsDao.restockTrip(
          tripId: tripId,
          performedBy: managerId,
          dispatchEventId: UuidV7.generate(),
          lines: [
            VanLoadLine(productId: productId, quantity: 50, loadPriceKobo: 5000),
          ],
        ),
        throwsA(isA<InsufficientStockException>()),
      );

      expect(await db.vanTripsDao.lotsForTrip(tripId), hasLength(1));
      expect(await ledgerRows(), hasLength(1));
      expect(await onHand(warehouseId), 20);
      expect(await onHand(vanId), 10);
    });

    test('a restock onto a CLOSED trip is refused', () async {
      await stockWithBatch(warehouseId, 100, 1000);
      final tripId = await loadVan(qty: 10, loadPriceKobo: 5000);
      await (db.update(db.vanTrips)..where((t) => t.id.equals(tripId))).write(
        VanTripsCompanion(
          status: const Value(kVanTripStatusClosed),
          closedAt: Value(DateTime.now()),
        ),
      );

      await expectLater(
        db.vanTripsDao.restockTrip(
          tripId: tripId,
          performedBy: managerId,
          dispatchEventId: UuidV7.generate(),
          lines: [
            VanLoadLine(productId: productId, quantity: 5, loadPriceKobo: 5000),
          ],
        ),
        throwsA(isA<VanTripNotOpenException>()),
      );
      expect(await db.vanTripsDao.lotsForTrip(tripId), hasLength(1));
    });

    test('a restock does NOT re-price the driver terminal — the road price '
        'stays the oldest lot\'s (the #143 decision on the cursor)', () async {
      await stockWithBatch(warehouseId, 200, 1000);
      final tripId = await loadVan(qty: 20, loadPriceKobo: 5000);
      await db.vanTripsDao.restockTrip(
        tripId: tripId,
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
        lines: [
          VanLoadLine(productId: productId, quantity: 20, loadPriceKobo: 9000),
        ],
      );
      expect((await db.vanTripsDao.loadPricesForTrip(tripId))[productId], 5000);

      // …and it STILL does not, once a return has exhausted that oldest lot.
      // The price the driver signed for must not move because a manager typed
      // a return on another device.
      await db.vanTripsDao.recordReturn(
        tripId: tripId,
        performedBy: managerId,
        lines: [
          VanReturnLine(
            productId: productId,
            quantity: 20,
            condition: kVanReturnConditionGood,
          ),
        ],
      );
      expect((await db.vanTripsDao.lotsForTrip(tripId))[0].qtyRemaining, 0);
      expect(
        (await db.vanTripsDao.loadPricesForTrip(tripId))[productId],
        5000,
        reason: 'the cursor is a valuation device, not a pricing one',
      );
    });
  });

  // ═══ The running balance moves at the moment each event lands ════════════

  group('multiple restocks and returns each move the balance when logged', () {
    test('the running balance tracks every event in order', () async {
      await stockWithBatch(warehouseId, 500, 1000);
      final tripId = await loadVan(qty: 100, loadPriceKobo: 5000);
      expect(await db.driverLedgerDao.getBalanceKobo(driverId), -500000);

      await db.vanTripsDao.restockTrip(
        tripId: tripId,
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
        lines: [
          VanLoadLine(productId: productId, quantity: 50, loadPriceKobo: 5000),
        ],
      );
      expect(await db.driverLedgerDao.getBalanceKobo(driverId), -750000);

      await db.vanTripsDao.recordReturn(
        tripId: tripId,
        performedBy: managerId,
        lines: [
          VanReturnLine(
            productId: productId,
            quantity: 20,
            condition: kVanReturnConditionGood,
          ),
        ],
      );
      expect(await db.driverLedgerDao.getBalanceKobo(driverId), -650000);

      await db.vanTripsDao.restockTrip(
        tripId: tripId,
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
        lines: [
          VanLoadLine(productId: productId, quantity: 10, loadPriceKobo: 5000),
        ],
      );
      expect(await db.driverLedgerDao.getBalanceKobo(driverId), -700000);

      // A damaged return moves NOTHING — the driver is still liable.
      await db.vanTripsDao.recordReturn(
        tripId: tripId,
        performedBy: managerId,
        lines: [
          VanReturnLine(
            productId: productId,
            quantity: 5,
            condition: kVanReturnConditionDamaged,
          ),
        ],
      );
      expect(await db.driverLedgerDao.getBalanceKobo(driverId), -700000);

      await db.vanTripsDao.recordReturn(
        tripId: tripId,
        performedBy: managerId,
        lines: [
          VanReturnLine(
            productId: productId,
            quantity: 30,
            condition: kVanReturnConditionGood,
          ),
        ],
      );
      expect(await db.driverLedgerDao.getBalanceKobo(driverId), -550000);

      // Every event is its own dated row — three returns, three lots.
      expect(await db.vanTripsDao.returnsForTrip(tripId), hasLength(3));
      expect(await db.vanTripsDao.lotsForTrip(tripId), hasLength(3));
    });
  });

  // ═══ The #145 read seam ══════════════════════════════════════════════════

  group('the close seam #145 reads', () {
    test('cogs = loaded cost − good-return cost, per lot and never blended',
        () async {
      final older = DateTime(2026, 1, 1);
      final newer = DateTime(2026, 2, 1);
      await stockWithBatch(warehouseId, 100, 1000, receivedAt: older);
      await stockWithBatch(warehouseId, 100, 3000, receivedAt: newer);

      final tripId = await loadVan(qty: 100, loadPriceKobo: 5000); // cost 1,000
      await db.vanTripsDao.restockTrip(
        tripId: tripId,
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
        lines: [
          // cost 3,000
          VanLoadLine(productId: productId, quantity: 100, loadPriceKobo: 8000),
        ],
      );

      // 120 back good (100 @ cost 1,000 + 20 @ cost 3,000) and 5 damaged.
      await db.vanTripsDao.recordReturn(
        tripId: tripId,
        performedBy: managerId,
        lines: [
          VanReturnLine(
            productId: productId,
            quantity: 120,
            condition: kVanReturnConditionGood,
          ),
          VanReturnLine(
            productId: productId,
            quantity: 5,
            condition: kVanReturnConditionDamaged,
          ),
        ],
      );

      final loadedCost = await db.vanTripsDao.loadedCostKoboForTrip(tripId);
      final totals = await db.vanTripsDao.returnTotalsForTrip(tripId);
      expect(loadedCost, 100 * 1000 + 100 * 3000);
      expect(totals.goodCostKobo, 100 * 1000 + 20 * 3000);

      // consumed = 200 loaded − 120 good returns = 80 units, all from the
      // ₦3,000 lot — so 240,000, which the identity reproduces exactly.
      expect(loadedCost - totals.goodCostKobo, 80 * 3000);
      // The damaged units are INSIDE consumed: their cost is already in COGS,
      // and damagedCostKobo is a disclosure figure (spec §6.3's guard).
      expect(totals.damagedCostKobo, 5 * 3000);
    });
  });

  // ═══ Sync ════════════════════════════════════════════════════════════════

  group('sync', () {
    test('a return enqueues its event, the moved cursor and the ledger credit',
        () async {
      await stockWithBatch(warehouseId, 100, 1000000);
      final tripId = await loadVan(qty: 50, loadPriceKobo: 1150000);

      await db.vanTripsDao.recordReturn(
        tripId: tripId,
        performedBy: managerId,
        lines: [
          VanReturnLine(
            productId: productId,
            quantity: 10,
            condition: kVanReturnConditionGood,
            shellsBack: 10,
          ),
        ],
      );

      final queued = await getPendingQueue(db);
      expect(
        queued.map((r) => r.actionType).toSet(),
        containsAll(<String>{
          'van_return_events:upsert',
          'van_trip_lots:upsert',
          'driver_ledger_entries:upsert',
          'van_trips:upsert',
          'cost_batches:upsert',
        }),
      );

      final push = queued.lastWhere(
        (r) => r.actionType == 'van_return_events:upsert',
      );
      final payload = decodePayload(push);
      expect(payload['business_id'], businessId);
      expect(payload['trip_id'], tripId);
      expect(payload['product_id'], productId);
      expect(payload['quantity'], 10);
      expect(payload['condition'], kVanReturnConditionGood);
      expect(payload['credit_kobo'], 10 * 1150000);
      expect(payload['cost_kobo'], 10 * 1000000);
      expect(payload['shells_back'], 10);
      expect(payload['crate_shells'], isNull);
    });

    test('the enqueued lot carries the DECREMENTED cursor', () async {
      await stockWithBatch(warehouseId, 100, 1000);
      final tripId = await loadVan(qty: 40, loadPriceKobo: 5000);

      await db.vanTripsDao.recordReturn(
        tripId: tripId,
        performedBy: managerId,
        lines: [
          VanReturnLine(
            productId: productId,
            quantity: 15,
            condition: kVanReturnConditionGood,
          ),
        ],
      );

      final lotPushes = (await getPendingQueue(db))
          .where((r) => r.actionType == 'van_trip_lots:upsert')
          .toList();
      final payload = decodePayload(lotPushes.last);
      expect(payload['quantity'], 40);
      expect(payload['qty_remaining'], 25);
    });
  });
}
