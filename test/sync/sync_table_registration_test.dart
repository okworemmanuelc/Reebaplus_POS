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
            'Add a `SyncedTable` entry for each in sync_registry.dart '
            '(tenantScoped: true) and route its writes through a DAO that '
            'enqueues — CLAUDE.md §5 — or mark it `isCache: true` if it is an '
            'intentional Phase D cache.',
      );
    } finally {
      await boot.db.close();
    }
  });

  // Registry membership (issue #15). `kSyncedTenantTables` / `kSyncCacheTables`
  // now DERIVE from the `SyncedTable` registry, so a fingerprinted table with no
  // registry entry ALSO fails the test above. This asserts the stronger property
  // directly: every fingerprinted Drift table has an actual registry entry (not
  // just membership in a derived list), so it participates in pull / restore /
  // reconcile — the whole point of collapsing the six constructs into one list.
  test('every sync-fingerprinted table has a SyncedTable registry entry',
      () async {
    final boot = await bootstrapTestDb();
    try {
      final missing = <String>[];
      for (final table in boot.db.allTables) {
        final cols = table.$columns.map((c) => c.name).toSet();
        final fingerprinted =
            cols.contains('business_id') && cols.contains('last_updated_at');
        if (!fingerprinted) continue;
        if (syncedTableForName(table.actualTableName) == null) {
          missing.add(table.actualTableName);
        }
      }
      expect(
        missing,
        isEmpty,
        reason: 'Sync-fingerprinted table(s) with no `SyncedTable` registry '
            'entry: $missing.\nAdd one entry in sync_registry.dart, after the '
            "table's parent(s) in the ordered list, so it pulls / restores / "
            'reconciles on every device.',
      );
    } finally {
      await boot.db.close();
    }
  });

  // Guards the other direction: a registry entry whose name is a typo (or a
  // renamed/dropped table) would silently never restore. Every registry name
  // must resolve to a real Drift table, except the declared cloud-only entries
  // that have no local mirror.
  test('every registry entry names a real Drift table (or a declared exemption)',
      () async {
    // Cloud-only / no-local-mirror entries present in the registry purely for
    // their pull-order + push-whitelist facts.
    const cloudOnlyExemptions = <String>{'profiles'};

    final boot = await bootstrapTestDb();
    try {
      final realTables = {
        for (final t in boot.db.allTables) t.actualTableName,
      };
      final unknown = <String>[
        for (final entry in kSyncRegistry)
          if (!realTables.contains(entry.name) &&
              !cloudOnlyExemptions.contains(entry.name))
            entry.name,
      ];
      expect(
        unknown,
        isEmpty,
        reason: 'Registry entry name(s) that match no Drift table and are not a '
            'declared cloud-only exemption: $unknown. Fix the name, or add it to '
            'cloudOnlyExemptions if it genuinely has no local mirror.',
      );
    } finally {
      await boot.db.close();
    }
  });

  test('registry has no duplicate table entries', () {
    final names = [for (final t in kSyncRegistry) t.name];
    expect(names.length, names.toSet().length,
        reason: 'A table appears twice in kSyncRegistry — pull/restore would run '
            'it twice and the derived sets would be ambiguous.');
  });
}
