// Visual goldens for the staff sign-up restyle (D2 PR 2, #463), one per step.
// Every step: 390x844 and 844x390 (24dp status bar + 48dp side inset), light
// and dark. The first step also at 800x1280 and 1280x800. PNGs live in
// test/redesign/goldens/. Regenerate with:
//
//     flutter test --update-goldens test/redesign/staff_sign_up_golden_test.dart
//
// Also checks that no step overflows with the keyboard up (sideways phone and
// 360dp at text scale 1.3). Steps are reached through the screen's own
// `initialStep` seam; nothing here changes onboarding behaviour.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/auth/screens/staff_sign_up_screen.dart';

import '../helpers/screen_harness.dart';

const _connectivityChannel = MethodChannel(
  'dev.fluttercommunity.plus/connectivity',
);

/// (golden name, initialStep)
const _steps = <(String, int)>[
  ('invite_code', 0),
  ('email', 1),
  ('otp', 2),
  ('full_name', 3),
  ('phone', 4),
  ('address', 5),
  ('create_pin', 6),
  ('confirm_pin', 7),
  ('welcome', 8),
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
    WidgetsApp.debugAllowBannerOverride = false;
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
    );
  });
  tearDown(() {
    WidgetsApp.debugAllowBannerOverride = true;
    return env.dispose();
  });

  Future<void> pumpStep(
    WidgetTester tester, {
    required int step,
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
      overrides: [
        currentBusinessNameProvider.overrideWithValue('Stallion Global'),
      ],
      screen: StaffSignUpScreen(initialStep: step),
      settle: false,
    );
    // Fixed durations only: the OTP row's 350ms focus timer and the 300ms
    // step cross-fade elapse; nothing repeating is left running.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));
  }

  for (final (name, step) in _steps) {
    final sizes = step == 0 ? allSizes : phoneSizes;
    for (final entry in sizes.entries) {
      final (size, padding) = entry.value;
      for (final brightness in [Brightness.light, Brightness.dark]) {
        final themeKey = brightness == Brightness.light ? 'light' : 'dark';
        testWidgets('Staff sign-up $name golden (${entry.key}, $themeKey)', (
          tester,
        ) async {
          await pumpStep(
            tester,
            step: step,
            size: size,
            padding: padding,
            brightness: brightness,
          );
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byType(StaffSignUpScreen),
            matchesGoldenFile(
              'goldens/staff_sign_up_${name}_${entry.key}_$themeKey.png',
            ),
          );
        });
      }
    }
  }

  // No overflow on every step at the sizes the app supports.
  const overflowSizes = <String, (Size, EdgeInsets, double)>{
    '360x640@1.3': (Size(360, 640), EdgeInsets.only(top: 24, bottom: 24), 1.3),
    '390x844': (Size(390, 844), EdgeInsets.only(top: 24, bottom: 24), 1.0),
    '844x390': (Size(844, 390), EdgeInsets.only(top: 24, right: 48), 1.0),
    '800x1280': (Size(800, 1280), EdgeInsets.zero, 1.0),
    '1280x800': (Size(1280, 800), EdgeInsets.zero, 1.0),
  };
  for (final (name, step) in _steps) {
    for (final e in overflowSizes.entries) {
      final (size, padding, scale) = e.value;
      testWidgets('Staff sign-up $name: no overflow at ${e.key}', (
        tester,
      ) async {
        await pumpStep(
          tester,
          step: step,
          size: size,
          padding: padding,
          brightness: Brightness.light,
          textScaler: TextScaler.linear(scale),
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  // Keyboard up (~300dp) at text scale 1.15, on every step (every text field:
  // invite code, full name, phone, address, OTP). The sign-up has no pop-up
  // holding a text box. Pattern: test/orders/orders_dialog_keyboard_test.dart.
  const keyboardSizes = <String, (Size, EdgeInsets)>{
    '360x640': (Size(360, 640), EdgeInsets.only(top: 24, bottom: 24)),
    '844x390': (Size(844, 390), EdgeInsets.only(top: 24, right: 48)),
  };
  for (final (name, step) in _steps) {
    for (final e in keyboardSizes.entries) {
      final (size, padding) = e.value;
      testWidgets('Staff sign-up $name: keyboard up at ${e.key}', (
        tester,
      ) async {
        await pumpScreen(
          tester,
          env: env,
          size: size,
          padding: padding,
          bottomNavHeight: 0,
          followView: true,
          textScaler: const TextScaler.linear(1.15),
          theme: AppTheme.dark(),
          overrides: [
            currentBusinessNameProvider.overrideWithValue('Stallion Global'),
          ],
          screen: StaffSignUpScreen(initialStep: step),
          settle: false,
        );
        await tester.pump(const Duration(milliseconds: 600));
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        addTearDown(tester.view.resetViewInsets);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.takeException(), isNull);
      });
    }
  }
}
