import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';

/// Catches the app up when it comes back to the foreground.
///
/// This is what is left of the old `AutoLockWrapper` now the app never locks
/// (owner decision #812: no PIN, no auto-lock). On every resume it checks the
/// local session is still active, and — for a signed-in user — refreshes the
/// businesses row, restarts realtime and pulls the delta the suspended socket
/// may have missed.
class AppResumeSync extends ConsumerStatefulWidget {
  final Widget child;

  const AppResumeSync({super.key, required this.child});

  /// Set to true immediately before opening a system camera / file / image
  /// picker: coming back from it is not a return from the background, so the
  /// next resume skips the catch-up work once.
  static bool suppressNextResume = false;

  @override
  ConsumerState<AppResumeSync> createState() => _AppResumeSyncState();
}

class _AppResumeSyncState extends ConsumerState<AppResumeSync>
    with WidgetsBindingObserver {
  // Captured at initState — never touch `ref` from the lifecycle handler
  // (riverpod invalidates `ref` the moment the element is unmounted, BEFORE
  // State.mounted flips). See plan §"Bug fix" Pattern 1.
  late final AuthService _auth;
  late final SupabaseSyncService _sync;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _auth = ref.read(authProvider);
    _sync = ref.read(supabaseSyncServiceProvider);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (AppResumeSync.suppressNextResume) {
      AppResumeSync.suppressNextResume = false;
      return;
    }

    // Single-active-device safety net: a device that was offline during
    // the kick may have missed the realtime UPDATE. Once realtime catches
    // up post-resume, the local sessions row reflects revoked_at — this
    // verifies and triggers fullLogout with the kick snackbar if so.
    unawaited(_auth.verifyLocalSessionStillActive());

    final businessId = _auth.currentUser?.businessId;
    if (businessId == null) return;

    // §32: re-pull the businesses row on resume so a subscription change made
    // from the admin console while this device was backgrounded is reflected
    // immediately, not only on the next full pull.
    unawaited(_sync.refreshBusinessRow(businessId));
    // The realtime websocket is suspended by the OS while the app is
    // backgrounded (Doze / screen-off) on a physical device, and the SDK's
    // channel rejoin is not guaranteed after a long suspension — without
    // this, "live" sync silently stays dead after the app comes back.
    unawaited(_sync.restartRealtimeSync(businessId));
    // Pull the full delta since the last watermark so any INSERT/UPDATE the
    // realtime socket missed while the app was backgrounded lands now — most
    // importantly a product soft-deleted on the console, which would otherwise
    // linger (still sellable). Silent + debounced inside catchUpPull.
    unawaited(_sync.catchUpPull(businessId, reason: 'app-resume'));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
