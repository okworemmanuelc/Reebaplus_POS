// roles_v13_seed_test.dart
//
// Verifies schema v13 (PIVOT_PLAN step 2):
//   * The seven new tables exist.
//   * The global `permissions` table is seeded with 34 rows.
//   * A fresh business gets 4 roles (with the right slugs), 65
//     role_permissions (CEO 31 / Manager 25 / Cashier 6 / Stock keeper 3),
//     8 role_settings (with the right default values), 1 user_businesses
//     row, and 1 user_stores row.
//   * The same seed logic works for a pre-existing business (backfill
//     scenario from cloud migration 0043).
//
// Live cloud is not in scope for unit tests, so the seed logic from
// cloud migrations 0043/0044 (+ 0061's customers.set_debt_limit grant) is
// mirrored in this file's `_seedDefaultRolesForBusiness` helper. The DDL it
// produces must match what the `seed_default_roles_for_business` SQL function
// produces — the assertions below check both row counts and slugs/
// keys/values, which is the contract.

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    // Force onCreate to run (which seeds permissions).
    await db.customSelect('SELECT 1').get();
  });

  tearDown(() => db.close());

  group('Schema v13 — roles/permissions/membership', () {
    test('all seven new tables exist', () async {
      final tables = await db
          .customSelect(
            "SELECT name FROM sqlite_master "
            "WHERE type='table' "
            "  AND name IN ('permissions','roles','role_permissions',"
            "'role_settings','user_businesses','invite_codes','user_stores') "
            "ORDER BY name",
          )
          .get();
      final names = tables.map((r) => r.read<String>('name')).toList();
      expect(
        names,
        equals([
          'invite_codes',
          'permissions',
          'role_permissions',
          'role_settings',
          'roles',
          'user_businesses',
          'user_stores',
        ]),
      );
    });

    test('permissions table seeded with 35 default rows on fresh install',
        () async {
      final perms = await db.permissionsDao.getAll();
      expect(perms.length, equals(35));

      // Spot-check a few keys + categories.
      final keys = perms.map((p) => p.key).toSet();
      expect(keys.contains('sales.make'), isTrue);
      expect(keys.contains('expenses.approve'), isTrue);
      expect(keys.contains('settings.manage'), isTrue);
      expect(keys.contains('settings.delete_business'), isTrue);
      expect(keys.contains('stores.manage'), isTrue); // §10.2
      expect(keys.contains('staff.assign_stores'), isTrue); // §9.5

      // Categories from master plan §10.2 grouping.
      final categories =
          perms.map((p) => p.category).toSet().toList()..sort();
      expect(
        categories,
        equals(['Customers', 'Expenses', 'Products', 'Reports',
                'Sales', 'Staff', 'Stock', 'Stores', 'Suppliers', 'System']),
      );
    });

    test('fresh business seed: 4 roles / 65 role_permissions / 8 settings',
        () async {
      final report = await _seedAndReport(
        db,
        businessName: 'Test Business — Fresh',
      );
      _expectSeedShape(report);
    });

    test('backfill scenario: pre-existing business gets the same shape',
        () async {
      // Insert two businesses sequentially, simulating a backfill loop
      // over `SELECT id FROM businesses`. The second business is the
      // "pre-existing" one being backfilled — the assertion is that
      // seeding it produces the same row counts as the fresh case.
      await _seedAndReport(db, businessName: 'First');
      final second = await _seedAndReport(db, businessName: 'Second');
      _expectSeedShape(second);

      // And total rows across both businesses should be 2× the per-
      // business counts.
      final totalRoles = await _countAll(db, 'roles');
      final totalPerms = await _countAll(db, 'role_permissions');
      final totalSettings = await _countAll(db, 'role_settings');
      final totalUserBiz = await _countAll(db, 'user_businesses');
      final totalUserStores = await _countAll(db, 'user_stores');

      expect(totalRoles, equals(8));
      expect(totalPerms, equals(130)); // 65 grants × 2 businesses
      expect(totalSettings, equals(16));
      expect(totalUserBiz, equals(2));
      expect(totalUserStores, equals(2));
    });

    test('role slugs are the four canonical machine identifiers', () async {
      final report = await _seedAndReport(db, businessName: 'Slug Check');
      final slugs = report.roles.map((r) => r.slug).toSet();
      expect(
        slugs,
        equals({'ceo', 'manager', 'cashier', 'stock_keeper'}),
      );

      // All four are system defaults.
      for (final r in report.roles) {
        expect(r.isSystemDefault, isTrue, reason: 'role ${r.slug}');
        expect(r.isDeleted, isFalse, reason: 'role ${r.slug}');
      }
    });

    test('default role_settings values match the planning decision', () async {
      final report = await _seedAndReport(db, businessName: 'Settings Check');

      // Build a (slug, key) -> value map for easy assertions.
      final settings = <String, String?>{};
      for (final s in report.settings) {
        final role = report.roles.firstWhere((r) => r.id == s.roleId);
        settings['${role.slug}.${s.settingKey}'] = s.settingValue;
      }

      // max_discount_percent
      expect(settings['ceo.max_discount_percent'], equals('100'));
      expect(settings['manager.max_discount_percent'], equals('10'));
      expect(settings['cashier.max_discount_percent'], equals('0'));
      expect(settings['stock_keeper.max_discount_percent'], equals('0'));

      // max_expense_approval_kobo: CEO null = unlimited; others 0
      // (Manager 0 by decision — CEO must set explicitly).
      expect(settings['ceo.max_expense_approval_kobo'], isNull);
      expect(settings['manager.max_expense_approval_kobo'], equals('0'));
      expect(settings['cashier.max_expense_approval_kobo'], equals('0'));
      expect(settings['stock_keeper.max_expense_approval_kobo'], equals('0'));
    });

    test('Stock keeper does NOT have products.add (planning correction)',
        () async {
      final report = await _seedAndReport(db, businessName: 'Stock Keeper');
      final sk = report.roles.firstWhere((r) => r.slug == 'stock_keeper');
      final skPerms = report.permissions
          .where((p) => p.roleId == sk.id)
          .map((p) => p.permissionKey)
          .toSet();

      expect(skPerms.contains('products.add'), isFalse,
          reason: 'master plan §16.7: Stock keeper cannot add products');
      expect(skPerms.contains('stock.add'), isTrue);
      expect(skPerms.contains('stock.view'), isTrue);
      expect(skPerms.contains('stock.adjust'), isTrue);
      expect(skPerms.length, equals(3));
    });
  });
}

