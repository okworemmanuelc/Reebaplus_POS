// #732 — the pure rule for which lines a return consumes.

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/orders/sale_return_allocation.dart';

ReturnableLine line(
  String id, {
  String? product = 'p',
  double sold = 1,
  double returned = 0,
  DateTime? addedAt,
  int price = 100000,
  int cost = 60000,
}) => ReturnableLine(
  lineId: id,
  productId: product,
  storeId: 's',
  sold: sold,
  returned: returned,
  unitPriceKobo: price,
  buyingPriceKobo: cost,
  addedAt: addedAt,
);

void main() {
  final day1 = DateTime(2026, 11, 1);
  final day2 = DateTime(2026, 11, 2);

  group('groupReturnableLines', () {
    test('a product is one row: originals first, then oldest edit first', () {
      final groups = groupReturnableLines([
        line('z-newer', addedAt: day2),
        line('a-older', addedAt: day1),
        line('m-original'),
      ]);
      expect(groups.length, 1);
      expect(groups.single.lines.map((l) => l.lineId), [
        'm-original',
        'a-older',
        'z-newer',
      ]);
      expect(groups.single.lineId, 'm-original');
    });

    test('same-day edits fall back to the line id, so phones agree', () {
      final groups = groupReturnableLines([
        line('b', addedAt: day1),
        line('a', addedAt: day1),
      ]);
      expect(groups.single.lines.map((l) => l.lineId), ['a', 'b']);
    });

    test('different products and Quick Sale lines stay apart', () {
      final groups = groupReturnableLines([
        line('1', product: null),
        line('2', product: null),
        line('3'),
        line('4', product: 'other'),
      ]);
      expect(groups.length, 4);
    });

    test('a product only an edit added is its own row, keyed by its line', () {
      final groups = groupReturnableLines([
        line('orig'),
        line('new', product: 'other', addedAt: day1),
      ]);
      expect(groups.map((g) => g.lineId), ['orig', 'new']);
    });
  });

  group('allocateReturn', () {
    ReturnableGoods goods() => groupReturnableLines([
      line('orig', sold: 10),
      line('first-edit', sold: 2, addedAt: day1, price: 120000, cost: 70000),
      line('second-edit', sold: 3, addedAt: day2, price: 130000, cost: 75000),
    ]).single;

    test('stays on the original line while it lasts', () {
      expect(allocateReturn(goods(), 4), {'orig': 4});
    });

    test('spills to the oldest edit, then the next', () {
      expect(allocateReturn(goods(), 11), {'orig': 10, 'first-edit': 1});
      expect(allocateReturn(goods(), 14), {
        'orig': 10,
        'first-edit': 2,
        'second-edit': 2,
      });
    });

    test('skips what earlier returns already took', () {
      final g = groupReturnableLines([
        line('orig', sold: 10, returned: 10),
        line('first-edit', sold: 2, returned: 1, addedAt: day1),
        line('second-edit', sold: 3, addedAt: day2),
      ]).single;
      expect(g.standing, 4);
      expect(allocateReturn(g, 2), {'first-edit': 1, 'second-edit': 1});
    });

    test('quarter units allocate exactly', () {
      final g = groupReturnableLines([
        line('orig', sold: 1.5),
        line('added', sold: 1, addedAt: day1),
      ]).single;
      expect(allocateReturn(g, 1.75), {'orig': 1.5, 'added': 0.25});
    });

    test('more than stands is an error, the caller refuses first', () {
      expect(() => allocateReturn(goods(), 16), throwsArgumentError);
    });
  });

  group('allocateDamaged', () {
    test('follows the consumed lines in the same order', () {
      final g = groupReturnableLines([
        line('orig', sold: 2),
        line('added', sold: 2, addedAt: day1),
      ]).single;
      final allocated = allocateReturn(g, 3);
      expect(allocateDamaged(g, allocated, 1), {'orig': 1});
      expect(allocateDamaged(g, allocated, 3), {'orig': 2, 'added': 1});
    });
  });

  group('saleHasAdjustments', () {
    test('false for an untouched sale', () {
      expect(saleHasAdjustments(groupReturnableLines([line('a')])), isFalse);
    });

    test('true once anything was returned or added', () {
      expect(
        saleHasAdjustments(
          groupReturnableLines([line('a', sold: 2, returned: 1)]),
        ),
        isTrue,
      );
      expect(
        saleHasAdjustments(groupReturnableLines([line('a', addedAt: day1)])),
        isTrue,
      );
    });
  });
}
