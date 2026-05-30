// appearance_settings_screen_test.dart
//
// §10.1 Appearance — the CEO picks the business accent colour (synced). Picking
// a colour writes the `business_design_system` setting and enqueues it; the
// page is gated to settings.manage.

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
import 'package:reebaplus_pos/core/settings/appearance_settings_screen.dart';
import 'package:reebaplus_pos/core/theme/theme_notifier.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  const businessId = 'biz-1';
  const ceoRoleId = 'role-ceo';
  const cashierRoleId = 'role-cashier';
  const ceoUserId = 'user-ceo';
  const cashierUserId = 'user-cashier';

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
    await db.customSelect('SELECT 1').get();

    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(
              id: const Value(businessId), name: 'Test Biz'),
        );
    for (final r in [
      (ceoRoleId, 'CEO', 'ceo'),
      (cashierRoleId, 'Cashier', 'cashier'),
    ]) {
      await db.into(db.roles).insert(RolesCompanion.insert(
            id: Value(r.$1),
            businessId: businessId,
            name: r.$2,
            slug: r.$3,
            isSystemDefault: const Value(true),
          ));
    }
    for (final u in [
      (ceoUserId, 'Carla CEO', ceoRoleId),
      (cashierUserId, 'Cathy Cashier', cashierRoleId),
    ]) {
      await db.into(db.users).insert(UsersCompanion.insert(
            id: Value(u.$1),
            businessId: businessId,
            name: u.$2,
            pin: '0000',
          ));
      await db.into(db.userBusinesses).insert(UserBusinessesCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            userId: u.$1,
            roleId: u.$3,
          ));
    }
    await db.into(db.rolePermissions).insert(RolePermissionsCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: businessId,
          roleId: ceoRoleId,
          permissionKey: 'settings.manage',
        ));
  });

  tearDown(() async {
    await db.close();
    // themeController is a global singleton — reset to the brand default so a
    // tap in one test doesn't leak into another.
    themeController.setDesignSystem(DesignSystem.amber);
  });

  Future<void> pumpScreen(WidgetTester tester, String userId) async {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    container.read(authProvider).value = await db.storesDao.getUserById(userId);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: AppearanceSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<String?> settingValue(String key) async {
    final row = await (db.select(db.settings)
          ..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  testWidgets('CEO picks an accent → writes synced setting + enqueues',
      (tester) async {
    await pumpScreen(tester, ceoUserId);

    await tester.tap(find.text('Green'));
    await tester.pumpAndSettle();

    expect(await settingValue('business_design_system'), 'green');
    final pending = await getPendingQueue(db);
    expect(pending.any((r) => r.actionType == 'settings:upsert'), isTrue);
    expect(themeController.designSystem, DesignSystem.green);
  });

  testWidgets('non-CEO is blocked (no accent cards)', (tester) async {
    await pumpScreen(tester, cashierUserId);

    expect(find.text('You don\'t have access to settings.'), findsOneWidget);
    expect(find.text('Amber'), findsNothing);
    expect(find.text('Green'), findsNothing);
  });
}
