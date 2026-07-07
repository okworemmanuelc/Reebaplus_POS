// catch_up_pull_test.dart
//
// #88: devices missed cloud soft-deletes because realtime never replays events
// dropped while the socket was down, and a catch-up pull only fired after a
// *failed* pull. `catchUpPull` is the shared, silent, debounced delta-pull that
// the reconnect (unconditional) and app-resume paths now call.
//
// These tests pin the guard + debounce decisions in isolation via the
// @visibleForTesting seams, without driving the full connectivity-guarded pull.

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../helpers/dispatch_test_utils.dart';
import '../helpers/in_memory_cloud_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('catchUpPull guards + debounce', () {
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
      await transport.dispose();
      await db.close();
    });

    test('is a no-op when no business is bound (no pull attempted)', () async {
      sync.currentBusinessIdForTesting = null;
      sync.isOnline.value = true;

      await sync.catchUpPull(businessId, reason: 'test');

      expect(sync.lastCatchUpAtForTesting, isNull);
      expect(transport.fetchQueries, isEmpty);
    });

    test('is a no-op when offline (no pull attempted)', () async {
      sync.currentBusinessIdForTesting = businessId;
      sync.isOnline.value = false;

      await sync.catchUpPull(businessId, reason: 'test');

      expect(sync.lastCatchUpAtForTesting, isNull);
      expect(transport.fetchQueries, isEmpty);
    });

    test('proceeds once when eligible, then debounces an immediate second call',
        () async {
      sync.currentBusinessIdForTesting = businessId;
      sync.isOnline.value = true;

      // First call is eligible: it stamps _lastCatchUpAt before pulling. (The
      // pull itself is best-effort and swallowed — this test only asserts the
      // gate/debounce decision, not the pull outcome.)
      await sync.catchUpPull(businessId, reason: 'first');
      final firstAt = sync.lastCatchUpAtForTesting;
      expect(firstAt, isNotNull);

      // Second call within the debounce window must NOT re-stamp — proving it
      // returned early instead of firing another overlapping pull.
      await sync.catchUpPull(businessId, reason: 'second');
      expect(sync.lastCatchUpAtForTesting, firstAt);
    });
  });
}
