@Tags(['integration'])
library;

// broadcast_signal_live_test.dart — Tier-2, real dev Supabase.
//
// End-to-end proof of Workstream B's server half (#101): the generic emit
// trigger (migration 0147) + the per-tenant Realtime Authorization RLS policy
// (migration 0148) together deliver a `{table, id, op}` Broadcast signal to a
// client subscribed to the private tenant topic `store_<business_id>` — over
// exactly the channel shape the app's `SupabaseCloudTransport.startBroadcast`
// uses.
//
// Runs only with `--tags integration` and the TEST_SUPABASE_* env (see
// test/helpers/supabase_test_env.dart). It performs one benign committed write
// (touch a product's `last_updated_at` — the same thing sync does) via the
// service-role client, proving the emit is writer-agnostic.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../helpers/supabase_test_clients.dart';
import '../helpers/supabase_test_env.dart';

/// Tier-2: hits live Supabase, auto-skipped when the TEST_SUPABASE_* env vars
/// are absent (so a plain `flutter test` skips instead of failing).
final String? _skipReason = (() {
  try {
    TestEnv.load();
    return null;
  } on StateError catch (e) {
    return e.message;
  }
})();

/// Finds the `{table, id, op}` object inside whatever envelope the broadcast
/// binding hands back — realtime delivers `{event, payload, type}`, so the
/// signal is usually one level down under `payload`, but tolerate a flat shape.
Map<String, dynamic>? _findSignal(Map<String, dynamic> raw) {
  if (raw.containsKey('table') && raw.containsKey('op')) return raw;
  final inner = raw['payload'];
  if (inner is Map && inner.containsKey('table')) {
    return Map<String, dynamic>.from(inner);
  }
  return null;
}

void main() {
  group('Broadcast live signal end-to-end (#101 B1+B2, real Supabase)', () {
    late TestClients clients;

    setUp(() async {
      if (_skipReason != null) return;
      clients = await TestClients.setUp();
    });

    tearDown(() async {
      if (_skipReason != null) return;
      await clients.dispose();
    });

    test(
      'a tenant-row write delivers a {table,id,op} signal to a subscriber on '
      'the private store_<business_id> topic',
      () async {
        final businessId = clients.env.businessId;
        final user = clients.userClient;
        final admin = clients.adminClient;

        // Private-channel joins are RLS-gated on realtime.messages (0148):
        // force the user JWT onto the socket before subscribing, exactly like
        // the app's startBroadcast.
        await user.realtime.setAuth(user.auth.currentSession!.accessToken);

        final subscribed = Completer<void>();
        final received = Completer<Map<String, dynamic>>();

        final channel = user.channel(
          'store_$businessId',
          opts: const RealtimeChannelConfig(private: true),
        );
        channel
            .onBroadcast(
              event: 'sync',
              callback: (payload) {
                final signal = _findSignal(payload);
                if (signal != null && !received.isCompleted) {
                  received.complete(signal);
                }
              },
            )
            .subscribe((status, error) {
              if (status == RealtimeSubscribeStatus.subscribed &&
                  !subscribed.isCompleted) {
                subscribed.complete();
              } else if ((status == RealtimeSubscribeStatus.channelError ||
                      status == RealtimeSubscribeStatus.timedOut) &&
                  !subscribed.isCompleted) {
                subscribed.completeError(
                  'private channel join failed ($status): $error — the B2 RLS '
                  'policy must authorize this tenant.',
                );
              }
            });

        await subscribed.future.timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw StateError('never reached SUBSCRIBED'),
        );

        // One benign committed write in this business → fires the 0147 trigger.
        final rows = await admin
            .from('products')
            .select('id')
            .eq('business_id', businessId)
            .limit(1);
        expect(rows, isNotEmpty, reason: 'need a product in TEST_BUSINESS_ID');
        final productId = (rows.first as Map)['id'] as String;
        await admin
            .from('products')
            .update({
              'last_updated_at': DateTime.now().toUtc().toIso8601String(),
            })
            .eq('id', productId);

        final signal = await received.future.timeout(
          const Duration(seconds: 20),
          onTimeout: () =>
              throw StateError('no broadcast signal arrived within 20s'),
        );

        expect(signal['table'], 'products');
        expect(signal['id'], productId);
        expect(signal['op'], anyOf('UPDATE', 'INSERT'));

        await user.removeChannel(channel);
      },
      timeout: const Timeout(Duration(seconds: 60)),
      skip: _skipReason,
    );
  });
}
