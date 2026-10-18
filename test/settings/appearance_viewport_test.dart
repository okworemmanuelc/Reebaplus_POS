import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/appearance_settings_screen.dart';
import 'package:reebaplus_pos/core/theme/theme_notifier.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

void main() {
  late ScreenTestEnvironment env;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await initTestSupabase();
  });

  setUp(() async {
    env = await setupScreenTestEnvironment();
  });

  tearDown(() async {
    await env.dispose();
    themeController.setDesignSystem(DesignSystem.amber);
  });

  const colours = [
    ('Amber', DesignSystem.amber),
    ('Blue', DesignSystem.blue),
    ('Purple', DesignSystem.purple),
    ('Green', DesignSystem.green),
    ('Black & White', DesignSystem.bw),
  ];

  const testViewports = [
    ('phoneSe1Portrait', phoneSe1Portrait),
    ('androidCompactPortrait', androidCompactPortrait),
    ('pixel7Portrait', pixel7Portrait),
    ('androidCompactLandscape', androidCompactLandscape),
  ];

  group('AppearanceSettingsScreen viewport overflow test (#260)', () {
    for (final (vpName, vpSize) in testViewports) {
      for (final (label, ds) in colours) {
        testWidgets(
          'renders without overflow at $vpName with $label selected',
          (tester) async {
            themeController.setDesignSystem(ds);

            await pumpScreen(
              tester,
              env: env,
              size: vpSize,
              screen: const AppearanceSettingsScreen(),
              grantedKeys: {'settings.manage'},
              overrides: [
                businessDesignSystemProvider.overrideWith(
                  (ref) => Stream.value(ds),
                ),
              ],
            );

            expectNoOverflow(
              tester,
              reason: 'Expected no overflow at $vpName with $label selected',
            );

            // Verify the selected card's check badge is fully visible
            final badgeFinder = find.byKey(appearanceCheckBadgeKey(ds));
            await tester.scrollUntilVisible(
              badgeFinder,
              100,
              scrollable: find.byType(Scrollable).first,
            );
            expect(badgeFinder, findsOneWidget);

            final badgeRect = tester.getRect(badgeFinder);
            expect(badgeRect.width, greaterThan(0));
            expect(badgeRect.height, greaterThan(0));

            // Verify check badge does not overlap any swatch
            for (var i = 0; i < 3; i++) {
              final swatchFinder = find.byKey(appearanceSwatchKey(ds, i));
              expect(swatchFinder, findsOneWidget);
              final swatchRect = tester.getRect(swatchFinder);

              expect(
                badgeRect.overlaps(swatchRect),
                isFalse,
                reason:
                    'Check badge overlaps swatch $i for $label on $vpName: '
                    'badge=$badgeRect swatch=$swatchRect',
              );
              expect(
                badgeRect.left,
                greaterThanOrEqualTo(swatchRect.right),
                reason:
                    'Check badge should be positioned to the right of swatch $i: '
                    'badge.left=${badgeRect.left} swatch.right=${swatchRect.right}',
              );
            }

            await disposeScreen(tester);
          },
        );
      }
    }

    testWidgets(
      'tapping an unselected colour card selects its colour',
      (tester) async {
        themeController.setDesignSystem(DesignSystem.amber);

        await pumpScreen(
          tester,
          env: env,
          size: androidCompactPortrait,
          screen: const AppearanceSettingsScreen(),
          grantedKeys: {'settings.manage'},
          overrides: [
            businessDesignSystemProvider.overrideWith(
              (ref) => Stream.value(DesignSystem.amber),
            ),
          ],
        );

        expectNoOverflow(tester);

        // Tap Blue card
        await tester.tap(find.byKey(appearanceCardKey(DesignSystem.blue)));
        await tester.pumpAndSettle();

        expect(themeController.designSystem, DesignSystem.blue);

        // Drain toast timer
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();

        await disposeScreen(tester);
      },
    );

    testWidgets(
      'renders without overflow under max text scale (1.3x) on compact viewports',
      (tester) async {
        themeController.setDesignSystem(DesignSystem.bw);

        for (final (vpName, vpSize) in [
          ('phoneSe1Portrait', phoneSe1Portrait),
          ('androidCompactPortrait', androidCompactPortrait),
        ]) {
          await pumpScreen(
            tester,
            env: env,
            size: vpSize,
            textScaler: const TextScaler.linear(1.3),
            screen: const AppearanceSettingsScreen(),
            grantedKeys: {'settings.manage'},
            overrides: [
              businessDesignSystemProvider.overrideWith(
                (ref) => Stream.value(DesignSystem.bw),
              ),
            ],
          );

          expectNoOverflow(
            tester,
            reason:
                'Expected no overflow at $vpName under 1.3x text scale with Black & White selected',
          );

          await disposeScreen(tester);
        }
      },
    );
  });
}
