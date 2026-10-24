/// How a product's stored unit is shown to a person (#487).
///
/// The SAVED unit never changes: a product stays `Bottle` in Drift, the cloud
/// and every `== 'bottle'` crate check. Only the words on screen change, and
/// only for a shop that counts empty crates: there a `Bottle` product is sold,
/// counted and returned by the crate, so it reads as "Bottle Crate". Every
/// other shop (a pharmacy's bottle of syrup, a supermarket's bottle of oil)
/// keeps plain "Bottle".
///
/// The [crates] flag every helper here takes is
/// `businessTracksCrates(business)` for the active business (the combined
/// gate: crate business type AND `tracks_empty_crates`). It is required on
/// purpose, so no caller can forget which shop it is drawing for. Every place
/// a unit is shown passes it through [unitLabel]; a dropdown or chip still
/// saves the raw value.
library;

export 'package:reebaplus_pos/core/industry/lexicon.dart'
    show kGenericUnits, kCrateOnlyUnits, kCrateUnits;

/// The on-screen label for a stored [unit].
///
/// With [crates] (a shop that counts empty crates) a `Bottle` (any case) reads
/// "Bottle Crate". Otherwise, and for every other unit, the unit is shown
/// unchanged (null stays null).
///
///   unitLabel('Bottle', crates: true)  → 'Bottle Crate'
///   unitLabel('Bottle', crates: false) → 'Bottle'
///   unitLabel('Can', crates: true)     → 'Can'
///   unitLabel(null, crates: true)      → null
String? unitLabel(String? unit, {required bool crates}) {
  if (unit == null) return null;
  if (crates && unit.trim().toLowerCase() == 'bottle') return 'Bottle Crate';
  return unit;
}

/// The lower-case count noun for [count] of a product in [unit] — the word
/// after a number ("12 crates", "1 pack").
///
/// With [crates] a `Bottle` product counts in crates; without, in bottles. A
/// unit-less product (null, blank or `Other`) counts in "unit"/"units". Any
/// other unit is its own name, lower case, made plural when [count] isn't
/// exactly 1.
///
///   unitCountNoun('Bottle', 3, crates: true)  → 'crates'
///   unitCountNoun('Bottle', 3, crates: false) → 'bottles'
///   unitCountNoun('Box', 2, crates: true)     → 'boxes'
///   unitCountNoun(null, 2, crates: true)      → 'units'
String unitCountNoun(String? unit, num count, {required bool crates}) {
  final one = count == 1;
  final u = unit?.trim().toLowerCase() ?? '';
  if (u.isEmpty || u == 'other') return one ? 'unit' : 'units';
  final singular = (crates && u == 'bottle') ? 'crate' : u;
  if (one) return singular;
  if (singular.endsWith('s') ||
      singular.endsWith('x') ||
      singular.endsWith('ch') ||
      singular.endsWith('sh')) {
    return '${singular}es';
  }
  return '${singular}s';
}

/// True for a unit no NEW product may pick (#487): plain `Crate`, for every
/// shop. A drink sold by the crate is a `Bottle` product ("Bottle Crate" in a
/// shop that counts empties), whose empties are tracked; a `Crate` product
/// never was, and plain "Crate" is a drinks idea no other trade needs. The
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
