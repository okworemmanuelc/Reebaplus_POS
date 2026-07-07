import 'package:reebaplus_pos/core/industry/industry.dart';

/// The app-shipped, compile-time set of an [Industry]'s domain nouns and starter
/// presets (CONTEXT.md → *Lexicon*, ADR 0015). It covers only the words that
/// read wrong cross-industry — what a sellable **item** is called, its default
/// **unit**, the **category** word — plus the starter unit/category suggestions
/// and example hints a brand-new shop sees. Neutral words (Save, Price, Stock,
/// Search) are left literal and never live here.
///
/// Every slot has a neutral **generic** default (the constructor defaults), so
/// an industry that fills only some slots still resolves the rest to sensible
/// generic words — the per-slot fallback the ADR calls for. Beverage-only nouns
/// (crate, empties) are NOT here: their surfaces are already gated by
/// `isCrateBusiness`, so they cannot leak to another trade.
///
/// Not CEO-editable and not synced. The UI reads a business's Lexicon through
/// `industryLexiconProvider`, which resolves the active [Industry] and returns
/// the entry below via [lexiconFor].
class Lexicon {
  const Lexicon({
    this.item = 'Product',
    this.category = 'Category',
    this.unit = 'Piece',
    this.starterUnits = _genericUnits,
    this.starterCategories = _genericCategories,
    this.itemNameHint = 'e.g. product name',
    this.itemDescriptionHint = 'e.g. short description',
  });

  /// Singular noun for a sellable item ("Product", "Medicine", "Handset"). Used
  /// e.g. as the `"$item Name"` field label.
  final String item;

  /// The grouping word ("Category" for most trades).
  final String category;

  /// The default unit-of-measure for a new item ("Bottle", "Pack", "Piece").
  final String unit;

  /// Suggested units of measure offered in the product form.
  final List<String> starterUnits;

  /// Suggested starter categories so a brand-new shop isn't a blank slate.
  final List<String> starterCategories;

  /// Example product-name hint text.
  final String itemNameHint;

  /// Example description hint text.
  final String itemDescriptionHint;

  static const _genericUnits = ['Piece', 'Pack', 'Box', 'Carton', 'Bag', 'Other'];
  static const _genericCategories = ['General'];
}

// ── Per-industry lexicons ────────────────────────────────────────────────────
// Beverage/Bar reproduce today's wording verbatim (no regression): the product
// form has always shown "Product Name", the "Eva water 75cl" / "sparkling water"
// hints, and a Bottle default.

const _generic = Lexicon();

const _beverage = Lexicon(
  item: 'Product',
  unit: 'Bottle',
  starterUnits: [
    'Bottle', 'Can', 'PET', 'Sachet', 'Keg', 'Crate', 'Pack', 'Carton',
    'Piece', 'Bag', 'Box', 'Tin', 'Other',
  ],
  starterCategories: [
    'Water', 'Soft Drinks', 'Beer', 'Spirits', 'Wine', 'Energy Drinks',
  ],
  itemNameHint: 'Eva water 75cl',
  itemDescriptionHint: 'sparkling water',
);

const _pharmacy = Lexicon(
  item: 'Medicine',
  unit: 'Pack',
  starterUnits: ['Tablet', 'Pack', 'Bottle', 'Tube', 'Sachet', 'Vial', 'Box', 'Piece'],
  starterCategories: [
    'Antibiotics', 'Painkillers', 'Vitamins', 'Antimalarials', 'First Aid',
  ],
  itemNameHint: 'e.g. Paracetamol 500mg',
  itemDescriptionHint: 'e.g. pain relief',
);

const _phoneAndGadgets = Lexicon(
  item: 'Handset',
  unit: 'Piece',
  starterUnits: ['Piece', 'Pack', 'Set', 'Box'],
  starterCategories: [
    'Phones', 'Accessories', 'Chargers', 'Earphones', 'Cases',
  ],
  itemNameHint: 'e.g. iPhone 13 128GB',
  itemDescriptionHint: 'e.g. smartphone',
);

const _frozenFoodsAndGrocery = Lexicon(
  item: 'Product',
  unit: 'Pack',
  starterUnits: ['Pack', 'Kg', 'Bag', 'Piece', 'Carton', 'Box'],
  starterCategories: [
    'Frozen Meat', 'Frozen Fish', 'Vegetables', 'Dairy', 'Groceries',
  ],
  itemNameHint: 'e.g. Chicken 1kg',
  itemDescriptionHint: 'e.g. frozen',
);

const _restaurant = Lexicon(
  item: 'Item',
  unit: 'Plate',
  starterUnits: ['Plate', 'Portion', 'Bowl', 'Piece', 'Pack'],
  starterCategories: ['Starters', 'Main Dishes', 'Drinks', 'Desserts'],
  itemNameHint: 'e.g. Jollof Rice',
  itemDescriptionHint: 'e.g. with chicken',
);

const _supermarket = Lexicon(
  item: 'Product',
  unit: 'Piece',
  starterUnits: ['Piece', 'Pack', 'Kg', 'Bag', 'Carton', 'Box'],
  starterCategories: [
    'Groceries', 'Beverages', 'Toiletries', 'Household', 'Snacks',
  ],
  itemNameHint: 'e.g. Rice 5kg',
  itemDescriptionHint: 'e.g. groceries',
);

const _buildingMaterials = Lexicon(
  item: 'Material',
  unit: 'Bag',
  starterUnits: ['Bag', 'Piece', 'Ton', 'Length', 'Sheet', 'Litre'],
  starterCategories: ['Cement', 'Blocks', 'Steel', 'Paint', 'Plumbing'],
  itemNameHint: 'e.g. Dangote Cement 50kg',
  itemDescriptionHint: 'e.g. building material',
);

const _boutique = Lexicon(
  item: 'Item',
  unit: 'Piece',
  starterUnits: ['Piece', 'Pair', 'Set', 'Pack'],
  starterCategories: ['Men', 'Women', 'Kids', 'Accessories', 'Footwear'],
  itemNameHint: 'e.g. Ankara Dress',
  itemDescriptionHint: 'e.g. size M',
);

/// Resolves the [Lexicon] for [industry]. Total: every [Industry] maps to an
/// entry, and [Industry.generic] returns the neutral fallback.
Lexicon lexiconFor(Industry industry) => switch (industry) {
      Industry.bar || Industry.beverage => _beverage,
      Industry.pharmacy => _pharmacy,
      Industry.phoneAndGadgets => _phoneAndGadgets,
      Industry.frozenFoodsAndGrocery => _frozenFoodsAndGrocery,
      Industry.restaurant => _restaurant,
      Industry.supermarket => _supermarket,
      Industry.buildingMaterials => _buildingMaterials,
      Industry.boutique => _boutique,
      Industry.generic => _generic,
    };
