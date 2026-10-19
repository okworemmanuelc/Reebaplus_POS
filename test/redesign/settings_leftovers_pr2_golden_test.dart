// Visual goldens for Business Info, Appearance, Display and Receipt printer
// (#442 PR 2, PRD #346 Wave 2 C). No mockups: they follow the CEO Settings
// menu's design language.
//
// Each screen at 390x844, 844x390 (24 top + 48 right insets), 800x1280 and
// 1280x800, light + dark. Sample data only. Regenerate with:
//
//     flutter test --update-goldens test/redesign/settings_leftovers_pr2_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/appearance_settings_screen.dart';
import 'package:reebaplus_pos/core/settings/business_info_screen.dart';
import 'package:reebaplus_pos/core/settings/receipt_printer_settings_screen.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/theme_notifier.dart';
import 'package:reebaplus_pos/core/theme/theme_settings_screen.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';

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
  tearDown(() async {
    await env.dispose();
    themeController.setDesignSystem(DesignSystem.amber);
  });

  setUpAll(() => WidgetsApp.debugAllowBannerOverride = false);
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  final screens = <String, (Type, Widget)>{
    'business_info': (BusinessInfoScreen, const BusinessInfoScreen()),
    'appearance': (AppearanceSettingsScreen, const AppearanceSettingsScreen()),
    'display': (ThemeSettingsScreen, const ThemeSettingsScreen()),
    'receipt_printer': (
      ReceiptPrinterSettingsScreen,
      const ReceiptPrinterSettingsScreen(),
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
        final (type, screen) = entry;
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
          themeController.setDesignSystem(DesignSystem.blue);
          await env.db.customStatement(
            "UPDATE businesses SET type = 'Beer distributor', "
            "phone = '08031234567' WHERE id = '${env.businessId}'",
          );
          if (name == 'receipt_printer') {
            SharedPreferences.setMockInitialValues({});
            await tester.runAsync(
              () => FakePrinterService().savePaperSizeFor(
                kBackOfficeMac,
                ReceiptPaperSize.mm80,
              ),
            );
          }
          await pumpSettingsPage(
            tester,
            env: env,
            screen: screen,
            size: size,
            padding: padding,
            theme: theme,
            overrides: [
              businessDesignSystemProvider.overrideWith(
                (ref) => Stream.value(DesignSystem.blue),
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
