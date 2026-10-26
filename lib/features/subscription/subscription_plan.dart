// Subscription tiers (reebaplus-web#90, slice A). Pure, Flutter-free logic that
// mirrors the cloud functions `business_effective_plan()` /
// `business_plan_limits()` from migration 0224, so the client can pre-check
// limits offline and explain them. The server triggers remain the authority.
//
// Every feature is in every plan; plans differ ONLY by stores + staff accounts
// (owner counts as staff). Selling is never blocked, and nothing is deleted on
// a downgrade: extra staff are paused and extra stores become read-only.

const String kPlanFree = 'free';
const String kPlanBasic = 'basic';
const String kPlanPremium = 'premium';

/// Server error codes (message of the P0001 exception raised by 0224).
enum PlanLimitKind { stores, staff, warehouse }

/// Limits for one plan. `null` = unlimited. Mirrors `business_plan_limits()`.
class PlanLimits {
  const PlanLimits({
    required this.maxStores,
    required this.maxStaff,
    required this.warehouseAllowed,
  });

  final int? maxStores;
  final int? maxStaff;
  final bool warehouseAllowed;
}

/// Limits for [plan]; an unknown or null plan is treated as Free (matches the
/// SQL function).
PlanLimits limitsForPlan(String? plan) => switch (plan) {
  kPlanBasic => const PlanLimits(
    maxStores: 1,
    maxStaff: 5,
    warehouseAllowed: false,
  ),
  kPlanPremium => const PlanLimits(
    maxStores: null,
    maxStaff: null,
    warehouseAllowed: true,
  ),
  _ => const PlanLimits(maxStores: 1, maxStaff: 1, warehouseAllowed: false),
};

/// The plan whose limits apply right now. Mirrors `business_effective_plan()`:
/// Premium while a trial is running, the stored plan while active (and not past
/// `current_period_end`), otherwise Free.
String effectivePlan({
  required String? status,
  required String? plan,
  required DateTime? trialEndsAt,
  required DateTime? currentPeriodEnd,
  required DateTime now,
}) {
  if (status == 'trial' && (trialEndsAt == null || trialEndsAt.isAfter(now))) {
    return kPlanPremium;
  }
  if (status == 'active' &&
      (currentPeriodEnd == null || currentPeriodEnd.isAfter(now))) {
    return const {kPlanFree, kPlanBasic, kPlanPremium}.contains(plan)
        ? plan!
        : kPlanFree;
  }
  return kPlanFree;
}

String planLabel(String? plan) => switch (plan) {
  kPlanBasic => 'Basic',
  kPlanPremium => 'Premium',
  _ => 'Free',
};

/// One-line summary of what a plan includes, for the Subscription screen.
String planSummary(String? plan) {
  final l = limitsForPlan(plan);
  final stores = l.maxStores == null
      ? 'unlimited stores'
      : '${l.maxStores} store';
  final staff = l.maxStaff == null
      ? 'unlimited staff'
      : l.maxStaff == 1
      ? 'owner only'
      : 'up to ${l.maxStaff} staff';
  return '${l.warehouseAllowed ? 'Warehouse, ' : ''}$stores, $staff';
}

/// Price line per plan. Naira for Nigeria, USD elsewhere (decided pricing).
String planPriceLine(String? plan, {required bool nigeria}) => switch (plan) {
  kPlanBasic => nigeria ? '₦6,500 per month' : '\$5 per month',
  kPlanPremium => nigeria ? '₦25,000 per month' : '\$20 per month',
  _ => nigeria ? '₦0' : '\$0',
};

/// Whether prices show in naira: the business's `default_currency` setting is
/// NGN or unset; any other currency shows USD (matches the console and 0223).
bool pricesInNaira(String? currencyCode) =>
    currencyCode == null || currencyCode.isEmpty || currencyCode == 'NGN';

/// The plan that keeps the owner's CURRENT setup after the trial: Basic when
/// they have at most 1 store and at most 5 staff and no van/warehouse,
/// otherwise Premium.
String recommendedPlanFor({
  required int stores,
  required int staff,
  int vans = 0,
}) {
  final basic = limitsForPlan(kPlanBasic);
  if (stores <= basic.maxStores! && staff <= basic.maxStaff! && vans == 0) {
    return kPlanBasic;
  }
  return kPlanPremium;
}

