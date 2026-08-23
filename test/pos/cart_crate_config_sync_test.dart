// cart_crate_config_sync_test.dart
//
// Pins the cart's crate configuration against the catalogue. A cart line
// snapshots its crate fields when the product is tapped in, but the write side
// never trusted that snapshot — `createOrder` re-reads the product and
// `manufacturers.deposit_amount_kobo` when it books the crate ledger. Left
// alone, the cart quotes one deposit and the sale books another.
//
//   (a) a brand deposit edited after the line was added flows into the cart;
//   (b) the MANUFACTURER rate wins over the stale products mirror;
//   (c) a product with no manufacturer falls back to its own crate value;
//   (d) trackEmpties / unit toggles reach the line, not just the money;
//   (e) an unconfigured brand resolves to 0 — what the cart's banner keys on;
//   (f) a mixed cart only touches the products it resolved;
//   (g) syncCrateConfig reports "nothing moved" so listeners cannot loop;
//   (h) qty, discounts and custom prices survive a sync;
//   (i) CartCrateSync reconciles live, without the cart being rebuilt;
//   (j) a correction to a PARKED store's cart does not interrupt the cashier.

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
import 'package:reebaplus_pos/shared/services/cart_crate_sync.dart';
import 'package:reebaplus_pos/shared/services/cart_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';

const int _retailerKobo = 100000; // ₦1,000.00
const int _openingDepositKobo = 50000; // ₦500.00 per crate
const int _raisedDepositKobo = 80000; // ₦800.00 per crate

