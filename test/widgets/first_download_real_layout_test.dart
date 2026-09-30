// first_download_real_layout_test.dart
//
// PRD #313 slice 3 — the shimmer placeholders are gone. While the first
// download on a phone is still running, Home, POS, Inventory and Reports show
// their real layout at once, and their list areas stay blank: no "No … yet"
// message and no call to action, because an empty list says nothing about the
// business until the download has finished.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/first_download_state.dart';
import 'package:reebaplus_pos/features/dashboard/screens/home_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/reports_hub_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/inventory_screen.dart';
import 'package:reebaplus_pos/features/pos/screens/pos_home_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/first_run_empty_state.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const grants = {
    'sales.make',
    'stock.view',
    'products.add',
    'stock.add',
    'suppliers.manage',
    'reports.daily_reconciliation',
  };

  late ScreenTestEnvironment env;

  // A phone that has downloaded its store but nothing else yet.
  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessType: 'Beverage distributor',
    );
  });

  tearDown(() async {
    await env.dispose();
  });

  // Drift streams deliver in real time; the pumps then let the frames land.
  Future<void> deliver(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> pump(
    WidgetTester tester,
    Widget screen, {
    required bool downloading,
    Size size = pixel7Portrait,
    String roleSlug = 'ceo',
    int roleRank = GateTier.ceo,
  }) async {
    await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: screen,
      grantedKeys: grants,
      roleSlug: roleSlug,
      roleRank: roleRank,
      overrides: [
        firstDownloadInProgressProvider.overrideWithValue(downloading),
      ],
      settle: false,
    );
    await deliver(tester);
  }

  group('while the first download is running', () {
    testWidgets('Home shows its real layout and no empty-list message',
        (tester) async {
      await pump(
        tester,
        const HomeScreen(),
        downloading: true,
        size: tablet109Portrait,
      );

      expect(find.text('Total Sales'), findsOneWidget);
      expect(find.textContaining('No staff sales'), findsNothing);

      await disposeScreen(tester);
    });

    testWidgets('Home product breakdown opens to nothing, not "none yet"',
        (tester) async {
      await pump(
        tester,
        const HomeScreen(),
        downloading: true,
        roleSlug: 'cashier',
        roleRank: GateTier.cashier,
      );

      await tester.tap(find.text('Tap to see breakdown by manufacturer'));
      await deliver(tester);
      expect(find.textContaining('yet'), findsNothing);

      await disposeScreen(tester);
    });

    testWidgets('POS shows its real layout and a blank grid', (tester) async {
      await pump(tester, const PosHomeScreen(), downloading: true);

      expect(find.byKey(kPosScrollSurfaceKey), findsOneWidget);
      expect(find.byType(FirstRunEmptyState), findsOneWidget);
      expect(find.textContaining('yet'), findsNothing);
      expect(find.byType(AppButton), findsNothing);

      await disposeScreen(tester);
    });

    testWidgets('Inventory shows its tabs and a blank list on each',
        (tester) async {
      await pump(tester, const InventoryScreen(), downloading: true);

      // Products tab.
      expect(find.byType(FirstRunEmptyState), findsOneWidget);
      expect(find.textContaining('yet'), findsNothing);

      await tester.tap(find.text('Suppliers'));
      await deliver(tester);
      expect(find.widgetWithText(AppButton, 'Add Supplier'), findsOneWidget);
      expect(find.text('No suppliers added yet'), findsNothing);

      await tester.tap(find.text('Empty Crates'));
      await deliver(tester);
      expect(find.text('No manufacturers to track'), findsNothing);

      await disposeScreen(tester);
    });

    testWidgets('Reports shows its report cards', (tester) async {
      await pump(tester, const ReportsHubScreen(), downloading: true);

      expect(find.text('Business Reports'), findsOneWidget);
      expect(find.text('Daily Reconciliation'), findsOneWidget);

      await disposeScreen(tester);
    });
  });

  group('once the first download has finished', () {
    testWidgets('Home says when there are no staff sales', (tester) async {
      await pump(
        tester,
        const HomeScreen(),
        downloading: false,
        size: tablet109Portrait,
      );

      expect(find.textContaining('No staff sales'), findsOneWidget);

      await disposeScreen(tester);
    });

    testWidgets('Inventory says when a tab has nothing in it', (tester) async {
      await pump(tester, const InventoryScreen(), downloading: false);

      expect(find.textContaining('yet'), findsWidgets);

      await tester.tap(find.text('Suppliers'));
      await deliver(tester);
      expect(find.text('No suppliers added yet'), findsOneWidget);

      await tester.tap(find.text('Empty Crates'));
      await deliver(tester);
      expect(find.text('No manufacturers to track'), findsOneWidget);

      await disposeScreen(tester);
    });
  });
}
