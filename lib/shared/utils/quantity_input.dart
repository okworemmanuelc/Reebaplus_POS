// Typed-quantity helpers for stock screens (#620 / #630): the input filter, the
// product-switch-aware parse and the error wording, so Receive Stock, stock
// adjustments, transfers and counts all behave the same.
//
// Parsing and validation stay in `quantity.dart` ([Qty]); this file only adds
// the product's `allow_fractional_sales` switch on top: switch off means whole
// numbers only, switch on means quarter steps (0.25, 0.5, 0.75, ...).

import 'package:flutter/services.dart';
import 'package:reebaplus_pos/shared/utils/quantity.dart';

/// Parses a typed stock quantity, honouring the product's parts switch.
///
/// Returns null for empty / non-numeric text, anything off the quarter step,
/// and (when [allowParts] is false) any part quantity such as `0.5`.
double? parseStockQty(
  String? raw, {
  required bool allowParts,
  bool allowZero = true,
}) {
  final value = Qty.parse(raw, allowZero: allowZero);
  if (value == null) return null;
  if (!allowParts && !Qty.isWhole(value)) return null;
  return value;
}

/// True when [value] may be stored for a product with this switch.
bool stockQtyAllowed(double value, {required bool allowParts}) =>
    Qty.validate(value) != null && (allowParts || Qty.isWhole(value));

/// Why [raw] was rejected, in shop-owner words. Call only when
/// [parseStockQty] returned null for non-empty text.
String stockQtyError(String? raw, {required bool allowParts}) {
  final parsed = Qty.parse(raw);
  if (parsed != null && !allowParts && !Qty.isWhole(parsed)) {
    return 'This product is sold in whole numbers only.';
  }
  return allowParts
      ? 'Use whole numbers or quarters (0.25, 0.5, 0.75).'
      : 'Enter a whole number.';
}

/// Keyboard for a stock quantity field.
TextInputType stockQtyKeyboard({required bool allowParts}) =>
    TextInputType.numberWithOptions(decimal: allowParts);

/// Input filter for a stock quantity field: digits only when parts are off,
/// else digits with one `.` / `,` and at most two decimals.
List<TextInputFormatter> stockQtyFormatters({required bool allowParts}) =>
    allowParts
    ? [FilteringTextInputFormatter.allow(RegExp(r'^\d*[.,]?\d{0,2}'))]
    : [FilteringTextInputFormatter.digitsOnly];
