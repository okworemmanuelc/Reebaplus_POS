import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:reebaplus_pos/core/services/push_messaging_port.dart';

/// Top-level FCM background handler (isolate entry point).
///
/// Our broadcast messages carry a `notification` block, so Android's system
/// tray displays them automatically while the app is backgrounded/killed — this
/// handler does nothing on purpose. **It MUST NOT write Drift** (ADR 0018): the
/// notification row of record arrives via the Sync Engine, never a push payload.
@pragma('vm:entry-point')
Future<void> firebasePushBackgroundHandler(RemoteMessage message) async {
  // Intentionally empty — the OS renders the notification; nothing to persist.
}

/// Production [PushMessagingPort]: `firebase_messaging` for transport +
/// `flutter_local_notifications` for foreground display and the announcements
/// channel.
///
/// Every Firebase call is Android-guarded and wrapped, so an unconfigured build
/// (iOS without APNs, desktop, tests, or a missing `google-services.json`)
/// degrades to an inert seam rather than throwing — device/token work must
/// never break login or sync.
class FirebasePushMessaging implements PushMessagingPort {
  FirebasePushMessaging();

  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  final StreamController<PushMessage> _foreground =
      StreamController<PushMessage>.broadcast();
  final StreamController<PushMessage> _taps =
      StreamController<PushMessage>.broadcast();
  final StreamController<String> _tokenRefreshes =
      StreamController<String>.broadcast();

  /// True once initialize() succeeded on a supported platform. Gates every
  /// Firebase call so an unconfigured build no-ops instead of throwing.
  bool _available = false;
  bool _initialized = false;

  /// Android is the only wired platform (iOS APNs deferred, #138). `flutter
  /// test` runs on the host VM where this is false, so the adapter stays inert.
  bool get _supported => !kIsWeb && Platform.isAndroid;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    if (!_supported) return;
    try {
      await Firebase.initializeApp();

      // High-importance announcements channel so an alert actually buzzes. Its
      // id MUST equal [kAnnouncementsChannelId] / the edge fn / the manifest.
      const channel = AndroidNotificationChannel(
        kAnnouncementsChannelId,
        'Announcements',
        description: 'Important announcements from your operator.',
        importance: Importance.high,
      );
      final androidPlugin =
          _local.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.createNotificationChannel(channel);

      await _local.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
        onDidReceiveNotificationResponse: _onLocalNotificationTap,
      );

      FirebaseMessaging.onBackgroundMessage(firebasePushBackgroundHandler);
      FirebaseMessaging.onMessage.listen((m) => _foreground.add(_parse(m)));
      FirebaseMessaging.onMessageOpenedApp.listen((m) => _taps.add(_parse(m)));
      FirebaseMessaging.instance.onTokenRefresh.listen(_tokenRefreshes.add);

      _available = true;
    } catch (e) {
      debugPrint('[Push] initialize failed (degrading to no-op): $e');
      _available = false;
    }
  }

  /// A tap on a foreground local notification we showed — parse the payload
  /// (the message `data`) back and route it like any other tap.
  void _onLocalNotificationTap(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    try {
      final decoded = jsonDecode(payload) as Map<String, dynamic>;
      _taps.add(PushMessage(data: _stringifyData(decoded)));
    } catch (e) {
      debugPrint('[Push] local-notification payload parse failed: $e');
    }
  }

  PushMessage _parse(RemoteMessage m) => PushMessage(
        title: m.notification?.title,
        body: m.notification?.body,
        data: _stringifyData(m.data),
      );

  /// FCM v1 `data` values are always strings, but the SDK types the map as
  /// `Map<String, dynamic>`; coerce defensively so downstream reads are typed.
  Map<String, String> _stringifyData(Map<String, dynamic> data) =>
      data.map((k, v) => MapEntry(k, v?.toString() ?? ''));

  @override
  Future<PushPermissionStatus> currentPermission() async {
    if (!_available) return PushPermissionStatus.notDetermined;
    try {
      final settings =
          await FirebaseMessaging.instance.getNotificationSettings();
      return _mapAuthStatus(settings.authorizationStatus);
    } catch (e) {
      debugPrint('[Push] currentPermission failed: $e');
      return PushPermissionStatus.notDetermined;
    }
  }

  @override
  Future<PushPermissionStatus> requestPermission() async {
    if (!_available) return PushPermissionStatus.notDetermined;
    try {
      final settings = await FirebaseMessaging.instance.requestPermission();
      return _mapAuthStatus(settings.authorizationStatus);
    } catch (e) {
      debugPrint('[Push] requestPermission failed: $e');
      return PushPermissionStatus.notDetermined;
    }
  }

  PushPermissionStatus _mapAuthStatus(AuthorizationStatus status) {
    switch (status) {
      case AuthorizationStatus.authorized:
      case AuthorizationStatus.provisional:
        return PushPermissionStatus.granted;
      case AuthorizationStatus.denied:
        return PushPermissionStatus.denied;
      case AuthorizationStatus.notDetermined:
        return PushPermissionStatus.notDetermined;
    }
  }

  @override
  Future<String?> getToken() async {
    if (!_available) return null;
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (e) {
      debugPrint('[Push] getToken failed: $e');
      return null;
    }
  }

  @override
  Stream<String> get tokenRefreshes => _tokenRefreshes.stream;

  @override
  Future<void> deleteToken() async {
    if (!_available) return;
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (e) {
      debugPrint('[Push] deleteToken failed: $e');
    }
  }

  @override
  Stream<PushMessage> get foregroundMessages => _foreground.stream;

  @override
  Stream<PushMessage> get notificationTaps => _taps.stream;

  @override
  Future<PushMessage?> initialTapMessage() async {
    if (!_available) return null;
    try {
      final m = await FirebaseMessaging.instance.getInitialMessage();
      return m == null ? null : _parse(m);
    } catch (e) {
      debugPrint('[Push] getInitialMessage failed: $e');
      return null;
    }
  }

  @override
  Future<void> showLocalNotification(PushMessage message) async {
    if (!_available) return;
    try {
      // Stable per-broadcast id so the same announcement can't stack twice.
      final id = (message.notificationId?.hashCode ??
              DateTime.now().millisecondsSinceEpoch) &
          0x7fffffff;
      await _local.show(
        id,
        message.title ?? 'Reebaplus Announcement',
        message.body ?? '',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            kAnnouncementsChannelId,
            'Announcements',
            channelDescription: 'Important announcements from your operator.',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        payload: jsonEncode(message.data),
      );
    } catch (e) {
      debugPrint('[Push] showLocalNotification failed: $e');
    }
  }
}
