// cancel_keeps_original_day_test.dart
//
// #549 (PRD #337, "Reporting: a returned sale keeps its original day") — a
// reviewed day must never change because a sale from it was cancelled later.
// A cancelled Order STILL counts on its `createdAt` day and ALSO books a
// NEGATIVE entry of the same amounts on its `cancelledAt` day.
//
// Three layers: the pure rule (`saleDayStamps`), the one Total Sales
// definition (`computeTotalSalesKobo`), and the real reconciliation roll-up
// (`reconDataFrom`) — costed revenue / COGS / discounts / uncosted takings /
// profit / the paid-now split — compared before and after a later-day cancel.

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/report_revenue.dart';
import 'package:reebaplus_pos/shared/models/order_status.dart';

DateTime _d(int day, [int hour = 10]) => DateTime(2026, 7, day, hour);

ProductData _product() => ProductData(
  id: 'prod-1',
  businessId: 'b1',
  name: 'Star 60cl',
  unit: 'bottle',
  buyingPriceKobo: 5000,
  retailerPriceKobo: 10000,
  wholesalerPriceKobo: 9000,
  isAvailable: true,
  showOnline: true,
  minOrderQty: 1,
  orderStep: 1,
  isDeleted: false,
  lowStockThreshold: 0,
  avgDailySales: 0,
  leadTimeDays: 0,
  safetyStockQty: 0,
  monthlyTargetUnits: 0,
  emptyCrateValueKobo: 0,
  trackEmpties: false,
  allowFractionalSales: false,
  version: 1,
  createdAt: DateTime.utc(2026, 1, 1),
  lastUpdatedAt: DateTime.utc(2026, 1, 1),
);

/// One order with a costed line (3 × ₦100, cost ₦50 each) and a quick-sale line
/// (2 × ₦30, no cost), a ₦20 discount, fully paid. Goods net =
/// 30000 + 6000 − 2000 = 34000.
OrderWithItems _order({
  required String id,
  required String status,
  required DateTime createdAt,
  DateTime? cancelledAt,
  String? reason,
}) {
  final product = _product();
  final order = OrderData(
    id: id,
    businessId: 'b1',
    orderNumber: id,
    customerId: null,
    totalAmountKobo: 34000,
    discountKobo: 2000,
    netAmountKobo: 34000,
    amountPaidKobo: 34000,
    paymentType: 'cash',
    status: status,
    riderName: 'Pick-up Order',
    cancellationReason: reason,
    barcode: null,
    staffId: 'staff-1',
    storeId: 's1',
    confirmedBy: null,
    crateDepositPaidKobo: 0,
    completedAt: null,
    cancelledAt: cancelledAt,
    createdAt: createdAt,
    lastUpdatedAt: createdAt,
  );
  OrderItemData line(String n, String? pid, int qty, int price, int cost) =>
      OrderItemData(
        id: '$id-$n',
        businessId: 'b1',
        orderId: id,
        productId: pid,
        storeId: 's1',
        quantity: qty,
        unitPriceKobo: price,
        buyingPriceKobo: cost,
        totalKobo: qty * price,
        cataloguePriceKobo: null,
        priceSnapshot: null,
        createdAt: createdAt,
        lastUpdatedAt: createdAt,
      );
  return OrderWithItems(order, [
    OrderItemDataWithProductData(line('a', product.id, 3, 10000, 5000), product),
    OrderItemDataWithProductData(line('b', null, 2, 3000, 0), null),
  ], null);
}

OrderWithItems _live() =>
    _order(id: 'o1', status: 'completed', createdAt: _d(1));
OrderWithItems _cancelledOn(int day, {String? reason}) => _order(
  id: 'o1',
  status: 'cancelled',
  createdAt: _d(1),
  cancelledAt: _d(day, 15).toUtc(),
  reason: reason ?? 'Customer changed mind',
);

bool Function(DateTime) _spanDays(int from, int toInclusive) =>
    (t) => !t.isBefore(DateTime(2026, 7, from)) &&
        t.isBefore(DateTime(2026, 7, toInclusive + 1));

ReconData _recon(List<OrderWithItems> orders, int from, int toInclusive) =>
    reconDataFrom(
      ReconInputs(
        orders: orders,
        inScope: (_) => true,
        start: DateTime(2026, 7, from),
        endExclusive: DateTime(2026, 7, toInclusive + 1),
      ),
    );

Map<String, int> _figures(ReconData d) => {
  'totalRevenueKobo': d.totalRevenueKobo,
  'totalSalesKobo': d.totalSalesKobo,
  'costedRevenueKobo': d.costedRevenueKobo,
  'cogsKobo': d.cogsKobo,
  'grossProfitKobo': d.grossProfitKobo,
  'netProfitKobo': d.netProfitKobo,
  'discountsKobo': d.discountsKobo,
  'uncostedTakingsKobo': d.uncostedTakingsKobo,
  'itemsSold': d.itemsSold,
  'uncostedItems': d.uncostedItems,
  'salesPaidNowKobo': d.salesPaidNowKobo,
  'salesOnCreditKobo': d.salesOnCreditKobo,
};

