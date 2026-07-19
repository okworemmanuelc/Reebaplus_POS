// minimum_login_permission_tables_test.dart
//
// Regression guard for the "blank shell with no bottom nav after login" bug on
// a fresh device-join whose background full pull is slow or fails.
//
// MainLayout lands every login on the POS tab, then HIDES that tab (and its
// whole bottom nav) for a role without `sales.make`, bouncing it to Home — but
// only once the permission set RESOLVES (`currentUserRoleProvider` +
// `rolePermissionsProvider`, backed by the `roles` / `user_businesses` /
// `role_permissions` tables). If those rows arrive only via the heavy full pull
// and that pull stalls, the role never resolves: POS stays hidden AND the
// bounce never fires, stranding the user on a hidden tab with no nav.
//
// The fix pulls the role/permission trio in `syncMinimumLogin` (the fast,
// pre-MainLayout pull) so the gate resolves within a frame or two of login.
// This test pins that the minimum-login pull queries those tables; it fails if
// the set is trimmed back to render-chrome only.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../helpers/dispatch_test_utils.dart';
import '../helpers/in_memory_cloud_transport.dart';

/// `syncMinimumLogin` reads the live connectivity signal to size its pages;
/// without a mock it throws `MissingPluginException` in the test VM. Report
/// Wi-Fi so the pull proceeds to `fetchTable`.
const _connectivityChannel = MethodChannel(
  'dev.fluttercommunity.plus/connectivity',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('syncMinimumLogin table set', () {
    late AppDatabase db;
    late String businessId;
    late InMemoryCloudTransport transport;
    late SupabaseSyncService sync;

    setUp(() async {
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

    test(
      'pulls the role/permission trio so MainLayout can gate the nav',
      () async {
        await sync.syncMinimumLogin(businessId);

        final queried = transport.fetchQueries.map((q) => q.table).toSet();

        // Without these three, a fresh device can't resolve the user's role or
        // `sales.make` grant, so a permission-gated tab (POS) is hidden with no
        // fallback nav — the blank-shell bug.
        expect(
          queried,
          containsAll(<String>['roles', 'role_permissions', 'user_businesses']),
          reason:
              'minimum-login must fetch the tables MainLayout gates on, not '
              'just the render-chrome tables',
        );
        // The original render-chrome tables must still be there.
        expect(
          queried,
          containsAll(<String>['profiles', 'businesses', 'stores', 'users']),
        );
      },
    );
  });
}
