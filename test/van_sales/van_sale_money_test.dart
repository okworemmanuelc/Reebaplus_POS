// van_sale_money_test.dart
//
// #142 (PRD #139 as amended by #161, ADR 0019 decisions 1 & 2, van-sales spec
// §4.6, §5.3, §5.4, §9.2) — what a ROAD SALE does and, mostly, what it must NOT
// do.
//
// This is the money-critical slice. Everything before it put money INTO the
// books correctly; this is where road sales stop writing cash the business does
// not hold. So the assertions here are almost all NEGATIVE — no payment row, no
// COGS snapshot, no ledger movement — because each of them is a figure that was
// silently wrong before, and none of them announces itself when it regresses:
//
//   · a payment row on a road sale overstates "Cash sales" by every unremitted
//     naira, forever (ADR 0019 decision 2);
//   · a per-line COGS snapshot double-counts cost against the trip's close-time
//     profit, which is computed from the lot snapshots (decision 1);
//   · a driver-ledger row on a sale destroys the one property that makes the
//     balance readable — that it is exactly `loaded − returned − paid`.
//
// The POSITIVE assertion is the trip tag, proven on BOTH sync paths: the v1
// per-row push and the v2 envelope (`feature.domain_rpcs_v2.record_sale`).
//
// In-memory Drift via bootstrapTestDb(); same shape as van_dispatch_test.dart.

