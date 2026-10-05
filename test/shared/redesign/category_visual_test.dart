import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/category_visual.dart';

/// #352 PR 2: the pure product-tile rule (PRD #346 "Product tiles").
void main() {
  final f = AppFixedColors.light;

  test('keywords pick the icon, case-insensitively', () {
    expect(categoryVisual('Beer', f).icon, AppIcons.beerMug);
    expect(categoryVisual('PREMIUM LAGER', f).icon, AppIcons.beerMug);
    expect(categoryVisual('Stout', f).icon, AppIcons.beerMug);
    expect(categoryVisual('Table Water', f).icon, AppIcons.waterDrop);
    expect(categoryVisual('energy drinks', f).icon, AppIcons.quickSale);
    expect(categoryVisual('Soft Drinks', f).icon, AppIcons.softDrinkCup);
    expect(categoryVisual('Soda', f).icon, AppIcons.softDrinkCup);
    expect(categoryVisual('Fruit Juice', f).icon, AppIcons.softDrinkCup);
    expect(categoryVisual('Malt', f).icon, AppIcons.maltCan);
    expect(categoryVisual('Red Wine', f).icon, AppIcons.wineBottle);
    expect(categoryVisual('Spirits', f).icon, AppIcons.wineBottle);
    expect(categoryVisual('Insecticide', f).icon, AppIcons.box);
  });

  test('keyword colours follow the mockups', () {
    expect(categoryVisual('Beer', f).tint, f.warningTint);
    expect(categoryVisual('Beer', f).iconColor, f.warning);
    expect(categoryVisual('Stout', f).tint, f.neutralTile);
    expect(categoryVisual('Soft Drinks', f).tint, f.dangerTint);
    expect(categoryVisual('Water', f).tint, f.infoTint);
    expect(categoryVisual('Malt', f).tint, f.maltTile);
    expect(categoryVisual('Energy', f).tint, f.greenTint);
  });

  test('stout wins over beer, malt over everything after it', () {
    expect(categoryVisual('Beer & Stout', f).tint, f.neutralTile);
    expect(categoryVisual('Malt Lager', f).icon, AppIcons.maltCan);
  });

  test('null or blank category is the neutral tile with a box', () {
    for (final name in [null, '', '   ']) {
      final v = categoryVisual(name, f);
      expect(v.icon, AppIcons.box);
      expect(v.tint, f.neutralTile);
      expect(v.iconColor, f.neutralIcon);
    }
  });

  test('other names hash stably into the fixed palette', () {
    // Sum of code units, not String.hashCode: pinned values never change.
    expect(categoryNameHash('biscuits'), 870);
    expect(categoryNameHash('Biscuits '), 870, reason: 'trim + lower-case');
    final a = categoryVisual('Biscuits', f);
    final b = categoryVisual('biscuits', f);
    expect(a, b);
    // 870 % 6 == 0 → the warning pair.
    expect(a.tint, f.warningTint);
    // Different names can land on different colours.
    final tints = {
      for (final n in [
        'Insecticide',
        'Biscuits',
        'Snacks',
        'Toiletries',
        'Rice',
        'Noodles',
      ])
        categoryVisual(n, f).tint,
    };
    expect(tints.length, greaterThan(1));
  });

  test('dark fixed colours are used when given', () {
    final d = AppFixedColors.dark;
    expect(categoryVisual('Beer', d).tint, d.warningTint);
  });
}
