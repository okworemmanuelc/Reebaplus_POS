// stores_settings_screen_test.dart
//
// §10.1 Stores — the one surface that creates a `stores` row after onboarding.
// Covers both affordances (Add a store / Add a van, which differ only in `kind`)
// and pins the sheet's controller lifetime.
//
// The lifetime case is the regression that matters: the sheet used to take its
// `TextEditingController`s from the caller, which disposed them the instant
// `showModalBottomSheet` returned. That future completes on `pop`, while the
// sheet is still animating out with its fields mounted, so the fields touched a
// disposed controller and threw "A TextEditingController was used after being
// disposed." `pumpAndSettle` drives that exit animation, so a re-regression
// lands in `tester.takeException()`.

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
import 'package:reebaplus_pos/core/settings/stores_settings_screen.dart';
import 'package:reebaplus_pos/core/stores/van_store.dart';

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
    // The CEO holds both axes: stores.manage owns a warehouse, van.manage a van.
    for (final key in ['stores.manage', 'van.manage']) {
      await db.into(db.rolePermissions).insert(RolePermissionsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            roleId: ceoRoleId,
            permissionKey: key,
          ));
    }
    // The store onboarding mints, so the screen always has one card to render.
    await db.storesDao.createStore(name: 'Main Warehouse');
  });

  tearDown(() async => db.close());

  Future<void> pumpScreen(WidgetTester tester, String userId) async {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    container.read(authProvider).value = await db.storesDao.getUserById(userId);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: StoresSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Drives one add-location flow end to end: open the sheet, type [name], then
  /// submit and let the sheet animate fully out (the window the old crash lived
  /// in). Leaves the success toast's auto-dismiss timer drained.
  Future<void> addLocation(
    WidgetTester tester, {
    required String openLabel,
    required String submitLabel,
    required String name,
    String? note,
  }) async {
    await tester.tap(find.text(openLabel));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, name);
    if (note != null) {
      await tester.enterText(find.byType(TextFormField).last, note);
    }
    await tester.tap(find.text(submitLabel));
    await tester.pumpAndSettle();

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  Future<List<StoreData>> allStores() => db.storesDao.getActiveStores();

  testWidgets('Add a store inserts a non-van location + enqueues it',
      (tester) async {
    await pumpScreen(tester, ceoUserId);

    await addLocation(
      tester,
      openLabel: 'Add a store',
      submitLabel: 'Add store',
      name: 'Second Branch',
      note: '12 Market Road',
    );

    expect(tester.takeException(), isNull);

    final added = withoutVans(await allStores())
        .firstWhere((s) => s.name == 'Second Branch');
    expect(added.kind, kStoreKindStore);
    expect(isVanStore(added), isFalse);
    expect(added.location, '12 Market Road');

    // Pin the NEW row's id specifically — the seeded 'Main Warehouse' already
    // put a stores:upsert on the queue, so a bare actionType check would pass
    // even if the screen enqueued nothing.
    final pending = await getPendingQueue(db);
    expect(
      pending
          .where((r) => r.actionType == 'stores:upsert')
          .map(decodePayload)
          .any((p) => p['id'] == added.id),
      isTrue,
    );
  });

  testWidgets('Add a van inserts a van location without disposing its fields',
      (tester) async {
    await pumpScreen(tester, ceoUserId);

    await addLocation(
      tester,
      openLabel: 'Add a van',
      submitLabel: 'Add van',
      name: 'Blue Hilux',
      note: 'ABC-123-XY',
    );

    // The regression guard: the old caller-owned-controller sheet threw here.
    expect(tester.takeException(), isNull);

    final vans = onlyVans(await allStores());
    expect(vans, hasLength(1));
    expect(vans.single.name, 'Blue Hilux');
    expect(vans.single.kind, kStoreKindVan);
    expect(vans.single.location, 'ABC-123-XY');
  });

  testWidgets('a van never lands in the store list, and vice versa',
      (tester) async {
    await pumpScreen(tester, ceoUserId);

    await addLocation(
      tester,
      openLabel: 'Add a van',
      submitLabel: 'Add van',
      name: 'Blue Hilux',
    );
    await addLocation(
      tester,
      openLabel: 'Add a store',
      submitLabel: 'Add store',
      name: 'Second Branch',
    );

    expect(tester.takeException(), isNull);
    final stores = await allStores();
    expect(
      withoutVans(stores).map((s) => s.name),
      containsAll(['Main Warehouse', 'Second Branch']),
    );
    expect(onlyVans(stores).map((s) => s.name), ['Blue Hilux']);
  });

  testWidgets('an empty name is rejected — no row, sheet stays open',
      (tester) async {
    await pumpScreen(tester, ceoUserId);
    final before = (await allStores()).length;

    await tester.tap(find.text('Add a store'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add store'));
    await tester.pumpAndSettle();

    expect(find.text('Give the store a name'), findsOneWidget);
    expect(await allStores(), hasLength(before));
  });

  testWidgets('dismissing the sheet adds nothing and disposes cleanly',
      (tester) async {
    await pumpScreen(tester, ceoUserId);
    final before = (await allStores()).length;

    await tester.tap(find.text('Add a store'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Abandoned');
    // Barrier tap = the caller gets null back, so nothing is created.
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(await allStores(), hasLength(before));
  });

  testWidgets('the retired "coming in a future update" copy is gone',
      (tester) async {
    await pumpScreen(tester, ceoUserId);

    expect(
      find.textContaining('coming in a future update'),
      findsNothing,
    );
    expect(find.text('Add a store'), findsOneWidget);
  });

  testWidgets('a cashier holding neither gate sees no access', (tester) async {
    await pumpScreen(tester, cashierUserId);

    expect(find.text('Add a store'), findsNothing);
    expect(find.text('Add a van'), findsNothing);
  });
}
