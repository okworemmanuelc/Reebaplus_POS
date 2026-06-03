/// Country → ISO-4217 currency code, used to auto-fill currency from the
/// chosen country on the CEO Sign Up store-details step (master plan §5.1 /
/// §30.6). Every name in `kCountries` (countries.dart) has an entry here.
const Map<String, String> kCountryCurrency = {
  'Nigeria': 'NGN',
  'Benin': 'XOF',
  'Cameroon': 'XAF',
  'Canada': 'CAD',
  'Chad': 'XAF',
  'China': 'CNY',
  'Egypt': 'EGP',
  'France': 'EUR',
  'Germany': 'EUR',
  'Ghana': 'GHS',
  'India': 'INR',
  'Italy': 'EUR',
  'Ivory Coast': 'XOF',
  'Kenya': 'KES',
  'Liberia': 'LRD',
  'Mali': 'XOF',
  'Morocco': 'MAD',
  'Niger': 'XOF',
  'Rwanda': 'RWF',
  'Senegal': 'XOF',
  'Sierra Leone': 'SLL',
  'South Africa': 'ZAR',
  'Spain': 'EUR',
  'Tanzania': 'TZS',
  'Togo': 'XOF',
  'Uganda': 'UGX',
  'United Arab Emirates': 'AED',
  'United Kingdom': 'GBP',
  'United States': 'USD',
  'Zambia': 'ZMW',
  'Zimbabwe': 'ZWL',
};

/// The default currency when the country is unknown or unmapped (master plan
/// is Nigeria-first, so NGN is the safe fallback).
const String kDefaultCurrency = 'NGN';

/// Returns the currency for [country], falling back to [kDefaultCurrency].
String currencyForCountry(String? country) {
  if (country == null) return kDefaultCurrency;
  return kCountryCurrency[country] ?? kDefaultCurrency;
}

/// ISO-4217 currency code → display symbol, for every code in
/// [kCountryCurrency]. Drives app-wide money formatting (see `formatCurrency`
/// in core/utils/number_format.dart) so the CEO-chosen currency (Business
/// Info, §10.1) actually appears on receipts and every money surface. Codes
/// without a clean single glyph use a short letter abbreviation;
/// [currencySymbolForCode] falls back to the bare code.
const Map<String, String> kCurrencySymbols = {
  'NGN': '₦',
  'XOF': 'CFA',
  'XAF': 'FCFA',
  'CAD': r'CA$',
  'CNY': '¥',
  'EGP': 'E£',
  'EUR': '€',
  'GHS': 'GH₵',
  'INR': '₹',
  'KES': 'KSh',
  'LRD': r'L$',
  'MAD': 'DH',
  'RWF': 'FRw',
  'SLL': 'Le',
  'ZAR': 'R',
  'TZS': 'TSh',
  'UGX': 'USh',
  'AED': 'AED',
  'GBP': '£',
  'USD': r'$',
  'ZMW': 'ZK',
  'ZWL': r'Z$',
};

/// Normalises a stored currency value to a bare ISO-4217 code where possible.
///
/// Tolerant of legacy/label-style stored values: older onboarding wrote the
/// `default_currency` setting as e.g. `"NGN (₦)"` instead of the bare `"NGN"`,
/// which the old hardcoded formatter ignored. Pulls the first embedded known
/// ISO code (`"NGN (₦)"` → `"NGN"`, `"Naira (NGN)"` → `"NGN"`) so pickers and
/// re-saves use the clean code and the display stays a single glyph. Returns
/// the trimmed input when nothing maps (already a glyph, or an unknown code).
String normalizeCurrencyCode(String? code) {
  if (code == null || code.trim().isEmpty) return kDefaultCurrency;
  final raw = code.trim().toUpperCase();
  if (kCurrencySymbols.containsKey(raw)) return raw;
  for (final m in RegExp(r'[A-Za-z]{3}').allMatches(raw)) {
    if (kCurrencySymbols.containsKey(m.group(0))) return m.group(0)!;
  }
  return raw;
}

/// Display symbol for a stored currency value — returns ONLY the glyph (e.g.
/// '₦', r'$', 'GH₵'), never the code or a "CODE (symbol)" label. Resilient to
/// label-style stored values via [normalizeCurrencyCode].
String currencySymbolForCode(String? code) {
  final norm = normalizeCurrencyCode(code);
  return kCurrencySymbols[norm] ?? norm;
}
