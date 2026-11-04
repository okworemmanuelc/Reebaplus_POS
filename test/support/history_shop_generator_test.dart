// #682 — the generated history shop builds at 6 / 12 / 24 months and the app's
// existing report computations run on it without errors.
//
// The default run keeps to a light 6-month shop (a few sales a day) so the
// suite stays quick. The 12 and 24 month shops, at full volume, are built by
// the benchmark (test/benchmark/history_benchmark_test.dart, tag `benchmark`).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/dashboard/screens/profit_report_screen.dart';

import '../helpers/screen_harness.dart';
import 'history_reports.dart';
import 'history_shop_generator.dart';

void main() {
  // Determinism: same months + seed => same counts.
  test(
    'the generator is deterministic for a seed',
    () async {
      const spec = HistoryShopSpec(
        months: 1,
        minSalesPerDay: 2,
        maxSalesPerDay: 3,
        productCount: 8,
        customerCount: 5,
      );
      final a = await buildHistoryShop(newHistoryDb(), spec);
      final b = await buildHistoryShop(newHistoryDb(), spec);
      expect(a.counts, b.counts);
      await a.close();
      await b.close();
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  group('a 6-month shop', () {
    late HistoryShop shop;
    late ScreenTestEnvironment env;

    setUpAll(() async {
      shop = await buildHistoryShop(
        newHistoryDb(),
        const HistoryShopSpec(
          months: 6,
          minSalesPerDay: 2,
          maxSalesPerDay: 5,
          productCount: 20,
          customerCount: 15,
        ),
      );
    });
    tearDownAll(() => shop.close());
    setUp(() async {
      env = await setupScreenTestEnvironment(
        productCount: 3,
        businessName: 'History Shop',
      );
    });
    tearDown(() => env.dispose());

    test('has every kind of history and the Reconciliation runs', () async {
      final c = shop.counts;
      for (final k in const [
        'sales',
        'saleLines',
        'cancelled',
        'vanSales',
        'depositsHeld',
        'expenses',
        'adjustments',
        'stockCounts',
      ]) {
        expect(c[k], greaterThan(0), reason: k);
      }

      final lists = await loadReconLists(shop.db);
      expect(lists.orders, isNotEmpty);
      expect(lists.payments, isNotEmpty);
      expect(lists.stockTxns, isNotEmpty);

      final p = reconPeriods(DateTime(2026, 10, 15));
      for (final (s, e) in [p.day, p.week, p.month]) {
        final d = reconFor(lists, s, e);
        expect(d.totalSalesKobo, isNonNegative);
      }
      // The month carries real sales.
      final month = reconFor(lists, p.month.$1, p.month.$2);
      expect(month.totalSalesKobo, greaterThan(0));
      expect(month.itemsSold, greaterThan(0));
    });

    test(
      'a return keeps its original day: cancels dated after the sale',
      () async {
        final rows = await shop.db
            .customSelect(
              "SELECT COUNT(*) AS n FROM orders "
              "WHERE status = 'cancelled' AND cancelled_at > created_at + 3600",
            )
            .getSingle();
        expect(rows.data['n'] as int, greaterThan(0));
      },
    );

    test('Product Details derived data runs for the busy product', () async {
      final days = await shop.db.ordersDao.getProductSalesByDay(
        shop.busiestProductId,
        now: DateTime(2026, 10, 31),
      );
      expect(days, isNotEmpty);
    });

    testWidgets('the Profit report opens on the shop', (tester) async {
      final orders = (await tester.runAsync(
        () => shop.db.ordersDao.watchAllOrdersWithItems().first,
      ))!;
      await pumpScreen(
        tester,
        env: env,
        size: const Size(390, 844),
        padding: const EdgeInsets.only(top: 24, bottom: 24),
        screen: const ProfitReportScreen(),
        bottomNavHeight: 0,
        grantedKeys: const {
          'sales.make',
          'reports.see_profit',
          'reports.see_cost_prices',
        },
        roleRank: GateTier.ceo,
        theme: AppTheme.light(),
        overrides: [
          periodOrdersProvider.overrideWith((ref, w) => Stream.value(orders)),
        ],
        settle: false,
      );
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(find.byType(ProfitReportScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
