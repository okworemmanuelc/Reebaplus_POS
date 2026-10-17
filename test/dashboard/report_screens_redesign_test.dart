// #413 (PRD #346 Wave 2 B, PR 1): the restyled Reports hub, Sales Detail,
// Profit, Crate Deposits and Supplier Accounts reports. Restyle only: these
// pin that every control, figure and permission rule still behaves as before
// and that nothing overflows at the supported sizes (realistic insets).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/features/dashboard/screens/crate_deposits_report_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/profit_report_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/reports_hub_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/sales_detail_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/supplier_accounts_report_screen.dart';
import 'package:reebaplus_pos/features/dashboard/widgets/report_parts.dart';

import '../helpers/screen_harness.dart';
import 'report_fixture.dart';

const _minTap = kMinInteractiveDimension - 0.01;

const _all = {
  'sales.make',
  'reports.view_approvals',
  'reports.daily_reconciliation',
  'reports.crate_deposits',
  'reports.supplier_accounts',
  'reports.see_profit',
  'reports.see_cost_prices',
  'suppliers.manage',
};

const _sizes = <(String, Size, EdgeInsets)>[
  ('360x640', Size(360, 640), EdgeInsets.only(top: 24, bottom: 24)),
  ('390x844', Size(390, 844), EdgeInsets.only(top: 24, bottom: 24)),
  ('844x390', Size(844, 390), EdgeInsets.only(top: 24, right: 48)),
  ('800x1280', Size(800, 1280), EdgeInsets.zero),
  ('1280x800', Size(1280, 800), EdgeInsets.zero),
];

