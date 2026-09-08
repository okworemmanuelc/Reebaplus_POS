import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/features/auth/onboarding/onboarding_draft.dart';

void main() {
  group('OnboardingDraft.locationCombined — "street, country"', () {
    test('fuses street and country', () {
      final draft = OnboardingDraft()
        ..streetAddress = '14 Market Road'
        ..country = 'Nigeria';
      expect(draft.locationCombined, '14 Market Road, Nigeria');
    });

    test('trims each part', () {
      final draft = OnboardingDraft()
        ..streetAddress = '  14 Market Road '
        ..country = ' Ghana ';
      expect(draft.locationCombined, '14 Market Road, Ghana');
    });

    test('drops an empty or missing part rather than leaving a stray comma', () {
      expect(
        (OnboardingDraft()..streetAddress = '14 Market Road').locationCombined,
        '14 Market Road',
      );
      expect(
        (OnboardingDraft()
              ..streetAddress = '   '
              ..country = 'Kenya')
            .locationCombined,
        'Kenya',
      );
    });

    test('is null when nothing was collected', () {
      expect(OnboardingDraft().locationCombined, isNull);
    });

    // The cloud `complete_onboarding` RPC rebuilds the same string with
    // concat_ws(', ', street, city, country) and the client no longer sends a
    // `city` key — so both sides produce this exact two-part value and the
    // first pull cannot overwrite the local mirror with a different fusion.
    test('matches what the receipt formatter expects', () {
      final draft = OnboardingDraft()
        ..streetAddress = '14 Market Road'
        ..country = 'Nigeria';
      // receiptStoreAddress drops the trailing country segment (§15.1).
      expect(draft.locationCombined!.split(', ').first, '14 Market Road');
    });
  });
}
