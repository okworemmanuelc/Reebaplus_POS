import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

/// Sync safeguard — Layer A (CLAUDE.md §5). `enqueueUpsert` / `enqueueDelete`
/// must reject an unknown or typo'd table name at the local write boundary.
/// The pusher dispatches `<table>:upsert` to `_supabase.from(table)` with no
/// whitelist, so a bad name would otherwise stick forever as a failed queue
/// row instead of surfacing the bug where it was made. Mirrors the
/// `_ledgerTables` guard locked in by sync_dao_ledger_guard_test.dart.
void main() {
  group('SyncDao.enqueueUpsert table-name guard', () {
    test('rejects an unregistered table name', () async {
      final boot = await bootstrapTestDb();
      try {
        expect(
          () => boot.db.syncDao.enqueueUpsert(
            'not_a_table',
            ProductsCompanion(
              id: Value(UuidV7.generate()),
              businessId: Value(boot.businessId),
            ),
          ),
          throwsA(isA<StateError>()),
        );
      } finally {
        await boot.db.close();
      }
    });

    test('allows a synced table (products)', () async {
      final boot = await bootstrapTestDb();
      try {
        // Should not throw — products is in _syncedTenantTables.
        await boot.db.syncDao.enqueueUpsert(
          'products',
          ProductsCompanion(
            id: Value(UuidV7.generate()),
            businessId: Value(boot.businessId),
          ),
        );
      } finally {
        await boot.db.close();
      }
    });

    test('allows a cache table (inventory)', () async {
      final boot = await bootstrapTestDb();
      try {
        // Caches are enqueued + pushed but absent from _syncedTenantTables;
        // they live in kSyncCacheTables, so the guard must allow them.
        await boot.db.syncDao.enqueueUpsert(
          'inventory',
          InventoryCompanion(
            id: Value(UuidV7.generate()),
            businessId: Value(boot.businessId),
          ),
        );
      } finally {
        await boot.db.close();
      }
    });
  });

  group('SyncDao.enqueueDelete table-name guard', () {
    test('rejects an unregistered table name', () async {
      final boot = await bootstrapTestDb();
      try {
        expect(
          () => boot.db.syncDao.enqueueDelete('not_a_table', UuidV7.generate()),
          throwsA(isA<StateError>()),
        );
      } finally {
        await boot.db.close();
      }
    });

    test('rejects a cache table (not a delete target)', () async {
      final boot = await bootstrapTestDb();
      try {
        // Caches are rebuilt from domain responses, never hard-deleted by a
        // client. enqueueDelete only accepts _syncedTenantTables members.
        expect(
          () => boot.db.syncDao.enqueueDelete('inventory', UuidV7.generate()),
          throwsA(isA<StateError>()),
        );
      } finally {
        await boot.db.close();
      }
    });

    test('allows a synced, non-ledger table (saved_carts)', () async {
      final boot = await bootstrapTestDb();
      try {
        // Should not throw — saved_carts is soft-deletable.
        await boot.db.syncDao.enqueueDelete('saved_carts', UuidV7.generate());
      } finally {
        await boot.db.close();
      }
    });
  });
}
