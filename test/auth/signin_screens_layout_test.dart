// No-overflow + keyboard-up checks for the restyled sign-in screens (#462 PR 2):
// Email entry, OTP verification, Existing account, No account found.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/features/auth/screens/email_entry_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/existing_account_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/no_account_found_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/otp_verification_screen.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';

import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  setUp(() async {
    env = await setupScreenTestEnvironment(productCount: 0);
  });
  tearDown(() => env.dispose());

  const account = SupabaseAccountInfo(
    businessId: 'biz-1',
    businessName: 'Stallion Global',
    roleName: 'CEO',
    roleSlug: 'ceo',
  );

  final screens = <String, Widget Function()>{
    'email entry': () =>
        const EmailEntryScreen(prefilledEmail: 'ada@example.com'),
    'otp verification': () =>
        const OtpVerificationScreen(user: null, email: 'ada@example.com'),
    'existing account': () =>
        const ExistingAccountScreen(email: 'ada@example.com', account: account),
    'no account found': () =>
        const NoAccountFoundScreen(email: 'ada@example.com'),
  };

  // (name, size, side/top insets, text scale)
  const layouts = <(String, Size, EdgeInsets, double)>[
    ('360x640 @1.3', Size(360, 640), EdgeInsets.zero, 1.3),
    ('390x844', Size(390, 844), EdgeInsets.zero, 1.0),
    (
      '844x390 insets',
      Size(844, 390),
      EdgeInsets.only(top: 24, right: 48),
      1.0,
    ),
    ('800x1280', Size(800, 1280), EdgeInsets.zero, 1.0),
    ('1280x800', Size(1280, 800), EdgeInsets.zero, 1.0),
  ];

  void setInsets(WidgetTester tester, EdgeInsets p, double keyboard) {
    tester.view.padding = FakeViewPadding(top: p.top, right: p.right);
    tester.view.viewPadding = FakeViewPadding(top: p.top, right: p.right);
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetViewInsets);
  }

  for (final s in screens.entries) {
    for (final (name, size, pad, scale) in layouts) {
      testWidgets('${s.key} has no overflow at $name', (tester) async {
        setInsets(tester, pad, 0);
        await pumpScreen(
          tester,
          env: env,
          size: size,
          padding: pad,
          bottomNavHeight: 0,
          followView: true,
          textScaler: TextScaler.linear(scale),
          screen: s.value(),
          settle: false,
        );
        await tester.pump(const Duration(milliseconds: 700));
        expect(tester.takeException(), isNull);
        await disposeScreen(tester);
      });
    }
  }

  // Keyboard up: the email field and the OTP row are the only text fields.
  for (final key in ['email entry', 'otp verification']) {
    for (final (name, size, pad, keyboard)
        in const <(String, Size, EdgeInsets, double)>[
          ('360x640', Size(360, 640), EdgeInsets.zero, 300.0),
          (
            '844x390',
            Size(844, 390),
            EdgeInsets.only(top: 24, right: 48),
            300.0,
          ),
        ]) {
      testWidgets('$key fits with the keyboard up at $name', (tester) async {
        setInsets(tester, pad, 0);
        await pumpScreen(
          tester,
          env: env,
          size: size,
          padding: pad,
          bottomNavHeight: 0,
          followView: true,
          textScaler: const TextScaler.linear(1.15),
          screen: screens[key]!(),
          settle: false,
        );
        await tester.pump(const Duration(milliseconds: 700));
        await tester.tap(find.byType(EditableText).first);
        await tester.pump();
        tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
        await tester.pump(const Duration(milliseconds: 700));
        expect(tester.takeException(), isNull);
        await disposeScreen(tester);
      });
    }
  }
}
