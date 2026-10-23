// Visual goldens for Add Product and the Update Product sheet (#392 PR 2).
//
// Add Product (Fast-Add, "More details" closed) at 390x844 (gesture nav,
// bottom 24), 844x390 (status bar 24, 3-button nav on the right 48), 800x1280
// and 1280x800; Fast-Add with "More details" open and the classic "Add Stock"
// layout at 390x844 and 1280x800; the Update Product sheet at 390x844 and
// 844x390. Light + dark. No relative dates or times anywhere. Regenerate with:
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
import 'package:reebaplus_pos/features/inventory/screens/inventory_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/update_product_sheet.dart';

import '../helpers/inventory_seed.dart';
import '../helpers/screen_harness.dart';

/// The sample grants plus the buying price (Add Product shows it to the CEO).
const kAddProductGrants = {
  ...kInventorySampleGrants,
  'products.edit_buying_price',
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
  final pair = [all.first, all.last];
  final phones = [all[0], all[1]];

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

    for (final (sizeName, size, insets) in pair) {
      testWidgets('add product, more details, $sizeName $theme', (
        tester,
      ) async {
        await pump(
          tester,
          screen: const AddProductScreen(),
          size: size,
          insets: insets,
          brightness: brightness,
        );
        await tester.ensureVisible(find.text('More details'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('More details'));
        await tester.pumpAndSettle();
        // Bring the opened section (photo first) into view.
        await tester.ensureVisible(find.text('Add photo'));
        await tester.pumpAndSettle();
        await snap(tester, 'add_product_more_${sizeName}_$theme');
      });

      testWidgets('add stock to an existing product, $sizeName $theme', (
        tester,
      ) async {
        await pump(
          tester,
          screen: const AddProductScreen(),
          size: size,
          insets: insets,
          brightness: brightness,
        );
        await tester.enterText(find.byType(TextField).first, 'Gul');
        await tester.pumpAndSettle();
        await tester.tap(find.text('Bottle Crate Gulder'));
        await tester.pumpAndSettle();
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        expect(find.text('Adding stock to existing product'), findsOneWidget);
        await snap(tester, 'add_product_existing_${sizeName}_$theme');
      });
    }

    for (final (sizeName, size, insets) in phones) {
      testWidgets('update product sheet, $sizeName $theme', (tester) async {
        await pump(
          tester,
          screen: const InventoryScreen(),
          size: size,
          insets: insets,
          brightness: brightness,
          bottomNavHeight: kBottomNavBodyHeight,
        );
        // Coca-Cola (first row by name) has no expiry date, so nothing in
        // the sheet depends on today.
        final row = find.byKey(
          inventoryProductRowKey(sample.productIds['Coca-Cola']!),
        );
        // Sideways, the figure cards push the rows below the fold: drag the
        // page up until the first row is on screen.
        bool onScreen() =>
            row.evaluate().isNotEmpty &&
            tester.getCenter(row).dy < size.height - 60;
        for (var i = 0; i < 10 && !onScreen(); i++) {
          await tester.drag(
            find.byType(NestedScrollView),
            const Offset(0, -120),
          );
          await tester.pumpAndSettle();
        }
        await tester.longPress(row);
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.byType(UpdateProductSheet), findsOneWidget);
        await snap(tester, 'update_product_sheet_${sizeName}_$theme');
      });
    }
  }
}
