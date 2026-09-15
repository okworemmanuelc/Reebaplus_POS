/// Get-started checklist state (Seam 3 — issue #31, ADR 0006).
///
/// A first-time CEO's Home tab shows a short "Get started" card tracking three
/// first-run milestones (add a product, make a sale, invite the team). It ticks
/// each step off automatically and quietly disappears once the store is up and
/// running.
///
/// Completion is **derived from data, never stored as flags** — so it is
/// cross-device correct for free (a reinstall reflects real progress, nothing to
/// migrate or reset). The only persisted bit is a device-local *manual*
/// dismissal, mirroring [UiHintService]'s SharedPreferences pattern, for the
/// solo CEO who won't invite staff and doesn't want the optional step nagging.
///
/// The top half of this file is a pure, widget-free, Riverpod-free unit:
/// [computeGetStartedChecklist] maps the five inputs to `{ visible, steps }`.
/// The providers below wire it to the live app signals. Both halves are
/// unit-tested (role / threshold / dismissal).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/providers/first_run_tour_state.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';

/// The four first-run milestones, in display order (PRD #229, Issue #234).
enum GetStartedStepId { createStore, addProduct, makeSale, inviteTeam }

/// One checklist row: which milestone, whether it is done (derived from data),
/// whether it is optional (only "Invite your team" is — a solo CEO can finish
/// setup without it, via manual dismissal), and whether it is locked (later steps
/// are visibly locked while the Store step is undone).
class GetStartedStep {
  const GetStartedStep({
    required this.id,
    required this.done,
    this.optional = false,
    this.locked = false,
  });

  final GetStartedStepId id;
  final bool done;
  final bool optional;
  final bool locked;
}

/// The derived card state: whether to render it, and the per-step done-state.
class GetStartedChecklistState {
  const GetStartedChecklistState({required this.visible, required this.steps});

  final bool visible;
  final List<GetStartedStep> steps;
}

/// Pure derivation of the Get-started card state.
///
/// Rules (ADR 0006, PRD #229, Issue #234):
/// - The four steps are always present, in fixed order; each `done` flag is a
///   pure projection of a data count crossing its threshold (stores > 0,
///   products > 0, orders > 0, staff > 1).
/// - The `createStore` step is first and acts as the recovery surface when the
///   first-run rail aborted or never ran.
/// - Later steps (`addProduct`, `makeSale`, `inviteTeam`) are visibly locked
///   while the Store step is undone.
/// - The card cannot be dismissed while the Store step is undone.
/// - The card is hidden while the first-run rail is up ([tourActive]), avoiding
///   conflicting duplicate guidance.
/// - The card is visible only when the current role is CEO, not every step is
///   done, it has not been manually dismissed on this device (when dismissal is
///   allowed), and the rail is not active. Once all steps are done it disappears.
GetStartedChecklistState computeGetStartedChecklist({
  required bool isCeo,
  required bool hasStores,
  required bool hasProducts,
  required bool hasOrders,
  required bool hasTeam,
  required bool dismissed,
  bool tourActive = false,
  bool cardHandoffPending = false,
}) {
  final steps = <GetStartedStep>[
    GetStartedStep(
      id: GetStartedStepId.createStore,
      done: hasStores,
      locked: false,
    ),
    GetStartedStep(
      id: GetStartedStepId.addProduct,
      done: hasProducts,
      locked: !hasStores,
    ),
    GetStartedStep(
      id: GetStartedStepId.makeSale,
      done: hasOrders,
      optional: true,
      locked: !hasStores,
    ),
    GetStartedStep(
      id: GetStartedStepId.inviteTeam,
      done: hasTeam,
      optional: true,
      locked: !hasStores,
    ),
  ];
  final allDone = steps.every((s) => s.done);
  final canDismiss = hasStores;
  final visible = isCeo &&
      !allDone &&
      (!dismissed || !canDismiss || cardHandoffPending) &&
      !tourActive;
  return GetStartedChecklistState(visible: visible, steps: steps);
}

// ─────────────────────────────────────────────────────────────────────────────
// Providers — the live wiring. Each input is an overridable provider, so the
// derivation is unit-testable in a ProviderContainer with no widget tree.
// ─────────────────────────────────────────────────────────────────────────────

/// Device-local dismissal latch for the Get-started card, mirroring
/// [UiHintService]'s SharedPreferences pattern. A boolean latch (not a
/// view-count): once the CEO dismisses the card it stays gone on this device
/// across restarts. Deliberately device-local and un-synced — dismissal is a
/// per-device UI preference, and completion itself is derived from data so it is
/// already cross-device correct without a stored flag. Starts `false` and
/// hydrates asynchronously from prefs; the card is briefly eligible until the
/// stored value resolves (a fresh CEO's default is not-dismissed anyway).
class GetStartedDismissalNotifier extends Notifier<bool> {
  static const prefKey = 'get_started_checklist_dismissed_v1';

  @override
  bool build() {
    _hydrate();
    return false;
  }

  Future<void> _hydrate() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getBool(prefKey) ?? false;
    if (stored) state = true;
  }

  /// Latches dismissal on and persists it. Idempotent.
  Future<void> dismiss() async {
    state = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKey, true);
  }
}

final getStartedChecklistDismissedProvider =
    NotifierProvider<GetStartedDismissalNotifier, bool>(
      GetStartedDismissalNotifier.new,
    );

/// The derived Get-started checklist state for the Home tab (Seam 3). Composes
/// the live role, the store-exists, products-exist and orders-exist streams,
/// the active-staff count, the tour state, and the device-local dismissal through
/// [computeGetStartedChecklist].
/// Consumed only by the Home-tab card; never on POS.
final getStartedChecklistProvider = Provider<GetStartedChecklistState>((ref) {
  final storesAsync = ref.watch(allStoresProvider);
  if (storesAsync.isLoading || storesAsync.hasError || !storesAsync.hasValue) {
    return const GetStartedChecklistState(visible: false, steps: []);
  }

  final isCeo = ref.watch(currentUserRoleProvider)?.slug == 'ceo';
  final hasStores = storesAsync.requireValue.isNotEmpty;
  final hasProducts = ref.watch(hasLocalProductsProvider).valueOrNull ?? false;
  final hasOrders = ref.watch(hasAnyOrderProvider).valueOrNull ?? false;

  // Active staff includes the CEO themselves, so "invited a teammate" is a count
  // strictly greater than one. Keyed by the explicit session businessId (the
  // family resolves before login binds a session-scoped provider).
  final businessId = ref.watch(currentBusinessIdProvider);
  final staffCount = businessId == null
      ? 0
      : (ref.watch(activeStaffProvider(businessId)).valueOrNull?.length ?? 0);
  final hasTeam = staffCount > 1;

  final dismissed = ref.watch(getStartedChecklistDismissedProvider);
  final tourActive = ref.watch(firstRunTourStopProvider) != TourStop.none;
  final cardHandoffPending = ref.watch(tourCardHandoffProvider);

  return computeGetStartedChecklist(
    isCeo: isCeo,
    hasStores: hasStores,
    hasProducts: hasProducts,
    hasOrders: hasOrders,
    hasTeam: hasTeam,
    dismissed: dismissed,
    tourActive: tourActive,
    cardHandoffPending: cardHandoffPending,
  );
});
