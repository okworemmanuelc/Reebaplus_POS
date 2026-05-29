/// Country suggestions for the CEO Sign Up store-details step (master plan
/// §5.1). Nigeria is first so it surfaces as the default; the rest are
/// alphabetical. Currency auto-fill keys off these names — see
/// [currencyForCountry] in `currencies.dart`, which must have an entry for
/// every name here.
const List<String> kCountries = [
  'Nigeria',
  'Benin',
  'Cameroon',
  'Canada',
  'Chad',
  'China',
  'Egypt',
  'France',
  'Germany',
  'Ghana',
  'India',
  'Italy',
  'Ivory Coast',
  'Kenya',
  'Liberia',
  'Mali',
  'Morocco',
  'Niger',
  'Rwanda',
  'Senegal',
  'Sierra Leone',
  'South Africa',
  'Spain',
  'Tanzania',
  'Togo',
  'Uganda',
  'United Arab Emirates',
  'United Kingdom',
  'United States',
  'Zambia',
  'Zimbabwe',
];

/// The default country (master plan §30.6).
const String kDefaultCountry = 'Nigeria';
