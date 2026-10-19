// Visual goldens for Profile, Edit Profile and Staff Settings (#442 PR 1,
// PRD #346 Wave 2 C). No mockups exist for these: they follow the CEO
// Settings menu's design language.
//
// Screens at 390x844, 844x390 (24 top + 48 right insets), 800x1280 and
// 1280x800, light + dark; the Edit Profile sheet at 390x844 and 844x390.
// Sample data only. PNGs live in test/redesign/goldens/. Regenerate with:
//
//     flutter test --update-goldens test/redesign/profile_settings_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/profile/screens/profile_screen.dart';
import 'package:reebaplus_pos/features/profile/widgets/edit_profile_sheet.dart';
import 'package:reebaplus_pos/features/settings/screens/staff_settings_screen.dart';

import '../helpers/screen_harness.dart';
import '../profile/profile_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sizes = <String, (Size, EdgeInsets)>{
    '390x844': (Size(390, 844), EdgeInsets.zero),
    '844x390': (Size(844, 390), EdgeInsets.only(top: 24, right: 48)),
    '800x1280': (Size(800, 1280), EdgeInsets.zero),
    '1280x800': (Size(1280, 800), EdgeInsets.zero),
  };

  late ScreenTestEnvironment env;
  setUp(() async => env = await setupProfileEnv());
  tearDown(() => env.dispose());

  setUpAll(() => WidgetsApp.debugAllowBannerOverride = false);
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  void setInsets(WidgetTester tester, EdgeInsets p) {
    final fake = FakeViewPadding(top: p.top, right: p.right, bottom: p.bottom);
    tester.view.padding = fake;
    tester.view.viewPadding = fake;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
  }

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    final theme = brightness == Brightness.light
        ? AppTheme.light()
        : AppTheme.dark();

    sizes.forEach((sizeName, spec) {
      final (size, padding) = spec;
      for (final (name, finder, slug, role) in <(String, Type, String, String)>[
        ('profile', ProfileScreen, 'cashier', 'Cashier'),
        ('staff_settings', StaffSettingsScreen, 'manager', 'Manager'),
      ]) {
        testWidgets('$name $sizeName $themeName', (tester) async {
          setInsets(tester, padding);
          await pumpProfilePage(
            tester,
            env: env,
            size: size,
            padding: padding,
            slug: slug,
            roleName: role,
            theme: theme,
            screen: name == 'profile'
                ? const ProfileScreen()
                : const StaffSettingsScreen(),
          );
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byType(finder),
            matchesGoldenFile('goldens/${name}_${sizeName}_$themeName.png'),
          );
          await disposeScreen(tester);
        });
      }
    });

    for (final sizeName in const ['390x844', '844x390']) {
      final (size, padding) = sizes[sizeName]!;
      testWidgets('edit profile sheet $sizeName $themeName', (tester) async {
        setInsets(tester, padding);
        await pumpProfilePage(
          tester,
          env: env,
          size: size,
          padding: padding,
          theme: theme,
          followView: true,
          screen: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => EditProfileSheet.show(
                    context,
                    user: ref.read(authProvider).currentUser!,
                    parentRef: ref,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(Navigator).first,
          matchesGoldenFile(
            'goldens/edit_profile_sheet_${sizeName}_$themeName.png',
          ),
        );
        await disposeScreen(tester);
      });
    }
  }
}
