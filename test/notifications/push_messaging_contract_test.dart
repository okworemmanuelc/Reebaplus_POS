import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/services/push_messaging_port.dart';

// Pins the client-side push contract that the send-push edge function
// (supabase/functions/send-push/fcm.ts) depends on: the announcements channel
// id and the `data` keys a broadcast carries. A drift here is exactly what
// silently drops a notification's channel or breaks tap routing (#138).
void main() {
  test('announcements channel id matches the edge function constant', () {
    // Must equal ANNOUNCEMENTS_CHANNEL_ID in fcm.ts + the manifest meta-data.
    expect(kAnnouncementsChannelId, 'reebaplus_announcements');
  });

  group('PushMessage.data accessors (fcm.ts buildFcmMessages keys)', () {
    test('parse the broadcast payload keys', () {
      const message = PushMessage(
        title: 'Reebaplus — Alert',
        body: 'Head office announcement',
        data: {
          'notification_id': 'notif-123',
          'type': 'console_broadcast',
          'severity': 'alert',
          'business_id': 'biz-1',
        },
      );

      expect(message.notificationId, 'notif-123');
      expect(message.type, 'console_broadcast');
      expect(message.severity, 'alert');
      expect(message.businessId, 'biz-1');
      expect(message.isConsoleBroadcast, isTrue);
    });

    test('severity defaults to info when absent', () {
      const message = PushMessage(data: {'type': 'console_broadcast'});
      expect(message.severity, 'info');
      expect(message.notificationId, isNull);
    });

    test('a non-broadcast type is not a console broadcast', () {
      const message = PushMessage(data: {'type': 'new_order'});
      expect(message.isConsoleBroadcast, isFalse);
    });
  });
}
