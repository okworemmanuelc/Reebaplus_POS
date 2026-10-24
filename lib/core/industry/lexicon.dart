import 'package:reebaplus_pos/core/industry/industry.dart';

/// The short list of units offered to every shop (#492 G3).
///
/// Kept in lock-step with G4's database CHECK so the UI never offers a unit
/// the database rejects.
const List<String> kGenericUnits = [
  'Piece',
  'Pack',
  'Box',
  'Carton',
  'Bag',
  'Bottle',
  'Can',
  'Kg',
  'Litre',
  'Other',
];

/// Extra units offered to shops that count empty crates (#492 G3).
const List<String> kCrateOnlyUnits = ['PET', 'Keg'];

/// The full starter units offered to crate-tracking shops (#492 G3).
const List<String> kCrateUnits = [
  'Piece',
  'Pack',
  'Box',
  'Carton',
  'Bag',
  'Bottle',
  'Can',
  'PET',
  'Keg',
  'Kg',
  'Litre',
  'Other',
];

/// The app-shipped domain nouns and starter presets (ADR 0015, #492 G3).
///
/// Every shop gets "Product" and "Category", plain example hints, no starter
/// categories, and no unit filled in by default. The only variation is
/// [starterUnits]: shops that count crates also get PET and Keg.
///
/// Not CEO-editable and not synced. The UI reads a business's Lexicon through
/// `industryLexiconProvider`, which resolves the active [Industry] and returns
/// the entry below via [lexiconFor].
class Lexicon {
  const Lexicon({
    this.item = 'Product',
    this.category = 'Category',
    this.unit,
    this.starterUnits = kGenericUnits,
    this.starterCategories = const [],
    this.itemNameHint = 'e.g. Product name',
    this.itemDescriptionHint = 'e.g. Short description',
  });

  /// Singular noun for a sellable item ("Product").
  final String item;

  /// The grouping word ("Category").
  final String category;

  /// The default unit-of-measure for a new item. Null by default: no unit is
  /// filled in by default (#492 G3).
  final String? unit;

  /// Suggested units of measure offered in the product form.
  final List<String> starterUnits;

  /// Suggested starter categories (empty: no starter categories, #492 G3).
  final List<String> starterCategories;

  /// Example product-name hint text.
  final String itemNameHint;

  /// Example description hint text.
  final String itemDescriptionHint;

  /// The plural of [item] for list/tab headings ("Products").
  String get itemPlural => '${item}s';

  /// Lowercased [item] / [itemPlural] for mid-sentence use ("tap a product",
  /// "no products found").
  String get itemLower => item.toLowerCase();
  String get itemPluralLower => itemPlural.toLowerCase();
}

const _generic = Lexicon(starterUnits: kGenericUnits);
const _crate = Lexicon(starterUnits: kCrateUnits);

/// Resolves the [Lexicon] for [industry]. Every trade gets generic nouns and
/// hints; crate-eligible shops (Bar and Beverage distributor) also get PET
/// and Keg in [Lexicon.starterUnits] (#492 G3).
Lexicon lexiconFor(Industry industry) =>
    industry.crateEligible ? _crate : _generic;