class _SeedReport {
  final String businessId;
  final String userId;
  final String storeId;
  final List<RoleData> roles;
  final List<RolePermissionData> permissions;
  final List<RoleSettingData> settings;
  final List<UserBusinessData> userBusinesses;
  final List<UserStoreData> userStores;

  _SeedReport({
    required this.businessId,
    required this.userId,
    required this.storeId,
    required this.roles,
    required this.permissions,
    required this.settings,
    required this.userBusinesses,
    required this.userStores,
  });
}

Future<int> _countAll(AppDatabase db, String table) async {
  final row = await db.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle();
  return row.read<int>('c');
}

Future<_SeedReport> _seedAndReport(
  AppDatabase db, {
  required String businessName,
}) async {
  final businessId = UuidV7.generate();
  final userId = UuidV7.generate();
  final storeId = UuidV7.generate();
  db.businessIdResolver = () => businessId;
  db.userIdResolver = () => userId;

  await db.into(db.businesses).insert(
        BusinessesCompanion.insert(
          id: Value(businessId),
          name: businessName,
        ),
      );
  await db.into(db.stores).insert(
        StoresCompanion.insert(
          id: Value(storeId),
          businessId: businessId,
          name: '$businessName Store',
        ),
      );
  await db.into(db.users).insert(
        UsersCompanion.insert(
          id: Value(userId),
          businessId: businessId,
          name: 'Test CEO',
          email: Value('ceo-$businessId@test.local'),
          pin: '__HASHED__',
        ),
      );

  await _seedDefaultRolesForBusiness(
    db,
    businessId: businessId,
    userId: userId,
    storeId: storeId,
  );

  return _SeedReport(
    businessId: businessId,
    userId: userId,
    storeId: storeId,
    roles: await db.rolesDao.getAll(),
    permissions: await (db.select(db.rolePermissions)
          ..where((t) => t.businessId.equals(businessId)))
        .get(),
    settings: await (db.select(db.roleSettings)
          ..where((t) => t.businessId.equals(businessId)))
        .get(),
    userBusinesses: await (db.select(db.userBusinesses)
          ..where((t) => t.businessId.equals(businessId)))
        .get(),
    userStores: await (db.select(db.userStores)
          ..where((t) => t.businessId.equals(businessId)))
        .get(),
  );
}

void _expectSeedShape(_SeedReport r) {
  // Top-level row counts (master plan §2.4 + the corrected matrix).
  expect(r.roles.length, equals(4),
      reason: 'CEO, Manager, Cashier, Stock keeper');
  expect(r.permissions.length, equals(65),
      reason: 'CEO 31 + Manager 25 + Cashier 6 + Stock keeper 3');
  expect(r.settings.length, equals(8),
      reason: '2 settings × 4 roles');
  expect(r.userBusinesses.length, equals(1),
      reason: 'Phase 1: lone CEO bound to their business');
  expect(r.userStores.length, equals(1),
      reason: 'CEO bound to their first store');

  // Per-role permission counts.
  final perRole = <String, int>{};
  for (final perm in r.permissions) {
    final role = r.roles.firstWhere((rl) => rl.id == perm.roleId);
    perRole[role.slug] = (perRole[role.slug] ?? 0) + 1;
  }
  expect(perRole['ceo'], equals(31));
  expect(perRole['manager'], equals(25));
  expect(perRole['cashier'], equals(6));
  expect(perRole['stock_keeper'], equals(3));

  // CEO membership is active.
  expect(r.userBusinesses.single.status, equals('active'));
  final ceoRole = r.roles.firstWhere((rl) => rl.slug == 'ceo');
  expect(r.userBusinesses.single.roleId, equals(ceoRole.id));
}

