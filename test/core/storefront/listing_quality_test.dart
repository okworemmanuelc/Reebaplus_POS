import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/storefront/listing_quality.dart';

void main() {
  group('listingGaps', () {
    List<ListingGap> gaps({
      bool photo = true,
      String? category = 'Drinks',
      String? description = 'Cold',
      bool stock = true,
    }) => listingGaps(
      hasPhoto: photo,
      marketplaceCategory: category,
      onlineDescription: description,
      inStockOnline: stock,
    );

    test('a complete listing has no gaps', () => expect(gaps(), isEmpty));

    test('each missing thing is its own gap, in checklist order', () {
      expect(
        gaps(photo: false, category: null, description: null, stock: false),
        ListingGap.values,
      );
      expect(gaps(photo: false), [ListingGap.photo]);
      expect(gaps(stock: false), [ListingGap.onlineStock]);
    });

    test('blank text counts as missing', () {
      expect(gaps(category: '  '), [ListingGap.marketplaceCategory]);
      expect(gaps(description: ''), [ListingGap.description]);
    });
  });

  group('summariseStoreGaps', () {
    ListingFacts f(String id, {bool p = true, bool c = true, bool d = true}) =>
        ListingFacts(
          productId: id,
          hasPhoto: p,
          hasMarketplaceCategory: c,
          hasDescription: d,
        );

    test('clear when nothing is missing', () {
      final s = summariseStoreGaps([f('a'), f('b')]);
      expect(s.isClear, isTrue);
      expect(s.lines, isEmpty);
      expect(s.firstProductId, isNull);
    });

    test('counts each gap and the products with any gap', () {
      final s = summariseStoreGaps([
        f('a'),
        f('b', p: false),
        f('c', p: false, d: false),
        f('d', c: false),
      ]);
      expect(s.missingPhoto, 2);
      expect(s.missingCategory, 1);
      expect(s.missingDescription, 1);
      expect(s.withGaps, 3);
      expect(s.firstProductId, 'b');
      expect(s.lines, [
        '2 products missing a photo',
        '1 product missing a marketplace category',
        '1 product missing an online description',
      ]);
    });
  });
}
