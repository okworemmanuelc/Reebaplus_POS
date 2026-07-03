// settings_menu_gating_test.dart
//
// §10.1 / hard rule #6–#7 — the "CEO Settings" drawer entry is gated on the
// `settings.manage` permission (CEO-only by default) and hidden entirely for
// roles without it.
//
// The real AppDrawer pulls in SVG assets, responsive sizing, SharedPreferences,
// and several sync stream providers, so we exercise the actual gate rule
// (`settings.manage` resolved through `currentUserPermissionsProvider`, the same
// set `Gates.manageSettings` reads) in a minimal harness rather than pumping the
// whole drawer.

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
import 'package:reebaplus_pos/core/providers/stream_providers.dart';

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
    for (final u in [
      (ceoUserId, 'Carla CEO', ceoRoleId),
      (cashierUserId, 'Cathy Cashier', cashierRoleId),
    ]) {
      await db.into(db.users).insert(
            UsersCompanion.insert(
              id: Value(u.$1),
              businessId: businessId,
              name: u.$2,
              pin: '0000',
            ),
          );
      await db.into(db.userBusinesses).insert(
            UserBusinessesCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              userId: u.$1,
              roleId: u.$3,
            ),
          );
    }
    // settings.manage granted to CEO only.
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

  // The exact gate the drawer uses for the "CEO Settings" row.
  Widget harness(ProviderContainer container) => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (_, ref, __) =>
                  ref.watch(currentUserPermissionsProvider).contains('settings.manage')
                      ? const Text('CEO Settings')
                      : const SizedBox.shrink(),
            ),
          ),
        ),
      );

  testWidgets('shown for a CEO (has settings.manage)', (tester) async {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    container.read(authProvider).value = await db.storesDao.getUserById(ceoUserId);

    await tester.pumpWidget(harness(container));
    await tester.pumpAndSettle();

    expect(find.text('CEO Settings'), findsOneWidget);
  });

  testWidgets('hidden for a Cashier (no settings.manage)', (tester) async {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    container.read(authProvider).value =
        await db.storesDao.getUserById(cashierUserId);

    await tester.pumpWidget(harness(container));
    await tester.pumpAndSettle();

    expect(find.text('CEO Settings'), findsNothing);
  });
}
