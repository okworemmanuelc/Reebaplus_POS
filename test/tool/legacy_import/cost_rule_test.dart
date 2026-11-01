import 'package:flutter_test/flutter_test.dart';

import '../../../tool/legacy_import/src/cost_rule.dart';

void main() {
  final day1 = DateTime.utc(2026, 1, 1);
  final day5 = DateTime.utc(2026, 1, 5);
  final day9 = DateTime.utc(2026, 1, 9);

  DeliveryPrice delivery(
    DateTime at,
    int kobo, {
    String product = 'p1',
    bool cancelled = false,
  }) => DeliveryPrice(
    productId: product,
    deliveredAt: at,
    unitKobo: kobo,
    isCancelled: cancelled,
  );

  LineCost cost(CostRule rule, DateTime soldAt, {int sale = 500}) => rule
      .costFor(productId: 'p1', soldAt: soldAt, saleUnitKobo: sale);

  group('CostRule', () {
    test('A: the most recent delivery on or before the sale', () {
      final rule = CostRule([delivery(day1, 100), delivery(day5, 200)]);

      final result = cost(rule, day9);

      expect(result.unitKobo, 200);
      expect(result.group, CostGroup.a);
    });

    test('A: a delivery at the exact sale time counts', () {
      final rule = CostRule([delivery(day1, 100), delivery(day5, 200)]);

      expect(cost(rule, day5).unitKobo, 200);
    });

    test('A: ignores a later delivery', () {
      final rule = CostRule([delivery(day1, 100), delivery(day9, 300)]);

      expect(cost(rule, day5).unitKobo, 100);
    });

    test('B: sold before the first delivery takes the first price', () {
      final rule = CostRule([delivery(day5, 200), delivery(day9, 300)]);

      final result = cost(rule, day1);

      expect(result.unitKobo, 200);
      expect(result.group, CostGroup.b);
    });

    test('C: never delivered costs the sale price, so zero profit', () {
      final rule = CostRule([delivery(day1, 100, product: 'other')]);

      final result = cost(rule, day5, sale: 750);

      expect(result.unitKobo, 750);
      expect(result.group, CostGroup.c);
    });

    test('free deliveries set no price', () {
      final rule = CostRule([delivery(day1, 100), delivery(day5, 0)]);

      expect(cost(rule, day9).unitKobo, 100);
    });

    test('only free deliveries means never delivered', () {
      final rule = CostRule([delivery(day1, 0)]);

      expect(cost(rule, day5).group, CostGroup.c);
    });

    test('cancelled deliveries set no price', () {
      final rule = CostRule([
        delivery(day1, 100),
        delivery(day5, 999, cancelled: true),
      ]);

      expect(cost(rule, day9).unitKobo, 100);
    });

    test('deliveries are sorted by date, whatever order they arrive in', () {
      final rule = CostRule([delivery(day5, 200), delivery(day1, 100)]);

      expect(cost(rule, day9).unitKobo, 200);
    });

    test('a free line of a never-delivered product is the only zero cost', () {
      final rule = CostRule(const []);

      expect(cost(rule, day5, sale: 0).unitKobo, 0);
    });
  });
}
