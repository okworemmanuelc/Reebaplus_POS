import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/first_load_marker_service.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

/// The single, sole source of truth for the post-login "first-load" overlay
/// (brief: First-Load "Loading your store" Overlay Redesign, §4.1).
///
/// - [hidden]: nothing shown (returning device, established store, or the brief
///   loading window has handed off to skeletons + the thin top sync line).
/// - [loading]: the brief, non-interactive centered "Setting up ‹Business›…"
///   reassurance. Shown for a minimum anti-flicker floor and a maximum cap,
///   dismissing the moment the landing screen's data is ready or the pull
///   completes.
/// - [retryNeeded]: a prominent, interactive "couldn't reach your store" card —
///   reached only after silent retries are exhausted (online) or immediately
///   (offline), and only while the store is still empty.
enum FirstLoadOverlayState { hidden, loading, retryNeeded }

/// Owns ALL timing, the retry counter, and eligibility for the first-load
/// overlay so the behaviour is testable in isolation and survives widget
/// rebuilds. It derives its state purely from five injected inputs (pull stage,
/// connectivity, store-empty, the per-business first-pull marker, and a
/// landing-ready signal) pushed in via the `set*` methods. It owns NO UI —
/// `SyncPullBanner` and the tab skeletons render this state; they never
/// re-derive it.
class FirstLoadOverlayController extends StateNotifier<FirstLoadOverlayState> {
  FirstLoadOverlayController({
    this.minDisplay = const Duration(milliseconds: 400),
    this.maxDisplay = const Duration(seconds: 2),
    this.silentRetryDelays = const [
      Duration(seconds: 2),
      Duration(seconds: 5),
    ],
    this.onRetry,
  }) : super(FirstLoadOverlayState.hidden);

  /// Anti-flicker floor: the loading overlay shows for at least this long once
  /// it appears, so a sub-second pull doesn't flash it on and off.
  final Duration minDisplay;

  /// Upper bound: the loading overlay steps aside to skeletons after this even
  /// if not everything has arrived (§4.3 / user story 10).
  final Duration maxDisplay;

  /// Silent-retry backoff schedule. Its length is also the number of silent
  /// retries attempted before surfacing [retryNeeded] (§4.7).
  final List<Duration> silentRetryDelays;

  /// Called to kick a fresh pull (a silent retry, or a manual retry from the
  /// card). Kept injectable so the controller is testable without a network.
  final Future<void> Function()? onRetry;

  // ── Injected inputs (last-known values) ──────────────────────────────────
  PullStage _stage = PullStage.idle;
  bool _online = true;
  bool _storeEmpty = false;
  bool _markerCompleted = false;
  bool _landingReady = false;

  // ── Internal episode bookkeeping ─────────────────────────────────────────
  Timer? _minTimer;
  Timer? _maxTimer;
  Timer? _retryTimer;
  bool _minElapsed = false;
  bool _maxElapsed = false;
  bool _episodeActive = false;
  // The centered overlay shows at most once per first-load episode; once it has
  // handed off to skeletons (or a failure took over) it never re-opens — e.g. a
  // silent retry's re-pull keeps the skeletons, it does not re-flash the overlay.
  bool _overlayDone = false;
  int _retryCount = 0;
  bool _disposed = false;

  int get maxSilentRetries => silentRetryDelays.length;

  // ── Input setters (each re-evaluates the state machine) ──────────────────
  void setPullStage(PullStage stage) {
    if (stage == _stage) return;
    _stage = stage;
    _evaluate();
  }

  void setOnline(bool online) {
    if (online == _online) return;
    _online = online;
    _evaluate();
  }

  void setStoreEmpty(bool empty) {
    if (empty == _storeEmpty) return;
    _storeEmpty = empty;
    _evaluate();
  }

  void setMarkerCompleted(bool completed) {
    if (completed == _markerCompleted) return;
    _markerCompleted = completed;
    _evaluate();
  }

  void setLandingReady(bool ready) {
    if (ready == _landingReady) return;
    _landingReady = ready;
    _evaluate();
  }

  /// Invoked by the prominent retry card. Clears the retry counter, optimistically
  /// hides the card (the re-pull's skeletons + thin line carry it), and triggers
  /// a fresh pull. The re-pull's `background → completed/failed` transitions then
  /// drive the state machine as usual.
  void manualRetry() {
    _retryCount = 0;
    _retryTimer?.cancel();
    // Don't re-flash the centered overlay; a manual retry surfaces via skeletons.
    _overlayDone = true;
    _set(FirstLoadOverlayState.hidden);
    unawaited(_safeRetry());
  }

  // ── State machine ────────────────────────────────────────────────────────

