// Visual goldens for Security, the Subscription page, Activity Logs access,
// the Activity Logs list and Delete Business (#442 PR 3, PRD #346 Wave 2 C).
// No mockups: they follow the CEO Settings menu's design language.
//
// Each screen at 390x844, 844x390 (24 top + 48 right insets), 800x1280 and
// 1280x800, light + dark. Sample data only; every date is fixed (never
// relative to now). Regenerate with:
//
//     flutter test --update-goldens test/redesign/settings_leftovers_pr3_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/activity_logs_access_screen.dart';
import 'package:reebaplus_pos/core/settings/delete_business_screen.dart';
import 'package:reebaplus_pos/core/settings/security_settings_screen.dart';
import 'package:reebaplus_pos/core/settings/subscription_screen.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/subscription/subscription_access.dart';
import 'package:reebaplus_pos/shared/widgets/activity_log_screen.dart';

import '../helpers/screen_harness.dart';
import '../settings/settings_leftovers_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sizes = <String, (Size, EdgeInsets)>{
    '390x844': (Size(390, 844), EdgeInsets.zero),
    '844x390': (Size(844, 390), EdgeInsets.only(top: 24, right: 48)),
    '800x1280': (Size(800, 1280), EdgeInsets.zero),
    '1280x800': (Size(1280, 800), EdgeInsets.zero),
  };

  late ScreenTestEnvironment env;
  setUp(() async => env = await setupSettingsEnv());
  tearDown(() => env.dispose());

  setUpAll(() => WidgetsApp.debugAllowBannerOverride = false);
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  final screens = <String, (Type, Widget, bool)>{
    'security': (SecuritySettingsScreen, const SecuritySettingsScreen(), true),
    'subscription_settings': (
      SubscriptionScreen,
      const SubscriptionScreen(),
      true,
    ),
    'activity_logs_access': (
      ActivityLogsAccessScreen,
      const ActivityLogsAccessScreen(),
      true,
    ),
    'activity_log': (ActivityLogScreen, const ActivityLogScreen(), false),
    'delete_business': (
      DeleteBusinessScreen,
      const DeleteBusinessScreen(),
      true,
    ),
  };

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    final theme = brightness == Brightness.light
        ? AppTheme.light()
        : AppTheme.dark();
    sizes.forEach((sizeName, spec) {
      final (size, padding) = spec;
      screens.forEach((name, entry) {
        final (type, screen, pushed) = entry;
        testWidgets('$name $sizeName $themeName', (tester) async {
          final fake = FakeViewPadding(
            top: padding.top,
            right: padding.right,
            bottom: padding.bottom,
          );
          tester.view.padding = fake;
          tester.view.viewPadding = fake;
          addTearDown(tester.view.resetPadding);
          addTearDown(tester.view.resetViewPadding);
          await seedSampleRoles(env);
          await seedSampleActivityLogs(env);
          await seedSubscription(
            env,
            plan: 'basic',
            periodEnd: DateTime(2099, 4, 14),
          );
          await pumpSettingsPage(
            tester,
            env: env,
            screen: screen,
            size: size,
            padding: padding,
            pushed: pushed,
            theme: theme,
            grantedKeys: const {
              'settings.manage',
              'settings.delete_business',
              'activity_logs.view',
            },
            overrides: [
              currentBusinessSubscriptionProvider.overrideWithValue(
                SubscriptionAccess.active,
              ),
            ],
          );
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byType(type),
            matchesGoldenFile('goldens/${name}_${sizeName}_$themeName.png'),
          );
          await disposeScreen(tester);
        });
      });
    });
  }
}
