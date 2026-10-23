/// How a product's stored unit is shown to a person (#487).
///
/// The SAVED unit never changes: a product stays `Bottle` in Drift, the cloud
/// and every `== 'bottle'` crate check. Only the words on screen change — a
/// `Bottle` product is sold, counted and returned by the crate, so it reads as
/// "Bottle Crate". Every place a unit is shown passes it through [unitLabel];
/// a dropdown or chip still saves the raw value.
library;

/// The on-screen label for a stored [unit]: "Bottle Crate" for `Bottle`
/// (any case), and the unit unchanged otherwise (null stays null).
///
///   unitLabel('Bottle') → 'Bottle Crate'
///   unitLabel('Can')    → 'Can'
///   unitLabel(null)     → null
String? unitLabel(String? unit) {
  if (unit == null) return null;
  if (unit.trim().toLowerCase() == 'bottle') return 'Bottle Crate';
  return unit;
}

/// The lower-case count noun for [count] of a product in [unit] — the word
/// after a number ("12 crates", "1 pack").
///
/// A `Bottle` product counts in crates. A unit-less product (null, blank or
/// `Other`) counts in "unit"/"units". Any other unit is its own name, lower
/// case, made plural when [count] isn't exactly 1.
///
///   unitCountNoun('Bottle', 1) → 'crate'
///   unitCountNoun('Bottle', 3) → 'crates'
///   unitCountNoun('Box', 2)    → 'boxes'
///   unitCountNoun(null, 2)     → 'units'
String unitCountNoun(String? unit, num count) {
  final one = count == 1;
  final u = unit?.trim().toLowerCase() ?? '';
  if (u.isEmpty || u == 'other') return one ? 'unit' : 'units';
  final singular = u == 'bottle' ? 'crate' : u;
  if (one) return singular;
  if (singular.endsWith('s') ||
      singular.endsWith('x') ||
      singular.endsWith('ch') ||
      singular.endsWith('sh')) {
    return '${singular}es';
  }
  return '${singular}s';
}

/// True for a unit no NEW product may pick (#487): plain `Crate`. A drink sold
/// by the crate is a `Bottle` product ("Bottle Crate"), whose empties are
/// tracked; a `Crate` product never was. The value stays valid in the database
/// (`kProductUnits` and the CHECK) so products already saved as `Crate` keep it.
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
      if (k != null) k,
  };
  return [
    for (final u in units)
      if (!isUnitHiddenForNewProducts(u) || kept.contains(u)) u,
  ];
}
