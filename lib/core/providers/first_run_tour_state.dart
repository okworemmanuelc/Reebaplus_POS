import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/sync/controllers/first_load_overlay_controller.dart';

/// The stops along the first-run onboarding rail (PRD #229, Issue #233, ADR 0026).
enum TourStop {
  /// No tour is active (completed, aborted, non-owner, or disabled).
  none,

  /// Stop 1: Create a Store (blocking spotlight overlay).
  createStore,

  /// Stop 2: Add a Product (non-blocking pointer).
  addProduct,
}

/// Pure derivation of the active tour stop.
///
/// Rules & Precedence:
/// 1. Remote off-switch wins over everything → [TourStop.none].
/// 2. Non-owners never receive a tour → [TourStop.none].
/// 3. 3 or more aborts on this device permanently suppresses the tour → [TourStop.none].
/// 4. An abort in the current session suppresses the overlay for the session → [TourStop.none].
/// 5. Products present always wins when stores also exist → [TourStop.none] (rail permanently complete).
/// 6. Settled with zero stores → [TourStop.createStore] (Stop 1, blocking).
/// 7. Settled with stores but zero products → [TourStop.addProduct] (Stop 2, non-blocking).
TourStop computeTourStop({
  required bool isOwner,
  required bool hasStores,
  required bool hasProducts,
  required bool abortedThisSession,
  required int deviceAbortCount,
  required bool remoteOffSwitch,
}) {
  if (remoteOffSwitch) return TourStop.none;
  if (!isOwner) return TourStop.none;
  if (deviceAbortCount >= 3) return TourStop.none;
  if (abortedThisSession) return TourStop.none;
  if (hasStores && hasProducts) return TourStop.none;
  if (!hasStores) return TourStop.createStore;
  return TourStop.addProduct;
}

// ─────────────────────────────────────────────────────────────────────────────
// Providers — the live wiring.
// ─────────────────────────────────────────────────────────────────────────────

/// Session-scoped abort flag. Reset on cold start / login.
class TourSessionAbortedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void abort() {
    state = true;
  }

  @visibleForTesting
  void reset() {
    state = false;
  }
}

final tourSessionAbortedProvider =
    NotifierProvider<TourSessionAbortedNotifier, bool>(
      TourSessionAbortedNotifier.new,
    );

/// Session-scoped: has the owner tapped through the welcome card yet?
///
/// Not persisted, and deliberately so. The rail's progress comes from the data
/// on every launch, so an owner who chose "I'll look around first" is offered
/// the introduction again on the next cold start rather than being written off
/// on the strength of one tap. Nothing here can mark a stop done.
class TourIntroAcknowledgedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void acknowledge() {
    state = true;
  }

  @visibleForTesting
  void reset() {
    state = false;
  }
}

final tourIntroAcknowledgedProvider =
    NotifierProvider<TourIntroAcknowledgedNotifier, bool>(
      TourIntroAcknowledgedNotifier.new,
    );

/// Session-scoped: stop one finished while the owner was being walked, so the
/// rail still owes them a hand-off to stop two.
///
/// Set from the stop transition rather than from the store count, so an owner
/// who already had a store when the app opened never sees it.
class TourHandoffNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void owe() {
    state = true;
  }

  void settle() {
    state = false;
  }
}

final tourHandoffProvider =
    NotifierProvider<TourHandoffNotifier, bool>(TourHandoffNotifier.new);

/// Device-local abort count persisted in [SharedPreferences].
///
/// If a device fails 3 times, the tour is suppressed permanently on this device.
class TourDeviceAbortCountNotifier extends Notifier<int> {
  static const prefKey = 'first_run_rail_device_abort_count_v1';
  bool _hasRecordedAbort = false;

  @override
  int build() {
    _hydrate();
    return 0;
  }

  Future<void> _hydrate() async {
    final prefs = await SharedPreferences.getInstance();
    if (_hasRecordedAbort) return;
    final count = prefs.getInt(prefKey) ?? 0;
    state = count;
  }

