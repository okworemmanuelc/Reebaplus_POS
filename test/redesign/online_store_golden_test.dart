// Visual goldens for Settings → Online store and one store's online page
// (#423). No Claude Design file was in the repo: built from the Stores /
// Settings parts and ui-context tokens.
//
// 390x844 (gesture nav), 844x390 with a 24dp status bar and 3-button nav on
// the right, and 1280x800; light + dark. Sample data only: business
// "Stallion Global". Regenerate:
//
//     flutter test --update-goldens test/redesign/online_store_golden_test.dart

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/features/settings/screens/online_store_detail_screen.dart';
import 'package:reebaplus_pos/features/settings/screens/online_store_settings_screen.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';

import '../helpers/screen_harness.dart';
import 'package:reebaplus_pos/core/storefront/online_ordering_switch.dart';

const _grants = {'stores.online_ordering'};

void main() {
  // Online ordering ships switched off; these tests cover it switched on.
  setUpAll(() => debugOverrideOnlineOrderingEnabled(true));
  tearDownAll(() => debugOverrideOnlineOrderingEnabled(null));
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(productCount: 1, businessName: 'Stallion Global',
        storeId: '01a18610-0000-7000-8000-000000000001');
    final db = env.db;
    await db.customStatement(
      "UPDATE stores SET name = 'Abuja HQ' WHERE id = '${env.storeId}'",
    );
    await db.storesDao.setStoreArea(
        storeId: env.storeId, country: 'Nigeria', state: 'Nasarawa', lga: 'Lafia');
    await db.storesDao.addDeliveryArea(
        storeId: env.storeId, country: 'Nigeria', state: 'Federal Capital Territory');
    await db.storesDao.setStoreContact(
        storeId: env.storeId, phone: '0803 000 0000',
        onlineNote: 'Delivery fee 1,000 within Lafia. Pickup Monday to Saturday.');
    await db.storesDao.setOnlineOrdering(storeId: env.storeId, enabled: true);
    await db.into(db.stores).insert(StoresCompanion.insert(
      id: Value(UuidV7.generate()), businessId: env.businessId,
      name: 'Kano Depot With A Rather Long Name'));
  });

  tearDown(() => env.dispose());

  setUpAll(() => WidgetsApp.debugAllowBannerOverride = false);
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  Future<void> deliver(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    final theme = brightness == Brightness.light ? AppTheme.light() : AppTheme.dark();

    for (final (sizeName, size, insets) in const [
      ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
      ('844x390_insets', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
      ('1280x800', Size(1280, 800), FakeViewPadding()),
    ]) {
      for (final name in const ['online_store_hub', 'online_store_detail']) {
        testWidgets('$name $sizeName $themeName', (tester) async {
          tester.view.padding = insets;
          tester.view.viewPadding = insets;
          addTearDown(tester.view.resetPadding);
          addTearDown(tester.view.resetViewPadding);
          final Widget screen = name == 'online_store_hub'
              ? const OnlineStoreSettingsScreen()
              : OnlineStoreDetailScreen(storeId: env.storeId);
          await pumpScreen(
            tester,
            env: env,
            size: size,
            padding: EdgeInsets.fromLTRB(
                insets.left, insets.top, insets.right, insets.bottom),
            screen: screen,
            bottomNavHeight: size.width >= 600 ? kBottomNavBodyHeight : 0,
            grantedKeys: _grants,
            roleRank: GateTier.ceo,
            theme: theme,
            settle: false,
          );
          await deliver(tester);
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byType(screen.runtimeType),
            matchesGoldenFile('goldens/${name}_${sizeName}_$themeName.png'),
          );
          await disposeScreen(tester);
        });
      }
    }
  }
}
