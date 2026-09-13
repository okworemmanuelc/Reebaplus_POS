import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/features/auth/onboarding/complete_onboarding_params.dart';
import 'package:reebaplus_pos/features/auth/onboarding/onboarding_draft.dart';

/// Replaces the old `OnboardingDraft.locationCombined` test. That string
/// existed to keep the local `stores.location` mirror byte-identical to the
/// one the cloud rebuilt — and sign-up no longer creates a Store on either
/// side (#232), so the string, the getter and the test all go.
///
/// What matters about the payload now is what it does *not* carry.
void main() {
  OnboardingDraft filledDraft() => OnboardingDraft(email: 'ceo@example.test')
    ..ownerName = 'Ada Owner'
    ..businessName = 'Ada Drinks'
    ..businessType = 'Beverage distributor'
    ..businessPhone = '+2348135216317'
    ..businessEmail = 'ada@example.test'
    ..country = 'Nigeria'
    ..currency = 'NGN'
    ..timezone = 'Africa/Lagos'
    ..taxRegNumber = 'TIN-12345'
    ..tracksEmptyCrates = false;

  group('completeOnboardingParams — the payload carries no Store (#232)', () {
    test('sends a null store id and a null location', () {
      final params = completeOnboardingParams(filledDraft());

      expect(params.containsKey('p_store_id'), isTrue,
          reason: 'the key stays — the RPC parameter list is unchanged');
      expect(params['p_store_id'], isNull);
      expect(params['p_location'], isNull);
    });

    test('carries no store name, street or country anywhere in the payload', () {
      final params = completeOnboardingParams(filledDraft());

      expect(params.values.whereType<String>(), isNot(contains('Nigeria')),
          reason: 'country drives the currency; it is not sent as a location');
      expect(
        params.keys.where((k) => k.contains('location') || k.contains('store')),
        ['p_store_id', 'p_location'],
        reason: 'no new location/store keys may creep back in',
      );
    });

    test('still carries the business, the owner and their settings', () {
      final draft = filledDraft();
      final params = completeOnboardingParams(draft);

      expect(params['p_business_id'], draft.businessId);
      expect(params['p_user_id'], draft.userId);
      expect(params['p_owner_name'], 'Ada Owner');
      expect(params['p_business_name'], 'Ada Drinks');
      expect(params['p_business_type'], 'Beverage distributor');
      expect(params['p_business_phone'], '+2348135216317');
      expect(params['p_business_email'], 'ada@example.test');
      expect(params['p_tracks_empty_crates'], isFalse);
      expect(params['p_settings'], {
        'currency': 'NGN',
        'timezone': 'Africa/Lagos',
        'tax_reg_number': 'TIN-12345',
      });
    });

    test('key set matches the RPC parameter list exactly', () {
      // A key the function does not declare is a 404 from PostgREST; a new
      // parameter must be added by replacing the function in place, never by
      // creating an overload (PGRST203).
      expect(completeOnboardingParams(OnboardingDraft()).keys.toSet(), {
        'p_business_id',
        'p_store_id',
        'p_owner_name',
        'p_business_name',
        'p_business_type',
        'p_business_phone',
        'p_business_email',
        'p_location',
        'p_settings',
        'p_user_id',
        'p_tracks_empty_crates',
      });
    });

    test('an empty draft still sends a null store rather than omitting it', () {
      final params = completeOnboardingParams(OnboardingDraft());
      expect(params['p_store_id'], isNull);
      expect(params['p_location'], isNull);
    });
  });
}