  /// Increments the abort count, persists it, and returns the new count.
  Future<int> recordAbort() async {
    final prefs = await SharedPreferences.getInstance();
    final persisted = prefs.getInt(prefKey) ?? state;
    final newCount = persisted + 1;
    _hasRecordedAbort = true;
    state = newCount;
    await prefs.setInt(prefKey, newCount);
    return newCount;
  }

  @visibleForTesting
  void setCount(int count) {
    state = count;
  }
}

final tourDeviceAbortCountProvider =
    NotifierProvider<TourDeviceAbortCountNotifier, int>(
      TourDeviceAbortCountNotifier.new,
    );

/// Stream provider watching system_config for the remote off-switch.
final tourRemoteOffSwitchStreamProvider = StreamProvider<bool>((ref) {
  try {
    final db = ref.watch(databaseProvider);
    return db.systemConfigDao
        .watch('feature.first_run_rail.disabled')
        .map((val) => val == 'true' || val == '"true"' || val == '1');
  } catch (_) {
    return Stream.value(false);
  }
});

/// Remote off-switch for the first-run rail.
///
/// Backed by production system_config table (`feature.first_run_rail.disabled`).
/// Falls back to `false` (tour enabled) when unset or unavailable.
final tourRemoteOffSwitchProvider = Provider<bool>((ref) {
  final asyncVal = ref.watch(tourRemoteOffSwitchStreamProvider);
  return asyncVal.valueOrNull ?? false;
});

/// The signed-in owner's first name, for the welcome card. Empty when unknown.
///
/// A named seam rather than an inline read: the card is the one part of the
/// rail that greets a person, and a test of the walking steps should not have
/// to stand up an auth service to get past it.
final tourOwnerFirstNameProvider = Provider<String>((ref) {
  final name = ref.watch(authProvider).currentUser?.name.trim() ?? '';
  if (name.isEmpty) return '';
  return name.split(' ').first;
});

/// The name of the store the owner just created, for the hand-off card.
final tourFirstStoreNameProvider = Provider<String?>((ref) {
  final stores = ref.watch(allStoresProvider).valueOrNull;
  if (stores == null || stores.isEmpty) return null;
  return stores.first.name;
});

/// The active tour stop for the running application.
///
/// Evaluates [computeTourStop] against live permissions, database presence streams,
/// and failure controllers.
final firstRunTourStopProvider = Provider<TourStop>((ref) {
  // Invariant #11: Never show a tour while initial streaming / first-load skeleton is active.
  final firstLoadInProgress = ref.watch(firstLoadSkeletonActiveProvider);
  if (firstLoadInProgress) return TourStop.none;

  final userRole = ref.watch(currentUserRoleProvider);
  final isOwner = userRole?.slug == 'ceo';
  if (!isOwner) return TourStop.none;

  final storesAsync = ref.watch(allStoresProvider);
  // While stores are resolving or in error, do not show tour
  if (storesAsync.isLoading || storesAsync.hasError) return TourStop.none;
  final stores = storesAsync.valueOrNull;
  final hasStores = stores != null && stores.isNotEmpty;

  final productsAsync = ref.watch(hasLocalProductsProvider);
  // While products are resolving or in error, do not show tour
  if (productsAsync.isLoading || productsAsync.hasError) return TourStop.none;
  final hasProducts = productsAsync.valueOrNull ?? false;

  final abortedThisSession = ref.watch(tourSessionAbortedProvider);
  final deviceAbortCount = ref.watch(tourDeviceAbortCountProvider);
  final remoteOffSwitch = ref.watch(tourRemoteOffSwitchProvider);

  return computeTourStop(
    isOwner: isOwner,
    hasStores: hasStores,
    hasProducts: hasProducts,
    abortedThisSession: abortedThisSession,
    deviceAbortCount: deviceAbortCount,
    remoteOffSwitch: remoteOffSwitch,
  );
});
