// pos_redesign_test.dart
//
// #384 (PRD #346 Wave 1): the POS screen restyled to the mockups. What the new
// parts must do, and that nothing the old screen did was lost:
//   - top bar: ScreenHeader "Point of Sale" + the store, live bell, menu only
//     under 600dp, the kept view selector;
//   - search + scan: square scan beside the search on a phone, a "Scan
//     Barcode" pill at 600dp+; both open the scan session;
//   - category chips (shared CategoryChip) still filter;
//   - ProductTile grid: tap adds (+ toast), hold opens the quantity sheet,
//     the in-cart badge (fractions too), out of stock dims and ignores taps,
//     the price tier still changes prices;
//   - Quick Sale still opens; the tier row keeps its controls;
//   - columns from the grid's real width at each size;
//   - no overflow at 360dp @1.3 and 844×390 with insets, keyboard up.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/providers/first_run_tour_state.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/shared/scanner/scanner_providers.dart';
import 'package:reebaplus_pos/features/pos/screens/pos_home_screen.dart';
import 'package:reebaplus_pos/features/pos/widgets/edit_item_modal.dart';
import 'package:reebaplus_pos/features/pos/widgets/pos_barcode_scan_button.dart';
import 'package:reebaplus_pos/features/pos/widgets/product_grid.dart';
import 'package:reebaplus_pos/features/pos/widgets/quick_sale_modal.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/main_layout.dart';
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';
import 'package:reebaplus_pos/shared/widgets/notifications_modal.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/category_chip.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/product_tile.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/screen_header.dart';