void main() {
  group('saleDayStamps — the original-day rule', () {
    List<(int, int)> stamps({
      required String status,
      DateTime? cancelledAt,
      String? reason,
    }) => [
      for (final s in saleDayStamps(
        status: status,
        createdAt: _d(1),
        cancelledAt: cancelledAt,
        cancellationReason: reason,
      ))
        (s.day.day, s.sign),
    ];

    test('a live order is +1 on its creation day only', () {
      expect(stamps(status: 'pending'), [(1, 1)]);
      expect(stamps(status: 'completed'), [(1, 1)]);
    });

    test('a cancel on the same day is +1 and -1 on that day (nets to zero)', () {
      expect(
        stamps(status: 'cancelled', cancelledAt: _d(1, 18)),
        [(1, 1), (1, -1)],
      );
    });

    test('a cancel on a later day is +1 on day 1 and -1 on the cancel day', () {
      expect(
        stamps(status: 'cancelled', cancelledAt: _d(3, 9).toUtc()),
        [(1, 1), (3, -1)],
      );
    });

    test('a sale the server rejected is excluded entirely', () {
      expect(
        stamps(
          status: 'cancelled',
          cancelledAt: _d(3),
          reason: kRejectedByServerReason,
        ),
        isEmpty,
      );
    });

    test('a legacy cancel with no cancelledAt is excluded entirely', () {
      expect(stamps(status: 'cancelled'), isEmpty);
    });

    test('refunded (retired) and unknown statuses are excluded', () {
      expect(stamps(status: 'refunded', cancelledAt: _d(3)), isEmpty);
      expect(stamps(status: 'draft'), isEmpty);
    });
  });

  group('computeTotalSalesKobo — a return keeps its original day', () {
    test('day 1 is unchanged by a day-3 cancel; day 3 shows the negative', () {
      final before = computeTotalSalesKobo([_live()], inSpan: _spanDays(1, 1));
      final cancelled = _cancelledOn(3);
      expect(
        computeTotalSalesKobo([cancelled], inSpan: _spanDays(1, 1)),
        before,
      );
      expect(before, 34000);
      expect(
        computeTotalSalesKobo([cancelled], inSpan: _spanDays(2, 2)),
        0,
      );
      expect(
        computeTotalSalesKobo([cancelled], inSpan: _spanDays(3, 3)),
        -34000,
      );
      // A span covering both nets to zero.
      expect(
        computeTotalSalesKobo([cancelled], inSpan: _spanDays(1, 3)),
        0,
      );
    });

    test('a same-day cancel nets to zero on that day', () {
      expect(
        computeTotalSalesKobo([_cancelledOn(1)], inSpan: _spanDays(1, 1)),
        0,
      );
    });

    test('rejected_by_server and legacy (no cancelledAt) count nowhere', () {
      final rejected = _cancelledOn(3, reason: kRejectedByServerReason);
      final legacy = _order(
        id: 'o1',
        status: 'cancelled',
        createdAt: _d(1),
      );
      for (final o in [rejected, legacy]) {
        expect(computeTotalSalesKobo([o]), 0);
        expect(computeTotalSalesKobo([o], inSpan: _spanDays(1, 1)), 0);
        expect(computeTotalSalesKobo([o], inSpan: _spanDays(3, 3)), 0);
      }
    });
  });

  group('reconDataFrom — day 1 figures never move when a later cancel lands', () {
    test('every money figure of day 1 is identical before and after', () {
      final before = _figures(_recon([_live()], 1, 1));
      final after = _figures(_recon([_cancelledOn(3)], 1, 1));
      expect(after, before);
      // Sanity: the day actually carries the sale (so "identical" is not 0 == 0).
      expect(before['costedRevenueKobo'], 30000);
      expect(before['cogsKobo'], 15000);
      expect(before['uncostedTakingsKobo'], 6000);
      expect(before['discountsKobo'], 2000);
      expect(before['totalSalesKobo'], 34000);
    });

    test('the cancel day books the exact negative; a span over both is zero',
        () {
      final cancelled = _cancelledOn(3);
      final day3 = _recon([cancelled], 3, 3);
      expect(day3.costedRevenueKobo, -30000);
      expect(day3.cogsKobo, -15000);
      expect(day3.discountsKobo, -2000);
      expect(day3.uncostedTakingsKobo, -6000);
      expect(day3.totalSalesKobo, -34000);
      expect(day3.itemsSold, -5);
      expect(day3.salesPaidNowKobo, -34000);
      expect(day3.grossProfitKobo, -13000); // -(30000 - 15000 - 2000)
      // Profit counts the return once: net profit is the sign-flipped day-1
      // profit, with no extra refund deduction.
      expect(day3.netProfitKobo, -_recon([_live()], 1, 1).netProfitKobo);
      expect(day3.refundsKobo, 0);

      final both = _recon([cancelled], 1, 3);
      expect(both.costedRevenueKobo, 0);
      expect(both.cogsKobo, 0);
      expect(both.netProfitKobo, 0);
      expect(both.totalSalesKobo, 0);
    });

    test('a day between the sale and the cancel is untouched', () {
      final d2 = _recon([_cancelledOn(3)], 2, 2);
      expect(d2.totalSalesKobo, 0);
      expect(d2.costedRevenueKobo, 0);
      expect(d2.cogsKobo, 0);
    });

    test('a legacy cancel (no cancelledAt) is excluded, as before', () {
      final legacy = _order(id: 'o1', status: 'cancelled', createdAt: _d(1));
      expect(_recon([legacy], 1, 1).totalSalesKobo, 0);
    });
  });
}
