// Visual goldens for Add Product (#487 PR 2) and Edit Product (#487 PR 4).
//
// Add Product empty and filled in (a Bottle Crate product with cost, prices,
// brand and category, so the profit rows and Track Empty Crates show) at
// 390x844 (phone, gesture nav, bottom 24), 844x390 (status bar 24, 3-button
// nav on the right 48: two columns), 800x1280 (two columns) and 1280x800 (two
// columns + Preview), plus a filled 1024x700 (Preview in a short window). Edit Product at 390x844 and 1280x800, light only. Light +
// dark. No relative dates or times anywhere. Regenerate with:
//
//     flutter test --update-goldens test/redesign/add_product_golden_test.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/inventory/screens/add_product_screen.dart';

import '../helpers/inventory_seed.dart';
import '../helpers/screen_harness.dart';

/// The sample grants plus the buying price and the online listing (Add
/// Product shows both to the CEO; #473 adds the Online listing section).
const kAddProductGrants = {
  ...kInventorySampleGrants,
  'products.edit_buying_price',
  'products.manage_listing',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late InventorySample sample;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
      businessType: 'Beverage distributor',
    );
    sample = await seedInventorySample(env);
  });

  tearDown(() => env.dispose());

  // The Update sheet resolves the saved photo's device path on open.
  late Directory docs;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() {
    WidgetsApp.debugAllowBannerOverride = false;
    docs = Directory.systemTemp.createTempSync('add_product_golden');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => docs.path);
  });
  tearDownAll(() {
    WidgetsApp.debugAllowBannerOverride = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    docs.deleteSync(recursive: true);
  });

  const all = <(String, Size, FakeViewPadding)>[
    ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
    ('844x390', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
    ('800x1280', Size(800, 1280), FakeViewPadding(top: 24, bottom: 24)),
    ('1280x800', Size(1280, 800), FakeViewPadding(top: 24)),
  ];

  Future<void> pump(
    WidgetTester tester, {
    required Widget screen,
    required Size size,
    required FakeViewPadding insets,
    required Brightness brightness,
    double bottomNavHeight = 0,
  }) async {
    tester.view.padding = insets;
    tester.view.viewPadding = insets;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: screen,
      followView: true,
      bottomNavHeight: bottomNavHeight,
      grantedKeys: kAddProductGrants,
      roleRank: GateTier.ceo,
      theme: brightness == Brightness.light
          ? AppTheme.light()
          : AppTheme.dark(),
      overrides: [
        firstRunSurfaceStateProvider.overrideWithValue(
          FirstRunSurfaceState.hasContent,
        ),
      ],
    );
  }

  Future<void> type(WidgetTester tester, Key key, String text) async {
    final box = find.descendant(
      of: find.byKey(key),
      matching: find.byType(TextFormField),
    );
    await tester.ensureVisible(box);
    await tester.enterText(box, text);
    await tester.pumpAndSettle();
  }

  Future<void> pickIn(WidgetTester tester, Key field, String option) async {
    await tester.ensureVisible(find.byKey(field));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(field));
    await tester.pumpAndSettle();
    await tester.tap(find.text(option).last);
    await tester.pumpAndSettle();
  }

  /// The mockup's product: a Bottle Crate of 12, Beer, Nigerian Breweries.
  Future<void> fillIn(WidgetTester tester) async {
    await type(tester, AddProductKeys.name, 'Heineken 60cl');
    await pickIn(tester, AddProductKeys.category, 'Beer');
    await pickIn(tester, AddProductKeys.manufacturer, 'Nigerian Breweries');
    await tester.ensureVisible(find.byKey(AddProductKeys.unitChip('Bottle')));
    await tester.tap(find.byKey(AddProductKeys.unitChip('Bottle')));
    await tester.pumpAndSettle();
    await type(tester, AddProductKeys.unitsPerPack, '12');
    await type(tester, AddProductKeys.cost, '13500');
    await type(tester, AddProductKeys.retail, '15000');
    await type(tester, AddProductKeys.wholesale, '14200');
    await type(tester, AddProductKeys.quantity, '20');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    // Back to the top, as the mockups show it.
    for (final s in tester.stateList<ScrollableState>(
      find.byType(Scrollable),
    )) {
      s.position.jumpTo(0);
    }
    await tester.pumpAndSettle();
  }

  Future<void> snap(WidgetTester tester, String name) async {
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/$name.png'),
    );
    await disposeScreen(tester);
  }

  for (final brightness in Brightness.values) {
    final theme = brightness == Brightness.light ? 'light' : 'dark';

    for (final (sizeName, size, insets) in all) {
      testWidgets('add product, $sizeName $theme', (tester) async {
        await pump(
          tester,
          screen: const AddProductScreen(),
          size: size,
          insets: insets,
          brightness: brightness,
        );
        await snap(tester, 'add_product_${sizeName}_$theme');
      });
    }

    for (final (sizeName, size, insets) in [
      ...all,
      // A shorter wide window: the preview scrolls above the pinned buttons.
      ('1024x700', const Size(1024, 700), const FakeViewPadding(top: 24)),
    ]) {
      testWidgets('add product filled in, $sizeName $theme', (tester) async {
        await pump(
          tester,
          screen: const AddProductScreen(),
          size: size,
          insets: insets,
          brightness: brightness,
        );
        await fillIn(tester);
        await snap(tester, 'add_product_filled_${sizeName}_$theme');
      });
    }
  }

  // Edit Product (#487 PR 4): the same form opened on a saved product. Phone
  // and the wide layout, light only.
  for (final (sizeName, size, insets) in [all[0], all[3]]) {
    testWidgets('edit product, $sizeName light', (tester) async {
      final product =
          await (env.db.select(env.db.products)
                ..where((t) => t.id.equals(sample.productIds['Coca-Cola']!)))
              .getSingle();
      await pump(
        tester,
        screen: AddProductScreen(editProduct: product),
        size: size,
        insets: insets,
        brightness: Brightness.light,
      );
      await tester.pumpAndSettle();
      await snap(tester, 'edit_product_${sizeName}_light');
    });
  }
}
