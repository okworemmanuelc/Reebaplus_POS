import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/dashboard/screens/crate_deposits_report_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/daily_reconciliation_list_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/profit_report_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/reports_hub_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/stock_approvals_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/supplier_accounts_report_screen.dart';
import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

void main() {
  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(businessType: 'Beverage distributor');
  });

  Future<void> teardownScreen(WidgetTester tester) async {
    await disposeScreen(tester);
    await tester.runAsync(() => env.dispose());
  }

  const grantedAll = {
    'sales.make',
    'reports.view_approvals',
    'reports.daily_reconciliation',
    'reports.crate_deposits',
    'reports.supplier_accounts',
    'reports.see_profit',
    'suppliers.manage',
  };

  group('ReportsHubScreen viewport layout & content visibility (Issue #257)', () {
    testWidgets('androidCompactLandscape (800x360) shows complete report card',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: androidCompactLandscape,
        grantedKeys: grantedAll,
        roleRank: 0,
        screen: const ReportsHubScreen(),
      );

      expectNoOverflow(tester);
      final atRest = await expectContentRowVisible(
        tester,
        find.byKey(reportCardKey('Approvals')),
        minimum: 1,
      );
      expect(atRest, greaterThanOrEqualTo(1));
      await teardownScreen(tester);
    });

    testWidgets('phoneSe1Portrait (320x568) shows complete report card',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: phoneSe1Portrait,
        grantedKeys: grantedAll,
        roleRank: 0,
        screen: const ReportsHubScreen(),
      );

      expectNoOverflow(tester);
      final atRest = await expectContentRowVisible(
        tester,
        find.byKey(reportCardKey('Approvals')),
        minimum: 1,
      );
      expect(atRest, greaterThanOrEqualTo(1));
      await teardownScreen(tester);
    });

    testWidgets('pixel7Landscape (915x412) shows complete report card',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Landscape,
        grantedKeys: grantedAll,
        roleRank: 0,
        screen: const ReportsHubScreen(),
      );

      expectNoOverflow(tester);
      final atRest = await expectContentRowVisible(
        tester,
        find.byKey(reportCardKey('Approvals')),
        minimum: 1,
      );
      expect(atRest, greaterThanOrEqualTo(1));
      await teardownScreen(tester);
    });

    testWidgets('pixel7Portrait (412x915) comfortable control shows complete card',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        grantedKeys: grantedAll,
        roleRank: 0,
        screen: const ReportsHubScreen(),
      );

      expectNoOverflow(tester);
      final atRest = await expectContentRowVisible(
        tester,
        find.byKey(reportCardKey('Approvals')),
        minimum: 1,
      );
      expect(atRest, greaterThanOrEqualTo(1));
      await teardownScreen(tester);
    });

    testWidgets('phoneSe1Portrait (320x568) survives max text scale (1.3)',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: phoneSe1Portrait,
        grantedKeys: grantedAll,
        roleRank: 0,
        textScaler: const TextScaler.linear(1.3),
        screen: const ReportsHubScreen(),
      );

      expectNoOverflow(tester);
      final atRest = await expectContentRowVisible(
        tester,
        find.byKey(reportCardKey('Approvals')),
        minimum: 1,
      );
      expect(atRest, greaterThanOrEqualTo(1));
      await teardownScreen(tester);
    });

    testWidgets('androidCompactLandscape (800x360) survives max text scale (1.3)',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: androidCompactLandscape,
        grantedKeys: grantedAll,
        roleRank: 0,
        textScaler: const TextScaler.linear(1.3),
        screen: const ReportsHubScreen(),
      );

      expectNoOverflow(tester);
      final atRest = await expectContentRowVisible(
        tester,
        find.byKey(reportCardKey('Approvals')),
        minimum: 1,
      );
      expect(atRest, greaterThanOrEqualTo(1));
      await teardownScreen(tester);
    });

    testWidgets('pixel7Landscape (915x412) survives max text scale (1.3)',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Landscape,
        grantedKeys: grantedAll,
        roleRank: 0,
        textScaler: const TextScaler.linear(1.3),
        screen: const ReportsHubScreen(),
      );

      expectNoOverflow(tester);
      final atRest = await expectContentRowVisible(
        tester,
        find.byKey(reportCardKey('Approvals')),
        minimum: 1,
      );
      expect(atRest, greaterThanOrEqualTo(1));
      await teardownScreen(tester);
    });

    testWidgets('pixel7Portrait (412x915) survives max text scale (1.3)',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        grantedKeys: grantedAll,
        roleRank: 0,
        textScaler: const TextScaler.linear(1.3),
        screen: const ReportsHubScreen(),
      );

      expectNoOverflow(tester);
      final atRest = await expectContentRowVisible(
        tester,
        find.byKey(reportCardKey('Approvals')),
        minimum: 1,
      );
      expect(atRest, greaterThanOrEqualTo(1));
      await teardownScreen(tester);
    });

    testWidgets('Approvals card shows pending-count badge when count > 0',
        (tester) async {
      final dummyReq = StockAdjustmentRequestData(
        id: 'req-1',
        businessId: env.businessId,
        productId: 'prod-1',
        storeId: env.storeId,
        quantityDiff: 2,
        reason: 'restock',
        summary: 'Add 2',
        requestedBy: 'user-1',
        status: 'pending',
        approvedBy: null,
        approvedAt: null,
        createdAt: DateTime.now(),
        lastUpdatedAt: DateTime.now(),
      );

      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        grantedKeys: grantedAll,
        roleRank: 0,
        overrides: [
          viewerScopedPendingStockRequestsProvider.overrideWith((ref) => [dummyReq]),
        ],
        screen: const ReportsHubScreen(),
      );

      expectNoOverflow(tester);
      final badgeFinder = find.byKey(const Key('report-card-badge-Approvals'));
      expect(badgeFinder, findsOneWidget);
      expect(find.descendant(of: badgeFinder, matching: find.text('1')), findsOneWidget);
      await teardownScreen(tester);
    });

    testWidgets('tapping report cards navigates to corresponding screens',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        grantedKeys: grantedAll,
        roleRank: 0,
        screen: const ReportsHubScreen(),
      );

      // 1. Approvals
      await tester.tap(find.byKey(reportCardKey('Approvals')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(StockApprovalsScreen), findsOneWidget);
      Navigator.of(tester.element(find.byType(StockApprovalsScreen))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // 2. Daily Reconciliation
      await tester.tap(find.byKey(reportCardKey('Daily Reconciliation')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(DailyReconciliationListScreen), findsOneWidget);
      Navigator.of(tester.element(find.byType(DailyReconciliationListScreen))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // 3. Crate Deposits
      await tester.tap(find.byKey(reportCardKey('Crate Deposits')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(CrateDepositsReportScreen), findsOneWidget);
      Navigator.of(tester.element(find.byType(CrateDepositsReportScreen))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // 4. Supplier Accounts
      await tester.tap(find.byKey(reportCardKey('Supplier Accounts')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(SupplierAccountsReportScreen), findsOneWidget);
      Navigator.of(tester.element(find.byType(SupplierAccountsReportScreen))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // 5. Profit Report
      await tester.tap(find.byKey(reportCardKey('Profit Report')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(ProfitReportScreen), findsOneWidget);
      Navigator.of(tester.element(find.byType(ProfitReportScreen))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await teardownScreen(tester);
    });
  });
}
