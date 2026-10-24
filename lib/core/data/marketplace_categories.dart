import 'package:reebaplus_pos/core/industry/industry.dart';

/// Public category reference shared by every shop (#472). No tenant data.
class MarketplaceCategory {
  const MarketplaceCategory({required this.slug, required this.name,
    this.parentSlug, required this.sort, this.restricted});
  final String slug;
  final String name;
  final String? parentSlug;
  final int sort;
  final String? restricted;
}

const marketplaceCategories = <MarketplaceCategory>[
  MarketplaceCategory(slug: 'other', name: 'Other', parentSlug: null, sort: 0, restricted: null),
  MarketplaceCategory(slug: 'beverages', name: 'Beverages', parentSlug: null, sort: 1, restricted: null),
  MarketplaceCategory(slug: 'water', name: 'Water', parentSlug: 'beverages', sort: 2, restricted: null),
  MarketplaceCategory(slug: 'soft-drinks', name: 'Soft Drinks', parentSlug: 'beverages', sort: 3, restricted: null),
  MarketplaceCategory(slug: 'beer', name: 'Beer', parentSlug: 'beverages', sort: 4, restricted: 'age_18'),
  MarketplaceCategory(slug: 'spirits', name: 'Spirits', parentSlug: 'beverages', sort: 5, restricted: 'age_18'),
  MarketplaceCategory(slug: 'wine', name: 'Wine', parentSlug: 'beverages', sort: 6, restricted: 'age_18'),
  MarketplaceCategory(slug: 'energy-drinks', name: 'Energy Drinks', parentSlug: 'beverages', sort: 7, restricted: null),
  MarketplaceCategory(slug: 'health', name: 'Health', parentSlug: null, sort: 8, restricted: null),
  MarketplaceCategory(slug: 'antibiotics', name: 'Antibiotics', parentSlug: 'health', sort: 9, restricted: null),
  MarketplaceCategory(slug: 'painkillers', name: 'Painkillers', parentSlug: 'health', sort: 10, restricted: null),
  MarketplaceCategory(slug: 'vitamins', name: 'Vitamins', parentSlug: 'health', sort: 11, restricted: null),
  MarketplaceCategory(slug: 'antimalarials', name: 'Antimalarials', parentSlug: 'health', sort: 12, restricted: null),
  MarketplaceCategory(slug: 'first-aid', name: 'First Aid', parentSlug: 'health', sort: 13, restricted: null),
  MarketplaceCategory(slug: 'electronics', name: 'Electronics', parentSlug: null, sort: 14, restricted: null),
  MarketplaceCategory(slug: 'phones', name: 'Phones', parentSlug: 'electronics', sort: 15, restricted: null),
  MarketplaceCategory(slug: 'chargers', name: 'Chargers', parentSlug: 'electronics', sort: 16, restricted: null),
  MarketplaceCategory(slug: 'earphones', name: 'Earphones', parentSlug: 'electronics', sort: 17, restricted: null),
  MarketplaceCategory(slug: 'cases', name: 'Cases', parentSlug: 'electronics', sort: 18, restricted: null),
  MarketplaceCategory(slug: 'food', name: 'Food', parentSlug: null, sort: 19, restricted: null),
  MarketplaceCategory(slug: 'frozen-meat', name: 'Frozen Meat', parentSlug: 'food', sort: 20, restricted: null),
  MarketplaceCategory(slug: 'frozen-fish', name: 'Frozen Fish', parentSlug: 'food', sort: 21, restricted: null),
  MarketplaceCategory(slug: 'vegetables', name: 'Vegetables', parentSlug: 'food', sort: 22, restricted: null),
  MarketplaceCategory(slug: 'dairy', name: 'Dairy', parentSlug: 'food', sort: 23, restricted: null),
  MarketplaceCategory(slug: 'groceries', name: 'Groceries', parentSlug: 'food', sort: 24, restricted: null),
  MarketplaceCategory(slug: 'snacks', name: 'Snacks', parentSlug: 'food', sort: 25, restricted: null),
  MarketplaceCategory(slug: 'meals', name: 'Meals', parentSlug: null, sort: 26, restricted: null),
  MarketplaceCategory(slug: 'starters', name: 'Starters', parentSlug: 'meals', sort: 27, restricted: null),
  MarketplaceCategory(slug: 'main-dishes', name: 'Main Dishes', parentSlug: 'meals', sort: 28, restricted: null),
  MarketplaceCategory(slug: 'drinks', name: 'Drinks', parentSlug: 'meals', sort: 29, restricted: null),
  MarketplaceCategory(slug: 'desserts', name: 'Desserts', parentSlug: 'meals', sort: 30, restricted: null),
  MarketplaceCategory(slug: 'household', name: 'Household', parentSlug: null, sort: 31, restricted: null),
  MarketplaceCategory(slug: 'toiletries', name: 'Toiletries', parentSlug: 'household', sort: 32, restricted: null),
  MarketplaceCategory(slug: 'building-materials', name: 'Building Materials', parentSlug: null, sort: 33, restricted: null),
  MarketplaceCategory(slug: 'cement', name: 'Cement', parentSlug: 'building-materials', sort: 34, restricted: null),
  MarketplaceCategory(slug: 'blocks', name: 'Blocks', parentSlug: 'building-materials', sort: 35, restricted: null),
  MarketplaceCategory(slug: 'steel', name: 'Steel', parentSlug: 'building-materials', sort: 36, restricted: null),
  MarketplaceCategory(slug: 'paint', name: 'Paint', parentSlug: 'building-materials', sort: 37, restricted: null),
  MarketplaceCategory(slug: 'plumbing', name: 'Plumbing', parentSlug: 'building-materials', sort: 38, restricted: null),
  MarketplaceCategory(slug: 'fashion', name: 'Fashion', parentSlug: null, sort: 39, restricted: null),
  MarketplaceCategory(slug: 'men', name: 'Men', parentSlug: 'fashion', sort: 40, restricted: null),
  MarketplaceCategory(slug: 'women', name: 'Women', parentSlug: 'fashion', sort: 41, restricted: null),
  MarketplaceCategory(slug: 'kids', name: 'Kids', parentSlug: 'fashion', sort: 42, restricted: null),
  MarketplaceCategory(slug: 'footwear', name: 'Footwear', parentSlug: 'fashion', sort: 43, restricted: null),
  MarketplaceCategory(slug: 'phone-accessories', name: 'Phone accessories', parentSlug: 'electronics', sort: 44, restricted: null),
  MarketplaceCategory(slug: 'fashion-accessories', name: 'Fashion accessories', parentSlug: 'fashion', sort: 45, restricted: null),
];

/// An absent mapping is deliberately shown under Other in the storefront.
MarketplaceCategory marketplaceCategoryFor(String? slug) =>
    marketplaceCategories.firstWhere((c) => c.slug == slug,
        orElse: () => marketplaceCategories.first);

/// Initial mappings use exact public child names, independent of UI suggestions.
String? starterMarketplaceCategory({required Industry industry, required String name}) {
  final normalized = name.trim().toLowerCase();
  if (normalized == 'general') return 'other';
  if (normalized == 'accessories') {
    return switch (industry) {
      Industry.phoneAndGadgets => 'phone-accessories',
      Industry.boutique => 'fashion-accessories',
      _ => null,
    };
  }
  for (final category in marketplaceCategories) {
    if (category.parentSlug != null && category.name.toLowerCase() == normalized) {
      return category.slug;
    }
  }
  return null;
}
