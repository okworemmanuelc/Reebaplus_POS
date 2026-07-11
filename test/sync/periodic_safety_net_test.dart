// periodic_safety_net_test.dart
//
// Workstream C (#102) — guard the periodic pull "safety net" so it can never be
// silently removed. Realtime Broadcast (Workstream B) is deliberately ephemeral
// with NO replay: a device offline / asleep / backgrounded during a change
// simply misses the message. The periodic catch-up pull on the 30 s tick is the
// backstop that makes that "no replay" acceptable — it re-converges any missed
// change within one tick. Remove it and B's non-replay becomes a silent
// data-divergence bug.
//
// These tests pin, via the same private installer/tick production uses (the
// @visibleForTesting seams — so they fail if that wiring drifts):
//   1. the timer is scheduled, idempotently, at the documented cadence;
//   2. every tick fires the silent catch-up pull when foreground + online +
//      business-bound;
//   3. the tick pulls nothing when the device is ineligible — offline, or
//      logged-out (the backgrounded/suspended-device guard); and
//   4. logout (stopAutoPush) tears the timer down — no further ticks fire.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../helpers/dispatch_test_utils.dart';
import '../helpers/in_memory_cloud_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('periodic safety-net pull (#102 Workstream C)', () {
    late AppDatabase db;
    late String businessId;
    late InMemoryCloudTransport transport;
    late SupabaseSyncService sync;

    setUp(() async {
      final boot = await bootstrapTestDb();
      db = boot.db;
      businessId = boot.businessId;
      transport = InMemoryCloudTransport(authUserId: 'user-1');
      sync = SupabaseSyncService(db, transport);
    });

    tearDown(() async {
      sync.stopAutoPush();
      await transport.dispose();
      await db.close();
    });

    test('timer is scheduled (idempotently) at the 30s cadence and cancelled '
        'on logout', () {
      expect(sync.isPeriodicSafetyNetActiveForTesting, isFalse);

      sync.installPeriodicSafetyNetForTesting();
      expect(
        sync.isPeriodicSafetyNetActiveForTesting,
        isTrue,
        reason: 'the safety net must be scheduled once auto-push starts',
      );

      // Cadence == the C-S2 default. Changing it is a deliberate product/cost
      // decision (idle poll traffic vs. staleness), never an accident — this
      // line forces the change through review.
      expect(
        sync.periodicSafetyNetIntervalForTesting,
        const Duration(seconds: 30),
      );

      // Idempotent: a second install must not stack a second timer.
      sync.installPeriodicSafetyNetForTesting();
      expect(sync.isPeriodicSafetyNetActiveForTesting, isTrue);

      // Logout tears it down.
      sync.stopAutoPush();
      expect(
        sync.isPeriodicSafetyNetActiveForTesting,
        isFalse,
        reason: 'logout must cancel the safety net',
      );
    });

    test('a tick fires the silent catch-up pull when foreground + online + '
        'business-bound', () async {
      sync.currentBusinessIdForTesting = businessId;
      sync.isOnline.value = true;
      expect(sync.lastCatchUpAtForTesting, isNull);

      await sync.runPeriodicSafetyNetTickForTesting();

      expect(
        sync.lastCatchUpAtForTesting,
        isNotNull,
        reason: 'each tick must fire the periodic catch-up pull',
      );
    });

    test('a tick pulls nothing while logged out (backgrounded/suspended state)',
        () async {
      sync.currentBusinessIdForTesting = null; // not business-bound
      sync.isOnline.value = true;

      await sync.runPeriodicSafetyNetTickForTesting();

      expect(sync.lastCatchUpAtForTesting, isNull);
    });

    test('a tick pulls nothing while offline', () async {
      sync.currentBusinessIdForTesting = businessId;
      sync.isOnline.value = false;

      await sync.runPeriodicSafetyNetTickForTesting();

      expect(sync.lastCatchUpAtForTesting, isNull);
    });

    test('the scheduled timer actually fires the pull on the tick, and stops '
        'firing after logout', () {
      fakeAsync((async) {
        sync.currentBusinessIdForTesting = businessId;
        sync.isOnline.value = true;
        sync.installPeriodicSafetyNetForTesting();

        // Nothing before the first interval elapses.
        async.elapse(const Duration(seconds: 29));
        expect(sync.lastCatchUpAtForTesting, isNull);

        // The 30 s tick fires the catch-up pull. `catchUpPull` stamps
        // `_lastCatchUpAt` synchronously (before its best-effort awaited pull),
        // so the stamp is observable the instant the tick runs.
        async.elapse(const Duration(seconds: 1));
        final firedAt = sync.lastCatchUpAtForTesting;
        expect(
          firedAt,
          isNotNull,
          reason: 'the periodic timer must invoke the catch-up pull tick',
        );

        // Logout cancels the timer: no further ticks, so no further pulls even
        // after several more intervals elapse.
        sync.stopAutoPush();
        expect(sync.isPeriodicSafetyNetActiveForTesting, isFalse);
        async.elapse(const Duration(seconds: 120));
        expect(sync.lastCatchUpAtForTesting, firedAt);

        async.flushMicrotasks();
      });
    });
  });
}
