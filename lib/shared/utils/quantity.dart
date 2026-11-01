// Shared quantity + money helpers for quarter quantities (#620 / #627).
//
// Quantities (stock, sale lines, crates, cost layers) are stored as doubles in
// steps of 0.25. Quarters are exact binary fractions, so sums and differences
// of quantities stay exact. This file is the ONE place that:
//   * parses / validates a typed or synced quantity ([Qty]),
//   * formats it for screens, receipts and reports ([formatQty]),
//   * turns `unit price x quantity` into whole kobo ([lineTotalKobo]).
//
// SQL twins live in supabase/migrations/0239_quarter_quantities.sql
// (`public.qty_is_quarter`, `public.line_total_kobo`) and MUST agree with the
// rules below.

import 'package:intl/intl.dart' show NumberFormat;

/// Smallest quantity step: a quarter.
const double kQtyStep = 0.25;

/// Quantity parsing + validation (quarter steps, never negative).
class Qty {
  const Qty._();

  /// True when [value] is finite and an exact multiple of [kQtyStep]
  /// (0, 0.25, 0.5, 0.75, 1, ... and negative multiples, for deltas).
  static bool isQuarterStep(double value) {
    if (!value.isFinite) return false;
    final scaled = value * 4;
    return scaled == scaled.roundToDouble();
  }

  /// True when [value] has no fractional part (5, 5.0).
  static bool isWhole(double value) =>
      value.isFinite && value == value.roundToDouble();

  /// Parses typed text such as `12`, `0.5`, `1,5`, `.25`, ` 3 `.
  ///
  /// Returns null when the text is empty, not a number, negative, or not on a
  /// quarter step (`0.3`, `1.1`). `0` is accepted unless [allowZero] is false.
  static double? parse(String? raw, {bool allowZero = true}) {
    if (raw == null) return null;
    var text = raw.trim().replaceAll(',', '.');
    if (text.isEmpty) return null;
    // `1.` is a number still being typed; Dart's parser refuses it.
    if (text.endsWith('.') && text != '.') text = '${text}0';
    // Digits with an optional single decimal part; no sign, no exponent, so
    // `-1`, `1e3` and `0x10` are rejected up front.
    if (!RegExp(r'^(\d+(\.\d*)?|\.\d+)$').hasMatch(text)) return null;
    final value = double.tryParse(text);
    if (value == null) return null;
    return validate(value, allowZero: allowZero);
  }

  /// Returns [value] when it is a valid (>= 0, quarter-step) quantity, else
  /// null. `0` is accepted unless [allowZero] is false.
  static double? validate(double value, {bool allowZero = true}) {
    if (!isQuarterStep(value)) return null;
    if (value < 0) return null;
    if (value == 0 && !allowZero) return null;
    return value;
  }

  /// The smallest amount a line can move by: a quarter, or one whole unit for
  /// a product whose "Allow part quantities" switch is off (#628).
  static double stepFor({required bool allowParts}) =>
      allowParts ? kQtyStep : 1;

  /// Typed sale quantity for a line. Null when [raw] is not a positive quarter
  /// step, or is a fraction on a whole-numbers-only product.
  static double? parseSale(String? raw, {required bool allowParts}) {
    final value = parse(raw, allowZero: false);
    if (value == null) return null;
    return allowParts || isWhole(value) ? value : null;
  }

  /// [value] rounded DOWN onto the line's step: `snapDown(1.3, parts)` is 1.25,
  /// `snapDown(1.75, whole only)` is 1. Quantity is never rounded up, so a
  /// snapped line can never pass the stock it was capped at.
  static double snapDown(double value, {required bool allowParts}) {
    final step = stepFor(allowParts: allowParts);
    return (value / step).floorToDouble() * step;
  }

  /// What can be sold of [stock]: all of it in parts, or only the whole units
  /// (1.5 in stock is 1 for a whole-numbers-only product).
  static double sellable(double stock, {required bool allowParts}) =>
      snapDown(stock, allowParts: allowParts);

  /// Reads a quantity from a JSON / DB value: `5`, `5.0`, `0.5` or numeric
  /// text. Null / unparsable input yields [fallback]. No step validation (the
  /// cloud CHECK is the authority); it never throws.
  static double fromJson(Object? json, {double fallback = 0}) {
    if (json is num) return json.toDouble();
    if (json is String) return double.tryParse(json.trim()) ?? fallback;
    return fallback;
  }

  /// JSON-safe form of [value]: an `int` when whole (`5`, never `5.0`), the
  /// double otherwise. Keeps payloads readable by older app versions and by
  /// integer RPC casts.
  static Object toJson(double value) =>
      isWhole(value) && value.abs() < 9007199254740992
      ? value.toInt()
      : value;
}

/// Display text for a quantity: no trailing zeros, never a vulgar-fraction
/// character (thermal printers cannot print them): `12`, `0.5`, `1.5`,
/// `0.25`, `2.75`, `-0.5`.
String formatQty(num value) {
  final v = value.toDouble();
  if (!v.isFinite) return '0';
  if (Qty.isWhole(v)) return v.toInt().toString();
  // At most two decimals (quarters), trimmed: 1.50 -> 1.5, 0.25 stays.
  var text = v.toStringAsFixed(2);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '');
    text = text.replaceFirst(RegExp(r'\.$'), '');
  }
  return text == '-0' ? '0' : text;
}

/// [formatQty] with thousands separators, for report figures: `1,250.5`.
String formatQtyGrouped(num value) =>
    NumberFormat('#,##0.##', 'en_US').format(value);

/// Line total in whole kobo: `unitKobo x qty`, rounded to the nearest kobo
/// with halves rounded away from zero (half-up for sales; refunds mirror it).
///
/// Quarter quantities times an integer price are exact in a double, so the
/// only rounding is the final `.round()`. SQL twin: `public.line_total_kobo`.
int lineTotalKobo(int unitKobo, double qty) => (unitKobo * qty).round();
