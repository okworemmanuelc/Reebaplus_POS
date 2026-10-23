// Visual goldens for the sign-up finish screens (D2 PR 2, #463): Access
// granted and Success (dashboard entry). 390x844, 844x390 (24dp status bar +
// 48dp side inset), 800x1280 and 1280x800, light and dark. PNGs live in
// test/redesign/goldens/. Regenerate with:
//
//     flutter test --update-goldens test/redesign/finish_screens_golden_test.dart
//
// The pulsing ring, the success check and the staggered content are driven by
// fixed pumps (never settled: the ring repeats forever); the loading spinner
// on Success is frozen at its first frames. Also checks no overflow at the
// supported sizes, 360dp at text scale 1.3 included.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/auth/screens/access_granted_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/success_dashboard_entry_screen.dart';

import '../helpers/screen_harness.dart';

const _connectivityChannel = MethodChannel(
  'dev.fluttercommunity.plus/connectivity',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _connectivityChannel,
          (call) async => call.method == 'check' ? <String>['wifi'] : null,
        );
  });

  const sizes = <String, (Size, EdgeInsets)>{
    '390x844': (Size(390, 844), EdgeInsets.zero),
    '844x390': (Size(844, 390), EdgeInsets.only(top: 24, right: 48)),
    '800x1280': (Size(800, 1280), EdgeInsets.zero),
    '1280x800': (Size(1280, 800), EdgeInsets.zero),
  };
  const overflowSizes = <String, (Size, EdgeInsets, double)>{
    '360x640@1.3': (Size(360, 640), EdgeInsets.only(top: 24, bottom: 24), 1.3),
    '390x844': (Size(390, 844), EdgeInsets.only(top: 24, bottom: 24), 1.0),
    '844x390': (Size(844, 390), EdgeInsets.only(top: 24, right: 48), 1.0),
    '800x1280': (Size(800, 1280), EdgeInsets.zero, 1.0),
    '1280x800': (Size(1280, 800), EdgeInsets.zero, 1.0),
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

  UserData user() => UserData(
    id: 'user-ada',
    businessId: env.businessId,
    name: 'Ada Okafor',
    pin: '0000',
    avatarColor: '#3B82F6',
    storeId: env.storeId,
    biometricEnabled: false,
    createdAt: DateTime(2026, 1, 1),
    lastUpdatedAt: DateTime(2026, 1, 1),
  );

  Future<void> pump(
    WidgetTester tester, {
    required Widget screen,
    required Size size,
    required EdgeInsets padding,
    required Brightness brightness,
    double scale = 1.0,
  }) async {
    if (padding != EdgeInsets.zero) {
      tester.view.padding = FakeViewPadding(
        top: padding.top,
        right: padding.right,
        bottom: padding.bottom,
      );
      tester.view.viewPadding = FakeViewPadding(
        top: padding.top,
        right: padding.right,
        bottom: padding.bottom,
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
      textScaler: TextScaler.linear(scale),
      theme: brightness == Brightness.light
          ? AppTheme.light()
          : AppTheme.dark(),
      screen: screen,
      settle: false,
    );
    // Fixed durations only. The DB read resolves off the fake clock.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    // 12 x 100ms = 1.2s: past the 350ms stagger timer and the 900ms content
    // animation, short of Success's 1.5s auto-forward.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  final screens = <String, Widget Function()>{
    'access_granted': () => AccessGrantedScreen(user: user()),
    'success_dashboard_entry': () => const SuccessDashboardEntryScreen(),
  };

  for (final MapEntry(key: name, value: build) in screens.entries) {
    for (final entry in sizes.entries) {
      final (size, padding) = entry.value;
      for (final brightness in Brightness.values) {
        final themeKey = brightness == Brightness.light ? 'light' : 'dark';
        testWidgets('$name golden (${entry.key}, $themeKey)', (tester) async {
          await pump(
            tester,
            screen: build(),
            size: size,
            padding: padding,
            brightness: brightness,
          );
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byType(Scaffold).first,
            matchesGoldenFile('goldens/${name}_${entry.key}_$themeKey.png'),
          );
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(milliseconds: 50));
        });
      }
    }
    for (final e in overflowSizes.entries) {
      final (size, padding, scale) = e.value;
      testWidgets('$name: no overflow at ${e.key}', (tester) async {
        await pump(
          tester,
          screen: build(),
          size: size,
          padding: padding,
          brightness: Brightness.light,
          scale: scale,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 50));
      });
    }
  }
}
