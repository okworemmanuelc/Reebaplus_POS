// Visual goldens for CEO Settings (#369, PRD #346 Wave 1), compared side by
// side with docs/redesign/mockups/phone-ceo-settings-light.png.
//
// The screen at the four reference sizes, light and dark (Blue Classic), with
// the mockup's sample data: business "Stallion Global", store "Abuja HQ",
// user "Emmanuel Okwor", PRO + CEO, 8 unread notifications. Plus a sideways
// phone with a 24dp status bar and 3-button navigation on the right. At
// 600dp+ the harness leaves the side rail's width blank on the left; only the
// screen is captured.
//
// The PNGs live in test/redesign/goldens/ — never test/golden/, which CI runs
// on Linux. Regenerate with:
//
//     flutter test --update-goldens test/redesign/settings_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/settings_screen.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/subscription/subscription_access.dart';

import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sizes = <String, Size>{
    '390x844': Size(390, 844),
    '844x390': Size(844, 390),
    '800x1280': Size(800, 1280),
    '1280x800': Size(1280, 800),
  };

  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
    );
    await env.db.customStatement(
      "UPDATE stores SET name = 'Abuja HQ' WHERE id = '${env.storeId}'",
    );
    for (var i = 0; i < 8; i++) {
      await env.db.notificationsDao.create('info', 'Notification $i');
    }
  });

  tearDown(() => env.dispose());

  Future<void> pumpGolden(
    WidgetTester tester, {
    required Brightness brightness,
    required Size size,
    required EdgeInsets padding,
    required String goldenName,
  }) async {
    final context = await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: padding,
      // Pushed over another page, as the drawer opens it, so the top bar
      // shows its back arrow.
      screen: Navigator(
        onGenerateInitialRoutes: (_, _) => [
          MaterialPageRoute<void>(builder: (_) => const SizedBox.shrink()),
          MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
        ],
      ),
      // A pushed page: no bottom bar under 600dp; the rail at 600dp+.
      bottomNavHeight: size.width >= 600 ? kBottomNavBodyHeight : 0,
      grantedKeys: const {'settings.manage', 'settings.delete_business'},
      theme: brightness == Brightness.light
          ? AppTheme.light()
          : AppTheme.dark(),
      overrides: [
        currentBusinessNameProvider.overrideWithValue('Stallion Global'),
        currentBusinessSubscriptionProvider.overrideWithValue(
          SubscriptionAccess.active,
        ),
        currentBusinessLogoPathProvider.overrideWith((ref) async => null),
      ],
      settle: false,
    );
    final container = ProviderScope.containerOf(context, listen: false);
    final auth = container.read(authProvider);
    auth.value = auth.value!.copyWith(name: 'Emmanuel Okwor');

    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }

    await expectLater(
      find.byType(SettingsScreen),
      matchesGoldenFile('goldens/$goldenName.png'),
    );
    await disposeScreen(tester);
  }

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    sizes.forEach((sizeName, size) {
      testWidgets(
        'ceo settings $sizeName $themeName',
        (tester) => pumpGolden(
          tester,
          brightness: brightness,
          size: size,
          padding: EdgeInsets.zero,
          goldenName: 'settings_ceo_${sizeName}_$themeName',
        ),
      );
    });
    testWidgets('ceo settings 844x390 with insets $themeName', (tester) async {
      tester.view.padding = const FakeViewPadding(top: 24, right: 48);
      tester.view.viewPadding = const FakeViewPadding(top: 24, right: 48);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      await pumpGolden(
        tester,
        brightness: brightness,
        size: const Size(844, 390),
        padding: const EdgeInsets.only(top: 24, right: 48),
        goldenName: 'settings_ceo_844x390_insets_$themeName',
      );
    });
  }
}
