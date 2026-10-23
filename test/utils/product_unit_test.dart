import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/product_name.dart';
import 'package:reebaplus_pos/core/utils/product_unit.dart';

/// #487: a stored `Bottle` reads "Bottle Crate" everywhere a unit is shown,
/// the saved value never changes, and plain `Crate` is not offered to a new
/// product.
void main() {
  group('unitLabel', () {
    test('a stored Bottle reads "Bottle Crate", in any case', () {
      expect(unitLabel('Bottle'), 'Bottle Crate');
      expect(unitLabel('bottle'), 'Bottle Crate');
      expect(unitLabel('BOTTLE'), 'Bottle Crate');
    });

    test('every other unit is unchanged', () {
      for (final u in kProductUnits.where((u) => u != 'Bottle')) {
        expect(unitLabel(u), u, reason: u);
      }
      expect(unitLabel('Plate'), 'Plate');
    });

    test('no unit stays no unit', () {
      expect(unitLabel(null), isNull);
      expect(unitLabel(''), '');
    });
  });

  group('unitCountNoun', () {
    test('a Bottle product counts in crates', () {
      expect(unitCountNoun('Bottle', 1), 'crate');
      expect(unitCountNoun('Bottle', 0), 'crates');
      expect(unitCountNoun('Bottle', 12), 'crates');
      expect(unitCountNoun('bottle', 2), 'crates');
    });

    test('other units are their own lower-case name', () {
      expect(unitCountNoun('Pack', 1), 'pack');
      expect(unitCountNoun('Pack', 3), 'packs');
      expect(unitCountNoun('PET', 2), 'pets');
      expect(unitCountNoun('Crate', 1), 'crate');
      expect(unitCountNoun('Crate', 4), 'crates');
    });

    test('-s, -x, -ch and -sh units take "es"', () {
      expect(unitCountNoun('Box', 2), 'boxes');
      expect(unitCountNoun('Glass', 2), 'glasses');
      expect(unitCountNoun('Pouch', 2), 'pouches');
      expect(unitCountNoun('Dish', 2), 'dishes');
      expect(unitCountNoun('Box', 1), 'box');
    });

    test('a fraction is plural', () {
      expect(unitCountNoun('Keg', 1.5), 'kegs');
      expect(unitCountNoun('Keg', 1.0), 'keg');
    });

    test('no unit (null, blank or Other) counts in units', () {
      expect(unitCountNoun(null, 1), 'unit');
      expect(unitCountNoun(null, 5), 'units');
      expect(unitCountNoun('', 2), 'units');
      expect(unitCountNoun('  ', 1), 'unit');
      expect(unitCountNoun('Other', 3), 'units');
    });
  });

  group('productDisplayName shows the label, not the stored unit', () {
    test('Bottle Goldberg reads Bottle Crate Goldberg', () {
      expect(
        productDisplayName('Goldberg', null, unit: 'Bottle'),
        'Bottle Crate Goldberg',
      );
      expect(
        productDisplayName('Goldberg', 'big', unit: 'Bottle'),
        'Bottle Crate Goldberg (B)',
      );
    });

    test('other units are unchanged', () {
      expect(productDisplayName('Goldberg', null, unit: 'Can'), 'Can Goldberg');
      expect(
        productDisplayName('Goldberg', 'medium', unit: 'Crate'),
        'Crate Goldberg (M)',
      );
    });
  });

  group('plain Crate is hidden for new products', () {
    test('only Crate is hidden', () {
      expect(isUnitHiddenForNewProducts('Crate'), isTrue);
      expect(isUnitHiddenForNewProducts('crate'), isTrue);
      for (final u in kProductUnits.where((u) => u != 'Crate')) {
        expect(isUnitHiddenForNewProducts(u), isFalse, reason: u);
      }
    });

    test('a new product is offered every unit but Crate, Bottle included', () {
      final choices = unitChoices(kProductUnits);
      expect(choices, isNot(contains('Crate')));
      expect(choices, contains('Bottle'));
      expect(choices, hasLength(kProductUnits.length - 1));
    });

    test('a product saved as Crate keeps it on offer', () {
      expect(unitChoices(kProductUnits, keep: ['Crate']), contains('Crate'));
      expect(
        unitChoices(kProductUnits, keep: [null, 'Pack']),
        isNot(contains('Crate')),
      );
    });

    test('Crate stays a valid saved value', () {
      expect(kProductUnits, contains('Crate'));
    });
  });
}
