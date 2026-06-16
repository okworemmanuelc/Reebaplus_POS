// Subscription access state (master plan §32). The web admin console sets each
// business's subscription_status / trial_ends_at in the cloud; the app reads
// them off the local `businesses` mirror and derives the effective access here.
//
// This is a PURE function (no Drift, no Riverpod) so it is trivially unit-
// testable. The provider that feeds it `now` and the row lives in
// stream_providers.dart; the gate that reacts to a locked result lives in
// main.dart.

/// Effective access for the bound business, computed on-device.
///
/// `grace` means "don't lock" — used when the subscription state is unknown
/// (brand-new install before first sync, a null trial date, or an unrecognised
/// status). We only ever lock on a *known* expired/inactive state (§32).
enum SubscriptionAccess { active, trialActive, trialExpired, inactive, grace }

/// Maps the stored `subscription_status` + `trial_ends_at` to an effective
/// [SubscriptionAccess] using `now` (the device clock — works offline).
///
/// - `active`   → [SubscriptionAccess.active]
/// - `trial`    → before `trialEndsAt` ⇒ trialActive; at/after ⇒ trialExpired;
///                null `trialEndsAt` ⇒ grace (don't lock without a deadline)
/// - `inactive` → [SubscriptionAccess.inactive]
/// - null / unknown → grace
SubscriptionAccess computeSubscriptionAccess(
  String? status,
  DateTime? trialEndsAt,
  DateTime now,
) {
  switch (status) {
    case 'active':
      return SubscriptionAccess.active;
    case 'inactive':
      return SubscriptionAccess.inactive;
    case 'trial':
      if (trialEndsAt == null) return SubscriptionAccess.grace;
      return now.isBefore(trialEndsAt)
          ? SubscriptionAccess.trialActive
          : SubscriptionAccess.trialExpired;
    default:
      return SubscriptionAccess.grace;
  }
}

extension SubscriptionAccessX on SubscriptionAccess {
  /// Whether this state should replace the whole app with the locked screen.
  bool get isLocked =>
      this == SubscriptionAccess.trialExpired ||
      this == SubscriptionAccess.inactive;

  /// Short tag shown next to the current user's name (§32). null = show nothing.
  /// Paid → 'PRO'; inside the free trial → 'FREE TRIAL'; expired/inactive/grace
  /// show no tag.
  String? get badgeLabel => switch (this) {
    SubscriptionAccess.active => 'PRO',
    SubscriptionAccess.trialActive => 'FREE TRIAL',
    SubscriptionAccess.trialExpired ||
    SubscriptionAccess.inactive ||
    SubscriptionAccess.grace => null,
  };
}
