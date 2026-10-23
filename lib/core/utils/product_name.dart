import 'package:reebaplus_pos/core/utils/product_unit.dart';

/// Returns the display name for a product, optionally prepending the unit
/// and appending a size abbreviation. The unit is shown through [unitLabel],
/// so a stored `Bottle` reads "Bottle Crate" (#487).
///
/// Examples:
///   productDisplayName('Goldberg', 'big',    unit: 'Bottle') → 'Bottle Crate Goldberg (B)'
///   productDisplayName('Goldberg', 'medium', unit: 'Crate')  → 'Crate Goldberg (M)'
///   productDisplayName('Goldberg', null,     unit: 'Can')    → 'Can Goldberg'
///   productDisplayName('Goldberg', 'small')                  → 'Goldberg (S)'
///   productDisplayName('Goldberg', null)                     → 'Goldberg'
String productDisplayName(String name, String? size, {String? unit}) {
  final shown = unitLabel(unit);
  final base = (shown != null && shown.isNotEmpty) ? '$shown $name' : name;
  if (size == null || size.isEmpty) return base;
  final abbr = size[0].toUpperCase();
  return '$base ($abbr)';
}
