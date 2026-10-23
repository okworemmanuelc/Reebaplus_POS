import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/features/inventory/models/fast_add_product_model.dart';
import 'package:reebaplus_pos/features/inventory/models/product_form_rules.dart';

/// #487 PR 2: the Add Product form's words and figures.
void main() {
  group('"how many in one"', () {
    test('a crate shop: Bottle, Pack, Carton and Box take a count', () {
      expect(unitsPerPackLabel('Bottle', crates: true), 'Bottles in one crate');
      expect(unitsPerPackLabel('Pack', crates: true), 'Pieces in one pack');
      expect(unitsPerPackLabel('carton', crates: true), 'Pieces in one carton');
      expect(unitsPerPackLabel('Box', crates: true), 'Pieces in one box');
      expect(unitsPerPackLabel('Can', crates: true), isNull);
      expect(unitsPerPackLabel(null, crates: true), isNull);
    });

    test('any other shop: no box for Bottle; Pack, Carton and Box keep it', () {
      expect(unitsPerPackLabel('Bottle', crates: false), isNull);
      expect(unitTakesPackCount('Bottle', crates: false), isFalse);
      expect(unitsPerPackLabel('Pack', crates: false), 'Pieces in one pack');
    });
  });

  group('unit words', () {
    test('a crate shop reads a Bottle as a crate', () {
      expect(formUnitLabel('Bottle', crates: true), 'Bottle Crate');
      expect(formCountNoun('Bottle', 20, crates: true), 'crates');
      expect(
        pricingSubtitle('Bottle', crates: true),
        'All prices are per crate.',
      );
    });

    test('any other shop reads a Bottle as a bottle', () {
      expect(formUnitLabel('Bottle', crates: false), 'Bottle');
      expect(formCountNoun('Bottle', 1, crates: false), 'bottle');
      expect(formCountNoun('Bottle', 3, crates: false), 'bottles');
      expect(
        pricingSubtitle('Bottle', crates: false),
        'All prices are per bottle.',
      );
    });

    test('no unit: per item', () {
      expect(pricingSubtitle(null, crates: true), 'All prices are per item.');
      expect(pricingSubtitle('  ', crates: false), 'All prices are per item.');
      expect(
        pricingSubtitle('Pack', crates: false),
        'All prices are per pack.',
      );
    });
  });

  group('preview detail line', () {
    test('the pack count and the category', () {
      expect(
        previewDetailLine(
          unit: 'Bottle',
          unitsPerPack: 12,
          category: 'Beer',
          crates: true,
        ),
        'Crate of 12 · Beer',
      );
      expect(
        previewDetailLine(unit: 'Pack', unitsPerPack: 6, crates: false),
        'Pack of 6',
      );
    });

    test('no count: the unit label; nothing at all: empty', () {
      expect(
        previewDetailLine(unit: 'Bottle', category: 'Beer', crates: true),
        'Bottle Crate · Beer',
      );
      expect(previewDetailLine(unit: 'Can', crates: true), 'Can');
      expect(previewDetailLine(unit: null, crates: true), '');
      // A count for a unit without the box is not shown.
      expect(
        previewDetailLine(unit: 'Bottle', unitsPerPack: 12, crates: false),
        'Bottle',
      );
    });
  });

  group('profit', () {
    test('amount and the whole % of the selling price', () {
      final p = productProfit(priceKobo: 1500000, costKobo: 1350000)!;
      expect(p.amountKobo, 150000);
      expect(p.percent, 10);
      expect(p.isLoss, isFalse);
      // 700 / 14,200 = 4.93% → 5%.
      expect(productProfit(priceKobo: 1420000, costKobo: 1350000)!.percent, 5);
    });

    test('a loss is negative', () {
      final p = productProfit(priceKobo: 1300000, costKobo: 1350000)!;
      expect(p.amountKobo, -50000);
      expect(p.percent, -4);
      expect(p.isLoss, isTrue);
    });

    test('no price: no row', () {
      expect(productProfit(priceKobo: 0, costKobo: 100), isNull);
    });
  });
}
