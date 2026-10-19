// Visual goldens for the Stores list, its Add / Edit sheets and CEO Settings >
// Stores (#441, PRD #346 Wave 2 C). No mockup: built from the shared parts and
// the Wave 1 patterns (CEO Settings' top bar and 720dp cap, the customer
// sheets' frame).
//
// - `stores_*` / `stores_settings_*`: 390x844 (gesture nav), 844x390 with a
//   24dp status bar and 3-button navigation on the right, 800x1280 and
//   1280x800, light + dark.
// - `add_store_sheet_*` / `edit_store_sheet_*` / `stores_add_location_sheet_*`:
//   390x844 and 844x390 with insets, opened on a tab-like nested navigator.
//
// Sample data only: business "Stallion Global", store "Abuja HQ". Regenerate:
//
//     flutter test --update-goldens test/redesign/stores_golden_test.dart

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/settings/stores_settings_screen.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/stores/screens/stores_screen.dart';
import 'package:reebaplus_pos/features/stores/widgets/stores_parts.dart';

import '../helpers/screen_harness.dart';

const _grants = {'stores.manage'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 3,
      businessName: 'Stallion Global',
    );
    final db = env.db;
    await db.customStatement(
      "UPDATE stores SET name = 'Abuja HQ', "
      "location = '14 Wuse Road, Nigeria' WHERE id = '${env.storeId}'",
    );
    for (final (name, location, qty) in const [
      ('Lagos Island Annex', '3 Marina Street, Lagos, Nigeria', 24),
      ('Kano Depot With A Rather Long Name', '9 Zoo Road, Kano, Nigeria', 0),
    ]) {
      final id = UuidV7.generate();
      await db
          .into(db.stores)
          .insert(
            StoresCompanion.insert(
              id: Value(id),
              businessId: env.businessId,
              name: name,
              location: Value(location),
            ),
          );
      if (qty > 0) {
        for (final p in env.products) {
          await db
              .into(db.inventory)
              .insert(
                InventoryCompanion.insert(
                  id: Value(UuidV7.generate()),
                  businessId: env.businessId,
                  storeId: id,
                  productId: p.id,
                  quantity: Value(qty),
                ),
              );
        }
      }
    }
    for (var i = 0; i < 8; i++) {
      await db.notificationsDao.create('info', 'Notification $i');
    }
  });

  tearDown(() => env.dispose());

  setUpAll(() => WidgetsApp.debugAllowBannerOverride = false);
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  Future<void> deliver(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  void setInsets(WidgetTester tester, FakeViewPadding insets) {
    tester.view.padding = insets;
    tester.view.viewPadding = insets;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
  }

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    final theme = brightness == Brightness.light
        ? AppTheme.light()
        : AppTheme.dark();

    for (final (sizeName, size, insets) in const [
      ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
      ('844x390_insets', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
      ('800x1280', Size(800, 1280), FakeViewPadding()),
      ('1280x800', Size(1280, 800), FakeViewPadding()),
    ]) {
      for (final (name, screen) in const <(String, Widget)>[
        ('stores', StoresScreen()),
        ('stores_settings', StoresSettingsScreen()),
      ]) {
        testWidgets('$name $sizeName $themeName', (tester) async {
          setInsets(tester, insets);
          await pumpScreen(
            tester,
            env: env,
            size: size,
            padding: EdgeInsets.fromLTRB(
              insets.left,
              insets.top,
              insets.right,
              insets.bottom,
            ),
            screen: screen,
            bottomNavHeight: size.width >= 600 ? kBottomNavBodyHeight : 0,
            grantedKeys: _grants,
            roleRank: GateTier.ceo,
            theme: theme,
            overrides: [
              currentBusinessNameProvider.overrideWithValue('Stallion Global'),
            ],
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

    for (final (sizeName, size, insets) in const [
      ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
      ('844x390', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
    ]) {
      for (final (name, opener, screen) in const <(String, String, Widget)>[
        ('add_store_sheet', 'Add Store', StoresScreen()),
        ('stores_add_location_sheet', 'Add a store', StoresSettingsScreen()),
      ]) {
        testWidgets('$name $sizeName $themeName', (tester) async {
          setInsets(tester, insets);
          await pumpScreen(
            tester,
            env: env,
            size: size,
            padding: EdgeInsets.fromLTRB(
              insets.left,
              insets.top,
              insets.right,
              insets.bottom,
            ),
            screen: screen,
            bottomNavHeight: 0,
            grantedKeys: _grants,
            roleRank: GateTier.ceo,
            theme: theme,
            settle: false,
          );
          await deliver(tester);
          await tester.ensureVisible(find.text(opener).first);
          await tester.pump();
          await tester.tap(find.text(opener).first);
          await tester.pumpAndSettle();
          await deliver(tester);
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byType(Navigator).first,
            matchesGoldenFile('goldens/${name}_${sizeName}_$themeName.png'),
          );
          await disposeScreen(tester);
        });
      }

      testWidgets('edit_store_sheet $sizeName $themeName', (tester) async {
        setInsets(tester, insets);
        await pumpScreen(
          tester,
          env: env,
          size: size,
          padding: EdgeInsets.fromLTRB(
            insets.left,
            insets.top,
            insets.right,
            insets.bottom,
          ),
          screen: const StoresScreen(),
          bottomNavHeight: 0,
          grantedKeys: _grants,
          roleRank: GateTier.ceo,
          theme: theme,
          settle: false,
        );
        await deliver(tester);
        await tester.tap(find.byKey(StoresKeys.edit(env.storeId)));
        await tester.pumpAndSettle();
        await deliver(tester);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(Navigator).first,
          matchesGoldenFile(
            'goldens/edit_store_sheet_${sizeName}_$themeName.png',
          ),
        );
        await disposeScreen(tester);
      });
    }
  }
}
