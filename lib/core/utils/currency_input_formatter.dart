import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

/// Formats numeric input as the user types: groups the whole part with thousands
/// separators and allows up to 2 decimal places (e.g. `1500.5` -> `1,500.5`).
///
/// Set [grouping] to false for non-money numeric fields that want decimals but
/// no thousands separators (e.g. a percent discount).
class CurrencyInputFormatter extends TextInputFormatter {
  CurrencyInputFormatter({this.grouping = true, this.decimalDigits = 2});

  final bool grouping;
  final int decimalDigits;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.isEmpty) {
      return newValue.copyWith(text: '');
    }

    // Keep only digits and dots, then collapse to a single decimal point.
    String cleaned = newValue.text.replaceAll(RegExp(r'[^\d.]'), '');
    final firstDot = cleaned.indexOf('.');

    String whole;
    String? fraction; // null = no dot typed yet
    if (firstDot == -1) {
      whole = cleaned;
    } else {
      whole = cleaned.substring(0, firstDot);
      fraction = cleaned.substring(firstDot + 1).replaceAll('.', '');
      if (fraction.length > decimalDigits) {
        fraction = fraction.substring(0, decimalDigits);
      }
    }

    // Group the whole part; an empty whole (leading ".") becomes "0".
    String formattedWhole;
    if (whole.isEmpty) {
      formattedWhole = fraction == null ? '' : '0';
    } else if (grouping) {
      formattedWhole = NumberFormat('#,##0', 'en_US').format(int.parse(whole));
    } else {
      // Drop leading zeros but keep a single "0".
      formattedWhole = whole.replaceFirst(RegExp(r'^0+(?=\d)'), '');
    }

    final newText =
        fraction == null ? formattedWhole : '$formattedWhole.$fraction';

    return newValue.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: newText.length),
    );
  }
}

double parseCurrency(String text) {
  if (text.isEmpty) return 0.0;
  String cleanText = text.replaceAll(',', '');
  return double.tryParse(cleanText) ?? 0.0;
}
