// cart_tier_pricing_test.dart
//
// Regression net for the wholesaler-tier price bug (Ring 0, pivot §8.0).
//
// Before the fix, CartService.addItem unconditionally seeded the RETAILER
// price, and OrdersDao.checkCartStaleness re-priced every line against the
// retailer column — so a wholesale customer was shown the wholesale price but
// charged retailer, and any wholesaler line was silently reverted to retailer
// at checkout staleness. These tests pin both halves:
//   (a)/(b) addItem seeds the price for the SELECTED tier;
//   (c) checkCartStaleness re-prices against the line's OWN tier, never retailer;
//   (d) a wholesaler customer's tier prices the line at wholesale;
//   (e) a per-line discount clamps against the (correct) wholesaler line total.

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/services/cart_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';

const int _retailerKobo = 100000; // ₦1,000.00
const int _wholesalerKobo = 80000; // ₦800.00

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
          BusinessesCompanion.insert(id: Value(businessId), name: 'Tier Biz'),
        );

    productId = UuidV7.generate();
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: Value(productId),
            businessId: businessId,
            name: 'Test Beer',
            retailerPriceKobo: const Value(_retailerKobo),
            wholesalerPriceKobo: const Value(_wholesalerKobo),
          ),
        );

    // CartService only needs AuthService for currentUser?.id; with nobody
    // signed in, _uid falls back to '' (a valid cart key). Constructing
    // AuthService repoints db.businessIdResolver at value?.businessId (null),
    // so re-point it at the seeded business for the business-scoped DAO query.
    final client = Supabase.instance.client;
    final nav = NavigationService();
    final auth = AuthService(
      db,
      nav,
      SecureStorageService(),
      SupabaseSyncService(db, client),
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

  test('(a) addItem seeds the wholesaler price when tier is wholesaler',
      () async {
    final p = await readProduct();
    final accepted = cart.addItem(p, tier: PriceTier.wholesaler);
    expect(accepted, isTrue);
    final line = cart.value.single;
    expect(line['unitPriceKobo'], _wholesalerKobo);
    expect(line['price'], _wholesalerKobo / 100.0);
    expect(line['priceTier'], 'wholesaler');
  });

  test('(b) addItem seeds the retailer price by default', () async {
    final p = await readProduct();
    cart.addItem(p); // default tier
    final line = cart.value.single;
    expect(line['unitPriceKobo'], _retailerKobo);
    expect(line['priceTier'], 'retailer');
  });

  test('(b2) addItem seeds the retailer price when tier is retailer', () async {
    final p = await readProduct();
    cart.addItem(p, tier: PriceTier.retailer);
    expect(cart.value.single['unitPriceKobo'], _retailerKobo);
  });

  test(
      '(c) checkCartStaleness re-prices a wholesaler line against the '
      'wholesaler column, never retailer', () async {
    final p = await readProduct();

    // A wholesaler line correctly priced at the wholesale price must NOT be
    // flagged stale (the old retailer-hardcoded check would have flagged it
    // and offered to "fix" it down to retailer).
    final wholesaleLine = CartLineSnapshot(
      productId: productId,
      cartVersion: p.version,
      cartUnitPriceKobo: _wholesalerKobo,
      priceTier: 'wholesaler',
    );
    expect(await db.ordersDao.checkCartStaleness([wholesaleLine]), isEmpty);

    // A retailer line at the retail price is likewise clean.
    final retailLine = CartLineSnapshot(
      productId: productId,
      cartVersion: p.version,
      cartUnitPriceKobo: _retailerKobo,
    );
    expect(await db.ordersDao.checkCartStaleness([retailLine]), isEmpty);

    // Bump ONLY the wholesaler price; the UPDATE trigger bumps version too.
    await (db.update(db.products)..where((q) => q.id.equals(productId)))
        .write(const ProductsCompanion(wholesalerPriceKobo: Value(90000)));

    final stale = await db.ordersDao.checkCartStaleness([wholesaleLine]);
    expect(stale, hasLength(1));
    // The new price is the WHOLESALER price (90000), not the retailer 100000.
    expect(stale.single.newPriceKobo, 90000);
  });

  test('(d) a wholesaler customer\'s tier prices the line at wholesale',
      () async {
    // In production pos_controller._onCustomerSelected copies the selected
    // customer's priceTier into selectedGroup, which _addToCart passes as
    // `tier`. This pins the CartService boundary of that flow.
    final p = await readProduct();
    final customer = Customer(
      id: 'c1',
      name: 'Bulk Buyer',
      addressText: 'x',
      googleMapsLocation: 'x',
      priceTier: PriceTier.wholesaler,
    );
    cart.addItem(p, tier: customer.priceTier);
    expect(cart.value.single['unitPriceKobo'], _wholesalerKobo);
  });

  test('(e) per-line discount clamps against the wholesaler line total',
      () async {
    final p = await readProduct();
    cart.addItem(p, tier: PriceTier.wholesaler); // line total 80000
    // Attempt a ₦900 discount (90000 kobo) — between wholesale (80000) and
    // retail (100000). It must clamp to the wholesale line total. If the line
    // had been mispriced at retailer, the clamp ceiling would be 90000.
    cart.setLineDiscount(
      p.name,
      kind: 'naira',
      enteredValue: 900,
      discountKobo: 90000,
    );
    expect(cart.value.single['discountKobo'], _wholesalerKobo);
  });
}
