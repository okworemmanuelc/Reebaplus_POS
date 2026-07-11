import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/product_name.dart';
import 'package:drift/drift.dart' hide isNull;

/// Optional product units (#108). A product may have NO unit; when absent it
/// renders nothing anywhere and crate-eligibility treats it as "not a bottle".
/// These tests pin the three behaviours the acceptance criteria call out:
///   • a null unit PERSISTS (insert + clear-on-edit) — no silent 'Bottle',
///   • a null unit RENDERS as absent (the shared display helper), and
///   • the crate gate treats a null unit as NON-bottle.
void main() {
  group('productDisplayName renders an absent unit as nothing (#108)', () {
    test('a null unit shows just the name', () {
      expect(productDisplayName('Goldberg', null, unit: null), 'Goldberg');
    });

    test('a null unit still keeps the size abbreviation', () {
      expect(productDisplayName('Goldberg', 'big', unit: null), 'Goldberg (B)');
    });

    test('an empty-string unit is treated as absent', () {
      expect(productDisplayName('Goldberg', null, unit: ''), 'Goldberg');
    });

    test('a present unit is still prepended', () {
      expect(
        productDisplayName('Goldberg', null, unit: 'Bottle'),
        'Bottle Goldberg',
      );
    });
  });

  group('CatalogDao — a null unit persists (#108)', () {
    late AppDatabase db;
    const businessId = 'biz-1';

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      db.businessIdResolver = () => businessId;
      await db.into(db.businesses).insert(
            BusinessesCompanion.insert(
              id: const Value(businessId),
              name: 'Test Biz',
            ),
          );
    });

    tearDown(() async => db.close());

    test('a product saved with no unit reads back null', () async {
      final id = await db.catalogDao.insertProduct(
        const ProductsCompanion(
          businessId: Value(businessId),
          name: Value('Just A Name'),
          unit: Value(null),
        ),
      );

      final row = await (db.select(db.products)
            ..where((t) => t.id.equals(id)))
          .getSingle();
      expect(row.unit, isNull);
    });

    test('clearing a unit on edit persists null (not "leave untouched")',
        () async {
      final id = await db.catalogDao.insertProduct(
        const ProductsCompanion(
          businessId: Value(businessId),
          name: Value('Was Bottled'),
          unit: Value('Bottle'),
        ),
      );

      // The edit form passes the field's current value; a cleared field is an
      // explicit null, which must CLEAR the column rather than skip it.
      await db.catalogDao.updateProductDetails(
        id,
        name: 'Was Bottled',
        buyingPriceKobo: 0,
        retailerPriceKobo: 1000,
        wholesalerPriceKobo: 1000,
        unit: null,
      );

      final row = await (db.select(db.products)
            ..where((t) => t.id.equals(id)))
          .getSingle();
      expect(row.unit, isNull);
    });

    test('omitting unit on edit leaves the existing unit untouched', () async {
      final id = await db.catalogDao.insertProduct(
        const ProductsCompanion(
          businessId: Value(businessId),
          name: Value('Keeps Its Unit'),
          unit: Value('Can'),
        ),
      );

      // No `unit:` argument → the sentinel default → the column is not written.
      await db.catalogDao.updateProductDetails(
        id,
        name: 'Keeps Its Unit',
        buyingPriceKobo: 0,
        retailerPriceKobo: 1000,
        wholesalerPriceKobo: 1000,
      );

      final row = await (db.select(db.products)
            ..where((t) => t.id.equals(id)))
          .getSingle();
      expect(row.unit, 'Can');
    });

    test('getUniqueProductUnits skips the null unit', () async {
      await db.catalogDao.insertProduct(
        const ProductsCompanion(
          businessId: Value(businessId),
          name: Value('Bottled'),
          unit: Value('Bottle'),
        ),
      );
      await db.catalogDao.insertProduct(
        const ProductsCompanion(
          businessId: Value(businessId),
          name: Value('Unitless'),
          unit: Value(null),
        ),
      );

      final units = await db.catalogDao.getUniqueProductUnits();
      expect(units, contains('Bottle'));
      expect(units, isNot(contains(null)));
    });
  });

  group('crate-eligibility treats a null unit as not-a-bottle (#108)', () {
    late AppDatabase db;
    const businessId = 'biz-1';
    const storeId = 'store-1';
    const manufacturerId = 'mfr-1';

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      db.businessIdResolver = () => businessId;
      await db.into(db.businesses).insert(
            BusinessesCompanion.insert(
              id: const Value(businessId),
              name: 'Test Biz',
            ),
          );
      await db.into(db.stores).insert(
            StoresCompanion.insert(
              id: const Value(storeId),
              businessId: businessId,
              name: 'Main',
            ),
          );
      await db.into(db.manufacturers).insert(
            ManufacturersCompanion.insert(
              id: const Value(manufacturerId),
              businessId: businessId,
              name: 'Test Mfr',
            ),
          );
    });

    tearDown(() async => db.close());

    test('a unitless tracked product is excluded from the full-crate count',
        () async {
      // Both products are tracked and share a manufacturer; only the Bottle is
      // a bottle. The unitless product must NOT count toward full crates.
      final bottleId = await db.catalogDao.insertProduct(
        const ProductsCompanion(
          businessId: Value(businessId),
          name: Value('Bottled Water'),
          unit: Value('Bottle'),
          manufacturerId: Value(manufacturerId),
          trackEmpties: Value(true),
        ),
      );
      final unitlessId = await db.catalogDao.insertProduct(
        const ProductsCompanion(
          businessId: Value(businessId),
          name: Value('Unitless Item'),
          unit: Value(null),
          manufacturerId: Value(manufacturerId),
          trackEmpties: Value(true),
        ),
      );

      await db.into(db.inventory).insert(
            InventoryCompanion.insert(
              businessId: businessId,
              productId: bottleId,
              storeId: storeId,
              quantity: const Value(12),
            ),
          );
      await db.into(db.inventory).insert(
            InventoryCompanion.insert(
              businessId: businessId,
              productId: unitlessId,
              storeId: storeId,
              quantity: const Value(7),
            ),
          );

      final crates =
          await db.inventoryDao.watchFullCratesByManufacturer().first;
      // 12 (the Bottle) only — the unitless product's 7 is excluded, proving a
      // null unit is treated as not-a-bottle.
      expect(crates[manufacturerId], 12);
    });
  });
}
