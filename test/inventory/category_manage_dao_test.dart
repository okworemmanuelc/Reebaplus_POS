import 'package:drift/drift.dart' hide isNull; // matcher's isNull wins here
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

/// Category edit & delete (#109): rename (reject a collision), and soft-delete
/// that moves the category's products to Uncategorized (`categoryId = null`).
/// The data layer is CatalogDao; assertions cover the local write, the sync
/// enqueue shape, and the reactive `watchAllCategories` read.
void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
  });

  tearDown(() => db.close());

  Future<String> newCategory(String name) => db.catalogDao.insertCategory(
    CategoriesCompanion.insert(name: name, businessId: businessId),
  );

  // Inserts a product directly (bypassing the sync queue) so queue assertions
  // only observe rows the method under test enqueues.
  Future<String> newProduct({required String name, String? categoryId}) async {
    final id = UuidV7.generate();
    await db.into(db.products).insert(
      ProductsCompanion.insert(
        id: Value(id),
        businessId: businessId,
        name: name,
        categoryId: Value(categoryId),
        retailerPriceKobo: const Value(100000),
      ),
    );
    return id;
  }

  Future<ProductData> productById(String id) =>
      (db.select(db.products)..where((p) => p.id.equals(id))).getSingle();

  Future<CategoryData> categoryById(String id) =>
      (db.select(db.categories)..where((c) => c.id.equals(id))).getSingle();

  // ─── Rename ────────────────────────────────────────────────────────────────

  test('renameCategory updates the local name and full-row enqueues it', () async {
    final id = await newCategory('Sodas');
    await newProduct(name: 'Cola', categoryId: id); // untouched by a rename

    await db.catalogDao.renameCategory(id, name: 'Soft Drinks');

    expect((await categoryById(id)).name, 'Soft Drinks');

    final push = (await getPendingQueue(db))
        .firstWhere((r) => r.actionType == 'categories:upsert');
    final payload = decodePayload(push);
    expect(payload['id'], id);
    expect(payload['name'], 'Soft Drinks');
    // Full-row: the NOT NULL business_id must ride along (else Postgres 23502).
    expect(payload['business_id'], businessId);
    expect(payload['is_deleted'], false);
  });

  test('categoryNameExists is case-insensitive, trims, and honours excludeId',
      () async {
    final sodas = await newCategory('Sodas');
    await newCategory('Water');

    // Collision detection (case-insensitive + trimmed).
    expect(await db.catalogDao.categoryNameExists('sodas'), isTrue);
    expect(await db.catalogDao.categoryNameExists('  WATER '), isTrue);
    expect(await db.catalogDao.categoryNameExists('Juice'), isFalse);

    // Renaming a category to its own (differently-cased) name is not a
    // collision — it excludes itself.
    expect(
      await db.catalogDao.categoryNameExists('SODAS', excludeId: sodas),
      isFalse,
    );
    // But a name owned by a *different* category still collides.
    expect(
      await db.catalogDao.categoryNameExists('Water', excludeId: sodas),
      isTrue,
    );
  });

  test('a soft-deleted category is not a collision (its name is freed)', () async {
    final id = await newCategory('Seasonal');
    await db.catalogDao.softDeleteCategoryAndReassign(id);
    expect(await db.catalogDao.categoryNameExists('Seasonal'), isFalse);
  });

  // ─── Count ───────────────────────────────────────────────────────────────

  test('countProductsInCategory counts only live products in that category',
      () async {
    final sodas = await newCategory('Sodas');
    final water = await newCategory('Water');
    await newProduct(name: 'Cola', categoryId: sodas);
    await newProduct(name: 'Fanta', categoryId: sodas);
    await newProduct(name: 'Aqua', categoryId: water); // other category
    await newProduct(name: 'Loose', categoryId: null); // uncategorized

    // A soft-deleted product in the category is excluded from the count.
    final deletedId = await newProduct(name: 'Old', categoryId: sodas);
    await (db.update(db.products)..where((p) => p.id.equals(deletedId)))
        .write(const ProductsCompanion(isDeleted: Value(true)));

    expect(await db.catalogDao.countProductsInCategory(sodas), 2);
    expect(await db.catalogDao.countProductsInCategory(water), 1);
  });

  // ─── Soft-delete + reassign ────────────────────────────────────────────────

  test('softDeleteCategoryAndReassign tombstones the category, moves its '
      'products to null, leaves others alone, and returns the count', () async {
    final sodas = await newCategory('Sodas');
    final water = await newCategory('Water');
    final cola = await newProduct(name: 'Cola', categoryId: sodas);
    final fanta = await newProduct(name: 'Fanta', categoryId: sodas);
    final aqua = await newProduct(name: 'Aqua', categoryId: water);

    final moved = await db.catalogDao.softDeleteCategoryAndReassign(sodas);
    expect(moved, 2);

    // Category tombstoned locally.
    expect((await categoryById(sodas)).isDeleted, isTrue);
    // Its products are now Uncategorized; the other category is untouched.
    expect((await productById(cola)).categoryId, isNull);
    expect((await productById(fanta)).categoryId, isNull);
    expect((await productById(aqua)).categoryId, water);
  });

  test('reassignment pushes an EXPLICIT category_id: null so the cloud clears '
      'it (not dropped as Value.absent), plus the category tombstone', () async {
    final sodas = await newCategory('Sodas');
    final cola = await newProduct(name: 'Cola', categoryId: sodas);

    await db.catalogDao.softDeleteCategoryAndReassign(sodas);

    final queue = await getPendingQueue(db);

    final productPush = queue.firstWhere(
      (r) => r.actionType == 'products:upsert' && decodePayload(r)['id'] == cola,
    );
    final productPayload = decodePayload(productPush);
    // The key must be present AND null — an absent key leaves the stale FK on
    // the cloud (the whole point of the copyWith(Value(null)) override).
    expect(productPayload.containsKey('category_id'), isTrue);
    expect(productPayload['category_id'], isNull);
    expect(productPayload['name'], 'Cola'); // NOT NULL rides along
    expect(productPayload['business_id'], businessId);

    final catPush = queue.firstWhere(
      (r) => r.actionType == 'categories:upsert',
    );
    expect(decodePayload(catPush)['is_deleted'], true);
  });

  // ─── Reactive read ───────────────────────────────────────────────────────

  test('watchAllCategories excludes a soft-deleted category', () async {
    final sodas = await newCategory('Sodas');
    final water = await newCategory('Water');

    await db.catalogDao.softDeleteCategoryAndReassign(sodas);

    final live = await db.inventoryDao.watchAllCategories().first;
    final ids = live.map((c) => c.id).toList();
    expect(ids, contains(water));
    expect(ids, isNot(contains(sodas)));
  });
}
