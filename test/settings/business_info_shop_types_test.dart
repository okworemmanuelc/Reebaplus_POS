import 'package:drift/drift.dart' show Variable;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/industry/industry.dart';
import 'package:reebaplus_pos/core/settings/business_info_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

import '../helpers/screen_harness.dart';
import 'settings_leftovers_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ScreenTestEnvironment env;

  setUp(() async => env = await setupSettingsEnv());
  tearDown(() async {
    await env.dispose();
  });

  group('Business Info - Shop types & Other (#492)', () {
    testWidgets('dropdown offers all 9 shop types plus Other', (tester) async {
      await pumpSettingsPage(
        tester,
        env: env,
        screen: const BusinessInfoScreen(),
        size: const Size(390, 844),
      );

      final dropdown = tester.widget<AppDropdown<String>>(
        find.byType(AppDropdown<String>).first,
      );
      final options = dropdown.items.map((i) => i.value).toList();

      for (final ind in Industry.catalogue) {
        expect(
          options,
          contains(ind.label),
          reason: '${ind.label} missing from options',
        );
      }
      expect(options, contains('Other'));

      await disposeScreen(tester);
    });

    testWidgets('loads custom type as Other and displays custom text in input', (
      tester,
    ) async {
      await env.db.customStatement(
        "UPDATE businesses SET type = 'Bakery' WHERE id = '${env.businessId}'",
      );
      await pumpSettingsPage(
        tester,
        env: env,
        screen: const BusinessInfoScreen(),
        size: const Size(390, 844),
      );

      final dropdown = tester.widget<AppDropdown<String>>(
        find.byType(AppDropdown<String>).first,
      );
      expect(dropdown.currentValue, 'Other');

      // Text box shows Bakery
      expect(find.text('Bakery'), findsOneWidget);
      expect(find.text('Specify business type'), findsOneWidget);

      // No crate switch for Bakery
      expect(find.text('Track empty crates'), findsNothing);

      await disposeScreen(tester);
    });

    testWidgets('loads a lowercase known type as that type, not Other', (
      tester,
    ) async {
      await env.db.customStatement(
        "UPDATE businesses SET type = 'pharmacy' WHERE id = '${env.businessId}'",
      );
      await pumpSettingsPage(
        tester,
        env: env,
        screen: const BusinessInfoScreen(),
        size: const Size(390, 844),
      );

      final dropdown = tester.widget<AppDropdown<String>>(
        find.byType(AppDropdown<String>).first,
      );
      expect(dropdown.currentValue, 'Pharmacy');
      expect(find.text('Specify business type'), findsNothing);

      await disposeScreen(tester);
    });

    testWidgets('selecting Other displays text box and saves custom type', (
      tester,
    ) async {
      await pumpSettingsPage(
        tester,
        env: env,
        screen: const BusinessInfoScreen(),
        size: const Size(390, 844),
      );

      // Select Other
      final dropdown = tester.widget<AppDropdown<String>>(
        find.byType(AppDropdown<String>).first,
      );
      dropdown.onChanged('Other');
      await tester.pumpAndSettle();

      expect(find.text('Specify business type'), findsOneWidget);

      // Enter custom type
      final otherField = find.descendant(
        of: find.widgetWithText(AppInput, 'Specify business type'),
        matching: find.byType(TextField),
      );
      await tester.enterText(otherField, 'Electronics Repair');
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

      // Verify DB was updated with 'Electronics Repair'
      final rows = await env.db
          .customSelect(
            'SELECT type FROM businesses WHERE id = ?',
            variables: [Variable.withString(env.businessId)],
          )
          .get();
      expect(rows.single.read<String>('type'), 'Electronics Repair');

      await tester.pumpAndSettle(const Duration(seconds: 5));
      await disposeScreen(tester);
    });

    testWidgets('shows crate switch for Bar but not for Pharmacy or Other', (
      tester,
    ) async {
      await pumpSettingsPage(
        tester,
        env: env,
        screen: const BusinessInfoScreen(),
        size: const Size(390, 844),
      );

      AppDropdown<String> dropdown() => tester.widget<AppDropdown<String>>(
        find.byType(AppDropdown<String>).first,
      );

      // Select Bar
      dropdown().onChanged('Bar');
      await tester.pumpAndSettle();
      expect(find.text('Track empty crates'), findsOneWidget);

      // Select Pharmacy
      dropdown().onChanged('Pharmacy');
      await tester.pumpAndSettle();
      expect(find.text('Track empty crates'), findsNothing);

      // Select Other
      dropdown().onChanged('Other');
      await tester.pumpAndSettle();
      expect(find.text('Track empty crates'), findsNothing);

      await disposeScreen(tester);
    });
  });
}
