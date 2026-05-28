// crate_size_groups_v16_migration_test.dart
//
// Smoke test for the v16 (Crate Size Groups) migration's schema change:
// the rebuild of crate_groups → crate_size_groups that converts the int
// `size` column (12/20/24) into a `crate_size_label` text category
// (big/medium/small), per the `if (from < 16)` block in
// lib/core/database/app_database.dart.
//
// Two things are asserted:
//
//   1. The post-migration TARGET shape (exercised here via a fresh v16
//      onCreate): crate_size_groups has a `crate_size_label` text column
//      (default 'medium', CHECK IN ('big','medium','small')) and NO `size`
//      column. This is exactly what the upgrade rebuild produces.
//
//   2. The size→label MAPPING used by the rebuild's columnTransformer
//      (12→small, 20→medium, 24→big, anything else→medium). Mirrored here
//      against a throwaway v15-shaped table — the CASE expression below is a
//      verbatim copy of the one in the migration block; if you change one,
//      change the other.
//
// NOTE: this does not drive the real onUpgrade(15→16) end-to-end — the
// versioned schema-fixture harness is still deferred (see BUILD_LOG, the
// v11→v15 gap). The actual TableMigration rebuild path is covered by
// reasoning (FK enforcement is OFF during onUpgrade; the column set is
// otherwise unchanged) plus this mapping + target-shape check.

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    businessId = UuidV7.generate();
    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(
            id: Value(businessId),
            name: 'Test Business',
          ),
        );
  });

  tearDown(() => db.close());

  Future<Set<String>> columnsOf(String table) async {
    final rows =
        await db.customSelect('PRAGMA table_info($table)').get();
    return rows.map((r) => r.read<String>('name')).toSet();
  }

  group('Schema v16 — crate_size_groups target shape', () {
    test('has crate_size_label, no size column', () async {
      final cols = await columnsOf('crate_size_groups');
      expect(cols.contains('crate_size_label'), isTrue,
          reason: 'crate_size_label must exist after the rename/convert');
      expect(cols.contains('size'), isFalse,
          reason: 'the int size column is dropped in v16');
      // The old table name must be gone.
      final tables = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='crate_groups'",
          )
          .get();
      expect(tables, isEmpty);
    });

    test('crate_size_label defaults to medium when omitted', () async {
      final id = UuidV7.generate();
      await db.into(db.crateSizeGroups).insert(
            CrateSizeGroupsCompanion.insert(
              id: Value(id),
              businessId: businessId,
              name: 'Default Pack',
            ),
          );
      final row = await (db.select(db.crateSizeGroups)
            ..where((t) => t.id.equals(id)))
          .getSingle();
      expect(row.crateSizeLabel, 'medium');
    });

    test('CHECK accepts big / medium / small', () async {
      for (final label in const ['big', 'medium', 'small']) {
        final id = UuidV7.generate();
        await db.into(db.crateSizeGroups).insert(
              CrateSizeGroupsCompanion.insert(
                id: Value(id),
                businessId: businessId,
                name: 'Pack $label',
                crateSizeLabel: Value(label),
              ),
            );
        final row = await (db.select(db.crateSizeGroups)
              ..where((t) => t.id.equals(id)))
            .getSingle();
        expect(row.crateSizeLabel, label);
      }
    });

    test('CHECK rejects an out-of-set value', () async {
      await expectLater(
        db.customStatement(
          "INSERT INTO crate_size_groups (id, business_id, name, crate_size_label) "
          "VALUES (?, ?, ?, ?)",
          [UuidV7.generate(), businessId, 'Bad', 'huge'],
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('Schema v16 — size→crate_size_label mapping (rebuild transformer)', () {
    test('12→small, 20→medium, 24→big, anything else→medium', () async {
      // A throwaway table standing in for the v15-shaped crate_groups, with
      // the int `size` column. We then apply the SAME CASE expression the
      // migration's columnTransformer uses to fill crate_size_label.
      await db.customStatement(
        'CREATE TABLE _v15_crate_groups (id TEXT PRIMARY KEY, size INTEGER, label TEXT)',
      );
      await db.customStatement(
        "INSERT INTO _v15_crate_groups (id, size) VALUES "
        "('a', 12), ('b', 20), ('c', 24), ('d', 16)",
      );
      // Verbatim mirror of the columnTransformer CASE in the v16 block.
      await db.customStatement(
        "UPDATE _v15_crate_groups SET label = "
        "CASE size "
        "WHEN 12 THEN 'small' "
        "WHEN 20 THEN 'medium' "
        "WHEN 24 THEN 'big' "
        "ELSE 'medium' END",
      );

      final rows = await db
          .customSelect(
            'SELECT id, label FROM _v15_crate_groups ORDER BY id',
          )
          .get();
      final byId = {
        for (final r in rows) r.read<String>('id'): r.read<String>('label'),
      };
      expect(byId['a'], 'small'); // 12
      expect(byId['b'], 'medium'); // 20
      expect(byId['c'], 'big'); // 24
      expect(byId['d'], 'medium'); // 16 → ELSE
    });
  });
}
