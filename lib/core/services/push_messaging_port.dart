import 'dart:async';

/// The Android notification channel id for console-broadcast announcements.
///
/// MUST stay byte-identical to `ANNOUNCEMENTS_CHANNEL_ID` in the send-push edge
/// function (`supabase/functions/send-push/fcm.ts`) and the FCM default-channel
/// meta-data in `AndroidManifest.xml`. A mismatch makes Android silently drop
/// the channel, losing the notification's importance and sound (#138).
const String kAnnouncementsChannelId = 'reebaplus_announcements';

/// Where the OS notification permission currently stands.
enum PushPermissionStatus {
  granted,

  /// Denied — includes "permanently denied", where the client can no longer
  /// reprompt and must deep-link the user to the OS settings screen.
  denied,

  /// Never asked yet (Android 13+ before the first prompt).
  notDetermined,
}

/// A push message flattened to just the fields the client consumes.
///
/// [data] values are all strings (an FCM v1 requirement); the accessors name
/// the keys the send-push edge function sets (`fcm.ts buildFcmMessages`):
/// `notification_id`, `type`, `severity`, `business_id`.
class PushMessage {
  final String? title;
  final String? body;
  final Map<String, String> data;

  const PushMessage({this.title, this.body, this.data = const {}});

  /// The `public.notifications` row id — used to open + mark the broadcast read.
  String? get notificationId => data['notification_id'];

  /// The notification `type` (only `console_broadcast` is pushed today).
  String? get type => data['type'];

  /// `info` / `warning` / `alert`; unknown degrades to `info`.
  String get severity => data['severity'] ?? 'info';

  String? get businessId => data['business_id'];

  bool get isConsoleBroadcast => type == 'console_broadcast';
}

/// The seam between the app and the OS push stack (FCM + local notifications),
/// mirroring [CloudTransport] (ADR 0001). A deep module: Firebase init, the
/// announcements channel, the background isolate handler, permission plumbing,
/// and `flutter_local_notifications` all hide behind these members.
///
/// **Invariant (ADR 0018): a push is an alert only — no member here writes
/// Drift.** The notification row of record always arrives via the Sync Engine,
/// so the client persists nothing from a push payload.
abstract interface class PushMessagingPort {
  /// Initialise Firebase, register the announcements channel, and wire the
  /// message/tap streams. Idempotent, and safe to call when unconfigured
  /// (non-Android / no `google-services.json`) — it degrades to a no-op.
  Future<void> initialize();

  /// The current OS notification-permission status (no prompt shown).
  Future<PushPermissionStatus> currentPermission();

  /// Trigger the OS permission prompt (Android 13+ `POST_NOTIFICATIONS`) and
  /// return the resulting status. A no-op returning `granted` on pre-13.
  Future<PushPermissionStatus> requestPermission();

  /// This device's current FCM registration token, or null when unavailable
  /// (unconfigured, offline on first fetch, permission denied).
  Future<String?> getToken();

  /// Fires whenever FCM rotates this device's token.
  Stream<String> get tokenRefreshes;

  /// Drop the FCM token (logout) so a re-login mints a fresh one.
  Future<void> deleteToken();

  /// Foreground messages. Android does NOT display these itself, so the app
  /// shows them via [showLocalNotification].
  Stream<PushMessage> get foregroundMessages;

  /// A tap that brought the app to the foreground: a background/killed-app
  /// notification tap, or a tap on a foreground local notification we showed.
  /// Every tap flows through here.
  Stream<PushMessage> get notificationTaps;

  /// The tap that cold-started the app from a killed state, if any. Consumed
  /// once, then replayed after the app shell mounts.
  Future<PushMessage?> initialTapMessage();

  /// Display [message] as a local notification on the announcements channel.
  Future<void> showLocalNotification(PushMessage message);
}
