// Visual goldens for Store Details, its Transfer hub and the Dispatch dialog
// (#441, PRD #346 Wave 2 C, PR 2). No mockup: built from the shared parts and
// the Wave 1 patterns.
//
// - `store_details_*`: 390x844 (gesture nav), 844x390 with a 24dp status bar
//   and 3-button navigation on the right, 800x1280 and 1280x800, light + dark.
//   `store_details_hub_*`: the same screen scrolled to the Transfer hub.
// - `store_details_restricted_*`: the browse-only view at 390x844 / 1280x800.
// - `dispatch_dialog_*`: 390x844 and 844x390 with insets.
//
// Sample data only; transfer dates are fixed. Regenerate with:
//
//     flutter test --update-goldens test/redesign/store_details_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/stores/screens/store_details_screen.dart';

import '../helpers/screen_harness.dart';
import '../stores/store_details_fixture.dart';

const _grants = {
  'stores.request_transfer',
  'stores.dispatch_transfer',
  'stores.receive_transfer',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 3,
      businessName: 'Stallion Global',
    );
    await seedStoreDetails(env);
    for (var i = 0; i < 8; i++) {
      await env.db.notificationsDao.create('info', 'Notification $i');
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

  Future<void> pumpDetails(
    WidgetTester tester, {
    required Size size,
    required FakeViewPadding insets,
    required ThemeData theme,
    Set<String> grants = _grants,
    bool restricted = false,
  }) async {
    setInsets(tester, insets);
    final store = (await env.db.storesDao.getStore(env.storeId))!;
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
      screen: StoreDetailsScreen(store: store),
      bottomNavHeight: 0,
      grantedKeys: grants,
      roleRank: restricted ? GateTier.cashier : GateTier.ceo,
      roleSlug: restricted ? 'cashier' : 'ceo',
      roleName: restricted ? 'cashier' : 'ceo',
      theme: theme,
      overrides: [
        currentBusinessNameProvider.overrideWithValue('Stallion Global'),
      ],
      settle: false,
    );
    await deliver(tester);
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
      testWidgets('store details $sizeName $themeName', (tester) async {
        await pumpDetails(tester, size: size, insets: insets, theme: theme);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(StoreDetailsScreen),
          matchesGoldenFile('goldens/store_details_${sizeName}_$themeName.png'),
        );
        await disposeScreen(tester);
      });

      testWidgets('store details hub $sizeName $themeName', (tester) async {
        await pumpDetails(tester, size: size, insets: insets, theme: theme);
        await tester.drag(
          find.byType(Scrollable).first,
          const Offset(0, -4000),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(StoreDetailsScreen),
          matchesGoldenFile(
            'goldens/store_details_hub_${sizeName}_$themeName.png',
          ),
        );
        await disposeScreen(tester);
      });
    }

    for (final (sizeName, size, insets) in const [
      ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
      ('1280x800', Size(1280, 800), FakeViewPadding()),
    ]) {
      testWidgets('store details restricted $sizeName $themeName', (
        tester,
      ) async {
        await pumpDetails(
          tester,
          size: size,
          insets: insets,
          theme: theme,
          grants: const {'stores.request_transfer'},
          restricted: true,
        );
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(StoreDetailsScreen),
          matchesGoldenFile(
            'goldens/store_details_restricted_${sizeName}_$themeName.png',
          ),
        );
        await disposeScreen(tester);
      });
    }

    for (final (sizeName, size, insets) in const [
      ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
      ('844x390', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
    ]) {
      testWidgets('dispatch dialog $sizeName $themeName', (tester) async {
        await pumpDetails(tester, size: size, insets: insets, theme: theme);
        await tester.scrollUntilVisible(
          find.text('Accept & Dispatch'),
          100,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Accept & Dispatch'));
        await tester.pumpAndSettle();
        expect(find.text('Dispatch quantity'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(Navigator).first,
          matchesGoldenFile(
            'goldens/dispatch_dialog_${sizeName}_$themeName.png',
          ),
        );
        await disposeScreen(tester);
      });
    }
  }
}
