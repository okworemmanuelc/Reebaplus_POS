import 'dart:async';

import 'package:reebaplus_pos/core/services/push_messaging_port.dart';

/// In-memory [PushMessagingPort] for tests — the push analogue of
/// `InMemoryCloudTransport`. No Firebase, no platform channels; the test drives
/// the streams directly and asserts against the recorded side effects.
class InMemoryPushMessaging implements PushMessagingPort {
  InMemoryPushMessaging({
    this.permission = PushPermissionStatus.notDetermined,
    this.token,
    this.initialTap,
  });

  /// Settable current permission, returned by [currentPermission] and (after
  /// [requestPermission]) the result of prompting.
  PushPermissionStatus permission;

  /// Settable token returned by [getToken].
  String? token;

  /// The cold-start tap [initialTapMessage] returns once.
  PushMessage? initialTap;

  final StreamController<PushMessage> _foreground =
      StreamController<PushMessage>.broadcast();
  final StreamController<PushMessage> _taps =
      StreamController<PushMessage>.broadcast();
  final StreamController<String> _tokenRefreshes =
      StreamController<String>.broadcast();

  // ── Recorded side effects (for assertions) ─────────────────────────────────
  final List<PushMessage> shownNotifications = [];
  int initializeCalls = 0;
  int requestPermissionCalls = 0;
  int deleteTokenCalls = 0;
  bool initialTapConsumed = false;

  @override
  Future<void> initialize() async => initializeCalls++;

  @override
  Future<PushPermissionStatus> currentPermission() async => permission;

  @override
  Future<PushPermissionStatus> requestPermission() async {
    requestPermissionCalls++;
    return permission;
  }

  @override
  Future<String?> getToken() async => token;

  @override
  Stream<String> get tokenRefreshes => _tokenRefreshes.stream;

  @override
  Future<void> deleteToken() async {
    deleteTokenCalls++;
    token = null;
  }

  @override
  Stream<PushMessage> get foregroundMessages => _foreground.stream;

  @override
  Stream<PushMessage> get notificationTaps => _taps.stream;

  @override
  Future<PushMessage?> initialTapMessage() async {
    initialTapConsumed = true;
    final tap = initialTap;
    initialTap = null;
    return tap;
  }

  @override
  Future<void> showLocalNotification(PushMessage message) async =>
      shownNotifications.add(message);

  // ── Test drivers ────────────────────────────────────────────────────────────
  void emitForeground(PushMessage message) => _foreground.add(message);

  void emitTap(PushMessage message) => _taps.add(message);

  void emitTokenRefresh(String value) {
    token = value;
    _tokenRefreshes.add(value);
  }

  Future<void> dispose() async {
    await _foreground.close();
    await _taps.close();
    await _tokenRefreshes.close();
  }
}
