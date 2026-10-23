// Sample data for the Product Details tests and goldens (#487 PR 3): Gulder as
// a Bottle Crate of 12 with prices, a description and a monthly target, stocked
// in Main Store (4, low) and a second store (28). Made-up names only.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/inventory/data/models/inventory_item.dart';

import 'inventory_seed.dart';
import 'screen_harness.dart';

class DetailSample {
  DetailSample({required this.productId, required this.warehouseId});

  final String productId;
  final String warehouseId;
}

Future<DetailSample> seedDetailSample(
  ScreenTestEnvironment env,
  InventorySample sample, {
  int costKobo = 1350000,
  int retailKobo = 1500000,
  int wholesaleKobo = 1420000,
  int targetUnits = 200,
  int? unitsPerPack = 12,
  String? description =
      'Lager beer in 60cl returnable glass bottles, sold by the crate.',
  String? barcode,
  bool archived = false,
  String businessType = 'Beverage distributor',
  bool tracksCrates = true,
}) async {
  final db = env.db;
  // Crate wording ("Bottle Crate", "crates") is for a shop that counts empty
  // crates; a pharmacy or such reads plain "Bottle" / "bottles".
  await (db.update(
    db.businesses,
  )..where((b) => b.id.equals(env.businessId))).write(
    BusinessesCompanion(
      type: Value(businessType),
      tracksEmptyCrates: Value(tracksCrates),
    ),
  );
  final productId = sample.productIds['Gulder']!;
  await (db.update(db.products)..where((p) => p.id.equals(productId))).write(
    ProductsCompanion(
      buyingPriceKobo: Value(costKobo),
      retailerPriceKobo: Value(retailKobo),
      wholesalerPriceKobo: Value(wholesaleKobo),
      monthlyTargetUnits: Value(targetUnits),
      unitsPerPack: Value(unitsPerPack),
      subtitle: Value(description),
      barcode: Value(barcode),
      isAvailable: Value(!archived),
    ),
  );
  // The signed-in test user, so the activity log's staff link resolves.
  await db
      .into(db.users)
      .insert(
        UsersCompanion.insert(
          id: const Value('test-user-id'),
          businessId: env.businessId,
          name: 'Test Admin',
          pin: '1234',
        ),
      );
  final warehouseId = UuidV7.generate();
  await db
      .into(db.stores)
      .insert(
        StoresCompanion.insert(
          id: Value(warehouseId),
          businessId: env.businessId,
          name: 'Warehouse',
        ),
      );
  await db
      .into(db.inventory)
      .insert(
        InventoryCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: env.businessId,
          storeId: warehouseId,
          productId: productId,
          quantity: const Value(28),
        ),
      );
  return DetailSample(productId: productId, warehouseId: warehouseId);
}

/// The list row the screen is opened from (Inventory builds the same).
InventoryItem detailItemFor(
  ScreenTestEnvironment env,
  InventorySample sample, {
  String name = 'Gulder',
}) {
  return InventoryItem(
    id: sample.productIds[name]!,
    productName: name,
    subtitle: '60cl',
    icon: Icons.local_drink,
    color: Colors.blue,
    storeStock: {env.storeId: 4},
    lowStockThreshold: 5,
    unit: 'Bottle',
    manufacturer: 'Nigerian Breweries',
  );
}
