import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/uuid_v7.dart';

/// Collected-but-uncommitted state for the new-business onboarding wizard.
///
/// The wizard is collect-first / commit-once: each step of `CeoSignUpScreen`
/// (master plan §5) writes into this draft and nothing else. The atomic cloud
/// commit happens once on Confirm PIN via `AuthService.completeOnboarding` /
/// `complete_onboarding` RPC. If the user abandons mid-flow, nothing reaches
/// Supabase.
///
/// Identifiers ([businessId], [storeId], [userId]) are generated at
/// draft init so retries — same physical wizard run, second tap on PIN
/// confirm — reuse them and the RPC's `ON CONFLICT (id) DO UPDATE`
/// clauses keep the commit idempotent.
///
/// The cloud's `complete_onboarding` RPC accepts [userId] as `p_user_id`
/// so the cloud-side `public.users.id` matches the local Drift mirror's
/// id exactly.
class OnboardingDraft {
  /// CEO email. In the §5 single-screen flow the business name comes first and
  /// email is collected at step 5, so the draft is created without an email
  /// and this is filled in then (mutable). Defaults to '' until set.
  String email;

  /// Generated client-side at construction so retries reuse the same id.
  final String businessId;
  final String storeId;
  final String userId;

  String? ownerName;
  String? businessName;
  String? businessType;
  // Onboarding opt-in: shown when businessType is crate-eligible. Default true
  // so crate businesses keep their features; non-crate types don't use this.
  bool tracksEmptyCrates = true;
  String? businessPhone;
  String? businessEmail;

  String? locationName;
  String? streetAddress;
  String? lgaDistrict;
  String? cityState;
  String? country;

  String? currency;
  String? timezone;
  String? taxRegNumber;

  OnboardingDraft({
    this.email = '',
    String? businessId,
    String? storeId,
    String? userId,
  }) : businessId = businessId ?? UuidV7.generate(),
       storeId = storeId ?? UuidV7.generate(),
       userId = userId ?? UuidV7.generate();

  /// Combines the structured location parts into `stores.location`
  /// ("street, LGA/District, city, country") — the shape existing UI that reads this field
  /// expects.
  String? get locationCombined {
    final parts = [
      streetAddress?.trim(),
      lgaDistrict?.trim(),
      cityState?.trim(),
      country?.trim(),
    ].where((p) => p != null && p.isNotEmpty).toList();
    if (parts.isEmpty) return null;
    return parts.join(', ');
  }
}

class OnboardingDraftNotifier extends StateNotifier<OnboardingDraft?> {
  OnboardingDraftNotifier() : super(null);

  /// Starts a fresh draft. In the §5 single-screen flow this is called on
  /// flow entry with no email (collected at step 5 via [update]). Overwrites
  /// any prior draft so an abandoned-then-restarted onboarding starts clean.
  void start([String email = '']) {
    state = OnboardingDraft(email: email);
  }

  /// Drops the draft (e.g. on successful commit, or if the user backs out
  /// of the wizard root).
  void clear() {
    state = null;
  }

  /// Returns the current draft, throwing if there isn't one. Use at submit
  /// sites that *require* a draft — a null here is a wiring bug, not a
  /// user-flow case.
  OnboardingDraft require() {
    final s = state;
    if (s == null) {
      throw StateError(
        'OnboardingDraft is null — commit reached without a draft. '
        'CeoSignUpScreen must call start() on flow entry before any step '
        'writes to the draft.',
      );
    }
    return s;
  }

  /// Field setters that preserve the draft instance and notify listeners.
  /// Each rebuild of the draft is cheap (just a copy with one field changed)
  /// and allows StateNotifier to fire its `==` comparison correctly.
  void update(void Function(OnboardingDraft draft) mutator) {
    final current = state;
    if (current == null) return;
    mutator(current);
    // Force a notify by reassigning a fresh reference — StateNotifier only
    // notifies on identity change, and we mutated the existing object in
    // place so callers see the updated values without us needing to
    // implement a full copyWith.
    state = current;
  }
}

/// Regular (non-autoDispose) provider. Lifetime is managed explicitly:
///   - `CeoSignUpScreen` calls `start()` on flow entry, overwriting any prior
///     draft (and clears the local DB alongside).
///   - `AuthService.completeOnboarding` / the commit calls `clear()` once the
///     cloud commit + local mirror succeed.
final onboardingDraftProvider =
    StateNotifierProvider<OnboardingDraftNotifier, OnboardingDraft?>(
      (ref) => OnboardingDraftNotifier(),
    );
