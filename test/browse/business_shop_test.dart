// #437 — business users can shop. Browse opened from the till (Shop) on a
// phone signed in to a business: the owner sees their own business as
// "Your store" with no way to order; staff order from their employer like any
// Shopper; the cloud's 'own_business' refusal reads clearly; and the shopper
// side only ever reaches the storefront_* / shopper_* RPCs.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/storefront/shopper_cart.dart';
import 'package:reebaplus_pos/core/storefront/shopper_models.dart';
import 'package:reebaplus_pos/core/storefront/shopper_session.dart';
import 'package:reebaplus_pos/core/storefront/storefront_providers.dart';
import 'package:reebaplus_pos/features/browse/screens/browse_screen.dart';
import 'package:reebaplus_pos/features/browse/screens/shopper_cart_screen.dart';
import 'package:reebaplus_pos/features/browse/screens/storefront_store_screen.dart';
import 'package:reebaplus_pos/features/browse/widgets/shopper_texts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shopper/shopper_fixtures.dart';
import 'browse_fixtures.dart';

Future<void> _tapKey(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

Future<void> _openSheet(WidgetTester tester, String name) async {
  await tester.tap(find.text(name).first);
  await tester.pumpAndSettle();
}

/// Browse from the till: a business phone whose sign-in is the Shopper login.
Future<({FakeStorefront storefront, FakeShopperBackend backend})> _pumpShop(
  WidgetTester tester, {
  required Set<String> ownStores,
  Widget screen = const BrowseScreen(fromTill: true),
  String? cartJson,
}) async {
  final storefront = FakeStorefront()..store = [_store9];
  final backend = FakeShopperBackend()..profile = Map.of(kProfileJson);
  await pumpShopper(
    tester,
    screen: screen,
    storefront: storefront,
    backend: backend,
    auth: FakeShopperAuth(email: 'emeka@stallion.ng'),
    deviceUserId: 'device-user-1',
    cartJson: cartJson,
    extraOverrides: [ownStoreIdsProvider.overrideWith((ref) => ownStores)],
  );
  return (storefront: storefront, backend: backend);
}

void main() {
  group('Browse from the till', () {
    testWidgets('titled Shop, back button, no Sell on Reebaplus', (
      tester,
    ) async {
      await _pumpShop(tester, ownStores: const {});
      expect(find.text('Shop'), findsOneWidget);
      expect(find.byKey(const Key('browse-back-to-till')), findsOneWidget);
      expect(find.byKey(const Key('browse-sell-on-reebaplus')), findsNothing);
    });

    testWidgets('the business sign-in is the Shopper login (no sign-out)', (
      tester,
    ) async {
      await _pumpShop(tester, ownStores: const {});
      final container = ProviderScope.containerOf(
        tester.element(find.byType(BrowseScreen)),
      );
      final session = container.read(shopperSessionProvider);
      expect(session.isSignedIn, isTrue);
      expect(session.isBusinessPhone, isTrue);
      expect(session.canSignOut, isFalse);
    });
  });

  group('owner', () {
    testWidgets('own products read "Your store"; other shops do not', (
      tester,
    ) async {
      await _pumpShop(tester, ownStores: const {'store-1'});
      // p1/p3/p4 are store-1 (own), p2 is store-2 (Keffi Drinks).
      expect(find.byKey(const ValueKey('browse-your-store-p1')), findsOneWidget);
      expect(find.byKey(const ValueKey('browse-your-store-p2')), findsNothing);
    });

    testWidgets('own product sheet: no Add to cart, no report, a clear note', (
      tester,
    ) async {
      await _pumpShop(tester, ownStores: const {'store-1'});
      await _openSheet(tester, 'Hero Lager');
      expect(find.byKey(const Key('browse-product-sheet')), findsOneWidget);
      expect(find.byKey(const Key('shopper-add-to-cart')), findsNothing);
      expect(find.byKey(const Key('browse-report-product')), findsNothing);
      expect(find.byKey(const Key('browse-your-store-note')), findsOneWidget);
      expect(
        find.text("You can't order from your own business."),
        findsOneWidget,
      );
    });

    testWidgets('another shop stays orderable for the owner', (tester) async {
      await _pumpShop(tester, ownStores: const {'store-1'});
      await _openSheet(tester, 'Eva Water 75cl');
      expect(find.byKey(const Key('shopper-add-to-cart')), findsOneWidget);
      expect(find.byKey(const Key('browse-your-store-note')), findsNothing);
    });

    testWidgets('own store page: "Your store" note, no report button', (
      tester,
    ) async {
      await _pumpShop(
        tester,
        ownStores: const {'store-9'},
        screen: const StorefrontStoreScreen(storeId: 'store-9'),
      );
      expect(find.byKey(const Key('store-your-store')), findsOneWidget);
      expect(find.byKey(const Key('browse-report-store')), findsNothing);
      expect(find.byKey(const Key('store-no-delivery')), findsNothing);
    });
  });

  group('staff', () {
    testWidgets('adds from their employer like any Shopper', (tester) async {
      final fakes = await _pumpShop(tester, ownStores: const {});
      expect(find.byKey(const ValueKey('browse-your-store-p4')), findsNothing);
      await _openSheet(tester, 'Hero Lager');
      await _tapKey(tester, const Key('shopper-add-to-cart'));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(BrowseScreen)),
      );
      final cart = container.read(shopperCartProvider).valueOrNull;
      expect(cart?.lineFor('store-1', 'p4')?.quantity, 1);

      // Gate: only the public storefront / shopper RPCs were reached.
      final names = [
        ...fakes.storefront.calls.map((c) => c.$1),
        ...fakes.backend.calls.map((c) => c.$1),
      ];
      expect(names, isNotEmpty);
      for (final name in names) {
        expect(
          name,
          matches(RegExp(r'^(storefront|shopper)_')),
          reason: 'the shopper side reached $name',
        );
      }
      await tester.pump(const Duration(seconds: 5)); // let the toast close
    });

    testWidgets('own store page for staff: no "Your store"', (tester) async {
      await _pumpShop(
        tester,
        ownStores: const {},
        screen: const StorefrontStoreScreen(storeId: 'store-9'),
      );
      expect(find.byKey(const Key('store-your-store')), findsNothing);
      expect(find.byKey(const Key('browse-report-store')), findsOneWidget);
    });
  });

  group("'own_business'", () {
    test('reads clearly', () {
      final text = placeOrderFailureText(PlaceOrderFailure.ownBusiness);
      expect(text, contains('your own store'));
      expect(text, contains("can't order from your own business"));
      expect(
        PlaceOrderFailure.fromWire('own_business'),
        PlaceOrderFailure.ownBusiness,
      );
    });

    testWidgets('a refused own-business order shows the message', (
      tester,
    ) async {
      final storefront = FakeStorefront()..store = [_store1Delivers];
      final backend = FakeShopperBackend()
        ..profile = Map.of(kProfileJson)
        ..failStores['store-1'] = 'own_business';
      await pumpShopper(
        tester,
        screen: const ShopperCartScreen(),
        storefront: storefront,
        backend: backend,
        auth: FakeShopperAuth(email: 'owner@stallion.ng'),
        deviceUserId: 'device-user-1',
        cartJson: twoShopCartJson(),
        extraOverrides: [
          ownStoreIdsProvider.overrideWith((ref) => const <String>{}),
        ],
      );
      await _tapKey(tester, const Key('shopper-cart-place-order'));
      await _tapKey(tester, const Key('shopper-place-orders'));
      expect(find.textContaining('This is your own store'), findsOneWidget);
      expect(find.text('Reference ON-1'), findsOneWidget); // store-2 placed
    });
  });

  group('ownStoreIdsFor', () {
    test('the owner gets their stores', () {
      expect(
        ownStoreIdsFor(authUserId: 'a', ownerId: 'a', storeIds: ['s1', 's2']),
        {'s1', 's2'},
      );
    });

    test('staff (not the owner) get nothing', () {
      expect(
        ownStoreIdsFor(authUserId: 'b', ownerId: 'a', storeIds: ['s1']),
        isEmpty,
      );
    });

    test('unknown owner or login gets nothing', () {
      expect(
        ownStoreIdsFor(authUserId: null, ownerId: 'a', storeIds: ['s1']),
        isEmpty,
      );
      expect(
        ownStoreIdsFor(authUserId: 'a', ownerId: null, storeIds: ['s1']),
        isEmpty,
      );
    });
  });
}

const _store9 = <String, Object?>{
  'store_id': 'store-9',
  'business_name': 'Stallion Global',
  'logo_url': null,
  'store_state': 'Nasarawa',
  'store_lga': 'Keffi',
  'online_note': null,
  'currency': 'NGN',
  'delivers_to_area': false,
  'stock_may_be_stale': false,
};

const _store1Delivers = <String, Object?>{
  'store_id': 'store-1',
  'business_name': 'Stallion Global',
  'logo_url': null,
  'store_state': 'Nasarawa',
  'store_lga': 'Keffi',
  'online_note': null,
  'currency': 'NGN',
  'delivers_to_area': true,
  'stock_may_be_stale': false,
};
