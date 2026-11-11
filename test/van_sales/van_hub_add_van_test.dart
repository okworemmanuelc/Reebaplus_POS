// van_hub_add_van_test.dart
//
// #779 — a van can be added from the Van Sales hub itself, through the same
// add-location flow Settings → Stores uses (kind fixed to van).

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
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/van_sales/van_sales_switch.dart';
import 'package:reebaplus_pos/features/van_sales/screens/van_sales_hub_screen.dart';

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
    debugOverrideVanSalesEnabled(true);
    debugOverrideDriverScreensEnabled(true);
    addTearDown(() {
      debugOverrideVanSalesEnabled(null);
      debugOverrideDriverScreensEnabled(null);
    });
    db = AppDatabase.forTesting(NativeDatabase.memory());
    db.businessIdResolver = () => businessId;
    db.userIdResolver = () => ceoUserId;
    await db.customSelect('SELECT 1').get();

    await db
        .into(db.businesses)
        .insert(
          BusinessesCompanion.insert(
            id: const Value(businessId),
            name: 'Test Biz',
          ),
        );
    for (final r in [
      (ceoRoleId, 'CEO', 'ceo'),
      (cashierRoleId, 'Cashier', 'cashier'),
    ]) {
      await db
          .into(db.roles)
          .insert(
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
      await db
          .into(db.users)
          .insert(
            UsersCompanion.insert(
              id: Value(u.$1),
              businessId: businessId,
              name: u.$2,
              pin: '0000',
            ),
          );
      await db
          .into(db.userBusinesses)
          .insert(
            UserBusinessesCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              userId: u.$1,
              roleId: u.$3,
            ),
          );
    }
    await db
        .into(db.rolePermissions)
        .insert(
          RolePermissionsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            roleId: ceoRoleId,
            permissionKey: 'van.manage',
          ),
        );
  });

  tearDown(() async => db.close());

  Future<void> pumpHub(WidgetTester tester, String userId) async {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    container.read(authProvider).value = await db.storesDao.getUserById(userId);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const VanSalesHubScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the action for a user with van.manage', (tester) async {
    await pumpHub(tester, ceoUserId);

    expect(find.text('No vans yet'), findsOneWidget);
    expect(find.text('Add a van'), findsOneWidget); // empty-state button
    expect(find.byTooltip('Add a van'), findsOneWidget); // app-bar action
  });

  testWidgets('hides the action without van.manage', (tester) async {
    await pumpHub(tester, cashierUserId);

    expect(find.text('Add a van'), findsNothing);
    expect(find.byTooltip('Add a van'), findsNothing);
  });

  testWidgets('adding a van from the hub lists it with the van kind', (
    tester,
  ) async {
    await pumpHub(tester, ceoUserId);

    await tester.tap(find.text('Add a van'));
    await tester.pumpAndSettle();

    final fields = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(TextFormField),
    );
    await tester.enterText(fields.first, '  blue   hilux ');
    await tester.tap(find.text('Add van'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('No vans yet'), findsNothing);
    expect(find.text('Blue Hilux'), findsOneWidget);

    final stores = await db.storesDao.getActiveStores();
    final van = stores.singleWhere((s) => s.name == 'Blue Hilux');
    expect(van.kind, kStoreKindVan);

    // Same sync enqueue as the Settings flow.
    final pending = await getPendingQueue(db);
    expect(
      pending
          .where((r) => r.actionType == 'stores:upsert')
          .map(decodePayload)
          .any((p) => p['id'] == van.id),
      isTrue,
    );

    // With a van present the app-bar action is still there.
    expect(find.byTooltip('Add a van'), findsOneWidget);
  });
}
