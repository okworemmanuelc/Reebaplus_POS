import 'package:reebaplus_pos/features/auth/onboarding/onboarding_draft.dart';

/// Builds the parameter map for the cloud `complete_onboarding` RPC.
///
/// Pure and widget-free so the shape of the payload is assertable without a
/// Supabase session — the payload is the contract between the wizard and the
/// server function, and from #232 the most important thing about it is what it
/// no longer carries.
///
/// `p_store_id` and `p_location` are always null: sign-up does not create a
/// Store any more (PRD #229). Migration 0178 skips the store insert and the
/// owner-to-store binding when the store id is null, so the business, the
/// owner, their roles and their settings are all seeded without one.
///
/// The key set is fixed and matches the RPC's parameter list exactly. Do not
/// add a key here without adding the parameter to the function in a migration
/// — and never by adding an overload (PGRST203).
Map<String, dynamic> completeOnboardingParams(OnboardingDraft draft) {
  return {
    'p_business_id': draft.businessId,
    'p_store_id': null,
    'p_owner_name': draft.ownerName,
    'p_business_name': draft.businessName,
    'p_business_type': draft.businessType,
    'p_business_phone': draft.businessPhone,
    'p_business_email': draft.businessEmail,
    'p_location': null,
    'p_settings': {
      'currency': draft.currency,
      'timezone': draft.timezone,
      'tax_reg_number': draft.taxRegNumber,
    },
    'p_user_id': draft.userId,
    'p_tracks_empty_crates': draft.tracksEmptyCrates,
  };
}
