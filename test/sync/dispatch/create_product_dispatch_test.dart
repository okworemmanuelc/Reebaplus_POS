import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../../helpers/dispatch_test_utils.dart';

/// Seeds: warehouse + staff (so initial-stock paths can resolve FKs).
Future<({String warehouseId, String staffId})> _seedCreateProductFixtures(
  AppDatabase db,
  String businessId,
) async {
  final warehouseId = UuidV7.generate();
  await db.into(db.warehouses).insert(
        WarehousesCompanion.insert(
          id: Value(warehouseId),
          businessId: businessId,
          name: 'Main',
        ),
      );
  final staffId = UuidV7.generate();
  await db.into(db.users).insert(
        UsersCompanion.insert(
          id: Value(staffId),
          businessId: businessId,
          name: 'Stockkeeper',
          pin: '0000',
        ),
      );
  return (warehouseId: warehouseId, staffId: staffId);
}

void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
  });

  tearDown(() => db.close());

  group('CatalogDao.insertProductWithInitialStock dispatch', () {
    test(
        'flag OFF (no initial stock): enqueues only products:upsert',
        () async {
      await setFlag(db, 'feature.domain_rpcs_v2.create_product', on: false);
      await _seedCreateProductFixtures(db, businessId);

      final productId = await db.catalogDao.insertProductWithInitialStock(
        ProductsCompanion.insert(
          businessId: businessId,
          name: 'No-Stock Lager',
          sellingPriceKobo: const Value(100000),
        ),
      );

      expect(await db.select(db.products).get(), hasLength(1));
      expect(await db.select(db.stockAdjustments).get(), isEmpty);
      expect(await db.select(db.stockTransactions).get(), isEmpty);

      final pending = await getPendingQueue(db);
      final actionTypes = pending.map((r) => r.actionType).toList();
      expect(actionTypes, ['products:upsert']);

      // Sanity: the returned id matches the local row.
      expect((await db.select(db.products).getSingle()).id, productId);
    });

    test(
        'flag OFF (with initial stock): enqueues products + adjustments + '
        'stock_tx + inventory upserts', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.create_product', on: false);
      final fx = await _seedCreateProductFixtures(db, businessId);

      await db.catalogDao.insertProductWithInitialStock(
        ProductsCompanion.insert(
          businessId: businessId,
          name: 'Stocked Stout',
          sellingPriceKobo: const Value(150000),
        ),
        initialStock: 24,
        warehouseId: fx.warehouseId,
        performedBy: fx.staffId,
      );

      expect(await db.select(db.stockAdjustments).get(), hasLength(1));
      expect(await db.select(db.stockTransactions).get(), hasLength(1));
      final inv = await db.select(db.inventory).getSingle();
      expect(inv.quantity, 24);

      final pending = await getPendingQueue(db);
      final actionTypes = pending.map((r) => r.actionType).toList()..sort();
      expect(actionTypes, [
        'inventory:upsert',
        'products:upsert',
        'stock_adjustments:upsert',
        'stock_transactions:upsert',
      ]);
    });

    test(
        'flag ON (with initial stock): one envelope, only products + '
        'inventory mirrored locally', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.create_product', on: true);
      final fx = await _seedCreateProductFixtures(db, businessId);

      final productId = await db.catalogDao.insertProductWithInitialStock(
        ProductsCompanion.insert(
          businessId: businessId,
          name: 'Test Beer V2',
          sellingPriceKobo: const Value(100000),
          buyingPriceKobo: const Value(60000),
          subtitle: const Value('5% ABV'),
          lowStockThreshold: const Value(10),
          trackEmpties: const Value(true),
        ),
        initialStock: 50,
        warehouseId: fx.warehouseId,
        performedBy: fx.staffId,
      );

      // Local: product + inventory present, but not stock_adjustments /
      // stock_transactions — those arrive via _applyDomainResponse.
      expect(await db.select(db.products).get(), hasLength(1));
      expect((await db.select(db.inventory).getSingle()).quantity, 50);
      expect(await db.select(db.stockAdjustments).get(), isEmpty,
          reason: 'no local adjustment row until RPC response is applied');
      expect(await db.select(db.stockTransactions).get(), isEmpty,
          reason: 'no local stock_tx row until RPC response is applied');

      // Queue: exactly one envelope.
      final pending = await getPendingQueue(db);
      expect(pending, hasLength(1));
      expect(pending.first.actionType, 'domain:pos_create_product_v2');

      final payload = decodePayload(pending.first);
      expect(payload['p_business_id'], businessId);
      expect(payload['p_actor_id'], fx.staffId);
      // Idempotency key — must match the local product row id.
      expect(payload['p_product_id'], productId);
      expect(payload['p_name'], 'Test Beer V2');
      expect(payload['p_selling_price_kobo'], 100000);
      expect(payload['p_buying_price_kobo'], 60000);
      expect(payload['p_subtitle'], '5% ABV');
      expect(payload['p_low_stock_threshold'], 10);
      expect(payload['p_track_empties'], true);

      final initialStock = payload['p_initial_stock'] as Map;
      expect(initialStock['warehouse_id'], fx.warehouseId);
      expect(initialStock['quantity'], 50);
      // performed_by must NOT be in p_initial_stock — server uses
      // p_actor_id at the top level. Same shape as batch 8.
      expect(initialStock.containsKey('performed_by'), isFalse);

      // Optionals not provided → not in payload (caller's Companion didn't
      // set them, so the v2 RPC's SQL DEFAULT applies server-side).
      expect(payload.containsKey('p_size'), isFalse);
      expect(payload.containsKey('p_sku'), isFalse);
      expect(payload.containsKey('p_image_path'), isFalse);
    });

    test(
        'flag ON (no initial stock): envelope with no p_initial_stock key',
        () async {
      await setFlag(db, 'feature.domain_rpcs_v2.create_product', on: true);
      await _seedCreateProductFixtures(db, businessId);

      await db.catalogDao.insertProductWithInitialStock(
        ProductsCompanion.insert(
          businessId: businessId,
          name: 'Stockless Brew',
          sellingPriceKobo: const Value(50000),
        ),
      );

      final pending = await getPendingQueue(db);
      expect(pending, hasLength(1));
      final payload = decodePayload(pending.first);
      expect(payload.containsKey('p_initial_stock'), isFalse,
          reason: 'no initial stock means key is omitted entirely');

      // Local: product written, no inventory row yet.
      expect(await db.select(db.products).get(), hasLength(1));
      expect(await db.select(db.inventory).get(), isEmpty);
    });
  });
}
