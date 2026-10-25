// #426 end to end on the phone: browse → add from two shops → sign in →
// details → place → one order per shop in My Orders. Plus the failing-shop,
// out-of-area and keyboard-up cases.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/features/browse/screens/browse_screen.dart';
import 'package:reebaplus_pos/features/browse/screens/my_orders_screen.dart';
import 'package:reebaplus_pos/features/browse/screens/place_order_screen.dart';
import 'package:reebaplus_pos/features/browse/screens/shopper_cart_screen.dart';
import 'package:reebaplus_pos/features/browse/screens/shopper_details_screen.dart';
import 'package:reebaplus_pos/features/browse/screens/shopper_sign_in_screen.dart';
import 'package:reebaplus_pos/core/storefront/shopper_models.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

import '../browse/browse_fixtures.dart';
import 'shopper_fixtures.dart';

Future<void> typeInto(WidgetTester tester, Key key, String text) async {
  final field = find.descendant(
    of: find.byKey(key),
    matching: find.byType(EditableText),
  );
  await tester.ensureVisible(field);
  await tester.enterText(field, text);
  await tester.pump();
}

Future<void> tapKey(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

Future<void> addFromSheet(WidgetTester tester, String name) async {
  await tester.tap(find.text(name).first);
  await tester.pumpAndSettle();
  await tapKey(tester, const Key('shopper-add-to-cart'));
}

void main() {
  testWidgets('browse → two shops → sign in → details → two orders', (tester) async {
    final backend = FakeShopperBackend();
    final auth = FakeShopperAuth();
    final push = FakePush();
    await pumpShopper(tester, screen: const BrowseScreen(), backend: backend,
        auth: auth, push: push,
        storefront: FakeStorefront()..store = [_delivers]);

    await addFromSheet(tester, 'Star Lager'); // store-1, starts at 2
    await addFromSheet(tester, 'Eva Water 75cl'); // store-2
    await tapKey(tester, const Key('browse-cart'));
    expect(find.byType(ShopperCartScreen), findsOneWidget);
    expect(find.text('Place 2 orders'), findsOneWidget);
    expect(find.text('Stallion Global · Nasarawa'), findsOneWidget);
    expect(find.text('Keffi Drinks · Keffi'), findsOneWidget);

    await tapKey(tester, const Key('shopper-cart-place-order'));
    expect(find.byType(ShopperSignInScreen), findsOneWidget);
    await typeInto(tester, const Key('shopper-email'), 'ada@example.com');
    await tapKey(tester, const Key('shopper-sign-in-submit'));
    await typeInto(tester, const Key('shopper-code'), '123456');
    await tapKey(tester, const Key('shopper-sign-in-submit'));
    expect(push.signedIn, 1);

    // First time: details, with the sharing notice.
    expect(find.byType(ShopperDetailsScreen), findsOneWidget);
    expect(find.byKey(const Key('shopper-sharing-notice')), findsOneWidget);
    await typeInto(tester, const Key('shopper-name'), 'Ada Obi');
    await typeInto(tester, const Key('shopper-phone'), '08030000000');
    await tapKey(tester, const Key('shopper-area'));
    await typeInto(tester, const ValueKey('area-search-state'), 'Nasarawa');
    await tester.pumpAndSettle();
    await tapKey(tester, const ValueKey('area-option-Nasarawa'));
    await typeInto(tester, const ValueKey('area-search-lga'), 'Keffi');
    await tester.pumpAndSettle();
    await tapKey(tester, const ValueKey('area-option-Keffi'));
    await typeInto(tester, const Key('shopper-street'), '1 Road');
    await tapKey(tester, const Key('shopper-details-save'));

    expect(find.byType(PlaceOrderScreen), findsOneWidget);
    expect(find.text('1 Road, Keffi, Nasarawa'), findsOneWidget);
    await typeInto(tester, const Key('shopper-note'), 'Blue gate');
    await tapKey(tester, const Key('shopper-place-orders'));

    final place = backend.calls.lastWhere((c) => c.$1 == 'shopper_place_orders').$2;
    expect((place['p_orders']! as List), hasLength(2));
    expect(place['p_note'], 'Blue gate');
    expect(find.text('Reference ON-1'), findsOneWidget);
    expect(find.text('Reference ON-2'), findsOneWidget);

    await tapKey(tester, const Key('shopper-see-my-orders'));
    expect(find.byType(MyOrdersScreen), findsOneWidget);
    expect(find.textContaining('Ref ON-'), findsNWidgets(2));
    expect(find.text('Placed'), findsNWidgets(2));
    await tester.pump(const Duration(seconds: 5)); // let the toast close
  });

  testWidgets('a failing shop is reported and its lines stay in the cart',
      (tester) async {
    final backend = FakeShopperBackend()
      ..profile = Map.of(kProfileJson)
      ..failStores['store-2'] = 'not_enough_stock';
    final storefront = FakeStorefront()..store = [_delivers];
    await pumpShopper(tester, screen: const ShopperCartScreen(),
        backend: backend, storefront: storefront,
        auth: FakeShopperAuth(email: 'ada@example.com'),
        cartJson: twoShopCartJson());
    await tapKey(tester, const Key('shopper-cart-place-order'));
    await tapKey(tester, const Key('shopper-place-orders'));
    expect(find.text('Reference ON-1'), findsOneWidget);
    expect(find.textContaining("The store can't supply that many"), findsOneWidget);
    // The message never reveals a count.
    expect(find.textContaining(RegExp(r'only \d', caseSensitive: false)), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Keffi Drinks · Keffi'), findsOneWidget);
    expect(find.text('Stallion Global · Nasarawa'), findsNothing);
  });

  testWidgets('shops that do not deliver to the address are flagged and skipped',
      (tester) async {
    final backend = FakeShopperBackend()..profile = Map.of(kProfileJson);
    final storefront = FakeStorefront(); // kStoreRow: delivers_to_area false
    await pumpShopper(tester, size: const Size(390, 1600),
        screen: PlaceOrderScreen(profile: ShopperProfile.fromJson(kProfileJson)),
        backend: backend, storefront: storefront,
        auth: FakeShopperAuth(email: 'ada@example.com'),
        cartJson: twoShopCartJson());
    expect(find.byKey(const ValueKey('shopper-out-of-area-store-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('shopper-out-of-area-store-2')), findsOneWidget);
    // Nothing is placeable, so Place is off and nothing is sent.
    await tester.tap(find.byKey(const Key('shopper-place-orders')));
    await tester.pumpAndSettle();
    expect(backend.calls.where((c) => c.$1 == 'shopper_place_orders'), isEmpty);
  });

  testWidgets('cancel only while Placed', (tester) async {
    final backend = FakeShopperBackend();
    backend.orders.addAll([
      {'id': 'o1', 'store_id': 'store-1', 'business_name': 'Stallion Global',
       'store_lga': 'Nasarawa', 'reference': 'ON-AAA', 'status': 'new',
       'currency': 'NGN', 'total_kobo': 100, 'placed_at': '2026-10-25T09:00:00Z',
       'lines': []},
      {'id': 'o2', 'store_id': 'store-2', 'business_name': 'Keffi Drinks',
       'store_lga': 'Keffi', 'reference': 'ON-BBB', 'status': 'accepted',
       'currency': 'NGN', 'total_kobo': 100, 'placed_at': '2026-10-24T09:00:00Z',
       'lines': []},
    ]);
    await pumpShopper(tester, screen: const MyOrdersScreen(), backend: backend,
        auth: FakeShopperAuth(email: 'ada@example.com'));
    expect(find.byKey(const ValueKey('my-order-cancel-o1')), findsOneWidget);
    expect(find.byKey(const ValueKey('my-order-cancel-o2')), findsNothing);
    await tapKey(tester, const ValueKey('my-order-cancel-o1'));
    await tapKey(tester, const Key('shopper-cancel-confirm'));
    expect(find.text('Cancelled'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5)); // let the toast close
  });

  group('keyboard up (owner rule: text boxes stay reachable)', () {
    Future<void> keyboardUp(WidgetTester tester, {double height = 336}) async {
      tester.view.viewInsets = FakeViewPadding(bottom: height);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
    }

    testWidgets('sign-in email and code', (tester) async {
      await pumpShopper(tester, screen: const ShopperSignInScreen(),
          size: const Size(390, 640));
      await keyboardUp(tester);
      await typeInto(tester, const Key('shopper-email'), 'ada@example.com');
      expect(tester.takeException(), isNull);
      await tapKey(tester, const Key('shopper-sign-in-submit'));
      await typeInto(tester, const Key('shopper-code'), '123456');
      await tester.ensureVisible(find.byKey(const Key('shopper-sign-in-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shopper-sign-in-submit')).hitTestable(),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('details form', (tester) async {
      await pumpShopper(tester, screen: const ShopperDetailsScreen(),
          size: const Size(844, 390));
      await keyboardUp(tester, height: 200);
      await typeInto(tester, const Key('shopper-street'), '1 Road');
      await tester.ensureVisible(find.byKey(const Key('shopper-street')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('shopper-street')),
          matching: find.byType(EditableText),
        ).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('quantity pop-up', (tester) async {
      await pumpShopper(tester, screen: const ShopperCartScreen(),
          cartJson: twoShopCartJson(), size: const Size(844, 390));
      await tester.tap(find.byKey(const Key('shopper-qty-value')).first);
      await tester.pumpAndSettle();
      await keyboardUp(tester, height: 200);
      expect(find.byType(AlertDialog), findsOneWidget);
      await typeInto(tester, const Key('shopper-qty-input'), '3');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      // 3 breaks "steps of 2": the pop-up says so and stays open.
      expect(find.byKey(const Key('shopper-qty-error')), findsOneWidget);
      expect(find.byType(AppInput).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

const _delivers = <String, Object?>{
  'store_id': 'store-1',
  'business_name': 'Stallion Global',
  'logo_url': null,
  'store_state': 'Nasarawa',
  'store_lga': 'Nasarawa',
  'online_note': null,
  'currency': 'NGN',
  'delivers_to_area': true,
  'stock_may_be_stale': false,
};
