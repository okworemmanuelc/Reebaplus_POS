import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/uuid_v7.dart';

/// Collected-but-uncommitted state for the new-business onboarding wizard.
///
/// The wizard is collect-first / commit-once: every screen between
/// [NewOwnerNameScreen] and [CreatePinScreen] writes into this draft and
/// nothing else. The atomic cloud commit happens once on PIN confirm via
/// [AuthService.completeOnboarding] / `complete_onboarding` RPC. If the user
/// abandons mid-flow, nothing reaches Supabase.
///
/// Identifiers ([businessId], [warehouseId], [userId]) are generated at
/// draft init so retries — same physical wizard run, second tap on PIN
/// confirm — reuse them and the RPC's `ON CONFLICT (id) DO UPDATE`
/// clauses keep the commit idempotent.
///
/// The cloud's `complete_onboarding` RPC accepts [userId] as `p_user_id`
/// so the cloud-side `public.users.id` matches the local Drift mirror's
/// id exactly.
class OnboardingDraft {
  /// Email is captured at OTP entry and threaded through every screen.
  /// Required at construction time.
  final String email;

  /// Generated client-side at construction so retries reuse the same id.
  final String businessId;
  final String warehouseId;
  final String userId;

  String? ownerName;
  String? businessName;
  String? businessType;
  String? businessPhone;
  String? businessEmail;

  String? locationName;
  String? streetAddress;
  String? cityState;
  String? country;

  String? currency;
  String? timezone;
  String? taxRegNumber;

  OnboardingDraft({
    required this.email,
    String? businessId,
    String? warehouseId,
    String? userId,
  })  : businessId = businessId ?? UuidV7.generate(),
        warehouseId = warehouseId ?? UuidV7.generate(),
        userId = userId ?? UuidV7.generate();

  /// Combines the structured location parts the same way the legacy
  /// LocationDetailsScreen formed `warehouses.location` ("street, city, country")
  /// — kept identical so existing UI that reads this field still parses.
  String? get locationCombined {
    final parts = [
      streetAddress?.trim(),
      cityState?.trim(),
      country?.trim(),
    ].where((p) => p != null && p.isNotEmpty).toList();
    if (parts.isEmpty) return null;
    return parts.join(', ');
  }
}

class OnboardingDraftNotifier extends StateNotifier<OnboardingDraft?> {
  OnboardingDraftNotifier() : super(null);

  /// Starts a fresh draft. Called from [BusinessTypeSelectionScreen] when the
  /// user picks "Register a new business" — it also clears the local DB, so
  /// kicking off a new draft alongside is the natural reset point.
  void start(String email) {
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
        'OnboardingDraft is null — wizard screen reached without a draft. '
        'BusinessTypeSelectionScreen.start(email) must run before any '
        'wizard screen mounts.',
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

/// Regular (non-autoDispose) provider. autoDispose was tempting but the
/// wizard pushes screens with no overlapping watch listeners — the draft
/// would be reclaimed in the brief window between two pushes. Lifetime is
/// instead managed explicitly:
///   - [BusinessTypeSelectionScreen._onRegister] calls `start(email)` which
///     also overwrites any prior draft.
///   - [AuthService.completeOnboarding] calls `clear()` once the cloud
///     commit + local mirror succeed.
final onboardingDraftProvider =
    StateNotifierProvider<OnboardingDraftNotifier, OnboardingDraft?>(
  (ref) => OnboardingDraftNotifier(),
);
