// v8 → v9 migration sanity test for the role vocabulary refactor.
//
// What this verifies:
//   • New v9 CHECK constraints accept the granular vocabulary
//     (ceo / manager / stock_keeper / cashier / rider) and the new tier
//     set (2,3,4,5,6) — proves the customConstraints lists in
//     Users / BusinessMembers / Invites are wired through codegen.
//   • New v9 CHECK constraints reject the old vocabulary (admin/staff)
//     and reject 'cleaner'.
//   • The backfill UPDATE statements from the v8→v9 onUpgrade block
//     produce the expected mappings: admin→ceo/6, staff→cashier/3,
//     ceo/!=6→ceo/6, manager/!=5→manager/5.
//
// What this does NOT verify (same limitation as migration_v6_to_v7_test):
//   • The actual onUpgrade(8, 9) code path running against a real v8
//     schema. drift_dev's schema-versioning infra (`schema dump` +
//     `verifySelf`) is not set up in this repo. The Drift TableMigration
//     dance for the new CHECK constraints is library code we trust;
//     the data-rewrite SQL is what's project-specific, and it's tested
//     here on an unconstrained sandbox table created via customStatement.
//
// If we ever add the schema-dump infra, this file is the natural home
// for the proper "boot at v8, migrate, assert" version.

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

