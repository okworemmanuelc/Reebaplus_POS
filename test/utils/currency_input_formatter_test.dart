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

/// Simulates an in-place edit: the field currently shows [oldText]; the user's
/// keystroke produced [newText] with the caret now at [newCaret]. Returns the
/// value the field would end up with (reformatted text + resolved caret).
TextEditingValue editAt(
  CurrencyInputFormatter f, {
  required String oldText,
  required String newText,
  required int newCaret,
}) {
  return f.formatEditUpdate(
    TextEditingValue(text: oldText),
    TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCaret),
    ),
  );
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

  group('CurrencyInputFormatter caret preservation (mid-string edits)', () {
    final f = CurrencyInputFormatter();

    test('typing in the middle keeps the caret next to the inserted digit', () {
      // Field shows "1,500"; caret placed right after the "1"; user types "2".
      final out = editAt(f, oldText: '1,500', newText: '12,500', newCaret: 2);
      expect(out.text, '12,500');
      // Caret stays just after the digit the user typed, not slammed to the end.
      expect(out.selection.baseOffset, 2);
    });

    test('caret hops over a newly inserted grouping comma', () {
      // "500" + "2" after the first digit => "5,200"; caret follows the "2".
      final out = editAt(f, oldText: '500', newText: '5200', newCaret: 2);
      expect(out.text, '5,200');
      expect(out.selection.baseOffset, 3); // after "5,2"
    });

    test('deleting a middle digit keeps the caret in place', () {
      // "12,500" with the "2" removed => "1,500"; caret rests after the "1".
      final out = editAt(f, oldText: '12,500', newText: '1,500', newCaret: 1);
      expect(out.text, '1,500');
      expect(out.selection.baseOffset, 1);
    });

    test('caret at the start stays at the start', () {
      final out = editAt(f, oldText: '500', newText: '500', newCaret: 0);
      expect(out.selection.baseOffset, 0);
    });

    test('caret at the end still lands at the end', () {
      final out = editAt(f, oldText: '1,50', newText: '1,500', newCaret: 5);
      expect(out.text, '1,500');
      expect(out.selection.baseOffset, 5);
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
