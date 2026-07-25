// van_store_test.dart
//
// #140 (PRD #139 / ADR 0019) — the van-as-location prefactor.
//
// Three things are pinned here, because between them they are the whole slice:
//
//  1. A location can be created as a van (`stores.kind = 'van'`), it round-trips
//     through Drift, and the central predicate reports it correctly. A normal
//     store — including one written by any pre-#140 code path that never
//     mentions `kind` — defaults to 'store'.
//  2. Van stock is still company stock. `inventoryOnHandKobo` /
//     `businessNetPositionKobo` read `watchProductsWithStock(storeId: null)` on
//     the All-Stores view, so the van's units MUST be in that total; they fall
//     out on their own when a concrete store is locked (spec §4.1). The
//     exclusion is about revenue, not assets, and this is the test that stops
//     someone "tidying up" by filtering vans out of the inventory read.
//  3. Van ORDERS are excluded from the orders list and its stats, in both the
//     All-Stores and the locked-store scope (spec §8.1).

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/core/stores/van_store.dart';

import '../helpers/dispatch_test_utils.dart';
import '../helpers/in_memory_cloud_transport.dart';

void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
  });

  tearDown(() async => db.close());

  Future<String> addProduct(String name, {required int buyingPriceKobo}) async {
    final id = UuidV7.generate();
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: Value(id),
            businessId: businessId,
            name: name,
            buyingPriceKobo: Value(buyingPriceKobo),
            lastUpdatedAt: Value(DateTime.now()),
          ),
        );
    return id;
  }

  Future<void> stock(String productId, String storeId, int qty) async {
    await db.into(db.inventory).insert(
          InventoryCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            productId: productId,
            storeId: storeId,
            quantity: Value(qty),
            lastUpdatedAt: Value(DateTime.now()),
          ),
        );
  }

  group('creating a van', () {
    test('createStore(kind: van) persists the kind and isVanStore agrees',
        () async {
      final vanId = await db.storesDao.createStore(
        name: 'Van 1',
        location: 'ABC-123-XY',
        kind: kStoreKindVan,
      );

      final van = await db.storesDao.getStore(vanId);
      expect(van, isNotNull);
      expect(van!.kind, kStoreKindVan);
      expect(isVanStore(van), isTrue);
      expect(van.location, 'ABC-123-XY');
    });

    test('createStore defaults to a normal store', () async {
      final storeId = await db.storesDao.createStore(name: 'Main');

      final store = (await db.storesDao.getStore(storeId))!;
      expect(store.kind, kStoreKindStore);
      expect(isVanStore(store), isFalse);
    });

    test('a row written without mentioning kind lands as a store', () async {
      // Every pre-#140 insert path (onboarding, the Stores screen's Add Store
      // sheet, a cloud restore of a legacy row) omits `kind`. The NOT NULL
      // DEFAULT is what keeps those rows out of the van surfaces.
      final id = UuidV7.generate();
      await db.into(db.stores).insert(
            StoresCompanion.insert(
              id: Value(id),
              businessId: businessId,
              name: 'Legacy',
              lastUpdatedAt: Value(DateTime.now()),
            ),
          );

      expect(isVanStore((await db.storesDao.getStore(id))!), isFalse);
    });

    test('the new van is enqueued for push carrying its kind', () async {
      await db.storesDao.createStore(name: 'Van 1', kind: kStoreKindVan);

      final queued = await getPendingQueue(db);
      final storeRows =
          queued.where((r) => r.actionType == 'stores:upsert').toList();
      expect(storeRows, hasLength(1));
      expect(decodePayload(storeRows.single)['kind'], kStoreKindVan);
    });

    test('withoutVans / onlyVans / VanStores split the same list', () async {
      await db.storesDao.createStore(name: 'Main');
      await db.storesDao.createStore(name: 'Van 1', kind: kStoreKindVan);
      await db.storesDao.createStore(name: 'Van 2', kind: kStoreKindVan);

      final all = await db.storesDao.getActiveStores();
      expect(all, hasLength(3));
      expect(withoutVans(all).map((s) => s.name), ['Main']);
      expect(onlyVans(all).map((s) => s.name), ['Van 1', 'Van 2']);

      final vans = VanStores.of(all);
      expect(vans.ids, hasLength(2));
      expect(vans.isEmpty, isFalse);
      expect(vans.isVan(onlyVans(all).first.id), isTrue);
      expect(vans.isVan(withoutVans(all).first.id), isFalse);
      // A legacy, pre-store order carries a null store id — never a van.
      expect(vans.isVan(null), isFalse);
      expect(vans.isNotVan(null), isTrue);
      expect(const VanStores.none().isEmpty, isTrue);
    });
  });

  group('All-Stores inventory value counts van stock (spec §4.1)', () {
    test('van units are inside the All-Stores total, out of a locked store',
        () async {
      final storeId = await db.storesDao.createStore(name: 'Warehouse');
      final vanId =
          await db.storesDao.createStore(name: 'Van 1', kind: kStoreKindVan);
      final beer = await addProduct('Star 60cl', buyingPriceKobo: 10000);
      await stock(beer, storeId, 200);
      await stock(beer, vanId, 100);

      // All Stores (storeId: null) — what `computeReconData` reads when nothing
      // is locked. Goods on wheels are still the company's.
      final allStores =
          await db.inventoryDao.watchProductsWithStock(storeId: null).first;
      final allValueKobo = allStores.fold<int>(
        0,
        (sum, p) => sum + p.totalStock * p.product.buyingPriceKobo,
      );
      expect(allValueKobo, 300 * 10000,
          reason: 'excluding van stock would drop business worth by the value '
              'of every load that is currently on the road');

      // Locked concrete store — the van simply is not this store.
      final locked =
          await db.inventoryDao.watchProductsWithStock(storeId: storeId).first;
      final lockedValueKobo = locked.fold<int>(
        0,
        (sum, p) => sum + p.totalStock * p.product.buyingPriceKobo,
      );
      expect(lockedValueKobo, 200 * 10000);
    });
  });

  group('van orders are out of the orders list (spec §8.1)', () {
    Future<void> sale({
      required String storeId,
      required String number,
      required int netKobo,
    }) async {
      final orderId = UuidV7.generate();
      await db.into(db.orders).insert(
            OrdersCompanion.insert(
              id: Value(orderId),
              businessId: businessId,
              storeId: Value(storeId),
              orderNumber: number,
              totalAmountKobo: netKobo,
              netAmountKobo: netKobo,
              amountPaidKobo: Value(netKobo),
              paymentType: 'cash',
              status: 'completed',
              lastUpdatedAt: Value(DateTime.now()),
            ),
          );
    }

    late String storeId;
    late String vanId;

    setUp(() async {
      storeId = await db.storesDao.createStore(name: 'Warehouse');
      vanId = await db.storesDao.createStore(name: 'Van 1', kind: kStoreKindVan);
      await sale(storeId: storeId, number: 'ORD-1', netKobo: 100000);
      await sale(storeId: vanId, number: 'ORD-2', netKobo: 690000);
    });

    test('All-Stores scope lists only the store sale', () async {
      final page = await db.ordersDao
          .watchOrdersPage(status: 'completed', excludeStoreIds: {vanId})
          .first;
      expect(page.map((o) => o.order.orderNumber), ['ORD-1']);
    });

    test('All-Stores stats count only the store sale', () async {
      final stats = await db.ordersDao
          .watchOrdersStats(status: 'completed', excludeStoreIds: {vanId})
          .first;
      expect(stats.count, 1);
      expect(stats.totalAmountKobo, 100000,
          reason: 'road revenue must not inflate the orders tab total');
    });

    test('no vans registered → nothing changes (empty set is a no-op)',
        () async {
      final page =
          await db.ordersDao.watchOrdersPage(status: 'completed').first;
      expect(page.map((o) => o.order.orderNumber),
          containsAll(['ORD-1', 'ORD-2']));
    });

    test('a legacy null-store order survives the exclusion', () async {
      // `NOT IN` over a NULL left side is NULL, so a naive predicate would
      // silently drop every pre-store order.
      await db.into(db.orders).insert(
            OrdersCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              orderNumber: 'ORD-LEGACY',
              totalAmountKobo: 5000,
              netAmountKobo: 5000,
              paymentType: 'cash',
              status: 'completed',
              lastUpdatedAt: Value(DateTime.now()),
            ),
          );

      final page = await db.ordersDao
          .watchOrdersPage(status: 'completed', excludeStoreIds: {vanId})
          .first;
      expect(page.map((o) => o.order.orderNumber),
          containsAll(['ORD-1', 'ORD-LEGACY']));
      expect(page.map((o) => o.order.orderNumber), isNot(contains('ORD-2')));
    });
  });

  group('pull tolerates a cloud row without `kind` (deploy order)', () {
    // `kind` is NOT NULL locally, and Restore.plain runs `fromJson` BEFORE the
    // FK-resilient wrapper — so a missing column would throw and abort the
    // WHOLE pull page, not skip one row. That is exactly what a v70 device sees
    // if it pulls before supabase/migrations/0161 is applied. The registry's
    // `defaults` entry is the fuse; this is the test that keeps it there.
    test('a legacy row with no kind restores as a normal store', () async {
      final transport = InMemoryCloudTransport(authUserId: 'user-1');
      addTearDown(transport.dispose);
      final sync = SupabaseSyncService(db, transport);
      final storeId = UuidV7.generate();
      final ts = DateTime.utc(2026, 7, 25, 8).toIso8601String();

      await sync.restoreTableDataForTesting('stores', [
        {
          'id': storeId,
          'business_id': businessId,
          'name': 'Pre-0161 Warehouse',
          'location': null,
          // no 'kind' — the pre-0161 cloud shape
          'is_deleted': false,
          'created_at': ts,
          'last_updated_at': ts,
        },
      ]);

      final restored = await db.storesDao.getStore(storeId);
      expect(restored, isNotNull);
      expect(restored!.kind, kStoreKindStore);
      expect(isVanStore(restored), isFalse);
    });

    test('a cloud row that DOES carry kind=van restores as a van', () async {
      final transport = InMemoryCloudTransport(authUserId: 'user-1');
      addTearDown(transport.dispose);
      final sync = SupabaseSyncService(db, transport);
      final vanId = UuidV7.generate();
      final ts = DateTime.utc(2026, 7, 25, 8).toIso8601String();

      await sync.restoreTableDataForTesting('stores', [
        {
          'id': vanId,
          'business_id': businessId,
          'name': 'Van 1',
          'location': null,
          'kind': 'van',
          'is_deleted': false,
          'created_at': ts,
          'last_updated_at': ts,
        },
      ]);

      expect(isVanStore((await db.storesDao.getStore(vanId))!), isTrue);
    });
  });
}
