/// The small, pure rules behind the Add Product form's words and figures
/// (#487): unit words, the "how many in one" label, the pricing subtitle, the
/// preview's detail line and the profit rows. No widgets, no database.
///
/// [crates] is `businessTracksCrates(business)`: only a shop that counts empty
/// crates reads a Bottle product as "Bottle Crate" / "crates". Anywhere else a
/// Bottle is a plain bottle.
library;

import 'package:reebaplus_pos/core/utils/product_unit.dart';
import 'package:reebaplus_pos/features/inventory/models/fast_add_product_model.dart';

bool _isBottle(String? unit) => unit?.trim().toLowerCase() == 'bottle';

/// The on-screen label for [unit] in the form (chips, preview).
String? formUnitLabel(String? unit, {required bool crates}) =>
    (!crates && _isBottle(unit)) ? unit : unitLabel(unit);

/// The count word after a number ("20 crates", "1 bottle", "3 units").
String formCountNoun(String? unit, num count, {required bool crates}) {
  if (!crates && _isBottle(unit)) return count == 1 ? 'bottle' : 'bottles';
  return unitCountNoun(unit, count);
}

/// The label of the "how many in one" box for [unit], or null when the unit
/// has no such box ([unitTakesPackCount]).
///
///   unitsPerPackLabel('Bottle', crates: true)  → 'Bottles in one crate'
///   unitsPerPackLabel('Bottle', crates: false) → null
///   unitsPerPackLabel('Pack', crates: false)   → 'Pieces in one pack'
///   unitsPerPackLabel('Can', crates: true)     → null
String? unitsPerPackLabel(String? unit, {required bool crates}) {
  if (!unitTakesPackCount(unit, crates: crates)) return null;
  final u = unit!.trim().toLowerCase();
  if (u == 'bottle') return 'Bottles in one crate';
  return 'Pieces in one $u';
}

/// The Pricing card's subtitle: "All prices are per crate." for a crate
/// shop's Bottle product, "per item" when there is no unit.
String pricingSubtitle(String? unit, {required bool crates}) =>
    'All prices are per ${priceUnitNoun(unit, crates: crates)}.';

/// What one price buys: the unit's singular count word, or "item" when there
/// is no unit.
String priceUnitNoun(String? unit, {required bool crates}) {
  final blank = unit == null || unit.trim().isEmpty;
  return blank ? 'item' : formCountNoun(unit, 1, crates: crates);
}

/// The preview card's detail line: the pack ("Crate of 12", or the unit's
/// label when no count is given) and the category, joined by " · ". Empty when
/// there is neither.
///
///   previewDetailLine(unit: 'Bottle', unitsPerPack: 12, category: 'Beer',
///       crates: true) → 'Crate of 12 · Beer'
///   previewDetailLine(unit: 'Can', category: null, crates: true) → 'Can'
String previewDetailLine({
  required String? unit,
  required bool crates,
  int? unitsPerPack,
  String? category,
}) {
  final String? pack;
  if (unitsPerPack != null && unitTakesPackCount(unit, crates: crates)) {
    final noun = formCountNoun(unit, 1, crates: crates);
    pack = '${noun[0].toUpperCase()}${noun.substring(1)} of $unitsPerPack';
  } else {
    pack = formUnitLabel(unit, crates: crates);
  }
  final cat = category?.trim();
  return [
    if (pack != null && pack.trim().isNotEmpty) pack,
    if (cat != null && cat.isNotEmpty) cat,
  ].join(' · ');
}

/// A profit row's figures: the amount (price − cost) in kobo and the share of
/// the selling price, rounded to a whole percent.
class ProductProfit {
  const ProductProfit({required this.amountKobo, required this.percent});

  final int amountKobo;

  /// `(price − cost) / price`, as a whole number (10 for 10%).
  final int percent;

  bool get isLoss => amountKobo < 0;
}

/// The profit on [priceKobo] at [costKobo], or null when there is no price to
/// take a share of.
ProductProfit? productProfit({required int priceKobo, required int costKobo}) {
  if (priceKobo <= 0) return null;
  final amount = priceKobo - costKobo;
  return ProductProfit(
    amountKobo: amount,
    percent: (amount * 100 / priceKobo).round(),
  );
}
