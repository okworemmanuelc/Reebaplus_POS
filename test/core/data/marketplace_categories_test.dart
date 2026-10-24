import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/data/marketplace_categories.dart';
import 'package:reebaplus_pos/core/industry/industry.dart';

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

  test('exact child names pre-map without any industry starter suggestions', () {
    for (final entry in [('Water', 'water'), ('Beer', 'beer'), ('Phones', 'phones')]) {
      expect(starterMarketplaceCategory(industry: Industry.generic, name: entry.$1),
          entry.$2);
    }
    final children = marketplaceCategories.where((c) => c.parentSlug != null).toList();
    expect(children, isNotEmpty);
    for (final category in children) {
      expect(starterMarketplaceCategory(industry: Industry.generic,
          name: ' ${category.name.toUpperCase()} '), category.slug);
    }
  });

  test('only exact child names match, with General and industry-aware Accessories exceptions', () {
    expect(starterMarketplaceCategory(industry: Industry.boutique, name: 'Accessories'),
        'fashion-accessories');
    expect(starterMarketplaceCategory(industry: Industry.phoneAndGadgets, name: 'Accessories'),
        'phone-accessories');
    expect(starterMarketplaceCategory(industry: Industry.beverage, name: 'Accessories'), isNull);
    expect(starterMarketplaceCategory(industry: Industry.generic, name: ' general '), 'other');
    for (final name in ['Seasonal', 'Beverages', 'Food', 'Other', 'Watermelon', 'Phone',
      'Soft  Drinks', 'Beer specials']) {
      expect(starterMarketplaceCategory(industry: Industry.generic, name: name), isNull,
          reason: name);
    }
    expect(marketplaceCategoryFor(null).slug, 'other');
    expect(marketplaceCategoryFor('unknown-future-slug').slug, 'other');
  });
}
