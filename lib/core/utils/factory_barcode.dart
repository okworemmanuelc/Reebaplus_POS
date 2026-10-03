/// A real factory barcode (GTIN), keyed by its GTIN-14 form.
///
/// Decides which barcodes take part in the shared barcode catalogue
/// (ADR 0029 §2, #330). Barcodes stay free text in `products.barcode`; this
/// only says whether a code is shared.
///
/// A code is a factory GTIN when it is:
/// - ASCII digits only, 8, 12, 13 or 14 long, with a valid GS1 mod-10 check
///   digit;
/// - not all zeros;
/// - not a GS1 restricted-circulation number (codes shops and scales make up
///   themselves): GTIN-13 prefixes `02`, `04` and `2`; UPC-A (GTIN-12)
///   number systems `2` and `4`; GTIN-8 starting `0` or `2`; a GTIN-14 is
///   judged on its inner GTIN-13 (the 13 digits after the indicator).
///
/// The same rule lives in SQL as `public.is_factory_gtin(text)` and
/// `public.gtin14(text)` (migration 0181). The shared vectors in
/// `test/fixtures/gtin_vectors.json` keep the two in lockstep. Change both
/// together, never one.
final class FactoryBarcode {
  const FactoryBarcode._(this.gtin14);

  /// The catalogue key: the code left-padded with zeros to 14 digits, so a
  /// UPC-A read as 12 digits and the same code read as EAN-13 with a leading
  /// `0` are one entry.
  final String gtin14;

  static const _validLengths = {8, 12, 13, 14};

  /// Parses [code] strictly (no trimming). Returns null when it is not a
  /// factory GTIN.
  static FactoryBarcode? tryParse(String code) {
    if (!isFactoryGtin(code)) return null;
    return FactoryBarcode._(code.padLeft(14, '0'));
  }

  /// Mirrors SQL `public.gtin14`: [code] left-padded to 14 digits when it is
  /// ASCII digits of length 8, 12, 13 or 14, else null. Says nothing about
  /// the check digit or restricted prefixes; use [isFactoryGtin] for that.
  static String? padToGtin14(String code) {
    if (!_isDigitsOfValidLength(code)) return null;
    return code.padLeft(14, '0');
  }

  /// Mirrors SQL `public.is_factory_gtin`.
  static bool isFactoryGtin(String code) {
    if (!_isDigitsOfValidLength(code)) return false;
    if (!code.contains(RegExp('[1-9]'))) return false;
    if (!_hasValidCheckDigit(code)) return false;
    return !_isRestrictedCirculation(code);
  }

  static bool _isDigitsOfValidLength(String code) =>
      _validLengths.contains(code.length) && RegExp(r'^[0-9]+$').hasMatch(code);

  /// GS1 mod-10: from the right, the check digit has weight 1, then the
  /// weights alternate 3, 1, 3, … The weighted sum must be a multiple of 10.
  static bool _hasValidCheckDigit(String code) {
    var sum = 0;
    for (var i = 0; i < code.length; i++) {
      final digit = code.codeUnitAt(code.length - 1 - i) - 0x30;
      sum += i.isOdd ? digit * 3 : digit;
    }
    return sum % 10 == 0;
  }

  static bool _isRestrictedCirculation(String code) => switch (code.length) {
    8 => code.startsWith('0') || code.startsWith('2'),
    12 => code.startsWith('2') || code.startsWith('4'),
    13 => _isRestrictedGtin13(code),
    14 => _isRestrictedGtin13(code.substring(1)),
    _ => true,
  };

  static bool _isRestrictedGtin13(String code) =>
      code.startsWith('02') || code.startsWith('04') || code.startsWith('2');

  @override
  bool operator ==(Object other) =>
      other is FactoryBarcode && other.gtin14 == gtin14;

  @override
  int get hashCode => gtin14.hashCode;

  @override
  String toString() => 'FactoryBarcode($gtin14)';
}
