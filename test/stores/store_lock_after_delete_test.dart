// store_lock_after_delete_test.dart
//
// #456: a device locked to a store that gets deleted (here, or on another
// device and then synced) must not keep selling / receiving against it. There
// is no extra read-side fallback: the deleted store drops out of
// allStoresProvider → selectableStoresProvider, and MainLayout's §12.1
// active-store default moves the lock to the first remaining store. While the
// store list is still loading (empty), the lock is left alone.

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/providers/first_run_tour_state.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/main_layout.dart';

import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const testPrefs = {
    'push_soft_ask_shown_v1': true,
    'pos_grid_columns': 2,
    'pos_is_list_view': false,
    'hint_pos_gestures': 2,
  };

  late ScreenTestEnvironment env;
  late String storeBId;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      sharedPreferences: testPrefs,
    );
    storeBId = UuidV7.generate();
    await env.db
        .into(env.db.stores)
        .insert(
          StoresCompanion.insert(
            id: Value(storeBId),
            businessId: env.businessId,
            name: 'Store B',
          ),
        );
    final nav = NavigationService();
    nav.resetNavigation();
    nav.beginSessionLanding();
  });

  tearDown(() async {
    NavigationService().resetNavigation();
    NavigationService().clearStoreLock();
    await env.dispose();
  });

  test('a soft-deleted store drops out of the selectable stores', () async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(env.db),
        currentBusinessIdProvider.overrideWithValue(env.businessId),
        canViewAllStoresProvider.overrideWithValue(true),
      ],
    );
    addTearDown(container.dispose);
    container.listen(allStoresProvider, (_, _) {});

    await container.read(allStoresProvider.future);
    expect(
      container.read(selectableStoresProvider).map((s) => s.id),
      containsAll([env.storeId, storeBId]),
    );

    await env.db.storesDao.softDeleteStore(storeBId);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final ids = container.read(selectableStoresProvider).map((s) => s.id);
    expect(ids, contains(env.storeId));
    expect(ids, isNot(contains(storeBId)));
  });

  Future<void> pumpMainLayout(
    WidgetTester tester, {
    required List<StoreData> selectable,
  }) async {
    await pumpScreen(
      tester,
      env: env,
      size: const Size(390, 844),
      screen: const MainLayout(),
      bottomNavHeight: 0,
      grantedKeys: const {'sales.make', 'stock.view'},
      overrides: [firstRunTourStopProvider.overrideWithValue(TourStop.none)],
      sharedPreferences: testPrefs,
      selectableStores: selectable,
      settle: false,
    );
    await tester.pump();
  }

  Future<void> pumpFrames(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets(
    'device locked to a store that is no longer active moves to a remaining store',
    (tester) async {
      // Store B was deleted (locally or via sync): it is no longer selectable.
      await pumpMainLayout(tester, selectable: [env.store]);
      final nav = NavigationService();

      nav.setLockedStore(storeBId);
      await pumpFrames(tester);

      expect(nav.lockedStoreId.value, env.storeId);
      expect(nav.allStoresChosen.value, isFalse);
    },
  );

  testWidgets(
    "the deleting device's silent clear lands on a remaining store, not All Stores",
    (tester) async {
      await pumpMainLayout(tester, selectable: [env.store]);
      final nav = NavigationService();

      // What StoresScreen does after deleting the locked store.
      nav.setLockedStore(null, explicit: false);
      await pumpFrames(tester);

      expect(nav.lockedStoreId.value, env.storeId);
    },
  );

  testWidgets('the lock is kept while the store list is still loading', (
    tester,
  ) async {
    await pumpMainLayout(tester, selectable: const []);
    final nav = NavigationService();

    nav.setLockedStore(storeBId);
    await pumpFrames(tester);

    expect(nav.lockedStoreId.value, storeBId);
  });
}
