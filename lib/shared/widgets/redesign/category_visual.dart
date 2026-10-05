import 'package:flutter/widgets.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';

/// The tile colour, icon colour and icon a product category gets when a
/// product has no photo (PRD #346 "Product tiles", #352 PR 2). Category chip
/// dots use [iconColor].
@immutable
class CategoryVisual {
  const CategoryVisual({
    required this.tint,
    required this.iconColor,
    required this.icon,
  });

  /// Pale tile fill behind the icon.
  final Color tint;

  /// The icon's colour; also the category chip's dot.
  final Color iconColor;
  final IconData icon;

  @override
  bool operator ==(Object other) =>
      other is CategoryVisual &&
      other.tint == tint &&
      other.iconColor == iconColor &&
      other.icon == icon;

  @override
  int get hashCode => Object.hash(tint, iconColor, icon);
}

/// One (tile, icon colour) pair of the fixed palette. Fixed colours: the same
/// in every design system (PRD #346 decision 6).
typedef _Pair = (Color tint, Color icon);

List<_Pair> _palette(AppFixedColors c) => [
  (c.warningTint, c.warning),
  (c.dangerTint, c.danger),
  (c.infoTint, c.info),
  (c.greenTint, c.green),
  (c.maltTile, c.info),
  (c.neutralTile, c.neutralIcon),
];

/// A stable hash of [name] — the sum of its (lower-cased, trimmed) UTF-16 code
/// units. Deliberately not `String.hashCode`, which is not guaranteed stable
/// across runs or platforms; a category must keep its colour forever.
int categoryNameHash(String name) {
  var sum = 0;
  for (final unit in name.trim().toLowerCase().codeUnits) {
    sum += unit;
  }
  return sum;
}

/// The pure rule behind a product tile without a photo.
///
/// Matching is case-insensitive and by keyword, first match wins:
///
/// | Keyword in the category name | Icon | Colour |
/// |---|---|---|
/// | stout | beer mug | neutral |
/// | malt | mug (`AppIcons.maltCan`) | malt tile |
/// | beer, lager | beer mug | warning (amber) |
/// | water | drop | info (blue) |
/// | energy | bolt | green |
/// | soft drink, soda, juice | cup | danger (red) |
/// | wine, spirit | bottle | hashed |
/// | anything else | box | hashed |
///
/// The keyword colours are the mockups' (`tablet-pos-*.png`: amber beer, dark
/// stout, red soft drinks, blue water, pale-blue malt, green energy). Every
/// other name gets a colour from [categoryNameHash] over the fixed palette, so
/// it is stable across runs. A null or blank category is the neutral tile with
/// the box icon.
CategoryVisual categoryVisual(String? categoryName, AppFixedColors colors) {
  final palette = _palette(colors);
  CategoryVisual of(_Pair pair, IconData icon) =>
      CategoryVisual(tint: pair.$1, iconColor: pair.$2, icon: icon);

  final name = categoryName?.trim().toLowerCase() ?? '';
  if (name.isEmpty) return of(palette[5], AppIcons.box);

  bool has(List<String> words) => words.any(name.contains);
  final hashed = palette[categoryNameHash(name) % palette.length];

  if (has(const ['stout'])) return of(palette[5], AppIcons.beerMug);
  if (has(const ['malt'])) return of(palette[4], AppIcons.maltCan);
  if (has(const ['beer', 'lager'])) return of(palette[0], AppIcons.beerMug);
  if (has(const ['water'])) return of(palette[2], AppIcons.waterDrop);
  if (has(const ['energy'])) return of(palette[3], AppIcons.quickSale);
  if (has(const ['soft drink', 'soda', 'juice'])) {
    return of(palette[1], AppIcons.softDrinkCup);
  }
  if (has(const ['wine', 'spirit'])) return of(hashed, AppIcons.wineBottle);
  return of(hashed, AppIcons.box);
}
