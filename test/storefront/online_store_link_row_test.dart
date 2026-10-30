// #439: the per-store share link row on the online store page.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/features/settings/screens/online_store_detail_screen.dart';
import 'package:reebaplus_pos/core/storefront/store_share_link.dart';

import '../helpers/screen_harness.dart';
import 'package:reebaplus_pos/core/storefront/online_ordering_switch.dart';

const _grants = {'stores.online_ordering'};

void main() {
  // Online ordering ships switched off; these tests cover it switched on.
  setUpAll(() => debugOverrideOnlineOrderingEnabled(true));
  tearDownAll(() => debugOverrideOnlineOrderingEnabled(null));
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

  testWidgets('link row is hidden while the store is offline', (tester) async {
    await pump(tester, OnlineStoreDetailScreen(storeId: env.storeId));
    expect(find.byKey(const Key('online-store-link')), findsNothing);
    await disposeScreen(tester);
  });

  testWidgets('link row shows when online; Copy writes the link to the clipboard',
      (tester) async {
    await env.db.storesDao.setStoreArea(
        storeId: env.storeId, country: 'Nigeria', state: 'Nasarawa', lga: 'Lafia');
    await env.db.storesDao.setOnlineOrdering(storeId: env.storeId, enabled: true);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    tester.platformDispatcher.textScaleFactorTestValue = 1.15;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pump(tester, OnlineStoreDetailScreen(storeId: env.storeId), size: const Size(320, 640));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('online-store-link')), findsOneWidget);
    expect(find.text(storeShareLink(env.storeId)), findsOneWidget);
    await tester.tap(find.byKey(const Key('online-store-link-copy')));
    await tester.pump();
    expect(copied, storeShareLink(env.storeId));
    await tester.pump(const Duration(seconds: 5));
    await disposeScreen(tester);
  });
}
