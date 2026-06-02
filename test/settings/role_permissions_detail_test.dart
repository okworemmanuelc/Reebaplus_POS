// role_permissions_detail_test.dart
//
// §10.2 Roles & Permissions detail — per-role permission toggles + the two
// numeric limits. CEO is locked all-on; non-CEO grants/revokes sync, and the
// limit edits persist + sync.

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/role_permissions_detail_screen.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late RoleData ceoRole;
  late RoleData cashierRole;
  late RoleData managerRole;
  const businessId = 'biz-1';
  const ceoRoleId = 'role-ceo';
  const cashierRoleId = 'role-cashier';
  const managerRoleId = 'role-manager';
  const ceoUserId = 'user-ceo';

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://placeholder.supabase.co',
      anonKey: 'placeholder',
    );
  });

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    db.businessIdResolver = () => businessId;
    db.userIdResolver = () => ceoUserId;
    await db.customSelect('SELECT 1').get(); // force onCreate (seeds permissions)

    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(
            id: const Value(businessId),
            name: 'Test Biz',
          ),
        );
    for (final r in [
      (ceoRoleId, 'CEO', 'ceo'),
      (cashierRoleId, 'Cashier', 'cashier'),
      (managerRoleId, 'Manager', 'manager'),
    ]) {
      await db.into(db.roles).insert(
            RolesCompanion.insert(
              id: Value(r.$1),
              businessId: businessId,
              name: r.$2,
              slug: r.$3,
              isSystemDefault: const Value(true),
            ),
          );
    }
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: const Value(ceoUserId),
            businessId: businessId,
            name: 'Carla CEO',
            pin: '0000',
          ),
        );
    await db.into(db.userBusinesses).insert(
          UserBusinessesCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            userId: ceoUserId,
            roleId: ceoRoleId,
          ),
        );
    // CEO can manage settings (so the edit guards pass).
    await db.into(db.rolePermissions).insert(
          RolePermissionsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            roleId: ceoRoleId,
            permissionKey: 'settings.manage',
          ),
        );
    // Cashier starts with one grant so the revoke test has something to remove.
    await db.into(db.rolePermissions).insert(
          RolePermissionsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            roleId: cashierRoleId,
            permissionKey: 'stock.view',
          ),
        );

    ceoRole = await (db.select(db.roles)..where((t) => t.id.equals(ceoRoleId)))
        .getSingle();
    cashierRole = await (db.select(db.roles)
          ..where((t) => t.id.equals(cashierRoleId)))
        .getSingle();
    managerRole = await (db.select(db.roles)
          ..where((t) => t.id.equals(managerRoleId)))
        .getSingle();
  });

  tearDown(() => db.close());

  // Pump in a tall viewport so all 30 toggles + the limits fit on screen and
  // can be interacted with directly (no scrolling/off-fold tap misses).
  Future<void> pumpDetail(WidgetTester tester, RoleData role) async {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    container.read(authProvider).value = await db.storesDao.getUserById(ceoUserId);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: RolePermissionsDetailScreen(role: role)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<int> grantCount(String roleId, String key) async {
    final rows = await (db.select(db.rolePermissions)
          ..where((t) => t.roleId.equals(roleId) & t.permissionKey.equals(key)))
        .get();
    return rows.length;
  }

  Future<String?> settingValue(String roleId, String key) async {
    final row = await (db.select(db.roleSettings)
          ..where((t) => t.roleId.equals(roleId) & t.settingKey.equals(key)))
        .getSingleOrNull();
    return row?.settingValue;
  }

  testWidgets('CEO role: all switches locked on; limits read-only',
      (tester) async {
    await pumpDetail(tester, ceoRole);

    final switches =
        tester.widgetList<SwitchListTile>(find.byType(SwitchListTile)).toList();
    expect(switches.length, 33, reason: 'all 33 permissions shown');
    expect(
      switches.every((s) => s.onChanged == null && s.value == true),
      isTrue,
      reason: 'every CEO toggle is locked on',
    );
    // CEO has no editable discount slider; expense shows read-only "Unlimited".
    expect(find.byType(Slider), findsNothing);
    expect(find.text('Unlimited'), findsOneWidget);
  });

  testWidgets('toggling a permission on grants it (role_permissions:upsert)',
      (tester) async {
    await pumpDetail(tester, cashierRole);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Edit product prices'));
    await tester.pumpAndSettle();

    expect(await grantCount(cashierRoleId, 'products.edit_price'), 1);
    final pending = await getPendingQueue(db);
    expect(
      pending.any((r) => r.actionType == 'role_permissions:upsert'),
      isTrue,
    );
  });

  testWidgets('toggling a granted permission off revokes it (delete)',
      (tester) async {
    await pumpDetail(tester, cashierRole);

    final tile = find.widgetWithText(SwitchListTile, 'View stock levels');
    expect(tester.widget<SwitchListTile>(tile).value, isTrue,
        reason: 'seeded grant starts on');
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(await grantCount(cashierRoleId, 'stock.view'), 0);
    final pending = await getPendingQueue(db);
    expect(
      pending.any((r) => r.actionType == 'role_permissions:delete'),
      isTrue,
    );
  });

  testWidgets('editing max expense approval stores kobo + enqueues',
      (tester) async {
    await pumpDetail(tester, cashierRole);

    await tester.enterText(find.byType(TextField), '5000');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(await settingValue(cashierRoleId, 'max_expense_approval_kobo'),
        '500000');
    final pending = await getPendingQueue(db);
    expect(pending.any((r) => r.actionType == 'role_settings:upsert'), isTrue);
  });

  testWidgets('dragging the discount slider stores a new percent',
      (tester) async {
    await pumpDetail(tester, cashierRole);

    await tester.drag(find.byType(Slider), const Offset(80, 0));
    await tester.pumpAndSettle();

    final disc = await settingValue(cashierRoleId, 'max_discount_percent');
    expect(disc, isNotNull);
    expect(int.parse(disc!), greaterThan(0));
    final pending = await getPendingQueue(db);
    expect(pending.any((r) => r.actionType == 'role_settings:upsert'), isTrue);
  });

  testWidgets(
      'Manager role: "Allow viewing other stores" defaults off, persists + enqueues',
      (tester) async {
    await pumpDetail(tester, managerRole);

    final tile =
        find.widgetWithText(SwitchListTile, 'Allow viewing other stores');
    expect(tile, findsOneWidget, reason: 'shown for the Manager role');
    expect(tester.widget<SwitchListTile>(tile).value, isFalse,
        reason: 'off by default');

    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(await settingValue(managerRoleId, 'manager_view_all_stores'), 'true');
    final pending = await getPendingQueue(db);
    expect(pending.any((r) => r.actionType == 'role_settings:upsert'), isTrue);
  });

  testWidgets('CEO role: no cross-store toggle (Manager-only)', (tester) async {
    await pumpDetail(tester, ceoRole);
    expect(find.widgetWithText(SwitchListTile, 'Allow viewing other stores'),
        findsNothing);
  });

  testWidgets('Cashier role: no cross-store toggle (Manager-only)',
      (tester) async {
    await pumpDetail(tester, cashierRole);
    expect(find.widgetWithText(SwitchListTile, 'Allow viewing other stores'),
        findsNothing);
  });

  test(
      'managerCanViewAllStoresProvider: false by default, true once CEO enables it',
      () async {
    // A Manager user + membership so currentUserRoleProvider resolves Manager.
    const mgrUserId = 'user-mgr';
    await db.into(db.users).insert(UsersCompanion.insert(
          id: const Value(mgrUserId),
          businessId: businessId,
          name: 'Mara Manager',
          pin: '0000',
        ));
    await db.into(db.userBusinesses).insert(UserBusinessesCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: businessId,
          userId: mgrUserId,
          roleId: managerRoleId,
        ));

    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    container.read(authProvider).value = await db.storesDao.getUserById(mgrUserId);
    // Keep the derived provider (and its stream deps) subscribed.
    container.listen(managerCanViewAllStoresProvider, (_, __) {});

    Future<bool> settle(bool want) async {
      for (var i = 0; i < 50; i++) {
        if (container.read(managerCanViewAllStoresProvider) == want) return want;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      return container.read(managerCanViewAllStoresProvider);
    }

    expect(await settle(false), isFalse, reason: 'off until the CEO enables it');

    await db.roleSettingsDao
        .set(managerRoleId, kManagerViewAllStoresKey, 'true');

    expect(await settle(true), isTrue, reason: 'unlocked once the row is true');
  });
}
