// #392 PR 2 (Wave 2 A): the restyled Add Product screen and Update Product
// sheet keep every control and permission rule, hold their content at every
// redesign viewport (and with the keyboard up), stay inside their width caps
// and keep their controls 48dp targets.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/features/inventory/screens/add_product_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/inventory_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_parts.dart';
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

  Future<void> openMoreDetails(WidgetTester tester) async {
    await tester.ensureVisible(find.text('More details'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More details'));
    await tester.pumpAndSettle();
  }

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
    testWidgets('top bar, back, footer button and the More details toggle', (
      tester,
    ) async {
      await pump(tester);
      expect(find.byType(InventoryTopBar), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(InventoryTopBar),
          matching: find.text('Add Product'),
        ),
        findsOneWidget,
      );
      expectTarget(tester, find.byTooltip('Back'));
      final footer = find.byType(InventoryFormFooter);
      expect(footer, findsOneWidget);
      expect(
        find.descendant(of: footer, matching: find.text('Add Product')),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('More details'));
      await tester.pumpAndSettle();
      expect(
        tester
            .getSize(
              find.ancestor(
                of: find.text('More details'),
                matching: find.byType(InkWell),
              ),
            )
            .height,
        greaterThanOrEqualTo(kMinInteractiveDimension),
      );
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });

    testWidgets('More details opens the photo, barcode and date fields', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('Add photo'), findsNothing);
      await openMoreDetails(tester);
      expect(find.text('Add photo'), findsOneWidget);
      expect(find.text('Barcode (optional)'), findsOneWidget);
      expect(find.text('No expiry date'), findsOneWidget);
      await tester.ensureVisible(find.text('Add photo'));
      await tester.pumpAndSettle();
      expect(
        tester
            .getSize(
              find.ancestor(
                of: find.text('Add photo'),
                matching: find.byType(InkWell),
              ),
            )
            .height,
        greaterThanOrEqualTo(kMinInteractiveDimension),
      );
      expect(
        tester.getSize(find.byType(InventoryDateField)).height,
        greaterThanOrEqualTo(kMinInteractiveDimension),
      );
      await disposeScreen(tester);
    });

    testWidgets('picking an existing product shows the notice; ✕ clears it', (
      tester,
    ) async {
      await pump(tester);
      await tester.enterText(find.byType(TextField).first, 'Gul');
      await tester.pumpAndSettle();
      final tile = find.byType(InventorySuggestionTile);
      expect(tile, findsWidgets);
      expect(
        tester.getSize(tile.first).height,
        greaterThanOrEqualTo(kMinInteractiveDimension),
      );
      await tester.tap(find.text('Bottle Crate Gulder'));
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      final notice = find.byType(InventoryNotice);
      expect(find.text('Adding stock to existing product'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(InventoryTopBar),
          matching: find.text('Add Stock'),
        ),
        findsOneWidget,
      );
      final close = find.descendant(
        of: notice,
        matching: find.byTooltip('Clear'),
      );
      expectTarget(tester, close);
      // The category ✕ on the prefilled field is a 48dp target too.
      expectTarget(
        tester,
        find
            .descendant(
              of: find.byType(InventoryFieldClear),
              matching: find.byType(IconButton),
            )
            .first,
      );

      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(find.text('Adding stock to existing product'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(InventoryTopBar),
          matching: find.text('Add Product'),
        ),
        findsOneWidget,
      );
      await disposeScreen(tester);
    });
  });

  group('permission-hidden controls stay hidden', () {
    testWidgets('no products.edit_buying_price: no Buying Price', (
      tester,
    ) async {
      await pump(tester, grants: kInventorySampleGrants);
      expect(find.textContaining('Buying Price'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('with products.edit_buying_price: Buying Price shows', (
      tester,
    ) async {
      await pump(tester);
      expect(find.textContaining('Buying Price'), findsWidgets);
      await disposeScreen(tester);
    });

    testWidgets('no suppliers.manage: no "Add new supplier"', (tester) async {
      await pump(tester, grants: {..._withBuying}..remove('suppliers.manage'));
      await openMoreDetails(tester);
      expect(find.text('Supplier'), findsOneWidget);
      expect(find.text('Add new supplier'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('with suppliers.manage: "Add new supplier" shows', (
      tester,
    ) async {
      await pump(tester);
      await openMoreDetails(tester);
      expect(find.text('Add new supplier'), findsOneWidget);
      await disposeScreen(tester);
    });
  });

  group('no overflow, More details open', () {
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
        await openMoreDetails(tester);
        expect(tester.takeException(), isNull);
        // The footer sits inside the screen, above the system bar.
        final footer = tester.getRect(find.byType(InventoryFormFooter));
        expect(footer.bottom, lessThanOrEqualTo(size.height));
        await disposeScreen(tester);
      });
    }

    testWidgets('the form holds at 720 wide on a 1280 screen', (tester) async {
      await pump(
        tester,
        size: const Size(1280, 800),
        insets: const FakeViewPadding(top: 24),
      );
      await openMoreDetails(tester);
      for (final card in find.byType(InventoryFormCard).evaluate()) {
        final box = card.renderObject! as RenderBox;
        expect(box.size.width, lessThanOrEqualTo(kInventoryMaxContentWidth));
      }
      await disposeScreen(tester);
    });
  });

  group('keyboard up', () {
    for (final (name, size, insets, keyboard) in [
      ('390x844', const Size(390, 844), _gesture, 300.0),
      ('844x390', const Size(844, 390), _sideways, 200.0),
    ]) {
      for (final (field, index) in [('name', 0), ('buying price', 2)]) {
        testWidgets('$name, $field focused', (tester) async {
          await pump(tester, size: size, insets: insets);
          final input = find.byType(EditableText).at(index);
          await tester.ensureVisible(input);
          await tester.pumpAndSettle();
          await tester.tap(input);
          await tester.pump();
          await raiseKeyboard(tester, insets, keyboard);
          expect(tester.takeException(), isNull);
          final keyboardTop = size.height - keyboard;
          // The body ends at the keyboard (the footer stays under it, as on
          // main) and the focused field scrolls into the space left.
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
