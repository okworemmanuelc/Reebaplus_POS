import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/product_name.dart';
import 'package:reebaplus_pos/core/utils/product_unit.dart';

/// #487: in a shop that counts empty crates (`crates: true`) a stored `Bottle`
/// reads "Bottle Crate" everywhere a unit is shown; every other shop
/// (`crates: false`: a pharmacy's bottle of syrup, a supermarket's bottle of
/// oil) keeps "Bottle". The saved value never changes either way, and plain
/// `Crate` is not offered to a new product.
void main() {
  group('unitLabel, a shop that counts crates', () {
    test('a stored Bottle reads "Bottle Crate", in any case', () {
      expect(unitLabel('Bottle', crates: true), 'Bottle Crate');
      expect(unitLabel('bottle', crates: true), 'Bottle Crate');
      expect(unitLabel('BOTTLE', crates: true), 'Bottle Crate');
    });

    test('every other unit is unchanged', () {
      for (final u in kProductUnits.where((u) => u != 'Bottle')) {
        expect(unitLabel(u, crates: true), u, reason: u);
      }
      expect(unitLabel('Plate', crates: true), 'Plate');
    });

    test('no unit stays no unit', () {
      expect(unitLabel(null, crates: true), isNull);
      expect(unitLabel('', crates: true), '');
    });
  });

  group('unitLabel, a shop that does not count crates', () {
    test('a stored Bottle stays "Bottle"', () {
      expect(unitLabel('Bottle', crates: false), 'Bottle');
      expect(unitLabel('bottle', crates: false), 'bottle');
    });

    test('every unit is unchanged', () {
      for (final u in kProductUnits) {
        expect(unitLabel(u, crates: false), u, reason: u);
      }
    });

    test('no unit stays no unit', () {
      expect(unitLabel(null, crates: false), isNull);
      expect(unitLabel('', crates: false), '');
    });
  });

  group('unitCountNoun', () {
    test('a Bottle product counts in crates in a crate shop', () {
      expect(unitCountNoun('Bottle', 1, crates: true), 'crate');
      expect(unitCountNoun('Bottle', 0, crates: true), 'crates');
      expect(unitCountNoun('Bottle', 12, crates: true), 'crates');
      expect(unitCountNoun('bottle', 2, crates: true), 'crates');
    });

    test('a Bottle product counts in bottles everywhere else', () {
      expect(unitCountNoun('Bottle', 1, crates: false), 'bottle');
      expect(unitCountNoun('Bottle', 0, crates: false), 'bottles');
      expect(unitCountNoun('Bottle', 12, crates: false), 'bottles');
      expect(unitCountNoun('bottle', 2, crates: false), 'bottles');
    });

    test('other units are their own lower-case name, in either shop', () {
      for (final crates in [true, false]) {
        expect(unitCountNoun('Pack', 1, crates: crates), 'pack');
        expect(unitCountNoun('Pack', 3, crates: crates), 'packs');
        expect(unitCountNoun('PET', 2, crates: crates), 'pets');
        expect(unitCountNoun('Crate', 1, crates: crates), 'crate');
        expect(unitCountNoun('Crate', 4, crates: crates), 'crates');
      }
    });

    test('-s, -x, -ch and -sh units take "es"', () {
      expect(unitCountNoun('Box', 2, crates: true), 'boxes');
      expect(unitCountNoun('Glass', 2, crates: true), 'glasses');
      expect(unitCountNoun('Pouch', 2, crates: false), 'pouches');
      expect(unitCountNoun('Dish', 2, crates: false), 'dishes');
      expect(unitCountNoun('Box', 1, crates: true), 'box');
    });

    test('a fraction is plural', () {
      expect(unitCountNoun('Keg', 1.5, crates: true), 'kegs');
      expect(unitCountNoun('Keg', 1.0, crates: true), 'keg');
      expect(unitCountNoun('Bottle', 1.5, crates: false), 'bottles');
    });

    test('no unit (null, blank or Other) counts in units', () {
      for (final crates in [true, false]) {
        expect(unitCountNoun(null, 1, crates: crates), 'unit');
        expect(unitCountNoun(null, 5, crates: crates), 'units');
        expect(unitCountNoun('', 2, crates: crates), 'units');
        expect(unitCountNoun('  ', 1, crates: crates), 'unit');
        expect(unitCountNoun('Other', 3, crates: crates), 'units');
      }
    });
  });

  group('productDisplayName shows the label, not the stored unit', () {
    test('a crate shop: Bottle Goldberg reads Bottle Crate Goldberg', () {
      expect(
        productDisplayName('Goldberg', null, unit: 'Bottle', crates: true),
        'Bottle Crate Goldberg',
      );
      expect(
        productDisplayName('Goldberg', 'big', unit: 'Bottle', crates: true),
        'Bottle Crate Goldberg (B)',
      );
    });

    test('any other shop: Bottle Cough Syrup stays Bottle Cough Syrup', () {
      expect(
        productDisplayName('Cough Syrup', null, unit: 'Bottle', crates: false),
        'Bottle Cough Syrup',
      );
      expect(
        productDisplayName('Palm Oil', 'big', unit: 'Bottle', crates: false),
        'Bottle Palm Oil (B)',
      );
    });

    test('other units are unchanged, in either shop', () {
      for (final crates in [true, false]) {
        expect(
          productDisplayName('Goldberg', null, unit: 'Can', crates: crates),
          'Can Goldberg',
        );
        expect(
          productDisplayName(
            'Goldberg',
            'medium',
            unit: 'Crate',
            crates: crates,
          ),
          'Crate Goldberg (M)',
        );
      }
    });
  });

  group('plain Crate is hidden for new products (every shop)', () {
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

    // #490: every unit the form offers must pass the products.unit CHECK.
    test('every offered unit is one the database accepts', () {
      for (final u in {...kGenericUnits, ...kCrateUnits}) {
        expect(kProductUnits, contains(u), reason: u);
      }
    });

    test(
      'saved units (Sachet, Tin, Crate...) stay valid and keep showing in unitChoices (#492 G3)',
      () {
        expect(unitChoices(kGenericUnits, keep: ['Crate']), contains('Crate'));
        expect(
          unitChoices(kGenericUnits, keep: ['Sachet']),
          contains('Sachet'),
        );
        expect(unitChoices(kGenericUnits, keep: ['Tin']), contains('Tin'));
        expect(
          unitChoices(kGenericUnits, keep: ['sachet']),
          contains('sachet'),
        );
      },
    );
  });
}
