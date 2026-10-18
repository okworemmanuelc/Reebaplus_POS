// Visual goldens for Roles & Permissions, Role Permissions Detail (Manager)
// and Staff Permissions (#440 part 2, PRD #346 Wave 2 batch C). No mockup:
// built from the shared parts and the Wave 1 patterns.
//
// `roles_permissions_*`, `role_permissions_detail_*`, `staff_permissions_*`:
// 390x844 (gesture nav), 844x390 with a 24dp status bar and a 48dp nav bar on
// the right, 800x1280 and 1280x800, light + dark. Sample data only. Regenerate:
//
//     flutter test --update-goldens test/redesign/roles_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/settings/role_permissions_detail_screen.dart';
import 'package:reebaplus_pos/core/settings/roles_permissions_screen.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/staff/screens/staff_permissions_screen.dart';

import '../helpers/screen_harness.dart';
import '../helpers/staff_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late StaffFixture fx;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
    );
    fx = await seedStaff(env);
  });
  tearDown(() => env.dispose());

  setUpAll(() => WidgetsApp.debugAllowBannerOverride = false);
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  Future<void> deliver(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> pump(
    WidgetTester tester,
    Size size,
    FakeViewPadding insets,
    ThemeData theme,
    Widget screen,
  ) async {
    tester.view.padding = insets;
    tester.view.viewPadding = insets;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: screen,
      bottomNavHeight: 0,
      followView: true,
      grantedKeys: staffGrants,
      roleRank: GateTier.ceo,
      theme: theme,
      overrides: [
        currentBusinessNameProvider.overrideWithValue('Stallion Global'),
      ],
      settle: false,
    );
    await deliver(tester);
  }

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    final theme = brightness == Brightness.light
        ? AppTheme.light()
        : AppTheme.dark();

    for (final (sizeName, size, insets) in const [
      ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
      ('844x390_insets', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
      ('800x1280', Size(800, 1280), FakeViewPadding()),
      ('1280x800', Size(1280, 800), FakeViewPadding()),
    ]) {
      for (final (name, build, type)
          in <(String, Future<Widget> Function(), Type)>[
            (
              'roles_permissions',
              () async => const RolesPermissionsScreen(),
              RolesPermissionsScreen,
            ),
            (
              'role_permissions_detail',
              () async => RolePermissionsDetailScreen(
                role:
                    await (env.db.select(env.db.roles)
                          ..where((r) => r.id.equals(fx.roleIds['manager']!)))
                        .getSingle(),
              ),
              RolePermissionsDetailScreen,
            ),
            (
              'staff_permissions',
              () async => StaffPermissionsScreen(
                user: fx.cashierUser,
                role: fx.cashierRole,
              ),
              StaffPermissionsScreen,
            ),
          ]) {
        testWidgets('$name $sizeName $themeName', (tester) async {
          await pump(tester, size, insets, theme, await build());
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byType(type),
            matchesGoldenFile('goldens/${name}_${sizeName}_$themeName.png'),
          );
          await disposeScreen(tester);
        });
      }
    }
  }
}
