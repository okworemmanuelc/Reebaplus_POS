// van_cost_fence_test.dart
//
// #142 (van-sales spec §5.6, ADR 0019 decision 1) — the COSTING FENCES.
//
// The hazard these pin is not hypothetical, it is arithmetic. A road sale books
// no per-line COGS by design, so every one of its `order_items` rows sits at
// `buying_price_kobo == 0`, on a recognised order, carrying a product — which is
// EXACTLY the F5 cost-backfill's gather set (`CostBatchesDao._planBackfill`).
// For a van-selling business the road lines would be the bulk of every offer.
//
// One accepted prompt would then restate them with per-line cost, ON TOP OF the
// trip's close-time COGS, which #145 computes from the lot snapshots
// (`van_trip_lots.unit_cost_kobo`). The same goods, costed twice, against a
// profit figure a manager already signed off — and nothing downstream announces
// it. ADR 0019's consequence note says it plainly: "Anyone extending the
// backfill or the recost RPC must preserve the van fence, and the regression
// tests exist to say so." This is that file.
//
// The fences are deliberately DOUBLE — the trip tag (bookkeeping) and the store
// kind (the physical fact) — and both halves are exercised here, because a road
// line that lost its tag must still be fenced.
//
// The CLOUD half of §5.6 (fence 2, `pos_recost_product_store` skipping van
// stores) lives in SQL and has no Dart seam; it is pinned by migration
// 0164's own verification block and its inline comment. See the note at the
// bottom of this file.

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
    // An UNCOSTED product — the exact state the F5 backfill exists for.
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

  var orderSeq = 0;

  Future<String> ringSale({
    required String storeId,
    int qty = 10,
    int unitPriceKobo = 1150000,
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

  /// Load the van from an UNCOSTED warehouse position, so the road sale below
  /// is uncosted for the same reason the shop sale is — the difference the
  /// fence has to see is the STORE, not the state of the queue.
  Future<String> loadTheVan({int qty = 100}) async {
    await db.inventoryDao.adjustStock(
      productId,
      warehouseId,
      200,
      'opening',
      managerId,
      trackCost: false,
    );
    await db.costBatchesDao.recordInflowBatch(
      productId: productId,
      storeId: warehouseId,
      quantity: 200,
      costKobo: 0, // uncosted
    );
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

  Future<int> lineCost(String orderId) async {
    final row = await (db.select(db.orderItems)
          ..where((i) => i.orderId.equals(orderId)))
        .getSingle();
    return row.buyingPriceKobo;
  }

  // ═══ Fence 1a — the offer never GATHERS a road line ══════════════════════

  group('onCostBecameReal gathers no van lines', () {
    test('a 0 → real cost transition on a product sold on the road offers '
        'nothing', () async {
      await loadTheVan();
      await ringSale(storeId: vanId, qty: 40);
      await ringSale(storeId: vanId, qty: 20);

      // Sanity: those lines ARE uncosted, recognised and product-carrying —
      // i.e. they would qualify on every criterion except the van fence. If
      // this ever stops being true the test below passes vacuously.
      final uncosted = await (db.select(db.orderItems)
            ..where((i) => i.buyingPriceKobo.equals(0)))
          .get();
      expect(uncosted, hasLength(2));

      final offer = await db.costBatchesDao.onCostBecameReal(
        productId,
        1000000,
      );

      expect(offer.isEmpty, isTrue);
      expect(offer.lineIds, isEmpty);
      expect(offer.unitsUncosted, 0);
    });

    test('a SHOP line on the same product is still gathered — the fence is '
        'van-only, not a blanket off switch', () async {
      await loadTheVan();
      await ringSale(storeId: vanId, qty: 40); // road: fenced
      final shopOrder = await ringSale(storeId: warehouseId, qty: 7); // shop

      final offer = await db.costBatchesDao.onCostBecameReal(
        productId,
        1000000,
      );

      expect(offer.lineIds, hasLength(1));
      expect(offer.unitsUncosted, 7);

      final gathered = await (db.select(db.orderItems)
            ..where((i) => i.id.equals(offer.lineIds.single)))
          .getSingle();
      expect(gathered.orderId, shopOrder);
    });

    test('a business with no vans behaves exactly as before the fence existed',
        () async {
      // The common case, and the one the fence must not change: with no van
      // rows the predicate short-circuits to `Constant(true)` and the generated
      // SQL is what it was before #142. Drop the fixture van so this really is
      // a van-less business rather than one that merely never used its van.
      await (db.delete(db.stores)..where((s) => s.id.equals(vanId))).go();

      // Uncosted warehouse stock, one shop sale.
      await db.inventoryDao.adjustStock(
        productId,
        warehouseId,
        50,
        'opening',
        managerId,
        trackCost: false,
      );
      await db.costBatchesDao
          .recordInflowBatch(
            productId: productId,
            storeId: warehouseId,
            quantity: 50,
            costKobo: 0,
          );
      final id = await ringSale(storeId: warehouseId, qty: 12);

      final offer = await db.costBatchesDao.onCostBecameReal(
        productId,
        1000000,
      );

      expect(offer.lineIds, hasLength(1));
      expect(offer.unitsUncosted, 12);

      final applied = await db.costBatchesDao.applyCostBackfill(
        offer,
        description: 'test backfill',
        staffId: managerId,
      );
      expect(applied, 1);
      expect(await lineCost(id), 1000000);
    });
  });

  // ═══ Fence 1b — the WRITE refuses a road line even if handed one ══════════

  group('applyCostBackfill refuses a van line at the row', () {
    test('an offer that names road lines restates none of them', () async {
      await loadTheVan();
      final road = await ringSale(storeId: vanId, qty: 40);
      final roadLine = (await (db.select(db.orderItems)
                ..where((i) => i.orderId.equals(road)))
              .getSingle())
          .id;

      // A hand-built offer, as if it had been gathered before the store was
      // flipped to a van (or by a future caller that builds offers some other
      // way). The gather fence cannot help here — only the write fence can.
      final applied = await db.costBatchesDao.applyCostBackfill(
        CostBackfillOffer(
          productId: productId,
          newCostKobo: 1000000,
          lineIds: [roadLine],
          unitsUncosted: 40,
        ),
        description: 'hand-built offer',
        staffId: managerId,
      );

      expect(applied, 0);
      expect(await lineCost(road), 0, reason: 'the road line stays uncosted');
    });

    test('a mixed offer restates the shop line and skips the road line',
        () async {
      await loadTheVan();
      final road = await ringSale(storeId: vanId, qty: 40);
      final shop = await ringSale(storeId: warehouseId, qty: 7);
      final roadLine = (await (db.select(db.orderItems)
                ..where((i) => i.orderId.equals(road)))
              .getSingle())
          .id;
      final shopLine = (await (db.select(db.orderItems)
                ..where((i) => i.orderId.equals(shop)))
              .getSingle())
          .id;

      final applied = await db.costBatchesDao.applyCostBackfill(
        CostBackfillOffer(
          productId: productId,
          newCostKobo: 1000000,
          lineIds: [roadLine, shopLine],
          unitsUncosted: 47,
        ),
        description: 'mixed offer',
        staffId: managerId,
      );

      expect(applied, 1);
      expect(await lineCost(road), 0);
      expect(await lineCost(shop), 1000000);
    });
  });

  // ═══ Fence 1c — the trip TAG is a second, independent fence ══════════════

  test('a trip-tagged line on a NON-van store is fenced too', () async {
    // The belt-and-braces case: the order carries a trip tag but its store is a
    // normal warehouse (a data state a mis-scoped write or a partial restore
    // could produce). The store-kind fence cannot see it; the tag fence must.
    final tripId = await loadTheVan();
    final id = await ringSale(storeId: warehouseId, qty: 9);
    await (db.update(db.orders)..where((o) => o.id.equals(id)))
        .write(OrdersCompanion(vanTripId: Value(tripId)));

    final offer = await db.costBatchesDao.onCostBecameReal(productId, 1000000);

    expect(
      offer.lineIds,
      isEmpty,
      reason: 'orders.van_trip_id alone must fence a line out of the gather',
    );
  });

  // ═══ Fence 2 (cloud) — SQL-only, recorded here so the pair is findable ═══
  //
  // `pos_recost_product_store` skipping van stores is enforced in Postgres
  // (supabase/migrations/0164_van_sales_trip_tagged_orders.sql, the block
  // marked `#142 delta`). It has NO Dart seam: the client never calls the
  // function directly — the sync service asks the cloud to recost the
  // (product, store) pairs a push touched — so there is nothing to drive from
  // an in-memory Drift DB.
  //
  // It is pinned instead by:
  //   · the early return in 0164 §3, with the reason attached in the migration
  //     comment (so a later editor reads WHY before deleting it), and
  //   · verification step 3 in that migration's footer, which calls the
  //     function against a van store and expects
  //     `{"recosted_count": 0, "skipped": "van_store"}`.
  //
  // If a Dart-drivable seam ever appears (e.g. a fake Transport that records
  // recost calls), the assertion belongs in this group.
}
