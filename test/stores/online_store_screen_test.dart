// #423: Settings → Online store hub, the per-store online page, the Store
// Details online card and the first-run New Store sheet's area question.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/settings/online_store_detail_screen.dart';
import 'package:reebaplus_pos/core/settings/online_store_settings_screen.dart';
import 'package:reebaplus_pos/features/stores/screens/stores_screen.dart';

import '../helpers/screen_harness.dart';

const _grants = {'stores.online_ordering'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late String vanId;

  setUp(() async {
    env = await setupScreenTestEnvironment(productCount: 1, businessName: 'Stallion Global');
    final db = env.db;
    await db.customStatement(
      "UPDATE stores SET name = 'Abuja HQ' WHERE id = '${env.storeId}'",
    );
    env.db.userIdResolver = () => 'test-user-id';
    // Store writes stamp the signed-in user on their activity log row.
    await db.into(db.users).insert(UsersCompanion.insert(
      id: const Value('test-user-id'), businessId: env.businessId,
      name: 'Test Admin', pin: '0000'));
    vanId = UuidV7.generate();
    await db.into(db.stores).insert(StoresCompanion.insert(
      id: Value(vanId), businessId: env.businessId, name: 'Van One',
      kind: const Value(kStoreKindVan)));
  });

  tearDown(() => env.dispose());

  Future<void> deliver(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> pump(WidgetTester tester, Widget screen,
      {Set<String> grants = _grants, int rank = GateTier.ceo,
      Size size = const Size(390, 844)}) async {
    await pumpScreen(tester, env: env, size: size, screen: screen,
        bottomNavHeight: 0, grantedKeys: grants, roleRank: rank, settle: false);
    await deliver(tester);
  }

  testWidgets('hub lists stores with their online status and never vans', (tester) async {
    await pump(tester, const OnlineStoreSettingsScreen());
    expect(find.text('Abuja HQ'), findsOneWidget);
    expect(find.text('Van One'), findsNothing);
    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Area not set'), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('hub shows "Business · LGA" and Online once switched on', (tester) async {
    await env.db.storesDao.setStoreArea(
        storeId: env.storeId, country: 'Nigeria', state: 'Nasarawa', lga: 'Lafia');
    await env.db.storesDao.setOnlineOrdering(storeId: env.storeId, enabled: true);
    await pump(tester, const OnlineStoreSettingsScreen());
    expect(find.text('Online'), findsOneWidget);
    expect(find.text('Stallion Global · Lafia'), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('hub counts in-stock products with listing gaps (#475)', (tester) async {
    await env.db.customStatement(
        "UPDATE inventory SET quantity = 5 WHERE store_id = '${env.storeId}'");
    await pump(tester, const OnlineStoreSettingsScreen(),
        grants: const {'stores.online_ordering', 'products.manage_listing'});
    expect(find.byKey(ValueKey('store-gaps-${env.storeId}')), findsOneWidget);
    expect(find.text('1 product missing a photo'), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('hub gap counts need the listing grant (#475)', (tester) async {
    await env.db.customStatement(
        "UPDATE inventory SET quantity = 5 WHERE store_id = '${env.storeId}'");
    await pump(tester, const OnlineStoreSettingsScreen());
    expect(find.byKey(ValueKey('store-gaps-${env.storeId}')), findsNothing);
    await disposeScreen(tester);
  });

  const listingGrants = {'stores.online_ordering', 'products.manage_listing'};

  testWidgets('"Show all products online" lists every hidden product (#421)',
      (tester) async {
    await env.db.customStatement('UPDATE products SET show_online = 0');
    await env.db.delete(env.db.syncQueue).go();
    await pump(tester, const OnlineStoreSettingsScreen(), grants: listingGrants);
    final tile = find.byKey(const Key('all-products-online-switch'));
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    expect(find.text('1 of 1 products are hidden from shoppers.'), findsOneWidget);
    await tester.tap(tile);
    await deliver(tester);
    final rows = await env.db.select(env.db.products).get();
    expect(rows.every((p) => p.showOnline), isTrue);
    expect(await env.db.select(env.db.syncQueue).get(), isNotEmpty);
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
    await disposeScreen(tester);
  });

  testWidgets('turning it off asks first, then hides every product (#421)',
      (tester) async {
    await pump(tester, const OnlineStoreSettingsScreen(), grants: listingGrants);
    await tester.tap(find.byKey(const Key('all-products-online-switch')));
    await deliver(tester);
    expect(find.text('Hide all products?'), findsOneWidget);
    await tester.tap(find.text('Hide all'));
    await deliver(tester);
    final rows = await env.db.select(env.db.products).get();
    expect(rows.any((p) => p.showOnline), isFalse);
    await disposeScreen(tester);
  });

  testWidgets('the all-products switch needs the listing grant (#421)', (tester) async {
    await pump(tester, const OnlineStoreSettingsScreen());
    expect(find.byKey(const Key('all-products-online-switch')), findsNothing);
    await disposeScreen(tester);
  });

  testWidgets('without the permission the hub and page show no access', (tester) async {
    await pump(tester, const OnlineStoreSettingsScreen(),
        grants: const {'settings.manage', 'stores.manage'}, rank: GateTier.manager);
    expect(find.byKey(const Key('online-store-no-access')), findsOneWidget);
    expect(find.text('Abuja HQ'), findsNothing);
    await disposeScreen(tester);
  });

  testWidgets('switch disabled with a clear prompt until state + LGA are set',
      (tester) async {
    await pump(tester, OnlineStoreDetailScreen(storeId: env.storeId));
    final tile = tester.widget<SwitchListTile>(find.byKey(const Key('online-store-switch')));
    expect(tile.onChanged, isNull);
    expect(find.byKey(const Key('online-store-blocker')), findsOneWidget);
    expect(find.textContaining('state and local government area'), findsWidgets);
    await disposeScreen(tester);
  });

  testWidgets('with an area the switch turns the store online', (tester) async {
    await env.db.storesDao.setStoreArea(
        storeId: env.storeId, country: 'Nigeria', state: 'Lagos', lga: 'Ikeja');
    await pump(tester, OnlineStoreDetailScreen(storeId: env.storeId));
    expect(find.text('Ikeja, Lagos'), findsWidgets);
    expect(find.byKey(const Key('online-store-blocker')), findsNothing);
    await tester.tap(find.byKey(const Key('online-store-switch')));
    await deliver(tester);
    final store = await env.db.storesDao.getStore(env.storeId);
    expect(store!.onlineOrderingEnabled, isTrue);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await disposeScreen(tester);
  });

  testWidgets('a van page refuses online ordering', (tester) async {
    await pump(tester, OnlineStoreDetailScreen(storeId: vanId));
    expect(find.byKey(const Key('online-store-van')), findsOneWidget);
    expect(find.byKey(const Key('online-store-switch')), findsNothing);
    await disposeScreen(tester);
  });

  testWidgets('phone and note save from the page', (tester) async {
    await pump(tester, OnlineStoreDetailScreen(storeId: env.storeId));
    await tester.enterText(find.byKey(const Key('online-store-phone')), '08030000000');
    await tester.enterText(find.byKey(const Key('online-store-note')), 'Delivery Mon-Sat');
    await tester.ensureVisible(find.byKey(const Key('online-store-save-details')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('online-store-save-details')));
    await deliver(tester);
    final store = await env.db.storesDao.getStore(env.storeId);
    expect(store!.phone, '08030000000');
    expect(store.onlineNote, 'Delivery Mon-Sat');
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await disposeScreen(tester);
  });

  for (final (name, size, keyboard) in const <(String, Size, double)>[
    ('390x844', Size(390, 844), 340),
    ('844x390', Size(844, 390), 200),
  ]) {
    testWidgets('keyboard up: the note box and Save stay reachable $name', (tester) async {
      await pumpScreen(tester, env: env, size: size, followView: true,
          screen: OnlineStoreDetailScreen(storeId: env.storeId),
          bottomNavHeight: 0, grantedKeys: _grants, roleRank: GateTier.ceo,
          textScaler: const TextScaler.linear(1.15), settle: false);
      await deliver(tester);
      await tester.ensureVisible(find.byKey(const Key('online-store-note')));
      await tester.tap(find.byKey(const Key('online-store-note')));
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      await tester.pumpAndSettle();
      expectNoOverflow(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('online-store-save-details')), 200,
        scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('online-store-save-details')).hitTestable(),
          findsOneWidget);
      tester.view.resetViewInsets();
      await disposeScreen(tester);
    });
  }

  testWidgets('first-run New Store sheet asks for state + LGA and requires it',
      (tester) async {
    await pump(tester, const StoresScreen(), grants: const {'stores.manage'});
    await tester.tap(find.text('Add Store').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('new-store-area')), findsOneWidget);
    expect(find.text('State and local government area'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).at(0), 'Kano Depot');
    await tester.enterText(find.byType(TextFormField).at(1), '9 Zoo Road');
    await tester.ensureVisible(find.text('Save Store'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save Store'));
    await tester.pumpAndSettle();
    expect(find.text('Choose the store\'s state and local government area'), findsOneWidget);
    final stores = await env.db.storesDao.getActiveStores();
    expect(stores.where((s) => s.name == 'Kano Depot'), isEmpty);

    await tester.tap(find.byKey(const ValueKey<String>('new-store-area')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('area-search-state')), 'Kano');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('area-option-Kano')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('area-search-lga')), 'Nasarawa');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('area-option-Nasarawa')));
    await tester.pumpAndSettle();
    expect(find.text('Nasarawa, Kano'), findsOneWidget);
    await tester.ensureVisible(find.text('Save Store'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save Store'));
    await tester.pumpAndSettle();
    await deliver(tester);
    final created = (await env.db.storesDao.getActiveStores())
        .singleWhere((s) => s.name == 'Kano Depot');
    expect(created.state, 'Kano');
    expect(created.lga, 'Nasarawa');
    expect((await env.db.storesDao.getDeliveryAreas(created.id)).single.lga, 'Nasarawa');
    await disposeScreen(tester);
  });
}
