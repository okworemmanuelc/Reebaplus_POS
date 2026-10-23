import 'package:reebaplus_pos/core/industry/industry.dart';
import 'package:reebaplus_pos/core/industry/lexicon.dart';

/// Public category reference shared by every shop (#472). No tenant data.
class MarketplaceCategory {
  const MarketplaceCategory(this.slug, this.name, this.parentSlug, this.sort, this.restricted);
  final String slug;
  final String name;
  final String? parentSlug;
  final int sort;
  final String? restricted;
}

const marketplaceCategories = <MarketplaceCategory>[
  MarketplaceCategory('other', 'Other', null, 0, null),
  MarketplaceCategory('beverages', 'Beverages', null, 1, null),
  MarketplaceCategory('water', 'Water', 'beverages', 2, null),
  MarketplaceCategory('soft-drinks', 'Soft Drinks', 'beverages', 3, null),
  MarketplaceCategory('beer', 'Beer', 'beverages', 4, 'age_18'),
  MarketplaceCategory('spirits', 'Spirits', 'beverages', 5, 'age_18'),
  MarketplaceCategory('wine', 'Wine', 'beverages', 6, 'age_18'),
  MarketplaceCategory('energy-drinks', 'Energy Drinks', 'beverages', 7, null),
  MarketplaceCategory('health', 'Health', null, 8, null),
  MarketplaceCategory('antibiotics', 'Antibiotics', 'health', 9, null),
  MarketplaceCategory('painkillers', 'Painkillers', 'health', 10, null),
  MarketplaceCategory('vitamins', 'Vitamins', 'health', 11, null),
  MarketplaceCategory('antimalarials', 'Antimalarials', 'health', 12, null),
  MarketplaceCategory('first-aid', 'First Aid', 'health', 13, null),
  MarketplaceCategory('electronics', 'Electronics', null, 14, null),
  MarketplaceCategory('phones', 'Phones', 'electronics', 15, null),
  MarketplaceCategory('chargers', 'Chargers', 'electronics', 16, null),
  MarketplaceCategory('earphones', 'Earphones', 'electronics', 17, null),
  MarketplaceCategory('cases', 'Cases', 'electronics', 18, null),
  MarketplaceCategory('food', 'Food', null, 19, null),
  MarketplaceCategory('frozen-meat', 'Frozen Meat', 'food', 20, null),
  MarketplaceCategory('frozen-fish', 'Frozen Fish', 'food', 21, null),
  MarketplaceCategory('vegetables', 'Vegetables', 'food', 22, null),
  MarketplaceCategory('dairy', 'Dairy', 'food', 23, null),
  MarketplaceCategory('groceries', 'Groceries', 'food', 24, null),
  MarketplaceCategory('snacks', 'Snacks', 'food', 25, null),
  MarketplaceCategory('meals', 'Meals', null, 26, null),
  MarketplaceCategory('starters', 'Starters', 'meals', 27, null),
  MarketplaceCategory('main-dishes', 'Main Dishes', 'meals', 28, null),
  MarketplaceCategory('drinks', 'Drinks', 'meals', 29, null),
  MarketplaceCategory('desserts', 'Desserts', 'meals', 30, null),
  MarketplaceCategory('household', 'Household', null, 31, null),
  MarketplaceCategory('toiletries', 'Toiletries', 'household', 32, null),
  MarketplaceCategory('building-materials', 'Building Materials', null, 33, null),
  MarketplaceCategory('cement', 'Cement', 'building-materials', 34, null),
  MarketplaceCategory('blocks', 'Blocks', 'building-materials', 35, null),
  MarketplaceCategory('steel', 'Steel', 'building-materials', 36, null),
  MarketplaceCategory('paint', 'Paint', 'building-materials', 37, null),
  MarketplaceCategory('plumbing', 'Plumbing', 'building-materials', 38, null),
  MarketplaceCategory('fashion', 'Fashion', null, 39, null),
  MarketplaceCategory('men', 'Men', 'fashion', 40, null),
  MarketplaceCategory('women', 'Women', 'fashion', 41, null),
  MarketplaceCategory('kids', 'Kids', 'fashion', 42, null),
  MarketplaceCategory('footwear', 'Footwear', 'fashion', 43, null),
  MarketplaceCategory('phone-accessories', 'Phone accessories', 'electronics', 44, null),
  MarketplaceCategory('fashion-accessories', 'Fashion accessories', 'fashion', 45, null),
];

/// An absent mapping is deliberately shown under Other in the storefront.
MarketplaceCategory marketplaceCategoryFor(String? slug) =>
    marketplaceCategories.firstWhere((c) => c.slug == slug,
        orElse: () => marketplaceCategories.first);

/// Only exact Lexicon suggestions are pre-mapped; custom names stay unmapped.
String? starterMarketplaceCategory(Industry industry, String name) {
  final normalized = name.trim().toLowerCase();
  if (!lexiconFor(industry).starterCategories
      .any((s) => s.toLowerCase() == normalized)) {
    return null;
  }
  if (normalized == 'general') return 'other';
  if (normalized == 'accessories') {
    return industry == Industry.phoneAndGadgets
        ? 'phone-accessories' : 'fashion-accessories';
  }
  return normalized.replaceAll(' ', '-');
}
