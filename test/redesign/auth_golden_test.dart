// Visual goldens for Auth PR 1 screens (Welcome, Coming Soon):
// 390x844, 844x390 (24dp status bar + 48dp side inset), 800x1280, 1280x800,
// light and dark. The PNGs live in test/redesign/goldens/. Regenerate with:
//
//     flutter test --update-goldens test/redesign/auth_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/auth/screens/coming_soon_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/welcome_screen.dart';

import '../helpers/screen_harness.dart';

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
      settle: true,
    );

    await expectLater(
      find.byType(type),
      matchesGoldenFile('goldens/$name.png'),
    );
  }

  for (final entry in sizes.entries) {
    final sizeKey = entry.key;
    final (size, padding) = entry.value;

    for (final brightness in [Brightness.light, Brightness.dark]) {
      final themeKey = brightness == Brightness.light ? 'light' : 'dark';

      testWidgets(
        'Welcome screen golden ($sizeKey, $themeKey)',
        (tester) async {
          await golden(
            tester,
            screen: const WelcomeScreen(),
            type: WelcomeScreen,
            size: size,
            padding: padding,
            brightness: brightness,
            name: 'welcome_${sizeKey}_$themeKey',
          );
        },
      );

      testWidgets(
        'Coming soon screen golden ($sizeKey, $themeKey)',
        (tester) async {
          await golden(
            tester,
            screen: const ComingSoonScreen(
              title: 'Terms of Service',
              message: 'Terms of Service — coming soon.',
            ),
            type: ComingSoonScreen,
            size: size,
            padding: padding,
            brightness: brightness,
            name: 'coming_soon_${sizeKey}_$themeKey',
          );
        },
      );
    }
  }
}
