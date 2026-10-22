// Visual goldens for the CEO sign-up restyle (D2 PR 1, #463), one per step.
// Every step: 390x844 and 844x390 (24dp status bar + 48dp side inset), light
// and dark. The first step also at 800x1280 and 1280x800. PNGs live in
// test/redesign/goldens/. Regenerate with:
//
//     flutter test --update-goldens test/redesign/ceo_sign_up_golden_test.dart
//
// Also checks that no step overflows with the keyboard up (sideways phone and
// 360dp at text scale 1.3). Steps are reached through the screen's own
// `initialStep` seam; nothing here changes onboarding behaviour.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/industry/industry.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/auth/screens/ceo_sign_up_screen.dart';

import '../helpers/screen_harness.dart';

const _connectivityChannel = MethodChannel(
  'dev.fluttercommunity.plus/connectivity',
);

/// (golden name, initialStep, verifiedEmail?, taps to reach the state)
const _steps = <(String, int, String?)>[
  ('business_name', 0, 'ceo@example.com'),
  ('business_type', 1, 'ceo@example.com'),
  ('contact', 2, 'ceo@example.com'),
  ('full_name', 3, 'ceo@example.com'),
  ('email', 4, null),
  ('otp', 5, null),
  ('create_pin', 6, 'ceo@example.com'),
  ('confirm_pin', 7, 'ceo@example.com'),
  ('ready', 8, 'ceo@example.com'),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _connectivityChannel,
          (call) async => call.method == 'check' ? <String>['wifi'] : null,
        );
  });

  const phoneSizes = <String, (Size, EdgeInsets)>{
    '390x844': (Size(390, 844), EdgeInsets.zero),
    '844x390': (Size(844, 390), EdgeInsets.only(top: 24, right: 48)),
  };
  const allSizes = <String, (Size, EdgeInsets)>{
    ...phoneSizes,
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

  Future<void> pumpStep(
    WidgetTester tester, {
    required int step,
    required String? verifiedEmail,
    required Size size,
    required EdgeInsets padding,
    required Brightness brightness,
    EdgeInsets viewInsets = EdgeInsets.zero,
    TextScaler? textScaler,
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
      viewInsets: viewInsets,
      bottomNavHeight: 0,
      textScaler: textScaler,
      theme: brightness == Brightness.light
          ? AppTheme.light()
          : AppTheme.dark(),
      screen: CeoSignUpScreen(verifiedEmail: verifiedEmail, initialStep: step),
      settle: false,
    );
    // Fixed durations only: the OTP row's 350ms focus timer and the 300ms
    // step cross-fade elapse; nothing repeating is left running.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));
  }

  for (final (name, step, email) in _steps) {
    final sizes = step == 0 ? allSizes : phoneSizes;
    for (final entry in sizes.entries) {
      final (size, padding) = entry.value;
      for (final brightness in [Brightness.light, Brightness.dark]) {
        final themeKey = brightness == Brightness.light ? 'light' : 'dark';
        testWidgets('CEO sign-up $name golden (${entry.key}, $themeKey)', (
          tester,
        ) async {
          await pumpStep(
            tester,
            step: step,
            verifiedEmail: email,
            size: size,
            padding: padding,
            brightness: brightness,
          );
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byType(CeoSignUpScreen),
            matchesGoldenFile(
              'goldens/ceo_sign_up_${name}_${entry.key}_$themeKey.png',
            ),
          );
        });
      }
    }
  }

  // The business-type step with a crate business chosen: shows the
  // crate-tracking toggle under the cards.
  for (final entry in phoneSizes.entries) {
    final (size, padding) = entry.value;
    for (final brightness in [Brightness.light, Brightness.dark]) {
      final themeKey = brightness == Brightness.light ? 'light' : 'dark';
      testWidgets('CEO sign-up business_type_crates golden '
          '(${entry.key}, $themeKey)', (tester) async {
        await pumpStep(
          tester,
          step: 1,
          verifiedEmail: 'ceo@example.com',
          size: size,
          padding: padding,
          brightness: brightness,
        );
        final first = Industry.selectableCatalogue.firstWhere(
          (t) => !t.comingSoon,
        );
        await tester.tap(find.text(first.label));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(CeoSignUpScreen),
          matchesGoldenFile(
            'goldens/ceo_sign_up_business_type_crates_${entry.key}_$themeKey.png',
          ),
        );
      });
    }
  }

  // No overflow with the keyboard up, on every step.
  for (final (name, step, email) in _steps) {
    testWidgets('CEO sign-up $name: no overflow, keyboard up sideways', (
      tester,
    ) async {
      await pumpStep(
        tester,
        step: step,
        verifiedEmail: email,
        size: const Size(844, 390),
        padding: const EdgeInsets.only(top: 24, right: 48),
        brightness: Brightness.light,
        viewInsets: const EdgeInsets.only(bottom: 200),
      );
      expect(tester.takeException(), isNull);
    });
    testWidgets('CEO sign-up $name: no overflow at 360dp, text 1.3', (
      tester,
    ) async {
      await pumpStep(
        tester,
        step: step,
        verifiedEmail: email,
        size: const Size(360, 640),
        padding: const EdgeInsets.only(top: 24, bottom: 24),
        brightness: Brightness.dark,
        viewInsets: const EdgeInsets.only(bottom: 280),
        textScaler: const TextScaler.linear(1.3),
      );
      expect(tester.takeException(), isNull);
    });
  }
}
