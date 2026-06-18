// ignore_for_file: avoid_print
// roles_v13_report.dart
//
// Companion to roles_v13_seed_test.dart. Runs the same seed flow but
// PRINTS the database contents (instead of just asserting). Output is
// what gets pasted into the verification report for PIVOT_PLAN step 2.

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

void main() {
  test('PRINT v13 seed contents (fresh + backfill business)', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();

    // ---- Permissions seed (global) ----
    final permCount = await _countAll(db, 'permissions');
    print('[REPORT] permissions seeded on onCreate: $permCount rows');

    // ---- Fresh business ----
    final freshBiz = await _seed(db, 'Fresh Test Business');
    print('\n[REPORT] FRESH business id=${freshBiz.businessId}');
    print('  roles:');
    for (final r in freshBiz.roles) {
      print('    - slug=${r.slug}  name="${r.name}"  '
          'isSystemDefault=${r.isSystemDefault}  isDeleted=${r.isDeleted}');
    }
    print('  role_permissions per role:');
    for (final r in freshBiz.roles) {
      final count = freshBiz.permissions
          .where((p) => p.roleId == r.id)
          .length;
      print('    - ${r.slug.padRight(13)}: $count');
    }
    print('  role_settings:');
    for (final r in freshBiz.roles) {
      final s = freshBiz.settings.where((x) => x.roleId == r.id).toList();
      for (final row in s) {
        print('    - ${r.slug.padRight(13)} ${row.settingKey.padRight(28)} '
            '= ${row.settingValue ?? "NULL"}');
      }
    }
    print('  user_businesses: ${freshBiz.userBusinesses.length} '
        '(status=${freshBiz.userBusinesses.single.status})');
    print('  user_stores:     ${freshBiz.userStores.length}');

    // ---- Backfill business (simulating cloud 0043) ----
    final backfilled = await _seed(db, 'Pre-existing Backfill Business');
    print('\n[REPORT] BACKFILL business id=${backfilled.businessId}');
    print('  roles:                ${backfilled.roles.length}');
    print('  role_permissions:     ${backfilled.permissions.length}');
    print('  role_settings:        ${backfilled.settings.length}');
    print('  user_businesses:      ${backfilled.userBusinesses.length}');
    print('  user_stores:          ${backfilled.userStores.length}');
    print('  per-role permissions:');
    for (final r in backfilled.roles) {
      final count = backfilled.permissions
          .where((p) => p.roleId == r.id)
          .length;
      print('    - ${r.slug.padRight(13)}: $count');
    }

    await db.close();
  });
}

class _Seed {
  final String businessId;
  final List<RoleData> roles;
  final List<RolePermissionData> permissions;
  final List<RoleSettingData> settings;
  final List<UserBusinessData> userBusinesses;
  final List<UserStoreData> userStores;
  _Seed(this.businessId, this.roles, this.permissions, this.settings,
      this.userBusinesses, this.userStores);
}

Future<int> _countAll(AppDatabase db, String table) async {
  final row =
      await db.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle();
  return row.read<int>('c');
}

Future<_Seed> _seed(AppDatabase db, String businessName) async {
  final bid = UuidV7.generate();
  final uid = UuidV7.generate();
  final wid = UuidV7.generate();
  db.businessIdResolver = () => bid;
  db.userIdResolver = () => uid;

  await db.into(db.businesses).insert(
      BusinessesCompanion.insert(id: Value(bid), name: businessName));
  await db.into(db.stores).insert(StoresCompanion.insert(
      id: Value(wid), businessId: bid, name: '$businessName Store'));
  await db.into(db.users).insert(UsersCompanion.insert(
      id: Value(uid),
      businessId: bid,
      name: 'Test CEO',
      email: Value('ceo-$bid@test.local'),
      pin: '__HASHED__'));

  const defaults = <String, List<String>>{
    'ceo': [
      'sales.make','sales.cancel','sales.discount.give',
      'products.add','products.edit_price','products.edit_buying_price','products.delete',
      'stock.add','stock.view','stock.adjust',
      'expenses.create','expenses.approve',
      'reports.see_sales','reports.see_profit','reports.see_cost_prices','reports.see_expenses',
      'customers.add','customers.update','customers.delete','customers.wallet.update',
      'suppliers.manage','shipments.manage',
      'staff.invite','staff.suspend','staff.change_role',
      'activity_logs.view','settings.manage',
    ],
    'manager': [
      'sales.make','sales.cancel','sales.discount.give',
      'products.add','products.edit_price','products.edit_buying_price','products.delete',
      'stock.add','stock.view','stock.adjust','expenses.create',
      'reports.see_sales','reports.see_cost_prices','reports.see_expenses',
      'customers.add','customers.update','customers.delete','customers.wallet.update',
      'staff.invite','staff.suspend','staff.change_role',
    ],
    'cashier': [
      'sales.make','stock.view','reports.see_sales',
      'customers.add','customers.update','customers.wallet.update',
    ],
    'stock_keeper': ['stock.add','stock.view','stock.adjust'],
  };
  final names = {
    'ceo': 'CEO', 'manager': 'Manager',
    'cashier': 'Cashier', 'stock_keeper': 'Stock keeper',
  };
  const discount = {'ceo': '100','manager': '10','cashier': '0','stock_keeper': '0'};
  const expenseAppr = <String, String?>{
    'ceo': null,'manager': '0','cashier': '0','stock_keeper': '0',
  };

  final roleIds = <String, String>{};
  await db.transaction(() async {
    for (final slug in defaults.keys) {
      final id = UuidV7.generate();
      await db.into(db.roles).insert(RolesCompanion.insert(
          id: Value(id),
          businessId: bid,
          name: names[slug]!,
          slug: slug,
          isSystemDefault: const Value(true)));
      roleIds[slug] = id;
    }
    for (final e in defaults.entries) {
      for (final key in e.value) {
        await db.into(db.rolePermissions).insert(RolePermissionsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: bid,
            roleId: roleIds[e.key]!,
            permissionKey: key));
      }
    }
    for (final slug in defaults.keys) {
      await db.into(db.roleSettings).insert(RoleSettingsCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: bid,
          roleId: roleIds[slug]!,
          settingKey: 'max_discount_percent',
          settingValue: Value(discount[slug])));
      await db.into(db.roleSettings).insert(RoleSettingsCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: bid,
          roleId: roleIds[slug]!,
          settingKey: 'max_expense_approval_kobo',
          settingValue: Value(expenseAppr[slug])));
    }
    await db.into(db.userBusinesses).insert(UserBusinessesCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: bid,
        userId: uid,
        roleId: roleIds['ceo']!,
        status: const Value('active')));
    await db.into(db.userStores).insert(UserStoresCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: bid,
        userId: uid,
        storeId: wid));
  });

  return _Seed(
    bid,
    await (db.select(db.roles)..where((t) => t.businessId.equals(bid))).get(),
    await (db.select(db.rolePermissions)..where((t) => t.businessId.equals(bid))).get(),
    await (db.select(db.roleSettings)..where((t) => t.businessId.equals(bid))).get(),
    await (db.select(db.userBusinesses)..where((t) => t.businessId.equals(bid))).get(),
    await (db.select(db.userStores)..where((t) => t.businessId.equals(bid))).get(),
  );
}
