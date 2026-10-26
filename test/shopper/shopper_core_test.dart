// #426: the Shopper cart, service and session (no widgets).

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/storefront/shopper_cart.dart';
import 'package:reebaplus_pos/core/storefront/shopper_models.dart';
import 'package:reebaplus_pos/core/storefront/shopper_service.dart';
import 'package:reebaplus_pos/core/storefront/shopper_session.dart';
import 'package:reebaplus_pos/core/storefront/storefront_models.dart';

import '../browse/browse_fixtures.dart';
import 'shopper_fixtures.dart';

StorefrontCard card(int i) => StorefrontCard.fromRow(kFeedRows[i]);

ProviderContainer container({
  FakeShopperAuth? auth,
  FakePush? push,
  String? deviceUserId,
}) {
  final c = ProviderContainer(
    overrides: [
      shopperAuthPortProvider.overrideWithValue(auth ?? FakeShopperAuth()),
      pushNotificationServiceProvider.overrideWithValue(push ?? FakePush()),
      deviceUserIdProvider
          .overrideWith((ref) => ValueNotifier<String?>(deviceUserId)),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('cart (#426)', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('holds several shops, per-shop subtotals, survives a restart', () async {
      final c = container();
      final cart = c.read(shopperCartProvider.notifier);
      await c.read(shopperCartProvider.future);
      expect(await cart.add(card(0), 2), isNull); // Star Lager, store-1
      expect(await cart.add(card(1), 3), isNull); // Eva Water, store-2
      final groups = c.read(shopperCartProvider).requireValue.groups;
      expect(groups.map((g) => g.storeId), ['store-1', 'store-2']);
      expect(groups[0].subtotalKobo, 900000);
      expect(groups[1].subtotalKobo, 360000);

      // A new app run reads the same cart back from the phone.
      final restarted = container();
      final again = await restarted.read(shopperCartProvider.future);
      expect(again.lineCount, 2);
      expect(again.lineFor('store-2', 'p2')!.quantity, 3);
    });

    test('obeys min / step / max (#473) and a shown "Only N left"', () async {
      final c = container();
      final cart = c.read(shopperCartProvider.notifier);
      await c.read(shopperCartProvider.future);
      // Star Lager: at least 2, steps of 2, up to 20.
      expect(await cart.add(card(0), 1), 'Order at least 2, in steps of 2, up to 20');
      expect(await cart.add(card(0), 2), isNull);
      expect(await cart.setQuantity('store-1', 'p1', 3), isNotNull);
      expect(await cart.setQuantity('store-1', 'p1', 22), isNotNull);
      expect(await cart.setQuantity('store-1', 'p1', 20), isNull);
      // Coca-Cola shows "Only 2 left": 3 is refused without a count.
      expect(await cart.add(card(2), 3), kStoreCannotSupplyMessage);
      expect(await cart.add(card(2), 2), isNull);
    });

    test('placed shops leave the cart; the others stay', () async {
      final c = container();
      final cart = c.read(shopperCartProvider.notifier);
      await c.read(shopperCartProvider.future);
      await cart.add(card(0), 2);
      await cart.add(card(1), 1);
      await cart.removeStores({'store-1'});
      final left = c.read(shopperCartProvider).requireValue;
      expect(left.groups.single.storeId, 'store-2');
    });

    test('a corrupt saved cart starts empty', () async {
      SharedPreferences.setMockInitialValues({
        ShopperCartNotifier.prefKey: '{not json',
      });
      expect((await container().read(shopperCartProvider.future)).isEmpty, isTrue);
      SharedPreferences.setMockInitialValues({
        ShopperCartNotifier.prefKey: jsonEncode([{'storeId': 1}]),
      });
      expect((await container().read(shopperCartProvider.future)).isEmpty, isTrue);
    });
  });

  group('service (#426)', () {
    test('place sends one order per shop with client ids; parses results', () async {
      SharedPreferences.setMockInitialValues({
        ShopperCartNotifier.prefKey: twoShopCartJson(),
      });
      final backend = FakeShopperBackend()..failStores['store-2'] = 'not_enough_stock';
      final groups = (await container().read(shopperCartProvider.future)).groups;
      final results = await backend.service.placeOrders(
        groups: groups,
        orderIds: {'store-1': 'o1', 'store-2': 'o2'},
        phone: ' 0803 ',
        address: const ShopperAddress(state: 'Nasarawa', lga: 'Keffi', street: '1 Road'),
        note: '  ',
      );
      final params = backend.calls.single.$2;
      final orders = params['p_orders']! as List;
      expect(orders, hasLength(2));
      expect((orders[0] as Map)['id'], 'o1');
      expect((orders[0] as Map)['lines'], [
        {'product_id': 'p1', 'quantity': 2},
      ]);
      // No client price is ever sent.
      expect(jsonEncode(params), isNot(contains('price')));
      expect(params['p_note'], isNull);
      expect(params['p_phone'], '0803');
      expect(results[0].isPlaced, isTrue);
      expect(results[0].reference, 'ON-1');
      expect(results[1].failure, PlaceOrderFailure.notEnoughStock);
    });

    test('cancel after the shop answered is a clear failure', () async {
      final backend = FakeShopperBackend();
      backend.orders.add({'id': 'o1', 'status': 'accepted'});
      await expectLater(
        backend.service.cancelOrder('o1'),
        throwsA(isA<ShopperException>().having(
            (e) => e.failure, 'failure', ShopperFailure.notCancellable)),
      );
    });

    test('My Orders statuses read in plain words', () {
      ShopperOrder order(String status, {int? accepted}) => ShopperOrder.fromRow({
        'id': 'o', 'store_id': 's', 'business_name': 'B', 'reference': 'R',
        'status': status, 'currency': 'NGN', 'total_kobo': 1,
        'placed_at': '2026-10-25T09:00:00Z',
        'lines': [
          {'product_id': 'p', 'name': 'X', 'unit_price_kobo': 1,
           'requested_qty': 4, 'accepted_qty': accepted},
        ],
      });
      expect(order('new').statusText, 'Placed');
      expect(order('new').canCancel, isTrue);
      expect(order('accepted', accepted: 4).statusText, 'Accepted');
      expect(order('accepted', accepted: 2).statusText, 'Changed');
      expect(order('accepted').canCancel, isFalse);
      expect(order('declined').statusText, 'Declined');
      expect(order('cancelled_by_customer').statusText, 'Cancelled');
      expect(order('fulfilled').statusText, 'Sent out');
      expect(order('expired').statusText, "The shop didn't respond");
    });
  });

  group('session (#426, ADR 0030)', () {
    test('email + code signs in and registers the Shopper push token', () async {
      final auth = FakeShopperAuth();
      final push = FakePush();
      final c = container(auth: auth, push: push);
      final session = c.read(shopperSessionProvider.notifier);
      expect(await session.sendCode(' Ada@Example.com '), isNull);
      expect(auth.sent.single, 'ada@example.com');
      expect(await session.verifyCode('ada@example.com', '000000'), isNotNull);
      expect(c.read(shopperSessionProvider).isSignedIn, isFalse);
      expect(await session.verifyCode('ada@example.com', '123456'), isNull);
      expect(c.read(shopperSessionProvider).email, 'ada@example.com');
      await Future<void>.delayed(Duration.zero);
      expect(push.signedIn, 1);
    });

    test('sign-out is plain: auth sign-out only, no wipe gate, cart kept', () async {
      SharedPreferences.setMockInitialValues({
        ShopperCartNotifier.prefKey: twoShopCartJson(),
      });
      final auth = FakeShopperAuth(email: 'ada@example.com');
      final push = FakePush();
      final c = container(auth: auth, push: push);
      // No database or AuthService is reachable from this container: a wipe
      // (clearAllData / logOutCurrentUser) would throw here.
      await c.read(shopperSessionProvider.notifier).signOut();
      expect(auth.signOuts, 1);
      expect(push.signedOut, 1);
      expect(c.read(shopperSessionProvider).isSignedIn, isFalse);
      expect((await c.read(shopperCartProvider.future)).lineCount, 2);
    });

    test('a business phone keeps its session: no Shopper OTP, no sign-out', () async {
      final auth = FakeShopperAuth(email: 'owner@shop.com');
      final c = container(auth: auth, deviceUserId: 'user-1');
      final state = c.read(shopperSessionProvider);
      expect(state.isBusinessPhone, isTrue);
      expect(state.canSignOut, isFalse);
      expect(await c.read(shopperSessionProvider.notifier).sendCode('x@y.com'),
          isNotNull);
      expect(auth.sent, isEmpty);
      await c.read(shopperSessionProvider.notifier).signOut();
      expect(auth.signOuts, 0);
      expect(auth.email, 'owner@shop.com');
    });
  });
}
