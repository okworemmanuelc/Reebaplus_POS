// cart_custom_price_test.dart
//
// Pins the per-line custom-price feature (§13.4): a user holding
// `sales.set_custom_price` may sell a cart line at a price other than its
// designated selling price. These tests cover the CartService boundary —
// the permission gate itself lives in EditItemModal.
//
//   (a) setCustomPrice overrides the effective unit price and marks the line;
//   (b) the catalog reference is preserved and clearing reverts to it;
//   (c) a per-line discount clamps against the (lower) custom line total;
//   (d) refreshProduct keeps the custom price but refreshes the catalog ref;
//   (e) a non-positive custom price is treated as "clear".

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/services/cart_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';

const int _retailerKobo = 100000; // ₦1,000.00

void main() {
  late AppDatabase db;
  late CartService cart;
  late String businessId;
  late String productId;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://placeholder.supabase.co',
      anonKey: 'placeholder',
    );
  });

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());

    businessId = UuidV7.generate();
    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(id: Value(businessId), name: 'Custom Biz'),
        );

    productId = UuidV7.generate();
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: Value(productId),
            businessId: businessId,
            name: 'Test Beer',
            retailerPriceKobo: const Value(_retailerKobo),
          ),
        );

    final client = Supabase.instance.client;
    final nav = NavigationService();
    final auth = AuthService(
      db,
      nav,
      SecureStorageService(),
      SupabaseSyncService(db, SupabaseCloudTransport(client)),
      client,
    );
    cart = CartService(auth, nav);
    db.businessIdResolver = () => businessId;
  });

  tearDown(() async {
    await db.close();
  });

  Future<ProductData> readProduct() =>
      (db.select(db.products)..where((p) => p.id.equals(productId)))
          .getSingle();

  test('(a) setCustomPrice overrides the effective unit price and marks the line',
      () async {
    final p = await readProduct();
    cart.addItem(p); // retailer 100000
    cart.setCustomPrice(p.name, customPriceKobo: 75000, maxPercent: 50); // ₦750

    final line = cart.value.single;
    expect(line['customPriceKobo'], 75000);
    expect(line['unitPriceKobo'], 75000);
    expect(line['price'], 750.0);
    // The designated catalog price is untouched.
    expect(line['catalogPriceKobo'], _retailerKobo);
  });

  test('(b) clearing the custom price reverts to the catalog price', () async {
    final p = await readProduct();
    cart.addItem(p);
    cart.setCustomPrice(p.name, customPriceKobo: 75000, maxPercent: 50);
    cart.setCustomPrice(p.name, customPriceKobo: null, maxPercent: 50);

    final line = cart.value.single;
    expect(line['customPriceKobo'], isNull);
    expect(line['unitPriceKobo'], _retailerKobo);
    expect(line['price'], _retailerKobo / 100.0);
  });

  test('(c) a per-line discount clamps against the custom line total', () async {
    final p = await readProduct();
    cart.addItem(p); // qty 1
    cart.setCustomPrice(p.name, customPriceKobo: 50000, maxPercent: 50); // ₦500 line total
    // Attempt a ₦700 discount — more than the custom line total. It must clamp
    // to 50000, never produce a negative net.
    cart.setLineDiscount(
      p.name,
      kind: 'naira',
      enteredValue: 700,
      discountKobo: 70000,
    );
    expect(cart.value.single['discountKobo'], 50000);
  });

  test('(d) refreshProduct keeps the custom price and refreshes the catalog ref',
      () async {
    final p = await readProduct();
    cart.addItem(p);
    cart.setCustomPrice(p.name, customPriceKobo: 75000, maxPercent: 50);

    // Simulate a product edit that bumps the designated price to ₦1,200.
    cart.refreshProduct(
      productId: productId,
      name: p.name,
      price: 1200.0,
      emptyCrateValueKobo: 0,
      unitPriceKobo: 120000,
      version: (p.version) + 1,
    );

    final line = cart.value.single;
    // Custom price stands; only the catalog reference tracks the new price.
    expect(line['customPriceKobo'], 75000);
    expect(line['unitPriceKobo'], 75000);
    expect(line['catalogPriceKobo'], 120000);
  });

  test('(e) a non-positive custom price is treated as clear', () async {
    final p = await readProduct();
    cart.addItem(p);
    cart.setCustomPrice(p.name, customPriceKobo: 0, maxPercent: 50);

    final line = cart.value.single;
    expect(line['customPriceKobo'], isNull);
    expect(line['unitPriceKobo'], _retailerKobo);
  });

  test('(f) custom price below floor is clamped to floor (maxPercent > 0)', () async {
    final p = await readProduct();
    cart.addItem(p); // 100000 (₦1,000)
    // maxPercent = 10% -> floor = 90000. Try setting 85000.
    cart.setCustomPrice(p.name, customPriceKobo: 85000, maxPercent: 10);

    final line = cart.value.single;
    expect(line['customPriceKobo'], 90000);
    expect(line['unitPriceKobo'], 90000);
    expect(line['price'], 900.0);
  });

  test('(g) maxPercent == 0 -> floor == catalog -> any below-catalog custom price clamps to catalog', () async {
    final p = await readProduct();
    cart.addItem(p); // 100000
    // maxPercent = 0% -> floor = 100000. Try setting 95000.
    cart.setCustomPrice(p.name, customPriceKobo: 95000, maxPercent: 0);

    final line = cart.value.single;
    expect(line['customPriceKobo'], 100000);
    expect(line['unitPriceKobo'], 100000);
    expect(line['price'], 1000.0);
  });

  test('(h) Option A: custom price at floor + attempted max discount does not dip below floor', () async {
    final p = await readProduct();
    cart.addItem(p); // 100000
    // maxPercent = 10% -> floor = 90000. Set custom price to 90000.
    cart.setCustomPrice(p.name, customPriceKobo: 90000, maxPercent: 10);
    
    // Attempt 10% discount on the new custom line total (90000 * 1 = 90000).
    // 10% of 90000 is 9000.
    // However, since custom price is already at floor, the max allowed discount kobo is:
    // (90000 - 90000) * 1 = 0.
    // So the discount is clamped to 0.
    cart.setLineDiscount(
      p.name,
      kind: 'percent',
      enteredValue: 10,
      discountKobo: 9000,
      maxPercent: 10,
    );

    final line = cart.value.single;
    expect(line['discountKobo'], 0);
    expect(line['unitPriceKobo'], 90000);
    final netTotal = (line['unitPriceKobo'] * line['qty']) - line['discountKobo'];
    expect(netTotal, 90000); // respects floor
  });

  test('(i) custom price above catalog is allowed unchanged (overpricing is fine)', () async {
    final p = await readProduct();
    cart.addItem(p); // 100000
    // maxPercent = 10% -> floor = 90000. Try setting 120000.
    cart.setCustomPrice(p.name, customPriceKobo: 120000, maxPercent: 10);

    final line = cart.value.single;
    expect(line['customPriceKobo'], 120000);
    expect(line['unitPriceKobo'], 120000);
    expect(line['price'], 1200.0);
  });
}
