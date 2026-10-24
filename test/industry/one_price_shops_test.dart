// Issue #493: One-price shops (all trades except Beverage distributor).

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
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

  Future<void> setUpBusiness(String type) async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
      businessType: type,
      sharedPreferences: const {
        'pos_grid_columns': 2,
        'pos_is_list_view': false,
        'hint_pos_gestures': 2,
      },
    );
    await seedInventorySample(env);
    await env.db.into(env.db.users).insert(
          UsersCompanion.insert(
            id: const Value('test-user-id'),
            businessId: env.businessId,
            name: 'Test Admin',
            pin: '1234',
          ),
        );
  }

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


  group('Wholesale business (Beverage distributor) (#493)', () {
    setUp(() => setUpBusiness('Beverage distributor'));
    tearDown(() => env.dispose());

    testWidgets('shows Wholesale Price box on Add Product', (tester) async {
      await pump(tester, screen: const AddProductScreen());
      expect(find.byKey(AddProductKeys.retail), findsOneWidget);
      expect(find.byKey(AddProductKeys.wholesale), findsOneWidget);
      await finish(tester);
    });

    testWidgets('shows tier dropdown on POS Home', (tester) async {
      await pump(tester, screen: const PosHomeScreen());
      expect(find.byKey(kPosTierDropdownKey), findsOneWidget);
      await finish(tester);
    });

    testWidgets('shows Price Tier dropdown on Add Customer sheet', (tester) async {
      await pump(tester, screen: const Scaffold(body: AddCustomerSheet()));
      expect(find.text('Price Tier'), findsOneWidget);
      await finish(tester);
    });
  });

  group('One-price business (Restaurant) (#493)', () {
    setUp(() => setUpBusiness('Restaurant'));
    tearDown(() => env.dispose());

    testWidgets('hides Wholesale Price box and mirrors wholesale to retail on save', (tester) async {
      await pump(tester, screen: const AddProductScreen());
      expect(find.byKey(AddProductKeys.retail), findsOneWidget);
      expect(find.byKey(AddProductKeys.wholesale), findsNothing);

      await type(tester, AddProductKeys.name, 'Jollof Rice');
      await pickIn(tester, AddProductKeys.category, 'Beer');
      await type(tester, AddProductKeys.retail, '2500');
      await type(tester, AddProductKeys.quantity, '5');
      await saveAndConfirm(tester, AddProductKeys.saveAndNew);

      final saved = await (env.db.select(env.db.products)
            ..where((p) => p.name.equals('Jollof Rice')))
          .getSingleOrNull();
      expect(saved, isNotNull);
      expect(saved!.retailerPriceKobo, 250000);
      expect(saved.wholesalerPriceKobo, 250000);
      await finish(tester);
    });

    testWidgets('hides tier dropdown on POS Home', (tester) async {
      await pump(tester, screen: const PosHomeScreen());
      expect(find.byKey(kPosTierDropdownKey), findsNothing);
      await finish(tester);
    });

    testWidgets('hides Price Tier dropdown on Add Customer sheet', (tester) async {
      await pump(tester, screen: const Scaffold(body: AddCustomerSheet()));
      expect(find.text('Price Tier'), findsNothing);
      await finish(tester);
    });

    testWidgets('displays Price instead of Ret/Whls on ReceiveCartScreen', (tester) async {
      final product = await (env.db.select(env.db.products)..limit(1)).getSingle();
      final context = await pumpScreen(
        tester,
        env: env,
        size: _phone,
        screen: const ReceiveCartScreen(),
        grantedKeys: _grants,
        roleRank: GateTier.ceo,
      );
      ProviderScope.containerOf(context)
          .read(receiveCartProvider.notifier)
          .addOrIncrement(product);
      await tester.pumpAndSettle();

      expect(find.textContaining('Price:'), findsOneWidget);
      expect(find.textContaining('Whls:'), findsNothing);
      await finish(tester);
    });

    testWidgets('hides Wholesale Price input on EditReceiveItemModal', (tester) async {
      const line = ReceiveCartLine(
        productId: 'prod-1',
        productName: 'Item 1',
        qty: 1,
        buyingPriceKobo: 10000,
        retailKobo: 15000,
        wholesaleKobo: 15000,
        trackEmpties: false,
      );

      await pumpScreen(
        tester,
        env: env,
        size: _phone,
        screen: const Scaffold(body: EditReceiveItemModal(item: line)),
        grantedKeys: _grants,
        roleRank: GateTier.ceo,
      );

      expect(find.text('Retail Price'), findsOneWidget);
      expect(find.text('Wholesale Price'), findsNothing);
      await finish(tester);
    });
  });

  group('One-price business (Supermarket) (#493)', () {
    setUp(() => setUpBusiness('Supermarket'));
    tearDown(() => env.dispose());

    testWidgets('hides Wholesale Price box on Add Product', (tester) async {
      await pump(tester, screen: const AddProductScreen());
      expect(find.byKey(AddProductKeys.retail), findsOneWidget);
      expect(find.byKey(AddProductKeys.wholesale), findsNothing);
      await finish(tester);
    });
  });

  group('Product Prices & Profit card unit tests (#493)', () {
    testWidgets('shows Wholesale tile and profit row when showWholesale is true', (tester) async {
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
    });

    testWidgets('hides Wholesale tile and profit row when showWholesale is false', (tester) async {
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
    });
  });

  group('Customer cards & rows unit tests (#493)', () {
    testWidgets('CustomerProfileCard hides tier TagPill when showTier is false', (tester) async {
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
    });

    testWidgets('CustomerListRow hides tier TagPill when showTier is false', (tester) async {
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
