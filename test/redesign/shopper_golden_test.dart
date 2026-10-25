// Visual goldens for the Shopper screens (#426): cart, place order, My Orders
// and sign-in at 390x844 (light) and 844x390 (dark, 24dp status bar + 48dp
// side inset). No Claude Design files exist in the repo for these screens;
// they follow ui-context tokens and Browse's shared parts.
//
//     flutter test --update-goldens test/redesign/shopper_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/storefront/shopper_models.dart';
import 'package:reebaplus_pos/features/browse/screens/my_orders_screen.dart';
import 'package:reebaplus_pos/features/browse/screens/place_order_screen.dart';
import 'package:reebaplus_pos/features/browse/screens/shopper_cart_screen.dart';
import 'package:reebaplus_pos/features/browse/screens/shopper_sign_in_screen.dart';

import '../browse/browse_fixtures.dart';
import '../shopper/shopper_fixtures.dart';

void main() {
  const sizes = <String, (Size, EdgeInsets, Brightness)>{
    '390x844': (Size(390, 844), EdgeInsets.zero, Brightness.light),
    '844x390': (Size(844, 390), EdgeInsets.only(top: 24, right: 48), Brightness.dark),
  };

  FakeShopperBackend ordersBackend() => FakeShopperBackend()
    ..orders.addAll([
      {'id': 'o1', 'store_id': 'store-1', 'business_name': 'Stallion Global',
       'store_lga': 'Nasarawa', 'reference': 'ON-3F9A2C1B', 'status': 'new',
       'currency': 'NGN', 'total_kobo': 900000, 'placed_at': '2026-10-25T09:00:00Z',
       'lines': [
         {'product_id': 'p1', 'name': 'Star Lager', 'unit_price_kobo': 450000,
          'requested_qty': 2, 'accepted_qty': null},
       ]},
      {'id': 'o2', 'store_id': 'store-2', 'business_name': 'Keffi Drinks',
       'store_lga': 'Keffi', 'reference': 'ON-77D01E4A', 'status': 'accepted',
       'currency': 'NGN', 'total_kobo': 360000, 'placed_at': '2026-10-24T09:00:00Z',
       'lines': [
         {'product_id': 'p2', 'name': 'Eva Water 75cl', 'unit_price_kobo': 120000,
          'requested_qty': 4, 'accepted_qty': 3},
       ]},
    ]);

  final screens = <String, (Widget, FakeShopperBackend Function(), FakeStorefront Function())>{
    'cart': (const ShopperCartScreen(), FakeShopperBackend.new, FakeStorefront.new),
    'place_order': (
      PlaceOrderScreen(profile: ShopperProfile.fromJson(kProfileJson)),
      FakeShopperBackend.new,
      FakeStorefront.new, // store-9 header: flags "doesn't deliver"
    ),
    'my_orders': (const MyOrdersScreen(), ordersBackend, FakeStorefront.new),
    'sign_in': (const ShopperSignInScreen(), FakeShopperBackend.new, FakeStorefront.new),
  };

  for (final screen in screens.entries) {
    for (final size in sizes.entries) {
      final name = 'shopper_${screen.key}_${size.key}_${size.value.$3.name}';
      testWidgets(name, (tester) async {
        await pumpShopper(
          tester,
          screen: screen.value.$1,
          backend: screen.value.$2(),
          storefront: screen.value.$3(),
          auth: FakeShopperAuth(
            email: screen.key == 'sign_in' ? null : 'ada@example.com'),
          cartJson: twoShopCartJson(),
          size: size.value.$1,
          padding: size.value.$2,
          brightness: size.value.$3,
        );
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/$name.png'),
        );
      });
    }
  }
}
