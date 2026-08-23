// cart_crate_lines_test.dart
//
// The rules the cart reads crates by, tested without a widget harness.
// These decide which lines carry a crate deposit and which of those have no
// crate value configured — the condition the cart's warning banner renders on.

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/crates/cart_crate_lines.dart';

Map<String, dynamic> line({
  required String name,
  String? unit = 'Bottle',
  bool trackEmpties = true,
  int? crateValueKobo = 50000,
}) => {
  'name': name,
  'unit': unit,
  'trackEmpties': trackEmpties,
  'emptyCrateValueKobo': crateValueKobo,
};

void main() {
  group('lineBearsCrates', () {
    test('a bottle that tracks empties bears crates', () {
      expect(lineBearsCrates(line(name: 'Star')), isTrue);
    });

    test('casing of the unit does not matter', () {
      expect(lineBearsCrates(line(name: 'Star', unit: 'bottle')), isTrue);
      expect(lineBearsCrates(line(name: 'Star', unit: 'BOTTLE')), isTrue);
    });

    test('a bottle with tracking off does not', () {
      expect(
        lineBearsCrates(line(name: 'Star', trackEmpties: false)),
        isFalse,
      );
    });

    test('a non-bottle unit does not, even with tracking on', () {
      // PET / packs must never leak into a crate count.
      expect(lineBearsCrates(line(name: 'Water', unit: 'Pack')), isFalse);
    });

    test('a null unit is "not a bottle" (#108), not a default bottle', () {
      expect(lineBearsCrates(line(name: 'Loose', unit: null)), isFalse);
    });

    test('a Quick-Sale line carrying no crate fields at all does not', () {
      expect(lineBearsCrates({'name': 'Quick Sale', 'price': 500.0}), isFalse);
    });
  });

  group('crateBearingLines', () {
    test('a non-crate business yields nothing, even holding bottles', () {
      // Rule #13: a legacy bottle product on, say, a Pharmacy must not pull
      // crate features into a business that has none.
      expect(
        crateBearingLines([line(name: 'Star')], isCrate: false),
        isEmpty,
      );
    });

    test('a mixed cart keeps only the crate-bearing lines, in order', () {
      final items = [
        line(name: 'Star'),
        line(name: 'Water', unit: 'Pack'),
        line(name: 'Gulder'),
        {'name': 'Quick Sale', 'price': 500.0},
      ];
      expect(
        crateBearingLines(items, isCrate: true).map((l) => l['name']),
        ['Star', 'Gulder'],
      );
    });
  });

  group('unconfiguredCrateValueProducts', () {
    test('a configured crate value raises nothing', () {
      expect(
        unconfiguredCrateValueProducts([line(name: 'Star')]),
        isEmpty,
      );
    });

    test('zero, negative and missing all count as unconfigured', () {
      final flagged = unconfiguredCrateValueProducts([
        line(name: 'Zero', crateValueKobo: 0),
        line(name: 'Negative', crateValueKobo: -1),
        line(name: 'Missing', crateValueKobo: null),
      ]);
      expect(flagged, ['Missing', 'Negative', 'Zero']);
    });

    test('names are deduplicated and sorted for a stable banner', () {
      final flagged = unconfiguredCrateValueProducts([
        line(name: 'Star', crateValueKobo: 0),
        line(name: 'Gulder', crateValueKobo: 0),
        line(name: 'Star', crateValueKobo: 0),
      ]);
      expect(flagged, ['Gulder', 'Star']);
    });

    test('only the unconfigured lines of a mixed set are named', () {
      final flagged = unconfiguredCrateValueProducts([
        line(name: 'Star'),
        line(name: 'Gulder', crateValueKobo: 0),
      ]);
      expect(flagged, ['Gulder']);
    });
  });
}
