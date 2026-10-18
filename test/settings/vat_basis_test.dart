import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/settings/vat_settings.dart';

/// #176 (PRD #155 story 31) — VAT inclusive/exclusive basis (inclusive default).
/// The exclusive formula (`base × rate`) overstates the liability by (1+r) for a
/// shop whose marked prices already INCLUDE VAT; inclusive computes the VAT
/// portion WITHIN the recorded takings (`base × rate / (1 + rate)`).
void main() {
  group('computeVatKobo — basis', () {
    test('exclusive: VAT is added on top of the net base', () {
      // ₦100,000 @ 7.5% exclusive → ₦7,500.
      expect(
        computeVatKobo(10000000, 750, basis: VatBasis.exclusive),
        750000,
      );
    });

    test('inclusive: VAT is the portion within VAT-inclusive takings', () {
      // ₦100,000 @ 7.5% inclusive → 100,000 × 750 / 10,750 = ₦6,976.74 → ₦6,977.
      expect(
        computeVatKobo(10000000, 750, basis: VatBasis.inclusive),
        697674,
      );
    });

    test('inclusive is the default when no basis is passed', () {
      expect(computeVatKobo(10000000, 750),
          computeVatKobo(10000000, 750, basis: VatBasis.inclusive));
    });

    test('inclusive is always ≤ exclusive for the same base + rate', () {
      final incl = computeVatKobo(5000000, 2000, basis: VatBasis.inclusive);
      final excl = computeVatKobo(5000000, 2000, basis: VatBasis.exclusive);
      expect(incl, lessThan(excl));
    });

    test('a non-positive base or rate yields no VAT on either basis', () {
      expect(computeVatKobo(0, 750, basis: VatBasis.inclusive), 0);
      expect(computeVatKobo(0, 750, basis: VatBasis.exclusive), 0);
      expect(computeVatKobo(10000000, 0, basis: VatBasis.inclusive), 0);
      expect(computeVatKobo(-100, 750, basis: VatBasis.exclusive), 0);
    });
  });

  group('parseVatBasis — inclusive default', () {
    test('"exclusive" parses to exclusive', () {
      expect(parseVatBasis('exclusive'), VatBasis.exclusive);
      expect(parseVatBasis('  EXCLUSIVE '), VatBasis.exclusive);
    });

    test('"inclusive" parses to inclusive', () {
      expect(parseVatBasis('inclusive'), VatBasis.inclusive);
    });

    test('absent / blank / unknown defaults to inclusive', () {
      expect(parseVatBasis(null), VatBasis.inclusive);
      expect(parseVatBasis(''), VatBasis.inclusive);
      expect(parseVatBasis('nonsense'), VatBasis.inclusive);
    });
  });

  group('VatConfig', () {
    test('defaults to the inclusive basis', () {
      const c = VatConfig(enabled: true, rateBps: 750);
      expect(c.basis, VatBasis.inclusive);
      expect(c.basisLabel, 'inclusive');
    });

    test('carries an explicit exclusive basis + its label', () {
      const c =
          VatConfig(enabled: true, rateBps: 750, basis: VatBasis.exclusive);
      expect(c.basisLabel, 'exclusive');
    });
  });
}
