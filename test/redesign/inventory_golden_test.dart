// Visual goldens for the Inventory screen (#392, Wave 2 A): the solid top bar,
// the filter figure cards, the tab bar and each tab — Products, Empty Crates,
// History, Suppliers — plus the Manage Categories and Add Manufacturer sheets.
//
// Screens at 390x844 (gesture nav, bottom 24), 844x390 (status bar 24, 3-button
// nav on the right 48), 800x1280 and 1280x800; sheets at 390x844 and 844x390.
// Light + dark. Regenerate with:
//
//     flutter test --update-goldens test/redesign/inventory_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/inventory/screens/inventory_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/add_manufacturer_sheet.dart';
import 'package:reebaplus_pos/features/inventory/widgets/manage_categories_sheet.dart';

import '../helpers/inventory_seed.dart';
import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
      businessType: 'Beverage distributor',
    );
    await seedInventorySample(env);
  });

  tearDown(() => env.dispose());

  setUpAll(() => WidgetsApp.debugAllowBannerOverride = false);
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  const allSizes = <(String, Size, FakeViewPadding)>[
    ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
    ('844x390', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
    ('800x1280', Size(800, 1280), FakeViewPadding(top: 24, bottom: 24)),
    ('1280x800', Size(1280, 800), FakeViewPadding(top: 24)),
  ];
  const phoneSizes = <(String, Size, FakeViewPadding)>[
    ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
    ('844x390', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
  ];

  Future<void> pumpInventory(
    WidgetTester tester, {
    required Size size,
    required FakeViewPadding insets,
    required Brightness brightness,
  }) async {
    tester.view.padding = insets;
    tester.view.viewPadding = insets;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: const InventoryScreen(),
      followView: true,
      grantedKeys: kInventorySampleGrants,
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

  Future<void> openTab(WidgetTester tester, String label) async {
    // Switch through the controller: on a phone the tab may sit past the edge
    // of the sideways-scrolling bar, and ensureVisible would also scroll the
    // page and hide the summary cards the golden should show.
    final bar = tester.widget<TabBar>(find.byType(TabBar));
    final labels = [for (final t in bar.tabs) (t as Tab).text];
    bar.controller!.animateTo(labels.indexOf(label));
    await tester.pumpAndSettle();
  }

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';

    for (final (tab, label, sizes) in [
      ('products', 'Products', allSizes),
      ('crates', 'Empty Crates', allSizes),
      ('history', 'History', allSizes),
      ('suppliers', 'Suppliers', [allSizes.first, allSizes.last]),
    ]) {
      for (final (sizeName, size, insets) in sizes) {
        testWidgets('inventory $tab, $sizeName $themeName', (tester) async {
          await pumpInventory(
            tester,
            size: size,
            insets: insets,
            brightness: brightness,
          );
          if (tab != 'products') await openTab(tester, label);
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile(
              'goldens/inventory_${tab}_${sizeName}_$themeName.png',
            ),
          );
          await disposeScreen(tester);
        });
      }
    }

    for (final (sizeName, size, insets) in phoneSizes) {
      testWidgets('manage categories sheet, $sizeName $themeName', (
        tester,
      ) async {
        await pumpInventory(
          tester,
          size: size,
          insets: insets,
          brightness: brightness,
        );
        await tester.tap(
          find.byKey(const ValueKey('inventory-manage-categories')),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ManageCategoriesSheet), findsOneWidget);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            'goldens/manage_categories_sheet_${sizeName}_$themeName.png',
          ),
        );
        await disposeScreen(tester);
      });

      testWidgets('add manufacturer sheet, $sizeName $themeName', (
        tester,
      ) async {
        await pumpInventory(
          tester,
          size: size,
          insets: insets,
          brightness: brightness,
        );
        await openTab(tester, 'Manufacturers');
        await tester.tap(find.text('Add New'));
        await tester.pumpAndSettle();
        expect(find.byType(AddManufacturerSheet), findsOneWidget);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            'goldens/add_manufacturer_sheet_${sizeName}_$themeName.png',
          ),
        );
        await disposeScreen(tester);
      });
    }
  }
}
