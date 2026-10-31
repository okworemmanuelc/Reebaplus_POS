import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/stores/van_store.dart';
import 'package:reebaplus_pos/features/subscription/subscription_plan.dart';

/// The plan whose limits apply right now (trial = Premium, active = stored
/// plan, else Free). Re-evaluates on [subscriptionClockTickProvider] so a trial
/// crossing its deadline mid-session is picked up. Mirrors the cloud
/// `business_effective_plan()`; no business bound => Premium (never restrict
/// while state is unknown; the server stays the authority).
final effectivePlanProvider = Provider<String>((ref) {
  ref.watch(subscriptionClockTickProvider);
  final b = ref.watch(currentBusinessProvider);
  if (b == null) return kPlanPremium;
  return effectivePlan(
    status: b.subscriptionStatus,
    plan: b.subscriptionPlan,
    trialEndsAt: b.trialEndsAt,
    currentPeriodEnd: b.currentPeriodEnd,
    now: DateTime.now(),
  );
});

final planLimitsProvider = Provider<PlanLimits>(
  (ref) => limitsForPlan(ref.watch(effectivePlanProvider)),
);

/// Current usage against the limits.
class PlanUsage {
  const PlanUsage({
    required this.stores,
    required this.vans,
    required this.activeStaff,
    required this.pendingInvites,
  });

  final int stores;
  final int vans;
  final int activeStaff;
  final int pendingInvites;

  /// Staff slots consumed: active members plus unredeemed invites.
  int get staffSlots => activeStaff + pendingInvites;
}

final planUsageProvider = Provider<PlanUsage>((ref) {
  final all = ref.watch(allStoresProvider).valueOrNull ?? const [];
  final members = ref.watch(userBusinessesProvider).valueOrNull ?? const [];
  final invites = ref.watch(activeInviteCodesProvider).valueOrNull ?? const [];
  return PlanUsage(
    stores: withoutVans(all).length,
    vans: onlyVans(all).length,
    activeStaff: members.where((m) => m.status == 'active').length,
    pendingInvites: invites.length,
  );
});

// TODO(#584): remove once no legacy trials remain
/// Null when the trial reminder is not due; otherwise the reminder day (7 or 1)
/// and the plan that keeps the current setup.
final trialReminderProvider = Provider<({int day, String plan})?>((ref) {
  ref.watch(subscriptionClockTickProvider);
  final b = ref.watch(currentBusinessProvider);
  if (b == null || b.subscriptionStatus != 'trial') return null;
  final day = trialReminderDay(b.trialEndsAt, DateTime.now());
  if (day == null) return null;
  final u = ref.watch(planUsageProvider);
  return (
    day: day,
    plan: recommendedPlanFor(
      stores: u.stores,
      staff: u.activeStaff,
      vans: u.vans,
    ),
  );
});

/// Staff user ids paused because the plan allows fewer accounts than are active.
final pausedStaffIdsProvider = Provider<Set<String>>((ref) {
  final limits = ref.watch(planLimitsProvider);
  final members = ref.watch(userBusinessesProvider).valueOrNull ?? const [];
  final roles = ref.watch(allRolesProvider).valueOrNull ?? const [];
  final ceoRoleIds = {
    for (final r in roles)
      if (r.slug == 'ceo') r.id,
  };
  final active = members.where((m) => m.status == 'active').toList();
  return pausedStaffIds(
    limits,
    activeStaff: [
      for (final m in active) (id: m.userId, createdAt: m.createdAt),
    ],
    ownerIds: {
      for (final m in active)
        if (ceoRoleIds.contains(m.roleId)) m.userId,
    },
  );
});

/// Store ids that are read-only because the plan allows fewer stores than exist.
final readOnlyStoreIdsProvider = Provider<Set<String>>((ref) {
  final limits = ref.watch(planLimitsProvider);
  final all = ref.watch(allStoresProvider).valueOrNull ?? const [];
  return readOnlyStoreIds(
    limits,
    stores: [
      for (final s in withoutVans(all)) (id: s.id, createdAt: s.createdAt),
    ],
  );
});
