import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import 'package:reebaplus_pos/core/services/push_messaging_port.dart';
import 'package:reebaplus_pos/shared/services/device_registry_service.dart';

/// App-level push orchestrator (Slice 2, #138).
///
/// Owns the FCM token lifecycle (register on sign-in / permission-grant / token
/// refresh / reconnect; clear on logout), foreground display, and tap routing.
/// It sits behind the [PushMessagingPort] seam, so it is fully testable against
/// `InMemoryPushMessaging` with no Firebase.
///
/// **Invariant (ADR 0018): nothing here writes Drift from a push.** A tap only
/// opens the in-app bell and marks the row read (a no-op if the Sync Engine has
/// not pulled the row yet); the row of record always arrives via sync.
///
/// Sign-in/out is driven from the app shell via [onSignedIn] / [onSignedOut]
/// (which already observes `AuthService`), keeping this service free of the auth
/// layer and trivial to test.
class PushNotificationService {
  PushNotificationService({
    required PushMessagingPort port,
    required DeviceRegistryService deviceRegistry,
  })  : _port = port,
        _deviceRegistry = deviceRegistry;

  final PushMessagingPort _port;
  final DeviceRegistryService _deviceRegistry;

  // Bound by the UI host (needs a navigator/context). A broadcast tap routes
  // through these; they stay null until the app shell binds them.
  void Function()? _openNotifications;
  void Function(String notificationId)? _markRead;
  // Shopper push taps (#476); bound by the Shopper surface (#434). Null until
  // then, so a Shopper tap is a no-op rather than opening the business bell.
  void Function(PushMessage message)? _openShopperPush;

  StreamSubscription<PushMessage>? _foregroundSub;
  StreamSubscription<PushMessage>? _tapSub;
  StreamSubscription<String>? _tokenRefreshSub;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  /// The business bound at the last observed sign-in — cached so logout can
  /// clear the cloud token, and so a reconnect/token-refresh can re-register,
  /// without reaching back into the auth layer.
  String? _currentBusinessId;

  /// A Shopper login is signed in on this phone (#476). Only used when no
  /// business is bound: a business phone's `devices` row already carries the
  /// same login, so it receives Shopper pushes without a second row.
  bool _shopperSignedIn = false;
  bool _online = true;
  bool _started = false;

  /// Wire the port + connectivity triggers. Call once after the first frame
  /// (never blocks app entry — invariant #11). Idempotent.
  ///
  /// [connectivityStream] is injectable so tests can drive reconnects without
  /// the `connectivity_plus` platform channel; production passes none and uses
  /// the real stream.
  Future<void> start({
    Stream<List<ConnectivityResult>>? connectivityStream,
  }) async {
    if (_started) return;
    _started = true;

    await _port.initialize();

    _foregroundSub = _port.foregroundMessages.listen(_onForegroundMessage);
    _tapSub = _port.notificationTaps.listen(handleTap);
    _tokenRefreshSub = _port.tokenRefreshes.listen(_onTokenRefresh);
    _connectivitySub = (connectivityStream ?? Connectivity().onConnectivityChanged)
        .listen(_onConnectivityChanged);

    // A returning device may already be signed in before start() runs; register
    // now that the port is live.
    await _registerIfPermitted();
  }

  /// Bind the UI actions a broadcast tap triggers: open the in-app bell and mark
  /// the row read. Called by the app shell once it can supply a navigator.
  void bindTapActions({
    required void Function() openNotifications,
    required void Function(String notificationId) markRead,
  }) {
    _openNotifications = openNotifications;
    _markRead = markRead;
  }

  /// Bind what a Shopper push tap opens (#434's Shopper surface). Until bound,
  /// a Shopper tap does nothing — it never opens the business bell.
  void bindShopperTapAction(void Function(PushMessage message) openShopperPush) {
    _openShopperPush = openShopperPush;
  }

  // ── Sign-in / sign-out (driven by the app shell) ────────────────────────────
  /// A user signed in on this device (or app-open re-auth). Registers the token
  /// if OS permission is already granted; otherwise the soft-ask flow will.
  Future<void> onSignedIn(String businessId) async {
    _currentBusinessId = businessId;
    await _registerIfPermitted();
  }

  /// The device signed out — clear the token client-side (Firebase) AND null it
  /// in `devices` (invariant #2). [businessId] is the business that was bound.
  Future<void> onSignedOut(String businessId) async {
    if (_currentBusinessId == businessId) _currentBusinessId = null;
    await clearToken(businessId);
  }

  /// A Shopper signed in on this phone (#476). With no business bound this
  /// registers the token on a business-less `devices` row (by auth user). With
  /// a business bound it does nothing extra: that row already routes both.
  Future<void> onShopperSignedIn() async {
    _shopperSignedIn = true;
    await _registerIfPermitted();
  }

