// #392 (Wave 2 A): the restyled Inventory screen keeps every control, action
// and permission rule, holds its content at every redesign viewport, and its
// controls stay 48dp targets.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/features/inventory/screens/add_product_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/inventory_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/manufacturer_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/product_detail_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/stock_count_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/supplier_detail_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/add_manufacturer_sheet.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_parts.dart';
import 'package:reebaplus_pos/features/inventory/widgets/manage_categories_sheet.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/coach_hint_banner.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

import '../helpers/inventory_seed.dart';
import '../helpers/screen_harness.dart';

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

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    EdgeInsets padding = kRealisticPhoneInsets,
    EdgeInsets viewInsets = EdgeInsets.zero,
    Set<String> grants = kInventorySampleGrants,
    int roleRank = GateTier.ceo,
    String roleSlug = 'ceo',
    TextScaler? textScaler,
    bool followView = false,
  }) async {
    await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: padding,
      viewInsets: viewInsets,
      screen: const InventoryScreen(),
      grantedKeys: grants,
      roleRank: roleRank,
      roleSlug: roleSlug,
      textScaler: textScaler,
      followView: followView,
      overrides: [
        firstRunSurfaceStateProvider.overrideWithValue(
          FirstRunSurfaceState.hasContent,
        ),
      ],
    );
  }

  /// Switches tab through the controller (the bar scrolls sideways on a phone).
  Future<void> openTab(WidgetTester tester, String label) async {
    final bar = tester.widget<TabBar>(find.byType(TabBar));
    final labels = [for (final t in bar.tabs) (t as Tab).text];
    expect(labels, contains(label));
    bar.controller!.animateTo(labels.indexOf(label));
    await tester.pumpAndSettle();
  }

  List<String> tabLabels(WidgetTester tester) => [
    for (final t in tester.widget<TabBar>(find.byType(TabBar)).tabs)
      (t as Tab).text!,
  ];

  Finder productRow(String name) =>
      find.byKey(inventoryProductRowKey(sample.productIds[name]!));

  group('renders its controls', () {
    testWidgets('Manage categories offers the public category picker', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('inventory-manage-categories')));
      await tester.pumpAndSettle();
      final dropdown = find.descendant(of: find.byType(ManageCategoriesSheet),
          matching: find.byType(AppDropdown<String>)).first;
      expect(dropdown, findsOneWidget);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      expect(find.text('Beverages / Water'), findsOneWidget);
      await tester.tap(find.text('Beverages / Water'));
      await tester.pumpAndSettle();
      final rows = await tester.runAsync(() =>
          env.db.inventoryDao.watchAllCategories().firstWhere(
            (rows) => rows.any((c) => c.marketplaceCategory == 'water')));
      expect(rows!.any((c) => c.marketplaceCategory == 'water'), isTrue);
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });
    testWidgets('top bar, figure cards, tabs, filters and rows', (
      tester,
    ) async {
      await pump(tester);

      expect(find.byType(InventoryTopBar), findsOneWidget);
      expect(find.text('Inventory'), findsOneWidget);
      expect(find.text('Abuja HQ'), findsOneWidget);
      expect(find.byTooltip('Search products'), findsOneWidget);
      expect(find.byTooltip('Daily Stock Count'), findsOneWidget);
      expect(find.byType(InventoryLiveBell), findsOneWidget);

      for (final label in const [
        'Total SKUs',
        'Low Stock',
        'Out of Stock',
        'Total Crates',
        'Near Expiry',
      ]) {
        expect(
          find.descendant(
            of: find.byType(InventoryFigureCard),
            matching: find.text(label),
          ),
          findsOneWidget,
          reason: label,
        );
      }

      expect(tabLabels(tester), [
        'Products',
        'Suppliers',
        'Empty Crates',
        'Manufacturers',
        'History',
      ]);
      expect(find.text('Category'), findsOneWidget);
      expect(find.text('Manufacturer'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('inventory-manage-categories')),
        findsOneWidget,
      );
      // No "press and hold to edit" tip any more (#487 PR 4).
      expect(find.byType(CoachHintBanner), findsNothing);
      expect(productRow('Eva Water'), findsOneWidget);
      // Expiry pill and stock pills keep their words.
      expect(find.text('Expires in 10d'), findsOneWidget);
      expect(find.byType(TagPill), findsWidgets);
      await disposeScreen(tester);
    });

    testWidgets('a product row shows its category tile, not its own colour', (
      tester,
    ) async {
      await pump(tester);
      final row = tester.widget<InventoryProductRow>(productRow('Eva Water'));
      expect(row.categoryName, 'Water');
      expect(row.state, InventoryStockState.ok);
      final gulder = tester.widget<InventoryProductRow>(productRow('Gulder'));
      expect(gulder.state, InventoryStockState.low);
      await disposeScreen(tester);
    });
  });

  group('main actions still work', () {
    testWidgets('search toggles a field that filters the list', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('Search products'));
      await tester.pumpAndSettle();
      expect(find.byType(AppInput), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'gulder');
      await tester.pumpAndSettle();
      expect(productRow('Gulder'), findsOneWidget);
      expect(productRow('Eva Water'), findsNothing);
      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();
      expect(productRow('Eva Water'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('figure cards drive the stock filter', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('inventory-summary-low')));
      await tester.pumpAndSettle();
      expect(productRow('Gulder'), findsOneWidget);
      expect(productRow('Coca-Cola'), findsNothing);
      expect(
        tester
            .widget<InventoryFigureCard>(
              find.byKey(const ValueKey('inventory-summary-low')),
            )
            .selected,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('inventory-summary-total')));
      await tester.pumpAndSettle();
      expect(productRow('Coca-Cola'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('Total Crates jumps to Empty Crates', (tester) async {
      await pump(tester, size: const Size(1280, 800));
      await tester.tap(find.byKey(const ValueKey('inventory-summary-crates')));
      await tester.pumpAndSettle();
      expect(find.text('Bottle manufacturers'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('a row opens Product Detail; a hold never opens the editor', (
      tester,
    ) async {
      await pump(tester);
      await tester.longPress(productRow('Eva Water'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // A hold is just a slow tap now: Product Details, never an edit form.
      expect(find.byType(AddProductScreen), findsNothing);
      expect(find.byType(ProductDetailScreen), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('Manage categories opens its sheet with 48dp actions', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(
        find.byKey(const ValueKey('inventory-manage-categories')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ManageCategoriesSheet), findsOneWidget);
      expect(find.text('Manage categories'), findsOneWidget);
      for (final tip in const ['Rename', 'Delete']) {
        final size = tester.getSize(find.byTooltip(tip).first);
        expect(size.width, greaterThanOrEqualTo(kMinInteractiveDimension));
        expect(size.height, greaterThanOrEqualTo(kMinInteractiveDimension));
      }
      await tester.tap(find.byTooltip('Rename').first);
      await tester.pumpAndSettle();
      expect(find.text('Rename category'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('Daily Stock Count opens from the top bar', (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('Daily Stock Count'));
      await tester.pumpAndSettle();
      expect(find.byType(StockCountScreen), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('a supplier row opens Supplier Detail', (tester) async {
      await pump(tester);
      await openTab(tester, 'Suppliers');
      await tester.tap(find.text('Kano Distributors'));
      await tester.pumpAndSettle();
      expect(find.byType(SupplierDetailScreen), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('a bottle manufacturer card opens its screen', (tester) async {
      await pump(tester);
      await openTab(tester, 'Empty Crates');
      expect(find.text('Empty In Stock'), findsOneWidget);
      expect(find.text('Full (Crate)'), findsOneWidget);
      // Coca-Cola HBC has no returnable bottles: not on Empty Crates (#389).
      expect(find.text('Coca-Cola HBC'), findsNothing);
      await tester.tap(find.text('Guinness Nigeria'));
      await tester.pumpAndSettle();
      expect(find.byType(ManufacturerScreen), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('History period pills switch the period', (tester) async {
      await pump(tester);
      await openTab(tester, 'History');
      // The sample movements are 2–4 days old: none today.
      expect(find.text('No stock movements found'), findsOneWidget);
      final pill = find.widgetWithText(InventoryPeriodChip, '7 Days');
      expect(
        tester.getSize(pill).height,
        greaterThanOrEqualTo(kMinInteractiveDimension),
      );
      await tester.tap(pill);
      await tester.pumpAndSettle();
      expect(tester.widget<InventoryPeriodChip>(pill).selected, isTrue);
      expect(find.text('Stock In'), findsOneWidget);
      expect(find.text('Amaka Obi'), findsWidgets);
      expect(find.text('3d ago'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('Add New on Manufacturers opens the sheet', (tester) async {
      await pump(tester);
      await openTab(tester, 'Manufacturers');
      await tester.tap(find.text('Add New'));
      await tester.pumpAndSettle();
      expect(find.byType(AddManufacturerSheet), findsOneWidget);
      await disposeScreen(tester);
    });
  });

  group('permission-hidden controls stay hidden', () {
    testWidgets('without products.add: no Manage categories', (tester) async {
      await pump(
        tester,
        grants: kInventorySampleGrants.difference({'products.add'}),
      );
      expect(
        find.byKey(const ValueKey('inventory-manage-categories')),
        findsNothing,
      );
      await disposeScreen(tester);
    });

    testWidgets('without products.edit_price: no hint and no hold-to-edit', (
      tester,
    ) async {
      await pump(
        tester,
        grants: kInventorySampleGrants.difference({'products.edit_price'}),
      );
      expect(find.byType(CoachHintBanner), findsNothing);
      expect(
        tester.widget<InventoryProductRow>(productRow('Eva Water')).onLongPress,
        isNull,
      );
      await disposeScreen(tester);
    });

    testWidgets('without stock.adjust: no Daily Stock Count', (tester) async {
      await pump(
        tester,
        grants: kInventorySampleGrants.difference({'stock.adjust'}),
      );
      expect(find.byTooltip('Daily Stock Count'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('a cashier: no Daily Stock Count, no History tab', (
      tester,
    ) async {
      await pump(tester, roleRank: GateTier.cashier, roleSlug: 'cashier');
      expect(find.byTooltip('Daily Stock Count'), findsNothing);
      expect(tabLabels(tester), isNot(contains('History')));
      await disposeScreen(tester);
    });

    testWidgets('without suppliers.manage: no Suppliers tab', (tester) async {
      await pump(
        tester,
        grants: kInventorySampleGrants.difference({'suppliers.manage'}),
      );
      expect(tabLabels(tester), isNot(contains('Suppliers')));
      await disposeScreen(tester);
    });
  });

  group('no overflow at the redesign viewports', () {
    final viewports = <String, (Size, EdgeInsets, TextScaler?)>{
      '360dp @1.3': (
        const Size(360, 780),
        kRealisticPhoneInsets,
        const TextScaler.linear(1.3),
      ),
      '390x844': (const Size(390, 844), kRealisticPhoneInsets, null),
      '844x390 insets': (
        const Size(844, 390),
        const EdgeInsets.only(top: 24, right: 48),
        null,
      ),
      '390x844 3-button': (
        const Size(390, 844),
        const EdgeInsets.only(top: 24, bottom: 48),
        null,
      ),
      '800x1280': (const Size(800, 1280), kRealisticPhoneInsets, null),
      '1280x800': (const Size(1280, 800), const EdgeInsets.only(top: 24), null),
    };
    viewports.forEach((name, spec) {
      final (size, padding, scaler) = spec;
      testWidgets('every tab at $name', (tester) async {
        await pump(tester, size: size, padding: padding, textScaler: scaler);
        expectNoOverflow(tester, reason: 'Products at $name');
        expect(
          visibleRowCount(
            tester,
            find.byWidgetPredicate(
              (w) =>
                  w.key is ValueKey<String> &&
                  (w.key! as ValueKey<String>).value.startsWith(
                    kInventoryProductRowKeyPrefix,
                  ),
            ),
          ),
          greaterThanOrEqualTo(size.height < 500 ? 0 : 1),
          reason: 'a complete product row at $name',
        );
        for (final tab in const [
          'Suppliers',
          'Empty Crates',
          'Manufacturers',
          'History',
        ]) {
          await openTab(tester, tab);
          expectNoOverflow(tester, reason: '$tab at $name');
        }
        await disposeScreen(tester);
      });
    });

    for (final (name, size, padding) in [
      ('390x844', const Size(390, 844), kRealisticPhoneInsets),
      (
        '844x390 insets',
        const Size(844, 390),
        const EdgeInsets.only(top: 24, right: 48),
      ),
    ]) {
      testWidgets('search field with the keyboard up at $name', (tester) async {
        await pump(
          tester,
          size: size,
          padding: padding,
          viewInsets: const EdgeInsets.only(bottom: 300),
        );
        await tester.tap(find.byTooltip('Search products'));
        await tester.pumpAndSettle();
        expectNoOverflow(tester, reason: 'search, keyboard up, $name');
        await disposeScreen(tester);
      });
    }
  });

  group('sheets with the keyboard up', () {
    /// Pumps at [size] following the view, so the keyboard can rise after a
    /// sheet opens, as on a device.
    Future<void> pumpFollowing(
      WidgetTester tester,
      Size size,
      FakeViewPadding insets,
    ) async {
      tester.view.padding = insets;
      tester.view.viewPadding = insets;
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.view.resetViewInsets);
      await pump(tester, size: size, followView: true);
    }

    /// A phone keyboard: about 300dp upright, 200dp sideways.
    Future<void> raiseKeyboard(WidgetTester tester) async {
      final upright =
          tester.view.physicalSize.height > tester.view.physicalSize.width;
      tester.view.viewInsets = FakeViewPadding(bottom: upright ? 300 : 200);
      await tester.pumpAndSettle();
    }

    for (final (name, size, insets) in const [
      ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
      ('844x390 insets', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
    ]) {
      testWidgets('Add Manufacturer at $name', (tester) async {
        await pumpFollowing(tester, size, insets);
        await openTab(tester, 'Manufacturers');
        await tester.tap(find.text('Add New'));
        await tester.pumpAndSettle();
        expect(find.byType(AddManufacturerSheet), findsOneWidget);
        await tester.showKeyboard(find.byType(TextField).first);
        await raiseKeyboard(tester);
        expectNoOverflow(tester, reason: 'Add Manufacturer, keyboard, $name');
        await tester.ensureVisible(
          find.widgetWithText(AppButton, 'Add Manufacturer'),
        );
        await tester.pumpAndSettle();
        expectNoOverflow(tester);
        await disposeScreen(tester);
      });

      testWidgets('Rename category at $name', (tester) async {
        await pumpFollowing(tester, size, insets);
        await tester.tap(
          find.byKey(const ValueKey('inventory-manage-categories')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Rename').first);
        await tester.pumpAndSettle();
        await raiseKeyboard(tester);
        expectNoOverflow(tester, reason: 'Rename dialog, keyboard, $name');
        await disposeScreen(tester);
      });
    }
  });

  group('wide screens', () {
    testWidgets('content is capped at 720dp and centred at 1280', (
      tester,
    ) async {
      await pump(tester, size: const Size(1280, 800));
      final rect = tester.getRect(productRow('Eva Water'));
      expect(rect.width, lessThanOrEqualTo(kInventoryMaxContentWidth));
      final body = tester.getRect(find.byType(TabBarView));
      expect(
        (rect.center.dx - body.center.dx).abs(),
        lessThan(1),
        reason: 'the column is centred in the body',
      );
      // The figure cards share one row there.
      final total = tester.getRect(
        find.byKey(const ValueKey('inventory-summary-total')),
      );
      final expiry = tester.getRect(
        find.byKey(const ValueKey('inventory-summary-expiry')),
      );
      expect(total.top, expiry.top);
      expect(expiry.right, lessThanOrEqualTo(rect.right + 0.5));
      await disposeScreen(tester);
    });

    testWidgets('the Manage categories square stays 48dp when compressed', (
      tester,
    ) async {
      await pump(tester, size: const Size(800, 360));
      final size = tester.getSize(
        find.byKey(const ValueKey('inventory-manage-categories')),
      );
      expect(size.width, greaterThanOrEqualTo(kMinInteractiveDimension));
      expect(size.height, greaterThanOrEqualTo(kMinInteractiveDimension));
      await disposeScreen(tester);
    });
  });
}
