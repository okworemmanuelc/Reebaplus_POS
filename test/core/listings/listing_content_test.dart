// #473: the online order-quantity rule and the listing box parser.
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/listings/listing_content.dart';

void main() {
  group('OrderQuantityRule', () {
    test('default allows any whole amount from 1', () {
      const rule = OrderQuantityRule();
      expect(rule.isDefault, isTrue);
      expect([0, 1, 7, 500].map(rule.allows), [false, true, true, true]);
      expect(rule.smallestAllowed, 1);
    });

    test('step 12 means whole crates only, even when min is 1', () {
      const rule = OrderQuantityRule(step: 12);
      expect([1, 11, 12, 13, 24].map(rule.allows),
          [false, false, true, false, true]);
      expect(rule.smallestAllowed, 12);
      expect(rule.allowedAtOrAbove(13), 24);
    });

    test('min and max bound the steps', () {
      const rule = OrderQuantityRule(min: 6, step: 6, max: 18);
      expect([0, 6, 12, 18, 24].map(rule.allows),
          [false, true, true, true, false]);
      expect(rule.allowedAtOrAbove(1), 6);
      expect(rule.allowedAtOrAbove(19), isNull);
    });

    test('a max under the first step leaves nothing to order', () {
      expect(const OrderQuantityRule(min: 1, step: 12, max: 10).smallestAllowed,
          isNull);
    });
  });

  group('parseListingContent', () {
    ListingParse parse({
      String d = '',
      String b = '',
      String min = '',
      String step = '',
      String max = '',
    }) => parseListingContent(
      description: d, brand: b, minOrder: min, orderStep: step, maxOrder: max);

    test('blank boxes mean no text and no limits', () {
      expect(parse().content, const ListingContent());
    });

    test('trims text and reads the limits', () {
      final c = parse(d: '  Cold  ', b: ' Nestlé ', min: '2', step: '2', max: '10')
          .content!;
      expect(c, const ListingContent(onlineDescription: 'Cold', brand: 'Nestlé',
          minOrderQty: 2, orderStep: 2, maxOrderQty: 10));
    });

    test('refuses overlong text, zero limits and impossible ranges', () {
      expect(parse(d: 'x' * 2001).field, ListingField.description);
      expect(parse(d: 'x' * 2000).isValid, isTrue);
      expect(parse(b: 'x' * 61).field, ListingField.brand);
      expect(parse(min: '0').field, ListingField.minOrder);
      expect(parse(step: '0').field, ListingField.orderStep);
      expect(parse(min: '5', max: '4').field, ListingField.maxOrder);
      expect(parse(step: '12', max: '10').field, ListingField.maxOrder);
    });
  });
}
