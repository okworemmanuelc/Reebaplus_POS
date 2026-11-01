import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/shared/utils/quantity_input.dart';

/// Typed stock quantities (#630): quarter steps when the product's parts
/// switch is on, whole numbers when it is off.
void main() {
  group('parseStockQty', () {
    test('parts on: whole numbers and quarters pass', () {
      for (final (raw, want) in [
        ('5', 5.0),
        ('0.25', 0.25),
        ('.5', 0.5),
        ('1,5', 1.5),
        ('2.75', 2.75),
        ('0', 0.0),
      ]) {
        expect(parseStockQty(raw, allowParts: true), want, reason: raw);
      }
    });

    test('parts on: off-quarter, negative and junk are rejected', () {
      for (final raw in ['0.3', '1.1', '-1', 'abc', '', '1e3', '0.125']) {
        expect(parseStockQty(raw, allowParts: true), isNull, reason: raw);
      }
    });

    test('parts off: a part quantity is rejected, whole numbers pass', () {
      expect(parseStockQty('0.5', allowParts: false), isNull);
      expect(parseStockQty('1.25', allowParts: false), isNull);
      expect(parseStockQty('3', allowParts: false), 3);
      // 2.0 typed with a dot is still a whole number.
      expect(parseStockQty('2.0', allowParts: false), 2);
    });

    test('allowZero false rejects 0 on both switches', () {
      expect(parseStockQty('0', allowParts: true, allowZero: false), isNull);
      expect(parseStockQty('0', allowParts: false, allowZero: false), isNull);
    });
  });

  test('stockQtyAllowed mirrors the switch', () {
    expect(stockQtyAllowed(0.5, allowParts: true), isTrue);
    expect(stockQtyAllowed(0.5, allowParts: false), isFalse);
    expect(stockQtyAllowed(0.3, allowParts: true), isFalse);
    expect(stockQtyAllowed(4, allowParts: false), isTrue);
  });

  test('error wording tells the owner what to do', () {
    expect(
      stockQtyError('0.5', allowParts: false),
      contains('whole numbers only'),
    );
    expect(stockQtyError('0.3', allowParts: true), contains('quarters'));
    expect(stockQtyError('x', allowParts: false), 'Enter a whole number.');
  });

  group('stockQtyFormatters', () {
    String type(bool parts, String text) {
      var value = TextEditingValue.empty;
      for (final formatter in stockQtyFormatters(allowParts: parts)) {
        value = formatter.formatEditUpdate(
          TextEditingValue.empty,
          TextEditingValue(text: text),
        );
      }
      return value.text;
    }

    test('parts on keeps one dot and at most two decimals', () {
      expect(type(true, '1.25'), '1.25');
      expect(type(true, '0.5'), '0.5');
      expect(type(true, '1.255'), '1.25');
      expect(type(true, '1.2.5'), '1.2');
      expect(type(true, '12'), '12');
    });

    test('parts off keeps digits only', () {
      expect(type(false, '1.5'), '15');
      expect(type(false, '12'), '12');
    });

    test('keyboard shows a decimal point only with parts', () {
      expect(stockQtyKeyboard(allowParts: true).decimal, isTrue);
      expect(stockQtyKeyboard(allowParts: false).decimal, isFalse);
    });
  });
}
