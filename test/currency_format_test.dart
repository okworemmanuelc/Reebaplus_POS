import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/data/currencies.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';

void main() {
  group('currencySymbolForCode returns ONLY the glyph', () {
    test('clean ISO codes map to their glyph', () {
      expect(currencySymbolForCode('NGN'), '₦');
      expect(currencySymbolForCode('USD'), r'$');
      expect(currencySymbolForCode('GBP'), '£');
      expect(currencySymbolForCode('GHS'), 'GH₵');
    });

    test('case-insensitive', () {
      expect(currencySymbolForCode('ngn'), '₦');
      expect(currencySymbolForCode('usd'), r'$');
    });

    test('legacy label-style values resolve to the glyph (the bug)', () {
      // Older onboarding stored "NGN (₦)" instead of "NGN"; the display must
      // still be a single clean symbol — no code, no brackets.
      expect(currencySymbolForCode('NGN (₦)'), '₦');
      expect(currencySymbolForCode('Naira (NGN)'), '₦');
      expect(currencySymbolForCode('USD (\$)'), r'$');
      expect(currencySymbolForCode('GHS (GH₵)'), 'GH₵');
    });

    test('null / empty / bare glyph fall back sensibly', () {
      expect(currencySymbolForCode(null), '₦');
      expect(currencySymbolForCode(''), '₦');
      expect(currencySymbolForCode('₦'), '₦');
    });
  });

  group('normalizeCurrencyCode', () {
    test('strips label noise to the bare ISO code', () {
      expect(normalizeCurrencyCode('NGN (₦)'), 'NGN');
      expect(normalizeCurrencyCode('NGN'), 'NGN');
      expect(normalizeCurrencyCode('ghs'), 'GHS');
      expect(normalizeCurrencyCode(null), 'NGN');
    });
  });

  group('formatCurrency follows the active currency', () {
    test('legacy "NGN (₦)" setting still renders a clean ₦ amount', () {
      setActiveCurrencyCode('NGN (₦)');
      expect(formatCurrency(197640), '₦197,640');
      expect(formatCurrency(-10654), '-₦10,654');
    });

    test('glyph currencies have no trailing space', () {
      setActiveCurrencyCode('USD');
      expect(formatCurrency(5000), r'$5,000');
    });

    test('letter-symbol currencies get a separating space', () {
      setActiveCurrencyCode('KES');
      expect(formatCurrency(5000), 'KSh 5,000');
    });

    // Restore the default so other test files see ₦.
    tearDownAll(() => setActiveCurrencyCode('NGN'));
  });
}
