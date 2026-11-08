import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/features/subscription/subscription_plan.dart';

void main() {
  final now = DateTime(2026, 11, 1, 12);
  final future = now.add(const Duration(days: 3));
  final past = now.subtract(const Duration(days: 1));

  group('limitsForPlan', () {
    test('free / basic / premium match business_plan_limits()', () {
      final f = limitsForPlan(kPlanFree);
      expect((f.maxStores, f.maxStaff, f.warehouseAllowed), (1, 2, false));
      final b = limitsForPlan(kPlanBasic);
      expect((b.maxStores, b.maxStaff, b.warehouseAllowed), (1, 5, false));
      final p = limitsForPlan(kPlanPremium);
      expect((p.maxStores, p.maxStaff, p.warehouseAllowed), (null, null, true));
    });

    test('unknown or legacy plan names are treated as free', () {
      expect(limitsForPlan('local').maxStaff, 2);
      expect(limitsForPlan('international').maxStores, 1);
      expect(limitsForPlan(null).maxStaff, 2);
    });
  });

  group('effectivePlan', () {
    String eff(String? status, String? plan, DateTime? trial, DateTime? end) =>
        effectivePlan(
          status: status,
          plan: plan,
          trialEndsAt: trial,
          currentPeriodEnd: end,
          now: now,
        );

    test('running trial is premium regardless of stored plan', () {
      expect(eff('trial', null, future, null), kPlanPremium);
      expect(eff('trial', kPlanBasic, future, null), kPlanPremium);
    });
    test('ended trial falls to free; a trial with no deadline is premium', () {
      expect(eff('trial', kPlanPremium, past, null), kPlanFree);
      expect(eff('trial', kPlanPremium, null, null), kPlanPremium);
    });
    test('active uses the stored plan until period end', () {
      expect(eff('active', kPlanBasic, null, null), kPlanBasic);
      expect(eff('active', kPlanPremium, null, future), kPlanPremium);
      expect(eff('active', kPlanPremium, null, past), kPlanFree);
      expect(eff('active', null, null, future), kPlanFree);
    });
    test('inactive is free', () {
      expect(eff('inactive', kPlanPremium, future, future), kPlanFree);
    });
  });

  test('planSummary: Free allows the owner plus one staff', () {
    expect(planSummary(kPlanFree), '1 store, up to 2 staff');
    expect(
      planLimitMessage(PlanLimitKind.staff, plan: kPlanFree),
      contains('allows 2 staff accounts'),
    );
  });

  test('pricesInNaira follows default_currency', () {
    expect(pricesInNaira(null), isTrue);
    expect(pricesInNaira('NGN'), isTrue);
    expect(pricesInNaira('USD'), isFalse);
    expect(pricesInNaira('GHS'), isFalse);
  });

  group('recommendedPlanFor', () {
    test('basic when <=1 store and <=5 staff', () {
      expect(recommendedPlanFor(stores: 1, staff: 5), kPlanBasic);
      expect(recommendedPlanFor(stores: 1, staff: 1), kPlanBasic);
    });
    test('premium when more stores, more staff or a van', () {
      expect(recommendedPlanFor(stores: 2, staff: 1), kPlanPremium);
      expect(recommendedPlanFor(stores: 1, staff: 6), kPlanPremium);
      expect(recommendedPlanFor(stores: 1, staff: 2, vans: 1), kPlanPremium);
    });
  });

  group('trialReminderDay', () {
    test('7 inside the last week, 1 inside the last day, else null', () {
      expect(trialReminderDay(now.add(const Duration(days: 10)), now), isNull);
      expect(trialReminderDay(now.add(const Duration(days: 7)), now), 7);
      expect(trialReminderDay(now.add(const Duration(days: 2)), now), 7);
      expect(trialReminderDay(now.add(const Duration(hours: 20)), now), 1);
      expect(trialReminderDay(past, now), isNull);
      expect(trialReminderDay(null, now), isNull);
    });
    test('text names the recommended plan', () {
      expect(
        trialReminderText(day: 7, recommendedPlan: kPlanBasic),
        contains('Basic'),
      );
      expect(
        trialReminderText(day: 1, recommendedPlan: kPlanPremium),
        contains('Premium'),
      );
    });
  });

  group('pre-checks', () {
    test('store: free/basic block the 2nd, premium never', () {
      expect(
        checkAddStore(limitsForPlan(kPlanFree), currentStores: 1),
        PlanLimitKind.stores,
      );
      expect(
        checkAddStore(limitsForPlan(kPlanBasic), currentStores: 0),
        isNull,
      );
      expect(
        checkAddStore(limitsForPlan(kPlanPremium), currentStores: 50),
        isNull,
      );
    });
    test('staff counts the owner: free blocks the 3rd, basic the 6th', () {
      expect(checkAddStaff(limitsForPlan(kPlanFree), currentStaff: 1), isNull);
      expect(
        checkAddStaff(limitsForPlan(kPlanFree), currentStaff: 2),
        PlanLimitKind.staff,
      );
      expect(checkAddStaff(limitsForPlan(kPlanBasic), currentStaff: 4), isNull);
      expect(
        checkAddStaff(limitsForPlan(kPlanBasic), currentStaff: 5),
        PlanLimitKind.staff,
      );
    });
    test('van needs premium', () {
      expect(checkAddVan(limitsForPlan(kPlanBasic)), PlanLimitKind.warehouse);
      expect(checkAddVan(limitsForPlan(kPlanPremium)), isNull);
    });
  });

  group('planLimitKindOf', () {
    test('parses server errors', () {
      expect(
        planLimitKindOf('PostgrestException(message: plan_limit_stores)'),
        PlanLimitKind.stores,
      );
      expect(
        planLimitKindOf(Exception('plan_limit_staff')),
        PlanLimitKind.staff,
      );
      expect(planLimitKindOf('plan_limit_warehouse'), PlanLimitKind.warehouse);
      expect(planLimitKindOf('boom'), isNull);
      expect(planLimitKindOf(null), isNull);
    });
  });

  group('over-limit downgrade', () {
    final t0 = DateTime(2026, 1, 1);
    List<({String id, DateTime createdAt})> items(List<String> ids) => [
      for (var i = 0; i < ids.length; i++)
        (id: ids[i], createdAt: t0.add(Duration(days: i))),
    ];

    test('free keeps the owner + 1 longest-serving, even a newer owner', () {
      final paused = pausedStaffIds(
        limitsForPlan(kPlanFree),
        activeStaff: items(['a', 'b', 'owner']),
        ownerIds: {'owner'},
      );
      expect(paused, {'b'});
    });
    test('basic keeps owner + 4 longest-serving', () {
      final paused = pausedStaffIds(
        limitsForPlan(kPlanBasic),
        activeStaff: items(['owner', 'a', 'b', 'c', 'd', 'e']),
        ownerIds: {'owner'},
      );
      expect(paused, {'e'});
    });
    test('premium pauses nobody', () {
      expect(
        pausedStaffIds(
          limitsForPlan(kPlanPremium),
          activeStaff: items(['a', 'b']),
          ownerIds: {},
        ),
        isEmpty,
      );
    });
    test('extra stores are read-only, the oldest stays writable', () {
      expect(
        readOnlyStoreIds(
          limitsForPlan(kPlanFree),
          stores: items(['main', 's2', 's3']),
        ),
        {'s2', 's3'},
      );
      expect(
        readOnlyStoreIds(
          limitsForPlan(kPlanPremium),
          stores: items(['main', 's2']),
        ),
        isEmpty,
      );
    });
  });
}
