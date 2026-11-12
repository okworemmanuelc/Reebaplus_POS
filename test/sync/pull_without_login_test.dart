// #798: with no cloud login a pull reads back empty under RLS and would still
// move the last-synced marker forward, skipping whatever changed meanwhile.
// pullChanges must not run at all until the login is back.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../helpers/dispatch_test_utils.dart';
import '../helpers/in_memory_cloud_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late String businessId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
  });

  tearDown(() => db.close());

  test('no login: nothing is fetched and the last-synced marker stays put',
      () async {
    final transport = InMemoryCloudTransport();
    final sync = SupabaseSyncService(db, transport);

    await sync.pullChanges(businessId);

    expect(transport.fetchQueries, isEmpty);
    expect(sync.pullBusinessId, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getKeys().where((k) => k.startsWith('last_sync_timestamp::')),
      isEmpty,
    );
    await transport.dispose();
  });

  test('with a login the pull runs', () async {
    final transport = InMemoryCloudTransport(authUserId: 'user-1');
    final sync = SupabaseSyncService(db, transport);

    try {
      await sync.pullChanges(businessId);
    } catch (_) {
      // The outcome is not under test (the connectivity plugin is absent
      // here), only that the pull got past the login check and started.
    }

    expect(sync.pullBusinessId, businessId);
    await transport.dispose();
  });
}
