import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/receiving/screens/receive_stock_screen.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';

import '../helpers/screen_harness.dart';

/// Sample data for the Receive Stock tests and goldens (#394): business
/// "Stallion Global", store "Abuja HQ", four categories and five products in
/// that store — one with a long name, one low, one out of stock.
class ReceiveFixture {
  ReceiveFixture._(
    this.env,
    this.categories,
    this.productIds,
    this.products,
    this.supplierId,
  );

  final ScreenTestEnvironment env;

  /// Category name → id.
  final Map<String, String> categories;

  /// Star Lager, Malta Guinness, the long Guinness, Eva Water, Hero Lager (0).
  final List<String> productIds;

  /// The same products, as rows (to put on the receive cart).
  final List<ProductData> products;

  /// "Lagos Beverages Ltd", the one supplier.
  final String supplierId;

  static Future<ReceiveFixture> create() async {
    final env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
    );
    final db = env.db;
    await db.customStatement(
      "UPDATE stores SET name = 'Abuja HQ' WHERE id = '${env.storeId}'",
    );
    final supplierId = UuidV7.generate();
    await db
        .into(db.suppliers)
        .insert(
          SuppliersCompanion.insert(
            id: Value(supplierId),
            businessId: env.businessId,
            name: 'Lagos Beverages Ltd',
          ),
        );
    // Star Lager moves crates on a receipt (bottle + tracks empties + a
    // manufacturer), so the checkout shows its crate row.
    final manufacturerId = UuidV7.generate();
    await db
        .into(db.manufacturers)
        .insert(
          ManufacturersCompanion.insert(
            id: Value(manufacturerId),
            businessId: env.businessId,
            name: 'Nigerian Breweries',
          ),
        );
    final categories = <String, String>{};
    for (final name in ['Beer', 'Malt', 'Water', 'Stout']) {
      final id = UuidV7.generate();
      await db
          .into(db.categories)
          .insert(
            CategoriesCompanion.insert(
              id: Value(id),
              businessId: env.businessId,
              name: name,
            ),
          );
      categories[name] = id;
    }
    final ids = <String>[];
    // `size` is the crate size category (big / medium / small), which the
    // tile shows before the unit, as before; the volume is the description.
    for (final (name, category, volume, size, unit, stock) in [
      ('Star Lager', 'Beer', '60cl', 'big', 'Bottle', 48),
      ('Malta Guinness', 'Malt', '33cl', null, 'Can', 4),
      (
        'Guinness Foreign Extra Stout Big Bottle Party Pack',
        'Stout',
        '60cl',
        'big',
        'Bottle',
        120,
      ),
      ('Eva Water', 'Water', '75cl', null, 'Bottle', 36),
      ('Hero Lager', 'Beer', '60cl', 'medium', 'Bottle', 0),
    ]) {
      final id = UuidV7.generate();
      await db
          .into(db.products)
          .insert(
            ProductsCompanion.insert(
              id: Value(id),
              businessId: env.businessId,
              name: name,
              categoryId: Value(categories[category]),
              subtitle: Value(volume),
              size: Value(size),
              manufacturerId: Value(
                name == 'Star Lager' ? manufacturerId : null,
              ),
              trackEmpties: Value(name == 'Star Lager'),
              unit: Value(unit),
              buyingPriceKobo: const Value(750000),
              retailerPriceKobo: const Value(960000),
              wholesalerPriceKobo: const Value(900000),
            ),
          );
      await db
          .into(db.inventory)
          .insert(
            InventoryCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: env.businessId,
              storeId: env.storeId,
              productId: id,
              quantity: Value(stock),
            ),
          );
      ids.add(id);
    }
    final products = [
      for (final id in ids)
        await (db.select(
          db.products,
        )..where((t) => t.id.equals(id))).getSingle(),
    ];
    return ReceiveFixture._(env, categories, ids, products, supplierId);
  }

  /// Soft-deletes category [name] through Drift, so watchers fire (as a
  /// synced delete would).
  Future<void> deleteCategory(String name) =>
      (env.db.update(env.db.categories)
            ..where((t) => t.id.equals(categories[name]!)))
          .write(const CategoriesCompanion(isDeleted: Value(true)));

  /// The receipt quantity of product [index] (0 when not on it).
  int cartQty(WidgetTester tester, int index) {
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReceiveStockScreen)),
    );
    return container
            .read(receiveCartProvider)
            .where((l) => l.productId == productIds[index])
            .firstOrNull
            ?.qty ??
        0;
  }
}
