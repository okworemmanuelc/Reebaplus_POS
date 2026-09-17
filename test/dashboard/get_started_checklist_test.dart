// Seam 3 — Get-started checklist state (issue #31, ADR 0006).
//
// Two layers, both asserting external behaviour:
//   1. `computeGetStartedChecklist` — the pure derivation, exhaustive over
//      role / threshold / dismissal.
//   2. `getStartedChecklistProvider` — the live wiring, driven purely through
//      input overrides in a ProviderContainer (no widget tree), proving each
//      data source maps to the right step and that role + dismissal gate
//      visibility.
//   3. `GetStartedDismissalNotifier` — the device-local latch persists across a
//      simulated restart (a fresh container re-reads the stored flag).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/providers/first_run_tour_state.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/dashboard/get_started_checklist.dart';

// ── Test factories ───────────────────────────────────────────────────────────

RoleData _role(String slug) => RoleData(
      id: 'role-$slug',
      businessId: 'biz1',
      name: slug,
      slug: slug,
      isSystemDefault: true,
      isDeleted: false,
      createdAt: DateTime(2026, 1, 1),
      lastUpdatedAt: DateTime(2026, 1, 1),
    );

/// A staff list of exactly [n] active members (only its length matters to the
/// checklist — the CEO themselves is one member, so a team needs n > 1).
List<ActiveStaffEntry> _staff(int n) => List.generate(
      n,
      (i) => ActiveStaffEntry(
        user: UserData(
          id: 'user-$i',
          businessId: 'biz1',
          name: 'User $i',
          pin: '0000',
          avatarColor: '#3B82F6',
          biometricEnabled: false,
          createdAt: DateTime(2026, 1, 1),
          lastUpdatedAt: DateTime(2026, 1, 1),
        ),
      ),
    );

/// A dismissal notifier that skips SharedPreferences and reports a fixed value.
class _StubDismissal extends GetStartedDismissalNotifier {
  _StubDismissal(this._value);
  final bool _value;
  @override
  bool build() => _value;
}

StoreData _store(String id) => StoreData(
      id: id,
      businessId: 'biz1',
      name: 'Store $id',
      location: 'Lagos, Nigeria',
      kind: 'store',
      isDeleted: false,
      createdAt: DateTime(2026, 1, 1),
      lastUpdatedAt: DateTime(2026, 1, 1),
    );

/// Drives [getStartedChecklistProvider] through its input providers only.
Future<GetStartedChecklistState> _evaluate({
  required String? roleSlug,
  bool hasStores = true,
  bool hasProducts = false,
  bool hasOrders = false,
  int staffCount = 1,
  bool dismissed = false,
  bool tourActive = false,
  String? businessId = 'biz1',
}) async {
  final container = ProviderContainer(
    overrides: [
      currentUserRoleProvider
          .overrideWith((ref) => roleSlug == null ? null : _role(roleSlug)),
      allStoresProvider
          .overrideWith((ref) => Stream.value(hasStores ? [_store('s1')] : [])),
      hasLocalProductsProvider.overrideWith((ref) => Stream.value(hasProducts)),
      hasAnyOrderProvider.overrideWith((ref) => Stream.value(hasOrders)),
      currentBusinessIdProvider.overrideWith((ref) => businessId),
      activeStaffProvider
          .overrideWith((ref, id) => Stream.value(_staff(staffCount))),
      getStartedChecklistDismissedProvider
          .overrideWith(() => _StubDismissal(dismissed)),
      firstRunTourStopProvider
          .overrideWith((ref) => tourActive ? TourStop.createStore : TourStop.none),
    ],
  );
  addTearDown(container.dispose);

  // Let each overridden stream deliver its first value before we read the
  // derived provider (a StreamProvider is `loading` until it emits).
  await container.read(allStoresProvider.future);
  await container.read(hasLocalProductsProvider.future);
  await container.read(hasAnyOrderProvider.future);
  if (businessId != null) {
    await container.read(activeStaffProvider(businessId).future);
  }
  return container.read(getStartedChecklistProvider);
}

bool _done(GetStartedChecklistState s, GetStartedStepId id) =>
    s.steps.firstWhere((step) => step.id == id).done;

bool _locked(GetStartedChecklistState s, GetStartedStepId id) =>
    s.steps.firstWhere((step) => step.id == id).locked;

