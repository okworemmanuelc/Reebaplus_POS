// Visual goldens for the Stock Approvals screen (#413, PRD #346 Wave 2 B,
// PR 3). No mockup: built from the report parts and the Wave 1 / batch A
// patterns. One stock adjustment, one Quick Sale and one crate deposit, with
// the first card of each kind collapsed. Every date is fixed.
//
// 390x844 (gesture nav), 844x390 with a 24dp status bar and 3-button
// navigation on the right, 800x1280 and 1280x800, light + dark. Sample data
// only. Regenerate:
//
//     flutter test --update-goldens test/redesign/stock_approvals_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/dashboard/screens/stock_approvals_screen.dart';

import '../dashboard/approvals_fixture.dart';
import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 3,
      businessName: 'Stallion Global',
      businessType: 'Beverage distributor',
      manufacturerCount: 1,
    );
    await env.db.customStatement(
      "UPDATE stores SET name = 'Abuja HQ' WHERE id = '${env.storeId}'",
    );
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

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    final theme = brightness == Brightness.light
        ? AppTheme.light()
        : AppTheme.dark();

    for (final (sizeName, size, insets) in const [
      ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
      ('844x390_insets', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
      ('800x1280', Size(800, 1280), FakeViewPadding()),
      ('1280x800', Size(1280, 800), FakeViewPadding()),
    ]) {
      testWidgets('stock_approvals $sizeName $themeName', (tester) async {
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
          screen: const StockApprovalsScreen(),
          bottomNavHeight: size.width >= 600 ? kBottomNavBodyHeight : 0,
          grantedKeys: const {
            'sales.make',
            'reports.view_approvals',
            'expenses.approve',
          },
          roleRank: 0,
          theme: theme,
          overrides: [
            currentBusinessNameProvider.overrideWithValue('Stallion Global'),
            viewerScopedPendingStockRequestsProvider.overrideWith(
              (ref) => [
                approvalStockReq(env, id: 'r1', diff: 24),
                approvalStockReq(env, id: 'r2', diff: -6),
              ],
            ),
            viewerScopedPendingQuickSaleRequestsProvider.overrideWith(
              (ref) => [approvalQuickReq(env)],
            ),
            viewerScopedPendingCrateDepositsProvider.overrideWith(
              (ref) => [
                approvalCrateReq(env),
                approvalCrateReq(env, id: 'req-crate-2', kind: 'return'),
              ],
            ),
          ],
        );
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(StockApprovalsScreen),
          matchesGoldenFile(
            'goldens/stock_approvals_${sizeName}_$themeName.png',
          ),
        );
        await disposeScreen(tester);
      });
    }
  }
}
