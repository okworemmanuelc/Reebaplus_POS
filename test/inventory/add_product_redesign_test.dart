// The Add Product form (#487 PR 2) and the Update Product sheet (#392 PR 2)
// keep every control and permission rule, hold their content at every
// redesign viewport (and with the keyboard up), lay out by their measured
// width and keep their controls 48dp targets.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/features/inventory/screens/add_product_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/inventory_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_parts.dart';
import 'package:reebaplus_pos/features/inventory/widgets/product_form_parts.dart';
import 'package:reebaplus_pos/features/inventory/widgets/update_product_sheet.dart';

import '../helpers/inventory_seed.dart';
import '../helpers/screen_harness.dart';

const _withBuying = {...kInventorySampleGrants, 'products.edit_buying_price'};

const _gesture = FakeViewPadding(top: 24, bottom: 24);
const _threeButton = FakeViewPadding(top: 24, bottom: 48);
const _sideways = FakeViewPadding(top: 24, right: 48);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late InventorySample sample;

  // The Update sheet resolves the saved photo's device path on open.
  late Directory docs;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() {
    docs = Directory.systemTemp.createTempSync('add_product_redesign');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => docs.path);
  });
  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    docs.deleteSync(recursive: true);
  });

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
    Widget screen = const AddProductScreen(),
    Size size = const Size(390, 844),
    FakeViewPadding insets = _gesture,
    Set<String> grants = _withBuying,
    TextScaler? textScaler,
    double bottomNavHeight = 0,
  }) async {
    tester.view.padding = insets;
    tester.view.viewPadding = insets;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetViewInsets);
    await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: screen,
      followView: true,
      bottomNavHeight: bottomNavHeight,
      grantedKeys: grants,
      roleRank: GateTier.ceo,
      textScaler: textScaler,
      overrides: [
        firstRunSurfaceStateProvider.overrideWithValue(
          FirstRunSurfaceState.hasContent,
        ),
      ],
    );
  }

  Future<void> settleSheet(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  void expectTarget(WidgetTester tester, Finder f) {
    final size = tester.getSize(f);
    expect(size.width, greaterThanOrEqualTo(kMinInteractiveDimension));
    expect(size.height, greaterThanOrEqualTo(kMinInteractiveDimension));
  }

  Finder box(Key key) =>
      find.descendant(of: find.byKey(key), matching: find.byType(EditableText));

  /// Raises a keyboard of [height] the way the engine does: the bottom
  /// padding it covers reads as 0.
  Future<void> raiseKeyboard(
    WidgetTester tester,
    FakeViewPadding insets,
    double height,
  ) async {
    tester.view.viewInsets = FakeViewPadding(bottom: height);
    tester.view.padding = FakeViewPadding(
      top: insets.top,
      left: insets.left,
      right: insets.right,
    );
    await tester.pump();
    await tester.pumpAndSettle();
  }

  group('Add Product renders its controls', () {
    testWidgets('top bar, back, the footer buttons and every card (#487)', (
      tester,
    ) async {
      await pump(tester);
      final bar = find.byType(InventoryTopBar);
      expect(bar, findsOneWidget);
      expect(
        find.descendant(of: bar, matching: find.text('Add Product')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: bar,
          matching: find.text('Add a new item to your inventory'),
        ),
        findsOneWidget,
      );
      expectTarget(tester, find.byTooltip('Back'));
      final footer = find.byType(InventoryFormFooter);
      expect(footer, findsOneWidget);
      for (final key in [AddProductKeys.saveAndNew, AddProductKeys.save]) {
        expect(
          find.descendant(of: footer, matching: find.byKey(key)),
          findsOneWidget,
        );
      }
      expect(find.text('Save & New'), findsOneWidget);
      expect(find.text('Save Product'), findsOneWidget);
      for (final title in [
        'Product Details',
        'Product Unit',
        'Pricing',
        'Stock',
        'More details',
      ]) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      // More details is an open card: its boxes are there without a tap.
      expect(find.byKey(AddProductKeys.description), findsOneWidget);
      expect(find.byKey(AddProductKeys.supplier), findsOneWidget);
      expect(find.text('No expiry date'), findsOneWidget);
      expect(find.text('Allow fractional sales'), findsOneWidget);
      // 48dp targets: photo, pickers, chips, stepper, date.
      expectTarget(tester, find.byType(ProductPhotoBox));
      await tester.ensureVisible(find.byKey(AddProductKeys.category));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(AddProductKeys.category)).height,
        greaterThanOrEqualTo(kMinInteractiveDimension),
      );
      await tester.ensureVisible(find.byType(ProductUnitChip).first);
      await tester.pumpAndSettle();
      expectTarget(tester, find.byType(ProductUnitChip).first);
      await tester.ensureVisible(find.byTooltip('More'));
      await tester.pumpAndSettle();
      expectTarget(tester, find.byTooltip('Less'));
      expectTarget(tester, find.byTooltip('More'));
      await tester.ensureVisible(find.byType(InventoryDateField));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(InventoryDateField)).height,
        greaterThanOrEqualTo(kMinInteractiveDimension),
      );
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });

    testWidgets('the stepper steps the opening quantity, never below 0', (
      tester,
    ) async {
      await pump(tester);
      String quantity() => tester
          .widget<EditableText>(box(AddProductKeys.quantity))
          .controller
          .text;
      await tester.ensureVisible(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Less'));
      await tester.pump();
      expect(quantity(), '0');
      await tester.tap(find.byTooltip('More'));
      await tester.tap(find.byTooltip('More'));
      await tester.pump();
      expect(quantity(), '2');
      await tester.tap(find.byTooltip('Less'));
      await tester.pump();
      expect(quantity(), '1');
      await disposeScreen(tester);
    });

    testWidgets('a picker opens a searchable sheet with "Add new"', (
      tester,
    ) async {
      await pump(tester);
      await tester.ensureVisible(find.byKey(AddProductKeys.category));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(AddProductKeys.category));
      await tester.pumpAndSettle();
      final sheet = find.byType(ProductPickerSheet);
      expect(sheet, findsOneWidget);
      expect(find.text('Add new…'), findsOneWidget);
      expect(find.text('Stout'), findsOneWidget);
      await tester.enterText(
        find.descendant(of: sheet, matching: find.byType(TextFormField)),
        'sto',
      );
      await tester.pumpAndSettle();
      expect(find.text('Stout'), findsOneWidget);
      expect(find.text('Malt'), findsNothing);
      expect(find.text('Add new “sto”'), findsOneWidget);
      expectTarget(tester, find.byType(InventorySuggestionTile).first);
      await tester.tap(find.text('Stout'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ProductPickerField>(find.byKey(AddProductKeys.category))
            .value,
        'Stout',
      );
      await disposeScreen(tester);
    });
  });

  group('permission-hidden controls stay hidden', () {
    testWidgets('no products.edit_buying_price: no Cost Price', (tester) async {
      await pump(tester, grants: kInventorySampleGrants);
      expect(find.text('Cost Price'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('with products.edit_buying_price: Cost Price shows', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('Cost Price'), findsOneWidget);
      await disposeScreen(tester);
    });

    Future<void> openSupplierSheet(WidgetTester tester) async {
      await tester.ensureVisible(find.byKey(AddProductKeys.supplier));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(AddProductKeys.supplier));
      await tester.pumpAndSettle();
    }

    testWidgets('no suppliers.manage: no "Add new supplier"', (tester) async {
      await pump(tester, grants: {..._withBuying}..remove('suppliers.manage'));
      await openSupplierSheet(tester);
      expect(find.byType(ProductPickerSheet), findsOneWidget);
      expect(find.text('Add new supplier'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('with suppliers.manage: "Add new supplier" shows', (
      tester,
    ) async {
      await pump(tester);
      await openSupplierSheet(tester);
      expect(find.text('Add new supplier'), findsOneWidget);
      await disposeScreen(tester);
    });
  });

  group('no overflow', () {
    for (final (name, size, insets, scaler)
        in <(String, Size, FakeViewPadding, TextScaler?)>[
          (
            '360x740 @1.3',
            const Size(360, 740),
            _gesture,
            const TextScaler.linear(1.3),
          ),
          ('390x844 gesture', const Size(390, 844), _gesture, null),
          ('390x844 3-button', const Size(390, 844), _threeButton, null),
          ('844x390 sideways', const Size(844, 390), _sideways, null),
          ('800x1280', const Size(800, 1280), _gesture, null),
          (
            '1280x800',
            const Size(1280, 800),
            const FakeViewPadding(top: 24),
            null,
          ),
        ]) {
      testWidgets(name, (tester) async {
        await pump(tester, size: size, insets: insets, textScaler: scaler);
        expect(tester.takeException(), isNull);
        // Pick Bottle so every card (Track Empty Crates too) is drawn.
        await tester.ensureVisible(
          find.byKey(AddProductKeys.unitChip('Bottle')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(AddProductKeys.unitChip('Bottle')));
        await tester.pumpAndSettle();
        expect(find.text('Track Empty Crates'), findsOneWidget);
        expect(tester.takeException(), isNull);
        final save = tester.getRect(find.byKey(AddProductKeys.save));
        expect(save.bottom, lessThanOrEqualTo(size.height));
        await disposeScreen(tester);
      });
    }
  });

  group('measured layouts', () {
    testWidgets('under 600: one column capped at 720, the footer bar', (
      tester,
    ) async {
      await pump(tester);
      expect(find.byType(InventoryFormFooter), findsOneWidget);
      expect(find.byKey(AddProductKeys.preview), findsNothing);
      final details = tester.getRect(find.text('Product Details'));
      final pricing = tester.getRect(find.text('Pricing'));
      expect(pricing.top, greaterThan(details.bottom));
      await disposeScreen(tester);
    });

    testWidgets('600 to 1000: two columns, the footer bar, no Preview', (
      tester,
    ) async {
      await pump(tester, size: const Size(800, 1280));
      expect(find.byType(InventoryFormFooter), findsOneWidget);
      expect(find.byKey(AddProductKeys.preview), findsNothing);
      final details = tester.getRect(find.text('Product Details'));
      final pricing = tester.getRect(find.text('Pricing'));
      expect(pricing.left, greaterThan(details.right));
      expect((pricing.top - details.top).abs(), lessThan(20));
      await disposeScreen(tester);
    });

    testWidgets('1000 and over: two columns plus the Preview, whose buttons '
        'replace the footer bar', (tester) async {
      await pump(
        tester,
        size: const Size(1280, 800),
        insets: const FakeViewPadding(top: 24),
      );
      expect(find.byType(InventoryFormFooter), findsNothing);
      final preview = find.byKey(AddProductKeys.preview);
      expect(preview, findsOneWidget);
      expect(find.text('Preview'), findsOneWidget);
      expect(
        find.text('How this product will look on the sales screen.'),
        findsOneWidget,
      );
      for (final key in [AddProductKeys.save, AddProductKeys.saveAndNew]) {
        expect(
          find.descendant(of: preview, matching: find.byKey(key)),
          findsOneWidget,
        );
      }
      expect(find.text('Save & Add Another'), findsOneWidget);
      expect(
        find.descendant(of: preview, matching: find.text('Cancel')),
        findsOneWidget,
      );
      // The preview follows the form.
      await tester.enterText(
        find.descendant(
          of: find.byKey(AddProductKeys.name),
          matching: find.byType(TextFormField),
        ),
        'Hero 60cl',
      );
      await tester.enterText(
        find.descendant(
          of: find.byKey(AddProductKeys.quantity),
          matching: find.byType(TextFormField),
        ),
        '20',
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: preview, matching: find.text('Hero 60cl')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: preview, matching: find.text('20 in stock')),
        findsOneWidget,
      );
      // Opening Quantity and Low-Stock Alert share a row here.
      final quantity = tester.getRect(find.text('Opening Quantity'));
      final low = tester.getRect(find.text('Low-Stock Alert'));
      expect(low.left, greaterThan(quantity.right));
      await disposeScreen(tester);
    });
  });

  group('keyboard up: the boxes stay reachable', () {
    for (final (name, size, insets, keyboard) in [
      ('390x844', const Size(390, 844), _gesture, 300.0),
      ('844x390', const Size(844, 390), _sideways, 200.0),
    ]) {
      for (final (field, key) in [
        ('name', AddProductKeys.name),
        ('low-stock alert', AddProductKeys.lowStock),
        ('description (the last box)', AddProductKeys.description),
      ]) {
        testWidgets('$name, $field focused', (tester) async {
          await pump(tester, size: size, insets: insets);
          final input = box(key);
          await tester.ensureVisible(input);
          await tester.pumpAndSettle();
          await tester.tap(input);
          await tester.pump();
          await raiseKeyboard(tester, insets, keyboard);
          expect(tester.takeException(), isNull);
          final keyboardTop = size.height - keyboard;
          // The body ends at the keyboard (the footer stays under it) and the
          // focused field scrolls into the space left.
          await tester.ensureVisible(input);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final rect = tester.getRect(input);
          expect(rect.bottom, lessThanOrEqualTo(keyboardTop + 0.5));
          expect(rect.top, greaterThanOrEqualTo(0));
          await disposeScreen(tester);
        });
      }
    }
  });

  group('Update Product sheet', () {
    Finder row(String name) =>
        find.byKey(inventoryProductRowKey(sample.productIds[name]!));

    Future<void> openSheet(
      WidgetTester tester, {
      Size size = const Size(390, 844),
      FakeViewPadding insets = _gesture,
    }) async {
      await pump(
        tester,
        screen: const InventoryScreen(),
        size: size,
        insets: insets,
        bottomNavHeight: kBottomNavBodyHeight,
      );
      final r = row('Coca-Cola');
      bool onScreen() =>
          r.evaluate().isNotEmpty && tester.getCenter(r).dy < size.height - 60;
      for (var i = 0; i < 10 && !onScreen(); i++) {
        await tester.drag(find.byType(NestedScrollView), const Offset(0, -120));
        await tester.pumpAndSettle();
      }
      await tester.longPress(r);
      await settleSheet(tester);
      expect(find.byType(UpdateProductSheet), findsOneWidget);
    }

    testWidgets('a hold opens it; the photo button is a 48dp target', (
      tester,
    ) async {
      await openSheet(tester);
      expect(find.text('Update Product'), findsWidgets);
      expectTarget(tester, find.byTooltip('Change photo'));
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });

    for (final (name, size, insets, keyboard) in [
      ('390x844', const Size(390, 844), _gesture, 300.0),
      ('844x390', const Size(844, 390), _sideways, 200.0),
    ]) {
      testWidgets('$name, keyboard up on the name field: no overflow', (
        tester,
      ) async {
        await openSheet(tester, size: size, insets: insets);
        final input = find
            .descendant(
              of: find.byType(UpdateProductSheet),
              matching: find.byType(EditableText),
            )
            .first;
        await tester.tap(input);
        await tester.pump();
        await raiseKeyboard(tester, insets, keyboard);
        expect(tester.takeException(), isNull);
        // In the app the frame Scaffold already lifts the sheet's navigator
        // above the keyboard (ui-context "Safe-area rule"); here the focused
        // field must sit clear of it and nothing may overflow.
        expect(
          tester.getRect(input).bottom,
          lessThanOrEqualTo(size.height - keyboard + 0.5),
        );
        await disposeScreen(tester);
      });
    }

    testWidgets('holds at the 640 sheet width on a 1280 screen', (
      tester,
    ) async {
      await openSheet(
        tester,
        size: const Size(1280, 800),
        insets: const FakeViewPadding(top: 24),
      );
      expect(
        tester.getSize(find.byType(UpdateProductSheet)).width,
        lessThanOrEqualTo(640),
      );
      await disposeScreen(tester);
    });

    testWidgets('receive mode shows Stock Management', (tester) async {
      final product =
          await (env.db.select(env.db.products)
                ..where((p) => p.id.equals(sample.productIds['Coca-Cola']!)))
              .getSingle();
      await pump(
        tester,
        screen: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => UpdateProductSheet(
                    product: product,
                    totalStock: 52,
                    receiveMode: true,
                  ),
                ),
                child: const Text('Open sheet'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open sheet'));
      await settleSheet(tester);
      expect(
        find.text('Stock Management', skipOffstage: false),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });
  });
}
