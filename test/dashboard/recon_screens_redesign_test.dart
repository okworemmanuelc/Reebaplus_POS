// #413 (PRD #346 Wave 2 B, PR 2): the restyled Daily Reconciliation list and
// detail, and the changed-since-review badge. Restyle only: the figures come
// from the unchanged recon_data.dart; these pin that every control, card and
// permission rule still behaves as before and that nothing overflows at the
// supported sizes (realistic insets).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';
import 'package:reebaplus_pos/features/dashboard/screens/daily_reconciliation_detail_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/daily_reconciliation_list_screen.dart';
import 'package:reebaplus_pos/features/dashboard/widgets/changed_since_review_badge.dart';
import 'package:reebaplus_pos/features/dashboard/widgets/report_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

import '../helpers/screen_harness.dart';
import 'report_fixture.dart';

const _grants = {'reports.daily_reconciliation', 'sales.make'};

const _sizes = <(String, Size, EdgeInsets)>[
  ('360x640', Size(360, 640), EdgeInsets.only(top: 24, bottom: 24)),
  ('390x844', Size(390, 844), EdgeInsets.only(top: 24, bottom: 24)),
  ('844x390', Size(844, 390), EdgeInsets.only(top: 24, right: 48)),
  ('800x1280', Size(800, 1280), EdgeInsets.zero),
  ('1280x800', Size(1280, 800), EdgeInsets.zero),
];

Widget _detail({ReconGrouping grouping = ReconGrouping.day}) =>
    DailyReconciliationDetailScreen(
      start: DateTime(2026, 7, 14),
      endExclusive: DateTime(2026, 7, 15),
      grouping: grouping,
      title: 'Tue, 14 Jul 2026',
    );

void main() {
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
    Widget screen, {
    Size size = const Size(390, 844),
    EdgeInsets padding = const EdgeInsets.only(top: 24, bottom: 24),
    int roleRank = GateTier.ceo,
    String roleSlug = 'ceo',
    TextScaler? textScaler,
  }) async {
    await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: padding,
      screen: screen,
      bottomNavHeight: size.width >= 600 ? kBottomNavBodyHeight : 0,
      grantedKeys: _grants,
      roleRank: roleRank,
      roleSlug: roleSlug,
      textScaler: textScaler,
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

  final screens = <String, Widget Function()>{
    'list': () => const DailyReconciliationListScreen(),
    'detail': () => _detail(),
  };

  for (final entry in screens.entries) {
    for (final (name, size, padding) in _sizes) {
      for (final scale in [1.0, 1.3]) {
        testWidgets('${entry.key} fits at $name @$scale', (tester) async {
          await pump(
            tester,
            entry.value(),
            size: size,
            padding: padding,
            textScaler: TextScaler.linear(scale),
          );
          expect(tester.takeException(), isNull);
          expect(find.byKey(ReportKeys.topBar), findsOneWidget);
          await disposeScreen(tester);
        });
      }
    }
  }

  group('Recon list', () {
    testWidgets('renders the period picker, export and a day card', (
      tester,
    ) async {
      await pump(tester, const DailyReconciliationListScreen());
      expect(find.text('Daily Reconciliation'), findsOneWidget);
      expect(find.byKey(ReportKeys.period), findsOneWidget);
      expect(find.byKey(ReportKeys.export), findsOneWidget);
      expect(find.textContaining('items sold'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('tapping a day opens its reconciliation', (tester) async {
      await pump(tester, const DailyReconciliationListScreen());
      await tester.tap(find.textContaining('items sold'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(find.byType(DailyReconciliationDetailScreen), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('caps its column at 720 on 1280', (tester) async {
      await pump(
        tester,
        const DailyReconciliationListScreen(),
        size: const Size(1280, 800),
        padding: EdgeInsets.zero,
      );
      final card = find.byType(InkWell).last;
      expect(tester.getSize(card).width, lessThanOrEqualTo(720));
      await disposeScreen(tester);
    });
  });

  group('Recon detail', () {
    testWidgets('a CEO sees the profit and cash-movement cards', (
      tester,
    ) async {
      await pump(tester, _detail());
      expect(find.text('Sales summary'), findsOneWidget);
      expect(find.text('Profit & Loss'), findsOneWidget);
      expect(find.byKey(ReportKeys.export), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('a Manager never sees the cost-wall cards', (tester) async {
      await pump(
        tester,
        _detail(),
        roleRank: GateTier.manager,
        roleSlug: 'manager',
      );
      expect(find.text('Sales summary'), findsOneWidget);
      expect(find.text('Profit & Loss'), findsNothing);
      expect(find.text('Debts & expenses'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('has no cash balance anywhere (Hard Rule #8)', (tester) async {
      await pump(tester, _detail());
      expect(find.textContaining('Cash balance'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('cards sit side by side from 900 wide, stacked below', (
      tester,
    ) async {
      await pump(
        tester,
        _detail(),
        size: const Size(1280, 800),
        padding: EdgeInsets.zero,
      );
      final sales = tester.getTopLeft(find.text('Sales summary'));
      final pl = tester.getTopLeft(find.text('Stock reconciliation (at cost)'));
      expect(pl.dx, isNot(equals(sales.dx)), reason: 'two columns');
      await disposeScreen(tester);

      await pump(tester, _detail(), size: const Size(800, 1280));
      final sales2 = tester.getTopLeft(find.text('Sales summary'));
      final pl2 = tester.getTopLeft(
        find.text('Stock reconciliation (at cost)'),
      );
      expect(pl2.dx, equals(sales2.dx), reason: 'one column under 900');
      await disposeScreen(tester);
    });

    testWidgets('a week drills down through the breakdown', (tester) async {
      await pump(
        tester,
        DailyReconciliationDetailScreen(
          start: DateTime(2026, 7, 13),
          endExclusive: DateTime(2026, 7, 20),
          grouping: ReconGrouping.week,
          title: 'Week of 13 Jul 2026',
        ),
        size: const Size(390, 3000),
      );
      expect(find.textContaining('Breakdown by day'), findsOneWidget);
      await disposeScreen(tester);
    });
  });

  testWidgets('the badge is a warning TagPill with its label', (tester) async {
    await pump(
      tester,
      const Scaffold(
        body: ChangedSinceReviewBadge(label: 'Total sales + ₦2,000'),
      ),
    );
    final pill = tester.widget<TagPill>(find.byType(TagPill));
    expect(pill.tone, TagPillTone.warning);
    expect(find.text('Total sales + ₦2,000'), findsOneWidget);
    await disposeScreen(tester);
  });
}
