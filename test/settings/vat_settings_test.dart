import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/settings/vat_settings.dart';

void main() {
  group('computeVatKobo', () {
    test('7.5% of ₦175,000 (17,500,000 kobo) = ₦13,125', () {
      // 17_500_000 * 750 / 10000 = 1_312_500 kobo = ₦13,125.
      expect(computeVatKobo(17500000, 750), 1312500);
    });

    test('rounds half-away-from-zero to the nearest kobo', () {
      // 100 * 750 / 10000 = 7.5 → 8.
      expect(computeVatKobo(100, 750), 8);
    });

    test('zero rate yields no VAT even on a positive base', () {
      expect(computeVatKobo(50000, 0), 0);
    });

    test('non-positive base yields no VAT', () {
      expect(computeVatKobo(0, 750), 0);
      expect(computeVatKobo(-100, 750), 0);
    });
  });

  group('parseVatRateBps', () {
    test('parses a plain integer bps string', () {
      expect(parseVatRateBps('750'), 750);
    });

    test('blank, null or malformed → 0', () {
      expect(parseVatRateBps(null), 0);
      expect(parseVatRateBps(''), 0);
      expect(parseVatRateBps('abc'), 0);
      expect(parseVatRateBps('-5'), 0);
    });
  });

  group('VatConfig', () {
    test('off is disabled with a zero rate', () {
      expect(VatConfig.off.enabled, isFalse);
      expect(VatConfig.off.rateBps, 0);
    });

    test('ratePercentLabel trims a trailing .0', () {
      expect(const VatConfig(enabled: true, rateBps: 750).ratePercentLabel, '7.5');
      expect(const VatConfig(enabled: true, rateBps: 2000).ratePercentLabel, '20');
      expect(const VatConfig(enabled: true, rateBps: 500).ratePercentLabel, '5');
    });
  });
}
