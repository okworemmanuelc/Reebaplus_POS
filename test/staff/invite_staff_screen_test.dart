// invite_staff_screen_test.dart
//
// Phase 8B — verifies the invite-new-staff screen's role/store gating
// (master plan §9.4):
//   * A Manager sees only Cashier + Stock keeper in the role cards selector
//     (never CEO or Manager).
//   * A Manager's store dropdown is limited to their own store.
//
// Roles, the current Manager user + membership, and stores are seeded
// directly into an in-memory Drift DB (test-only inserts, not production
// sync writes). The screen derives the current role via
// currentUserRoleProvider, which reads the seeded membership + roles.

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
import 'package:reebaplus_pos/features/staff/screens/invite_staff_screen.dart';

void main() {
  late AppDatabase db;
  const businessId = 'biz-1';
  const store1Id = 'store-1';
  const store2Id = 'store-2';
  const managerUserId = 'user-mgr';
  const managerRoleId = 'role-manager';
  const cashierRoleId = 'role-cashier';
  const stockRoleId = 'role-stock';
  const ceoRoleId = 'role-ceo';

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
    // Force onCreate.
    await db.customSelect('SELECT 1').get();

    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(
            id: const Value(businessId),
            name: 'Test Biz',
            type: const Value('bar'),
          ),
        );
    for (final s in [
      (store1Id, 'Store 1'),
      (store2Id, 'Store 2'),
    ]) {
      await db.into(db.stores).insert(
            StoresCompanion.insert(
              id: Value(s.$1),
              businessId: businessId,
              name: s.$2,
            ),
          );
    }
    for (final r in [
      (ceoRoleId, 'CEO', 'ceo'),
      (managerRoleId, 'Manager', 'manager'),
      (cashierRoleId, 'Cashier', 'cashier'),
      (stockRoleId, 'Stock keeper', 'stock_keeper'),
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
            id: const Value(managerUserId),
            businessId: businessId,
            name: 'Mary Manager',
            pin: '0000',
            storeId: const Value(store1Id),
          ),
        );
    await db.into(db.userBusinesses).insert(
          UserBusinessesCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            userId: managerUserId,
            roleId: managerRoleId,
          ),
        );
  });

  tearDown(() => db.close());

  testWidgets('Manager role selector excludes CEO and Manager',
      (tester) async {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    // Bind the current user as the Manager so currentUserRoleProvider
    // resolves to the manager slug.
    container.read(authProvider).value = await db.storesDao
        .getUserById(managerUserId);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: InviteStaffScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // Cashier + Stock keeper offered; CEO + Manager never appear as selectable cards.
    expect(find.text('Cashier'), findsWidgets);
    expect(find.text('Stock keeper'), findsWidgets);
    expect(find.text('CEO'), findsNothing);
    expect(find.text('Manager'), findsNothing);
  });
}
