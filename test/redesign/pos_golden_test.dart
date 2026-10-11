// Visual goldens for the POS screen (#384, PRD #346 Wave 1). Compare:
//
//   pos_390x844_light.png   ↔ docs/redesign/mockups/phone-pos-light.png
//   pos_390x844_dark.png    ↔ docs/redesign/mockups/phone-pos-dark.png
//   pos_800x1280_*.png      ↔ docs/redesign/mockups/tablet-pos-*.png
//   pos_1280x800_*.png      ↔ docs/redesign/mockups/wide-pos-cart-*.png (the
//                             left side; the fixed cart panel is the Cart
//                             issue's)
//   pos_844x390_*.png       no mockup: the same parts, rail layout (+ _insets:
//                           a 24dp status bar and 3-button navigation on the
//                           right)
//
// Drawn inside the real app frame (MainLayout), signed in as the CEO, with the
// mockup's sample data: business "Stallion Global", store "Abuja HQ", the 16
// mockup products in their categories (Beer, Stout, Soft Drinks, Water, Malt,
// Energy), 8 unread notifications and a cart of Star Lager ×2, Hero Lager ×1
// and Eva Water ×2. Stock figures are the mockup's; the pill colours follow
// the POS rule (amber at or under 5, so Legend 4 and Amstel 3 are amber where
// the mockup draws red, and Hero 6 is green where it draws amber).
// `₦` draws as a box in tests (DM Sans has no Naira glyph).
//
// The PNGs live in test/redesign/goldens/ — never test/golden/, which CI runs
// on Linux. Regenerate with:
//
//     flutter test --update-goldens test/redesign/pos_golden_test.dart

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/providers/first_run_tour_state.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/main_layout.dart';

import '../helpers/screen_harness.dart';

/// The mockup's products: name, category, description (the mockup's size),
/// unit (the mockup's "Crate of 12" — the unit list has no pack size), price
/// (₦), stock.
const kMockupProducts = <(String, String, String, String, int, int)>[
  ('Star Lager', 'Beer', '60cl', 'Crate', 9600, 38),
  ('Trophy Lager', 'Beer', '60cl', 'Crate', 8400, 24),
  ('Hero Lager', 'Beer', '60cl', 'Crate', 8400, 6),
  ('Goldberg Lager', 'Beer', '60cl', 'Crate', 8700, 30),
  ('Guinness Foreign Extra', 'Stout', '60cl', 'Crate', 12000, 18),
  ('Legend Extra Stout', 'Stout', '60cl', 'Crate', 10200, 4),
  ('Coca-Cola', 'Soft Drinks', '50cl', 'Pack', 4200, 52),
  ('Fanta Orange', 'Soft Drinks', '50cl', 'Pack', 4200, 40),
  ('Sprite', 'Soft Drinks', '50cl', 'Pack', 4200, 35),
  ('Pepsi', 'Soft Drinks', '50cl', 'Pack', 4000, 28),
  ('Eva Water', 'Water', '75cl', 'Pack', 2700, 60),
  ('Aquafina', 'Water', '75cl', 'Pack', 2600, 44),
  ('Malta Guinness Can', 'Malt', '33cl', 'Pack', 13200, 20),
  ('Amstel Malta Can', 'Malt', '33cl', 'Pack', 12600, 3),
  ('Power Horse', 'Energy', '25cl', 'Pack', 16800, 15),
  ('Predator Energy', 'Energy', '40cl', 'Pack', 5400, 22),
];

