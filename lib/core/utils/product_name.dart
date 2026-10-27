import 'package:reebaplus_pos/core/utils/name_case.dart';
import 'package:reebaplus_pos/core/utils/product_unit.dart';

/// Returns the display name for a product, optionally prepending the unit
/// and appending a size abbreviation. The name goes through [toNameCase] so
/// names saved before #507 show the same way as new ones. The unit is shown
/// through [unitLabel],
/// so in a shop that counts empty crates ([crates] =
/// `businessTracksCrates(business)`) a stored `Bottle` reads "Bottle Crate"
/// (#487); every other shop keeps "Bottle".
///
/// Examples:
///   productDisplayName('Goldberg', 'big', unit: 'Bottle', crates: true)  → 'Bottle Crate Goldberg (B)'
///   productDisplayName('Syrup', null, unit: 'Bottle', crates: false)     → 'Bottle Syrup'
///   productDisplayName('Goldberg', 'medium', unit: 'Crate', crates: true) → 'Crate Goldberg (M)'
///   productDisplayName('Goldberg', null, unit: 'Can', crates: true)      → 'Can Goldberg'
///   productDisplayName('Goldberg', 'small', crates: true)                → 'Goldberg (S)'
///   productDisplayName('Goldberg', null, crates: false)                  → 'Goldberg'
String productDisplayName(
  String name,
  String? size, {
  String? unit,
  required bool crates,
}) {
  final shown = unitLabel(unit, crates: crates);
  final cased = toNameCase(name);
  final base = (shown != null && shown.isNotEmpty) ? '$shown $cased' : cased;
  if (size == null || size.isEmpty) return base;
  final abbr = size[0].toUpperCase();
  return '$base ($abbr)';
}