  void _evaluate() {
    if (_disposed) return;
    // Eligibility (§4.2): the overlay is a FIRST-LOAD affordance only. A store
    // that already has data — or one whose business carries the "first full
    // pull completed" marker (established-but-empty) — is never first-load.
    final firstLoad = _storeEmpty && !_markerCompleted;
    if (!firstLoad) {
      _settle();
      return;
    }
    switch (_stage) {
      case PullStage.background:
        _onBackground();
      case PullStage.completed:
        // Pull finished but the store is still empty → a genuinely empty store
        // (no products yet). Hand to the normal empty state, not a loader.
        _settle();
      case PullStage.failed:
        _onFailed();
      case PullStage.idle:
      case PullStage.minimum:
        // Offline first launch: a spinner could never finish — surface retry
        // straight away (§4.7 / user story 13). Online & not yet pulling: wait.
        if (!_online) _toRetryNeeded();
    }
  }

  void _onBackground() {
    // The overlay already handed off (skeletons are up): keep it that way. A
    // manual retry from the card lands here too — just clear the card.
    if (_overlayDone) {
      if (state == FirstLoadOverlayState.retryNeeded) {
        _retryCount = 0;
        _set(FirstLoadOverlayState.hidden);
      }
      return;
    }
    if (state == FirstLoadOverlayState.retryNeeded) _retryCount = 0;
    if (!_episodeActive) {
      _episodeActive = true;
      _minElapsed = false;
      _maxElapsed = false;
      _set(FirstLoadOverlayState.loading);
      _minTimer?.cancel();
      _minTimer = Timer(minDisplay, () {
        _minElapsed = true;
        _maybeDismiss();
      });
      _maxTimer?.cancel();
      _maxTimer = Timer(maxDisplay, () {
        _maxElapsed = true;
        _maybeDismiss();
      });
    } else {
      _maybeDismiss();
    }
  }

  void _maybeDismiss() {
    if (_disposed || !_episodeActive) return;
    final ready = _landingReady || _stage == PullStage.completed;
    // Dismiss as soon as the landing data is ready (respecting the min floor),
    // or unconditionally once the max cap is hit.
    if (_maxElapsed || (ready && _minElapsed)) {
      _episodeActive = false;
      _overlayDone = true;
      _cancelLoadingTimers();
      _set(FirstLoadOverlayState.hidden);
    }
  }

  void _onFailed() {
    _episodeActive = false;
    _cancelLoadingTimers();
    // Once a failure happens we never re-open the centered overlay; skeletons +
    // the thin top line carry any silent re-pull quietly.
    _overlayDone = true;
    if (!_online) {
      _toRetryNeeded();
      return;
    }
    if (_retryCount < maxSilentRetries) {
      _retryCount++;
      _set(FirstLoadOverlayState.hidden);
      _scheduleSilentRetry();
    } else {
      _toRetryNeeded();
    }
  }

  void _scheduleSilentRetry() {
    final idx = (_retryCount - 1).clamp(0, silentRetryDelays.length - 1);
    _retryTimer?.cancel();
    _retryTimer = Timer(silentRetryDelays[idx], () {
      if (_disposed) return;
      unawaited(_safeRetry());
    });
  }

  Future<void> _safeRetry() async {
    final cb = onRetry;
    if (cb == null) return;
    try {
      await cb();
    } catch (_) {
      // pullChanges sets pullStatus → failed, which flows back in via
      // setPullStage; nothing to do here.
    }
  }

  void _toRetryNeeded() {
    _episodeActive = false;
    _cancelLoadingTimers();
    _retryTimer?.cancel();
    _set(FirstLoadOverlayState.retryNeeded);
  }

  /// Terminal "not a first load" resolution: cancel everything and reset the
  /// episode so a later genuine first load (e.g. after a wipe within the same
  /// session) starts clean.
  void _settle() {
    _episodeActive = false;
    _overlayDone = false;
    _retryCount = 0;
    _minElapsed = false;
    _maxElapsed = false;
    _cancelLoadingTimers();
    _retryTimer?.cancel();
    _set(FirstLoadOverlayState.hidden);
  }

  void _cancelLoadingTimers() {
    _minTimer?.cancel();
    _maxTimer?.cancel();
  }

  void _set(FirstLoadOverlayState next) {
    if (_disposed) return;
    if (state != next) state = next;
  }

