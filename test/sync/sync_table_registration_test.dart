import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';

import '../helpers/dispatch_test_utils.dart';

/// Sync safeguard — Layer B (CLAUDE.md §5). The keystone future-proofing.
///
/// Reflects over the live Drift schema and asserts that every table carrying
/// the "sync fingerprint" — BOTH a `business_id` and a `last_updated_at`
/// column — is registered for sync (in `_syncedTenantTables`) or is an
/// explicitly-exempt Phase D cache (`kSyncCacheTables`).
///
/// This makes the most common silent-sync failure impossible to merge: adding
/// a new tenant table and forgetting to register it. A new fingerprinted table
/// turns this test red until the author makes a deliberate choice — register
/// it, or declare it an intentional cache.
///
/// One-directional on purpose: fingerprint ⇒ registered. We do NOT assert the
/// reverse (every synced table is fingerprinted) — `businesses` syncs via its
/// own realtime channel and has no `business_id`, and a future synced table
/// could legitimately omit a column.
void main() {
  test('every sync-fingerprinted table is registered for sync', () async {
    final boot = await bootstrapTestDb();
    try {
      final unregistered = <String>[];
      for (final table in boot.db.allTables) {
        final cols = table.$columns.map((c) => c.name).toSet();
        final fingerprinted =
            cols.contains('business_id') && cols.contains('last_updated_at');
        if (!fingerprinted) continue;

        final name = table.actualTableName;
        if (kSyncedTenantTables.contains(name)) continue;
        if (kSyncCacheTables.contains(name)) continue;
        unregistered.add(name);
      }

      expect(
        unregistered,
        isEmpty,
        reason: 'These tables carry the sync fingerprint (business_id + '
            'last_updated_at) but are not registered for sync: $unregistered.\n'
            'Add each to `_syncedTenantTables` in app_database.dart (and route '
            'its writes through a DAO that enqueues — CLAUDE.md §5), or to '
            '`kSyncCacheTables` if it is an intentional Phase D cache.',
      );
    } finally {
      await boot.db.close();
    }
  });
}
