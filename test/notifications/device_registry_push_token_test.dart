import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/shared/services/device_registry_service.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';

// #138 Slice 2 / invariant #3: token registration is fire-and-forget and must
// NEVER throw — a failure (offline, un-deployed column, RLS, or here a failing
// device-id read) must be swallowed so it can never block or break login/sync.
// recordPushToken + clearPushToken wrap their whole body in one try/catch, so a
// throw from any step (device-id read or the Supabase upsert) is swallowed;
// this drives the boundary deterministically without a network call.

class _ThrowingSecure implements SecureStorageService {
  @override
  Future<String> getOrCreateDeviceId() async =>
      throw StateError('device id unavailable');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  // A real client is fine — it is never reached (the device-id read throws
  // first) and construction opens no connection.
  final supabase = SupabaseClient('https://example.supabase.co', 'anon-key');

  test('recordPushToken swallows a failure and never throws', () async {
    final registry = DeviceRegistryService(supabase, _ThrowingSecure());
    await expectLater(
      registry.recordPushToken(
        businessId: 'biz-1',
        token: 'tok-1',
        permissionGranted: true,
      ),
      completes,
    );
  });

  test('clearPushToken swallows a failure and never throws', () async {
    final registry = DeviceRegistryService(supabase, _ThrowingSecure());
    await expectLater(
      registry.clearPushToken(businessId: 'biz-1'),
      completes,
    );
  });
}
