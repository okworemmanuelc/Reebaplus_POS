import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/product_name.dart';
import 'package:reebaplus_pos/core/utils/product_unit.dart';

/// #675 (supersedes the #487 "Bottle Crate" wording): a stored unit is shown
/// and counted by its own name in every shop — "Bottle" / "3 bottles", never
/// "Bottle Crate" / "3 crates". The saved value never changes, and plain
/// `Crate` is not offered to a new product.
void main() {
  group('unitLabel', () {
    test('a stored Bottle reads "Bottle", never "Bottle Crate"', () {
      expect(unitLabel('Bottle'), 'Bottle');
      expect(unitLabel('bottle'), 'bottle');
    });

    test('every unit is unchanged', () {
      for (final u in kProductUnits) {
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
    test('a Bottle product counts in bottles, never crates', () {
      expect(unitCountNoun('Bottle', 1), 'bottle');
      expect(unitCountNoun('Bottle', 0), 'bottles');
      expect(unitCountNoun('Bottle', 12), 'bottles');
      expect(unitCountNoun('bottle', 2), 'bottles');
    });

    test('other units are their own lower-case name', () {
      expect(unitCountNoun('Pack', 1), 'pack');
      expect(unitCountNoun('Pack', 3), 'packs');
      expect(unitCountNoun('Can', 3), 'cans');
      expect(unitCountNoun('PET', 2), 'pets');
      expect(unitCountNoun('Carton', 2), 'cartons');
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
      expect(unitCountNoun('Bottle', 1.5), 'bottles');
    });

    test('no unit (null, blank or Other) counts in units', () {
      expect(unitCountNoun(null, 1), 'unit');
      expect(unitCountNoun(null, 5), 'units');
      expect(unitCountNoun('', 2), 'units');
      expect(unitCountNoun('  ', 1), 'unit');
      expect(unitCountNoun('Other', 3), 'units');
    });
  });

  group('productDisplayName never shows the unit or size', () {
    test('Bottle Heineken reads just Heineken', () {
      expect(productDisplayName('Heineken'), 'Heineken');
    });

    test('a size typed into the name stays as typed', () {
      expect(productDisplayName('Goldberg 60cl'), 'Goldberg 60cl');
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

  test('productDisplayName name-cases names saved before #507', () {
    expect(
      productDisplayName('STAR lager 60CL'),
      'Star Lager 60CL',
    );
  });
}
