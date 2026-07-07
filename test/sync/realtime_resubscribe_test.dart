// realtime_resubscribe_test.dart
//
// #93: realtime live sync died every session. `restartRealtimeSync` (fired on
// app-resume + connectivity-recovery, ~every launch) tore the channels down
// fire-and-forget, then synchronously re-created them — but the transport's
// `startRealtime` no-ops while any channel object is still held, so the recreate
// bailed and left ZERO channels. Symptom: logs show "Starting real-time sync"
// twice but never "Realtime subscribed: <table>", and console edits/deletes only
// land on a manual pull.
//
// This test drives a transport that models the worst case — `stopRealtime`
// yields (suspends) *before* releasing its channels, exactly like the real
// adapter's `await removeChannel(...)` loop that only clears afterwards. The fix
// is that `restartRealtimeSync` now awaits the full teardown before
// re-subscribing, so it works even against such a transport.

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgresChangePayload;

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../helpers/dispatch_test_utils.dart';
import '../helpers/in_memory_cloud_transport.dart';

/// A transport whose realtime teardown releases its channels *after* an async
/// gap — reproducing the pre-#93 race window where `startRealtime`'s
/// "channels still held" guard would see stale channels and refuse to subscribe.
class _LateReleaseRealtimeTransport extends InMemoryCloudTransport {
  _LateReleaseRealtimeTransport({super.authUserId});

  /// Mirrors the real adapter's `_tableChannels.isNotEmpty` guard state.
  bool held = false;

  @override
  void startRealtime(
    Iterable<String> tables,
    String businessId, {
    required void Function(PostgresChangePayload) onChange,
  }) {
    if (held) return; // the guard that silently dropped every channel (#93)
    held = true;
    super.startRealtime(tables, businessId, onChange: onChange);
  }

  @override
  Future<void> stopRealtime() async {
    // Yield BEFORE releasing the channels, exactly like the real adapter
    // suspending at its first `await removeChannel` with `_tableChannels` full.
    await Future<void>.delayed(Duration.zero);
    held = false;
    await super.stopRealtime();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('restartRealtimeSync teardown/re-create ordering (#93)', () {
    late AppDatabase db;
    late String businessId;
    late _LateReleaseRealtimeTransport transport;
    late SupabaseSyncService sync;

    setUp(() async {
      final boot = await bootstrapTestDb();
      db = boot.db;
      businessId = boot.businessId;
      transport = _LateReleaseRealtimeTransport(authUserId: 'user-1');
      sync = SupabaseSyncService(db, transport);
    });

    tearDown(() async {
      await transport.dispose();
      await db.close();
    });

    test('initial start subscribes every synced table, not just products',
        () async {
      sync.startRealtimeSync(businessId);

      expect(transport.held, isTrue);
      // Coverage is the whole synced set — the console can edit any of these.
      expect(transport.subscribedTables, contains('products'));
      expect(transport.subscribedTables, contains('categories'));
      expect(transport.subscribedTables, contains('customers'));
      expect(transport.subscribedTables, contains('manufacturers'));
      expect(transport.subscribedTables, contains('suppliers'));
    });

    test('restart re-subscribes after teardown instead of dropping all channels',
        () async {
      sync.startRealtimeSync(businessId);
      expect(transport.subscribedTables, contains('products'));

      // The pre-fix race: recreate raced the still-in-flight teardown and the
      // guard bailed, leaving zero channels. Awaiting the teardown fixes it.
      await sync.restartRealtimeSync(businessId);
      // Drain any still-pending teardown: without the fix, the fire-and-forget
      // `stopRealtime` finishes here and wipes the (never-recreated) channels,
      // so the assertions below go red. With the fix there is nothing pending.
      await pumpEventQueue();

      expect(transport.held, isTrue,
          reason: 'realtime must be live again after a restart');
      expect(transport.subscribedTables, contains('products'));
      expect(transport.subscribedTables, contains('categories'));
    });

    test('a second restart is still live (repeatable across resumes)', () async {
      sync.startRealtimeSync(businessId);

      await sync.restartRealtimeSync(businessId);
      await sync.restartRealtimeSync(businessId);
      await pumpEventQueue();

      expect(transport.held, isTrue);
      expect(transport.subscribedTables, contains('products'));
    });
  });
}
