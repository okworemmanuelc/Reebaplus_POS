import 'package:timezone/timezone.dart' as tz;

import 'package:reebaplus_pos/core/data/currencies.dart';

/// Country → IANA timezone(s), the timezone twin of [kCountryCurrency] (#63).
/// Every country in [kCountryCurrency] has an entry. The first zone is the
/// default; countries that span several zones list the rest so the device's own
/// offset can pick the right one ([timezoneForCountry]).
const Map<String, List<String>> kCountryTimezones = {
  'Nigeria': ['Africa/Lagos'],
  'Benin': ['Africa/Porto-Novo'],
  'Cameroon': ['Africa/Douala'],
  'Canada': [
    'America/Toronto',
    'America/Vancouver',
    'America/Edmonton',
    'America/Regina',
    'America/Winnipeg',
    'America/Halifax',
    'America/St_Johns',
  ],
  'Chad': ['Africa/Ndjamena'],
  'China': ['Asia/Shanghai'],
  'Egypt': ['Africa/Cairo'],
  'France': ['Europe/Paris'],
  'Germany': ['Europe/Berlin'],
  'Ghana': ['Africa/Accra'],
  'India': ['Asia/Kolkata'],
  'Italy': ['Europe/Rome'],
  'Ivory Coast': ['Africa/Abidjan'],
  'Kenya': ['Africa/Nairobi'],
  'Liberia': ['Africa/Monrovia'],
  'Mali': ['Africa/Bamako'],
  'Morocco': ['Africa/Casablanca'],
  'Niger': ['Africa/Niamey'],
  'Rwanda': ['Africa/Kigali'],
  'Senegal': ['Africa/Dakar'],
  'Sierra Leone': ['Africa/Freetown'],
  'South Africa': ['Africa/Johannesburg'],
  'Spain': ['Europe/Madrid'],
  'Tanzania': ['Africa/Dar_es_Salaam'],
  'Togo': ['Africa/Lome'],
  'Uganda': ['Africa/Kampala'],
  'United Arab Emirates': ['Asia/Dubai'],
  'United Kingdom': ['Europe/London'],
  'United States': [
    'America/New_York',
    'America/Chicago',
    'America/Denver',
    'America/Phoenix',
    'America/Los_Angeles',
    'America/Anchorage',
    'Pacific/Honolulu',
  ],
  'Zambia': ['Africa/Lusaka'],
  'Zimbabwe': ['Africa/Harare'],
};

/// Fallback when the country is unknown: neutral, never another country's
/// zone (the old hardcoded `Africa/Lagos` cut every non-Nigerian business's
/// days on Lagos time).
const String kFallbackTimezone = 'UTC';

/// The IANA timezone for a business in [country] (#63).
///
/// A single-zone country maps straight to its zone. For a multi-zone country
/// (United States, Canada) the zone whose current UTC offset equals the
/// device's ([deviceOffset], default the phone's own) wins, else the first
/// listed. Needs `tz.initializeTimeZones()` for the multi-zone match; without it
/// the country's default zone is returned.
String timezoneForCountry(
  String? country, {
  Duration? deviceOffset,
  DateTime? now,
}) {
  final zones = kCountryTimezones[country?.trim()];
  if (zones == null) return kFallbackTimezone;
  if (zones.length == 1) return zones.first;
  final at = now ?? DateTime.now();
  final offset = deviceOffset ?? at.timeZoneOffset;
  for (final name in zones) {
    try {
      final zoneOffset = tz.TZDateTime.from(at.toUtc(), tz.getLocation(name))
          .timeZoneOffset;
      if (zoneOffset == offset) return name;
    } catch (_) {
      // Timezone database not loaded: use the default zone.
      break;
    }
  }
  return zones.first;
}
