// set_product_barcode_test.dart
//
// #321 — CatalogDao.setProductBarcode, the narrow write behind "Link to an
// existing product" on an unknown scan:
//   - it changes ONLY the barcode (+ lastUpdatedAt): name, prices,
//     manufacturer, category and stock stay exactly as they were (the reason
//     it exists — updateProductDetails would clear manufacturer + category);
//   - the code is trimmed;
//   - it enqueues the FULL products row (a partial upsert omits the NOT NULL
//     name → 23502);
//   - it is business-scoped: another business's product id is left alone.
// Plus searchProductsByName, the link search: business-scoped, non-deleted,
// case-insensitive, ordered by name.

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

  Future<ProductData> getProduct(String id) =>
      (db.select(db.products)..where((t) => t.id.equals(id))).getSingle();

  /// A fully dressed product: manufacturer, category, every price, a size, a
  /// unit and stock in a store — everything a careless write could clobber.
  Future<String> seedDressedProduct({String? barcode}) async {
    final manufacturerId = UuidV7.generate();
    await db
        .into(db.manufacturers)
        .insert(
          ManufacturersCompanion.insert(
            id: Value(manufacturerId),
            businessId: businessId,
            name: 'Nigerian Breweries',
          ),
        );
    final categoryId = UuidV7.generate();
    await db
        .into(db.categories)
        .insert(
          CategoriesCompanion.insert(
            id: Value(categoryId),
            businessId: businessId,
            name: 'Beer',
          ),
        );
    final storeId = UuidV7.generate();
    await db
        .into(db.stores)
        .insert(
          StoresCompanion.insert(
            id: Value(storeId),
            businessId: businessId,
            name: 'Main Store',
          ),
        );
    final id = UuidV7.generate();
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: Value(id),
            businessId: businessId,
            name: 'Star Lager',
            subtitle: const Value('Big bottle'),
            manufacturerId: Value(manufacturerId),
            categoryId: Value(categoryId),
            buyingPriceKobo: const Value(60000),
            retailerPriceKobo: const Value(100000),
            wholesalerPriceKobo: const Value(80000),
            unit: const Value('Bottle'),
            size: const Value('big'),
            barcode: Value(barcode),
          ),
        );
    await db
        .into(db.inventory)
        .insert(
          InventoryCompanion.insert(
            businessId: businessId,
            productId: id,
            storeId: storeId,
            quantity: const Value(12),
          ),
        );
    await db.customStatement('DELETE FROM sync_queue');
    return id;
  }

  test('changes ONLY the barcode (+ lastUpdatedAt); the rest of the row and '
      'the stock are untouched', () async {
    final id = await seedDressedProduct();
    final before = await getProduct(id);
    final stockBefore = await db.select(db.inventory).get();
    expect(before.manufacturerId, isNotNull);
    expect(before.categoryId, isNotNull);

    final updated = await db.catalogDao.setProductBarcode(id, '  6151234  ');

    final after = await getProduct(id);
    expect(after.barcode, '6151234', reason: 'the code is trimmed');
    expect(updated, after);
    expect(
      after.lastUpdatedAt.isBefore(before.lastUpdatedAt),
      isFalse,
    );
    // Every other column is exactly as it was (version is the sync row
    // counter the DB's update trigger bumps on any write).
    expect(after.version, greaterThan(before.version));
    expect(
      after.copyWith(
        barcode: Value(before.barcode),
        lastUpdatedAt: before.lastUpdatedAt,
        version: before.version,
      ),
      before,
    );
    expect(after.manufacturerId, before.manufacturerId);
    expect(after.categoryId, before.categoryId);
    expect(after.name, 'Star Lager');
    expect(after.retailerPriceKobo, 100000);
    expect(after.wholesalerPriceKobo, 80000);
    expect(after.buyingPriceKobo, 60000);
    expect(await db.select(db.inventory).get(), stockBefore);
  });

  test('replaces an existing barcode the same way', () async {
    final id = await seedDressedProduct(barcode: 'OLD-1');
    final before = await getProduct(id);

    await db.catalogDao.setProductBarcode(id, 'NEW-2');

    final after = await getProduct(id);
    expect(after.barcode, 'NEW-2');
    expect(after.manufacturerId, before.manufacturerId);
    expect(after.categoryId, before.categoryId);
  });

  test('enqueues the FULL products row (name and all)', () async {
    final id = await seedDressedProduct();
    final row = await getProduct(id);

    await db.catalogDao.setProductBarcode(id, 'BC-LINK');

    final pending = await getPendingQueue(db);
    final upserts = pending
        .where((r) => r.actionType == 'products:upsert')
        .toList();
    expect(upserts, hasLength(1));
    expect(pending, hasLength(1), reason: 'nothing but the product is queued');
    final payload = decodePayload(upserts.single);
    expect(payload['id'], id);
    expect(payload['barcode'], 'BC-LINK');
    expect(
      payload['name'],
      'Star Lager',
      reason: 'a partial products upsert omits the NOT NULL name → 23502',
    );
    expect(payload['business_id'], businessId);
    expect(payload['manufacturer_id'], row.manufacturerId);
    expect(payload['category_id'], row.categoryId);
    expect(payload['retailer_price_kobo'], 100000);
    expect(payload['wholesaler_price_kobo'], 80000);
  });

  test("another business's product is never updated or queued", () async {
    final otherBusinessId = UuidV7.generate();
    await db
        .into(db.businesses)
        .insert(
          BusinessesCompanion.insert(
            id: Value(otherBusinessId),
            name: 'Other Biz',
          ),
        );
    final theirsId = UuidV7.generate();
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: Value(theirsId),
            businessId: otherBusinessId,
            name: 'Their Lager',
          ),
        );
    await db.customStatement('DELETE FROM sync_queue');

    final updated = await db.catalogDao.setProductBarcode(theirsId, 'BC-X');

    expect(updated, isNull);
    expect((await getProduct(theirsId)).barcode, isNull);
    expect(await getPendingQueue(db), isEmpty);
  });

  group('searchProductsByName (#321)', () {
    Future<String> insertProduct(String name) => db.catalogDao.insertProduct(
      ProductsCompanion.insert(businessId: businessId, name: name),
    );

    test('case-insensitive contains, ordered by name', () async {
      final zobo = await insertProduct('Zobo Lager');
      final star = await insertProduct('Star Lager');
      await insertProduct('Malta');

      final hits = await db.catalogDao.searchProductsByName(' lager ');
      expect(hits.map((p) => p.id), [star, zobo]);
    });

    test('a blank query lists the first products by name', () async {
      final b = await insertProduct('Beta');
      final a = await insertProduct('Alpha');

      final hits = await db.catalogDao.searchProductsByName('', limit: 1);
      expect(hits.map((p) => p.id), [a]);
      expect(
        (await db.catalogDao.searchProductsByName('')).map((p) => p.id),
        [a, b],
      );
    });

    test('soft-deleted and other businesses\' products never appear', () async {
      final kept = await insertProduct('Star Lager');
      final gone = await insertProduct('Star Lager Old');
      await db.catalogDao.softDeleteProduct(gone);
      final otherBusinessId = UuidV7.generate();
      await db
          .into(db.businesses)
          .insert(
            BusinessesCompanion.insert(
              id: Value(otherBusinessId),
              name: 'Other Biz',
            ),
          );
      await db
          .into(db.products)
          .insert(
            ProductsCompanion.insert(
              businessId: otherBusinessId,
              name: 'Star Lager Theirs',
            ),
          );

      final hits = await db.catalogDao.searchProductsByName('star');
      expect(hits.map((p) => p.id), [kept]);
    });
  });
}
