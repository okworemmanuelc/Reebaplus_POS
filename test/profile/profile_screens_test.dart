// Profile, Edit Profile and Staff Settings after the #442 restyle: every
// control still renders, the permission-hidden ones stay hidden, the main
// actions still work and nothing overflows at the reference sizes (PRD #346
// Wave 2 C).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/profile/screens/profile_screen.dart';
import 'package:reebaplus_pos/features/profile/widgets/edit_profile_sheet.dart';
import 'package:reebaplus_pos/features/settings/screens/staff_settings_screen.dart';

import '../helpers/screen_harness.dart';
import 'profile_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ScreenTestEnvironment env;
  setUp(() async => env = await setupProfileEnv());
  tearDown(() => env.dispose());

  group('Profile', () {
    testWidgets('renders its controls for a cashier', (tester) async {
      await pumpProfilePage(
        tester,
        env: env,
        screen: const ProfileScreen(),
        size: const Size(390, 844),
      );
      expect(find.text('Chinedu Eze'), findsWidgets);
      expect(find.text('Account Details'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Announcements'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Announcements'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Edit Profile'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Edit Profile'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Leave / delete my account'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      // A cashier can resign; only the owner sees Delete Business.
      expect(find.text('Leave / delete my account'), findsOneWidget);
      expect(find.text('Delete Business'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('the owner sees Delete Business, not Leave', (tester) async {
      await pumpProfilePage(
        tester,
        env: env,
        screen: const ProfileScreen(),
        size: const Size(390, 844),
        slug: 'ceo',
        roleName: 'CEO',
      );
      await tester.scrollUntilVisible(
        find.text('Delete Business'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Delete Business'), findsOneWidget);
      expect(find.text('Leave / delete my account'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('Edit Profile opens the sheet', (tester) async {
      await pumpProfilePage(
        tester,
        env: env,
        screen: const ProfileScreen(),
        size: const Size(390, 844),
      );
      final edit = find.text('Edit Profile');
      await tester.scrollUntilVisible(
        edit,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(edit);
      await tester.pumpAndSettle();
      await tester.tap(edit);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('edit-profile-sheet')), findsOneWidget);
      expect(find.text('Save changes'), findsOneWidget);
      expect(find.text('Avatar colour'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('Leave asks for confirmation first', (tester) async {
      await pumpProfilePage(
        tester,
        env: env,
        screen: const ProfileScreen(),
        size: const Size(390, 844),
      );
      final leave = find.text('Leave / delete my account');
      await tester.scrollUntilVisible(
        leave,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(leave);
      await tester.pumpAndSettle();
      await tester.tap(leave);
      await tester.pumpAndSettle();
      expect(find.text('Leave and delete your account?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Leave and delete your account?'), findsNothing);
      await disposeScreen(tester);
    });
  });

  group('Staff Settings', () {
    testWidgets('lists the four rows for a manager', (tester) async {
      await pumpProfilePage(
        tester,
        env: env,
        screen: const StaffSettingsScreen(),
        size: const Size(390, 844),
        slug: 'manager',
        roleName: 'Manager',
      );
      for (final t in ['Profile', 'Change PIN', 'Receipt printer', 'Display']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      await tester.tap(find.text('Profile'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('edit-profile-sheet')), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('Display opens the display page', (tester) async {
      await pumpProfilePage(
        tester,
        env: env,
        screen: const StaffSettingsScreen(),
        size: const Size(390, 844),
        slug: 'manager',
        roleName: 'Manager',
      );
      await tester.tap(find.text('Display'));
      await tester.pumpAndSettle();
      expect(find.text('Appearance Mode'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('the CEO gets no access', (tester) async {
      await pumpProfilePage(
        tester,
        env: env,
        screen: const StaffSettingsScreen(),
        size: const Size(390, 844),
        slug: 'ceo',
        roleName: 'CEO',
      );
      expect(find.text("You don't have access to settings."), findsOneWidget);
      expect(find.text('Change PIN'), findsNothing);
      await disposeScreen(tester);
    });
  });

  group('no overflow', () {
    const cases = <(String, Size, EdgeInsets, double)>[
      ('360x640 @1.3', Size(360, 640), EdgeInsets.zero, 1.3),
      ('390x844', Size(390, 844), EdgeInsets.only(top: 24, bottom: 24), 1),
      ('844x390', Size(844, 390), EdgeInsets.only(top: 24, right: 48), 1),
      ('800x1280', Size(800, 1280), EdgeInsets.zero, 1),
      ('1280x800', Size(1280, 800), EdgeInsets.zero, 1),
    ];
    for (final (name, size, insets, scale) in cases) {
      for (final (label, screen) in <(String, Widget)>[
        ('profile', const ProfileScreen()),
        ('staff settings', const StaffSettingsScreen()),
      ]) {
        testWidgets('$label $name', (tester) async {
          final fake = FakeViewPadding(
            top: insets.top,
            right: insets.right,
            bottom: insets.bottom,
          );
          tester.view.padding = fake;
          tester.view.viewPadding = fake;
          addTearDown(tester.view.resetPadding);
          addTearDown(tester.view.resetViewPadding);
          await pumpProfilePage(
            tester,
            env: env,
            screen: screen,
            size: size,
            padding: insets,
            slug: 'manager',
            roleName: 'Manager',
            textScaler: TextScaler.linear(scale),
          );
          expectNoOverflow(tester);
          await disposeScreen(tester);
        });
      }
    }
  });

  group('Edit Profile keyboard up', () {
    const phones = <(String, Size, double)>[
      ('390x844', Size(390, 844), 340),
      ('360x640', Size(360, 640), 280),
    ];
    for (final (name, size, keyboard) in phones) {
      testWidgets('the sheet fits above the keyboard $name', (tester) async {
        await pumpProfilePage(
          tester,
          env: env,
          size: size,
          followView: true,
          textScaler: const TextScaler.linear(1.15),
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
        tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('edit-profile-sheet')), findsOneWidget);
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
        await disposeScreen(tester);
      });
    }
  });
}
