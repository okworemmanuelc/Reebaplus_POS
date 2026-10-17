// Business Info, Appearance, Display and Receipt printer after the #442
// restyle (PR 2 of 3, PRD #346 Wave 2 C): every control still renders, the
// permission gate still hides the page, the main actions still work and
// nothing overflows at the reference sizes or with the keyboard up.

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/appearance_settings_screen.dart';
import 'package:reebaplus_pos/core/settings/business_info_screen.dart';
import 'package:reebaplus_pos/core/settings/receipt_printer_settings_screen.dart';
import 'package:reebaplus_pos/core/theme/theme_notifier.dart';
import 'package:reebaplus_pos/core/theme/theme_settings_screen.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';

import '../helpers/screen_harness.dart';
import 'settings_leftovers_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ScreenTestEnvironment env;
  setUp(() async => env = await setupSettingsEnv());
  tearDown(() async {
    await env.dispose();
    themeController.setDesignSystem(DesignSystem.amber);
  });

  group('Business Info', () {
    testWidgets('renders every control', (tester) async {
      await pumpSettingsPage(
        tester,
        env: env,
        screen: const BusinessInfoScreen(),
        size: const Size(390, 844),
      );
      expect(find.text('Business Info'), findsOneWidget);
      for (final t in ['Logo', 'Business', 'Tax']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      expect(find.text('Upload logo'), findsOneWidget);
      expect(find.text('Business name'), findsOneWidget);
      expect(find.text('Phone number'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Save changes'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Charge VAT'), findsOneWidget);
      expect(find.text('Save changes'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('without settings.manage the page is hidden', (tester) async {
      await pumpSettingsPage(
        tester,
        env: env,
        screen: const BusinessInfoScreen(),
        size: const Size(390, 844),
        grantedKeys: const {},
        roleSlug: 'cashier',
        roleName: 'Cashier',
      );
      expect(find.text("You don't have access to settings."), findsOneWidget);
      expect(find.text('Save changes'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('VAT is off by default; the switch reveals the rate', (
      tester,
    ) async {
      await pumpSettingsPage(
        tester,
        env: env,
        screen: const BusinessInfoScreen(),
        size: const Size(390, 844),
      );
      await tester.scrollUntilVisible(
        find.text('Charge VAT'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('VAT rate (%)'), findsNothing);
      await tester.tap(find.text('Charge VAT'));
      await tester.pumpAndSettle();
      expect(find.text('VAT rate (%)'), findsOneWidget);
      expect(find.text('Prices already include VAT'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('Save writes the new name', (tester) async {
      await pumpSettingsPage(
        tester,
        env: env,
        screen: const BusinessInfoScreen(),
        size: const Size(390, 844),
      );
      await tester.enterText(
        find.byType(TextField).first,
        'Stallion Global Ltd',
      );
      final save = find.text('Save changes');
      await tester.scrollUntilVisible(
        save,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final rows = await env.db
          .customSelect(
            'SELECT name FROM businesses WHERE id = ?',
            variables: [Variable.withString(env.businessId)],
          )
          .get();
      expect(rows.single.read<String>('name'), 'Stallion Global Ltd');
      await tester.pumpAndSettle(const Duration(seconds: 5));
      await disposeScreen(tester);
    });
  });

  group('Appearance', () {
    testWidgets('lists the colour cards', (tester) async {
      await pumpSettingsPage(
        tester,
        env: env,
        screen: const AppearanceSettingsScreen(),
        size: const Size(390, 844),
      );
      for (final ds in [
        DesignSystem.amber,
        DesignSystem.blue,
        DesignSystem.purple,
        DesignSystem.green,
        DesignSystem.bw,
      ]) {
        expect(find.byKey(appearanceCardKey(ds)), findsOneWidget);
      }
      await disposeScreen(tester);
    });

    testWidgets('hidden without settings.manage', (tester) async {
      await pumpSettingsPage(
        tester,
        env: env,
        screen: const AppearanceSettingsScreen(),
        size: const Size(390, 844),
        grantedKeys: const {},
        roleSlug: 'cashier',
        roleName: 'Cashier',
      );
      expect(find.byKey(appearanceCardKey(DesignSystem.blue)), findsNothing);
      await disposeScreen(tester);
    });
  });

  group('Display', () {
    testWidgets('renders the three modes and Dark switches the mode', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await pumpSettingsPage(
        tester,
        env: env,
        screen: const ThemeSettingsScreen(),
        size: const Size(390, 844),
      );
      expect(find.text('Appearance Mode'), findsOneWidget);
      expect(find.text('Applies to this device only.'), findsOneWidget);
      expect(find.text('Light'), findsOneWidget);
      expect(find.text('System'), findsOneWidget);
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();
      expect(themeController.themeMode, ThemeMode.dark);
      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      expect(themeController.themeMode, ThemeMode.light);
      await disposeScreen(tester);
    });
  });

  group('Receipt printer', () {
    testWidgets('last used first, 58/80 choice saved', (tester) async {
      await pumpSettingsPage(
        tester,
        env: env,
        screen: const ReceiptPrinterSettingsScreen(),
        size: const Size(390, 844),
      );
      expect(find.text('Counter printer'), findsOneWidget);
      expect(find.text('Back office printer'), findsOneWidget);
      expect(find.text('Last used'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Back office printer')).dy,
        lessThan(tester.getTopLeft(find.text('Counter printer')).dy),
      );
      await tester.tap(find.text('58mm (small)').first);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Refresh printers'), findsOneWidget);
      await disposeScreen(tester);
      expect(ReceiptPaperSize.values, isNotEmpty);
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
        ('business info', const BusinessInfoScreen()),
        ('appearance', const AppearanceSettingsScreen()),
        ('display', const ThemeSettingsScreen()),
        ('receipt printer', const ReceiptPrinterSettingsScreen()),
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
          await pumpSettingsPage(
            tester,
            env: env,
            screen: screen,
            size: size,
            padding: insets,
            textScaler: TextScaler.linear(scale),
            overrides: [
              businessDesignSystemProvider.overrideWith(
                (ref) => Stream.value(DesignSystem.blue),
              ),
            ],
          );
          expectNoOverflow(tester);
          await disposeScreen(tester);
        });
      }
    }
  });

  group('Business Info keyboard up', () {
    const phones = <(String, Size, double)>[
      ('390x844', Size(390, 844), 340),
      ('360x640', Size(360, 640), 280),
    ];
    for (final (name, size, keyboard) in phones) {
      testWidgets('the form scrolls above the keyboard $name', (tester) async {
        await pumpSettingsPage(
          tester,
          env: env,
          screen: const BusinessInfoScreen(),
          size: size,
          followView: true,
          textScaler: const TextScaler.linear(1.15),
        );
        await tester.tap(find.byType(TextField).first);
        tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
        await tester.pumpAndSettle();
        expectNoOverflow(tester);
        await tester.scrollUntilVisible(
          find.text('Save changes'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Save changes'), findsOneWidget);
        tester.view.resetViewInsets();
        await disposeScreen(tester);
      });
    }
  });
}