import 'dart:convert';

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

  /// Stock + a matching FIFO batch at [unitCostKobo] — physical and costed
  /// position agree, the only sane starting point.
  Future<void> stockWithBatch(String store, int qty, int unitCostKobo) async {
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
    );
  }

  /// The spec §6.3 opening move: 200 @ ₦10,000 cost in the warehouse, load 100
  /// onto the van at an ₦11,500 load price. Returns the trip id.
  Future<String> loadTheVan({int qty = 100}) async {
    await stockWithBatch(warehouseId, 200, 1000000);
    final result = await db.vanTripsDao.dispatchLoad(
      vanStoreId: vanId,
      driverUserId: driverId,
      sourceStoreId: warehouseId,
      lines: [
        VanLoadLine(
          productId: productId,
          quantity: qty,
          loadPriceKobo: 1150000,
        ),
      ],
      performedBy: managerId,
      dispatchEventId: UuidV7.generate(),
    );
    return result.tripId;
  }

  var orderSeq = 0;

  /// Rings [qty] units on [storeId] as a cash walk-in — the exact shape the
  /// driver terminal produces.
  Future<String> ringSale({
    required String storeId,
    int qty = 10,
    int unitPriceKobo = 1150000,
    String? orderId,
  }) async {
    final id = orderId ?? UuidV7.generate();
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

  Future<List<PaymentTransactionData>> paymentRows() =>
      db.select(db.paymentTransactions).get();

  Future<OrderData> order(String id) =>
      (db.select(db.orders)..where((o) => o.id.equals(id))).getSingle();

  Future<List<OrderItemData>> lines(String orderId) =>
      (db.select(db.orderItems)..where((i) => i.orderId.equals(orderId))).get();

  // ═══ Cash follows custody (spec §5.3, ADR 0019 decision 2) ═══════════════

  group('a road sale writes NO payment row', () {
    test('none of the three #175 tender rows is written', () async {
      final tripId = await loadTheVan();

      await ringSale(storeId: vanId);

      // Not "no `sale` row" — NO ROW OF ANY TYPE. The #175 split writes up to
      // three (sale / crate_deposit / wallet_topup) and all three are suppressed
      // together, because all three would put money the business does not hold
      // into a cash figure.
      expect(await paymentRows(), isEmpty);

      // …and the sale really happened: the order exists, tagged to the trip,
      // with the money recorded on the ORDER (the driver was paid) but nowhere
      // in the payment ledger (the business was not).
      final rows = await db.select(db.orders).get();
      expect(rows, hasLength(1));
      expect(rows.single.amountPaidKobo, 10 * 1150000);
      expect(rows.single.vanTripId, tripId);
    });

    test('the SAME sale on a warehouse still writes its payment row — the '
        'suppression is about the van, not about the shape of the sale',
        () async {
      await stockWithBatch(warehouseId, 200, 1000000);

      await ringSale(storeId: warehouseId);

      final rows = await paymentRows();
      expect(rows, hasLength(1));
      expect(rows.single.type, 'sale');
      expect(rows.single.amountKobo, 10 * 1150000);
    });

    test('a van sale is stripped even when the van has NO open trip — '
        'suppression fails SAFE', () async {
      // No dispatch: the van holds stock but is not out on a trip. (The terminal
      // blocks this state, spec §9.2 #6; this is the write-boundary backstop.)
      await stockWithBatch(vanId, 50, 0);

      final id = await ringSale(storeId: vanId);

      expect(await paymentRows(), isEmpty);
      // No trip to attribute it to — but the money legs are still suppressed.
      // The tag is bookkeeping; the store is the fact.
      expect((await order(id)).vanTripId, isNull);
    });

    test('"Cash sales" — the sale-typed rows a reconciliation sums — is '
        'unchanged by a road sale', () async {
      await loadTheVan();
      // A shop sale first, so the figure is non-zero and a leak would be
      // visible as a CHANGE rather than as an absolute.
      await stockWithBatch(warehouseId, 50, 1000000);
      await ringSale(storeId: warehouseId, qty: 5);

      Future<int> cashSalesKobo() async {
        final rows = await (db.select(db.paymentTransactions)..where(
              (p) => p.type.equals('sale') & p.voidedAt.isNull(),
            ))
            .get();
        return rows.fold<int>(0, (sum, p) => sum + p.amountKobo);
      }

      final before = await cashSalesKobo();
      expect(before, 5 * 1150000);

      await ringSale(storeId: vanId, qty: 20);
      await ringSale(storeId: vanId, qty: 30);

      expect(await cashSalesKobo(), before);
    });
  });

  // ═══ No per-sale COGS (spec §5.6, ADR 0019 decision 1) ═══════════════════

  group('a road sale books NO per-sale COGS', () {
    test('every line stays uncosted, and the van store gains no batch',
        () async {
      await loadTheVan();

      final id = await ringSale(storeId: vanId);

      // The line carries no cost snapshot: the trip's COGS is the lot snapshot,
      // summed at close (#145). A per-line figure here would be counted twice.
      expect((await lines(id)).single.buyingPriceKobo, 0);

      // ADR 0019: no cost batch is EVER created on a van, so there was nothing
      // to draw and nothing was invented.
      expect(await db.costBatchesDao.queueFor(productId, vanId), isEmpty);
    });

    test('the warehouse queue is untouched by a road sale — its coverage was '
        'already drawn down at DISPATCH', () async {
      await loadTheVan();

      final coverageAfterLoad = (await db.costBatchesDao
              .queueFor(productId, warehouseId))
          .fold<int>(0, (sum, b) => sum + b.qtyRemaining);
      // 200 loaded in, 100 dispatched out.
      expect(coverageAfterLoad, 100);

      await ringSale(storeId: vanId, qty: 40);

      final coverageAfterSale = (await db.costBatchesDao
              .queueFor(productId, warehouseId))
          .fold<int>(0, (sum, b) => sum + b.qtyRemaining);
      expect(coverageAfterSale, coverageAfterLoad);
    });

    test('a warehouse sale still snapshots COGS — the skip is van-only',
        () async {
      await stockWithBatch(warehouseId, 200, 1000000);

      final id = await ringSale(storeId: warehouseId, qty: 10);

      expect((await lines(id)).single.buyingPriceKobo, 1000000);
    });
  });

  // ═══ Van stock still moves ══════════════════════════════════════════════

  test('van stock decrements normally — only the COSTING is skipped', () async {
    await loadTheVan();

    Future<int> onVan() async {
      final row = await (db.select(db.inventory)..where(
            (t) =>
                t.productId.equals(productId) &
                t.storeId.equals(vanId) &
                t.businessId.equals(businessId),
          ))
          .getSingleOrNull();
      return row?.quantity ?? 0;
    }

    expect(await onVan(), 100);
    await ringSale(storeId: vanId, qty: 35);
    expect(await onVan(), 65);
  });

  // ═══ The balance is untouched (spec §4.4) ═══════════════════════════════

  test('a road sale does NOT move the driver balance, and writes no ledger row',
      () async {
    await loadTheVan();

    final balanceAfterLoad =
        await db.driverLedgerDao.getBalanceKobo(driverId);
    // Loaded 100 @ ₦11,500 → they signed for ₦1,150,000.
    expect(balanceAfterLoad, -115000000);
    final rowsAfterLoad = (await db.select(db.driverLedgerEntries).get()).length;

    await ringSale(storeId: vanId, qty: 60);
    await ringSale(storeId: vanId, qty: 30);

    // Unchanged BOTH ways: same number and same rows. A sale converts goods the
    // driver already owes for into cash they still owe — booking it would
    // double-count the debt and stop the balance meaning `loaded − returned −
    // paid`.
    expect(await db.driverLedgerDao.getBalanceKobo(driverId), balanceAfterLoad);
    expect(
      (await db.select(db.driverLedgerEntries).get()).length,
      rowsAfterLoad,
    );
  });

  // ═══ The trip tag, on BOTH sync paths (spec §4.6, §12) ══════════════════

  group('the order carries its van_trip_id', () {
    test('v1 (flag OFF): the tag is on the row AND on the pushed payload',
        () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
      final tripId = await loadTheVan();

      final id = await ringSale(storeId: vanId);

      expect((await order(id)).vanTripId, tripId);

      final orderPush = (await getPendingQueue(db))
          .where((r) => r.actionType == 'orders:upsert')
          .toList();
      expect(orderPush, isNotEmpty);
      expect(decodePayload(orderPush.last)['van_trip_id'], tripId);
    });

    test('v2 (flag ON): the tag is on the row AND forwarded on the envelope',
        () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: true);
      final tripId = await loadTheVan();

      final id = await ringSale(storeId: vanId);

      expect((await order(id)).vanTripId, tripId);

      final envelope = (await getPendingQueue(db))
          .where((r) => r.actionType == 'domain:pos_record_sale_v2')
          .toList();
      expect(envelope, hasLength(1));
      final payload =
          jsonDecode(envelope.single.payload) as Map<String, dynamic>;
      // `p_van_trip_id` is what tells the cloud RPC (migration 0164) both how to
      // tag the order and that it must NOT mint a payment row.
      expect(payload['p_van_trip_id'], tripId);
      expect(payload['p_store_id'], vanId);
    });

    test('v2: still no local payment row — the suppression is not a v1 quirk',
        () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: true);
      await loadTheVan();

      await ringSale(storeId: vanId);

      expect(await paymentRows(), isEmpty);
    });

    test('an ordinary shop sale carries no tag on either path', () async {
      await stockWithBatch(warehouseId, 200, 1000000);

      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
      final v1 = await ringSale(storeId: warehouseId, qty: 5);
      expect((await order(v1)).vanTripId, isNull);

      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: true);
      final v2 = await ringSale(storeId: warehouseId, qty: 5);
      expect((await order(v2)).vanTripId, isNull);

      final envelope = (await getPendingQueue(db))
          .where((r) => r.actionType == 'domain:pos_record_sale_v2')
          .single;
      expect(
        (jsonDecode(envelope.payload) as Map<String, dynamic>)
            .containsKey('p_van_trip_id'),
        isFalse,
        reason: 'an untagged sale must not send a null key the RPC would read',
      );
    });
  });

  // ═══ The terminal's reads (spec §5.1, §9.2) ═════════════════════════════

  group('driver terminal reads', () {
    test('loadPricesForTrip prices the road at the LOAD price, oldest lot '
        'first', () async {
      final tripId = await loadTheVan();

      expect(await db.vanTripsDao.loadPricesForTrip(tripId), {
        productId: 1150000,
      });
    });

    test('sold value counts recognised orders only, at the price rung',
        () async {
      final tripId = await loadTheVan();
      await ringSale(storeId: vanId, qty: 60);
      final cancelled = await ringSale(storeId: vanId, qty: 5);

      await (db.update(db.orders)..where((o) => o.id.equals(cancelled))).write(
        const OrdersCompanion(status: Value('cancelled')),
      );

      expect(
        await db.vanTripsDao.watchSoldValueKoboForTrip(tripId).first,
        60 * 1150000,
      );
    });

    test('saleContextForStore answers both questions from one read', () async {
      final tripId = await loadTheVan();

      final onVan = await db.vanTripsDao.saleContextForStore(vanId);
      expect(onVan.isVanSale, isTrue);
      expect(onVan.tripId, tripId);

      final onStore = await db.vanTripsDao.saleContextForStore(warehouseId);
      expect(onStore.isVanSale, isFalse);
      expect(onStore.tripId, isNull);

      // A legacy, store-less order is never a van.
      final none = await db.vanTripsDao.saleContextForStore(null);
      expect(none.isVanSale, isFalse);
    });
  });
}
