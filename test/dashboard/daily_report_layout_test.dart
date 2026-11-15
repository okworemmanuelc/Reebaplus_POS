// daily_report_layout_test.dart
//
// #831 - the daily report screen fits every screen size: a hero card on a
// phone, three tiles over one 720 column on a small tablet, three tiles over
// two card columns (capped at 1080) on a wide screen. Layout and wording only.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';
import 'package:reebaplus_pos/features/dashboard/screens/daily_reconciliation_detail_screen.dart';
import 'package:reebaplus_pos/features/dashboard/widgets/report_parts.dart';
import 'package:reebaplus_pos/features/dashboard/widgets/report_summary_parts.dart';

import '../helpers/screen_harness.dart';
import 'report_fixture.dart';

const _grants = {'reports.daily_reconciliation', 'sales.make'};

Widget _detail() => DailyReconciliationDetailScreen(
  start: DateTime(2026, 7, 14),
  endExclusive: DateTime(2026, 7, 15),
  grouping: ReconGrouping.day,
  title: 'Tue, 14 Jul 2026',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 3,
      businessName: 'Stallion Global',
      businessType: 'Beverage distributor',
    );
  });
  tearDown(() => env.dispose());

  Future<void> pump(
    WidgetTester tester,
    Size size, {
    double scale = 1.0,
    int roleRank = GateTier.ceo,
    String roleSlug = 'ceo',
  }) async {
    await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: EdgeInsets.zero,
      screen: _detail(),
      bottomNavHeight: size.width >= 600 ? kBottomNavBodyHeight : 0,
      grantedKeys: _grants,
      roleRank: roleRank,
      roleSlug: roleSlug,
      textScaler: TextScaler.linear(scale),
      theme: AppTheme.light(),
      overrides: reportOverrides(env, kReportDay),
      settle: false,
    );
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  for (final size in const [
    Size(360, 800),
    Size(844, 390),
    Size(800, 1280),
    Size(1280, 800),
    Size(1920, 1080),
  ]) {
    for (final scale in size.width == 360 ? [1.0, 1.3] : [1.0]) {
      testWidgets(
        'pumps clean at ${size.width.toInt()}x${size.height.toInt()} @$scale',
        (tester) async {
          await pump(tester, size, scale: scale);
          expect(tester.takeException(), isNull);
          expect(find.text('Sales'), findsOneWidget);
          expect(find.text('Best sellers'), findsOneWidget);
          await disposeScreen(tester);
        },
      );
    }
  }

  testWidgets('phone: hero card, cards stacked in one column', (tester) async {
    await pump(tester, const Size(360, 800));
    expect(find.byType(ReportHeroCard), findsOneWidget);
    expect(find.byType(ReportSummaryTiles), findsNothing);
    expect(
      tester.getTopLeft(find.text('Best sellers')).dy,
      greaterThan(tester.getTopLeft(find.text('Sales')).dy),
    );
    await disposeScreen(tester);
  });

  testWidgets('small tablet: three tiles, one column capped at 720', (
    tester,
  ) async {
    await pump(tester, const Size(800, 1280));
    expect(find.byType(ReportHeroCard), findsNothing);
    expect(find.byType(ReportSummaryTiles), findsOneWidget);
    expect(
      tester.getSize(find.byType(ReportSummaryTiles)).width,
      lessThanOrEqualTo(kContentMaxWidth),
    );
    expect(
      tester.getTopLeft(find.text('Best sellers')).dx,
      tester.getTopLeft(find.text('Sales')).dx,
      reason: 'one column',
    );
    await disposeScreen(tester);
  });

  testWidgets('wide: two card columns, Download button, capped at 1080', (
    tester,
  ) async {
    await pump(tester, const Size(1920, 1080));
    final tiles = find.byType(ReportSummaryTiles);
    expect(tiles, findsOneWidget);
    expect(
      tester.getSize(tiles).width,
      lessThanOrEqualTo(kReconDetailMaxWidth),
    );
    // Left column: Sales; right column: Cash.
    expect(
      tester.getTopLeft(find.text('Cash')).dx,
      greaterThan(tester.getTopLeft(find.text('Sales')).dx),
    );
    expect(find.text('Download'), findsOneWidget);
    expect(find.byKey(ReportKeys.export), findsOneWidget);
    // "Business worth" spans under both columns.
    expect(
      tester.getTopLeft(find.text('What your business is worth right now')).dy,
      greaterThan(tester.getTopLeft(find.text('Cash')).dy),
    );
    // Centred: the same margin on both sides of the content.
    final left = tester.getTopLeft(tiles).dx;
    final right = 1920 - tester.getTopRight(tiles).dx;
    expect((left - right).abs(), lessThan(100));
    await disposeScreen(tester);
  });

  testWidgets('a Manager gets the sales header only, no profit or cash', (
    tester,
  ) async {
    await pump(
      tester,
      const Size(1280, 800),
      roleRank: GateTier.manager,
      roleSlug: 'manager',
    );
    expect(find.text('Profit'), findsNothing);
    expect(find.text('Cash received'), findsNothing);
    expect(find.text('Total sold'), findsWidgets);
    expect(tester.takeException(), isNull);
    await disposeScreen(tester);
  });
}