/// Seeds [kMockupProducts] (and their categories) into [env]'s Abuja HQ
/// store, renames the business and store, and adds 8 unread notifications.
/// Returns the products by name.
Future<Map<String, ProductData>> seedPosMockup(
  ScreenTestEnvironment env,
) async {
  final db = env.db;
  final b = env.businessId;
  await db.customStatement(
    "UPDATE stores SET name = 'Abuja HQ' WHERE id = '${env.storeId}'",
  );
  await db.customStatement(
    "UPDATE businesses SET name = 'Stallion Global' WHERE id = '$b'",
  );
  // The harness's own "Drinks" category holds nothing here; drop it so the
  // chips read as the mockup's.
  await db.customStatement(
    "DELETE FROM categories WHERE id = '${env.categoryId}'",
  );
  final categoryIds = <String, String>{};
  for (final (_, category, _, _, _, _) in kMockupProducts) {
    if (categoryIds.containsKey(category)) continue;
    final id = UuidV7.generate();
    categoryIds[category] = id;
    await db
        .into(db.categories)
        .insert(
          CategoriesCompanion.insert(
            id: Value(id),
            businessId: b,
            name: category,
          ),
        );
  }
  final byName = <String, ProductData>{};
  for (final (name, category, size, pack, naira, stock) in kMockupProducts) {
    final id = UuidV7.generate();
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: Value(id),
            businessId: b,
            categoryId: Value(categoryIds[category]),
            name: name,
            subtitle: Value(size),
            unit: Value(pack),
            retailerPriceKobo: Value(naira * 100),
            wholesalerPriceKobo: Value(naira * 90),
          ),
        );
    await db
        .into(db.inventory)
        .insert(
          InventoryCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: b,
            storeId: env.storeId,
            productId: id,
            quantity: Value(stock),
          ),
        );
    byName[name] = await (db.select(
      db.products,
    )..where((t) => t.id.equals(id))).getSingle();
  }
  for (var i = 0; i < 8; i++) {
    await db.notificationsDao.create('info', 'Notification $i');
  }
  return byName;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const prefs = {
    'push_soft_ask_shown_v1': true,
    'pos_is_list_view': false,
    'hint_pos_gestures': 2,
    'hint_cart_tap_edit': 2,
  };

  const sizes = <String, Size>{
    '390x844': Size(390, 844),
    '844x390': Size(844, 390),
    '800x1280': Size(800, 1280),
    '1280x800': Size(1280, 800),
  };

  late ScreenTestEnvironment env;
  late Map<String, ProductData> products;

  // Home starts a connectivity listener inside the frame; the plugin has no
  // test implementation, so answer "online over wifi" instead of throwing.
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

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
      sharedPreferences: prefs,
    );
    products = await seedPosMockup(env);
    NavigationService()
      ..resetNavigation()
      ..beginSessionLanding();
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
  }) async {
    NavigationService().setIndex(NavigationService.posTab);
    final context = await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: padding,
      screen: const MainLayout(),
      bottomNavHeight: 0,
      grantedKeys: const {'sales.make', 'stock.view', 'products.add'},
      theme: brightness == Brightness.light
          ? AppTheme.light()
          : AppTheme.dark(),
      overrides: [
        firstRunTourStopProvider.overrideWithValue(TourStop.none),
        firstRunSurfaceStateProvider.overrideWithValue(
          FirstRunSurfaceState.hasContent,
        ),
        currentBusinessNameProvider.overrideWithValue('Stallion Global'),
      ],
      sharedPreferences: prefs,
      settle: false,
    );

    final cart = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(cartProvider);
    cart.addItem(products['Star Lager']!, qty: 2, maxStock: 38);
    cart.addItem(products['Hero Lager']!, qty: 1, maxStock: 6);
    cart.addItem(products['Eva Water']!, qty: 2, maxStock: 60);

    // Let Drift streams deliver and every animation run out. Bounded:
    // spinners never settle.
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(tester.takeException(), isNull);

    await expectLater(
      find.byType(MainLayout),
      matchesGoldenFile('goldens/$goldenName.png'),
    );
    await disposeScreen(tester);
  }

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    sizes.forEach((sizeName, size) {
      testWidgets(
        'pos $sizeName $themeName',
        (tester) => pumpGolden(
          tester,
          brightness: brightness,
          size: size,
          padding: EdgeInsets.zero,
          goldenName: 'pos_${sizeName}_$themeName',
        ),
      );
    });
    testWidgets('pos 844x390 with insets $themeName', (tester) async {
      tester.view.padding = const FakeViewPadding(top: 24, right: 48);
      tester.view.viewPadding = const FakeViewPadding(top: 24, right: 48);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      await pumpGolden(
        tester,
        brightness: brightness,
        size: const Size(844, 390),
        padding: const EdgeInsets.only(top: 24, right: 48),
        goldenName: 'pos_844x390_insets_$themeName',
      );
    });
  }
}
