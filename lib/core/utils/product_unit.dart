/// How a product's stored unit is shown to a person (#487, #675).
///
/// The SAVED unit never changes: a product stays `Bottle` in Drift, the cloud
/// and every `== 'bottle'` crate check. A unit is shown and counted by its own
/// name in every shop: "Bottle" / "3 bottles", never "Bottle Crate" / "3
/// crates" (owner decision #675 — a wholesaler's one bottle in stock is one
/// crate sold, but the word stays the type's). Crate wording that is about
/// the crate itself ("Bottles in one crate", the crate ledger) is unaffected.
library;

export 'package:reebaplus_pos/core/industry/lexicon.dart'
    show kGenericUnits, kCrateOnlyUnits, kCrateUnits;

/// The on-screen label for a stored [unit]: the unit unchanged, null stays
/// null. "Bottle" never becomes "Bottle Crate" (#675).
String? unitLabel(String? unit) => unit;

/// The lower-case count noun for [count] of a product in [unit] — the word
/// after a number ("12 bottles", "1 pack").
///
/// A unit-less product (null, blank or `Other`) counts in "unit"/"units". Any
/// other unit is its own name, lower case, made plural when [count] isn't
/// exactly 1. A Bottle counts in bottles, never crates (#675).
///
///   unitCountNoun('Bottle', 3) → 'bottles'
///   unitCountNoun('Box', 2)    → 'boxes'
///   unitCountNoun(null, 2)     → 'units'
String unitCountNoun(String? unit, num count) {
  final one = count == 1;
  final u = unit?.trim().toLowerCase() ?? '';
  if (u.isEmpty || u == 'other') return one ? 'unit' : 'units';
  if (one) return u;
  if (u.endsWith('s') ||
      u.endsWith('x') ||
      u.endsWith('ch') ||
      u.endsWith('sh')) {
    return '${u}es';
  }
  return '${u}s';
}

/// True for a unit no NEW product may pick (#487): plain `Crate`, for every
/// shop. A drink sold by the crate is a `Bottle` product, whose empties are
/// tracked; a `Crate` product never was, and plain "Crate" is a drinks idea no other trade needs. The
/// value stays valid in the database (`kProductUnits` and the CHECK) so
/// products already saved as `Crate` keep it.
bool isUnitHiddenForNewProducts(String unit) =>
    unit.trim().toLowerCase() == 'crate';

/// The units a unit picker offers: [units] without the ones hidden for new
/// products ([isUnitHiddenForNewProducts]), except a unit in [keep] — the
/// product's saved unit and the picker's current value — which stays on offer
/// so an existing `Crate` product still shows and can keep its unit.
List<String> unitChoices(
  Iterable<String> units, {
  Iterable<String?> keep = const [],
}) {
  final kept = {
    for (final k in keep)
      if (k != null && k.trim().isNotEmpty) k.trim(),
  };
  final result = <String>[];
  for (final u in units) {
    if (!isUnitHiddenForNewProducts(u) ||
        kept.any((k) => k.toLowerCase() == u.toLowerCase())) {
      result.add(u);
    }
  }
  for (final k in kept) {
    if (!result.any((u) => u.toLowerCase() == k.toLowerCase())) {
      result.add(k);
    }
  }
  return result;
}