void main() {
  group('v9 CHECK constraints reject old vocabulary', () {
    late AppDatabase db;
    late String businessId;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      businessId = UuidV7.generate();
      db.businessIdResolver = () => businessId;
      await db.into(db.businesses).insert(
            BusinessesCompanion.insert(id: Value(businessId), name: 'Test Biz'),
          );
    });

    tearDown(() async {
      await db.close();
    });

    test('users.role: admin rejected, staff rejected, cleaner rejected',
        () async {
      for (final badRole in const ['admin', 'staff', 'cleaner']) {
        expect(
          () => db.into(db.users).insert(
                UsersCompanion.insert(
                  id: Value(UuidV7.generate()),
                  businessId: businessId,
                  name: 'X',
                  role: badRole,
                  roleTier: const Value(3),
                  pin: '0000',
                ),
              ),
          throwsA(isA<SqliteException>()),
          reason: 'role=$badRole should violate users_role_check',
        );
      }
    });

    test('users.role_tier: 1 rejected, 7 rejected', () async {
      for (final badTier in const [1, 7]) {
        expect(
          () => db.into(db.users).insert(
                UsersCompanion.insert(
                  id: Value(UuidV7.generate()),
                  businessId: businessId,
                  name: 'X',
                  role: 'cashier',
                  roleTier: Value(badTier),
                  pin: '0000',
                ),
              ),
          throwsA(isA<SqliteException>()),
          reason: 'role_tier=$badTier should violate users_role_tier_check',
        );
      }
    });

    test('business_members.role: admin rejected, staff rejected', () async {
      final userId = UuidV7.generate();
      await db.into(db.users).insert(
            UsersCompanion.insert(
              id: Value(userId),
              businessId: businessId,
              name: 'X',
              role: 'cashier',
              roleTier: const Value(3),
              pin: '0000',
            ),
          );
      for (final badRole in const ['admin', 'staff']) {
        expect(
          () => db.into(db.businessMembers).insert(
                BusinessMembersCompanion.insert(
                  id: Value(UuidV7.generate()),
                  businessId: businessId,
                  userId: userId,
                  role: badRole,
                  roleTier: const Value(3),
                ),
              ),
          throwsA(isA<SqliteException>()),
          reason: 'role=$badRole should violate business_members_role_check',
        );
      }
    });

    test('invites.role: admin rejected, staff rejected, cleaner rejected',
        () async {
      final ownerId = UuidV7.generate();
      await db.into(db.users).insert(
            UsersCompanion.insert(
              id: Value(ownerId),
              businessId: businessId,
              name: 'Owner',
              role: 'ceo',
              roleTier: const Value(6),
              pin: '0000',
            ),
          );
      for (final badRole in const ['admin', 'staff', 'cleaner']) {
        expect(
          () => db.into(db.invites).insert(
                InvitesCompanion.insert(
                  id: Value(UuidV7.generate()),
                  businessId: businessId,
                  email: 'x@y.z',
                  code: 'TEST0001',
                  role: badRole,
                  createdBy: ownerId,
                  inviteeName: 'X',
                  expiresAt: DateTime.now().add(const Duration(days: 7)),
                ),
              ),
          throwsA(isA<SqliteException>()),
          reason: 'role=$badRole should violate invites_role_check',
        );
      }
    });
  });

  group('v9 CHECK constraints accept new vocabulary', () {
    late AppDatabase db;
    late String businessId;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      businessId = UuidV7.generate();
      db.businessIdResolver = () => businessId;
      await db.into(db.businesses).insert(
            BusinessesCompanion.insert(id: Value(businessId), name: 'Test Biz'),
          );
    });

    tearDown(() async {
      await db.close();
    });

    test('users.role accepts every granular role at its canonical tier',
        () async {
      const matrix = {
        'ceo': 6,
        'manager': 5,
        'stock_keeper': 4,
        'cashier': 3,
        'rider': 2,
      };
      for (final entry in matrix.entries) {
        await db.into(db.users).insert(
              UsersCompanion.insert(
                id: Value(UuidV7.generate()),
                businessId: businessId,
                name: entry.key,
                role: entry.key,
                roleTier: Value(entry.value),
                pin: '0000',
              ),
            );
      }
      final rows = await db.select(db.users).get();
      expect(rows.map((u) => u.role).toSet(),
          {'ceo', 'manager', 'stock_keeper', 'cashier', 'rider'});
      expect(rows.map((u) => u.roleTier).toSet(), {2, 3, 4, 5, 6});
    });
  });

  group('v8→v9 backfill SQL', () {
    // Tests the data-rewrite UPDATE statements from the onUpgrade block on
    // an unconstrained sandbox table created via customStatement. Verifies
    // the SQL logic in isolation; the Drift TableMigration step that
    // rebuilds the real tables is library code we trust.
    late AppDatabase db;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      await db.customStatement(
        'CREATE TABLE sandbox ('
        '  id TEXT PRIMARY KEY,'
        '  role TEXT NOT NULL,'
        '  role_tier INTEGER NOT NULL'
        ')',
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('admin → ceo/6, staff → cashier/3, ceo/5 → ceo/6, manager/4 → manager/5',
        () async {
      // Seed: one row per pre-migration vocabulary case.
      await db.customStatement("INSERT INTO sandbox VALUES ('admin-row', 'admin',   4)");
      await db.customStatement("INSERT INTO sandbox VALUES ('staff-row', 'staff',   1)");
      await db.customStatement("INSERT INTO sandbox VALUES ('ceo-row',   'ceo',     5)");
      await db.customStatement("INSERT INTO sandbox VALUES ('mgr-row',   'manager', 4)");

      // Apply the exact UPDATE statements from the v8→v9 onUpgrade block
      // (text-substituted s/users/sandbox/).
      await db.customStatement(
          "UPDATE sandbox SET role = 'ceo',     role_tier = 6 WHERE role = 'admin'");
      await db.customStatement(
          "UPDATE sandbox SET role = 'cashier', role_tier = 3 WHERE role = 'staff'");
      await db.customStatement(
          "UPDATE sandbox SET role_tier = 6 WHERE role = 'ceo'     AND role_tier <> 6");
      await db.customStatement(
          "UPDATE sandbox SET role_tier = 5 WHERE role = 'manager' AND role_tier <> 5");

      final rows = await db
          .customSelect('SELECT id, role, role_tier FROM sandbox ORDER BY id')
          .get();
      expect(rows.length, 4);
      final byId = {
        for (final row in rows)
          row.read<String>('id'): {
            'role': row.read<String>('role'),
            'role_tier': row.read<int>('role_tier'),
          }
      };
      expect(byId['admin-row'], {'role': 'ceo',     'role_tier': 6});
      expect(byId['staff-row'], {'role': 'cashier', 'role_tier': 3});
      expect(byId['ceo-row'],   {'role': 'ceo',     'role_tier': 6});
      expect(byId['mgr-row'],   {'role': 'manager', 'role_tier': 5});
    });

    test('invites: admin → ceo, staff → cashier (no role_tier column)',
        () async {
      // Reuse the sandbox table but ignore role_tier (mirror invites which
      // has no role_tier column — the migration only runs the role-rename
      // pair on invites).
      await db.customStatement("INSERT INTO sandbox VALUES ('i-admin',   'admin',   0)");
      await db.customStatement("INSERT INTO sandbox VALUES ('i-staff',   'staff',   0)");
      await db.customStatement("INSERT INTO sandbox VALUES ('i-cashier', 'cashier', 0)");
      await db.customStatement("INSERT INTO sandbox VALUES ('i-manager', 'manager', 0)");

      await db.customStatement("UPDATE sandbox SET role = 'ceo'     WHERE role = 'admin'");
      await db.customStatement("UPDATE sandbox SET role = 'cashier' WHERE role = 'staff'");

      final rows = await db
          .customSelect('SELECT id, role FROM sandbox ORDER BY id')
          .get();
      final byId = {
        for (final row in rows) row.read<String>('id'): row.read<String>('role'),
      };
      expect(byId['i-admin'],   'ceo');
      expect(byId['i-staff'],   'cashier');
      expect(byId['i-cashier'], 'cashier');
      expect(byId['i-manager'], 'manager');
    });

    test('idempotency: re-running the backfill on migrated rows is a no-op',
        () async {
      // Seed already-migrated rows.
      await db.customStatement("INSERT INTO sandbox VALUES ('1', 'ceo',     6)");
      await db.customStatement("INSERT INTO sandbox VALUES ('2', 'cashier', 3)");
      await db.customStatement("INSERT INTO sandbox VALUES ('3', 'manager', 5)");

      // Re-run the migration's UPDATEs.
      await db.customStatement(
          "UPDATE sandbox SET role = 'ceo',     role_tier = 6 WHERE role = 'admin'");
      await db.customStatement(
          "UPDATE sandbox SET role = 'cashier', role_tier = 3 WHERE role = 'staff'");
      await db.customStatement(
          "UPDATE sandbox SET role_tier = 6 WHERE role = 'ceo'     AND role_tier <> 6");
      await db.customStatement(
          "UPDATE sandbox SET role_tier = 5 WHERE role = 'manager' AND role_tier <> 5");

      final rows = await db
          .customSelect('SELECT id, role, role_tier FROM sandbox ORDER BY id')
          .get();
      expect(rows[0].read<String>('role'), 'ceo');     expect(rows[0].read<int>('role_tier'), 6);
      expect(rows[1].read<String>('role'), 'cashier'); expect(rows[1].read<int>('role_tier'), 3);
      expect(rows[2].read<String>('role'), 'manager'); expect(rows[2].read<int>('role_tier'), 5);
    });
  });
}