  /// The Shopper signed out. Clears the token only when no business is bound —
  /// a business phone keeps its token so staff pushes keep arriving.
  Future<void> onShopperSignedOut() async {
    final wasSignedIn = _shopperSignedIn;
    _shopperSignedIn = false;
    if (!wasSignedIn || _currentBusinessId != null) return;
    await _port.deleteToken();
    await _deviceRegistry.clearShopperPushToken();
  }

  // ── Permission + registration ───────────────────────────────────────────────
  Future<PushPermissionStatus> currentPermission() => _port.currentPermission();

  /// Prompt for OS permission and, if granted, register the token immediately.
  /// Returns the resulting status so the caller can guide a denied user to the
  /// OS settings screen.
  Future<PushPermissionStatus> requestPermissionAndRegister() async {
    final status = await _port.requestPermission();
    if (status == PushPermissionStatus.granted) {
      final businessId = _currentBusinessId;
      if (businessId != null) {
        await registerToken(businessId, permissionGranted: true);
      } else if (_shopperSignedIn) {
        await _registerShopperToken(permissionGranted: true);
      }
    }
    return status;
  }

  /// Fetch the current token and upsert it onto this device's `devices` row.
  /// The registry swallows errors, so this never throws.
  Future<void> registerToken(
    String businessId, {
    required bool permissionGranted,
  }) async {
    final token = await _port.getToken();
    if (token == null || token.isEmpty) return;
    await _deviceRegistry.recordPushToken(
      businessId: businessId,
      token: token,
      permissionGranted: permissionGranted,
    );
  }

  /// Business-less phone: register the token by auth user (#476).
  Future<void> _registerShopperToken({required bool permissionGranted}) async {
    final token = await _port.getToken();
    if (token == null || token.isEmpty) return;
    await _deviceRegistry.recordShopperPushToken(
      token: token,
      permissionGranted: permissionGranted,
    );
  }

  /// Drop the token client-side (Firebase) AND null it in `devices`.
  Future<void> clearToken(String businessId) async {
    await _port.deleteToken();
    await _deviceRegistry.clearPushToken(businessId: businessId);
  }

  // ── Cold-start tap replay ────────────────────────────────────────────────────
  /// Route the tap that cold-started the app, if any. Called after the app shell
  /// mounts (post-frame), never before auth/PIN. No-op when there was none.
  Future<void> replayInitialTap() async {
    final tap = await _port.initialTapMessage();
    if (tap != null) handleTap(tap);
  }

  // ── Internals ───────────────────────────────────────────────────────────────
  void _onForegroundMessage(PushMessage message) {
    // Android does not display a foreground push itself — show it ourselves on
    // the announcements channel, using the server's severity-driven title/body.
    unawaited(_port.showLocalNotification(message));
  }

  /// A tapped notification (foreground, background, or cold-start). A console
  /// broadcast opens the in-app bell and marks the row read; a Shopper push
  /// (#476) goes to the Shopper tap action and never to the business bell.
  /// Public for the cold-start replay + tests.
  void handleTap(PushMessage message) {
    if (message.isShopperPush) {
      _openShopperPush?.call(message);
      return;
    }
    if (!message.isConsoleBroadcast) return;
    if (_currentBusinessId == null) return; // not signed in — ignore.
    _openNotifications?.call();
    final id = message.notificationId;
    if (id != null && id.isNotEmpty) _markRead?.call(id);
  }

  Future<void> _onTokenRefresh(String token) async {
    final businessId = _currentBusinessId;
    if (businessId == null && !_shopperSignedIn) return;
    final granted =
        await _port.currentPermission() == PushPermissionStatus.granted;
    if (businessId != null) {
      await _deviceRegistry.recordPushToken(
        businessId: businessId,
        token: token,
        permissionGranted: granted,
      );
    } else {
      await _deviceRegistry.recordShopperPushToken(
        token: token,
        permissionGranted: granted,
      );
    }
  }

  /// Register for whoever is signed in: the business row wins (it also routes
  /// Shopper pushes for the same login); otherwise a signed-in Shopper.
  Future<void> _registerIfPermitted() async {
    final businessId = _currentBusinessId;
    if (businessId == null && !_shopperSignedIn) return;
    if (await _port.currentPermission() != PushPermissionStatus.granted) return;
    if (businessId != null) {
      await registerToken(businessId, permissionGranted: true);
    } else {
      await _registerShopperToken(permissionGranted: true);
    }
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    final online = results.any((r) => r != ConnectivityResult.none);
    final wasOnline = _online;
    _online = online;
    // Re-register only on the offline→online edge — a device that signed in
    // offline lands its token the moment a connection returns.
    if (online && !wasOnline) unawaited(_registerIfPermitted());
  }

  void dispose() {
    _foregroundSub?.cancel();
    _tapSub?.cancel();
    _tokenRefreshSub?.cancel();
    _connectivitySub?.cancel();
  }
}
