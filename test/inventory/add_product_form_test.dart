// #487 PR 2: the new Add Product form's behaviour — validation points at the
// right box, Save & New, the name match opening Product Details, unit chips,
// "how many in one", the profit rows and the Track Empty Crates rule.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/shared/scanner/barcode_scan_page.dart';
import 'package:reebaplus_pos/shared/scanner/scanner_providers.dart';
import '../helpers/fake_barcode_scanner.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/inventory/screens/add_product_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/product_detail_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/product_form_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

import '../helpers/inventory_seed.dart';
import '../helpers/screen_harness.dart';

const _withBuying = {...kInventorySampleGrants, 'products.edit_buying_price'};
const _phone = Size(390, 844);
const _insets = FakeViewPadding(top: 24, bottom: 24);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late InventorySample sample;

  Future<void> setUpBusiness(String type) async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
      businessType: type,
    );
    sample = await seedInventorySample(env);
    // The harness signs in 'test-user-id'; a save records them as the one
    // who added the opening stock, so the row must exist.
    await env.db
        .into(env.db.users)
        .insert(
          UsersCompanion.insert(
            id: const Value('test-user-id'),
            businessId: env.businessId,
            name: 'Test Admin',
            pin: '1234',
          ),
        );
  }

  tearDown(() => env.dispose());

  Future<void> pump(
    WidgetTester tester, {
    Widget screen = const AddProductScreen(),
    Size size = _phone,
    Set<String> grants = _withBuying,
    FakeBarcodeScanner? scanner,
  }) async {
    tester.view.padding = _insets;
    tester.view.viewPadding = _insets;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: screen,
      followView: true,
      bottomNavHeight: 0,
      grantedKeys: grants,
      roleRank: GateTier.ceo,
      overrides: [
        if (scanner != null) barcodeScannerProvider.overrideWithValue(scanner),
        firstRunSurfaceStateProvider.overrideWithValue(
          FirstRunSurfaceState.hasContent,
        ),
      ],
    );
  }

  Future<void> finish(WidgetTester tester) async {
    AppNotification.hide();
    await disposeScreen(tester);
  }

  Finder box(Key key) => find.descendant(
    of: find.byKey(key),
    matching: find.byType(TextFormField),
  );

  String textIn(WidgetTester tester, Key key) =>
      tester.widget<TextFormField>(box(key)).controller!.text;

  Future<void> type(WidgetTester tester, Key key, String text) async {
    await tester.ensureVisible(box(key));
    await tester.enterText(box(key), text);
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, Key key) async {
    await tester.ensureVisible(find.byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
  }

  Future<void> pickIn(WidgetTester tester, Key field, String option) async {
    await tapKey(tester, field);
    await tester.tap(find.text(option).last);
    await tester.pumpAndSettle();
  }

  Future<void> saveAndConfirm(WidgetTester tester, Key button) async {
    await tester.tap(find.byKey(button));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, 'Save'));
    await tester.pumpAndSettle();
  }

  /// Product Details shimmers while it loads, so it never "settles".
  Future<void> settleDetails(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<ProductData?> saved(String name) => (env.db.select(
    env.db.products,
  )..where((p) => p.name.equals(name))).getSingleOrNull();

  group('a crate business (Beverage distributor)', () {
    setUp(() => setUpBusiness('Beverage distributor'));

    testWidgets('an error scrolls its box into view', (tester) async {
      await pump(tester);
      await type(tester, AddProductKeys.name, 'Star Radler');
      // Down at the bottom of the form, far from Retail Price.
      await tester.ensureVisible(box(AddProductKeys.description));
      await tester.pumpAndSettle();
      expect(tester.getRect(box(AddProductKeys.retail)).bottom, lessThan(100));

      await tester.tap(find.byKey(AddProductKeys.save));
      await tester.pumpAndSettle();

      final retail = tester.getRect(box(AddProductKeys.retail));
      final footer = tester.getRect(find.byKey(AddProductKeys.save));
      expect(retail.top, greaterThan(90));
      expect(retail.bottom, lessThan(footer.top));
      expect(find.text('Retail Price is required.'), findsOneWidget);
      expect(await saved('Star Radler'), isNull);
      await finish(tester);
    });

    testWidgets('a zero opening quantity points at the stepper', (
      tester,
    ) async {
      await pump(tester);
      await type(tester, AddProductKeys.name, 'Star Radler');
      await type(tester, AddProductKeys.retail, '500');
      await tester.tap(find.byKey(AddProductKeys.save));
      await tester.pumpAndSettle();
      expect(
        find.text('Opening Quantity must be greater than 0.'),
        findsOneWidget,
      );
      final quantity = tester.getRect(box(AddProductKeys.quantity));
      expect(quantity.top, greaterThan(90));
      expect(
        quantity.bottom,
        lessThan(tester.getRect(find.byKey(AddProductKeys.save)).top),
      );
      await finish(tester);
    });

    testWidgets('unit chips: "Bottle Crate" is shown, Bottle is saved, with '
        'the bottles in one crate', (tester) async {
      await pump(tester);
      final bottle = find.byKey(AddProductKeys.unitChip('Bottle'));
      expect(
        find.descendant(of: bottle, matching: find.text('Bottle Crate')),
        findsOneWidget,
      );
      // No plain Crate for a new product.
      expect(find.byKey(AddProductKeys.unitChip('Crate')), findsNothing);
      // No unit picked by default, so no "how many in one" box.
      expect(find.byKey(AddProductKeys.unitsPerPack), findsNothing);

      await type(tester, AddProductKeys.name, 'Hero Lager');
      await tapKey(tester, AddProductKeys.unitChip('Bottle'));
      expect(find.text('Bottles in one crate'), findsOneWidget);
      expect(find.text('All prices are per crate.'), findsOneWidget);
      await type(tester, AddProductKeys.unitsPerPack, '12');
      await type(tester, AddProductKeys.retail, '9000');
      await type(tester, AddProductKeys.quantity, '3');
      await saveAndConfirm(tester, AddProductKeys.save);

      final product = await saved('Hero Lager');
      expect(product!.unit, 'Bottle');
      expect(product.unitsPerPack, 12);
      expect(product.trackEmpties, isTrue);
      await finish(tester);
    });

    testWidgets('tapping the picked chip again clears the unit', (
      tester,
    ) async {
      await pump(tester);
      await tapKey(tester, AddProductKeys.unitChip('Pack'));
      expect(find.text('Pieces in one pack'), findsOneWidget);
      expect(
        tester
            .widget<ProductUnitChip>(
              find.byKey(AddProductKeys.unitChip('Pack')),
            )
            .selected,
        isTrue,
      );
      await tapKey(tester, AddProductKeys.unitChip('Pack'));
      expect(
        tester
            .widget<ProductUnitChip>(
              find.byKey(AddProductKeys.unitChip('Pack')),
            )
            .selected,
        isFalse,
      );
      expect(find.byKey(AddProductKeys.unitsPerPack), findsNothing);
      expect(find.text('All prices are per item.'), findsOneWidget);
      // A Can has no "how many in one" box.
      await tapKey(tester, AddProductKeys.unitChip('Can'));
      expect(find.byKey(AddProductKeys.unitsPerPack), findsNothing);
      await finish(tester);
    });

    testWidgets('a count typed for Pack is dropped when the unit changes to '
        'Can', (tester) async {
      await pump(tester);
      await type(tester, AddProductKeys.name, 'Fizz Can');
      await tapKey(tester, AddProductKeys.unitChip('Pack'));
      await type(tester, AddProductKeys.unitsPerPack, '6');
      await tapKey(tester, AddProductKeys.unitChip('Can'));
      await type(tester, AddProductKeys.retail, '400');
      await type(tester, AddProductKeys.quantity, '2');
      await saveAndConfirm(tester, AddProductKeys.save);
      final product = await saved('Fizz Can');
      expect(product!.unit, 'Can');
      expect(product.unitsPerPack, isNull);
      await finish(tester);
    });

    testWidgets('profit rows: amount and whole % of the selling price; a loss '
        'reads in danger', (tester) async {
      await pump(tester);
      expect(find.byType(ProductProfitBox), findsNothing);
      await type(tester, AddProductKeys.retail, '15000');
      await type(tester, AddProductKeys.wholesale, '14200');
      // No cost yet: no rows.
      expect(find.byType(ProductProfitBox), findsNothing);
      await type(tester, AddProductKeys.cost, '13500');

      expect(find.text('Retail profit'), findsOneWidget);
      expect(find.text('10% of selling price'), findsOneWidget);
      expect(find.text('₦1,500'), findsOneWidget);
      expect(find.text('Wholesale profit'), findsOneWidget);
      // 700 / 14,200 = 4.9% → 5%.
      expect(find.text('5% of selling price'), findsOneWidget);
      expect(find.text('₦700'), findsOneWidget);

      // Wholesale under cost: a loss, in the fixed danger colour.
      await type(tester, AddProductKeys.wholesale, '13000');
      final loss = tester.widget<Text>(find.text('-₦500'));
      expect(loss.style!.color, AppFixedColors.dark.danger);
      expect(find.text('-4% of selling price'), findsOneWidget);

      // A blank wholesale mirrors retail, as it is saved.
      await type(tester, AddProductKeys.wholesale, '');
      expect(find.text('10% of selling price'), findsNWidgets(2));
      await finish(tester);
    });

    testWidgets('without products.edit_buying_price: no Cost Price and no '
        'profit rows', (tester) async {
      await pump(tester, grants: kInventorySampleGrants);
      expect(find.byKey(AddProductKeys.cost), findsNothing);
      await type(tester, AddProductKeys.retail, '15000');
      expect(find.byType(ProductProfitBox), findsNothing);
      await finish(tester);
    });

    testWidgets('Track Empty Crates shows only for Bottle; the deposit fills '
        'from the manufacturer and is saved manufacturer-wide', (tester) async {
      await pump(tester);
      expect(find.text('Track Empty Crates'), findsNothing);
      await tapKey(tester, AddProductKeys.unitChip('Can'));
      expect(find.text('Track Empty Crates'), findsNothing);
      await tapKey(tester, AddProductKeys.unitChip('Bottle'));
      expect(find.text('Track Empty Crates'), findsOneWidget);
      expect(
        tester.widget<Switch>(find.byKey(AddProductKeys.trackEmpties)).value,
        isTrue,
      );

      await pickIn(tester, AddProductKeys.manufacturer, 'Nigerian Breweries');
      expect(textIn(tester, AddProductKeys.crateDeposit), '1200.00');
      expect(
        find.text(
          'Crates are counted under the manufacturer: Nigerian Breweries.',
        ),
        findsOneWidget,
      );
      await type(tester, AddProductKeys.crateDeposit, '1500');
      await type(tester, AddProductKeys.name, 'Hero 60cl');
      await type(tester, AddProductKeys.retail, '9000');
      await type(tester, AddProductKeys.quantity, '1');
      await saveAndConfirm(tester, AddProductKeys.save);

      final product = await saved('Hero 60cl');
      expect(product!.trackEmpties, isTrue);
      expect(product.emptyCrateValueKobo, 150000);
      final manufacturer = await (env.db.select(
        env.db.manufacturers,
      )..where((m) => m.id.equals(product.manufacturerId!))).getSingle();
      expect(manufacturer.depositAmountKobo, 150000);
      await finish(tester);
    });

    testWidgets('Save & New saves, clears the form and keeps the store, '
        'category and manufacturer', (tester) async {
      await pump(tester);
      await type(tester, AddProductKeys.name, 'Hero 33cl');
      await pickIn(tester, AddProductKeys.category, 'Beer');
      await pickIn(tester, AddProductKeys.manufacturer, 'Nigerian Breweries');
      await tapKey(tester, AddProductKeys.unitChip('Bottle'));
      await type(tester, AddProductKeys.retail, '700');
      await type(tester, AddProductKeys.cost, '600');
      await type(tester, AddProductKeys.quantity, '4');
      await saveAndConfirm(tester, AddProductKeys.saveAndNew);

      final product = await saved('Hero 33cl');
      expect(product, isNotNull);
      expect(product!.unit, 'Bottle');
      expect(
        await env.db.stockLedgerDao.getCurrentStock(product.id, env.storeId),
        4,
      );

      // Still on the form, cleared for the next product.
      expect(find.byType(AddProductScreen), findsOneWidget);
      expect(textIn(tester, AddProductKeys.name), isEmpty);
      expect(textIn(tester, AddProductKeys.retail), isEmpty);
      expect(textIn(tester, AddProductKeys.cost), isEmpty);
      expect(textIn(tester, AddProductKeys.quantity), '0');
      expect(textIn(tester, AddProductKeys.lowStock), '5');
      expect(
        tester
            .widgetList<ProductUnitChip>(find.byType(ProductUnitChip))
            .where((c) => c.selected),
        isEmpty,
      );
      // Kept.
      expect(
        tester
            .widget<ProductPickerField>(find.byKey(AddProductKeys.category))
            .value,
        'Beer',
      );
      expect(
        tester
            .widget<ProductPickerField>(find.byKey(AddProductKeys.manufacturer))
            .value,
        'Nigerian Breweries',
      );
      // The cursor is back in Name.
      final name = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(AddProductKeys.name),
          matching: find.byType(EditableText),
        ),
      );
      expect(name.focusNode.hasFocus, isTrue);

      // The next one saves into the same category and manufacturer.
      await type(tester, AddProductKeys.name, 'Hero 50cl');
      await type(tester, AddProductKeys.retail, '800');
      await type(tester, AddProductKeys.quantity, '2');
      await saveAndConfirm(tester, AddProductKeys.save);
      final next = await saved('Hero 50cl');
      expect(next!.categoryId, product.categoryId);
      expect(next.manufacturerId, product.manufacturerId);
      expect(next.unit, isNull);
      await finish(tester);
    });

    testWidgets('a name you already have lists it; tapping it opens its '
        'Product Details over the untouched form', (tester) async {
      await env.db.catalogDao.setProductArchived(
        sample.productIds['Star Lager']!,
        true,
      );
      await pump(tester);
      await type(tester, AddProductKeys.name, 'Gul');
      await type(tester, AddProductKeys.retail, '1234');
      expect(
        find.text('Already in your inventory. Tap one to open it.'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Bottle Crate Gulder'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bottle Crate Gulder'));
      await settleDetails(tester);
      expect(find.byType(ProductDetailScreen), findsOneWidget);
      expect(
        tester
            .widget<ProductDetailScreen>(find.byType(ProductDetailScreen))
            .item
            .id,
        sample.productIds['Gulder'],
      );

      Navigator.of(tester.element(find.byType(ProductDetailScreen))).pop();
      await settleDetails(tester);
      expect(find.byType(ProductDetailScreen), findsNothing);
      expect(textIn(tester, AddProductKeys.name), 'Gul');
      expect(textIn(tester, AddProductKeys.retail), '1,234');

      // An archived product says so, and still opens.
      await type(tester, AddProductKeys.name, 'Star');
      await tester.ensureVisible(find.text('Bottle Crate Star Lager'));
      await tester.pumpAndSettle();
      final archived = find.ancestor(
        of: find.text('Bottle Crate Star Lager'),
        matching: find.byType(InkWell),
      );
      expect(
        find.descendant(of: archived, matching: find.byType(TagPill)),
        findsOneWidget,
      );
      expect(find.text('Archived'), findsOneWidget);
      await tester.ensureVisible(find.text('Bottle Crate Star Lager'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bottle Crate Star Lager'));
      await settleDetails(tester);
      expect(find.byType(ProductDetailScreen), findsOneWidget);
      await finish(tester);
    });

    testWidgets('scanning a code you already have: Open it opens its Product '
        'Details (#465)', (tester) async {
      await (env.db.update(env.db.products)
            ..where((p) => p.id.equals(sample.productIds['Gulder']!)))
          .write(const ProductsCompanion(barcode: Value('4455')));
      final scanner = FakeBarcodeScanner();
      await pump(tester, scanner: scanner);
      final button = find.byTooltip('Scan barcode');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      scanner.camera!.read('4455');
      await tester.pumpAndSettle();
      expect(find.byType(BarcodeScanPage), findsNothing);
      await tester.ensureVisible(find.text('Open it'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open it'));
      await settleDetails(tester);
      expect(find.byType(ProductDetailScreen), findsOneWidget);
      await finish(tester);
    });

    testWidgets('Receive Stock: no Store box; the title stays Add Product', (
      tester,
    ) async {
      // A second store would show the Store box in direct mode.
      await env.db
          .into(env.db.stores)
          .insert(
            StoresCompanion.insert(
              id: const Value('store-second'),
              businessId: env.businessId,
              name: 'Second Store',
            ),
          );
      await pump(tester);
      expect(find.byKey(AddProductKeys.store), findsOneWidget);
      await disposeScreen(tester);

      await pump(tester, screen: const AddProductScreen(receiveMode: true));
      expect(find.byKey(AddProductKeys.store), findsNothing);
      expect(find.text('Add Product'), findsOneWidget);
      expect(find.text('Opening Quantity'), findsOneWidget);
      expect(
        find.text('This amount goes onto the delivery list.'),
        findsOneWidget,
      );
      await finish(tester);
    });
  });

  group('a shop that does not count crates (Pharmacy)', () {
    setUp(() => setUpBusiness('Pharmacy'));

    testWidgets('a Bottle is a plain bottle: no crate words, no "how many in '
        'one" box, no Track Empty Crates', (tester) async {
      await pump(tester);
      final bottle = find.byKey(AddProductKeys.unitChip('Bottle'));
      expect(
        find.descendant(of: bottle, matching: find.text('Bottle')),
        findsOneWidget,
      );
      await tapKey(tester, AddProductKeys.unitChip('Bottle'));
      expect(find.text('Bottle Crate'), findsNothing);
      expect(find.byKey(AddProductKeys.unitsPerPack), findsNothing);
      expect(find.text('All prices are per bottle.'), findsOneWidget);
      expect(find.text('Track Empty Crates'), findsNothing);
      // Pack still has its box.
      await tapKey(tester, AddProductKeys.unitChip('Pack'));
      expect(find.text('Pieces in one pack'), findsOneWidget);
      await finish(tester);
    });
  });
}
