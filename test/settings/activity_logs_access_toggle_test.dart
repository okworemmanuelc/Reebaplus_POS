// activity_logs_access_toggle_test.dart
//
// §10.1 Activity Logs access — per-role toggle for `activity_logs.view`.
//   * CEO row is locked ON (switch disabled, value true).
//   * Toggling a non-CEO role on grants the permission (role_permissions:upsert).
//   * Toggling a pre-existing grant off revokes it (role_permissions:delete).

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/settings/activity_logs_access_screen.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  const businessId = 'biz-1';
  const ceoRoleId = 'role-ceo';
  const cashierRoleId = 'role-cashier';
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
    await db.customSelect('SELECT 1').get(); // force onCreate

    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(
            id: const Value(businessId),
            name: 'Test Biz',
          ),
        );
    for (final r in [
      (ceoRoleId, 'CEO', 'ceo'),
      (cashierRoleId, 'Cashier', 'cashier'),
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
    // CEO can manage settings (so the toggle's permission guard passes).
    await db.into(db.rolePermissions).insert(
          RolePermissionsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            roleId: ceoRoleId,
            permissionKey: 'settings.manage',
          ),
        );
  });

  tearDown(() => db.close());

  Future<ProviderContainer> pumpScreen(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    container.read(authProvider).value = await db.storesDao.getUserById(ceoUserId);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ActivityLogsAccessScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<int> grantCount(String roleId) async {
    final rows = await (db.select(db.rolePermissions)
          ..where((t) =>
              t.roleId.equals(roleId) &
              t.permissionKey.equals('activity_logs.view')))
        .get();
    return rows.length;
  }

  testWidgets('CEO row is locked ON; others start off', (tester) async {
    await pumpScreen(tester);

    final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
    expect(switches, hasLength(2));

    final locked = switches.where((s) => s.onChanged == null).toList();
    expect(locked, hasLength(1), reason: 'only the CEO row is locked');
    expect(locked.first.value, isTrue, reason: 'CEO is always on');

    final editable = switches.where((s) => s.onChanged != null).toList();
    expect(editable, hasLength(1));
    expect(editable.first.value, isFalse, reason: 'Cashier starts without view');
  });

  testWidgets('toggling Cashier on grants activity_logs.view', (tester) async {
    await pumpScreen(tester);

    final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
    final idx = switches.indexWhere((s) => s.onChanged != null);
    await tester.tap(find.byType(Switch).at(idx));
    await tester.pumpAndSettle();

    expect(await grantCount(cashierRoleId), 1, reason: 'local grant written');
    final pending = await getPendingQueue(db);
    expect(
      pending.any((r) => r.actionType == 'role_permissions:upsert'),
      isTrue,
      reason: 'grant enqueues an upsert',
    );
  });

  testWidgets('toggling a pre-existing grant off revokes it', (tester) async {
    // Seed the Cashier grant directly (no queue entry) so the row starts ON.
    await db.into(db.rolePermissions).insert(
          RolePermissionsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            roleId: cashierRoleId,
            permissionKey: 'activity_logs.view',
          ),
        );

    await pumpScreen(tester);

    final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
    final idx = switches.indexWhere((s) => s.onChanged != null);
    expect(switches[idx].value, isTrue, reason: 'Cashier starts on');

    await tester.tap(find.byType(Switch).at(idx));
    await tester.pumpAndSettle();

    expect(await grantCount(cashierRoleId), 0, reason: 'local grant removed');
    final pending = await getPendingQueue(db);
    expect(
      pending.any((r) => r.actionType == 'role_permissions:delete'),
      isTrue,
      reason: 'revoke enqueues a delete tombstone',
    );
  });
}
