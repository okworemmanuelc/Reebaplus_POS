// #428: the Shopper's view of an accepted / changed / shop-cancelled order.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/storefront/shopper_models.dart';
import 'package:reebaplus_pos/features/browse/screens/my_orders_screen.dart';

import 'shopper_fixtures.dart';

Map<String, Object?> _order(String status, {String? phone, String? cancel}) => {
  'id': 'o1',
  'store_id': 'store-1',
  'business_name': 'Stallion Global',
  'store_lga': 'Nasarawa',
  'store_phone': phone,
  'reference': 'ON-AAA',
  'status': status,
  'currency': 'NGN',
  'total_kobo': 1000000,
  'placed_at': '2026-10-24T09:00:00Z',
  'cancel_reason': cancel,
  'lines': [
    {
      'product_id': 'p1',
      'name': 'Star Lager',
      'unit_price_kobo': 100000,
      'requested_qty': 4,
      'accepted_qty': 3,
    },
    {
      'product_id': 'p2',
      'name': 'Malt',
      'unit_price_kobo': 200000,
      'requested_qty': 3,
      'accepted_qty': 0,
    },
  ],
};

void main() {
  test('model: changed lines, accepted total, store phone', () {
    final o = ShopperOrder.fromRow(_order('accepted', phone: '0803'));
    expect(o.statusText, 'Changed');
    expect(o.lines.map((l) => l.isChanged), [true, true]);
    expect(o.displayTotalKobo, 300000); // 3 x 1000, malt removed
    expect(o.storePhone, '0803');
    expect(ShopperOrder.fromRow(_order('placed')).displayTotalKobo, 1000000);
  });

  testWidgets('accepted: changed lines, store phone, no cancel action', (t) async {
    await pumpShopper(t,
        screen: const MyOrdersScreen(),
        backend: FakeShopperBackend()..orders.add(_order('accepted', phone: '0803 000 1111')),
        auth: FakeShopperAuth(email: 'ada@example.com'));
    expect(find.text('3 × Star Lager (you asked for 4)'), findsOneWidget);
    expect(find.text('0 × Malt (you asked for 3)'), findsOneWidget);
    expect(find.byKey(const ValueKey('my-order-phone-o1')), findsOneWidget);
    expect(find.textContaining('0803 000 1111'), findsOneWidget);
    expect(find.byKey(const ValueKey('my-order-cancel-o1')), findsNothing);
  });

  testWidgets('accepted without a store phone shows no phone line', (t) async {
    await pumpShopper(t,
        screen: const MyOrdersScreen(),
        backend: FakeShopperBackend()..orders.add(_order('accepted')),
        auth: FakeShopperAuth(email: 'ada@example.com'));
    expect(find.byKey(const ValueKey('my-order-phone-o1')), findsNothing);
  });

  testWidgets('cancelled by the shop: the reason is shown', (t) async {
    await pumpShopper(t,
        screen: const MyOrdersScreen(),
        backend: FakeShopperBackend()
          ..orders.add(_order('cancelled_by_shop', phone: '0803', cancel: 'Van broke down')),
        auth: FakeShopperAuth(email: 'ada@example.com'));
    expect(find.text('Cancelled by the shop'), findsOneWidget);
    expect(find.text('Reason: Van broke down'), findsOneWidget);
    expect(find.byKey(const ValueKey('my-order-cancel-o1')), findsNothing);
    expect(find.byKey(const ValueKey('my-order-phone-o1')), findsNothing);
  });
}
