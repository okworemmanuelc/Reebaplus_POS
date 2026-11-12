import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';

/// A phone left in the background this long asks for the PIN when it comes
/// back, whatever the auto-lock setting says (#796).
///
/// This used to be a full sign-out (email + code). It must never be one: a
/// known phone always reaches the PIN screen, offline too (invariant #11),
/// and a full sign-out here skipped the un-uploaded-sales check that every
/// real logout runs through `DeviceTeardown`.
const Duration kLongAbsenceLock = Duration(hours: 12);

/// Whether a resume after [away] in the background drops to the PIN screen.
/// [autoLockSeconds] is the Settings > Security interval; 0 means off.
@visibleForTesting
bool shouldLockOnResume({
  required Duration away,
  required int autoLockSeconds,
}) {
  if (away >= kLongAbsenceLock) return true;
  return autoLockSeconds > 0 && away.inSeconds >= autoLockSeconds;
}

class AutoLockWrapper extends ConsumerStatefulWidget {
  final Widget child;

  const AutoLockWrapper({super.key, required this.child});

  /// Set this to true immediately before opening a system file/image picker.
  /// The auto-lock check will be skipped for that single resume event.
  static bool suppressNextResume = false;

  @override
  ConsumerState<AutoLockWrapper> createState() => _AutoLockWrapperState();
}

class _AutoLockWrapperState extends ConsumerState<AutoLockWrapper>
    with WidgetsBindingObserver {
  static const String _pausedTimeKey = 'app_paused_time';

  // Captured at initState — the lifecycle handler runs across `await`s and
  // must NOT touch `ref` after them (riverpod invalidates `ref` the moment
  // the element is unmounted, BEFORE State.mounted flips). See plan
  // §"Bug fix" Pattern 1.
  late final AppDatabase _db;
  late final AuthService _auth;
  late final SupabaseSyncService _sync;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _db = ref.read(databaseProvider);
    _auth = ref.read(authProvider);
    _sync = ref.read(supabaseSyncServiceProvider);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    final prefs = await SharedPreferences.getInstance();

    // iOS fires `inactive` for brief interruptions the user perceives as
    // still using the app (Notification Center, Control Center, system
    // alerts, app switcher, mid-call). Only treat genuine background
    // states as a pause so those don't accrue toward the auto-lock timer.
    final isBackgrounded =
        state == AppLifecycleState.paused || state == AppLifecycleState.hidden;
    if (isBackgrounded) {
      if (!prefs.containsKey(_pausedTimeKey)) {
        await prefs.setInt(
          _pausedTimeKey,
          DateTime.now().millisecondsSinceEpoch,
        );
      }
    } else if (state == AppLifecycleState.resumed) {
      if (AutoLockWrapper.suppressNextResume) {
        AutoLockWrapper.suppressNextResume = false;
        await prefs.remove(_pausedTimeKey);
        return;
      }
      // Single-active-device safety net: a device that was offline during
      // the kick may have missed the realtime UPDATE. Once realtime catches
      // up post-resume, the local sessions row reflects revoked_at — this
      // verifies and triggers fullLogout with the kick snackbar if so.
      unawaited(_auth.verifyLocalSessionStillActive());

      // No active session — auto-lock doesn't apply (and the timeout read
      // below is tenant-scoped, so it would throw on the unauth flow).
      // Drop any stale pause marker so it can't fire after eventual login.
      if (_auth.currentUser == null) {
        await prefs.remove(_pausedTimeKey);
        return;
      }

      // §32: re-pull the businesses row on resume so a subscription change made
      // from the admin console while this device was backgrounded is reflected
      // immediately (live lock / unlock + thank-you), not only on the next full
      // pull. Best-effort and ref-free (uses captured _sync, not ref, after the
      // awaits above); the local row update drives the gate's reactive recompute.
      final subBizId = _auth.currentUser?.businessId;
      if (subBizId != null) {
        unawaited(_sync.refreshBusinessRow(subBizId));
        // The realtime websocket is suspended by the OS while the app is
        // backgrounded (Doze / screen-off) on a physical device, and the SDK's
        // channel rejoin is not guaranteed after a long suspension — without
        // this, "live" sync silently stays dead after the app comes back even
        // though refreshBusinessRow above does a one-shot catch-up.
        unawaited(_sync.restartRealtimeSync(subBizId));
        // Beyond the businesses row above: pull the full delta since the last
        // watermark so any INSERT/UPDATE the realtime socket missed while the
        // app was backgrounded lands now — most importantly a product
        // soft-deleted on the console, which would otherwise linger (still
        // sellable) until the next login or manual refresh. Silent + debounced
        // inside catchUpPull; ref-free (uses captured _sync).
        unawaited(_sync.catchUpPull(subBizId, reason: 'app-resume'));
      }

      final pausedMs = prefs.getInt(_pausedTimeKey);
      if (pausedMs != null) {
        final pausedTime = DateTime.fromMillisecondsSinceEpoch(pausedMs);
        final difference = DateTime.now().difference(pausedTime);

        final intervalStr = await _db.settingsDao.get(
          'auto_lock_interval_seconds',
        );
        // Off (0) when unset: the short auto-lock only runs once someone
        // picks an interval in Settings > Security (owner decision
        // 2026-11-01). The long-absence lock below always applies.
        final autoLockSeconds = int.tryParse(intervalStr ?? '') ?? 0;

        if (shouldLockOnResume(
              away: difference,
              autoLockSeconds: autoLockSeconds,
            ) &&
            _auth.currentUser != null) {
          // lockApp (not logout) so the sessions row isn't revoked —
          // otherwise verifyLocalSessionStillActive on the next resume
          // would falsely trip the remote-kick path. See AuthService.
          _auth.lockApp();
        }
        await prefs.remove(_pausedTimeKey);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
