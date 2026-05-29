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