void main() {
  group('computeGetStartedChecklist (pure)', () {
    test('a fresh CEO with no store sees createStore unticked and downstream steps locked', () {
      final s = computeGetStartedChecklist(
        isCeo: true,
        hasStores: false,
        hasProducts: false,
        hasOrders: false,
        hasTeam: false,
        dismissed: false,
      );

      expect(s.visible, isTrue);
      expect(s.steps.map((e) => e.id), [
        GetStartedStepId.createStore,
        GetStartedStepId.addProduct,
        GetStartedStepId.makeSale,
        GetStartedStepId.inviteTeam,
      ]);
      expect(s.steps.every((e) => !e.done), isTrue);
      // createStore is unlocked; subsequent steps are locked.
      expect(_locked(s, GetStartedStepId.createStore), isFalse);
      expect(_locked(s, GetStartedStepId.addProduct), isTrue);
      expect(_locked(s, GetStartedStepId.makeSale), isTrue);
      expect(_locked(s, GetStartedStepId.inviteTeam), isTrue);

      // "Make a sale" and "Invite your team" are optional.
      expect(
        s.steps.where((e) => e.optional).map((e) => e.id),
        [GetStartedStepId.makeSale, GetStartedStepId.inviteTeam],
      );
    });

    test('cardHandoffPending keeps the card visible even when dismissed with stores', () {
      final s = computeGetStartedChecklist(
        isCeo: true,
        hasStores: true,
        hasProducts: false,
        hasOrders: false,
        hasTeam: false,
        dismissed: true,
        cardHandoffPending: true,
      );

      expect(s.visible, isTrue);

      // Once handoff settles, dismissal takes effect
      final settled = computeGetStartedChecklist(
        isCeo: true,
        hasStores: true,
        hasProducts: false,
        hasOrders: false,
        hasTeam: false,
        dismissed: true,
        cardHandoffPending: false,
      );

      expect(settled.visible, isFalse);
    });

    test('dismissal does NOT hide the card while the store step is undone', () {
      final s = computeGetStartedChecklist(
        isCeo: true,
        hasStores: false,
        hasProducts: false,
        hasOrders: false,
        hasTeam: false,
        dismissed: true,
      );

      expect(s.visible, isTrue);
    });

    test('tourActive hides the card entirely while the rail is up', () {
      final s = computeGetStartedChecklist(
        isCeo: true,
        hasStores: false,
        hasProducts: false,
        hasOrders: false,
        hasTeam: false,
        dismissed: false,
        tourActive: true,
      );

      expect(s.visible, isFalse);
    });

    test('with a store present, downstream steps are unlocked and dismissal works', () {
      final s = computeGetStartedChecklist(
        isCeo: true,
        hasStores: true,
        hasProducts: false,
        hasOrders: false,
        hasTeam: false,
        dismissed: false,
      );

      expect(s.visible, isTrue);
      expect(_done(s, GetStartedStepId.createStore), isTrue);
      expect(s.steps.every((e) => !e.locked), isTrue);

      final dismissed = computeGetStartedChecklist(
        isCeo: true,
        hasStores: true,
        hasProducts: false,
        hasOrders: false,
        hasTeam: false,
        dismissed: true,
      );
      expect(dismissed.visible, isFalse);
    });

    test('each step ticks independently as its threshold is crossed', () {
      final s = computeGetStartedChecklist(
        isCeo: true,
        hasStores: true,
        hasProducts: true,
        hasOrders: false,
        hasTeam: true,
        dismissed: false,
      );

      expect(_done(s, GetStartedStepId.createStore), isTrue);
      expect(_done(s, GetStartedStepId.addProduct), isTrue);
      expect(_done(s, GetStartedStepId.makeSale), isFalse);
      expect(_done(s, GetStartedStepId.inviteTeam), isTrue);
      expect(s.visible, isTrue);
    });

    test('the card is hidden once all steps are done', () {
      final s = computeGetStartedChecklist(
        isCeo: true,
        hasStores: true,
        hasProducts: true,
        hasOrders: true,
        hasTeam: true,
        dismissed: false,
      );
      expect(s.visible, isFalse);
    });

    test('a non-CEO never sees the card, regardless of counts', () {
      for (final dismissed in [false, true]) {
        for (final complete in [false, true]) {
          final s = computeGetStartedChecklist(
            isCeo: false,
            hasStores: complete,
            hasProducts: complete,
            hasOrders: complete,
            hasTeam: complete,
            dismissed: dismissed,
          );
          expect(s.visible, isFalse);
        }
      }
    });
  });

  group('getStartedChecklistProvider (input overrides)', () {
    test('unresolved storesAsync → keeps card hidden and computation prevented', () async {
      final container = ProviderContainer(
        overrides: [
          currentUserRoleProvider.overrideWith((ref) => _role('ceo')),
          allStoresProvider.overrideWith((ref) => const Stream.empty()),
        ],
      );
      addTearDown(container.dispose);

      final state = container.read(getStartedChecklistProvider);
      expect(state.visible, isFalse);
      expect(state.steps, isEmpty);
    });

    test('a fresh CEO with zero stores → visible, createStore unticked, downstream locked', () async {
      final s = await _evaluate(roleSlug: 'ceo', hasStores: false);
      expect(s.visible, isTrue);
      expect(_done(s, GetStartedStepId.createStore), isFalse);
      expect(_locked(s, GetStartedStepId.addProduct), isTrue);
      expect(_locked(s, GetStartedStepId.makeSale), isTrue);
      expect(_locked(s, GetStartedStepId.inviteTeam), isTrue);
    });

    test('dismissed with zero stores → remains visible', () async {
      final s = await _evaluate(roleSlug: 'ceo', hasStores: false, dismissed: true);
      expect(s.visible, isTrue);
    });

    test('tourActive → card is suppressed', () async {
      final s = await _evaluate(roleSlug: 'ceo', hasStores: false, tourActive: true);
      expect(s.visible, isFalse);
    });

    test('stores present → createStore ticked, downstream unlocked', () async {
      final s = await _evaluate(roleSlug: 'ceo', hasStores: true);
      expect(_done(s, GetStartedStepId.createStore), isTrue);
      expect(_locked(s, GetStartedStepId.addProduct), isFalse);
    });

    test('products stream ticks "Add a product"', () async {
      final s = await _evaluate(roleSlug: 'ceo', hasStores: true, hasProducts: true);
      expect(_done(s, GetStartedStepId.addProduct), isTrue);
      expect(s.visible, isTrue);
    });

    test('orders stream ticks "Make a sale"', () async {
      final s = await _evaluate(roleSlug: 'ceo', hasStores: true, hasOrders: true);
      expect(_done(s, GetStartedStepId.makeSale), isTrue);
    });

    test('staff count > 1 ticks "Invite your team" (threshold)', () async {
      final solo = await _evaluate(roleSlug: 'ceo', hasStores: true, staffCount: 1);
      expect(_done(solo, GetStartedStepId.inviteTeam), isFalse);

      final team = await _evaluate(roleSlug: 'ceo', hasStores: true, staffCount: 2);
      expect(_done(team, GetStartedStepId.inviteTeam), isTrue);
    });

    test('all thresholds crossed → card hidden', () async {
      final s = await _evaluate(
        roleSlug: 'ceo',
        hasStores: true,
        hasProducts: true,
        hasOrders: true,
        staffCount: 2,
      );
      expect(s.visible, isFalse);
    });

    test('dismissed with store → card hidden', () async {
      final s = await _evaluate(roleSlug: 'ceo', hasStores: true, dismissed: true);
      expect(s.visible, isFalse);
    });

    test('non-CEO roles never see the card', () async {
      for (final slug in ['manager', 'cashier', 'stock_keeper']) {
        final s = await _evaluate(roleSlug: slug);
        expect(s.visible, isFalse, reason: 'role=$slug');
      }
    });

    test('no bound business → team step stays unticked, not crashing',
        () async {
      final s = await _evaluate(roleSlug: 'ceo', businessId: null);
      expect(_done(s, GetStartedStepId.inviteTeam), isFalse);
      expect(s.visible, isTrue);
    });
  });

  group('GetStartedDismissalNotifier (device-local persistence)', () {
    setUp(TestWidgetsFlutterBinding.ensureInitialized);

    test('dismiss() persists so the card stays hidden across a restart',
        () async {
      SharedPreferences.setMockInitialValues({});

      final first = ProviderContainer();
      addTearDown(first.dispose);
      expect(first.read(getStartedChecklistDismissedProvider), isFalse);
      await first
          .read(getStartedChecklistDismissedProvider.notifier)
          .dismiss();
      expect(first.read(getStartedChecklistDismissedProvider), isTrue);

      // Simulate an app restart: a brand-new container re-hydrates from prefs.
      final restarted = ProviderContainer();
      addTearDown(restarted.dispose);
      // Trigger build(), then let the async hydrate resolve.
      expect(restarted.read(getStartedChecklistDismissedProvider), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(restarted.read(getStartedChecklistDismissedProvider), isTrue);
    });
  });
}
