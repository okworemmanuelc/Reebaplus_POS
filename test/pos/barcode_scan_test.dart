// barcode_scan_test.dart
//
// #118 — POS barcode scanning. Drives the scan flow through a FAKE scanner (no
// camera can run headless), exercising the whole always-visible scan button:
//   - a FOUND barcode adds the product to the cart via the normal add path, so
//     stock + tier rules apply (priced at the active tier; a 0-stock line is
//     rejected rather than oversold);
//   - an UNKNOWN barcode toasts and opens Add Product with the code pre-filled;
//   - a dismissed scan (null) is a no-op.
//
// The button is placed in a bare Scaffold's FAB slot (its real home, ADR 0017)
// with an empty cart to prove it is not gated on the cart.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/pos/providers/pos_providers.dart';
import 'package:reebaplus_pos/features/pos/services/barcode_scanner.dart';
import 'package:reebaplus_pos/features/pos/widgets/pos_barcode_scan_button.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/services/cart_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';

/// Test double for [BarcodeScanner]: returns a preset code without a camera and
/// records how many times it was invoked (to prove the button is wired).
class _FakeBarcodeScanner implements BarcodeScanner {
  _FakeBarcodeScanner(this.code);
  final String? code;
  int scanCount = 0;

  @override
  Future<String?> scanOnce(BuildContext context) async {
    scanCount++;
    return code;
  }
}

const int _retailerKobo = 100000; // ₦1,000.00
const int _wholesalerKobo = 80000; // ₦800.00

void main() {
  late AppDatabase db;
  late CartService cart;
  late String businessId;

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
    await db
        .into(db.businesses)
        .insert(
          BusinessesCompanion.insert(id: Value(businessId), name: 'Scan Biz'),
        );

    // CartService only needs AuthService for currentUser?.id; with nobody signed
    // in, _uid falls back to '' (a valid cart key). Constructing AuthService
    // repoints db.businessIdResolver at value?.businessId (null), so re-point it
    // at the seeded business afterwards for the business-scoped barcode lookup.
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
    AppNotification.hide(); // clear any toast left over from a prior test.
  });

  tearDown(() async {
    await db.close();
  });

  Future<ProductData> seedProduct({
    required String name,
    required String barcode,
  }) async {
    final id = UuidV7.generate();
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: Value(id),
            businessId: businessId,
            name: name,
            barcode: Value(barcode),
            retailerPriceKobo: const Value(_retailerKobo),
            wholesalerPriceKobo: const Value(_wholesalerKobo),
          ),
        );
    return (db.select(db.products)..where((t) => t.id.equals(id))).getSingle();
  }

  Widget host(
    BarcodeScanner scanner, {
    required List<ProductDataWithStock> loaded,
    PriceTier tier = PriceTier.retailer,
    void Function(BuildContext, String)? onUnknown,
  }) {
    return ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        cartProvider.overrideWith((ref) => cart),
        barcodeScannerProvider.overrideWithValue(scanner),
      ],
      child: MaterialApp(
        home: Scaffold(
          floatingActionButton: PosBarcodeScanButton(
            tier: tier,
            loadedProducts: loaded,
            onUnknownBarcode: onUnknown,
          ),
        ),
      ),
    );
  }

  testWidgets('scan button is always visible (not gated on the cart)', (
    tester,
  ) async {
    await tester.pumpWidget(host(_FakeBarcodeScanner(null), loaded: const []));
    // Rendered with an empty cart — the button is present regardless.
    expect(find.byType(PosBarcodeScanButton), findsOneWidget);
    expect(cart.value, isEmpty);
  });

  testWidgets('found barcode adds the product to the cart at the active tier', (
    tester,
  ) async {
    final product = await seedProduct(name: 'Star Lager', barcode: 'BC-1');
    final scanner = _FakeBarcodeScanner('BC-1');
    await tester.pumpWidget(
      host(
        scanner,
        loaded: [ProductDataWithStock(product: product, totalStock: 10)],
      ),
    );

    await tester.tap(find.byType(PosBarcodeScanButton));
    await tester.pumpAndSettle();

    expect(scanner.scanCount, 1);
    expect(cart.value, hasLength(1));
    final line = cart.value.single;
    expect(line['id'], product.id);
    expect(line['name'], 'Star Lager');
    // Priced at the active (retailer) tier — the normal add path's tier rule.
    expect(line['unitPriceKobo'], _retailerKobo);
    expect(line['priceTier'], 'retailer');
    expect(find.text('Star Lager added to cart'), findsOneWidget);

    AppNotification.hide();
    await tester.pumpAndSettle();
  });

  testWidgets('wholesaler tier prices the scanned line at wholesale', (
    tester,
  ) async {
    final product = await seedProduct(name: 'Star Lager', barcode: 'BC-1');
    await tester.pumpWidget(
      host(
        _FakeBarcodeScanner('BC-1'),
        loaded: [ProductDataWithStock(product: product, totalStock: 10)],
        tier: PriceTier.wholesaler,
      ),
    );

    await tester.tap(find.byType(PosBarcodeScanButton));
    await tester.pumpAndSettle();

    expect(cart.value.single['unitPriceKobo'], _wholesalerKobo);
    expect(cart.value.single['priceTier'], 'wholesaler');

    AppNotification.hide();
    await tester.pumpAndSettle();
  });

  testWidgets('found barcode with 0 store stock is rejected (stock rule)', (
    tester,
  ) async {
    final product = await seedProduct(name: 'Gulder', barcode: 'BC-2');
    await tester.pumpWidget(
      host(
        _FakeBarcodeScanner('BC-2'),
        // Zero stock in this store → the normal add path rejects, never oversells.
        loaded: [ProductDataWithStock(product: product, totalStock: 0)],
      ),
    );

    await tester.tap(find.byType(PosBarcodeScanButton));
    await tester.pumpAndSettle();

    expect(cart.value, isEmpty);
    expect(find.text('Stock limit reached for Gulder'), findsOneWidget);

    AppNotification.hide();
    await tester.pumpAndSettle();
  });

  testWidgets('unknown barcode toasts and opens Add Product pre-filled', (
    tester,
  ) async {
    await seedProduct(name: 'Star Lager', barcode: 'BC-1');
    String? openedWith;
    await tester.pumpWidget(
      host(
        _FakeBarcodeScanner('NOPE-999'),
        loaded: const [],
        onUnknown: (_, code) => openedWith = code,
      ),
    );

    await tester.tap(find.byType(PosBarcodeScanButton));
    await tester.pumpAndSettle();

    expect(cart.value, isEmpty);
    expect(find.text('No product matches that barcode'), findsOneWidget);
    // Add Product is opened with the scanned code pre-filled.
    expect(openedWith, 'NOPE-999');

    AppNotification.hide();
    await tester.pumpAndSettle();
  });

  testWidgets('dismissed scan (null) is a no-op', (tester) async {
    final scanner = _FakeBarcodeScanner(null);
    await tester.pumpWidget(host(scanner, loaded: const []));

    await tester.tap(find.byType(PosBarcodeScanButton));
    await tester.pumpAndSettle();

    expect(scanner.scanCount, 1);
    expect(cart.value, isEmpty);
  });
}