void main() {
  late AppDatabase db;
  late CartService cart;
  late CartCrateSync sync;
  late NavigationService nav;
  late String businessId;
  late String brandId;
  late String beerId;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://placeholder.supabase.co',
      anonKey: 'placeholder',
    );
  });

  /// A bottle product that tracks empties, optionally tied to [manufacturerId].
  /// [mirrorKobo] seeds `products.empty_crate_value_kobo` — the mirror written
  /// at product save, which is exactly what goes stale.
  Future<String> insertBottle({
    required String name,
    String? manufacturerId,
    int mirrorKobo = 0,
    bool trackEmpties = true,
    String? unit = 'Bottle',
  }) async {
    final id = UuidV7.generate();
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: Value(id),
            businessId: businessId,
            name: name,
            unit: Value(unit),
            retailerPriceKobo: const Value(_retailerKobo),
            manufacturerId: Value(manufacturerId),
            emptyCrateValueKobo: Value(mirrorKobo),
            trackEmpties: Value(trackEmpties),
          ),
        );
    return id;
  }

  Future<ProductData> readProduct(String id) =>
      (db.select(db.products)..where((p) => p.id.equals(id))).getSingle();

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());

    businessId = UuidV7.generate();
    await db
        .into(db.businesses)
        .insert(
          BusinessesCompanion.insert(id: Value(businessId), name: 'Crate Biz'),
        );

    brandId = UuidV7.generate();
    await db
        .into(db.manufacturers)
        .insert(
          ManufacturersCompanion.insert(
            id: Value(brandId),
            businessId: businessId,
            name: 'Star',
            depositAmountKobo: const Value(_openingDepositKobo),
          ),
        );

    beerId = await insertBottle(
      name: 'Star Lager',
      manufacturerId: brandId,
      mirrorKobo: _openingDepositKobo,
    );

    final client = Supabase.instance.client;
    nav = NavigationService();
    final auth = AuthService(
      db,
      nav,
      SecureStorageService(),
      SupabaseSyncService(db, SupabaseCloudTransport(client)),
      client,
    );
    cart = CartService(auth, nav);
    sync = CartCrateSync(db, cart);
    // AuthService installs its own resolver at construction; override it after
    // so the DAOs scope to this test's business.
    db.businessIdResolver = () => businessId;
  });

  tearDown(() async {
    sync.dispose();
    await db.close();
  });

  test('(a) a brand deposit raised after the line was added reaches the cart',
      () async {
    cart.addItem(await readProduct(beerId));
    expect(cart.value.single['emptyCrateValueKobo'], _openingDepositKobo);

    await db.catalogDao.updateManufacturerEmptyCrateValue(
      brandId,
      _raisedDepositKobo,
    );
    expect(await sync.sync(), isTrue);

    expect(cart.value.single['emptyCrateValueKobo'], _raisedDepositKobo);
  });

  test('(b) the manufacturer rate wins over the stale products mirror',
      () async {
    cart.addItem(await readProduct(beerId));

    // updateManufacturerEmptyCrateValue writes the BRAND only — the product
    // mirror is left behind at the opening figure. That divergence is the bug:
    // the cart used to read the mirror while createOrder read the brand.
    await db.catalogDao.updateManufacturerEmptyCrateValue(
      brandId,
      _raisedDepositKobo,
    );
    expect((await readProduct(beerId)).emptyCrateValueKobo,
        _openingDepositKobo); // mirror is stale

    await sync.sync();
    expect(cart.value.single['emptyCrateValueKobo'], _raisedDepositKobo);
  });

  test('(c) a product with no manufacturer falls back to its own crate value',
      () async {
    final looseId = await insertBottle(name: 'Loose Bottle', mirrorKobo: 12345);
    cart.addItem(await readProduct(looseId));

    await sync.sync();

    final line = cart.value.single;
    expect(line['manufacturerId'], isNull);
    expect(line['emptyCrateValueKobo'], 12345);
  });

  test('(d) trackEmpties and unit edits reach the line, not just the money',
      () async {
    cart.addItem(await readProduct(beerId));
    expect(cart.value.single['trackEmpties'], isTrue);

    await db.catalogDao.updateTrackEmpties(beerId, false);
    expect(await sync.sync(), isTrue);

    // Without this the cart would keep showing a deposit for a line that
    // createOrder — which re-reads trackEmpties — no longer books crates for.
    expect(cart.value.single['trackEmpties'], isFalse);
  });

  test('(e) an unconfigured brand resolves to 0, never to the stale mirror',
      () async {
    // The brand rate is cleared; the product mirror still holds the old figure.
    await db.catalogDao.updateManufacturerEmptyCrateValue(brandId, 0);
    cart.addItem(await readProduct(beerId));

    await sync.sync();

    // 0 is what the cart's "No crate value set" banner keys on. Falling back to
    // the mirror here would hide an unconfigured brand behind a stale number.
    expect(cart.value.single['emptyCrateValueKobo'], 0);
  });

  test('(f) a mixed cart only touches the products that resolved', () async {
    final waterId = await insertBottle(
      name: 'Table Water',
      unit: 'Pack',
      trackEmpties: false,
    );
    cart.addItem(await readProduct(beerId));
    cart.addItem(await readProduct(waterId));
    // A Quick-Sale line carries no DB product at all.
    cart.addItem({
      'name': 'Quick Sale',
      'price': 500.0,
      'icon': 0,
      'color': null,
      'subtitle': null,
      'category': null,
      'crateSizeGroupId': null,
      'crateGroupName': null,
      'manufacturerId': null,
      'size': null,
    });

    await db.catalogDao.updateManufacturerEmptyCrateValue(
      brandId,
      _raisedDepositKobo,
    );
    await sync.sync();

    final byName = {for (final l in cart.value) l['name'] as String: l};
    expect(byName['Star Lager']!['emptyCrateValueKobo'], _raisedDepositKobo);
    // The non-crate line and the Quick-Sale line are untouched.
    expect(byName['Table Water']!['trackEmpties'], isFalse);
    expect(byName['Table Water']!['emptyCrateValueKobo'], 0);
    expect(byName['Quick Sale']!['emptyCrateValueKobo'], 0);
    expect(cart.value.length, 3);
  });

  test('(g) a sync that changes nothing reports false and notifies nobody',
      () async {
    cart.addItem(await readProduct(beerId));
    var notifications = 0;
    void listener() => notifications++;
    cart.addListener(listener);
    addTearDown(() => cart.removeListener(listener));

    expect(await sync.sync(), isFalse);
    expect(notifications, 0);
  });

  test('(h) qty, discounts and custom prices survive a sync', () async {
    final p = await readProduct(beerId);
    cart.addItem(p, qty: 4);
    cart.setCustomPrice(p.name, customPriceKobo: 75000, maxPercent: 50);
    cart.setLineDiscount(
      p.name,
      kind: 'naira',
      enteredValue: 100,
      discountKobo: 10000,
    );

    await db.catalogDao.updateManufacturerEmptyCrateValue(
      brandId,
      _raisedDepositKobo,
    );
    await sync.sync();

    final line = cart.value.single;
    expect(line['emptyCrateValueKobo'], _raisedDepositKobo);
    expect(line['qty'], 4.0);
    expect(line['customPriceKobo'], 75000);
    expect(line['unitPriceKobo'], 75000);
    expect(line['discountKobo'], 10000);
  });

  test('(i) start() reconciles live, without the cart being rebuilt', () async {
    cart.addItem(await readProduct(beerId));
    sync.start();
    // Let the initial emission of the live query land.
    await _settle();
    expect(cart.value.single['emptyCrateValueKobo'], _openingDepositKobo);

    // The edit an owner makes on the Inventory tab while the cart sits open.
    await db.catalogDao.updateManufacturerEmptyCrateValue(
      brandId,
      _raisedDepositKobo,
    );
    await _settle();

    expect(cart.value.single['emptyCrateValueKobo'], _raisedDepositKobo);
  });

  test('(j) a fix landing only in a parked store\'s cart reports no change',
      () async {
    // Same product in two store buckets (§12.1). The cashier is looking at
    // store B; store A's cart is parked.
    nav.setLockedStore('store-a');
    cart.addItem(await readProduct(beerId));
    nav.setLockedStore('store-b');
    expect(cart.value, isEmpty); // B's bucket is its own

    await db.catalogDao.updateManufacturerEmptyCrateValue(
      brandId,
      _raisedDepositKobo,
    );

    // Nothing to resolve for the empty active cart, so nothing is reported —
    // and the cashier is not told their cart changed when it did not.
    expect(await sync.sync(), isFalse);

    // Store A's line is corrected when it comes back into view.
    nav.setLockedStore('store-a');
    expect(await sync.sync(), isTrue);
    expect(cart.value.single['emptyCrateValueKobo'], _raisedDepositKobo);
  });

  test('(i2) a line added AFTER start() is picked up too', () async {
    sync.start();
    await _settle();

    await db.catalogDao.updateManufacturerEmptyCrateValue(
      brandId,
      _raisedDepositKobo,
    );
    cart.addItem(await readProduct(beerId)); // stale mirror at add-time
    await _settle();

    expect(cart.value.single['emptyCrateValueKobo'], _raisedDepositKobo);
  });
}

/// Drift delivers a table-update notification on a later event-loop turn, so a
/// live-query assertion has to yield first. Kept generous: the point of these
/// two tests is that the update arrives at all, not how fast.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 100));
