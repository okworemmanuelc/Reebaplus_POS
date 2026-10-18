// sidebar_role_visibility_test.dart
//
// Master plan §27.3 — sidebar items are hidden for roles that lack the
// matching permission (hard rules #6/#7: hide, don't grey out). The real
// AppDrawer pulls in SVG assets, responsive sizing, and several sync stream
// providers, so — like settings_menu_gating_test — we exercise the exact gate
// rules through the same provider chain (each key resolved through
// `currentUserPermissionsProvider`, the set the named gates read) in a minimal
// harness rather than pumping the whole drawer.
//
// Each role is seeded with the default permission grants from migration
// 0043 (the subset that drives a sidebar gate) and we assert which items
// resolve visible.

import 'package:drift/drift.dart' hide Column;
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

  // (roleId, slug, userId, [granted gate-relevant permission keys]).
  // Grants mirror the default matrix in migration 0043 (only the keys that
  // drive a §27.3 sidebar gate are listed).
  final roles = <({String roleId, String slug, String userId, List<String> keys})>[
    (
      roleId: 'role-ceo',
      slug: 'ceo',
      userId: 'user-ceo',
      keys: [
        'sales.make',
        'customers.add',
        'suppliers.manage',
        'expenses.create',
        'settings.manage',
        'activity_logs.view',
        'staff.invite',
      ],
    ),
    (
      roleId: 'role-manager',
      slug: 'manager',
      userId: 'user-manager',
      keys: ['sales.make', 'customers.add', 'expenses.create', 'staff.invite'],
    ),
    (
      roleId: 'role-cashier',
      slug: 'cashier',
      userId: 'user-cashier',
      keys: ['sales.make', 'customers.add'],
    ),
    (
      roleId: 'role-stock',
      slug: 'stock_keeper',
      userId: 'user-stock',
      keys: ['stock.view'], // none of these drive a gate
    ),
  ];

  // The sidebar gates under test → the label they guard. settings.manage
  // guards two rows (Stores and CEO Settings).
  const gates = <(String, String)>[
    ('sales.make', 'Point of Sale'),
    ('customers.add', 'Customers'),
    ('suppliers.manage', 'Supplier Accounts'),
    ('expenses.create', 'Expenses'),
    ('settings.manage', 'Stores'),
    ('settings.manage', 'CEO Settings'),
    ('activity_logs.view', 'Activity Logs'),
    ('staff.invite', 'Staff Management'),
  ];

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

    for (final r in roles) {
      await db.into(db.roles).insert(
            RolesCompanion.insert(
              id: Value(r.roleId),
              businessId: businessId,
              name: r.slug,
              slug: r.slug,
              isSystemDefault: const Value(true),
            ),
          );
      await db.into(db.users).insert(
            UsersCompanion.insert(
              id: Value(r.userId),
              businessId: businessId,
              name: r.userId,
              pin: '0000',
            ),
          );
      await db.into(db.userBusinesses).insert(
            UserBusinessesCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              userId: r.userId,
              roleId: r.roleId,
            ),
          );
      for (final key in r.keys) {
        await db.into(db.rolePermissions).insert(
              RolePermissionsCompanion.insert(
                id: Value(UuidV7.generate()),
                businessId: businessId,
                roleId: r.roleId,
                permissionKey: key,
              ),
            );
      }
    }
  });

  tearDown(() => db.close());

  // Renders every gated label behind its real gate expression, plus the three
  // always-visible items (Home/Inventory/Orders).
  Widget harness(ProviderContainer container) => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (_, ref, __) => Column(
                children: [
                  const Text('Home'),
                  const Text('Inventory'),
                  const Text('Orders'),
                  for (final g in gates)
                    if (ref.watch(currentUserPermissionsProvider).contains(g.$1))
                      Text(g.$2),
                ],
              ),
            ),
          ),
        ),
      );

  // What each role should see among the gated rows (the always-on three are
  // asserted separately).
  final expected = <String, List<String>>{
    'user-ceo': [
      'Point of Sale',
      'Customers',
      'Supplier Accounts',
      'Expenses',
      'Stores',
      'CEO Settings',
      'Activity Logs',
      'Staff Management',
    ],
    'user-manager': [
      'Point of Sale',
      'Customers',
      'Expenses',
      'Staff Management',
    ],
    'user-cashier': ['Point of Sale', 'Customers'],
    'user-stock': <String>[],
  };

  for (final r in roles) {
    testWidgets('${r.slug}: sees only its §27.3-allowed items', (tester) async {
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      container.read(authProvider).value =
          await db.storesDao.getUserById(r.userId);

      await tester.pumpWidget(harness(container));
      await tester.pumpAndSettle();

      // Always-on items show for every role.
      for (final label in ['Home', 'Inventory', 'Orders']) {
        expect(find.text(label), findsOneWidget, reason: '$label always shows');
      }

      final visible = expected[r.userId]!;
      for (final g in gates) {
        final shouldShow = visible.contains(g.$2);
        expect(
          find.text(g.$2),
          shouldShow ? findsOneWidget : findsNothing,
          reason: '${r.slug} ${shouldShow ? 'sees' : 'must not see'} ${g.$2}',
        );
      }
    });
  }
}
