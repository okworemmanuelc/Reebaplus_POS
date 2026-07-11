// broadcast_signal_test.dart
//
// Workstream B (#101): the Broadcast live-signal layer. Broadcast is a *signal*
// that nudges the sync engine to pull — never the data transport, and it MUST
// NEVER write Drift (architecture "Realtime = signal", invariant #1). These
// tests pin the mobile subscriber half of B:
//
//   * Lifecycle — the broadcast subscription rides realtime's lifecycle
//     (start at sign-in, torn down at logout, re-subscribed on resume /
//     connectivity handoff) and coexists with the postgres_changes channel
//     (belt-and-suspenders; B does not rip out the working legacy path here).
//   * Signal → pull — a signal schedules a debounced catchUpPull, and a burst
//     of signals from one multi-row write collapses to a single pull.
//   * No Drift write — the signal carries no row data and has no Drift-write
//     path of its own: when its only effect (the pull) is gated off, nothing
//     happens at all.
//   * No replay dependency (B5) — convergence rides the periodic/reconnect pull
//     (Workstream C), so a device that missed a signal still recovers.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../helpers/dispatch_test_utils.dart';
import '../helpers/in_memory_cloud_transport.dart';

/// The pull path (`pullInitialData`) reads the live connectivity signal to size
/// its pages; without a mock it throws `MissingPluginException` in the test VM,
/// killing the pull before it reaches the transport. Report Wi-Fi so the pull
/// proceeds to `fetchTable`.
const _connectivityChannel = MethodChannel(
  'dev.fluttercommunity.plus/connectivity',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Broadcast live signal (#101)', () {
    late AppDatabase db;
    late String businessId;
    late InMemoryCloudTransport transport;
    late SupabaseSyncService sync;

    setUp(() async {
      // The catch-up pull reads its cursor from SharedPreferences and the live
      // connectivity signal; mock both so the pull actually reaches the
      // transport (fetchQueries) instead of throwing and being swallowed.
      SharedPreferences.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            _connectivityChannel,
            (call) async => call.method == 'check' ? <String>['wifi'] : null,
          );
      final boot = await bootstrapTestDb();
      db = boot.db;
      businessId = boot.businessId;
      transport = InMemoryCloudTransport(authUserId: 'user-1');
      sync = SupabaseSyncService(db, transport);
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_connectivityChannel, null);
      await transport.dispose();
      await db.close();
    });

    // ── Lifecycle: broadcast rides realtime's lifecycle ──────────────────────
    test(
      'startRealtimeSync opens a broadcast subscription on the tenant topic, '
      'alongside the postgres_changes channel (belt-and-suspenders)',
      () {
        sync.startRealtimeSync(businessId);

        expect(transport.broadcastActive, isTrue);
        expect(transport.broadcastBusinessId, businessId);
        expect(transport.startBroadcastCount, 1);
        // Coexists with — does not replace — the postgres_changes bindings.
        expect(transport.subscribedTables, contains('products'));
      },
    );

    test('logout (stopRealtimeSync) tears the broadcast channel down', () async {
      sync.startRealtimeSync(businessId);
      expect(transport.broadcastActive, isTrue);

      sync.stopRealtimeSync();
      await pumpEventQueue(); // teardown is unawaited inside stopRealtimeSync

      expect(transport.broadcastActive, isFalse);
      expect(transport.stopBroadcastCount, 1);
    });

    test(
      'restartRealtimeSync (resume / connectivity handoff) re-subscribes the '
      'broadcast channel',
      () async {
        sync.startRealtimeSync(businessId);

        await sync.restartRealtimeSync(businessId);
        await pumpEventQueue();

        expect(transport.broadcastActive, isTrue);
        expect(transport.startBroadcastCount, 2);
        expect(transport.stopBroadcastCount, 1);
      },
    );

    // ── Signal → debounced catch-up pull ─────────────────────────────────────
    test('a broadcast signal schedules a catch-up pull', () async {
      sync.currentBusinessIdForTesting = businessId;
      sync.isOnline.value = true;
      sync.startRealtimeSync(businessId);

      transport.emitBroadcastSignal();
      await pumpEventQueue();

      expect(
        sync.lastCatchUpAtForTesting,
        isNotNull,
        reason: 'the signal must trigger a (debounced) catch-up pull',
      );
      expect(
        transport.fetchQueries.where((q) => q.table == 'products'),
        isNotEmpty,
        reason: 'the scheduled pull actually reached the transport',
      );
    });

    test('a burst of signals collapses to a single debounced pull', () async {
      sync.currentBusinessIdForTesting = businessId;
      sync.isOnline.value = true;
      sync.startRealtimeSync(businessId);

      transport.emitBroadcastSignal();
      await pumpEventQueue();
      final firstAt = sync.lastCatchUpAtForTesting;
      final pullsAfterFirst = transport.fetchQueries
          .where((q) => q.table == 'products')
          .length;
      expect(firstAt, isNotNull);

      // Four more signals inside the 20 s debounce window must NOT re-pull —
      // a single multi-row write emits one signal per row, and the client
      // collapses that burst to one pull.
      for (var i = 0; i < 4; i++) {
        transport.emitBroadcastSignal();
      }
      await pumpEventQueue();

      expect(
        sync.lastCatchUpAtForTesting,
        firstAt,
        reason: 'the burst is debounced to the first pull',
      );
      expect(
        transport.fetchQueries.where((q) => q.table == 'products').length,
        pullsAfterFirst,
        reason: 'no extra pull crossed the wire for the debounced signals',
      );
    });

    // ── Invariant: a broadcast never writes Drift ────────────────────────────
    test(
      'a signal received while offline writes nothing and pulls nothing — the '
      'signal has no Drift-write path of its own',
      () async {
        sync.currentBusinessIdForTesting = businessId;
        sync.isOnline.value = false; // the pull (its only effect) is gated off
        sync.startRealtimeSync(businessId);

        final productsBefore = (await db.select(db.products).get()).length;
        transport.emitBroadcastSignal();
        await pumpEventQueue();

        expect(
          sync.lastCatchUpAtForTesting,
          isNull,
          reason: 'offline → catchUpPull is gated, so nothing runs',
        );
        expect(transport.fetchQueries, isEmpty);
        expect(
          (await db.select(db.products).get()).length,
          productsBefore,
          reason: 'the signal carries no row data and never writes Drift',
        );
      },
    );

    // ── B5: no dependency on broadcast replay ────────────────────────────────
    test(
      'the catch-up pull converges independently of any broadcast — a device '
      'that missed a signal still recovers on the periodic/reconnect pull',
      () async {
        sync.currentBusinessIdForTesting = businessId;
        sync.isOnline.value = true;
        // No broadcast started, no signal emitted — model a missed message.
        expect(transport.broadcastActive, isFalse);

        await sync.catchUpPull(businessId, reason: 'periodic');

        expect(
          sync.lastCatchUpAtForTesting,
          isNotNull,
          reason: 'convergence rides the periodic pull, not broadcast replay',
        );
        expect(
          transport.fetchQueries.where((q) => q.table == 'products'),
          isNotEmpty,
        );
      },
    );
  });
}
