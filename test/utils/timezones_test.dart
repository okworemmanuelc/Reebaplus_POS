import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'package:reebaplus_pos/core/data/currencies.dart';
import 'package:reebaplus_pos/core/data/timezones.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);

  test('every country with a currency has valid timezones (#63)', () {
    for (final country in kCountryCurrency.keys) {
      final zones = kCountryTimezones[country];
      expect(zones, isNotNull, reason: country);
      for (final z in zones!) {
        expect(() => tz.getLocation(z), returnsNormally, reason: '$country $z');
      }
    }
  });

  test('single-zone countries are not Lagos unless Nigeria', () {
    expect(timezoneForCountry('Nigeria'), 'Africa/Lagos');
    expect(timezoneForCountry('India'), 'Asia/Kolkata');
    expect(timezoneForCountry('Kenya'), 'Africa/Nairobi');
    expect(timezoneForCountry('Atlantis'), 'UTC');
    expect(timezoneForCountry(null), 'UTC');
  });

  test('multi-zone countries pick the zone matching the device offset', () {
    final now = DateTime.utc(2026, 1, 15, 12); // winter, no DST
    expect(
      timezoneForCountry('United States',
          deviceOffset: const Duration(hours: -8), now: now),
      'America/Los_Angeles',
    );
    expect(
      timezoneForCountry('United States',
          deviceOffset: const Duration(hours: -5), now: now),
      'America/New_York',
    );
    expect(
      timezoneForCountry('United States',
          deviceOffset: const Duration(hours: 1), now: now),
      'America/New_York',
    );
  });
}
