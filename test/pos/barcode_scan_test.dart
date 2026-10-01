// barcode_scan_test.dart
//
// #118 / #317 — POS barcode scanning. Drives the scan flow through a FAKE
// scanner (no camera can run headless), exercising the whole always-visible
// scan button:
//   - a FOUND, sellable barcode opens the tap-and-hold "Add to Cart" sheet
//     (#317) at the active store's stock cap and the active tier; it starts one
//     above what's already in the cart, and Cancel / dismiss add nothing;
//   - a found but unsellable product (out of stock here, all already in the
//     cart, switched off) shows its message and no sheet;
//   - two products sharing a barcode show the "Which one?" list (#318); a
//     pick continues as a single match, and dismissing adds nothing;
//   - an UNKNOWN barcode toasts and opens Add Product with the code pre-filled
//     (unchanged in #317);
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
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/pos/providers/pos_providers.dart';
import 'package:reebaplus_pos/features/pos/services/barcode_scanner.dart';
import 'package:reebaplus_pos/features/pos/widgets/edit_item_modal.dart';
import 'package:reebaplus_pos/features/pos/widgets/pos_barcode_scan_button.dart';
import 'package:reebaplus_pos/features/pos/widgets/scan_which_one_sheet.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/services/cart_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

import '../helpers/viewports.dart';

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
    BarcodeScanner scanner, {
    required List<ProductDataWithStock> loaded,
    PriceTier tier = PriceTier.retailer,
    String? storeName = 'Main Store',
    void Function(BuildContext, String)? onUnknown,
    List<ProductDataWithStock> Function()? readStoreProducts,
  }) {
    return ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        cartProvider.overrideWith((ref) => cart),
        barcodeScannerProvider.overrideWithValue(scanner),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          floatingActionButton: PosBarcodeScanButton(
            tier: tier,
            loadedProducts: loaded,
            storeName: storeName,
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

  Future<void> scan(WidgetTester tester) async {
    await tester.tap(find.byType(PosBarcodeScanButton));
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

  testWidgets('scan button is always visible (not gated on the cart) and textless', (
    tester,
  ) async {
    await tester.pumpWidget(host(_FakeBarcodeScanner(null), loaded: const []));
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
      final scanner = _FakeBarcodeScanner('BC-1');
      await tester.pumpWidget(
        host(
          scanner,
          loaded: [ProductDataWithStock(product: product, totalStock: 10)],
        ),
      );

      await scan(tester);

      expect(scanner.scanCount, 1);
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
          _FakeBarcodeScanner('BC-1'),
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
          _FakeBarcodeScanner('BC-1'),
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
          _FakeBarcodeScanner('BC-1'),
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
          _FakeBarcodeScanner('BC-1'),
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
          _FakeBarcodeScanner('BC-1'),
          loaded: [ProductDataWithStock(product: product, totalStock: 10)],
        ),
      );

      await scan(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(EditItemModal),
          matching: find.byIcon(Icons.close),
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
          _FakeBarcodeScanner('BC-1'),
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
          _FakeBarcodeScanner('BC-2'),
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
        host(_FakeBarcodeScanner('BC-2'), loaded: const [], storeName: null),
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
          _FakeBarcodeScanner('BC-2'),
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
          _FakeBarcodeScanner('BC-2'),
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
          _FakeBarcodeScanner('BC-DUP'),
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
          _FakeBarcodeScanner('BC-DUP'),
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
          _FakeBarcodeScanner('BC-DUP'),
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
          _FakeBarcodeScanner('BC-DUP'),
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
          _FakeBarcodeScanner('BC-DUP'),
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
          _FakeBarcodeScanner('BC-DUP'),
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
          matching: find.byIcon(Icons.close),
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
              _FakeBarcodeScanner('BC-DUP'),
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

    await scan(tester);

    expect(find.byType(EditItemModal), findsNothing);
    expect(cart.value, isEmpty);
    expect(find.text('No product matches that barcode'), findsOneWidget);
    // Add Product is opened with the scanned code pre-filled.
    expect(openedWith, 'NOPE-999');

    await clearToast(tester);
  });

  testWidgets('dismissed scan (null) is a no-op', (tester) async {
    final scanner = _FakeBarcodeScanner(null);
    await tester.pumpWidget(host(scanner, loaded: const []));

    await scan(tester);

    expect(scanner.scanCount, 1);
    expect(find.byType(EditItemModal), findsNothing);
    expect(cart.value, isEmpty);
  });
}
