// barcode_scan_test.dart
//
// #118 / #317 / #318 / #319 — POS barcode scanning. Drives the scan flow
// through the REAL scanner page over a FAKE camera (no camera can run
// headless; see helpers/fake_barcode_scanner.dart), exercising the whole
// always-visible scan button:
//   - a FOUND, sellable barcode opens the tap-and-hold "Add to Cart" sheet
//     (#317) at the active store's stock cap and the active tier; it starts one
//     above what's already in the cart, and Cancel / dismiss add nothing;
//   - a found but unsellable product (out of stock here, all already in the
//     cart, switched off) shows its message and no sheet;
//   - two products sharing a barcode show the "Which one?" list (#318); a
//     pick continues as a single match, and dismissing adds nothing;
//   - an UNKNOWN barcode (#320): holding neither products.add nor
//     products.edit_price a message and no Add Product; "Add as new" opens
//     Add Product (via the test seam), and a product saved there goes to the
//     quantity sheet if this store has stock, else a message; backing out
//     adds nothing (the real Add Product screen is driven end to end in
//     scan_unknown_barcode_test.dart);
//   - the unknown-barcode choice (#321): each option shows only with its gate;
//     "Link to an existing product" saves only the barcode on the picked
//     product (asking before replacing a different one), then the quantity
//     sheet opens and the next scan of the code finds it;
//   - the scanner stays open (#319): each read shows its outcome over the
//     live camera (never paused, so the torch stays on); other reads are
//     ignored meanwhile; the same code is ignored for the debounce window; the running count follows the cart; ✕ / back close it
//     with the cart intact; backgrounding stops the camera; a lock closes it.
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

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/pos/providers/pos_providers.dart';
import 'package:reebaplus_pos/features/pos/widgets/barcode_scan_page.dart';
import 'package:reebaplus_pos/features/pos/widgets/edit_item_modal.dart';
import 'package:reebaplus_pos/features/pos/widgets/pos_barcode_scan_button.dart';
import 'package:reebaplus_pos/features/pos/widgets/scan_cart_count.dart';
import 'package:reebaplus_pos/features/pos/widgets/scan_link_product_sheet.dart';
import 'package:reebaplus_pos/features/pos/widgets/scan_unknown_choice_sheet.dart';
import 'package:reebaplus_pos/features/pos/widgets/scan_which_one_sheet.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/services/cart_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

import '../helpers/fake_barcode_scanner.dart';
import '../helpers/viewports.dart';

const int _retailerKobo = 100000; // ₦1,000.00
const int _wholesalerKobo = 80000; // ₦800.00

