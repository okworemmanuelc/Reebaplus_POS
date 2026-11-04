// profit_period_orders_test.dart
//
// #685 (PRD #680, "Smooth screens" S4) - the Profit report loads only the
// orders that can put an entry on the chosen period, instead of the whole
// history, and feeds them to the SAME pure `computeProfit`. This proves the
// figures are IDENTICAL to the full-history ones for every period, store-scoped
// and business-wide, including sales cancelled on a later day (#549: the -1
// return lands on the cancel day) and entries sitting exactly on period edges.

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/features/dashboard/screens/profit_report_screen.dart';

import '../support/history_shop_generator.dart';

void main() {
  late HistoryShop shop;
  late List<OrderWithItems> full;

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

    // Hand-placed edge cases on top of the generated history (week of
    // Sun 2026-10-25): a sale exactly at the week's first instant, one a
    // second before it, and a sale from BEFORE the week cancelled exactly at
    // the week's first instant.
    final live =
        await (shop.db.select(shop.db.orders)
              ..where((o) => o.status.isIn(const ['pending', 'completed']))
              ..where((o) => o.kind.equals('sale'))
              ..orderBy([(o) => OrderingTerm.asc(o.createdAt)])
              ..limit(3))
            .get();
    Future<void> set(String id, OrdersCompanion c) => (shop.db.update(
      shop.db.orders,
    )..where((o) => o.id.equals(id))).write(c);
    await set(
      live[0].id,
      OrdersCompanion(createdAt: Value(DateTime(2026, 10, 25))),
    );
    await set(
      live[1].id,
      OrdersCompanion(createdAt: Value(DateTime(2026, 10, 24, 23, 59, 59))),
    );
    await set(
      live[2].id,
      OrdersCompanion(
        createdAt: Value(DateTime(2026, 10, 10, 9)),
        status: const Value('cancelled'),
        cancelledAt: Value(DateTime(2026, 10, 25)),
      ),
    );
    full = await shop.db.ordersDao.watchAllOrdersWithItems().first;
  });
  tearDownAll(() => shop.close());

  Future<List<OrderWithItems>> narrowed(String period, DateTime now) async {
    final (from, to) = dateRangeForLabel(period, now: now);
    return shop.db.ordersDao
        .watchAllOrdersWithItems(entryDayFrom: from, entryDayTo: to)
        .first;
  }

  void expectSame(ProfitData a, ProfitData b, String why) {
    expect(b.revenueKobo, a.revenueKobo, reason: '$why revenue');
    expect(b.cogsKobo, a.cogsKobo, reason: '$why cogs');
    expect(b.profitKobo, a.profitKobo, reason: '$why profit');
    expect(b.marginPct, a.marginPct, reason: '$why margin');
    expect(b.uncostedItems, a.uncostedItems, reason: '$why uncosted');
    expect(b.concessionKobo, a.concessionKobo, reason: '$why concession');
    expect(b.totalSalesKobo, a.totalSalesKobo, reason: '$why total sales');
    expect(b.returnsKobo, a.returnsKobo, reason: '$why returns');
    expect(
      b.returnedProfitKobo,
      a.returnedProfitKobo,
      reason: '$why ret.profit',
    );
    expect(b.products.length, a.products.length, reason: '$why product rows');
    for (var i = 0; i < a.products.length; i++) {
      final x = a.products[i], y = b.products[i];
      expect(
        (y.name, y.qty, y.revenueKobo, y.cogsKobo, y.concessionKobo),
        (x.name, x.qty, x.revenueKobo, x.cogsKobo, x.concessionKobo),
        reason: '$why product $i',
      );
    }
  }

  // Run-days: the last 30 days, plus month / week / year edges.
  final nowList = <DateTime>[
    for (var i = 0; i < 30; i++) DateTime(2026, 10, 31 - i, 12),
    DateTime(2026, 9, 30, 23, 59, 59),
    DateTime(2026, 10, 1),
    DateTime(2026, 10, 25),
    DateTime(2026, 10, 25, 0, 0, 1),
    DateTime(2026, 1, 1),
    DateTime(2026, 1, 2, 8),
    DateTime(2025, 12, 31, 23),
  ];

  List<String> periodsFor(DateTime now) {
    String d(DateTime x) =>
        '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
    final back = now.subtract(const Duration(days: 6));
    return [
      'Today',
      'This Week',
      'This Month',
      'This Year',
      'To Date',
      'Custom:${d(back)}:${d(now)}',
      'Custom:${d(now)}:${d(now)}',
    ];
  }

  final scopes = <String, bool Function(String?) Function()>{
    'one store': () =>
        (s) => s == shop.storeId,
    'all stores': () =>
        (s) => true,
    'van only': () =>
        (s) => s == shop.vanStoreId,
  };

  group('narrowed orders give the full-history figures', () {
    for (final scope in scopes.entries) {
      test('${scope.key}: every period, every run-day', () async {
        final inScope = scope.value();
        var checked = 0;
        var sawReturns = false;
        for (final now in nowList) {
          for (final period in periodsFor(now)) {
            final a = computeProfit(full, period, inScope, now: now);
            final sub = await narrowed(period, now);
            final b = computeProfit(sub, period, inScope, now: now);
            expectSame(a, b, '$period @ $now');
            if (a.returnsKobo != 0) sawReturns = true;
            checked++;
          }
        }
        expect(checked, nowList.length * 7);
        // The corpus must actually exercise later-day cancels, or the proof
        // would be vacuous.
        if (scope.key != 'van only') expect(sawReturns, isTrue);
      }, timeout: const Timeout(Duration(minutes: 5)));
    }

    test('To Date loads every order (no lower bound)', () async {
      final now = DateTime(2026, 10, 31, 12);
      expect((await narrowed('To Date', now)).length, full.length);
    });

    test('a short period loads far fewer orders than the history', () async {
      final now = DateTime(2026, 10, 31, 12);
      final today = await narrowed('Today', now);
      expect(today.length, lessThan(full.length ~/ 20));
    });

    test('a sale made before the window but cancelled inside it is loaded, '
        'and its return is counted', () async {
      final now = DateTime(2026, 10, 31, 12);
      final week = await narrowed('This Week', now);
      final cancelled = full.firstWhere(
        (o) =>
            o.order.status == 'cancelled' &&
            o.order.createdAt.isBefore(DateTime(2026, 10, 25)) &&
            o.order.cancelledAt != null &&
            !o.order.cancelledAt!.isBefore(DateTime(2026, 10, 25)),
      );
      expect(week.any((o) => o.order.id == cancelled.order.id), isTrue);
      final a = computeProfit(full, 'This Week', (s) => true, now: now);
      expect(a.returnsKobo, lessThan(0));
    });

    test('entries exactly on the week edge: in at the first instant, out a '
        'second earlier', () async {
      final now = DateTime(2026, 10, 31, 12);
      final week = await narrowed('This Week', now);
      final ids = {for (final o in week) o.order.id};
      final onEdge = full.where(
        (o) => o.order.createdAt == DateTime(2026, 10, 25),
      );
      final before = full.where(
        (o) => o.order.createdAt == DateTime(2026, 10, 24, 23, 59, 59),
      );
      expect(onEdge, isNotEmpty);
      expect(before, isNotEmpty);
      expect(ids.contains(onEdge.first.order.id), isTrue);
      expect(ids.contains(before.first.order.id), isFalse);
    });
  });
}
