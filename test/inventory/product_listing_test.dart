import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/listings/listing_content.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/services/product_listing_service.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../helpers/dispatch_test_utils.dart';
import '../helpers/in_memory_cloud_transport.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late ProductListingService service;
  const allowed = GateContext(grantedKeys: {'products.manage_listing'},
    roleRank: GateTier.manager, isReady: true);
  const priceOnly = GateContext(grantedKeys: {'products.edit_price'},
    roleRank: GateTier.ceo, isReady: true);

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    service = ProductListingService(db.catalogDao);
  });
  tearDown(() => db.close());

  Future<String> seed({String? tenant, bool deleted = false}) async {
    final id = UuidV7.generate();
    await db.into(db.products).insert(ProductsCompanion.insert(
      id: Value(id), businessId: tenant ?? businessId, name: 'Rice',
      unit: const Value('Kg'), isDeleted: Value(deleted),
      lastUpdatedAt: Value(DateTime(2026, 1, 1))));
    return id;
  }

  Future<ProductData> row(String id) => (db.select(db.products)
    ..where((p) => p.id.equals(id))).getSingle();

  test('listing has an independent grant, without a role bypass', () {
    expect(Gates.manageListing.evaluate(allowed), isTrue);
    expect(Gates.manageListing.evaluate(priceOnly), isFalse);
    expect(Gates.manageListing.evaluate(const GateContext(
      grantedKeys: {}, roleRank: null, isReady: false)), isFalse);
  });

  test('offline toggle preserves sale state and queues full row including clears', () async {
    final id = await seed();
    expect((await row(id)).showOnline, isTrue);
    await db.catalogDao.updateProductDetails(id, name: 'Rice edited',
      retailerPriceKobo: 25000, wholesalerPriceKobo: 24000, buyingPriceKobo: 20000,
      categoryId: null, subtitle: null);
    expect((await service.setShowOnline(productId: id, showOnline: false,
      gateContext: allowed)).isOk, isTrue);
    final product = await row(id);
    expect(product.showOnline, isFalse);
    expect(product.isAvailable, isTrue);
    expect(product.isDeleted, isFalse);
    expect(product.retailerPriceKobo, 25000);
    expect(product.lastUpdatedAt.isAfter(DateTime(2026, 1, 1)), isTrue);
    final payload = (await getPendingQueue(db)).where((q) =>
      q.actionType == 'products:upsert').map(decodePayload).last;
    expect(payload['show_online'], isFalse);
    expect(payload['name'], 'Rice edited');
    expect(payload['category_id'], isNull);
    expect(payload.containsKey('category_id'), isTrue);
    expect(payload.containsKey('subtitle'), isTrue);
    expect(payload['business_id'], businessId);
    expect(SupabaseSyncService.scrubForTesting('products', payload)['show_online'],
      isFalse);
  });

  test('denied or revoked grant leaves the product and outbox untouched', () async {
    final id = await seed();
    final before = (await row(id)).toJson();
    final result = await service.setShowOnline(productId: id, showOnline: false,
      gateContext: priceOnly);
    expect(result.isErr, isTrue);
    expect((await row(id)).toJson(), before);
    expect(await getPendingQueue(db), isEmpty);
  });

  test('foreign, deleted and missing product IDs cannot be changed or queued', () async {
    final other = UuidV7.generate();
    await db.into(db.businesses).insert(
      BusinessesCompanion.insert(id: Value(other), name: 'Other shop'));
    final foreign = await seed(tenant: other);
    final deleted = await seed(deleted: true);
    for (final id in [foreign, deleted, UuidV7.generate()]) {
      expect((await service.setShowOnline(productId: id, showOnline: false,
        gateContext: allowed)).isErr, isTrue);
    }
    expect((await row(foreign)).showOnline, isTrue);
    expect((await row(deleted)).showOnline, isTrue);
    expect(await getPendingQueue(db), isEmpty);
  });

  test('off/on payloads restore on a second device without changing archive', () async {
    final id = await seed();
    await db.catalogDao.setProductArchived(id, true);
    final peer = AppDatabase.forTesting(NativeDatabase.memory());
    peer.businessIdResolver = () => businessId;
    await peer.into(peer.businesses).insert(
      BusinessesCompanion.insert(id: Value(businessId), name: 'Peer shop'));
    final transport = InMemoryCloudTransport();
    final sync = SupabaseSyncService(peer, transport);
    addTearDown(() async { await transport.dispose(); await peer.close(); });
    for (final value in [false, true]) {
      expect((await service.setShowOnline(productId: id, showOnline: value,
        gateContext: allowed)).isOk, isTrue);
      final payload = (await getPendingQueue(db)).where((q) =>
        q.actionType == 'products:upsert').map(decodePayload).last;
      final wire = SupabaseSyncService.scrubForTesting('products', payload);
      await transport.upsertRows('products', [wire]);
      await sync.restoreTableDataForTesting('products', transport.rowsOf('products'));
      final restored = await (peer.select(peer.products)
        ..where((p) => p.id.equals(id))).getSingle();
      expect(restored.showOnline, value);
      expect(restored.isAvailable, isFalse);
    }
  });

  group('listing content (#473)', () {
    const content = ListingContent(onlineDescription: 'Long grain', brand: 'Mama Gold',
      minOrderQty: 2, orderStep: 2, maxOrderQty: 20);

    test('saves offline and queues the full row, clears included', () async {
      final id = await seed();
      expect((await service.saveContent(productId: id, content: content,
        gateContext: allowed)).isOk, isTrue);
      final p = await row(id);
      expect((p.onlineDescription, p.brand, p.minOrderQty, p.orderStep, p.maxOrderQty),
        ('Long grain', 'Mama Gold', 2, 2, 20));
      expect(p.isAvailable, isTrue);
      expect((await service.saveContent(productId: id,
        content: const ListingContent(), gateContext: allowed)).isOk, isTrue);
      final payload = SupabaseSyncService.scrubForTesting('products',
        (await getPendingQueue(db)).where((q) => q.actionType == 'products:upsert')
          .map(decodePayload).last);
      expect(payload.containsKey('online_description'), isTrue);
      expect(payload['online_description'], isNull);
      expect(payload.containsKey('max_order_qty'), isTrue);
      expect(payload['max_order_qty'], isNull);
      expect((payload['min_order_qty'], payload['order_step']), (1, 1));
    });

    test('denied grant, invalid limits and foreign rows write nothing', () async {
      final id = await seed();
      final other = UuidV7.generate();
      await db.into(db.businesses).insert(
        BusinessesCompanion.insert(id: Value(other), name: 'Other shop'));
      final foreign = await seed(tenant: other);
      expect((await service.saveContent(productId: id, content: content,
        gateContext: priceOnly)).isErr, isTrue);
      expect((await service.saveContent(productId: id,
        content: const ListingContent(minOrderQty: 5, maxOrderQty: 4),
        gateContext: allowed)).isErr, isTrue);
      expect((await service.saveContent(productId: foreign, content: content,
        gateContext: allowed)).isErr, isTrue);
      expect((await row(id)).minOrderQty, 1);
      expect(await getPendingQueue(db), isEmpty);
    });

    test('the database refuses limits that break the CHECKs', () async {
      final id = await seed();
      for (final bad in [
        const ProductsCompanion(minOrderQty: Value(0)),
        const ProductsCompanion(orderStep: Value(0)),
        const ProductsCompanion(maxOrderQty: Value(0)),
        ProductsCompanion(brand: Value('x' * 61)),
        ProductsCompanion(onlineDescription: Value('x' * 2001)),
      ]) {
        await expectLater((db.update(db.products)..where((p) => p.id.equals(id)))
          .write(bad), throwsA(anything));
      }
    });

    test('round-trips to a second device', () async {
      final id = await seed();
      final peer = AppDatabase.forTesting(NativeDatabase.memory());
      peer.businessIdResolver = () => businessId;
      await peer.into(peer.businesses).insert(
        BusinessesCompanion.insert(id: Value(businessId), name: 'Peer shop'));
      final transport = InMemoryCloudTransport();
      final sync = SupabaseSyncService(peer, transport);
      addTearDown(() async { await transport.dispose(); await peer.close(); });
      await service.saveContent(productId: id, content: content, gateContext: allowed);
      final payload = (await getPendingQueue(db)).where((q) =>
        q.actionType == 'products:upsert').map(decodePayload).last;
      await transport.upsertRows('products',
        [SupabaseSyncService.scrubForTesting('products', payload)]);
      await sync.restoreTableDataForTesting('products', transport.rowsOf('products'));
      final restored = await (peer.select(peer.products)
        ..where((p) => p.id.equals(id))).getSingle();
      expect(ListingContent.of(restored), content);
    });
  });
}
