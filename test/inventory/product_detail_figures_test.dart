// #487 PR 3: the plain numbers and words behind Product Details.

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/features/inventory/widgets/product_detail_figures.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/product_tile.dart'
    show StockLevel;

void main() {
  group('productKindLine', () {
    test('a Bottle with a count reads "Crate of 12 bottles"', () {
      expect(
        productKindLine(
          manufacturer: 'Nigerian Breweries',
          unit: 'Bottle',
          unitsPerPack: 12,
        ),
        'Nigerian Breweries · Crate of 12 bottles',
      );
    });

    test('a Bottle with no count reads "Bottle Crate"', () {
      expect(
        productKindLine(manufacturer: 'Guinness Nigeria', unit: 'Bottle'),
        'Guinness Nigeria · Bottle Crate',
      );
      expect(productKindLine(unit: 'Bottle', unitsPerPack: 0), 'Bottle Crate');
    });

    test('one bottle is singular', () {
      expect(
        productKindLine(unit: 'Bottle', unitsPerPack: 1),
        'Crate of 1 bottle',
      );
    });

    test('a Pack, Carton or Box with a count counts pieces', () {
      expect(
        productKindLine(unit: 'Pack', unitsPerPack: 24),
        'Pack of 24 pieces',
      );
      expect(
        productKindLine(unit: 'Carton', unitsPerPack: 6),
        'Carton of 6 pieces',
      );
      expect(
        productKindLine(unit: 'Box', unitsPerPack: 10),
        'Box of 10 pieces',
      );
    });

    test('another unit ignores the count and keeps its own words', () {
      expect(productKindLine(unit: 'Can', unitsPerPack: 6), 'Can');
      expect(productKindLine(unit: 'Crate', unitsPerPack: 12), 'Crate');
    });

    test('missing parts are left out', () {
      expect(productKindLine(), '');
      expect(productKindLine(manufacturer: ' '), '');
      expect(productKindLine(manufacturer: 'Coca-Cola HBC'), 'Coca-Cola HBC');
      expect(productKindLine(unit: ''), '');
    });
  });

  group('profitPercentOfPrice', () {
    test('is (price - cost) / price, rounded', () {
      expect(profitPercentOfPrice(1500000, 1350000), 10);
      expect(profitPercentOfPrice(1420000, 1350000), 5); // 4.93 -> 5
      expect(profitPercentOfPrice(1000, 667), 33);
    });

    test('is negative under cost and 0 with no price', () {
      expect(profitPercentOfPrice(1000, 1250), -25);
      expect(profitPercentOfPrice(0, 500), 0);
    });
  });

  group('stockLevelOf', () {
    test('out at 0, low up to and including the alert, else ok', () {
      expect(stockLevelOf(0, 5), StockLevel.out);
      expect(stockLevelOf(1, 5), StockLevel.low);
      expect(stockLevelOf(5, 5), StockLevel.low);
      expect(stockLevelOf(6, 5), StockLevel.ok);
    });
  });

  group('SalesTargetFigures', () {
    SalesTargetFigures at(DateTime now, {int sold = 136, int target = 200}) =>
        SalesTargetFigures(sold: sold, target: target, now: now);

    test('days left is the last day of the month minus today', () {
      expect(at(DateTime(2026, 10, 23)).daysLeft, 8);
      expect(at(DateTime(2026, 10, 31)).daysLeft, 0);
      expect(at(DateTime(2026, 2, 28)).daysLeft, 0); // 2026 is not a leap year
      expect(at(DateTime(2028, 2, 1)).daysLeft, 28); // 2028 is
      expect(at(DateTime(2026, 12, 25)).daysLeft, 6);
    });

    test('names the month and the days', () {
      expect(at(DateTime(2026, 10, 23)).headline, 'October, 8 days left');
      expect(at(DateTime(2026, 10, 30)).headline, 'October, 1 day left');
      expect(at(DateTime(2026, 10, 31)).headline, 'October, last day');
    });

    test('crates a day rounds up and counts today', () {
      // 64 to go over 8 days left + today = 9 selling days: 7.1 -> 8.
      final f = at(DateTime(2026, 10, 23));
      expect(f.remaining, 64);
      expect(f.perDay, 8);
      // On the last day, everything left is today's.
      expect(at(DateTime(2026, 10, 31)).perDay, 64);
      // 9 left over 3 days (2 left + today) is exactly 3.
      expect(at(DateTime(2026, 10, 29), sold: 191, target: 200).perDay, 3);
    });

    test('percent and the bar', () {
      final f = at(DateTime(2026, 10, 23));
      expect(f.percent, 68);
      expect(f.fraction, closeTo(0.68, 1e-9));
    });

    test('reached: at or over the target', () {
      final met = at(DateTime(2026, 10, 23), sold: 200);
      expect(met.reached, isTrue);
      expect(met.remaining, 0);
      expect(met.perDay, 0);
      final over = at(DateTime(2026, 10, 23), sold: 250);
      expect(over.reached, isTrue);
      expect(over.percent, 125);
      expect(over.fraction, 1.0);
    });

    test('no target: nothing to reach, no bar', () {
      final f = at(DateTime(2026, 10, 23), target: 0);
      expect(f.hasTarget, isFalse);
      expect(f.reached, isFalse);
      expect(f.percent, 0);
      expect(f.fraction, 0.0);
      expect(f.remaining, 0);
    });
  });

  group('expiryPillFor', () {
    final now = DateTime(2026, 10, 23, 15);
    test('expired is danger, soon is warning, later is quiet', () {
      expect(expiryPillFor(DateTime(2026, 10, 22), now), (
        label: 'Expired',
        tone: ExpiryTone.expired,
      ));
      expect(expiryPillFor(DateTime(2026, 10, 23), now), (
        label: 'Expires today',
        tone: ExpiryTone.soon,
      ));
      expect(expiryPillFor(DateTime(2026, 11, 2), now), (
        label: 'Expires in 10d',
        tone: ExpiryTone.soon,
      ));
      expect(expiryPillFor(DateTime(2026, 12, 12), now), (
        label: 'Expires 12 Dec 2026',
        tone: ExpiryTone.later,
      ));
    });
  });
}
