// Issue #493: "We sell at one price" (owner decision: option A). An owner
// setting on businesses.sells_one_price, OFF for every existing shop, suggested
// ON at sign-up for a Restaurant only. When ON the wholesale boxes hide, the
// till charges Retail whatever the customer's tier, and a saved wholesale
// price is never overwritten.

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/features/settings/screens/business_info_screen.dart';
import 'package:reebaplus_pos/features/auth/onboarding/onboarding_draft.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/customers/widgets/add_customer_sheet.dart';
import 'package:reebaplus_pos/features/customers/widgets/customer_parts.dart';
import 'package:reebaplus_pos/features/inventory/screens/add_product_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/product_detail_cards.dart';
import 'package:reebaplus_pos/features/pos/screens/pos_home_screen.dart';
import 'package:reebaplus_pos/features/receiving/screens/receive_cart_screen.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/features/receiving/widgets/edit_receive_item_modal.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/tag_pill.dart';

import '../helpers/inventory_seed.dart';
import '../helpers/screen_harness.dart';
import '../settings/settings_leftovers_fixture.dart';

const _phone = Size(390, 844);
const _insets = FakeViewPadding(top: 24, bottom: 24);
const _grants = {
  ...kInventorySampleGrants,
  'products.edit_buying_price',
  'customers.update',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late Directory docs;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() {
    docs = Directory.systemTemp.createTempSync('one_price_shops');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => docs.path);
  });
  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    docs.deleteSync(recursive: true);
  });

  Future<void> setOnePrice(bool on) =>
      (env.db.update(env.db.businesses)
            ..where((b) => b.id.equals(env.businessId)))
          .write(BusinessesCompanion(sellsOnePrice: Value(on)));

  Future<void> setUpBusiness({required bool sellsOnePrice}) async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
      businessType: 'Beverage distributor',
      sharedPreferences: const {
        'pos_grid_columns': 2,
        'pos_is_list_view': false,
        'hint_pos_gestures': 2,
      },
    );
    await seedInventorySample(env);
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
    if (sellsOnePrice) await setOnePrice(true);
  }

  Future<ProductData> productNamed(String name) => (env.db.select(
    env.db.products,
  )..where((p) => p.name.equals(name))).getSingle();

  Future<void> pump(
    WidgetTester tester, {
    required Widget screen,
    Set<String> grants = _grants,
  }) async {
    tester.view.padding = _insets;
    tester.view.viewPadding = _insets;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    await pumpScreen(
      tester,
      env: env,
      size: _phone,
      screen: screen,
      followView: true,
      bottomNavHeight: 0,
      grantedKeys: grants,
      roleRank: GateTier.ceo,
      overrides: [
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

  /// Opens the till, picks a Wholesaler customer and taps Coca-Cola (retail
  /// 600.00, wholesale 550.00). Returns the cart line.
  Future<Map<String, dynamic>> sellToWholesaler(WidgetTester tester) async {
    await pump(tester, screen: const PosHomeScreen());
    await tester.pump(const Duration(milliseconds: 200));
    final context = tester.element(find.byType(PosHomeScreen));
    final cart = ProviderScope.containerOf(context).read(cartProvider);
    cart.setActiveCustomer(
      Customer(
        id: 'cust-1',
        name: 'Big Buyer',
        addressText: '',
        googleMapsLocation: '',
        priceTier: PriceTier.wholesaler,
      ),
    );
    await tester.pumpAndSettle();
    final tile = find.text('Coca-Cola').first;
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();
    final line = cart.value.singleWhere((l) => l['name'] == 'Coca-Cola');
    return line;
  }

  group('the setting (#493)', () {
    test('is OFF by default for a business row', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await db
          .into(db.businesses)
          .insert(
            BusinessesCompanion.insert(id: const Value('b1'), name: 'Sample'),
          );
      final row = await db.select(db.businesses).getSingle();
      expect(row.sellsOnePrice, isFalse);
      expect(businessSellsOnePrice(row), isFalse);
      expect(businessSellsOnePrice(null), isFalse);
    });

    test('CEO sign-up suggests ON for a Restaurant only', () {
      expect(OnboardingDraft().sellsOnePrice, isFalse);
      expect(suggestsOnePriceAtSignUp('Restaurant'), isTrue);
      expect(suggestsOnePriceAtSignUp('restaurant'), isTrue);
      for (final t in [
        'Beer distributor',
        'Beverage distributor',
        'Supermarket',
        'Pharmacy',
        'Bar',
        'Boutique',
        'Something else',
        null,
      ]) {
        expect(suggestsOnePriceAtSignUp(t), isFalse, reason: '$t');
      }
    });
  });

  group('Business Info switch (#493)', () {
    setUp(() async => env = await setupSettingsEnv());
    tearDown(() => env.dispose());

    testWidgets('toggles "We sell at one price" and saves it', (tester) async {
      await pumpSettingsPage(
        tester,
        env: env,
        screen: const BusinessInfoScreen(),
        size: const Size(390, 844),
      );
      final row = find.byKey(kBusinessInfoSellsOnePriceKey);
      final tile = find.descendant(
        of: row,
        matching: find.byType(SwitchListTile),
      );
      await tester.scrollUntilVisible(
        row,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('We sell at one price'), findsOneWidget);
      expect(
        find.text(
          'Hides wholesale prices. Every customer pays the retail price.',
        ),
        findsOneWidget,
      );
      expect(tester.widget<SwitchListTile>(tile).value, isFalse);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(tile).value, isTrue);

      final save = find.text('Save changes');
      await tester.scrollUntilVisible(
        save,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final biz = await (env.db.select(
        env.db.businesses,
      )..where((b) => b.id.equals(env.businessId))).getSingle();
      expect(biz.sellsOnePrice, isTrue);
      await tester.pumpAndSettle(const Duration(seconds: 5));
      await disposeScreen(tester);
    });
  });

  group('setting OFF (#493)', () {
    setUp(() => setUpBusiness(sellsOnePrice: false));
    tearDown(() => env.dispose());

    testWidgets('shows the Wholesale Price box on Add Product', (tester) async {
      await pump(tester, screen: const AddProductScreen());
      expect(find.byKey(AddProductKeys.wholesale), findsOneWidget);
      await finish(tester);
    });

    testWidgets('shows the tier dropdown on POS Home', (tester) async {
      await pump(tester, screen: const PosHomeScreen());
      expect(find.byKey(kPosTierDropdownKey), findsOneWidget);
      await finish(tester);
    });

    testWidgets('shows Price Tier on the Add Customer sheet', (tester) async {
      await pump(tester, screen: const Scaffold(body: AddCustomerSheet()));
      expect(find.text('Price Tier'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a Wholesaler customer at the till pays wholesale', (
      tester,
    ) async {
      final line = await sellToWholesaler(tester);
      expect(line['priceTier'], 'wholesaler');
      expect(line['unitPriceKobo'], 55000);
      await finish(tester);
    });
  });

  group('setting ON (#493)', () {
    setUp(() => setUpBusiness(sellsOnePrice: true));
    tearDown(() => env.dispose());

    testWidgets('hides the Wholesale box; a new product mirrors retail', (
      tester,
    ) async {
      await pump(tester, screen: const AddProductScreen());
      expect(find.byKey(AddProductKeys.retail), findsOneWidget);
      expect(find.byKey(AddProductKeys.wholesale), findsNothing);

      await type(tester, AddProductKeys.name, 'Jollof Rice');
      await pickIn(tester, AddProductKeys.category, 'Beer');
      await type(tester, AddProductKeys.retail, '2500');
      await type(tester, AddProductKeys.quantity, '5');
      await saveAndConfirm(tester, AddProductKeys.saveAndNew);

      final saved = await productNamed('Jollof Rice');
      expect(saved.retailerPriceKobo, 250000);
      expect(saved.wholesalerPriceKobo, 250000);
      await finish(tester);
    });

    testWidgets('editing a product keeps its saved wholesale price', (
      tester,
    ) async {
      final before = await productNamed('Coca-Cola');
      expect(before.wholesalerPriceKobo, 55000);
      await pump(tester, screen: AddProductScreen(editProduct: before));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(AddProductKeys.wholesale), findsNothing);
      final retail = find.descendant(
        of: find.byKey(AddProductKeys.retail),
        matching: find.byType(EditableText),
      );
      await tester.ensureVisible(retail);
      await tester.enterText(retail, '700');
      await tester.pump();
      final save = find.byKey(AddProductKeys.save);
      await tester.ensureVisible(save);
      await tester.tap(save);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(seconds: 6));

      final after = await productNamed('Coca-Cola');
      expect(after.retailerPriceKobo, 70000);
      expect(after.wholesalerPriceKobo, 55000, reason: 'never overwritten');
      await finish(tester);
    });

    testWidgets('hides the tier dropdown on POS Home', (tester) async {
      await pump(tester, screen: const PosHomeScreen());
      expect(find.byKey(kPosTierDropdownKey), findsNothing);
      await finish(tester);
    });

    testWidgets('a Wholesaler customer at the till pays retail', (
      tester,
    ) async {
      final line = await sellToWholesaler(tester);
      expect(line['priceTier'], 'retailer');
      expect(line['unitPriceKobo'], 60000);
      await finish(tester);
    });

    testWidgets('hides Price Tier on the Add Customer sheet', (tester) async {
      await pump(tester, screen: const Scaffold(body: AddCustomerSheet()));
      expect(find.text('Price Tier'), findsNothing);
      await finish(tester);
    });

    testWidgets('Receive cart shows Price instead of Ret/Whls', (tester) async {
      final product = await productNamed('Coca-Cola');
      final context = await pumpScreen(
        tester,
        env: env,
        size: _phone,
        screen: const ReceiveCartScreen(),
        grantedKeys: _grants,
        roleRank: GateTier.ceo,
      );
      ProviderScope.containerOf(
        context,
      ).read(receiveCartProvider.notifier).addOrIncrement(product);
      await tester.pumpAndSettle();
      expect(find.textContaining('Price:'), findsOneWidget);
      expect(find.textContaining('Whls:'), findsNothing);
      await finish(tester);
    });

    testWidgets('Edit Receive Item hides Wholesale and keeps the saved price', (
      tester,
    ) async {
      final product = await productNamed('Coca-Cola');
      final context = await pumpScreen(
        tester,
        env: env,
        size: _phone,
        screen: const Scaffold(body: SizedBox()),
        grantedKeys: _grants,
        roleRank: GateTier.ceo,
      );
      final container = ProviderScope.containerOf(context);
      container.read(receiveCartProvider.notifier).addOrIncrement(product);
      final line = container.read(receiveCartProvider).single;
      expect(line.wholesaleKobo, 55000);

      await pumpScreen(
        tester,
        env: env,
        size: _phone,
        screen: Scaffold(body: EditReceiveItemModal(item: line)),
        grantedKeys: _grants,
        roleRank: GateTier.ceo,
      );
      expect(find.text('Retail Price'), findsOneWidget);
      expect(find.text('Wholesale Price'), findsNothing);
      await finish(tester);
    });
  });

  group('Product Prices & Profit card unit tests (#493)', () {
    testWidgets(
      'shows Wholesale tile and profit row when showWholesale is true',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: ProductPricesCard(
                perNoun: 'unit',
                retailKobo: 50000,
                wholesaleKobo: 45000,
                costKobo: 30000,
                showProfit: true,
                showWholesale: true,
              ),
            ),
          ),
        );

        expect(find.text('Retail'), findsOneWidget);
        expect(find.text('Wholesale'), findsOneWidget);
        expect(find.text('Retail profit'), findsOneWidget);
        expect(find.text('Wholesale profit'), findsOneWidget);
      },
    );

    testWidgets(
      'hides Wholesale tile and profit row when showWholesale is false',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: ProductPricesCard(
                perNoun: 'unit',
                retailKobo: 50000,
                wholesaleKobo: 50000,
                costKobo: 30000,
                showProfit: true,
                showWholesale: false,
              ),
            ),
          ),
        );

        expect(find.text('Price'), findsOneWidget);
        expect(find.text('Wholesale'), findsNothing);
        expect(find.text('Profit'), findsOneWidget);
        expect(find.text('Wholesale profit'), findsNothing);
      },
    );
  });

  group('Customer cards & rows unit tests (#493)', () {
    testWidgets(
      'CustomerProfileCard hides tier TagPill when showTier is false',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: CustomerProfileCard(
                initials: 'JD',
                name: 'John Doe',
                wholesaler: false,
                phone: '08012345678',
                address: 'Abuja',
                since: 'Since Jan 2026',
                showTier: false,
              ),
            ),
          ),
        );

        expect(find.byType(TagPill), findsNothing);
      },
    );

    testWidgets('CustomerListRow hides tier TagPill when showTier is false', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomerListRow(
              name: 'John Doe',
              address: 'Abuja',
              tierLabel: 'RETAILER',
              balanceLabel: '₦0.00',
              owes: false,
              showTier: false,
              onTap: () {},
            ),
          ),
        ),
      );

      expect(find.byType(TagPill), findsNothing);
    });
  });
}
