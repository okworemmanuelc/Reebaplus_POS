// Visual goldens for Stock Count (#392 PR 3, Wave 2 A): the solid top bar, the
// count list, and its sheets — Review Count, Record Damages and Count History.
//
// The screen at 390x844 (gesture nav, bottom 24), 844x390 (status bar 24,
// 3-button nav on the right 48), 800x1280 and 1280x800; the sheets at 390x844
// and 844x390. Light + dark. The sample count history has a pinned business
// date, so nothing depends on the clock. Regenerate with:
//
//     flutter test --update-goldens test/redesign/stock_count_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/inventory/screens/stock_count_screen.dart';

import '../helpers/inventory_seed.dart';
import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late InventorySample sample;

  setUpAll(() => WidgetsApp.debugAllowBannerOverride = false);
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
      businessType: 'Beverage distributor',
    );
    sample = await seedInventorySample(env);
  });

  tearDown(() => env.dispose());

  const allSizes = <(String, Size, FakeViewPadding)>[
    ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
    ('844x390', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
    ('800x1280', Size(800, 1280), FakeViewPadding(top: 24, bottom: 24)),
    ('1280x800', Size(1280, 800), FakeViewPadding(top: 24)),
  ];
  const phoneSizes = [
    ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
    ('844x390', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
  ];

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> pump(
    WidgetTester tester, {
    required Size size,
    required FakeViewPadding insets,
    required Brightness brightness,
  }) async {
    tester.view.padding = insets;
    tester.view.viewPadding = insets;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: StockCountScreen(storeId: env.storeId),
      followView: true,
      settle: false,
      grantedKeys: kInventorySampleGrants,
      roleRank: GateTier.ceo,
      theme: brightness == Brightness.light
          ? AppTheme.light()
          : AppTheme.dark(),
      overrides: [
        todaysBusinessDateProvider.overrideWith((ref) async => '2026-10-01'),
      ],
    );
    await settle(tester);
  }

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';

    for (final (sizeName, size, insets) in allSizes) {
      testWidgets('stock count, $sizeName $themeName', (tester) async {
        await pump(tester, size: size, insets: insets, brightness: brightness);
        // A count in progress: one over, one short, the rest untouched.
        await tester.enterText(find.byType(TextField).at(0), '55');
        await tester.enterText(find.byType(TextField).at(3), '2');
        await tester.pump();
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/stock_count_${sizeName}_$themeName.png'),
        );
        await disposeScreen(tester);
      });
    }

    for (final (sizeName, size, insets) in phoneSizes) {
      testWidgets('stock count review sheet, $sizeName $themeName', (
        tester,
      ) async {
        await pump(tester, size: size, insets: insets, brightness: brightness);
        await tester.enterText(find.byType(TextField).at(0), '55');
        await tester.enterText(find.byType(TextField).at(3), '2');
        await tester.pump();
        await tester.tap(find.text('Save Count'));
        await tester.pumpAndSettle();
        expect(find.text('Review Count'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            'goldens/stock_count_review_${sizeName}_$themeName.png',
          ),
        );
        await disposeScreen(tester);
      });

      testWidgets('stock count record damages sheet, $sizeName $themeName', (
        tester,
      ) async {
        await pump(tester, size: size, insets: insets, brightness: brightness);
        await tester.tap(find.byTooltip('Record Damages'));
        await tester.pumpAndSettle();
        expect(find.text('Record Damages'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            'goldens/stock_count_damages_${sizeName}_$themeName.png',
          ),
        );
        await disposeScreen(tester);
      });

      testWidgets('stock count history sheet, $sizeName $themeName', (
        tester,
      ) async {
        await tester.runAsync(() async {
          for (final (date, short) in const [
            ('2026-10-01', -1),
            ('2026-09-30', 0),
          ]) {
            await env.db.stockCountsDao.recordCount(
              storeId: env.storeId,
              businessDate: date,
              productsCounted: 6,
              changedLines: short == 0
                  ? const []
                  : [
                      {
                        'p': sample.productIds['Gulder'],
                        'n': 'Gulder',
                        's': 4,
                        'a': 3,
                        'd': short,
                      },
                    ],
              countedBy: sample.staffId,
            );
          }
        });
        await pump(tester, size: size, insets: insets, brightness: brightness);
        await tester.tap(find.byTooltip('View History'));
        await settle(tester);
        await tester.pumpAndSettle();
        expect(find.text('Count History'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            'goldens/stock_count_history_${sizeName}_$themeName.png',
          ),
        );
        await disposeScreen(tester);
      });
    }
  }
}
