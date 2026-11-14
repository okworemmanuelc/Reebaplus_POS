import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/tab_url_memory.dart';

void main() {
  group('tab name <-> index', () {
    test('fragmentForTab gives a route path', () {
      expect(fragmentForTab(3), '/orders');
    });
    test('every tab round-trips through its fragment', () {
      for (final e in NavigationService.indexToRoute.entries) {
        expect(tabIndexFromFragment(fragmentForTab(e.key)), e.key);
      }
    });
    test('accepts #/orders, /orders, orders, trailing slash, case', () {
      for (final f in [
        '#/orders',
        '/orders',
        'orders',
        '#/orders/',
        '#/ORDERS',
      ]) {
        expect(tabIndexFromFragment(f), 3, reason: f);
      }
    });
    test('empty, unknown, null give null', () {
      for (final f in [null, '', '#', '#/', '#/nope', '#/orders/123']) {
        expect(tabIndexFromFragment(f), isNull, reason: '$f');
      }
    });
    test('fragmentForTab of an unknown index is null', () {
      expect(fragmentForTab(42), isNull);
    });
  });

  group('resolveStartTab', () {
    test('saved allowed tab wins over the role landing', () {
      expect(
        resolveStartTab(saved: 3, roleLanding: 1, isAllowed: (_) => true),
        3,
      );
    });
    test('saved tab not allowed falls back to the landing', () {
      expect(
        resolveStartTab(saved: 6, roleLanding: 0, isAllowed: (t) => t != 6),
        0,
      );
    });
    test('nothing saved uses the landing', () {
      expect(
        resolveStartTab(saved: null, roleLanding: 1, isAllowed: (_) => true),
        1,
      );
    });
  });
}
