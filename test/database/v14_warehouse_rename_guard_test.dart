// v14_warehouse_rename_guard_test.dart
//
// Regression test for the v14 (warehouses → stores) migration crash hit on
// a real device: "no such column: warehouse_id" at
// `ALTER TABLE invite_codes RENAME COLUMN warehouse_id TO store_id`.
//
// Cause: invite_codes and user_stores are created by the v13 migration block
// via m.createTable, which builds them from the CURRENT Drift schema (already
// store_id). So a device upgrading FROM < 13 gets those tables with store_id
// and NO warehouse_id, and the unconditional RENAME COLUMN in the v14 block
// threw. The fix guards each rename on the old column actually existing.
//
// This test mirrors the guarded rename SQL from the v14 block in
// lib/core/database/app_database.dart against scratch tables. If you change
// that SQL, change it here.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get(); // force onCreate
  });

  tearDown(() => db.close());

  // Mirror of the v14 block's guarded rename.
  Future<void> guardedRename(String table) async {
    final hasOldColumn = await db.customSelect(
      "SELECT 1 FROM pragma_table_info('$table') WHERE name = 'warehouse_id'",
    ).get();
    if (hasOldColumn.isNotEmpty) {
      await db.customStatement(
        'ALTER TABLE $table RENAME COLUMN warehouse_id TO store_id',
      );
    }
  }

  Future<bool> columnExists(String table, String col) async {
    final rows = await db.customSelect(
      "SELECT 1 FROM pragma_table_info('$table') WHERE name = '$col'",
    ).get();
    return rows.isNotEmpty;
  }

  group('v14 warehouse_id → store_id rename guard', () {
    test('skips a table that already has store_id (the v13→v14 crash case)',
        () async {
      // Mimics invite_codes/user_stores as the v13 block creates them on a
      // < 13 upgrade: store_id present, warehouse_id absent.
      await db.customStatement(
        'CREATE TABLE scratch_invite_codes (id TEXT PRIMARY KEY, store_id TEXT)',
      );

      // Pre-fix this threw "no such column: warehouse_id". Must not now.
      await guardedRename('scratch_invite_codes');

      expect(await columnExists('scratch_invite_codes', 'store_id'), isTrue);
      expect(
        await columnExists('scratch_invite_codes', 'warehouse_id'),
        isFalse,
      );
    });

    test('renames a table that still has warehouse_id', () async {
      // Mimics a pre-v13 table (or a device installed during the v13 era).
      await db.customStatement(
        'CREATE TABLE scratch_orders (id TEXT PRIMARY KEY, warehouse_id TEXT)',
      );

      await guardedRename('scratch_orders');

      expect(await columnExists('scratch_orders', 'store_id'), isTrue);
      expect(await columnExists('scratch_orders', 'warehouse_id'), isFalse);
    });

    test('is idempotent on a repeat pass', () async {
      await db.customStatement(
        'CREATE TABLE scratch_two (id TEXT PRIMARY KEY, warehouse_id TEXT)',
      );
      await guardedRename('scratch_two'); // renames
      await guardedRename('scratch_two'); // no-op, must not throw

      expect(await columnExists('scratch_two', 'store_id'), isTrue);
      expect(await columnExists('scratch_two', 'warehouse_id'), isFalse);
    });
  });
}
