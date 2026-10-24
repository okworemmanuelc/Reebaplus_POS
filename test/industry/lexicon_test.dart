// Lexicon seam (issue #80, ADR 0015, #492 G3).
// Every shop gets "Product" and "Category", plain example hints, no starter
// categories, and no unit filled in by default. The only variation is
// starter units: crate-tracking shops also get PET and Keg.

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/industry/industry.dart';
import 'package:reebaplus_pos/core/industry/lexicon.dart';

void main() {
  group('Lexicon — generic words for every shop (#492 G3)', () {
    test('every industry gets "Product" and "Category"', () {
      for (final ind in Industry.values) {
        final lex = lexiconFor(ind);
        expect(lex.item, 'Product', reason: '$ind item');
        expect(lex.itemPlural, 'Products', reason: '$ind itemPlural');
        expect(lex.category, 'Category', reason: '$ind category');
      }
    });

    test(
      'one set of plain example hints, no starter categories, no unit default',
      () {
        for (final ind in Industry.values) {
          final lex = lexiconFor(ind);
          expect(
            lex.itemNameHint,
            'e.g. Product name',
            reason: '$ind name hint',
          );
          expect(
            lex.itemDescriptionHint,
            'e.g. Short description',
            reason: '$ind desc hint',
          );
          expect(
            lex.starterCategories,
            isEmpty,
            reason: '$ind starter categories',
          );
          expect(lex.unit, isNull, reason: '$ind unit default');
        }
      },
    );

    test(
      'resolves through registry: stored type -> industryOf -> lexiconFor',
      () {
        expect(lexiconFor(industryOf('Pharmacy')).item, 'Product');
        expect(lexiconFor(industryOf('Phone & Gadgets')).item, 'Product');
        expect(
          lexiconFor(industryOf('Beverage distributor')).itemNameHint,
          'e.g. Product name',
        );
        expect(lexiconFor(industryOf('Other custom shop')).item, 'Product');
      },
    );
  });

  group('Lexicon — unit lists (#492 G3)', () {
    test('kGenericUnits has the 10 short units for non-crate shops', () {
      expect(kGenericUnits, [
        'Piece',
        'Pack',
        'Box',
        'Carton',
        'Bag',
        'Bottle',
        'Can',
        'Kg',
        'Litre',
        'Other',
      ]);
    });

    test('kCrateUnits includes PET and Keg for crate shops', () {
      expect(kCrateUnits, [
        'Piece',
        'Pack',
        'Box',
        'Carton',
        'Bag',
        'Bottle',
        'Can',
        'PET',
        'Keg',
        'Kg',
        'Litre',
        'Other',
      ]);
    });

    test('non-crate shops get kGenericUnits', () {
      for (final ind in [
        Industry.pharmacy,
        Industry.supermarket,
        Industry.restaurant,
        Industry.boutique,
        Industry.buildingMaterials,
        Industry.phoneAndGadgets,
        Industry.frozenFoodsAndGrocery,
        Industry.generic,
      ]) {
        final lex = lexiconFor(ind);
        expect(lex.starterUnits, kGenericUnits, reason: '$ind starterUnits');
        expect(lex.starterUnits.contains('PET'), isFalse);
        expect(lex.starterUnits.contains('Keg'), isFalse);
        expect(lex.starterUnits.contains('Crate'), isFalse);
      }
    });

    test('crate shops (Bar and Beverage) get kCrateUnits with PET and Keg', () {
      for (final ind in [Industry.bar, Industry.beverage]) {
        final lex = lexiconFor(ind);
        expect(lex.starterUnits, kCrateUnits, reason: '$ind starterUnits');
        expect(lex.starterUnits.contains('PET'), isTrue);
        expect(lex.starterUnits.contains('Keg'), isTrue);
        expect(lex.starterUnits.contains('Crate'), isFalse);
      }
      expect(lexiconFor(Industry.bar), same(lexiconFor(Industry.beverage)));
    });
  });

  group('Lexicon — totality', () {
    test('every Industry resolves to a valid Lexicon', () {
      for (final ind in Industry.values) {
        final lex = lexiconFor(ind);
        expect(lex.item, isNotEmpty, reason: '$ind item');
        expect(lex.category, isNotEmpty, reason: '$ind category');
        expect(lex.starterUnits, isNotEmpty, reason: '$ind starterUnits');
        expect(lex.itemNameHint, isNotEmpty, reason: '$ind itemNameHint');
        expect(
          lex.itemDescriptionHint,
          isNotEmpty,
          reason: '$ind itemDescriptionHint',
        );
      }
    });
  });
}