void main() {
  late AppDatabase db;
  late AuthService auth;
  late CartService cart;
  late String businessId;
  // The scanner the current test hosted (set by host()).
  late FakeBarcodeScanner scanner;

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
    auth = AuthService(
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

  /// Signs a cashier in (most tests run with nobody signed in, which the
  /// scanner treats as a locked app when the app comes back to the front).
  void signIn() {
    auth.value = UserData(
      id: 'scan-user',
      businessId: businessId,
      name: 'Cashier',
      pin: '1234',
      createdAt: DateTime.now(),
      lastUpdatedAt: DateTime.now(),
      avatarColor: '#3B82F6',
      biometricEnabled: false,
    );
    db.businessIdResolver = () => businessId;
  }

  Future<ProductData> seedProduct({
    required String name,
    required String? barcode,
    bool isAvailable = true,
    int retailerKobo = _retailerKobo,
    String? size,
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
            retailerPriceKobo: Value(retailerKobo),
            wholesalerPriceKobo: const Value(_wholesalerKobo),
            isAvailable: Value(isAvailable),
            size: Value(size),
          ),
        );
    return (db.select(db.products)..where((t) => t.id.equals(id))).getSingle();
  }

  Widget host(
    FakeBarcodeScanner fake, {
    required List<ProductDataWithStock> loaded,
    PriceTier tier = PriceTier.retailer,
    String? storeName = 'Main Store',
    String? storeId,
    // products.add by default (#320) — "Add as new" is then the only option on
    // the unknown-barcode choice (#321); a Cashier passes a set with neither
    // products.add nor products.edit_price.
    Set<String> grantedKeys = const {'products.add'},
    Future<ProductData?> Function(BuildContext, String)? onUnknown,
    List<ProductDataWithStock> Function()? readStoreProducts,
  }) {
    scanner = fake;
    return ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        authProvider.overrideWith((ref) => auth),
        cartProvider.overrideWith((ref) => cart),
        barcodeScannerProvider.overrideWithValue(fake),
        gateContextProvider.overrideWithValue(
          GateContext(grantedKeys: grantedKeys, roleRank: null, isReady: true),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          floatingActionButton: PosBarcodeScanButton(
            tier: tier,
            loadedProducts: loaded,
            storeName: storeName,
            storeId: storeId,
            readStoreProducts: readStoreProducts,
            onUnknownBarcode: onUnknown,
          ),
        ),
      ),
    );
  }

  /// The quantity field of the open "Add to Cart" sheet (its first input).
  Finder qtyField() => find
      .descendant(
        of: find.byType(EditItemModal),
        matching: find.byType(TextField),
      )
      .first;

  String qtyText(WidgetTester tester) =>
      tester.widget<TextField>(qtyField()).controller!.text;

  /// Opens the scanner (if it isn't open yet) and has the camera read [code]
  /// (default: the scanner's preset code). The debounce clock moves past the
  /// window first, so a repeat read here always counts.
  Future<void> scan(WidgetTester tester, [String? code]) async {
    if (find.byType(BarcodeScanPage).evaluate().isEmpty) {
      await tester.tap(find.byType(PosBarcodeScanButton));
      await tester.pumpAndSettle();
    }
    scanner.advance(const Duration(seconds: 2));
    scanner.camera!.read(code ?? scanner.code!);
    await tester.pumpAndSettle();
  }

  Future<void> tapSheetButton(WidgetTester tester, String label) async {
    final button = find.widgetWithText(AppButton, label);
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  Future<void> clearToast(WidgetTester tester) async {
    AppNotification.hide();
    await tester.pumpAndSettle();
  }

  // The active store for the unknown-barcode cases (#320/#321): a saved or
  // linked product's stock is read from here.
  const storeId = 'store-main';

  Future<void> seedStore() => db
      .into(db.stores)
      .insert(
        StoresCompanion.insert(
          id: const Value(storeId),
          businessId: businessId,
          name: 'Main Store',
        ),
      );

  Future<void> stockIn(ProductData p, int qty) => db
      .into(db.inventory)
      .insert(
        InventoryCompanion.insert(
          businessId: businessId,
          productId: p.id,
          storeId: storeId,
          quantity: Value(qty),
        ),
      );

  /// Picks "Add as new product" on the unknown-barcode choice (#321).
  Future<void> chooseAddNew(WidgetTester tester) async {
    expect(find.byType(ScanUnknownChoiceSheet), findsOneWidget);
    await tester.tap(find.byKey(kScanUnknownAddNewKey));
    await tester.pumpAndSettle();
  }

  testWidgets('scan button is always visible (not gated on the cart) and textless', (
    tester,
  ) async {
    await tester.pumpWidget(host(FakeBarcodeScanner(null), loaded: const []));
    // Rendered with an empty cart — the button is present regardless.
    expect(find.byType(PosBarcodeScanButton), findsOneWidget);
    expect(find.text('Scan'), findsNothing);
    expect(find.byTooltip('Scan barcode'), findsOneWidget);
    expect(cart.value, isEmpty);
  });

  group('found and sellable — opens the Add to Cart sheet (#317)', () {
    testWidgets('confirming 3 puts 3 in the cart at the active tier', (
      tester,
    ) async {
      final product = await seedProduct(name: 'Star Lager', barcode: 'BC-1');
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner('BC-1'),
          loaded: [ProductDataWithStock(product: product, totalStock: 10)],
        ),
      );

      await scan(tester);

      expect(scanner.sessionCount, 1);
      // Nothing is added until the sheet is confirmed.
      expect(cart.value, isEmpty);
      expect(find.byType(EditItemModal), findsOneWidget);
      // Not in the cart yet → starts on 1, with no "already in cart" line.
      expect(qtyText(tester), '1');
      expect(find.textContaining('already in cart'), findsNothing);

      await tester.enterText(qtyField(), '3');
      await tester.pump();
      await tapSheetButton(tester, 'Add to Cart');

      expect(find.byType(EditItemModal), findsNothing);
      final line = cart.value.single;
      expect(line['id'], product.id);
      expect(line['qty'], 3);
      // Priced at the active (retailer) tier — the normal add path's tier rule.
      expect(line['unitPriceKobo'], _retailerKobo);
      expect(line['priceTier'], 'retailer');
      expect(find.text('Star Lager ×3 added'), findsOneWidget);

      await clearToast(tester);
    });

    testWidgets('wholesaler tier prices the scanned line at wholesale', (
      tester,
    ) async {
      final product = await seedProduct(name: 'Star Lager', barcode: 'BC-1');
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner('BC-1'),
          loaded: [ProductDataWithStock(product: product, totalStock: 10)],
          tier: PriceTier.wholesaler,
        ),
      );

      await scan(tester);
      await tapSheetButton(tester, 'Add to Cart');

      expect(cart.value.single['qty'], 1);
      expect(cart.value.single['unitPriceKobo'], _wholesalerKobo);
      expect(cart.value.single['priceTier'], 'wholesaler');
      expect(find.text('Star Lager ×1 added'), findsOneWidget);

      await clearToast(tester);
    });

    testWidgets('already ×2 in the cart → starts on 3 with "2 already in cart"', (
      tester,
    ) async {
      final product = await seedProduct(name: 'Star Lager', barcode: 'BC-1');
      cart.addItem(product, qty: 2, maxStock: 10, tier: PriceTier.retailer);
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner('BC-1'),
          loaded: [ProductDataWithStock(product: product, totalStock: 10)],
        ),
      );

      await scan(tester);

      expect(qtyText(tester), '3');
      expect(find.text('2 already in cart'), findsOneWidget);

      // The field is the cart TOTAL: confirming 3 leaves one line of 3.
      await tapSheetButton(tester, 'Add to Cart');
      expect(cart.value.single['qty'], 3);
      expect(find.text('Star Lager ×3 added'), findsOneWidget);

      await clearToast(tester);
    });

    testWidgets('the start value never passes the store stock', (tester) async {
      final product = await seedProduct(name: 'Star Lager', barcode: 'BC-1');
      cart.addItem(product, qty: 4.5, maxStock: 5, tier: PriceTier.retailer);
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner('BC-1'),
          loaded: [ProductDataWithStock(product: product, totalStock: 5)],
        ),
      );

      await scan(tester);

      expect(qtyText(tester), '5');
      expect(find.text('4.5 already in cart'), findsOneWidget);
    });

    testWidgets('Cancel adds nothing', (tester) async {
      final product = await seedProduct(name: 'Star Lager', barcode: 'BC-1');
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner('BC-1'),
          loaded: [ProductDataWithStock(product: product, totalStock: 10)],
        ),
      );

      await scan(tester);
      await tester.enterText(qtyField(), '3');
      await tester.pump();
      await tapSheetButton(tester, 'Cancel');

      expect(find.byType(EditItemModal), findsNothing);
      expect(cart.value, isEmpty);
      expect(find.textContaining('added'), findsNothing);
    });

    testWidgets('the close button adds nothing', (tester) async {
      final product = await seedProduct(name: 'Star Lager', barcode: 'BC-1');
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner('BC-1'),
          loaded: [ProductDataWithStock(product: product, totalStock: 10)],
        ),
      );

      await scan(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(EditItemModal),
          matching: find.byIcon(AppIcons.close),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(EditItemModal), findsNothing);
      expect(cart.value, isEmpty);
      expect(find.textContaining('added'), findsNothing);
    });

    testWidgets('back (dismiss) adds nothing, and leaves an existing line alone', (
      tester,
    ) async {
      final product = await seedProduct(name: 'Star Lager', barcode: 'BC-1');
      cart.addItem(product, qty: 2, maxStock: 10, tier: PriceTier.retailer);
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner('BC-1'),
          loaded: [ProductDataWithStock(product: product, totalStock: 10)],
        ),
      );

      await scan(tester);
      expect(find.byType(EditItemModal), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(EditItemModal), findsNothing);
      expect(cart.value.single['qty'], 2);
      expect(find.textContaining('added'), findsNothing);
    });
  });

  group('found but not sellable — a message and no sheet (#317)', () {
    testWidgets('0 stock in this store → out of stock at the store', (
      tester,
    ) async {
      final product = await seedProduct(name: 'Gulder', barcode: 'BC-2');
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner('BC-2'),
          loaded: [ProductDataWithStock(product: product, totalStock: 0)],
        ),
      );

      await scan(tester);

      expect(find.byType(EditItemModal), findsNothing);
      expect(cart.value, isEmpty);
      expect(find.text('Gulder is out of stock at Main Store'), findsOneWidget);
      // The old scan-path toast is gone.
      expect(find.textContaining('Stock limit reached'), findsNothing);

      await clearToast(tester);
    });

    testWidgets('not stocked in this store → out of stock (no store name yet)', (
      tester,
    ) async {
      await seedProduct(name: 'Gulder', barcode: 'BC-2');
      await tester.pumpWidget(
        host(FakeBarcodeScanner('BC-2'), loaded: const [], storeName: null),
      );

      await scan(tester);

      expect(find.byType(EditItemModal), findsNothing);
      expect(cart.value, isEmpty);
      expect(find.text('Gulder is out of stock at this store'), findsOneWidget);

      await clearToast(tester);
    });

    testWidgets('cart already holds all the stock → all in cart', (
      tester,
    ) async {
      final product = await seedProduct(name: 'Gulder', barcode: 'BC-2');
      cart.addItem(product, qty: 5, maxStock: 5, tier: PriceTier.retailer);
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner('BC-2'),
          loaded: [ProductDataWithStock(product: product, totalStock: 5)],
        ),
      );

      await scan(tester);

      expect(find.byType(EditItemModal), findsNothing);
      expect(cart.value.single['qty'], 5);
      expect(
        find.text('All 5 Gulder in stock are already in the cart'),
        findsOneWidget,
      );

      await clearToast(tester);
    });

    testWidgets('switched off for sale can no longer be added by scanning', (
      tester,
    ) async {
      final product = await seedProduct(
        name: 'Gulder',
        barcode: 'BC-2',
        isAvailable: false,
      );
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner('BC-2'),
          loaded: [ProductDataWithStock(product: product, totalStock: 10)],
        ),
      );

      await scan(tester);

      expect(find.byType(EditItemModal), findsNothing);
      expect(cart.value, isEmpty);
      expect(find.text('Gulder is switched off for sale'), findsOneWidget);

      await clearToast(tester);
    });
  });

  group('two products share a barcode — "Which one?" (#318)', () {
    Finder choiceRow(ProductData p) =>
        find.byKey(ValueKey<String>('$kScanChoiceKeyPrefix${p.id}'));

    Future<void> pick(WidgetTester tester, ProductData p) async {
      await tester.ensureVisible(choiceRow(p));
      await tester.pumpAndSettle();
      await tester.tap(choiceRow(p));
      await tester.pumpAndSettle();
    }

    testWidgets('lists both; picking one opens its sheet at its own price', (
      tester,
    ) async {
      final extra = await seedProduct(
        name: 'Panadol Extra',
        barcode: 'BC-DUP',
        size: 'big',
      );
      final junior = await seedProduct(
        name: 'Panadol Junior',
        barcode: 'BC-DUP',
        retailerKobo: 50000,
      );
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner('BC-DUP'),
          loaded: [
            ProductDataWithStock(product: extra, totalStock: 10),
            ProductDataWithStock(product: junior, totalStock: 4),
          ],
        ),
      );

      await scan(tester);

      // The list, not a sheet, and nothing added yet.
      expect(find.byType(ScanWhichOneSheet), findsOneWidget);
      expect(find.byType(EditItemModal), findsNothing);
      expect(cart.value, isEmpty);
      expect(find.text('Which one?'), findsOneWidget);
      expect(find.text('Panadol Extra · big'), findsOneWidget);
      expect(find.text('Panadol Junior'), findsOneWidget);
      expect(find.text('10 in stock here'), findsOneWidget);
      expect(find.text('4 in stock here'), findsOneWidget);
      expect(find.text(formatCurrency(_retailerKobo / 100.0)), findsOneWidget);
      expect(find.text(formatCurrency(50000 / 100.0)), findsOneWidget);

      await pick(tester, junior);

      expect(find.byType(ScanWhichOneSheet), findsNothing);
      expect(find.byType(EditItemModal), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(EditItemModal),
          matching: find.text('Panadol Junior'),
        ),
        findsOneWidget,
      );
      await tapSheetButton(tester, 'Add to Cart');

      final line = cart.value.single;
      expect(line['id'], junior.id);
      expect(line['qty'], 1);
      expect(line['unitPriceKobo'], 50000);
      expect(find.text('Panadol Junior ×1 added'), findsOneWidget);

      await clearToast(tester);
    });

    testWidgets('the pick starts on its OWN cart qty + 1', (tester) async {
      final extra = await seedProduct(name: 'Panadol Extra', barcode: 'BC-DUP');
      final junior = await seedProduct(name: 'Panadol Junior', barcode: 'BC-DUP');
      cart.addItem(junior, qty: 2, maxStock: 10, tier: PriceTier.retailer);
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner('BC-DUP'),
          loaded: [
            ProductDataWithStock(product: extra, totalStock: 10),
            ProductDataWithStock(product: junior, totalStock: 10),
          ],
        ),
      );

      await scan(tester);
      await pick(tester, junior);

      expect(qtyText(tester), '3');
      expect(find.text('2 already in cart'), findsOneWidget);
    });

    testWidgets('picking a switched-off row shows its message, not the sheet', (
      tester,
    ) async {
      final off = await seedProduct(
        name: 'Gulder',
        barcode: 'BC-DUP',
        isAvailable: false,
      );
      final ok = await seedProduct(name: 'Star Lager', barcode: 'BC-DUP');
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner('BC-DUP'),
          loaded: [
            ProductDataWithStock(product: off, totalStock: 10),
            ProductDataWithStock(product: ok, totalStock: 10),
          ],
        ),
      );

      await scan(tester);
      // Still listed, with its reason.
      expect(
        find.text('10 in stock here · Switched off for sale'),
        findsOneWidget,
      );
      await pick(tester, off);

      expect(find.byType(ScanWhichOneSheet), findsNothing);
      expect(find.byType(EditItemModal), findsNothing);
      expect(cart.value, isEmpty);
      expect(find.text('Gulder is switched off for sale'), findsOneWidget);

      await clearToast(tester);
    });

    testWidgets('the pick is checked against the CURRENT catalogue, not the '
        'one captured at scan time', (tester) async {
      final extra = await seedProduct(name: 'Panadol Extra', barcode: 'BC-DUP');
      final junior = await seedProduct(name: 'Panadol Junior', barcode: 'BC-DUP');
      // What the grid held when the scan started: Junior has 4 here.
      var current = [
        ProductDataWithStock(product: extra, totalStock: 10),
        ProductDataWithStock(product: junior, totalStock: 4),
      ];
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner('BC-DUP'),
          loaded: current,
          readStoreProducts: () => current,
        ),
      );

      await scan(tester);
      expect(find.text('4 in stock here'), findsOneWidget);

      // Another till sells the last Junior while the list is open.
      current = [ProductDataWithStock(product: extra, totalStock: 10)];
      await pick(tester, junior);

      expect(find.byType(EditItemModal), findsNothing);
      expect(cart.value, isEmpty);
      expect(
        find.text('Panadol Junior is out of stock at Main Store'),
        findsOneWidget,
      );

      await clearToast(tester);
    });

    testWidgets('picking an out-of-stock row shows its message, not the sheet', (
      tester,
    ) async {
      final empty = await seedProduct(name: 'Gulder', barcode: 'BC-DUP');
      final ok = await seedProduct(name: 'Star Lager', barcode: 'BC-DUP');
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner('BC-DUP'),
          // Gulder isn't stocked in this store at all.
          loaded: [ProductDataWithStock(product: ok, totalStock: 10)],
        ),
      );

      await scan(tester);
      expect(find.text('0 in stock here · Out of stock'), findsOneWidget);
      await pick(tester, empty);

      expect(find.byType(EditItemModal), findsNothing);
      expect(cart.value, isEmpty);
      expect(find.text('Gulder is out of stock at Main Store'), findsOneWidget);

      await clearToast(tester);
    });

    testWidgets('closing or backing out of the list adds nothing', (
      tester,
    ) async {
      final a = await seedProduct(name: 'Gulder', barcode: 'BC-DUP');
      final b = await seedProduct(name: 'Star Lager', barcode: 'BC-DUP');
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner('BC-DUP'),
          loaded: [
            ProductDataWithStock(product: a, totalStock: 10),
            ProductDataWithStock(product: b, totalStock: 10),
          ],
        ),
      );

      await scan(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(ScanWhichOneSheet),
          matching: find.byIcon(AppIcons.close),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ScanWhichOneSheet), findsNothing);
      expect(find.byType(EditItemModal), findsNothing);
      expect(cart.value, isEmpty);

      await scan(tester);
      expect(find.byType(ScanWhichOneSheet), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ScanWhichOneSheet), findsNothing);
      expect(find.byType(EditItemModal), findsNothing);
      expect(cart.value, isEmpty);
    });

    for (final size in const [phoneSe1Portrait, androidCompactLandscape]) {
      testWidgets(
        'a long list never overflows and the last row is reachable at '
        '${size.width.toInt()}x${size.height.toInt()}',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          final seeded = <ProductData>[
            for (var i = 0; i < 8; i++)
              await seedProduct(
                name: 'Panadol variant $i with a long name',
                barcode: 'BC-DUP',
                size: 'big',
              ),
          ];
          await tester.pumpWidget(
            host(
              FakeBarcodeScanner('BC-DUP'),
              loaded: [
                for (final p in seeded)
                  ProductDataWithStock(product: p, totalStock: 5),
              ],
            ),
          );

          await scan(tester);
          expect(tester.takeException(), isNull);

          await pick(tester, seeded.last);
          expect(tester.takeException(), isNull);
          expect(find.byType(EditItemModal), findsOneWidget);
        },
      );
    }
  });

  group('unknown barcode (#320)', () {
    testWidgets('a Cashier (neither products.add nor products.edit_price) '
        'gets the message; no choice and Add Product is never opened', (
      tester,
    ) async {
      await seedProduct(name: 'Star Lager', barcode: 'BC-1');
      var opened = 0;
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner('NOPE-999'),
          loaded: const [],
          grantedKeys: const {'sales.make'},
          onUnknown: (_, _) async {
            opened++;
            return null;
          },
        ),
      );

      await scan(tester);

      expect(opened, 0);
      expect(find.byType(ScanUnknownChoiceSheet), findsNothing);
      expect(find.byType(EditItemModal), findsNothing);
      expect(cart.value, isEmpty);
      expect(
        find.text('No product has this barcode. Ask a manager to add it.'),
        findsOneWidget,
      );
      // Still scanning.
      expect(find.byType(BarcodeScanPage), findsOneWidget);
      expect(scanner.camera!.isRunning, isTrue);

      await clearToast(tester);
    });

    testWidgets('"Add as new" opens Add Product with the code; a product saved '
        'with stock here opens its sheet, and confirming adds it', (
      tester,
    ) async {
      await seedStore();
      String? openedWith;
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner('NEW-123'),
          // The grid's stream hasn't caught up with the new product.
          loaded: const [],
          storeId: storeId,
          onUnknown: (_, code) async {
            openedWith = code;
            final p = await seedProduct(name: 'Fanta', barcode: code);
            await stockIn(p, 6);
            return p;
          },
        ),
      );

      await scan(tester);
      await chooseAddNew(tester);

      expect(openedWith, 'NEW-123');
      // The old generic toast is gone.
      expect(find.text('No product matches that barcode'), findsNothing);
      expect(find.byType(EditItemModal), findsOneWidget);
      expect(qtyText(tester), '1');
      expect(cart.value, isEmpty);

      await tapSheetButton(tester, 'Add to Cart');

      final line = cart.value.single;
      expect(line['name'], 'Fanta');
      expect(line['qty'], 1);
      expect(find.text('Fanta ×1 added'), findsOneWidget);
      expect(find.byType(BarcodeScanPage), findsOneWidget);
      expect(scanner.camera!.isRunning, isTrue);

      await clearToast(tester);
    });

    testWidgets('saved with no stock in this store → the no-stock message, '
        'back to scanning', (tester) async {
      await seedStore();
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner('NEW-123'),
          loaded: const [],
          storeId: storeId,
          onUnknown: (_, code) async =>
              seedProduct(name: 'Fanta', barcode: code),
        ),
      );

      await scan(tester);
      await chooseAddNew(tester);

      expect(find.byType(EditItemModal), findsNothing);
      expect(cart.value, isEmpty);
      expect(
        find.text(
          "Saved. Fanta has no stock at Main Store yet, so it can't be added "
          'to the cart.',
        ),
        findsOneWidget,
      );
      expect(find.byType(BarcodeScanPage), findsOneWidget);
      expect(scanner.camera!.isRunning, isTrue);

      await clearToast(tester);
    });

    testWidgets('no store name yet → "this store"', (tester) async {
      await seedStore();
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner('NEW-123'),
          loaded: const [],
          storeName: null,
          storeId: storeId,
          onUnknown: (_, code) async =>
              seedProduct(name: 'Fanta', barcode: code),
        ),
      );

      await scan(tester);
      await chooseAddNew(tester);

      expect(
        find.text(
          "Saved. Fanta has no stock at this store yet, so it can't be added "
          'to the cart.',
        ),
        findsOneWidget,
      );

      await clearToast(tester);
    });

    testWidgets('backing out of Add Product adds nothing and keeps scanning', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner('NEW-123'),
          loaded: const [],
          storeId: storeId,
          onUnknown: (_, _) async => null,
        ),
      );

      await scan(tester);
      await chooseAddNew(tester);

      expect(find.byType(EditItemModal), findsNothing);
      expect(cart.value, isEmpty);
      expect(find.byType(BarcodeScanPage), findsOneWidget);
      expect(scanner.camera!.isRunning, isTrue);
    });
  });

  group('unknown barcode — add new or link to existing (#321)', () {
    const both = {'products.add', 'products.edit_price'};
    const code = 'NEW-321';

    Future<ProductData> reload(ProductData p) =>
        (db.select(db.products)..where((t) => t.id.equals(p.id))).getSingle();

    /// Picks "Link to an existing product" on the choice.
    Future<void> chooseLink(WidgetTester tester) async {
      expect(find.byType(ScanUnknownChoiceSheet), findsOneWidget);
      await tester.tap(find.byKey(kScanUnknownLinkKey));
      await tester.pumpAndSettle();
      expect(find.byType(ScanLinkProductSheet), findsOneWidget);
    }

    Finder linkRow(ProductData p) =>
        find.byKey(ValueKey<String>('$kScanLinkRowKeyPrefix${p.id}'));

    Future<void> tapLinkRow(WidgetTester tester, ProductData p) async {
      await tester.ensureVisible(linkRow(p));
      await tester.pumpAndSettle();
      await tester.tap(linkRow(p));
      await tester.pumpAndSettle();
    }

    final gateCases = <(String, Set<String>, bool, bool)>[
      ('both gates → both options', both, true, true),
      ('only products.add → only Add new', {'products.add'}, true, false),
      (
        'only products.edit_price → only Link',
        {'products.edit_price'},
        false,
        true,
      ),
    ];
    for (final (label, keys, canAdd, canLink) in gateCases) {
      testWidgets(label, (tester) async {
        await tester.pumpWidget(
          host(
            FakeBarcodeScanner(code),
            loaded: const [],
            grantedKeys: keys,
            onUnknown: (_, _) async => null,
          ),
        );

        await scan(tester);

        expect(find.byType(ScanUnknownChoiceSheet), findsOneWidget);
        // The scanned code is shown on the choice.
        expect(
          find.descendant(
            of: find.byType(ScanUnknownChoiceSheet),
            matching: find.text(code),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(kScanUnknownAddNewKey),
          canAdd ? findsOneWidget : findsNothing,
        );
        expect(
          find.byKey(kScanUnknownLinkKey),
          canLink ? findsOneWidget : findsNothing,
        );
        expect(
          find.text('No product has this barcode. Ask a manager to add it.'),
          findsNothing,
        );
      });
    }

    testWidgets('neither gate → the message and no choice', (tester) async {
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner(code),
          loaded: const [],
          grantedKeys: const {'sales.make', 'products.edit_buying_price'},
        ),
      );

      await scan(tester);

      expect(find.byType(ScanUnknownChoiceSheet), findsNothing);
      expect(
        find.text('No product has this barcode. Ask a manager to add it.'),
        findsOneWidget,
      );
      expect(scanner.camera!.isRunning, isTrue);

      await clearToast(tester);
    });

    testWidgets('closing or backing out of the choice does nothing and keeps '
        'scanning', (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner(code),
          loaded: const [],
          grantedKeys: both,
          onUnknown: (_, _) async {
            opened++;
            return null;
          },
        ),
      );

      await scan(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(ScanUnknownChoiceSheet),
          matching: find.byIcon(AppIcons.close),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ScanUnknownChoiceSheet), findsNothing);
      expect(find.byType(BarcodeScanPage), findsOneWidget);
      expect(scanner.camera!.isRunning, isTrue);

      await scan(tester);
      expect(find.byType(ScanUnknownChoiceSheet), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ScanUnknownChoiceSheet), findsNothing);
      expect(find.byType(BarcodeScanPage), findsOneWidget);

      expect(opened, 0);
      expect(cart.value, isEmpty);
      expect(await db.catalogDao.findProductByBarcode(code), isNull);
    });

    testWidgets('linking a product with no barcode saves the code, opens the '
        'quantity sheet, and the next scan finds it', (tester) async {
      await seedStore();
      final malta = await seedProduct(name: 'Malta', barcode: null);
      final star = await seedProduct(name: 'Star Lager', barcode: null);
      await stockIn(malta, 5);
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner(code),
          loaded: [
            ProductDataWithStock(product: malta, totalStock: 5),
            ProductDataWithStock(product: star, totalStock: 0),
          ],
          grantedKeys: both,
          storeId: storeId,
        ),
      );

      await scan(tester);
      await chooseLink(tester);
      // The search lists the business's products; typing narrows it by name.
      expect(linkRow(malta), findsOneWidget);
      expect(linkRow(star), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byType(ScanLinkProductSheet),
          matching: find.byType(TextField),
        ),
        'mal',
      );
      await tester.pumpAndSettle();
      expect(linkRow(malta), findsOneWidget);
      expect(linkRow(star), findsNothing);

      await tapLinkRow(tester, malta);

      // Only the barcode was saved, and the quantity sheet opened for it.
      expect(find.byType(ScanLinkProductSheet), findsNothing);
      expect((await reload(malta)).barcode, code);
      expect(find.byType(EditItemModal), findsOneWidget);
      expect(qtyText(tester), '1');
      expect(cart.value, isEmpty);

      await tapSheetButton(tester, 'Add to Cart');
      expect(cart.value.single['id'], malta.id);
      expect(cart.value.single['qty'], 1);
      expect(find.text('Malta ×1 added'), findsOneWidget);
      expect(scanner.camera!.isRunning, isTrue);
      await clearToast(tester);

      // Scanning the same code again (past the debounce) now finds it.
      await scan(tester, code);
      expect(find.byType(ScanUnknownChoiceSheet), findsNothing);
      expect(find.byType(EditItemModal), findsOneWidget);
      expect(qtyText(tester), '2');
    });

    testWidgets('a product with a different barcode asks first; Cancel saves '
        'nothing and keeps the search, Continue replaces it', (tester) async {
      await seedStore();
      final gulder = await seedProduct(name: 'Gulder', barcode: 'OLD-1');
      await stockIn(gulder, 4);
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner(code),
          loaded: const [],
          grantedKeys: both,
          storeId: storeId,
        ),
      );

      await scan(tester);
      await chooseLink(tester);
      expect(
        find.descendant(of: linkRow(gulder), matching: find.text('Barcode OLD-1')),
        findsOneWidget,
      );
      await tapLinkRow(tester, gulder);

      const warning = 'This replaces barcode OLD-1 on Gulder. Continue?';
      expect(find.text(warning), findsOneWidget);
      await tester.tap(find.widgetWithText(AppButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(find.text(warning), findsNothing);
      expect(find.byType(ScanLinkProductSheet), findsOneWidget);
      expect((await reload(gulder)).barcode, 'OLD-1');
      expect(find.byType(EditItemModal), findsNothing);

      await tapLinkRow(tester, gulder);
      await tester.tap(find.widgetWithText(AppButton, 'Continue'));
      await tester.pumpAndSettle();

      expect((await reload(gulder)).barcode, code);
      expect(find.byType(EditItemModal), findsOneWidget);
      await tapSheetButton(tester, 'Add to Cart');
      expect(cart.value.single['id'], gulder.id);
      await clearToast(tester);
    });

    testWidgets('closing the search saves nothing and keeps scanning', (
      tester,
    ) async {
      final malta = await seedProduct(name: 'Malta', barcode: null);
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner(code),
          loaded: const [],
          grantedKeys: both,
          storeId: storeId,
        ),
      );

      await scan(tester);
      await chooseLink(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(ScanLinkProductSheet),
          matching: find.byIcon(AppIcons.close),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ScanLinkProductSheet), findsNothing);
      expect(find.byType(EditItemModal), findsNothing);
      expect((await reload(malta)).barcode, isNull);
      expect(find.byType(BarcodeScanPage), findsOneWidget);
      expect(scanner.camera!.isRunning, isTrue);
    });

    testWidgets('a linked product with no stock here → the found-scan '
        'out-of-stock message', (
      tester,
    ) async {
      await seedStore();
      final malta = await seedProduct(name: 'Malta', barcode: null);
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner(code),
          loaded: const [],
          grantedKeys: const {'products.edit_price'},
          storeId: storeId,
        ),
      );

      await scan(tester);
      await chooseLink(tester);
      await tapLinkRow(tester, malta);

      expect((await reload(malta)).barcode, code);
      expect(find.byType(EditItemModal), findsNothing);
      expect(
        find.text('Malta is out of stock at Main Store'),
        findsOneWidget,
      );
      expect(find.textContaining('Saved.'), findsNothing);
      expect(scanner.camera!.isRunning, isTrue);
      await clearToast(tester);
    });

    for (final size in const [phoneSe1Portrait, androidCompactLandscape]) {
      testWidgets(
        'the choice and a long search never overflow and the last row is '
        'reachable at ${size.width.toInt()}x${size.height.toInt()}',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          await seedStore();
          final seeded = <ProductData>[
            for (var i = 0; i < 30; i++)
              await seedProduct(
                name: 'Product ${i.toString().padLeft(2, '0')} with a long name',
                barcode: null,
                size: 'big',
              ),
          ];
          await tester.pumpWidget(
            host(
              FakeBarcodeScanner(code),
              loaded: const [],
              grantedKeys: both,
              storeId: storeId,
            ),
          );

          await scan(tester);
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(find.byKey(kScanUnknownLinkKey));
          await tester.pumpAndSettle();
          await chooseLink(tester);
          expect(tester.takeException(), isNull);

          await tester.scrollUntilVisible(
            linkRow(seeded.last),
            200,
            scrollable: find
                .descendant(
                  of: find.byType(ScanLinkProductSheet),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.pumpAndSettle();
          await tester.tap(linkRow(seeded.last));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect((await reload(seeded.last)).barcode, code);

          await clearToast(tester);
        },
      );
    }
  });

  group('the scanner stays open (#319)', () {
    Future<void> openScanner(WidgetTester tester) async {
      await tester.tap(find.byType(PosBarcodeScanButton));
      await tester.pumpAndSettle();
    }

    String countText(WidgetTester tester) => tester
        .widget<Text>(
          find.descendant(
            of: find.byType(ScanCartCount),
            matching: find.byType(Text),
          ),
        )
        .data!;

    testWidgets('scan A → confirm → scan B → confirm puts both in the cart '
        'without the scanner closing', (tester) async {
      final a = await seedProduct(name: 'Star Lager', barcode: 'BC-A');
      final b = await seedProduct(name: 'Gulder', barcode: 'BC-B');
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner(),
          loaded: [
            ProductDataWithStock(product: a, totalStock: 10),
            ProductDataWithStock(product: b, totalStock: 10),
          ],
        ),
      );

      await openScanner(tester);
      expect(find.byType(BarcodeScanPage), findsOneWidget);
      expect(countText(tester), '0 items in cart');

      await scan(tester, 'BC-A');
      // The sheet is up over the scanner and the camera keeps running: it is
      // never paused for a read (that turned the torch off, and on Android
      // mobile_scanner 7.2.0 could not start again after it).
      expect(find.byType(EditItemModal), findsOneWidget);
      expect(scanner.camera!.isRunning, isTrue);
      await tapSheetButton(tester, 'Add to Cart');
      expect(find.byType(BarcodeScanPage), findsOneWidget);
      expect(scanner.camera!.isRunning, isTrue);
      expect(countText(tester), '1 item in cart');

      await scan(tester, 'BC-B');
      expect(find.byType(EditItemModal), findsOneWidget);
      await tester.enterText(qtyField(), '3');
      await tester.pump();
      await tapSheetButton(tester, 'Add to Cart');

      expect(find.byType(BarcodeScanPage), findsOneWidget);
      expect(scanner.camera!.isRunning, isTrue);
      expect(scanner.sessionCount, 1);
      expect(cart.value.map((l) => l['id']), [a.id, b.id]);
      expect(cart.value.map((l) => l['qty']), [1, 3]);
      // The running count follows the cart — units, not lines.
      expect(countText(tester), '4 items in cart');
      // The toast is shown from the scanner's context, over the camera.
      expect(find.text('Gulder ×3 added'), findsOneWidget);

      await clearToast(tester);
    });

    testWidgets('Cancel on the sheet returns to scanning and adds nothing', (
      tester,
    ) async {
      final a = await seedProduct(name: 'Star Lager', barcode: 'BC-A');
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner('BC-A'),
          loaded: [ProductDataWithStock(product: a, totalStock: 10)],
        ),
      );

      await scan(tester);
      await tapSheetButton(tester, 'Cancel');

      expect(find.byType(EditItemModal), findsNothing);
      expect(find.byType(BarcodeScanPage), findsOneWidget);
      expect(scanner.camera!.isRunning, isTrue);
      expect(cart.value, isEmpty);
      expect(countText(tester), '0 items in cart');

      // Still scanning: the next read opens the sheet again.
      await scan(tester);
      expect(find.byType(EditItemModal), findsOneWidget);
    });

    testWidgets('the same code within the debounce window is ignored; a '
        'different code is not', (tester) async {
      final a = await seedProduct(name: 'Star Lager', barcode: 'BC-A');
      final b = await seedProduct(name: 'Gulder', barcode: 'BC-B');
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner(),
          loaded: [
            ProductDataWithStock(product: a, totalStock: 10),
            ProductDataWithStock(product: b, totalStock: 10),
          ],
        ),
      );

      await scan(tester, 'BC-A');
      await tapSheetButton(tester, 'Cancel');

      // Same code, 1 s after resuming — still in frame, ignored.
      scanner.advance(const Duration(seconds: 1));
      scanner.camera!.read('BC-A');
      await tester.pumpAndSettle();
      expect(find.byType(EditItemModal), findsNothing);
      expect(scanner.camera!.isRunning, isTrue);

      // A different code straight away is read.
      scanner.camera!.read('BC-B');
      await tester.pumpAndSettle();
      expect(find.byType(EditItemModal), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(EditItemModal),
          matching: find.text('Gulder'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('reads while a sheet is open are ignored', (tester) async {
      final a = await seedProduct(name: 'Star Lager', barcode: 'BC-A');
      final b = await seedProduct(name: 'Gulder', barcode: 'BC-B');
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner(),
          loaded: [
            ProductDataWithStock(product: a, totalStock: 10),
            ProductDataWithStock(product: b, totalStock: 10),
          ],
        ),
      );

      await scan(tester, 'BC-A');
      scanner.camera!.read('BC-B');
      await tester.pumpAndSettle();

      // Still the one sheet, for the first code; the camera kept running.
      expect(find.byType(EditItemModal), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(EditItemModal),
          matching: find.text('Gulder'),
        ),
        findsNothing,
      );
      expect(scanner.camera!.isRunning, isTrue);
    });

    testWidgets('✕ closes the scanner onto the till with the cart intact', (
      tester,
    ) async {
      final a = await seedProduct(name: 'Star Lager', barcode: 'BC-A');
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner('BC-A'),
          loaded: [ProductDataWithStock(product: a, totalStock: 10)],
        ),
      );

      await scan(tester);
      await tapSheetButton(tester, 'Add to Cart');
      await clearToast(tester);
      final camera = scanner.camera!;

      await tester.tap(find.byTooltip('Close scanner'));
      await tester.pumpAndSettle();

      expect(find.byType(BarcodeScanPage), findsNothing);
      expect(find.byType(PosBarcodeScanButton), findsOneWidget);
      expect(camera.isDisposed, isTrue);
      expect(cart.value.single['qty'], 1);
    });

    testWidgets('system back closes the scanner with the cart intact', (
      tester,
    ) async {
      final a = await seedProduct(name: 'Star Lager', barcode: 'BC-A');
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner('BC-A'),
          loaded: [ProductDataWithStock(product: a, totalStock: 10)],
        ),
      );

      await scan(tester);
      await tapSheetButton(tester, 'Add to Cart');
      await clearToast(tester);
      final camera = scanner.camera!;

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(BarcodeScanPage), findsNothing);
      expect(camera.isDisposed, isTrue);
      expect(cart.value.single['qty'], 1);
    });

    testWidgets('backgrounding stops the camera; coming back restarts it, '
        'but not while a sheet is open', (tester) async {
      final a = await seedProduct(name: 'Star Lager', barcode: 'BC-A');
      signIn();
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner('BC-A'),
          loaded: [ProductDataWithStock(product: a, totalStock: 10)],
        ),
      );
      await openScanner(tester);
      final camera = scanner.camera!;

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(camera.isRunning, isFalse);
      // A read can't sneak in while the app is in the background.
      camera.read('BC-A');
      await tester.pumpAndSettle();
      expect(find.byType(EditItemModal), findsNothing);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(camera.isRunning, isTrue);

      // Backgrounded with a sheet open: the camera stays off until the sheet
      // closes.
      await scan(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(camera.isRunning, isFalse);
      await tapSheetButton(tester, 'Cancel');
      expect(camera.isRunning, isTrue);

      // Supabase restarts its token auto-refresh timer on resume; stop it so
      // no timer outlives the test.
      Supabase.instance.client.auth.stopAutoRefresh();

      // Unmount inside the test so the providers' drift streams close here,
      // not after the test's timer check.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('coming back to a locked app does not restart the camera', (
      tester,
    ) async {
      // Nobody signed in = the app is locked.
      await tester.pumpWidget(host(FakeBarcodeScanner(), loaded: const []));
      await openScanner(tester);
      final camera = scanner.camera!;

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(camera.isRunning, isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(camera.isRunning, isFalse);

      Supabase.instance.client.auth.stopAutoRefresh();

      // Unmount inside the test so the providers' drift streams close here,
      // not after the test's timer check.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('the app locking closes the scanner and stops the camera', (
      tester,
    ) async {
      final a = await seedProduct(name: 'Star Lager', barcode: 'BC-A');
      signIn();
      await tester.pumpWidget(
        host(
          FakeBarcodeScanner('BC-A'),
          loaded: [ProductDataWithStock(product: a, totalStock: 10)],
        ),
      );

      // Locks with the quantity sheet open over the scanner.
      await scan(tester);
      expect(find.byType(EditItemModal), findsOneWidget);
      final camera = scanner.camera!;

      auth.lockApp();
      await tester.pumpAndSettle();

      expect(camera.stopCount, greaterThan(0));
      expect(camera.isDisposed, isTrue);
      expect(find.byType(EditItemModal), findsNothing);
      expect(find.byType(BarcodeScanPage), findsNothing);

      // Unmount inside the test so the providers' drift streams close here,
      // not after the test's timer check.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('the torch toggle flips the torch and hides with no torch', (
      tester,
    ) async {
      await tester.pumpWidget(host(FakeBarcodeScanner(), loaded: const []));
      await openScanner(tester);

      expect(find.byTooltip('Turn torch on'), findsOneWidget);
      await tester.tap(find.byTooltip('Turn torch on'));
      await tester.pump();
      expect(scanner.camera!.torch.value, isTrue);
      expect(find.byTooltip('Turn torch off'), findsOneWidget);

      scanner.camera!.reportTorch(null);
      await tester.pump();
      expect(find.byTooltip('Turn torch on'), findsNothing);
      expect(find.byTooltip('Turn torch off'), findsNothing);
    });
  });
}
