// Visual goldens for the Cart restyle (#385, PRD #346 Wave 1).
//
// The phone Cart tab inside MainLayout at 390×844 and 844×390, and the cart
// panel at 800×1280 (slide-in, open) and 1280×800 (fixed), light and dark, with
// the mockup's sample data (Walk-in Customer, Star Lager ×2, Hero Lager ×1,
// Eva Water ×2). `cart_crates_800x1280_*` adds the crate cards and a discount.
//
// The panel goldens capture the panel only (`Key('cart-panel')`), so the POS
// grid beside it — restyled separately — does not churn them.
//
// Mockups: `docs/redesign/mockups/tablet-cart-panel-*.png` (800×1280, and the
// crates golden) and `wide-pos-cart-*.png` (1280×800). There is no phone Cart
// mockup; the phone goldens are the same panel design at full width.
//
// The PNGs live in test/redesign/goldens/ — never test/golden/ (Linux CI).
// Regenerate with:
//
//     flutter test --update-goldens test/redesign/cart_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/providers/first_run_tour_state.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/main_layout.dart';

import '../helpers/screen_harness.dart';
import '../pos/cart_fixture.dart';

/// MainLayout's Cart tab (its tab list's index 8).
const int _cartTab = 8;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const grants = {'sales.make', 'stock.view', 'products.add'};

  const prefs = {
    'push_soft_ask_shown_v1': true,
    'pos_grid_columns': 2,
    'pos_is_list_view': false,
    'hint_pos_gestures': 2,
    'hint_cart_tap_edit': 2,
  };

  late ScreenTestEnvironment env;

  setUpAll(() {
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

  tearDown(() async {
    await env.dispose();
    NavigationService().resetNavigation();
  });

  Future<void> pumpGolden(
    WidgetTester tester, {
    required Brightness brightness,
    required Size size,
    required EdgeInsets padding,
    required String goldenName,
    required bool panel,
    bool crates = false,
  }) async {
    NavigationService()
      ..resetNavigation()
      ..beginSessionLanding()
      ..setIndex(panel ? NavigationService.posTab : _cartTab);

    final context = await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: padding,
      screen: const MainLayout(),
      bottomNavHeight: 0,
      grantedKeys: grants,
      roleSlug: 'manager',
      roleName: 'Manager',
      roleRank: 3,
      theme: brightness == Brightness.light
          ? AppTheme.light()
          : AppTheme.dark(),
      overrides: [
        firstRunTourStopProvider.overrideWithValue(TourStop.none),
        firstRunSurfaceStateProvider.overrideWithValue(
          FirstRunSurfaceState.hasContent,
        ),
      ],
      sharedPreferences: prefs,
      settle: false,
    );

    final cart = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(cartProvider);
    fillMockupCart(cart, crates: crates);
    if (crates) {
      cart.setLineDiscount(
        'Star Lager',
        kind: 'naira',
        enteredValue: 500,
        discountKobo: 50000,
      );
      // Empty Crates shows for a registered customer only (§3.13).
      cart.setActiveCustomer(
        Customer(
          id: 'golden-customer',
          name: 'Chinedu Okafor',
          addressText: '',
          googleMapsLocation: '',
        ),
      );
    }

    Future<void> settle() async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 250));
      }
    }

    await settle();
    final viewCart = find.byKey(const Key('view-cart-bar'));
    if (panel && viewCart.evaluate().isNotEmpty) {
      await tester.tap(viewCart);
      await settle();
    }

    if (crates) {
      // Scroll to the end so the Discount card shows above the footer.
      final scroll = find.descendant(
        of: find.byKey(const Key('cart-panel')),
        matching: find.byType(CustomScrollView),
      );
      await tester.drag(scroll.first, const Offset(0, -600));
      await settle();
    }

    await expectLater(
      panel ? find.byKey(const Key('cart-panel')) : find.byType(MainLayout),
      matchesGoldenFile('goldens/$goldenName.png'),
    );

    await disposeScreen(tester);
  }

  const cases = <(String, Size, EdgeInsets, bool)>[
    ('390x844', Size(390, 844), EdgeInsets.only(top: 24, bottom: 48), false),
    ('844x390', Size(844, 390), EdgeInsets.only(top: 24, right: 48), false),
    ('800x1280', Size(800, 1280), EdgeInsets.only(top: 24, bottom: 24), true),
    ('1280x800', Size(1280, 800), EdgeInsets.only(top: 24), true),
  ];

  group('walk-in, no crates', () {
    setUp(() async {
      env = await setupScreenTestEnvironment(sharedPreferences: prefs);
    });

    for (final brightness in Brightness.values) {
      final themeName = brightness == Brightness.light ? 'light' : 'dark';
      for (final (sizeName, size, padding, panel) in cases) {
        testWidgets(
          'cart $sizeName $themeName',
          (tester) => pumpGolden(
            tester,
            brightness: brightness,
            size: size,
            padding: padding,
            panel: panel,
            goldenName: 'cart_${sizeName}_$themeName',
          ),
        );
      }
    }
  });

  group('crate business, registered customer, a discount', () {
    setUp(() async {
      env = await setupScreenTestEnvironment(
        sharedPreferences: prefs,
        businessType: 'Bar',
      );
    });

    for (final brightness in Brightness.values) {
      final themeName = brightness == Brightness.light ? 'light' : 'dark';
      testWidgets(
        'cart crates 800x1280 $themeName',
        (tester) => pumpGolden(
          tester,
          brightness: brightness,
          size: const Size(800, 1280),
          padding: const EdgeInsets.only(top: 24, bottom: 24),
          panel: true,
          crates: true,
          goldenName: 'cart_crates_800x1280_$themeName',
        ),
      );
    }
  });
}
