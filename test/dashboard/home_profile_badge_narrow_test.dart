// home_profile_badge_narrow_test.dart
//
// #739 (PRD #680 follow-up). Home, Profile and the Reports badge stopped
// loading whole-history lists. This proves, on the #682 history shop, that the
// narrowed reads feed the SAME pure sums and give IDENTICAL figures:
//  - Home: period orders (entry-day window, #549 cancel-day rule) -> Total
//    Sales split, profit entries, pending count; period expenses -> total.
//  - Profile: the page-by-page fold equals the whole-history fold.
//  - Reports badge: the LIMIT 1 latest count equals the max over every session.

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/report_revenue.dart';

import '../support/history_shop_generator.dart';

void main() {
  late HistoryShop shop;
  late List<OrderWithItems> full;
  late List<ExpenseWithCategory> fullExpenses;

  setUpAll(() async {
    shop = await buildHistoryShop(
      newHistoryDb(),
      const HistoryShopSpec(
        months: 13,
        minSalesPerDay: 2,
        maxSalesPerDay: 5,
        productCount: 12,
        customerCount: 8,
      ),
    );
    full = await shop.db.ordersDao.watchAllOrdersWithItems().first;
    fullExpenses = await shop.db.expensesDao.watchAll().first;
  });
  tearDownAll(() => shop.close());

  String d(DateTime x) =>
      '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';

  final nowList = <DateTime>[
    for (var i = 0; i < 20; i++) DateTime(2026, 10, 31 - i, 12),
    DateTime(2026, 10, 1),
    DateTime(2026, 10, 25),
    DateTime(2026, 1, 1),
    DateTime(2025, 12, 31, 23),
  ];
  List<String> periodsFor(DateTime now) => [
    'Today',
    'This Week',
    'This Month',
    'This Year',
    'To Date',
    'Custom:${d(now.subtract(const Duration(days: 6)))}:${d(now)}',
  ];

  group('Home figures', () {
    test(
      'period orders give the same sales, profit entries and expenses',
      () async {
        var sawReturns = false;
        for (final now in nowList) {
          for (final period in periodsFor(now)) {
            final (from, to) = dateRangeForLabel(period, now: now);
            final sub = await shop.db.ordersDao
                .watchAllOrdersWithItems(entryDayFrom: from, entryDayTo: to)
                .first;
            bool inSpan(DateTime x) => isDateInPeriod(x, period, now: now);
            for (final scope in <bool Function(String?)>[
              (s) => true,
              (s) => s == shop.storeId,
            ]) {
              final a = computeSalesSplitKobo(
                full,
                inSpan: inSpan,
                inScope: scope,
              );
              final b = computeSalesSplitKobo(
                sub,
                inSpan: inSpan,
                inScope: scope,
              );
              expect(
                (b.salesKobo, b.returnsKobo, b.netKobo),
                (a.salesKobo, a.returnsKobo, a.netKobo),
                reason: '$period @ $now sales split',
              );
              if (a.returnsKobo != 0) sawReturns = true;
            }
            List<(String, int)> entries(List<OrderWithItems> os) => [
              for (final e in saleDayEntries(os))
                if (inSpan(e.day)) (e.o.order.id, e.sign),
            ]..sort((x, y) => x.$1.compareTo(y.$1));
            expect(
              entries(sub),
              entries(full),
              reason: '$period @ $now entries',
            );

            // Expenses: approved only, by expense date.
            final subExp = await shop.db.expensesDao
                .watchAll(from: from, to: to)
                .first;
            int sum(List<ExpenseWithCategory> xs) => xs
                .where(
                  (e) =>
                      e.expense.status == 'approved' &&
                      inSpan(e.expense.expenseDate),
                )
                .fold(0, (t, e) => t + e.expense.amountKobo);
            expect(
              sum(subExp),
              sum(fullExpenses),
              reason: '$period @ $now expenses',
            );
          }
        }
        expect(
          sawReturns,
          isTrue,
          reason: 'corpus must include later-day cancels',
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'pending count from the pending read equals the full-list count',
      () async {
        for (final storeId in <String?>[null, shop.storeId, shop.vanStoreId]) {
          final expected = full
              .where(
                (o) =>
                    o.order.status == 'pending' &&
                    (storeId == null || o.order.storeId == storeId),
              )
              .length;
          final got =
              (await shop.db.ordersDao
                      .watchPendingOrdersWithItems(storeId: storeId)
                      .first)
                  .length;
          expect(got, expected, reason: 'store $storeId');
        }
      },
    );
  });

  group('Profile', () {
    test(
      'paged fold equals the whole-history fold (small pages)',
      () async {
        final mine = await shop.db.ordersDao
            .watchAllOrdersWithItems(staffId: shop.staffId)
            .first;
        final orders = mine.where((o) => o.order.kind != 'adjustment').toList();
        final expected = (
          orders.length,
          orders.where((o) => o.order.status == 'completed').length,
          computeTotalSalesKobo(mine),
        );
        for (final pageSize in [7, 200, 100000]) {
          var total = 0, completed = 0, sales = 0, seen = 0;
          await shop.db.ordersDao.readStaffOrdersInPages(shop.staffId, (page) {
            seen += page.length;
            final os = page.where((o) => o.order.kind != 'adjustment');
            total += os.length;
            completed += os.where((o) => o.order.status == 'completed').length;
            sales += computeTotalSalesKobo(page);
          }, pageSize: pageSize);
          expect(
            seen,
            mine.length,
            reason: 'page $pageSize covers every order once',
          );
          expect((total, completed, sales), expected, reason: 'page $pageSize');
        }
        expect(expected.$1, greaterThan(0));
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });

  group('Reports badge', () {
    test(
      'LIMIT 1 latest count equals the max createdAt over every session',
      () async {
        final all = await shop.db.stockCountsDao.watchAllForBusiness().first;
        expect(all, isNotEmpty);
        final expected = all
            .map((c) => c.createdAt)
            .reduce((a, b) => a.isAfter(b) ? a : b);
        expect(
          await shop.db.stockCountsDao.watchLatestCountCreatedAt().first,
          expected,
        );
      },
    );
  });
}
