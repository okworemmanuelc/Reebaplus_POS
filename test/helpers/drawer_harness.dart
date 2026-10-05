// Pumps the real AppDrawer, open, for the drawer tests and goldens (#368).
//
// The drawer sits in a plain Scaffold over the page background (the same
// place MainLayout's Scaffold puts it at 600dp+), so its goldens do not change
// when another Wave 1 agent restyles the screen behind it.

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/features/subscription/subscription_access.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer.dart';

import 'screen_harness.dart';

/// The CEO's sidebar grants (migration 0043) plus Sync Issues access.
const Set<String> kDrawerCeoGrants = {
  'sales.make',
  'stock.view',
  'customers.add',
  'suppliers.manage',
  'reports.see_expenses',
  'expenses.create',
  'settings.manage',
  'stores.manage',
  'activity_logs.view',
  'staff.invite',
  'sync.view',
};

/// The mockup's sample data (`phone-drawer-dark.png`).
const String kDrawerSampleBusiness = 'Stallion Global';
const String kDrawerSampleUser = 'Emmanuel Okwor';
const String kDrawerSampleStore = 'Abuja HQ';

/// Adds a second store named [name] and makes it the active one, so the
/// store picker shows (it needs two stores to choose from).
Future<StoreData> addSecondStore(
  ScreenTestEnvironment env, {
  String name = kDrawerSampleStore,
}) async {
  final id = UuidV7.generate();
  await env.db
      .into(env.db.stores)
      .insert(
        StoresCompanion.insert(
          id: Value(id),
          businessId: env.businessId,
          name: name,
        ),
      );
  return (await env.db.storesDao.getStore(id))!;
}

/// Queues [count] unsynced records (failed ones when [failed]).
Future<void> queueSyncRecords(
  ScreenTestEnvironment env,
  int count, {
  bool failed = false,
}) async {
  for (var i = 0; i < count; i++) {
    await env.db
        .into(env.db.syncQueue)
        .insert(
          SyncQueueCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: env.businessId,
            actionType: 'products:upsert',
            payload: '{}',
            status: Value(failed ? 'failed' : 'pending'),
          ),
        );
  }
}

/// Pumps a Scaffold whose drawer is the real [AppDrawer] and opens it.
///
/// [padding] is both the MediaQuery padding and the view's padding (the
/// drawer's footer reads the raw view inset, `deviceBottomPadding`).
Future<BuildContext> pumpOpenDrawer(
  WidgetTester tester, {
  required ScreenTestEnvironment env,
  required Size size,
  EdgeInsets padding = kRealisticPhoneInsets,
  String activeRoute = 'pos',
  Set<String> grants = kDrawerCeoGrants,
  String roleSlug = 'ceo',
  String roleName = 'CEO',
  int roleRank = 4,
  SubscriptionAccess subscription = SubscriptionAccess.active,
  List<StoreData>? stores,
  String? activeStoreId,
  ThemeData? theme,
  TextScaler? textScaler,
}) async {
  tester.view.viewPadding = FakeViewPadding(
    left: padding.left,
    top: padding.top,
    right: padding.right,
    bottom: padding.bottom,
  );
  tester.view.padding = tester.view.viewPadding;
  addTearDown(tester.view.resetViewPadding);
  addTearDown(tester.view.resetPadding);

  final scaffoldKey = GlobalKey<ScaffoldState>();
  final context = await pumpScreen(
    tester,
    env: env,
    size: size,
    padding: padding,
    bottomNavHeight: 0,
    grantedKeys: grants,
    roleSlug: roleSlug,
    roleName: roleName,
    roleRank: roleRank,
    theme: theme,
    textScaler: textScaler,
    selectableStores: stores,
    settle: false,
    overrides: [
      currentBusinessNameProvider.overrideWithValue(kDrawerSampleBusiness),
      currentBusinessLogoPathProvider.overrideWith((ref) async => null),
      currentBusinessSubscriptionProvider.overrideWithValue(subscription),
    ],
    screen: Scaffold(
      key: scaffoldKey,
      drawer: AppDrawer(activeRoute: activeRoute),
      body: DrawerHost(
        child: Builder(
          builder: (context) => DecoratedBox(
            decoration: AppDecorations.pageBackground(context),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    ),
  );

  final container = ProviderScope.containerOf(context, listen: false);
  final auth = container.read(authProvider);
  auth.value = auth.value!.copyWith(name: kDrawerSampleUser);
  if (activeStoreId != null) {
    NavigationService().setLockedStore(activeStoreId, explicit: true);
  }

  scaffoldKey.currentState!.openDrawer();
  // Let the drawer slide in and the Drift streams deliver. Bounded, so a
  // stream that never settles cannot hang the test.
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }
  return context;
}
