// Visual goldens for the Subscription Locked and Thank You screens (Wave 2 B,
// #414): 390x844, 844x390 (24dp status bar + 48dp side inset), 800x1280 and
// 1280x800, light and dark. Fixed dates only (trial ended 30 Sep 2026, renews
// 15 Nov 2026). The PNGs live in test/redesign/goldens/. Regenerate with:
//
//     flutter test --update-goldens test/redesign/subscription_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/subscription/screens/subscription_locked_screen.dart';
import 'package:reebaplus_pos/features/subscription/subscription_access.dart';

import '../helpers/screen_harness.dart';
import '../subscription/subscription_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sizes = <String, (Size, EdgeInsets)>{
    '390x844': (Size(390, 844), EdgeInsets.zero),
    '844x390': (Size(844, 390), EdgeInsets.only(top: 24, right: 48)),
    '800x1280': (Size(800, 1280), EdgeInsets.zero),
    '1280x800': (Size(1280, 800), EdgeInsets.zero),
  };

  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
    );
    await seedSubscriptionBusiness(env);
  });
  tearDown(() => env.dispose());

  Future<void> golden(
    WidgetTester tester, {
    required Widget screen,
    required Type type,
    required Size size,
    required EdgeInsets padding,
    required Brightness brightness,
    required String name,
  }) async {
    if (padding != EdgeInsets.zero) {
      tester.view.padding = FakeViewPadding(
        top: padding.top,
        right: padding.right,
      );
      tester.view.viewPadding = FakeViewPadding(
        top: padding.top,
        right: padding.right,
      );
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
    }
    await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: padding,
      bottomNavHeight: 0,
      theme: brightness == Brightness.light
          ? AppTheme.light()
          : AppTheme.dark(),
      screen: screen,
      settle: false,
    );
    // Long enough for the Thank You entrance animation to finish; the pulse
    // ring loops, so it is frozen at a deterministic frame by the fixed pumps.
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
    await expectLater(
      find.byType(type),
      matchesGoldenFile('goldens/$name.png'),
    );
    await disposeScreen(tester);
  }

  for (final b in Brightness.values) {
    final theme = b == Brightness.light ? 'light' : 'dark';
    sizes.forEach((sizeName, spec) {
      final (size, padding) = spec;
      testWidgets('subscription locked $sizeName $theme', (tester) async {
        await golden(
          tester,
          screen: const SubscriptionLockedScreen(
            access: SubscriptionAccess.trialExpired,
          ),
          type: SubscriptionLockedScreen,
          size: size,
          padding: padding,
          brightness: b,
          name: 'subscription_locked_${sizeName}_$theme',
        );
      });
    });
  }
}
