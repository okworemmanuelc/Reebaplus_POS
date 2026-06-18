import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';

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
  static const int _shiftExpirationHours = 12;

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
        _sync.restartRealtimeSync(subBizId);
      }

      final pausedMs = prefs.getInt(_pausedTimeKey);
      if (pausedMs != null) {
        final pausedTime = DateTime.fromMillisecondsSinceEpoch(pausedMs);
        final difference = DateTime.now().difference(pausedTime);

        if (difference.inHours >= _shiftExpirationHours) {
          if (_auth.currentUser != null) {
            _auth.fullLogout();
          }
        } else {
          final intervalStr = await _db.settingsDao.get(
            'auto_lock_interval_seconds',
          );
          // Default 5 min (300 s) when unset — master plan §10.1/§8.5. The
          // Security page presets (1/3/5/10/15/30 min) have no "Never" option,
          // so auto-lock is always on, only the interval is adjustable.
          final autoLockSeconds = int.tryParse(intervalStr ?? '') ?? 300;

          if (autoLockSeconds > 0 && difference.inSeconds >= autoLockSeconds) {
            if (_auth.currentUser != null) {
              // lockApp (not logout) so the sessions row isn't revoked —
              // otherwise verifyLocalSessionStillActive on the next resume
              // would falsely trip the remote-kick path. See AuthService.
              _auth.lockApp();
            }
          }
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