/// Mirrors the SQL function `seed_default_roles_for_business` in
/// supabase/migrations/0043_seed_permissions_and_backfill_businesses.sql
/// and the user_businesses / user_stores rows that
/// 0044_complete_onboarding_seeds_roles.sql writes after it. Kept in
/// the test file (not production code) because production never seeds
/// locally — the cloud is authoritative, the local rows arrive via
/// sync pull.
Future<void> _seedDefaultRolesForBusiness(
  AppDatabase db, {
  required String businessId,
  required String userId,
  required String storeId,
}) async {
  await db.transaction(() async {
    // 4 roles.
    final defaultRoles = [
      ('CEO',          'ceo'),
      ('Manager',      'manager'),
      ('Cashier',      'cashier'),
      ('Stock keeper', 'stock_keeper'),
    ];
    final roleIds = <String, String>{};
    for (final (name, slug) in defaultRoles) {
      final id = UuidV7.generate();
      await db.into(db.roles).insert(
            RolesCompanion.insert(
              id: Value(id),
              businessId: businessId,
              name: name,
              slug: slug,
              isSystemDefault: const Value(true),
            ),
          );
      roleIds[slug] = id;
    }

    // Default permission matrix.
    const defaults = <String, List<String>>{
      'ceo': [
        'sales.make','sales.cancel','sales.discount.give',
        'products.add','products.edit_price','products.edit_buying_price','products.delete',
        'stock.add','stock.view','stock.adjust',
        'expenses.create','expenses.approve',
        'reports.see_sales','reports.see_profit','reports.see_cost_prices','reports.see_expenses',
        'customers.add','customers.update','customers.delete','customers.wallet.update',
        'customers.set_debt_limit',
        'suppliers.manage','shipments.manage',
        'staff.invite','staff.suspend','staff.change_role',
        'activity_logs.view','settings.manage',
        'funds.open_day','funds.close_day','funds.view',
      ],
      'manager': [
        'sales.make','sales.cancel','sales.discount.give',
        'products.add','products.edit_price','products.edit_buying_price','products.delete',
        'stock.add','stock.view','stock.adjust',
        'expenses.create',
        'reports.see_sales','reports.see_cost_prices','reports.see_expenses',
        'customers.add','customers.update','customers.delete','customers.wallet.update',
        'customers.set_debt_limit',
        'staff.invite','staff.suspend','staff.change_role',
        'funds.open_day','funds.close_day','funds.view',
      ],
      'cashier': [
        'sales.make','stock.view','reports.see_sales',
        'customers.add','customers.update','customers.wallet.update',
      ],
      // Master plan §16.7 (corrected this session): Stock keeper
      // CANNOT add products.
      'stock_keeper': [
        'stock.add','stock.view','stock.adjust',
      ],
    };
    for (final entry in defaults.entries) {
      final roleId = roleIds[entry.key]!;
      for (final key in entry.value) {
        await db.into(db.rolePermissions).insert(
              RolePermissionsCompanion.insert(
                id: Value(UuidV7.generate()),
                businessId: businessId,
                roleId: roleId,
                permissionKey: key,
              ),
            );
      }
    }

    // role_settings — 2 per role.
    const discountByRole = {
      'ceo': '100', 'manager': '10', 'cashier': '0', 'stock_keeper': '0',
    };
    const expenseByRole = <String, String?>{
      'ceo': null, 'manager': '0', 'cashier': '0', 'stock_keeper': '0',
    };
    for (final slug in defaults.keys) {
      final roleId = roleIds[slug]!;
      await db.into(db.roleSettings).insert(
            RoleSettingsCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              roleId: roleId,
              settingKey: 'max_discount_percent',
              settingValue: Value(discountByRole[slug]),
            ),
          );
      await db.into(db.roleSettings).insert(
            RoleSettingsCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              roleId: roleId,
              settingKey: 'max_expense_approval_kobo',
              settingValue: Value(expenseByRole[slug]),
            ),
          );
    }

    // user_businesses: CEO bound to business.
    await db.into(db.userBusinesses).insert(
          UserBusinessesCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            userId: userId,
            roleId: roleIds['ceo']!,
            status: const Value('active'),
          ),
        );

    // user_stores: CEO bound to their first store.
    await db.into(db.userStores).insert(
          UserStoresCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            userId: userId,
            storeId: storeId,
          ),
        );
  });
}
