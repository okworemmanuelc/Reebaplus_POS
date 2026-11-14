import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/push_messaging_port.dart';
import 'package:reebaplus_pos/shared/services/device_registry_service.dart';
import 'package:reebaplus_pos/shared/services/push_notification_service.dart';
import 'package:reebaplus_pos/shared/widgets/push_permission_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/in_memory_push_messaging.dart';

// #823: the announcements soft-ask is never offered in the browser, and the
// "asked" flag is remembered even when turning on fails.

class _Registry implements DeviceRegistryService {
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Service extends PushNotificationService {
  _Service({this.throwOnRegister = false})
    : super(port: InMemoryPushMessaging(), deviceRegistry: _Registry());
  final bool throwOnRegister;
  int registerCalls = 0;

  @override
  Future<PushPermissionStatus> requestPermissionAndRegister() async {
    registerCalls++;
    if (throwOnRegister) throw StateError('no service worker');
    return super.requestPermissionAndRegister();
  }
}

const _key = 'push_soft_ask_shown_v1';

Future<void> _pump(WidgetTester t, _Service svc, {required bool isWeb}) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [pushNotificationServiceProvider.overrideWithValue(svc)],
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  maybePromptForPushPermission(context, ref, isWeb: isWeb),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('go'));
  await t.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('not offered on web, nothing recorded or requested', (t) async {
    final svc = _Service();
    await _pump(t, svc, isWeb: true);
    expect(find.text('Turn on announcements'), findsNothing);
    expect((await SharedPreferences.getInstance()).getBool(_key), isNull);
    expect(svc.registerCalls, 0);
  });

  testWidgets('Turn on records the flag even when the step throws', (t) async {
    final svc = _Service(throwOnRegister: true);
    await _pump(t, svc, isWeb: false);
    expect(find.text('Turn on announcements'), findsOneWidget);
    await t.tap(find.text('Turn on'));
    await t.pumpAndSettle();
    expect(svc.registerCalls, 1);
    expect(t.takeException(), isNull);
    expect((await SharedPreferences.getInstance()).getBool(_key), isTrue);
  });

  testWidgets('Not now records the flag; a second call shows nothing', (
    t,
  ) async {
    final svc = _Service();
    await _pump(t, svc, isWeb: false);
    await t.tap(find.text('Not now'));
    await t.pumpAndSettle();
    expect((await SharedPreferences.getInstance()).getBool(_key), isTrue);
    expect(svc.registerCalls, 0);

    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    expect(find.text('Turn on announcements'), findsNothing);
  });
}