/// Which trial reminder is due: 7 when 1 < days left <= 7, 1 when 0 < left
/// <= 1 day, else null (too early, or already ended).
int? trialReminderDay(DateTime? trialEndsAt, DateTime now) {
  if (trialEndsAt == null) return null;
  final left = trialEndsAt.difference(now);
  if (left <= Duration.zero) return null;
  if (left <= const Duration(days: 1)) return 1;
  if (left <= const Duration(days: 7)) return 7;
  return null;
}

String trialReminderText({required int day, required String recommendedPlan}) {
  final plan = planLabel(recommendedPlan);
  return day == 1
      ? 'Your free trial ends within a day. Choose $plan to keep your '
            'current stores and staff.'
      : 'Your free trial ends in under 7 days. $plan keeps your current '
            'stores and staff.';
}

// ── Pre-checks (offline UX; the server triggers are authoritative) ─────────

/// Null when adding is allowed, else the limit that would be exceeded.
PlanLimitKind? checkAddStore(PlanLimits l, {required int currentStores}) =>
    l.maxStores != null && currentStores >= l.maxStores!
    ? PlanLimitKind.stores
    : null;

PlanLimitKind? checkAddVan(PlanLimits l) =>
    l.warehouseAllowed ? null : PlanLimitKind.warehouse;

/// [currentStaff] is active staff (incl. owner) PLUS pending invites.
PlanLimitKind? checkAddStaff(PlanLimits l, {required int currentStaff}) =>
    l.maxStaff != null && currentStaff >= l.maxStaff!
    ? PlanLimitKind.staff
    : null;

String planLimitMessage(PlanLimitKind kind, {String? plan}) {
  final label = planLabel(plan);
  return switch (kind) {
    PlanLimitKind.stores =>
      'Your $label plan allows ${limitsForPlan(plan).maxStores} store. '
          'Upgrade to Premium to add more stores.',
    PlanLimitKind.staff =>
      'Your $label plan allows ${limitsForPlan(plan).maxStaff} staff '
          'account${limitsForPlan(plan).maxStaff == 1 ? '' : 's'} (including '
          'you). Upgrade to add more.',
    PlanLimitKind.warehouse =>
      'Warehouse and van sales need the Premium plan. Upgrade to use them.',
  };
}

/// Parses a server error (or its message string) raised by the 0224 triggers.
PlanLimitKind? planLimitKindOf(Object? error) {
  final s = error?.toString() ?? '';
  if (s.contains('plan_limit_stores')) return PlanLimitKind.stores;
  if (s.contains('plan_limit_staff')) return PlanLimitKind.staff;
  if (s.contains('plan_limit_warehouse')) return PlanLimitKind.warehouse;
  return null;
}

// ── Over-limit after a downgrade (nothing is deleted) ──────────────────────

/// Ids that stay usable, oldest first, capped at [max] (null = all). The ids
/// in [alwaysKeep] (the owner) are kept first and count toward the cap.
Set<String> _keepIds(
  List<({String id, DateTime createdAt})> items,
  int? max, {
  Set<String> alwaysKeep = const {},
}) {
  if (max == null) return {for (final i in items) i.id};
  final sorted = [...items]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  final keep = <String>{
    for (final i in sorted)
      if (alwaysKeep.contains(i.id)) i.id,
  };
  for (final i in sorted) {
    if (keep.length >= max) break;
    keep.add(i.id);
  }
  return keep;
}

/// Staff user ids to PAUSE under [limits]: everyone beyond the cap, keeping the
/// owner first, then the longest-serving. Empty when within limits.
Set<String> pausedStaffIds(
  PlanLimits limits, {
  required List<({String id, DateTime createdAt})> activeStaff,
  required Set<String> ownerIds,
}) {
  final keep = _keepIds(activeStaff, limits.maxStaff, alwaysKeep: ownerIds);
  return {
    for (final s in activeStaff)
      if (!keep.contains(s.id)) s.id,
  };
}

/// Store ids that become READ-ONLY under [limits]: every normal store beyond
/// the cap, keeping the oldest (the main store) writable.
Set<String> readOnlyStoreIds(
  PlanLimits limits, {
  required List<({String id, DateTime createdAt})> stores,
}) {
  final keep = _keepIds(stores, limits.maxStores);
  return {
    for (final s in stores)
      if (!keep.contains(s.id)) s.id,
  };
}
