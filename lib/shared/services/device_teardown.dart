import 'package:flutter/foundation.dart';

/// Why this device is leaving its signed-in user (#573). One user per device:
/// every reason except [sessionKicked] wipes local business data; there is no
/// shared-till logout.
///
/// The per-reason flags below are the ONLY place the paths differ. The step
/// order is fixed in [DeviceTeardown.leave]:
///
///   outbox gate → detach (server RPC) → record loss → discard outbox →
///   clear local data → sign out (full logout) → clear first-load markers
enum LeaveReason {
  /// Drawer "Log Out" (also run when an admin removes the signed-in user).
  logout(gatesOnOutbox: true, wipesData: true),

  /// Resolve-unsynced-data terminal for a logout: the user exported and
  /// typed-confirmed discarding the un-pushable outbox.
  logoutDiscardingUnsynced(
    wipesData: true,
    lossReason: 'logout:user_discarded_unsynced',
    discardsOutbox: true,
  ),

  /// Self-resign (#117): push + confirm clean BEFORE the RPC detaches us.
  resign(gatesOnOutbox: true, detaches: true, wipesData: true),

  /// Resolve-unsynced-data terminal for a self-resign: detach first, so a
  /// failed RPC discards nothing.
  resignDiscardingUnsynced(
    detaches: true,
    wipesData: true,
    lossReason: 'resign:user_discarded_unsynced',
    discardsOutbox: true,
  ),

  /// The owner deleted their own business (§10.3): the `delete_business` RPC
  /// is the detach step.
  ownerDeletedBusiness(
    detaches: true,
    wipesData: true,
    lossReason: 'business_deleted:owner_delete',
  ),

  /// Another device deleted the active business (§10.3), confirmed by the
  /// cloud tombstone.
  businessDeletedRemotely(
    wipesData: true,
    lossReason: 'business_deleted:active',
  ),

  /// Single-active-session kick: another device signed in as this user.
  /// Signs out only (clears secure storage + tokens); local rows are kept,
  /// exactly as before #573.
  sessionKicked();

  const LeaveReason({
    this.gatesOnOutbox = false,
    this.detaches = false,
    this.wipesData = false,
    this.lossReason,
    this.discardsOutbox = false,
  });

  /// Runs the §3.1 wipe gate (throws when un-uploaded rows remain).
  final bool gatesOnOutbox;

  /// Requires a server-side detach callback, run after the gate.
  final bool detaches;

  /// Clears local business data and the first-load markers.
  final bool wipesData;

  /// Breadcrumb reason for the §3.1 loss record; null = no loss record.
  final String? lossReason;

  /// Discards the business's un-pushable outbox before the wipe.
  final bool discardsOutbox;
}

/// The single place that tears a signed-in user off this device (#573).
///
/// Collaborators are injected as functions so a test can pass recording
/// fakes; [AuthService] wires them to its database, sync service and
/// sign-out. Preconditions that must throw BEFORE anything is touched
/// (offline checks, van-sales offboarding guard, re-entry guards) stay with
/// the caller and run before [leave].
class DeviceTeardown {
  DeviceTeardown({
    required Future<void> Function(String businessId) assertOutboxClear,
    required Future<void> Function(String businessId, String reason)
        recordWipeLoss,
    required Future<int> Function(String businessId) discardUnsynced,
    required Future<void> Function() clearAllData,
    required Future<void> Function() signOut,
    required Future<void> Function() clearFirstLoadMarkers,
  })  : _assertOutboxClear = assertOutboxClear,
        _recordWipeLoss = recordWipeLoss,
        _discardUnsynced = discardUnsynced,
        _clearAllData = clearAllData,
        _signOut = signOut,
        _clearFirstLoadMarkers = clearFirstLoadMarkers;

  final Future<void> Function(String businessId) _assertOutboxClear;
  final Future<void> Function(String businessId, String reason)
      _recordWipeLoss;
  final Future<int> Function(String businessId) _discardUnsynced;
  final Future<void> Function() _clearAllData;
  final Future<void> Function() _signOut;
  final Future<void> Function() _clearFirstLoadMarkers;

  /// Runs the teardown for [reason] in the fixed step order.
  ///
  /// [businessId] is the tenant being left. It is required for the outbox
  /// gate and the discard; when null, the loss record is skipped (the
  /// business-deleted path can fail to resolve a tenant).
  ///
  /// [detach] is the server-side detach RPC; required when
  /// [LeaveReason.detaches]. The gate and [detach] may throw — nothing local
  /// has changed at that point. Every later step is best-effort and never
  /// blocks the sign-out.
  Future<void> leave(
    LeaveReason reason, {
    String? businessId,
    Future<void> Function()? detach,
  }) async {
    if (reason.gatesOnOutbox) {
      await _assertOutboxClear(businessId!);
    }
    if (reason.detaches) {
      await detach!();
    }
    final lossReason = reason.lossReason;
    if (lossReason != null && businessId != null) {
      await _recordWipeLoss(businessId, lossReason);
    }
    if (reason.discardsOutbox) {
      try {
        final discarded = await _discardUnsynced(businessId!);
        debugPrint(
          '[DeviceTeardown] ${reason.name}: discarded $discarded '
          'outbox row(s) for $businessId',
        );
      } catch (e) {
        debugPrint('[DeviceTeardown] ${reason.name} discard error: $e');
      }
    }
    if (reason.wipesData) {
      // A failed wipe must NOT block the sign-out.
      try {
        await _clearAllData();
      } catch (e) {
        debugPrint('[DeviceTeardown] ${reason.name} clearAllData error: $e');
      }
    }
    await _signOut();
    if (reason.wipesData) {
      // Second clear: a pull in flight can rewrite the markers between the
      // wipe and the sign-out (#313).
      try {
        await _clearFirstLoadMarkers();
      } catch (e) {
        debugPrint('[DeviceTeardown] post-wipe marker clear failed: $e');
      }
    }
  }
}
