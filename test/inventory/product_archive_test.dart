// Archive groundwork (#487). Archive reuses `products.is_available`: false =
// archived. CatalogDao.setProductArchived is the one writer — business-scoped,
// an explicit lastUpdatedAt, and a FULL-row products upsert so the flag
// converges cross-device without a 23502 or a dropped pending edit.

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
  });

  tearDown(() => db.close());

  Future<String> seed({String? inBusiness, String name = 'Star Lager'}) async {
    final id = UuidV7.generate();
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: Value(id),
            businessId: inBusiness ?? businessId,
            name: name,
            unit: const Value('Bottle'),
            lastUpdatedAt: Value(DateTime(2026, 1, 1)),
          ),
        );
    return id;
  }

  Future<ProductData> row(String id) =>
      (db.select(db.products)..where((t) => t.id.equals(id))).getSingle();

  List<Map<String, dynamic>> productPushes(
    List<SyncQueueData> queue,
    String id,
  ) => [
    for (final q in queue)
      if (q.actionType == 'products:upsert')
        if ((jsonDecode(q.payload) as Map<String, dynamic>)['id'] == id)
          jsonDecode(q.payload) as Map<String, dynamic>,
  ];

  test(
    'archiving writes is_available = false and a fresh lastUpdatedAt',
    () async {
      final id = await seed();
      expect((await row(id)).isAvailable, isTrue);

      await db.catalogDao.setProductArchived(id, true);

      final archived = await row(id);
      expect(archived.isAvailable, isFalse);
      expect(archived.isDeleted, isFalse, reason: 'archive never deletes');
      expect(archived.lastUpdatedAt.isAfter(DateTime(2026, 1, 1)), isTrue);
    },
  );

  test('unarchiving brings it back', () async {
    final id = await seed();
    await db.catalogDao.setProductArchived(id, true);
    await db.catalogDao.setProductArchived(id, false);
    expect((await row(id)).isAvailable, isTrue);
  });

  test('enqueues ONE full-row products upsert carrying is_available', () async {
    final id = await seed();
    await db.catalogDao.setProductArchived(id, true);

    final pushes = productPushes(await getPendingQueue(db), id);
    expect(pushes, hasLength(1));
    expect(pushes.single['is_available'], isFalse);
    expect(
      pushes.single['name'],
      'Star Lager',
      reason: 'full row: a partial upsert omits the NOT NULL name (23502)',
    );
    expect(pushes.single['business_id'], businessId);
  });

  test('a pending details edit survives the archive (coalesce-safe)', () async {
    final id = await seed(name: 'Old name');
    await db.catalogDao.updateProductDetails(
      id,
      name: 'New name',
      buyingPriceKobo: 100,
      retailerPriceKobo: 200,
      wholesalerPriceKobo: 150,
    );
    await db.catalogDao.setProductArchived(id, true);

    final pushes = productPushes(await getPendingQueue(db), id);
    expect(pushes, hasLength(1), reason: 'coalesced to one products upsert');
    expect(pushes.single['name'], 'New name');
    expect(pushes.single['is_available'], isFalse);
  });

  test("another business's product is never touched", () async {
    final otherBiz = UuidV7.generate();
    await db
        .into(db.businesses)
        .insert(
          BusinessesCompanion.insert(id: Value(otherBiz), name: 'Other Biz'),
        );
    final foreign = await seed(inBusiness: otherBiz);

    await db.catalogDao.setProductArchived(foreign, true);

    expect((await row(foreign)).isAvailable, isTrue);
    expect(productPushes(await getPendingQueue(db), foreign), isEmpty);
  });

  test('an archived product is off the sale list', () async {
    final kept = await seed(name: 'Gulder');
    final archived = await seed(name: 'Star Lager');
    await db.catalogDao.setProductArchived(archived, true);

    final onSale = await db.catalogDao.watchAvailableProductDatas().first;
    expect(onSale.map((p) => p.id), [kept]);
  });

  test('a details edit does not unarchive', () async {
    final id = await seed();
    await db.catalogDao.setProductArchived(id, true);
    await db.catalogDao.updateProductDetails(
      id,
      name: 'Star Lager',
      buyingPriceKobo: 100,
      retailerPriceKobo: 200,
      wholesalerPriceKobo: 150,
    );
    expect((await row(id)).isAvailable, isFalse);
  });
}
