// Lexicon seam (issue #80, ADR 0015). The Lexicon is the app-shipped set of an
// Industry's domain nouns (item/unit/category) + starter presets, resolved by
// `lexiconFor(industry)`. These tests exercise the pure lookup through the
// registry seam: the words each Industry yields, the generic per-slot fallback,
// and — critically — that Beverage reproduces today's wording (no regression).

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/industry/industry.dart';
import 'package:reebaplus_pos/core/industry/lexicon.dart';

void main() {
  group('Lexicon — no regression for Beverage', () {
    test('reproduces the current product-form wording verbatim', () {
      final lex = lexiconFor(Industry.beverage);
      expect(lex.item, 'Product'); // "Product Name" label
      expect(lex.itemNameHint, 'Eva water 75cl');
      expect(lex.itemDescriptionHint, 'sparkling water');
      expect(lex.unit, 'Bottle');
      expect(lex.starterUnits, contains('Crate'));
    });

    test('Bar shares the beverage lexicon', () {
      expect(lexiconFor(Industry.bar), same(lexiconFor(Industry.beverage)));
    });
  });

  group('Lexicon — the item noun morphs per trade', () {
    test('each industry names a sellable item in its own words', () {
      expect(lexiconFor(Industry.pharmacy).item, 'Medicine');
      expect(lexiconFor(Industry.phoneAndGadgets).item, 'Handset');
      expect(lexiconFor(Industry.buildingMaterials).item, 'Material');
      expect(lexiconFor(Industry.boutique).item, 'Item');
      expect(lexiconFor(Industry.restaurant).item, 'Item');
    });

    test('itemPlural pluralises the item noun for headings (#81)', () {
      expect(lexiconFor(Industry.beverage).itemPlural, 'Products');
      expect(lexiconFor(Industry.pharmacy).itemPlural, 'Medicines');
      expect(lexiconFor(Industry.phoneAndGadgets).itemPlural, 'Handsets');
      expect(lexiconFor(Industry.generic).itemPlural, 'Products');
    });

    test('resolves through the registry: industryOf → lexicon', () {
      // The UI path: stored type → industryOf → lexiconFor.
      expect(lexiconFor(industryOf('Pharmacy')).item, 'Medicine');
      expect(lexiconFor(industryOf('Phone & Gadgets')).item, 'Handset');
      expect(lexiconFor(industryOf('Beverage distributor')).itemNameHint,
          'Eva water 75cl');
    });
  });

  group('Lexicon — generic fallback', () {
    test('generic Industry yields the neutral defaults', () {
      final lex = lexiconFor(Industry.generic);
      expect(lex.item, 'Product');
      expect(lex.unit, 'Piece');
      expect(lex.category, 'Category');
      expect(lex.starterCategories, isNotEmpty);
    });

    test('an unfilled slot falls back to the generic word (per-slot fallback)',
        () {
      // Supermarket customises units/categories but not `category`, so the slot
      // resolves to the generic default rather than being blank.
      expect(lexiconFor(Industry.supermarket).category, 'Category');
    });
  });

  group('Lexicon — totality', () {
    test('every Industry resolves to a fully-populated Lexicon', () {
      for (final ind in Industry.values) {
        final lex = lexiconFor(ind);
        expect(lex.item, isNotEmpty, reason: '$ind item');
        expect(lex.unit, isNotEmpty, reason: '$ind unit');
        expect(lex.category, isNotEmpty, reason: '$ind category');
        expect(lex.starterUnits, isNotEmpty, reason: '$ind starterUnits');
        expect(lex.starterCategories, isNotEmpty, reason: '$ind starterCategories');
        expect(lex.itemNameHint, isNotEmpty, reason: '$ind itemNameHint');
      }
    });
  });
}