void main() {
  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 3,
      businessName: 'Stallion Global',
      businessType: 'Beverage distributor',
    );
    await seedReportCustomers(env);
  });
  tearDown(() => env.dispose());

  Future<void> pump(
    WidgetTester tester,
    Widget screen, {
    Size size = const Size(390, 844),
    EdgeInsets padding = const EdgeInsets.only(top: 24, bottom: 24),
    Set<String> grants = _all,
    int roleRank = GateTier.ceo,
    TextScaler? textScaler,
    ThemeData? theme,
  }) async {
    await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: padding,
      screen: screen,
      bottomNavHeight: size.width >= 600 ? kBottomNavBodyHeight : 0,
      grantedKeys: grants,
      roleRank: roleRank,
      textScaler: textScaler,
      theme: theme ?? AppTheme.light(),
      overrides: reportOverrides(env, DateTime.now()),
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
    'hub': () => const ReportsHubScreen(),
    'sales detail': () => SalesDetailScreen(
      orders: sampleReportOrders(env, kReportDay),
      mode: 'profit',
      period: 'Today',
    ),
    'profit': () => const ProfitReportScreen(),
    'crate deposits': () => const CrateDepositsReportScreen(),
    'supplier accounts': () => const SupplierAccountsReportScreen(),
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

    testWidgets('${entry.key} caps its column at the batch width on 1280', (
      tester,
    ) async {
      await pump(
        tester,
        entry.value(),
        size: const Size(1280, 800),
        padding: EdgeInsets.zero,
      );
      expect(tester.takeException(), isNull);
      // The top bar spans the width; every card is at most 720 wide.
      final cards = find.byType(ReportCard);
      if (cards.evaluate().isNotEmpty) {
        expect(tester.getSize(cards.first).width, lessThanOrEqualTo(720));
      }
      await disposeScreen(tester);
    });
  }

  group('Reports hub', () {
    testWidgets('shows a tappable card per report for a CEO', (tester) async {
      await pump(tester, const ReportsHubScreen());
      for (final title in [
        'Approvals',
        'Daily Reconciliation',
        'Crate Deposits',
        'Supplier Accounts',
        'Profit Report',
      ]) {
        final card = find.byKey(reportCardKey(title));
        expect(card, findsOneWidget, reason: title);
        expect(tester.getSize(card).height, greaterThanOrEqualTo(_minTap));
      }
      await disposeScreen(tester);
    });

    testWidgets('hides the cards a lower role has no permission for', (
      tester,
    ) async {
      await pump(
        tester,
        const ReportsHubScreen(),
        grants: const {'sales.make'},
        roleRank: GateTier.cashier,
      );
      for (final title in [
        'Daily Reconciliation',
        'Crate Deposits',
        'Supplier Accounts',
        'Profit Report',
      ]) {
        expect(find.byKey(reportCardKey(title)), findsNothing, reason: title);
      }
      await disposeScreen(tester);
    });
  });

  group('Sales Detail', () {
    testWidgets('keeps the netted headline and the discount chip', (
      tester,
    ) async {
      await pump(
        tester,
        SalesDetailScreen(
          orders: sampleReportOrders(env, kReportDay),
          mode: 'sales',
          period: 'Today',
        ),
      );
      // 12 x 4,500 + 6 x 8,200 + 3 x 15,000 + 2 x 3,000 = 154,200; less the
      // 2,500 discount = 151,700.
      expect(find.text('Total Sales Breakdown'), findsOneWidget);
      expect(find.text(formatCurrency(1517000 / 10)), findsWidgets);
      expect(
        find.text('Less discounts: ${formatCurrency(2500)}'),
        findsOneWidget,
      );
      expect(find.text('Ice block'), findsOneWidget);
      expect(find.text('PROFIT'), findsNothing); // sales mode: no profit column
      await disposeScreen(tester);
    });

    testWidgets('profit mode adds the PROFIT column and the export button', (
      tester,
    ) async {
      await pump(
        tester,
        SalesDetailScreen(
          orders: sampleReportOrders(env, kReportDay),
          mode: 'profit',
          period: 'Today',
        ),
      );
      expect(find.text('Net Profit Breakdown'), findsOneWidget);
      expect(find.text('PROFIT'), findsOneWidget);
      expect(find.byKey(ReportKeys.export), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('empty orders show the empty state, export disabled', (
      tester,
    ) async {
      await pump(
        tester,
        const SalesDetailScreen(orders: [], mode: 'sales', period: 'Today'),
      );
      expect(find.text('No sales data for this period'), findsOneWidget);
      final export = tester.widget<IconButton>(
        find.descendant(
          of: find.byKey(ReportKeys.export),
          matching: find.byType(IconButton),
        ),
      );
      expect(export.onPressed, isNull);
      await disposeScreen(tester);
    });
  });

  group('Profit report', () {
    testWidgets('shows cost of goods with see_cost_prices', (tester) async {
      await pump(tester, const ProfitReportScreen());
      expect(find.text('Gross Profit'), findsOneWidget);
      expect(find.textContaining('Cost of goods:'), findsOneWidget);
      expect(find.textContaining('Margin:'), findsOneWidget);
      expect(find.text('By product'), findsOneWidget);
      expect(find.byKey(ReportKeys.period), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('hides cost of goods without see_cost_prices', (tester) async {
      await pump(
        tester,
        const ProfitReportScreen(),
        grants: const {'sales.make', 'reports.see_profit'},
      );
      expect(find.text('Gross Profit'), findsOneWidget);
      expect(find.textContaining('Cost of goods:'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('notes the quick sale that has no buying price', (
      tester,
    ) async {
      await pump(tester, const ProfitReportScreen());
      expect(find.textContaining('Profit excludes 2 items'), findsOneWidget);
      await disposeScreen(tester);
    });
  });

  group('Crate Deposits report', () {
    testWidgets('shows the identity, the breakdown and the holders', (
      tester,
    ) async {
      await pump(tester, const CrateDepositsReportScreen());
      expect(find.text('Deposits held now'), findsOneWidget);
      expect(find.text('Held = Taken − Refunded − Kept'), findsOneWidget);
      expect(find.text('By customer'), findsOneWidget);
      expect(find.text('Adaeze Okafor'), findsOneWidget);
      expect(find.byKey(ReportKeys.export), findsOneWidget);
      await disposeScreen(tester);
    });
  });

  group('Supplier Accounts report', () {
    testWidgets('one card per supplier with Owed / Prepaid / Settled', (
      tester,
    ) async {
      await pump(tester, const SupplierAccountsReportScreen());
      expect(find.text('Lagos Bottling Co'), findsOneWidget);
      expect(find.textContaining('Owed'), findsOneWidget);
      expect(find.textContaining('Prepaid'), findsOneWidget);
      expect(find.text('Settled'), findsOneWidget);
      await disposeScreen(tester);
    });
  });

  testWidgets('back button on a pushed report pops', (tester) async {
    await pump(tester, const ReportsHubScreen());
    await tester.tap(find.byKey(reportCardKey('Profit Report')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(ProfitReportScreen), findsOneWidget);
    expect(
      tester.getSize(find.byKey(ReportKeys.back).last).shortestSide,
      greaterThanOrEqualTo(_minTap),
    );
    await tester.tap(find.byKey(ReportKeys.back).last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(ProfitReportScreen), findsNothing);
    await disposeScreen(tester);
  });
}
