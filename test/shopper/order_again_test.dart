// #436 Order again: today's prices, skipped lines, the 18+ gate, qty clamp.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/storefront/order_again.dart';
import 'package:reebaplus_pos/core/storefront/shopper_cart.dart';
import 'package:reebaplus_pos/core/storefront/storefront_models.dart';
import 'package:reebaplus_pos/features/browse/screens/my_orders_screen.dart';
import 'package:reebaplus_pos/features/browse/widgets/age_confirmation_dialog.dart';

import '../browse/browse_fixtures.dart';
import 'shopper_fixtures.dart';

Map<String, Object?> _line(String id, String name, int qty) => {
  'product_id': id,
  'name': name,
  'unit_price_kobo': 100000, // the OLD price
  'requested_qty': qty,
  'accepted_qty': null,
};

FakeShopperBackend _backendWith(List<Map<String, Object?>> lines) =>
    FakeShopperBackend()
      ..orders.add({
        'id': 'o1',
        'store_id': 'store-1',
        'business_name': 'Stallion Global',
        'store_lga': 'Nasarawa',
        'reference': 'ON-AAA',
        'status': 'accepted',
        'currency': 'NGN',
        'total_kobo': 100,
        'placed_at': '2026-10-24T09:00:00Z',
        'lines': lines,
      });

Future<void> _tapAgain(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('my-order-again-o1')));
  await tester.pumpAndSettle();
}

ShopperCart _cartOf(WidgetTester t) => ProviderScope.containerOf(
  t.element(find.byType(MyOrdersScreen)),
).read(shopperCartProvider).requireValue;

void main() {
  testWidgets("adds the items at today's price and stock label", (t) async {
    final storefront = FakeStorefront()
      ..storeProducts = [
        cardRow(id: 'p4', name: 'Hero Lager', price: 380000, stock: 'low_stock'),
      ];
    await pumpShopper(t,
        screen: const MyOrdersScreen(),
        backend: _backendWith([_line('p4', 'Hero Lager', 3)]),
        storefront: storefront,
        auth: FakeShopperAuth(email: 'ada@example.com'));
    await _tapAgain(t);
    expect(find.textContaining('Added to your cart'), findsOneWidget);
    final line = _cartOf(t).lines.single;
    expect(line.priceKobo, 380000, reason: 'today, not the 100000 paid before');
    expect(line.quantity, 3);
    expect(storefront.calls.last.$1, 'storefront_store_products');
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('skips an unavailable item with the note', (t) async {
    final storefront = FakeStorefront()
      ..storeProducts = [
        cardRow(id: 'p4', name: 'Hero Lager'),
        cardRow(id: 'p5', name: 'Star Radler', stock: 'out_of_stock'),
      ];
    await pumpShopper(t,
        screen: const MyOrdersScreen(),
        backend: _backendWith([
          _line('p4', 'Hero Lager', 1),
          _line('p5', 'Star Radler', 1),
          _line('gone', 'Hidden Thing', 1),
        ]),
        storefront: storefront,
        auth: FakeShopperAuth(email: 'ada@example.com'));
    await _tapAgain(t);
    expect(
      find.textContaining('2 items are no longer available and were skipped'),
      findsOneWidget,
    );
    expect(_cartOf(t).lines.map((l) => l.productId), ['p4']);
    await t.pump(const Duration(seconds: 5));
  });

  group('the 18+ gate', () {
    final rows = [
      cardRow(id: 'p1', name: 'Star Lager', age: true),
      cardRow(id: 'p4', name: 'Hero Lager'),
    ];

    testWidgets('Not now skips the 18+ items only', (t) async {
      await pumpShopper(t,
          screen: const MyOrdersScreen(),
          backend: _backendWith([
            _line('p1', 'Star Lager', 2),
            _line('p4', 'Hero Lager', 1),
          ]),
          storefront: FakeStorefront()..storeProducts = rows,
          auth: FakeShopperAuth(email: 'ada@example.com'));
      await _tapAgain(t);
      expect(find.text(AgeConfirmationDialog.title), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('age-decline')));
      await t.pumpAndSettle();
      expect(_cartOf(t).lines.map((l) => l.productId), ['p4']);
      expect(find.textContaining('1 item is no longer available'),
          findsOneWidget);
      await t.pump(const Duration(seconds: 5));
    });

    testWidgets('confirming adds them', (t) async {
      await pumpShopper(t,
          screen: const MyOrdersScreen(),
          backend: _backendWith([_line('p1', 'Star Lager', 2)]),
          storefront: FakeStorefront()..storeProducts = rows,
          auth: FakeShopperAuth(email: 'ada@example.com'));
      await _tapAgain(t);
      await t.tap(find.byKey(const ValueKey('age-confirm')));
      await t.pumpAndSettle();
      expect(_cartOf(t).lines.map((l) => l.productId), ['p1']);
      await t.pump(const Duration(seconds: 5));
    });
  });

  group('quantity clamp', () {
    StorefrontCard card({int min = 1, int step = 1, int? max, int? left}) =>
        StorefrontCard.fromRow(cardRow(
          id: 'p', name: 'X', minQty: min, step: step, maxQty: max,
          stock: left == null ? 'in_stock' : 'only_few_left', onlyLeft: left));

    test('raises to min, snaps to step, caps at max and "only left"', () {
      expect(clampOrderAgainQuantity(card(min: 4), 1), 4);
      expect(clampOrderAgainQuantity(card(min: 2, step: 2), 7), 6);
      expect(clampOrderAgainQuantity(card(max: 5), 9), 5);
      expect(clampOrderAgainQuantity(card(min: 2, step: 2, max: 10), 9), 8);
      expect(clampOrderAgainQuantity(card(left: 2), 5), 2);
      expect(clampOrderAgainQuantity(card(), 3), 3);
    });

    test('null when no allowed quantity is left', () {
      expect(clampOrderAgainQuantity(card(min: 4, left: 2), 4), isNull);
      expect(clampOrderAgainQuantity(card(min: 6, step: 4, max: 7), 6), isNull);
    });

    testWidgets('the cart gets the clamped quantity', (t) async {
      await pumpShopper(t,
          screen: const MyOrdersScreen(),
          backend: _backendWith([_line('p4', 'Hero Lager', 7)]),
          storefront: FakeStorefront()
            ..storeProducts = [
              cardRow(id: 'p4', name: 'Hero Lager', minQty: 2, step: 2, maxQty: 4),
            ],
          auth: FakeShopperAuth(email: 'ada@example.com'));
      await _tapAgain(t);
      expect(_cartOf(t).lines.single.quantity, 4);
      await t.pump(const Duration(seconds: 5));
    });
  });
}
