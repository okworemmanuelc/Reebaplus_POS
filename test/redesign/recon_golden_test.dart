// Visual goldens for the Dashboard report screens (#413, PRD #346 Wave 2 B,
// PR 2): Daily Reconciliation list and detail. No mockup: built from the shared parts and the Wave 1 / batch A
// patterns (the Customers top bar and the batch-wide 720 list cap).
//
// 390x844 (gesture nav), 844x390 with a 24dp status bar and 3-button
// navigation on the right, 800x1280 and 1280x800 (the harness leaves the
// rail's width blank at 600dp+), light + dark. Every date is fixed.
//
// Sample data only: business "Stallion Global", store "Abuja HQ". Regenerate:
//
//     flutter test --update-goldens test/redesign/recon_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';
import 'package:reebaplus_pos/features/dashboard/screens/daily_reconciliation_detail_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/daily_reconciliation_list_screen.dart';

import '../dashboard/report_fixture.dart';
import '../helpers/screen_harness.dart';

const _grants = {
  'sales.make',
  'reports.view_approvals',
  'reports.daily_reconciliation',
  'reports.crate_deposits',
  'reports.supplier_accounts',
  'reports.see_profit',
  'reports.see_cost_prices',
  'suppliers.manage',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 3,
      businessName: 'Stallion Global',
      businessType: 'Beverage distributor',
    );
    await env.db.customStatement(
      "UPDATE stores SET name = 'Abuja HQ' WHERE id = '${env.storeId}'",
    );
    await seedReportCustomers(env);
  });
  tearDown(() => env.dispose());

  setUpAll(() => WidgetsApp.debugAllowBannerOverride = false);
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  void setInsets(WidgetTester tester, FakeViewPadding insets) {
    tester.view.padding = insets;
    tester.view.viewPadding = insets;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
  }

  final screens = <String, Widget Function()>{
    'recon_list': () => const DailyReconciliationListScreen(),
    'recon_detail': () => DailyReconciliationDetailScreen(
      start: DateTime(2026, 7, 14),
      endExclusive: DateTime(2026, 7, 15),
      grouping: ReconGrouping.day,
      title: 'Tue, 14 Jul 2026',
    ),
  };

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    final theme = brightness == Brightness.light
        ? AppTheme.light()
        : AppTheme.dark();

    for (final entry in screens.entries) {
      for (final (sizeName, size, insets) in const [
        ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
        ('844x390_insets', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
        ('800x1280', Size(800, 1280), FakeViewPadding()),
        ('1280x800', Size(1280, 800), FakeViewPadding()),
      ]) {
        testWidgets('${entry.key} $sizeName $themeName', (tester) async {
          setInsets(tester, insets);
          await pumpScreen(
            tester,
            env: env,
            size: size,
            padding: EdgeInsets.fromLTRB(
              insets.left,
              insets.top,
              insets.right,
              insets.bottom,
            ),
            screen: entry.value(),
            bottomNavHeight: size.width >= 600 ? kBottomNavBodyHeight : 0,
            grantedKeys: _grants,
            roleRank: GateTier.ceo,
            theme: theme,
            overrides: [
              currentBusinessNameProvider.overrideWithValue('Stallion Global'),
              ...reportOverrides(env, kReportDay),
            ],
            settle: false,
          );
          for (var i = 0; i < 8; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 250));
          }
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byType(
              entry.key == 'recon_list'
                  ? DailyReconciliationListScreen
                  : DailyReconciliationDetailScreen,
            ),
            matchesGoldenFile(
              'goldens/${entry.key}_${sizeName}_$themeName.png',
            ),
          );
          await disposeScreen(tester);
        });
      }
    }
  }
}
