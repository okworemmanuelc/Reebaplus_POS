import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/data/marketplace_categories.dart';
import 'package:reebaplus_pos/core/industry/industry.dart';
import 'package:reebaplus_pos/core/industry/lexicon.dart';

void main() {
  test('bundled public catalogue exactly matches SQL seed, including metadata', () {
    final sql = File('supabase/migrations/0190_marketplace_categories.sql')
        .readAsStringSync();
    final rows = RegExp(r"\('([^']+)', '([^']+)', (NULL|'[^']+'), (\d+), (NULL|'[^']+')\)")
        .allMatches(sql).map((m) => [
          m[1], m[2], m[3] == 'NULL' ? null : m[3]!.replaceAll("'", ''),
          int.parse(m[4]!), m[5] == 'NULL' ? null : m[5]!.replaceAll("'", ''),
        ]).toList();
    expect(rows, marketplaceCategories.map((c) =>
      [c.slug, c.name, c.parentSlug, c.sort, c.restricted]).toList());
    expect(marketplaceCategories.map((c) => c.slug).toSet().length,
        marketplaceCategories.length);
    for (final c in marketplaceCategories) {
      if (c.parentSlug != null) {
        expect(marketplaceCategories.any((p) => p.slug == c.parentSlug), isTrue);
      }
    }
  });

  test('every Lexicon starter has a valid industry-aware mapping', () {
    for (final industry in Industry.values) {
      for (final name in lexiconFor(industry).starterCategories) {
        final slug = starterMarketplaceCategory(industry: industry, name: name);
        expect(marketplaceCategories.any((c) => c.slug == slug), isTrue,
            reason: '$industry / $name');
      }
    }
    expect(starterMarketplaceCategory(industry: Industry.boutique, name: 'Accessories'),
        'fashion-accessories');
    expect(starterMarketplaceCategory(industry: Industry.phoneAndGadgets, name: 'Accessories'),
        'phone-accessories');
    expect(starterMarketplaceCategory(industry: Industry.beverage, name: 'Seasonal'), isNull);
    expect(marketplaceCategoryFor(null).slug, 'other');
    expect(marketplaceCategoryFor('unknown-future-slug').slug, 'other');
  });
}