  @override
  void dispose() {
    _disposed = true;
    _minTimer?.cancel();
    _maxTimer?.cancel();
    _retryTimer?.cancel();
    super.dispose();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Input providers — overridable in tests (Seam A). Each is a thin, pure
// projection of an existing app signal so the controller can be driven with
// fakes in a ProviderContainer without any widget tree.
// ─────────────────────────────────────────────────────────────────────────────

/// Lifts the sync service's `isOnline` ValueNotifier into Riverpod (mirrors
/// [pullStatusProvider]).
final isOnlineNotifierProvider = ChangeNotifierProvider<ValueNotifier<bool>>((
  ref,
) {
  return ref.watch(supabaseSyncServiceProvider).isOnline;
});

/// Online / offline, as a plain bool the controller consumes.
final firstLoadOnlineProvider = Provider<bool>((ref) {
  return ref.watch(isOnlineNotifierProvider).value;
});

/// True while the local store has no products yet — the primary, self-healing
/// "store is empty" truth (live row counts via a business-scoped DAO read, never
/// a raw select). Reuses the distinct-filtered [hasLocalProductsProvider].
final firstLoadStoreEmptyProvider = Provider<bool>((ref) {
  final hasProducts = ref.watch(hasLocalProductsProvider).valueOrNull ?? false;
  return !hasProducts;
});

/// The role-aware "landing screen data is ready" signal. Both the POS landing
/// (products present) and the Home/dashboard landing default to products-present
/// as the safe universal fallback (§4.3 / §7).
final firstLoadLandingReadyProvider = Provider<bool>((ref) {
  return ref.watch(hasLocalProductsProvider).valueOrNull ?? false;
});

/// Whether THIS business has a "first full pull completed" marker on this device
/// (§4.2). False until resolved — which keeps the overlay eligible on a genuine
/// fresh device, and is corrected to true on a returning device (whose store is
/// non-empty anyway, so the overlay stays hidden).
final firstPullCompletedProvider = FutureProvider<bool>((ref) async {
  final businessId = ref.watch(
    authProvider.select((a) => a.currentUser?.businessId),
  );
  if (businessId == null) return false;
  return FirstLoadMarkerService.hasCompletedPull(businessId);
});

/// The current pull stage, projected from [pullStatusProvider].
final pullStageProvider = Provider<PullStage>((ref) {
  return ref.watch(pullStatusProvider).value.stage;
});

/// True while this is a genuine first load on this device — the store is empty
/// and the business has no "first full pull completed" marker yet. Used to
/// suppress the populated-device error pill (the prominent retry card / skeletons
/// own the empty-store failure experience instead).
final firstLoadActiveProvider = Provider<bool>((ref) {
  if (!ref.watch(firstLoadStoreEmptyProvider)) return false;
  final marker = ref.watch(firstPullCompletedProvider).valueOrNull ?? false;
  return !marker;
});

/// True when the tab skeletons should render: a first-load pull is streaming
/// (or briefly between silent-retry attempts), the store is still empty, and the
/// centered overlay / retry card is NOT showing (those take visual precedence).
/// The tab screens watch this to swap their empty body for a skeleton, resolving
/// to real content the moment data streams in (store no longer empty).
final firstLoadSkeletonActiveProvider = Provider<bool>((ref) {
  // The loading overlay and the retry card own the screen when present.
  if (ref.watch(firstLoadOverlayProvider) != FirstLoadOverlayState.hidden) {
    return false;
  }
  if (!ref.watch(firstLoadStoreEmptyProvider)) return false;
  final marker = ref.watch(firstPullCompletedProvider).valueOrNull ?? false;
  if (marker) return false;
  final stage = ref.watch(pullStageProvider);
  return stage == PullStage.background || stage == PullStage.failed;
});

/// The sole source of truth for the first-load overlay state. Wires the live
/// input providers into a stable [FirstLoadOverlayController] instance.
final firstLoadOverlayProvider =
    StateNotifierProvider<FirstLoadOverlayController, FirstLoadOverlayState>((
      ref,
    ) {
      final controller = FirstLoadOverlayController(
        onRetry: () async {
          final businessId = ref.read(authProvider).currentUser?.businessId;
          if (businessId == null) return;
          await ref.read(supabaseSyncServiceProvider).pullChanges(businessId);
        },
      );

      // Seed initial inputs. Stage is seeded LAST so emptiness/marker are known
      // before a (possibly already-running) background pull is evaluated.
      controller.setOnline(ref.read(firstLoadOnlineProvider));
      controller.setStoreEmpty(ref.read(firstLoadStoreEmptyProvider));
      controller.setMarkerCompleted(
        ref.read(firstPullCompletedProvider).valueOrNull ?? false,
      );
      controller.setLandingReady(ref.read(firstLoadLandingReadyProvider));
      controller.setPullStage(ref.read(pullStageProvider));

      // Push subsequent input changes into the controller.
      ref.listen(firstLoadOnlineProvider, (_, v) => controller.setOnline(v));
      ref.listen(
        firstLoadStoreEmptyProvider,
        (_, v) => controller.setStoreEmpty(v),
      );
      ref.listen(
        firstPullCompletedProvider,
        (_, v) => controller.setMarkerCompleted(v.valueOrNull ?? false),
      );
      ref.listen(
        firstLoadLandingReadyProvider,
        (_, v) => controller.setLandingReady(v),
      );
      ref.listen(pullStageProvider, (_, v) => controller.setPullStage(v));

      return controller;
    });
