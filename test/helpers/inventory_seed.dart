// Sample Inventory data for the #392 goldens and widget tests: business
// "Stallion Global", store "Abuja HQ", made-up people. Run after
// `setupScreenTestEnvironment(productCount: 0, businessType: 'Beverage
// distributor')`.

import 'package:drift/drift.dart' show Value;

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import 'screen_harness.dart';

/// Every permission the Inventory screen's tabs and actions read.
const kInventorySampleGrants = <String>{
  'sales.make',
  'stock.view',
  'products.add',
  'stock.add',
  'stock.adjust',
  'products.edit_price',
  'suppliers.manage',
};

/// What [seedInventorySample] created, for tests that need the ids.
class InventorySample {
  InventorySample({
    required this.productIds,
    required this.manufacturerIds,
    required this.staffId,
  });

  final Map<String, String> productIds;
  final Map<String, String> manufacturerIds;
  final String staffId;
}

Future<InventorySample> seedInventorySample(ScreenTestEnvironment env) async {
  final db = env.db;
  final b = env.businessId;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  await db.customStatement(
    "UPDATE stores SET name = 'Abuja HQ' WHERE id = '${env.storeId}'",
  );
  // The harness's own category is renamed rather than left as "Drinks".
  await db.customStatement(
    "UPDATE categories SET name = 'Beer' WHERE id = '${env.categoryId}'",
  );
  final categoryIds = <String, String>{'Beer': env.categoryId};
  for (final name in const ['Stout', 'Malt', 'Soft Drinks', 'Water']) {
    final id = UuidV7.generate();
    await db
        .into(db.categories)
        .insert(
          CategoriesCompanion.insert(id: Value(id), businessId: b, name: name),
        );
    categoryIds[name] = id;
  }

  final manufacturerIds = <String, String>{};
  for (final (name, kobo) in const [
    ('Nigerian Breweries', 120000),
    ('Guinness Nigeria', 150000),
    ('Coca-Cola HBC', 0),
  ]) {
    final id = UuidV7.generate();
    await db
        .into(db.manufacturers)
        .insert(
          ManufacturersCompanion.insert(
            id: Value(id),
            businessId: b,
            name: name,
            depositAmountKobo: Value(kobo),
          ),
        );
    manufacturerIds[name] = id;
  }

  final productIds = <String, String>{};
  for (final (name, category, manufacturer, unit, stock, subtitle, expiryInDays)
      in <(String, String, String?, String?, int, String?, int?)>[
        (
          'Star Lager',
          'Beer',
          'Nigerian Breweries',
          'Bottle',
          38,
          '60cl',
          null,
        ),
        ('Gulder', 'Beer', 'Nigerian Breweries', 'Bottle', 4, '60cl', null),
        (
          'Guinness Foreign Extra',
          'Stout',
          'Guinness Nigeria',
          'Bottle',
          18,
          '60cl',
          null,
        ),
        ('Malta Guinness', 'Malt', 'Guinness Nigeria', 'Can', 0, '33cl', null),
        ('Coca-Cola', 'Soft Drinks', 'Coca-Cola HBC', 'PET', 52, '50cl', null),
        ('Eva Water', 'Water', null, 'PET', 60, '75cl', 10),
      ]) {
    final id = UuidV7.generate();
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: Value(id),
            businessId: b,
            categoryId: Value(categoryIds[category]),
            manufacturerId: Value(
              manufacturer == null ? null : manufacturerIds[manufacturer],
            ),
            name: name,
            subtitle: Value(subtitle),
            unit: Value(unit),
            trackEmpties: Value(unit == 'Bottle'),
            retailerPriceKobo: const Value(60000),
            wholesalerPriceKobo: const Value(55000),
            expiryDate: Value(
              expiryInDays == null
                  ? null
                  : today.add(Duration(days: expiryInDays)),
            ),
          ),
        );
    await db
        .into(db.inventory)
        .insert(
          InventoryCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: b,
            storeId: env.storeId,
            productId: id,
            quantity: Value(stock),
          ),
        );
    productIds[name] = id;
  }

  final staffId = UuidV7.generate();
  await db
      .into(db.users)
      .insert(
        UsersCompanion.insert(
          id: Value(staffId),
          businessId: b,
          name: 'Amaka Obi',
          pin: '123456',
        ),
      );

  for (final (mfr, empties) in const [
    ('Nigerian Breweries', 20),
    ('Guinness Nigeria', 12),
  ]) {
    await db.cratePoolDao.recordManualCountCorrection(
      manufacturerId: manufacturerIds[mfr]!,
      storeId: env.storeId,
      performedBy: staffId,
      countedEmpties: empties,
    );
  }

  for (final (name, phone) in const [
    ('Kano Distributors', '0803 111 2222'),
    ('Lagos Beverages Ltd', '0809 333 4444'),
  ]) {
    await db
        .into(db.suppliers)
        .insert(
          SuppliersCompanion.insert(
            businessId: b,
            name: name,
            phone: Value(phone),
          ),
        );
  }

  // Stock movements for the History tab, minutes ago so the relative date
  // ("5m") is the same on every run.
  for (final (product, delta, type, minutesAgo) in const [
    ('Star Lager', 24, 'purchase_received', 5),
    ('Gulder', -2, 'adjustment', 12),
    ('Coca-Cola', -6, 'damage', 25),
  ]) {
    final at = now.subtract(Duration(minutes: minutesAgo));
    final adjustmentId = UuidV7.generate();
    await db
        .into(db.stockAdjustments)
        .insert(
          StockAdjustmentsCompanion.insert(
            id: Value(adjustmentId),
            businessId: b,
            productId: productIds[product]!,
            storeId: env.storeId,
            quantityDiff: delta,
            reason: 'Sample',
            performedBy: Value(staffId),
            createdAt: Value(at),
            lastUpdatedAt: Value(at),
          ),
        );
    await db
        .into(db.stockTransactions)
        .insert(
          StockTransactionsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: b,
            productId: productIds[product]!,
            locationId: env.storeId,
            quantityDelta: delta,
            movementType: type,
            adjustmentId: Value(adjustmentId),
            performedBy: Value(staffId),
            createdAt: Value(at),
            lastUpdatedAt: Value(at),
          ),
        );
  }

  return InventorySample(
    productIds: productIds,
    manufacturerIds: manufacturerIds,
    staffId: staffId,
  );
}
