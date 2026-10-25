// Roles & Permissions, Role Permissions Detail and Staff Permissions after the
// restyle (#440 part 2, PRD #346 Wave 2 batch C): every control still renders,
// the permission-hidden ones stay hidden, the cascade / lock rules stay, and
// nothing overflows at the batch's viewport set or with the keyboard up.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/settings/role_permissions_detail_screen.dart';
import 'package:reebaplus_pos/core/settings/roles_permissions_screen.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/staff/screens/staff_permissions_screen.dart';
import 'package:reebaplus_pos/features/staff/widgets/permission_parts.dart';

import '../helpers/screen_harness.dart';
import '../helpers/staff_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late StaffFixture fx;

  Future<RoleData> roleOf(String slug) => (env.db.select(
    env.db.roles,
  )..where((r) => r.id.equals(fx.roleIds[slug]!))).getSingle();

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
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> pump(
    WidgetTester tester,
    Widget screen, {
    Size size = const Size(390, 844),
    FakeViewPadding insets = const FakeViewPadding(top: 24, bottom: 24),
    Set<String> grants = staffGrants,
    double textScale = 1.0,
    ThemeData? theme,
  }) async {
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
      grantedKeys: grants,
      roleRank: GateTier.ceo,
      textScaler: TextScaler.linear(textScale),
      theme: theme ?? AppTheme.light(),
      settle: false,
    );
    await deliver(tester);
  }

  const viewports = <(String, Size, FakeViewPadding, double)>[
    ('360x640@1.3', Size(360, 640), FakeViewPadding(top: 24, bottom: 24), 1.3),
    ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24), 1.0),
    ('844x390', Size(844, 390), FakeViewPadding(top: 24, right: 48), 1.0),
    ('800x1280', Size(800, 1280), FakeViewPadding(), 1.0),
    ('1280x800', Size(1280, 800), FakeViewPadding(), 1.0),
  ];

  group('Roles & Permissions', () {
    testWidgets('lists the four roles by tier with their counts', (
      tester,
    ) async {
      await pump(tester, const RolesPermissionsScreen());
      expect(find.text('Roles & Permissions'), findsOneWidget);
      expect(find.text('Tap a role to set what it can do.'), findsOneWidget);
      double y(String name) => tester.getTopLeft(find.text(name)).dy;
      expect(y('CEO') < y('Manager'), isTrue);
      expect(y('Manager') < y('Cashier'), isTrue);
      expect(y('Cashier') < y('Stock keeper'), isTrue);
      expect(find.textContaining('All '), findsOneWidget);
      expect(find.textContaining(' of '), findsWidgets);
      await disposeScreen(tester);
    });

    testWidgets('tapping a role opens its detail', (tester) async {
      await pump(tester, const RolesPermissionsScreen());
      await tester.tap(find.byKey(PermissionKeys.roleRow('cashier')));
      await deliver(tester);
      expect(find.byType(RolePermissionsDetailScreen), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('without settings.manage it is closed', (tester) async {
      await pump(
        tester,
        const RolesPermissionsScreen(),
        grants: const {'sales.make'},
      );
      expect(find.text('You don\'t have access to settings.'), findsOneWidget);
      expect(find.byKey(PermissionKeys.roleRow('cashier')), findsNothing);
      await disposeScreen(tester);
    });

    for (final (name, size, insets, scale) in viewports) {
      testWidgets('no overflow at $name', (tester) async {
        await pump(
          tester,
          const RolesPermissionsScreen(),
          size: size,
          insets: insets,
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        await disposeScreen(tester);
      });
    }
  });

  group('Role Permissions Detail', () {
    testWidgets('cashier: scope toggle, groups, limits and switches', (
      tester,
    ) async {
      await pump(
        tester,
        RolePermissionsDetailScreen(role: await roleOf('cashier')),
      );
      expect(find.text('Cashier'), findsWidgets);
      expect(find.byKey(PermissionKeys.scopeBusiness), findsOneWidget);
      expect(find.byKey(PermissionKeys.scopeStore), findsOneWidget);
      expect(find.byType(SwitchListTile), findsWidgets);
      expect(find.text('Allow viewing other stores'), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(PermissionKeys.discountCard),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Maximum discount'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(PermissionKeys.expenseCard),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Max expense approval'), findsOneWidget);
      expect(find.byKey(PermissionKeys.expenseField), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });

    testWidgets('manager has the view-other-stores toggle', (tester) async {
      await pump(
        tester,
        RolePermissionsDetailScreen(role: await roleOf('manager')),
      );
      expect(find.text('Allow viewing other stores'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('CEO is locked all-on with unlimited limits', (tester) async {
      await pump(
        tester,
        RolePermissionsDetailScreen(role: await roleOf('ceo')),
      );
      expect(
        find.text('The CEO always has full access — these can\'t be changed.'),
        findsOneWidget,
      );
      final switches = tester.widgetList<SwitchListTile>(
        find.byType(SwitchListTile),
      );
      expect(switches, isNotEmpty);
      expect(switches.every((s) => s.value && s.onChanged == null), isTrue);
      await tester.scrollUntilVisible(
        find.byKey(PermissionKeys.discountCard),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('100% (unlimited)'), findsOneWidget);
      expect(find.byType(Slider), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('a hidden key never shows as a toggle', (tester) async {
      await pump(
        tester,
        RolePermissionsDetailScreen(role: await roleOf('cashier')),
      );
      final all = await env.db.select(env.db.permissions).get();
      final hidden = all.firstWhere((p) => p.key == 'sales.discount.give');
      expect(find.text(hidden.description), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('Store scope shows the store picker and Restore', (
      tester,
    ) async {
      await pump(
        tester,
        RolePermissionsDetailScreen(role: await roleOf('cashier')),
      );
      await tester.tap(find.byKey(PermissionKeys.scopeStore));
      await deliver(tester);
      expect(find.text('Abuja HQ'), findsWidgets);
      await tester.scrollUntilVisible(
        find.text('Restore store defaults'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Restore store defaults'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('Store scope on the CEO explains there is nothing to edit', (
      tester,
    ) async {
      await pump(
        tester,
        RolePermissionsDetailScreen(role: await roleOf('ceo')),
      );
      await tester.tap(find.byKey(PermissionKeys.scopeStore));
      await deliver(tester);
      expect(
        find.text(
          'The CEO always has full access — per-store overrides don\'t apply.',
        ),
        findsOneWidget,
      );
      await disposeScreen(tester);
    });

    testWidgets('without settings.manage it is closed', (tester) async {
      await pump(
        tester,
        RolePermissionsDetailScreen(role: await roleOf('cashier')),
        grants: const {'sales.make'},
      );
      expect(find.text('You don\'t have access to settings.'), findsOneWidget);
      expect(find.byType(SwitchListTile), findsNothing);
      await disposeScreen(tester);
    });

    for (final (name, size, insets, scale) in viewports) {
      testWidgets('no overflow at $name', (tester) async {
        await pump(
          tester,
          RolePermissionsDetailScreen(role: await roleOf('manager')),
          size: size,
          insets: insets,
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(PermissionKeys.scopeStore));
        await deliver(tester);
        expect(tester.takeException(), isNull);
        await disposeScreen(tester);
      });
    }

    for (final (name, size, keyboard) in const [
      ('390x844', Size(390, 844), 340.0),
      ('360x640', Size(360, 640), 280.0),
    ]) {
      testWidgets('expense limit fits with the keyboard up $name', (
        tester,
      ) async {
        await pump(
          tester,
          RolePermissionsDetailScreen(role: await roleOf('cashier')),
          size: size,
          textScale: 1.15,
        );
        await tester.scrollUntilVisible(
          find.byKey(PermissionKeys.expenseField),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.byKey(PermissionKeys.expenseField));
        tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
        await deliver(tester);
        await tester.enterText(find.byKey(PermissionKeys.expenseField), '5000');
        await deliver(tester);
        expect(tester.takeException(), isNull);
        // Blur commits the limit while the screen is still mounted.
        FocusManager.instance.primaryFocus?.unfocus();
        await deliver(tester);
        tester.view.resetViewInsets();
        await disposeScreen(tester);
      });
    }
  });

  group('Staff Permissions', () {
    Widget screen() =>
        StaffPermissionsScreen(user: fx.cashierUser, role: fx.cashierRole);

    testWidgets('renders groups, switches and a disabled Restore defaults', (
      tester,
    ) async {
      await pump(tester, screen());
      expect(find.text('Ngozi Adeyemi'), findsOneWidget);
      expect(
        find.textContaining('Overrides the Cashier role defaults'),
        findsOneWidget,
      );
      expect(find.byType(SwitchListTile), findsWidgets);
      await tester.scrollUntilVisible(
        find.text('Ngozi Adeyemi is already on the Cashier defaults.'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Restore defaults'), findsOneWidget);
      expect(
        find.text('Ngozi Adeyemi is already on the Cashier defaults.'),
        findsOneWidget,
      );
      await disposeScreen(tester);
    });

    testWidgets('without settings.manage it is closed', (tester) async {
      await pump(tester, screen(), grants: const {'sales.make'});
      expect(find.text('You don\'t have access to settings.'), findsOneWidget);
      expect(find.byType(SwitchListTile), findsNothing);
      await disposeScreen(tester);
    });

    for (final (name, size, insets, scale) in viewports) {
      testWidgets('no overflow at $name', (tester) async {
        await pump(
          tester,
          screen(),
          size: size,
          insets: insets,
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        await disposeScreen(tester);
      });
    }
  });
}
