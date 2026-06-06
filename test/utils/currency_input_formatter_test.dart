import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';

/// Runs [f] over [input] as if the user had just typed it, returning the
/// formatted text the field would show.
String fmt(CurrencyInputFormatter f, String input) {
  final out = f.formatEditUpdate(
    const TextEditingValue(text: ''),
    TextEditingValue(
      text: input,
      selection: TextSelection.collapsed(offset: input.length),
    ),
  );
  return out.text;
}

void main() {
  group('CurrencyInputFormatter (money, grouped + decimals)', () {
    final f = CurrencyInputFormatter();

    test('groups the whole part with thousands separators', () {
      expect(fmt(f, '1500'), '1,500');
      expect(fmt(f, '1000000'), '1,000,000');
    });

    test('keeps up to two decimal places', () {
      expect(fmt(f, '1500.5'), '1,500.5');
      expect(fmt(f, '1500.50'), '1,500.50');
    });

    test('caps the fraction at two digits', () {
      expect(fmt(f, '1500.555'), '1,500.55');
    });

    test('preserves an in-progress trailing dot', () {
      expect(fmt(f, '1500.'), '1,500.');
    });

    test('strips letters and stray symbols', () {
      expect(fmt(f, '1a2b3'), '123');
      expect(fmt(f, r'$1,500'), '1,500');
    });

    test('collapses multiple dots to a single decimal point', () {
      expect(fmt(f, '1.2.3'), '1.23');
    });

    test('a leading dot becomes "0."', () {
      expect(fmt(f, '.'), '0.');
      expect(fmt(f, '.5'), '0.5');
    });

    test('empty stays empty', () {
      expect(fmt(f, ''), '');
    });

    test('round-trips through parseCurrency to a decimal value', () {
      expect(parseCurrency(fmt(f, '1500.50')), 1500.50);
      expect(parseCurrency(fmt(f, '1500.')), 1500.0);
    });
  });

  group('CurrencyInputFormatter(grouping: false) (percent / fractional qty)', () {
    final f = CurrencyInputFormatter(grouping: false);

    test('does not insert thousands separators', () {
      expect(fmt(f, '1500'), '1500');
    });

    test('still allows decimals (e.g. 12.5%)', () {
      expect(fmt(f, '12.5'), '12.5');
    });

    test('drops leading zeros but keeps a single zero', () {
      expect(fmt(f, '05'), '5');
      expect(fmt(f, '0.5'), '0.5');
    });

    test('strips non-numeric characters', () {
      expect(fmt(f, '12%'), '12');
    });
  });
}
