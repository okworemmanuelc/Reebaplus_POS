// roles_permissions_screen_test.dart
//
// §10.1/§10.2 — the Roles & Permissions list: four role cards with grant
// counts; tapping one opens its detail.

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
import 'package:reebaplus_pos/core/settings/role_permissions_detail_screen.dart';
import 'package:reebaplus_pos/core/settings/roles_permissions_screen.dart';

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
    await db.customSelect('SELECT 1').get();

    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(
            id: const Value(businessId),
            name: 'Test Biz',
          ),
        );
    for (final r in [
      (ceoRoleId, 'CEO', 'ceo'),
      ('role-mgr', 'Manager', 'manager'),
      (cashierRoleId, 'Cashier', 'cashier'),
      ('role-sk', 'Stock keeper', 'stock_keeper'),
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
    await db.into(db.rolePermissions).insert(
          RolePermissionsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            roleId: ceoRoleId,
            permissionKey: 'settings.manage',
          ),
        );
    // Cashier: two grants → its card subtitle should read "2 of 33 permissions".
    for (final key in ['sales.make', 'stock.view']) {
      await db.into(db.rolePermissions).insert(
            RolePermissionsCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              roleId: cashierRoleId,
              permissionKey: key,
            ),
          );
    }
  });

  tearDown(() => db.close());

  Future<void> pumpList(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    container.read(authProvider).value = await db.storesDao.getUserById(ceoUserId);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: RolesPermissionsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders four role cards with grant counts', (tester) async {
    await pumpList(tester);

    expect(find.text('CEO'), findsOneWidget);
    expect(find.text('Manager'), findsOneWidget);
    expect(find.text('Cashier'), findsOneWidget);
    expect(find.text('Stock keeper'), findsOneWidget);

    expect(find.text('All 33 permissions'), findsOneWidget); // CEO, locked
    expect(find.text('2 of 33 permissions'), findsOneWidget); // Cashier
  });

  testWidgets('tapping a role card opens its detail', (tester) async {
    await pumpList(tester);

    await tester.tap(find.text('Cashier'));
    await tester.pumpAndSettle();

    expect(find.byType(RolePermissionsDetailScreen), findsOneWidget);
  });
}