import '../helpers/fake_barcode_scanner.dart';
import '../helpers/pos_home_harness.dart';
import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PosTestEnvironment env;

  final hasContent = firstRunSurfaceStateProvider.overrideWithValue(
    FirstRunSurfaceState.hasContent,
  );

  setUpAll(() {
    // The frame's Home tab listens to connectivity; answer "wifi".
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (call) async => <String>['wifi'],
    );
    messenger.setMockStreamHandler(
      const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
      MockStreamHandler.inline(
        onListen: (arguments, events) => events.success(<String>['wifi']),
      ),
    );
  });

  setUp(() async {
    env = await setupTestPosEnvironment(productCount: 8);
    AppNotification.hide();
  });

  tearDown(() async {
    AppNotification.hide();
    await env.dispose();
  });

  /// Lets a toast's timer run out before the tree comes down.
  Future<void> drainToasts(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  Finder tileOf(ProductData p) => find.byKey(posProductTileKey(p.id));

  ProductTile productTile(WidgetTester tester, ProductData p) =>
      tester.widget<ProductTile>(
        find.descendant(of: tileOf(p), matching: find.byType(ProductTile)),
      );

  int renderedColumns(WidgetTester tester) {
    final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    return (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
        .crossAxisCount;
  }

  Future<void> setStock(String productId, int qty) => env.db.customStatement(
    "UPDATE inventory SET quantity = $qty WHERE product_id = '$productId'",
  );

  /// POS inside the real frame (MainLayout), for the rail, the fixed cart
  /// panel and the toast's place.
  Future<BuildContext> pumpPosFrame(
    WidgetTester tester, {
    required Size size,
    EdgeInsets padding = EdgeInsets.zero,
  }) async {
    NavigationService()
      ..resetNavigation()
      ..beginSessionLanding()
      ..setIndex(NavigationService.posTab);
    addTearDown(NavigationService().resetNavigation);
    final context = await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: padding,
      screen: const MainLayout(),
      bottomNavHeight: 0,
      grantedKeys: const {'sales.make', 'stock.view'},
      overrides: [
        firstRunTourStopProvider.overrideWithValue(TourStop.none),
        hasContent,
      ],
      sharedPreferences: const {
        'push_soft_ask_shown_v1': true,
        'hint_pos_gestures': 2,
        'hint_cart_tap_edit': 2,
      },
      settle: false,
    );
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
    return context;
  }

  group('top bar', () {
    testWidgets('"Point of Sale", the store, the live bell and the view '
        'selector; menu under 600dp', (tester) async {
      for (var i = 0; i < 3; i++) {
        await env.db.notificationsDao.create('info', 'Note $i');
      }
      await pumpPosHome(
        tester,
        env: env,
        size: const Size(390, 844),
        overrides: [hasContent],
      );
      final header = find.byType(ScreenHeader);
      expect(header, findsOneWidget);
      expect(
        find.descendant(of: header, matching: find.text('Point of Sale')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: header, matching: find.text('Main Store')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: header, matching: find.byType(MenuButton)),
        findsOneWidget,
      );
      expect(find.byKey(kPosViewSelectorKey), findsOneWidget);
      final bell = find.byType(HeaderBell);
      expect(bell, findsOneWidget);
      expect(tester.widget<HeaderBell>(bell).count, 3);
      expect(
        tester.getSize(bell).height,
        greaterThanOrEqualTo(kMinInteractiveDimension),
      );

      await tester.tap(bell);
      // Bounded: the modal's list may animate a loader.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(NotificationsModal), findsOneWidget);
      await disposePosHome(tester);
    });

    testWidgets('no menu button in the rail layout (the rail has it)', (
      tester,
    ) async {
      await pumpPosHome(
        tester,
        env: env,
        size: const Size(800, 1280),
        overrides: [hasContent],
      );
      expect(
        find.descendant(
          of: find.byType(ScreenHeader),
          matching: find.byType(MenuButton),
        ),
        findsNothing,
      );
      expect(find.byType(HeaderBell), findsOneWidget);
      await disposePosHome(tester);
    });

    testWidgets('the view selector still switches to the list view', (
      tester,
    ) async {
      await pumpPosHome(
        tester,
        env: env,
        size: const Size(390, 844),
        overrides: [hasContent],
      );
      expect(find.byType(SliverGrid), findsOneWidget);
      await tester.tap(find.byKey(kPosViewSelectorKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('List View'));
      await tester.pumpAndSettle();
      expect(find.byType(SliverGrid), findsNothing);
      expect(tileOf(env.products.first), findsOneWidget);
      await disposePosHome(tester);
    });
  });

  group('search + scan', () {
    testWidgets('phone: a square scan button beside the search field', (
      tester,
    ) async {
      final scanner = FakeBarcodeScanner();
      await pumpPosHome(
        tester,
        env: env,
        size: const Size(390, 844),
        overrides: [
          hasContent,
          barcodeScannerProvider.overrideWithValue(scanner),
        ],
      );
      final scan = find.byKey(kPosScannerKey);
      final search = tester.getRect(find.byKey(kPosSearchFieldKey));
      final button = tester.getRect(scan);
      expect(
        tester.widget<PosBarcodeScanButton>(scan).shape,
        PosScanButtonShape.square,
      );
      expect(button.width, moreOrLessEquals(button.height, epsilon: 0.5));
      expect(button.height, greaterThanOrEqualTo(kMinInteractiveDimension));
      expect(button.left, greaterThan(search.right));
      expect(button.center.dy, moreOrLessEquals(search.center.dy, epsilon: 4));
      expect(
        find.descendant(of: find.byKey(kPosSearchBandKey), matching: scan),
        findsOneWidget,
        reason: 'the scan button rides in the frozen band, not a FAB',
      );
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.text('Scan Barcode'), findsNothing);

      await tester.tap(scan);
      await tester.pumpAndSettle();
      expect(scanner.sessionCount, 1, reason: 'the scan session still opens');
      await disposePosHome(tester);
    });

    testWidgets('tablet: a "Scan Barcode" pill beside the search field', (
      tester,
    ) async {
      final scanner = FakeBarcodeScanner();
      await pumpPosHome(
        tester,
        env: env,
        size: const Size(800, 1280),
        overrides: [
          hasContent,
          barcodeScannerProvider.overrideWithValue(scanner),
        ],
      );
      final scan = find.byKey(kPosScannerKey);
      expect(
        tester.widget<PosBarcodeScanButton>(scan).shape,
        PosScanButtonShape.pill,
      );
      expect(
        find.descendant(of: scan, matching: find.text('Scan Barcode')),
        findsOneWidget,
      );
      final search = tester.getRect(find.byKey(kPosSearchFieldKey));
      final button = tester.getRect(scan);
      expect(button.left, greaterThan(search.right));
      expect(button.height, greaterThanOrEqualTo(kMinInteractiveDimension));
      await tester.tap(scan);
      await tester.pumpAndSettle();
      expect(scanner.sessionCount, 1);
      await disposePosHome(tester);
    });

    testWidgets('search still narrows the grid', (tester) async {
      await pumpPosHome(
        tester,
        env: env,
        size: const Size(390, 844),
        overrides: [hasContent],
      );
      await tester.enterText(find.byKey(kPosSearchFieldKey), 'Product 3');
      await tester.pumpAndSettle();
      expect(tileOf(env.products[2]), findsOneWidget);
      expect(tileOf(env.products[0]), findsNothing);
      await disposePosHome(tester);
    });
  });

  testWidgets('category chips are the shared CategoryChip and still filter', (
    tester,
  ) async {
    final waterId = UuidV7.generate();
    await env.db
        .into(env.db.categories)
        .insert(
          CategoriesCompanion.insert(
            id: Value(waterId),
            businessId: env.businessId,
            name: 'Water',
          ),
        );
    await env.db.customStatement(
      "UPDATE products SET category_id = '$waterId' "
      "WHERE id = '${env.products[1].id}'",
    );
    await pumpPosHome(
      tester,
      env: env,
      size: const Size(390, 844),
      overrides: [hasContent],
    );
    final chips = find.descendant(
      of: find.byKey(kPosCategoryChipsKey),
      matching: find.byType(CategoryChip),
    );
    expect(
      tester.widgetList<CategoryChip>(chips).map((c) => c.label).first,
      'All',
    );
    expect(tester.widget<CategoryChip>(chips.first).selected, isTrue);

    await tester.tap(find.widgetWithText(CategoryChip, 'Water'));
    await tester.pumpAndSettle();
    expect(tileOf(env.products[1]), findsOneWidget);
    expect(tileOf(env.products[0]), findsNothing);
    expect(
      tester
          .widget<CategoryChip>(find.widgetWithText(CategoryChip, 'Water'))
          .selected,
      isTrue,
    );

    await tester.tap(find.widgetWithText(CategoryChip, 'All'));
    await tester.pumpAndSettle();
    expect(tileOf(env.products[0]), findsOneWidget);
    await disposePosHome(tester);
  });

  group('tiles', () {
    testWidgets('tap adds one to the cart and shows the badge', (tester) async {
      final harness = await pumpPosHome(
        tester,
        env: env,
        size: const Size(390, 844),
        overrides: [hasContent],
      );
      final cart = ProviderScope.containerOf(
        harness.context,
      ).read(cartProvider);
      final p = env.products.first;
      expect(productTile(tester, p).inCartQty, 0);

      await tester.tap(tileOf(p));
      await tester.pump();
      expect(cart.value.single['qty'], 1);
      expect(find.text('${p.name} added to cart'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(productTile(tester, p).inCartQty, 1);
      expect(
        find.descendant(of: tileOf(p), matching: find.text('1')),
        findsOneWidget,
      );

      cart.addItem(p, qty: 2, maxStock: 50, tier: PriceTier.retailer);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: tileOf(p), matching: find.text('3')),
        findsOneWidget,
        reason: 'the badge counts the whole cart line',
      );
      await drainToasts(tester);
      await disposePosHome(tester);
    });

    testWidgets('a fractional cart quantity keeps its decimal on the badge', (
      tester,
    ) async {
      final harness = await pumpPosHome(
        tester,
        env: env,
        size: const Size(390, 844),
        overrides: [hasContent],
      );
      final p = env.products.first;
      ProviderScope.containerOf(
        harness.context,
      ).read(cartProvider).addItem(p, qty: 1.5, maxStock: 50);
      await tester.pumpAndSettle();
      expect(productTile(tester, p).inCartQty, greaterThan(0));
      expect(
        find.descendant(of: tileOf(p), matching: find.text('1.5')),
        findsOneWidget,
      );
      await disposePosHome(tester);
    });

    testWidgets('hold opens the quantity sheet', (tester) async {
      await pumpPosHome(
        tester,
        env: env,
        size: const Size(390, 844),
        overrides: [hasContent],
      );
      await tester.longPress(tileOf(env.products.first));
      await tester.pumpAndSettle();
      expect(find.byType(EditItemModal), findsOneWidget);
      await disposePosHome(tester);
    });

    testWidgets('out of stock dims the tile and ignores tap and hold', (
      tester,
    ) async {
      final p = env.products.first;
      await setStock(p.id, 0);
      final harness = await pumpPosHome(
        tester,
        env: env,
        size: const Size(390, 844),
        overrides: [hasContent],
      );
      expect(productTile(tester, p).stockLevel, StockLevel.out);
      final dim = tester.widget<Opacity>(
        find.descendant(of: tileOf(p), matching: find.byType(Opacity)).first,
      );
      expect(dim.opacity, lessThan(1));
      expect(
        find.descendant(of: tileOf(p), matching: find.text('Out of stock')),
        findsOneWidget,
      );

      await tester.tap(tileOf(p), warnIfMissed: false);
      await tester.longPress(tileOf(p), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(
        ProviderScope.containerOf(harness.context).read(cartProvider).value,
        isEmpty,
      );
      expect(find.byType(EditItemModal), findsNothing);
      await disposePosHome(tester);
    });

    testWidgets('low stock (5 or fewer) is amber, more is green', (
      tester,
    ) async {
      await setStock(env.products[0].id, 5);
      await setStock(env.products[1].id, 6);
      await pumpPosHome(
        tester,
        env: env,
        size: const Size(390, 844),
        overrides: [hasContent],
      );
      expect(productTile(tester, env.products[0]).stockLevel, StockLevel.low);
      expect(productTile(tester, env.products[0]).stockLabel, '5');
      expect(productTile(tester, env.products[1]).stockLevel, StockLevel.ok);
      await disposePosHome(tester);
    });

    testWidgets('the price tier switch still changes the tile prices', (
      tester,
    ) async {
      await pumpPosHome(
        tester,
        env: env,
        size: const Size(390, 844),
        overrides: [hasContent],
      );
      final p = env.products.first;
      expect(productTile(tester, p).priceLabel, contains('1,000'));

      await tester.tap(find.byKey(kPosTierDropdownKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wholesaler').last);
      await tester.pumpAndSettle();
      expect(productTile(tester, p).priceLabel, contains('900'));
      await disposePosHome(tester);
    });
  });

  testWidgets('Quick Sale still opens, from a 48dp button in the tier row', (
    tester,
  ) async {
    await pumpPosHome(
      tester,
      env: env,
      size: const Size(390, 844),
      overrides: [hasContent],
    );
    final quickSale = find.byKey(kPosQuickSaleKey);
    expect(
      find.descendant(of: find.byKey(kPosTierRowKey), matching: quickSale),
      findsOneWidget,
    );
    expect(
      tester.getSize(quickSale).height,
      greaterThanOrEqualTo(kMinInteractiveDimension),
    );
    await tester.tap(quickSale);
    await tester.pumpAndSettle();
    expect(find.byType(QuickSaleModal), findsOneWidget);
    await disposePosHome(tester);
  });

  group('columns from the grid\'s real width', () {
    testWidgets('upright phone 390×844: 2', (tester) async {
      await pumpPosHome(
        tester,
        env: env,
        size: const Size(390, 844),
        overrides: [hasContent],
        posGridColumns: 2,
      );
      expect(renderedColumns(tester), 2);
      await disposePosHome(tester);
    });

    testWidgets('tablet 800×1280 beside the rail, cart closed: 4', (
      tester,
    ) async {
      await pumpPosFrame(tester, size: const Size(800, 1280));
      expect(renderedColumns(tester), 4);
      await disposeScreen(tester);
    });

    testWidgets('wide 1280×800 beside the fixed cart panel: 4', (tester) async {
      final context = await pumpPosFrame(tester, size: const Size(1280, 800));
      ProviderScope.containerOf(
        context,
        listen: false,
      ).read(cartProvider).addItem(env.products.first, qty: 1, maxStock: 50);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('cart-panel')), findsOneWidget);
      expect(renderedColumns(tester), 4);
      await disposeScreen(tester);
    });

    testWidgets('sideways phone 844×390 with insets: 4', (tester) async {
      await pumpPosFrame(
        tester,
        size: const Size(844, 390),
        padding: const EdgeInsets.only(top: 24, right: 48),
      );
      expect(renderedColumns(tester), 4);
      await disposeScreen(tester);
    });
  });

  group('short screen (sideways phone)', () {
    testWidgets('844×390 with insets: a full product row on first view, the '
        'tier controls in the search row', (tester) async {
      tester.view.padding = const FakeViewPadding(top: 24, right: 48);
      tester.view.viewPadding = const FakeViewPadding(top: 24, right: 48);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      final context = await pumpPosFrame(
        tester,
        size: const Size(844, 390),
        padding: const EdgeInsets.only(top: 24, right: 48),
      );
      // With a cart, so the View Cart bar takes its slot too.
      ProviderScope.containerOf(
        context,
        listen: false,
      ).read(cartProvider).addItem(env.products[1], qty: 1, maxStock: 50);
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(find.byKey(const Key('view-cart-bar')), findsOneWidget);

      final surface = tester.getRect(find.byKey(kPosScrollSurfaceKey));
      final band = tester.getRect(find.byKey(kPosSearchBandKey));
      final tile = tester.getRect(tileOf(env.products.first));
      expect(tile.top, greaterThanOrEqualTo(band.bottom));
      expect(
        tile.bottom,
        lessThanOrEqualTo(surface.bottom),
        reason: 'a whole tile must show on first view, above the View Cart bar',
      );
      expect(tileOf(env.products.first).hitTestable(), findsOneWidget);

      // One row: search, tier, manufacturer, Quick Sale, scan (square).
      expect(find.byKey(kPosTierRowKey), findsNothing);
      final search = tester.getRect(find.byKey(kPosSearchFieldKey));
      for (final key in [
        kPosTierDropdownKey,
        kPosManufacturerDropdownKey,
        kPosQuickSaleKey,
        kPosScannerKey,
      ]) {
        final r = tester.getRect(find.byKey(key));
        expect(r.center.dy, moreOrLessEquals(search.center.dy, epsilon: 4));
        expect(r.left, greaterThan(search.right), reason: '$key');
        expect(r.right, lessThanOrEqualTo(844 - 48), reason: '$key');
        expect(
          r.height,
          greaterThanOrEqualTo(kMinInteractiveDimension),
          reason: '$key',
        );
      }
      expect(
        tester.widget<PosBarcodeScanButton>(find.byKey(kPosScannerKey)).shape,
        PosScanButtonShape.square,
      );
      expectNoOverflow(tester, reason: 'POS short layout at 844×390');
      await disposeScreen(tester);
    });

    testWidgets('upright phone and tablet keep the separate tier row', (
      tester,
    ) async {
      for (final size in const [Size(390, 844), Size(800, 1280)]) {
        await pumpPosHome(
          tester,
          env: env,
          size: size,
          overrides: [hasContent],
        );
        expect(find.byKey(kPosTierRowKey), findsOneWidget, reason: '$size');
        expect(
          find.descendant(
            of: find.byKey(kPosTierRowKey),
            matching: find.byKey(kPosQuickSaleKey),
          ),
          findsOneWidget,
        );
        await disposePosHome(tester);
      }
    });
  });

  group('no overflow', () {
    testWidgets('360dp at text scale 1.3, 3-button nav, then searching with '
        'the keyboard up', (tester) async {
      await pumpPosHome(
        tester,
        env: env,
        size: const Size(360, 740),
        padding: const EdgeInsets.only(top: 24, bottom: 48),
        textScaler: const TextScaler.linear(1.3),
        overrides: [hasContent],
      );
      expectNoOverflow(tester, reason: 'POS at 360dp @1.3');
      expect(tileOf(env.products.first).hitTestable(), findsOneWidget);
      // Every tap target in the chrome keeps 48dp.
      for (final key in [
        kPosScannerKey,
        kPosQuickSaleKey,
        kPosViewSelectorKey,
      ]) {
        expect(
          tester.getSize(find.byKey(key)).height,
          greaterThanOrEqualTo(kMinInteractiveDimension),
          reason: '$key',
        );
      }
      await tester.enterText(find.byKey(kPosSearchFieldKey), 'Product');
      await tester.pumpAndSettle();
      expectNoOverflow(tester, reason: 'POS searching at 360dp @1.3');
      await disposePosHome(tester);

      await pumpPosHome(
        tester,
        env: env,
        size: const Size(360, 740),
        padding: const EdgeInsets.only(top: 24),
        textScaler: const TextScaler.linear(1.3),
        overrides: [hasContent],
      );
      // The keyboard (300dp) takes the bottom of the screen.
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expectNoOverflow(tester, reason: 'POS with the keyboard up @1.3');
      expect(find.byKey(kPosSearchFieldKey).hitTestable(), findsOneWidget);
      await disposePosHome(tester);
    });

    testWidgets('844×390 with a status bar and a right nav bar, in the frame, '
        'and at text scale 1.3', (tester) async {
      tester.view.padding = const FakeViewPadding(top: 24, right: 48);
      tester.view.viewPadding = const FakeViewPadding(top: 24, right: 48);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      await pumpPosFrame(
        tester,
        size: const Size(844, 390),
        padding: const EdgeInsets.only(top: 24, right: 48),
      );
      expectNoOverflow(tester, reason: 'POS at 844×390 with insets');
      // Short screen: the scan button is a square in the one search row.
      expect(find.text('Scan Barcode'), findsNothing);
      // Everything stays clear of the right navigation bar.
      for (final key in [
        kPosScannerKey,
        kPosQuickSaleKey,
        kPosTierDropdownKey,
        kPosManufacturerDropdownKey,
      ]) {
        expect(
          tester.getRect(find.byKey(key)).right,
          lessThanOrEqualTo(844 - 48),
          reason: '$key',
        );
      }
      expect(
        tester.getRect(find.byType(HeaderBell)).right,
        lessThanOrEqualTo(844 - 48),
      );
      await disposeScreen(tester);

      await pumpPosHome(
        tester,
        env: env,
        size: const Size(844, 390),
        padding: const EdgeInsets.only(top: 24, right: 48),
        textScaler: const TextScaler.linear(1.3),
        overrides: [hasContent],
      );
      expectNoOverflow(tester, reason: 'POS at 844×390 @1.3');
      await disposePosHome(tester);
    });
  });
}
