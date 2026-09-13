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

/// Device-local abort count persisted in [SharedPreferences].
///
/// If a device fails 3 times, the tour is suppressed permanently on this device.
class TourDeviceAbortCountNotifier extends Notifier<int> {
  static const prefKey = 'first_run_rail_device_abort_count_v1';

  @override
  int build() {
    _hydrate();
    return 0;
  }

  Future<void> _hydrate() async {
    final prefs = await SharedPreferences.getInstance();
    final count = prefs.getInt(prefKey) ?? 0;
    state = count;
  }

  /// Increments the abort count, persists it, and returns the new count.
  Future<int> recordAbort() async {
    final newCount = state + 1;
    state = newCount;
    final prefs = await SharedPreferences.getInstance();
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

/// Remote off-switch for the first-run rail.
///
/// Can be wired to remote config or server settings. Defaults to `false` (tour enabled).
final tourRemoteOffSwitchProvider = Provider<bool>((ref) => false);

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
