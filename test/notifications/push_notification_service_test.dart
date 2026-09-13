import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/services/push_messaging_port.dart';
import 'package:reebaplus_pos/shared/services/device_registry_service.dart';
import 'package:reebaplus_pos/shared/services/push_notification_service.dart';

import '../helpers/in_memory_push_messaging.dart';

// Slice 2 of #138: the push orchestrator, exercised end-to-end against the
// in-memory port + a recording registry (no Firebase, no Supabase). Covers
// foreground display, tap routing (broadcast opens the bell + marks read; a
// non-broadcast is ignored; a signed-out tap is ignored), the token lifecycle
// (register on sign-in / soft-ask grant / token refresh / reconnect; clear on
// sign-out), and cold-start tap replay.

class _RecordedToken {
  _RecordedToken(this.businessId, this.token, this.permissionGranted);
  final String businessId;
  final String token;
  final bool permissionGranted;
}

/// Records the token calls the orchestrator makes, without touching Supabase.
class _FakeDeviceRegistry implements DeviceRegistryService {
  final List<_RecordedToken> recorded = [];
  final List<String> cleared = [];

  @override
  Future<void> recordPushToken({
    required String businessId,
    required String token,
    required bool permissionGranted,
  }) async {
    recorded.add(_RecordedToken(businessId, token, permissionGranted));
  }

  @override
  Future<void> clearPushToken({required String businessId}) async {
    cleared.add(businessId);
  }

  @override
  Future<void> recordPresence({
    required String businessId,
    required String userId,
    String? userEmail,
    String? userName,
  }) async {}
}

void main() {
  late InMemoryPushMessaging port;
  late _FakeDeviceRegistry registry;
  late StreamController<List<ConnectivityResult>> connectivity;
  late PushNotificationService service;
  late int openCount;
  String? lastMarkReadId;

  setUp(() async {
    port = InMemoryPushMessaging();
    registry = _FakeDeviceRegistry();
    connectivity = StreamController<List<ConnectivityResult>>.broadcast();
    service =
        PushNotificationService(port: port, deviceRegistry: registry);
    openCount = 0;
    lastMarkReadId = null;
    service.bindTapActions(
      openNotifications: () => openCount++,
      markRead: (id) => lastMarkReadId = id,
    );
    await service.start(connectivityStream: connectivity.stream);
  });

  tearDown(() async {
    service.dispose();
    await connectivity.close();
    await port.dispose();
  });

  // Flush the microtask/event queue so stream deliveries + async handlers run.
  Future<void> flush() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  PushMessage broadcast({String id = 'notif-1', String severity = 'info'}) =>
      PushMessage(
        title: 'Reebaplus Announcement',
        body: 'Hello team',
        data: {
          'notification_id': id,
          'type': 'console_broadcast',
          'severity': severity,
          'business_id': 'biz-1',
        },
      );

  group('display + tap routing', () {
    test('a foreground message is shown as a local notification', () async {
      port.emitForeground(broadcast());
      await flush();
      expect(port.shownNotifications, hasLength(1));
      expect(port.shownNotifications.first.notificationId, 'notif-1');
    });

    test('a console_broadcast tap opens the bell and marks it read', () async {
      await service.onSignedIn('biz-1');
      port.emitTap(broadcast(id: 'notif-9'));
      await flush();
      expect(openCount, 1);
      expect(lastMarkReadId, 'notif-9');
    });

    test('a non-broadcast tap does nothing', () async {
      await service.onSignedIn('biz-1');
      port.emitTap(
        const PushMessage(data: {'type': 'new_order', 'notification_id': 'x'}),
      );
      await flush();
      expect(openCount, 0);
      expect(lastMarkReadId, isNull);
    });

    test('a broadcast tap while signed out is ignored', () async {
      port.emitTap(broadcast());
      await flush();
      expect(openCount, 0);
      expect(lastMarkReadId, isNull);
    });

    test('a cold-start tap is replayed after the shell mounts', () async {
      await service.onSignedIn('biz-1');
      port.initialTap = broadcast(id: 'cold-1');
      await service.replayInitialTap();
      await flush();
      expect(openCount, 1);
      expect(lastMarkReadId, 'cold-1');
    });
  });

  group('token lifecycle', () {
    test('sign-in with permission granted registers the token', () async {
      port.permission = PushPermissionStatus.granted;
      port.token = 'tok-1';
      await service.onSignedIn('biz-1');
      expect(registry.recorded, hasLength(1));
      expect(registry.recorded.first.businessId, 'biz-1');
      expect(registry.recorded.first.token, 'tok-1');
      expect(registry.recorded.first.permissionGranted, isTrue);
    });

    test('sign-in without permission does not register a token', () async {
      port.permission = PushPermissionStatus.notDetermined;
      port.token = 'tok-1';
      await service.onSignedIn('biz-1');
      expect(registry.recorded, isEmpty);
    });

    test('granting permission via the soft-ask registers the token', () async {
      port.token = 'tok-2';
      await service.onSignedIn('biz-1'); // notDetermined → no registration yet
      expect(registry.recorded, isEmpty);

      port.permission = PushPermissionStatus.granted; // OS prompt grants
      final result = await service.requestPermissionAndRegister();
      expect(result, PushPermissionStatus.granted);
      expect(registry.recorded, hasLength(1));
      expect(registry.recorded.first.token, 'tok-2');
    });

    test('sign-out clears the token client-side and in devices', () async {
      port.permission = PushPermissionStatus.granted;
      port.token = 'tok-1';
      await service.onSignedIn('biz-1');
      await service.onSignedOut('biz-1');
      expect(registry.cleared, contains('biz-1'));
      expect(port.deleteTokenCalls, 1);
    });

    test('a token refresh re-registers the new token', () async {
      port.permission = PushPermissionStatus.granted;
      port.token = 'tok-1';
      await service.onSignedIn('biz-1');
      port.emitTokenRefresh('tok-2');
      await flush();
      expect(registry.recorded.last.token, 'tok-2');
      expect(registry.recorded.last.businessId, 'biz-1');
    });

    test('regaining connectivity re-registers the token', () async {
      port.permission = PushPermissionStatus.granted;
      port.token = 'tok-1';
      await service.onSignedIn('biz-1');
      registry.recorded.clear();

      connectivity.add([ConnectivityResult.none]); // go offline
      await flush();
      connectivity.add([ConnectivityResult.wifi]); // offline → online edge
      await flush();

      expect(registry.recorded, isNotEmpty);
      expect(registry.recorded.last.token, 'tok-1');
    });
  });
}
