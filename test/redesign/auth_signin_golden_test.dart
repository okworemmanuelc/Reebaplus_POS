// Visual goldens for Auth PR 2 (sign-in screens): Email entry, OTP
// verification, Existing account, No account found at 390x844, 844x390 (24dp
// status bar + 48dp side inset), 800x1280, 1280x800 in light and dark, plus
// the stale-business prompt at 390x844 and 844x390. Regenerate with:
//
//     flutter test --update-goldens test/redesign/auth_signin_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/auth/screens/email_entry_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/existing_account_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/no_account_found_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/otp_verification_screen.dart';
import 'package:reebaplus_pos/features/auth/widgets/stale_business_clear_prompt.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';

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
    // No corner DEBUG banner in the goldens.
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

  Future<void> pumpIt(
    WidgetTester tester, {
    required Widget screen,
    required Size size,
    required EdgeInsets padding,
    required Brightness brightness,
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
    // Fixed durations: no settle (the OTP resend timer repeats).
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 600));
  }

  Future<void> golden(
    WidgetTester tester, {
    required Widget screen,
    required Type type,
    required Size size,
    required EdgeInsets padding,
    required Brightness brightness,
    required String name,
  }) async {
    await pumpIt(
      tester,
      screen: screen,
      size: size,
      padding: padding,
      brightness: brightness,
    );
    await expectLater(
      find.byType(type),
      matchesGoldenFile('goldens/$name.png'),
    );
    await disposeScreen(tester);
  }

  const account = SupabaseAccountInfo(
    businessId: 'biz-1',
    businessName: 'Stallion Global',
    roleName: 'CEO',
    roleSlug: 'ceo',
  );

  for (final entry in sizes.entries) {
    final sizeKey = entry.key;
    final (size, padding) = entry.value;

    for (final brightness in [Brightness.light, Brightness.dark]) {
      final themeKey = brightness == Brightness.light ? 'light' : 'dark';

      testWidgets('Email entry golden ($sizeKey, $themeKey)', (tester) async {
        await golden(
          tester,
          screen: const EmailEntryScreen(prefilledEmail: 'ada@example.com'),
          type: EmailEntryScreen,
          size: size,
          padding: padding,
          brightness: brightness,
          name: 'email_entry_${sizeKey}_$themeKey',
        );
      });

      testWidgets('OTP verification golden ($sizeKey, $themeKey)', (
        tester,
      ) async {
        await golden(
          tester,
          screen: const OtpVerificationScreen(
            user: null,
            email: 'ada@example.com',
          ),
          type: OtpVerificationScreen,
          size: size,
          padding: padding,
          brightness: brightness,
          name: 'otp_verification_${sizeKey}_$themeKey',
        );
      });

      testWidgets('Existing account golden ($sizeKey, $themeKey)', (
        tester,
      ) async {
        await golden(
          tester,
          screen: const ExistingAccountScreen(
            email: 'ada@example.com',
            account: account,
          ),
          type: ExistingAccountScreen,
          size: size,
          padding: padding,
          brightness: brightness,
          name: 'existing_account_${sizeKey}_$themeKey',
        );
      });

      testWidgets('No account found golden ($sizeKey, $themeKey)', (
        tester,
      ) async {
        await golden(
          tester,
          screen: const NoAccountFoundScreen(email: 'ada@example.com'),
          type: NoAccountFoundScreen,
          size: size,
          padding: padding,
          brightness: brightness,
          name: 'no_account_found_${sizeKey}_$themeKey',
        );
      });
    }
  }

  // The stale-business prompt: 390x844 and 844x390, light + dark.
  for (final key in ['390x844', '844x390']) {
    final (size, padding) = sizes[key]!;
    for (final brightness in [Brightness.light, Brightness.dark]) {
      final themeKey = brightness == Brightness.light ? 'light' : 'dark';
      testWidgets('Stale business prompt golden ($key, $themeKey)', (
        tester,
      ) async {
        await pumpIt(
          tester,
          screen: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => staleBusinessClearPrompt(context)(
                    const StaleBusinessWarning(
                      businessId: 'biz-old',
                      businessName: 'Abuja Traders',
                      unsentCount: 3,
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
          size: size,
          padding: padding,
          brightness: brightness,
        );
        await tester.tap(find.text('open'));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.text('Clear and continue'), findsOneWidget);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            'goldens/stale_business_prompt_${key}_$themeKey.png',
          ),
        );
        await disposeScreen(tester);
      });
    }
  }
}
