import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/report_revenue.dart';

/// #176 (Money integrity report-truth, PRD #155 story 28) — the SINGLE revenue
/// definition. `computeTotalSalesKobo` is item-line gross minus discounts,
/// deposit-exclusive, and is the one helper the Home dashboard, the Daily
/// Reconciliation, and the Profit report all resolve "Total Sales" through, so
/// three screens can no longer give three answers for the same day.

DateTime _day(int d) => DateTime(2026, 7, d);

bool _anyDay(DateTime _) => true;
bool _anyStore(String? _) => true;

/// Builds one [OrderWithItems]. Item lines are `(qty, unitPriceKobo)` — the
/// product is left null (the helper only sums lines; `productId` decides whether
/// a line is a quick sale). `totalAmountKobo` deliberately BUNDLES the deposit
/// (goodsNet + deposit) so a test can prove the helper stays deposit-exclusive.
OrderWithItems _order({
  required String status,
  required DateTime createdAt,
  required List<(int qty, int unitPriceKobo)> lines,
  String? storeId = 's1',
  int discountKobo = 0,
  int amountPaidKobo = 0,
  int crateDepositPaidKobo = 0,
  bool quickSale = false,
}) {
  final gross = lines.fold<int>(0, (s, l) => s + l.$1 * l.$2);
  final goodsNet = gross - discountKobo;
  final orderId = 'o-${createdAt.microsecondsSinceEpoch}-${lines.length}';
  final order = OrderData(
    id: orderId,
    businessId: 'b1',
    orderNumber: 'ORD-$orderId',
    customerId: null,
    totalAmountKobo: goodsNet + crateDepositPaidKobo, // deposit BUNDLED in
    discountKobo: discountKobo,
    netAmountKobo: goodsNet,
    amountPaidKobo: amountPaidKobo,
    paymentType: 'cash',
    status: status,
    riderName: 'Pick-up Order',
    cancellationReason: null,
    barcode: null,
    staffId: null,
    storeId: storeId,
    confirmedBy: null,
    crateDepositPaidKobo: crateDepositPaidKobo,
    completedAt: null,
    cancelledAt: null,
    createdAt: createdAt,
    lastUpdatedAt: createdAt,
  );
  final items = <OrderItemDataWithProductData>[
    for (var i = 0; i < lines.length; i++)
      OrderItemDataWithProductData(
        OrderItemData(
          id: '$orderId-$i',
          businessId: 'b1',
          orderId: orderId,
          productId: quickSale ? null : 'p$i',
          storeId: storeId ?? 's1',
          quantity: lines[i].$1,
          unitPriceKobo: lines[i].$2,
          buyingPriceKobo: quickSale ? 0 : 5000,
          totalKobo: lines[i].$1 * lines[i].$2,
          cataloguePriceKobo: null,
          priceSnapshot: null,
          createdAt: createdAt,
          lastUpdatedAt: createdAt,
        ),
        null,
      ),
  ];
  return OrderWithItems(order, items, null);
}

void main() {
  group('computeTotalSalesKobo — the single Total Sales definition', () {
    test('sums item lines minus discounts (deposit-exclusive)', () {
      // 3 × ₦1,000 = ₦3,000 goods, ₦500 discount, ₦2,000 deposit bundled in
      // totalAmountKobo. The deposit must NOT be counted — only 3,000 − 500.
      final o = _order(
        status: 'pending',
        createdAt: _day(10),
        lines: [(3, 100000)],
        discountKobo: 50000,
        crateDepositPaidKobo: 200000,
      );
      expect(computeTotalSalesKobo([o]), 250000);
      // Proves it is deposit-exclusive: the order's totalAmountKobo is larger.
      expect(o.order.totalAmountKobo, greaterThan(computeTotalSalesKobo([o])));
    });

    test('includes quick-sale (uncosted) lines', () {
      final costed = _order(
        status: 'pending', createdAt: _day(10), lines: [(1, 100000)]);
      final quick = _order(
        status: 'pending',
        createdAt: _day(10),
        lines: [(2, 30000)],
        quickSale: true,
      );
      expect(computeTotalSalesKobo([costed, quick]), 100000 + 60000);
    });

    test('excludes cancelled orders (never a sale)', () {
      final live = _order(
        status: 'pending', createdAt: _day(10), lines: [(1, 100000)]);
      final cancelled = _order(
        status: 'cancelled', createdAt: _day(10), lines: [(1, 100000)]);
      expect(computeTotalSalesKobo([live, cancelled]), 100000);
    });

    test('honours the inSpan and inScope predicates', () {
      final inDay = _order(
        status: 'pending', createdAt: _day(10), lines: [(1, 100000)]);
      final otherDay = _order(
        status: 'pending', createdAt: _day(11), lines: [(1, 100000)]);
      final otherStore = _order(
        status: 'pending',
        createdAt: _day(10),
        lines: [(1, 100000)],
        storeId: 's2',
      );
      final total = computeTotalSalesKobo(
        [inDay, otherDay, otherStore],
        inSpan: (t) => t == _day(10),
        inScope: (s) => s == 's1',
      );
      expect(total, 100000);
    });
  });

  group('Single Total Sales across the three surfaces (#176 AC / #195)', () {
    // The three surfaces, each resolved the way its own screen resolves it.
    // The reconciliation one runs the REAL roll-up (`reconDataFrom`, the pure
    // half of `computeReconData` extracted in #195) — the previous version of
    // this test fabricated a `ReconData` from figures it computed itself, so it
    // could not fail when the reconciliation's own loop drifted.
    ({int home, int recon, int profit, ReconData reconData}) surfacesFor(
      List<OrderWithItems> orders, {
      bool Function(DateTime) inSpan = _anyDay,
      bool Function(String?) inScope = _anyStore,
    }) {
      final reconData = reconDataFrom(
        ReconInputs(
          orders: orders,
          inScope: inScope,
          // The roll-up spans on start/endExclusive; the two callers below span
          // on a period label, so bound the roll-up to the same single day.
          start: _day(10),
          endExclusive: _day(11),
        ),
      );
      return (
        // Home passes its already period-filtered orders + the store predicate.
        home: computeTotalSalesKobo(orders, inScope: inScope),
        recon: reconData.totalSalesKobo,
        // The Profit report passes both predicates.
        profit: computeTotalSalesKobo(orders, inSpan: inSpan, inScope: inScope),
        reconData: reconData,
      );
    }

    test('Home, Recon, and Profit resolve the SAME figure for one order set',
        () {
      final orders = [
        _order(
          status: 'pending',
          createdAt: _day(10),
          lines: [(2, 100000)], // ₦2,000 goods
          discountKobo: 30000, // − ₦300
          crateDepositPaidKobo: 150000, // deposit bundled, must be excluded
          amountPaidKobo: 100000,
        ),
        _order(
          status: 'completed',
          createdAt: _day(10),
          lines: [(1, 50000), (3, 20000)], // ₦1,100 goods
          quickSale: true,
        ),
        _order(status: 'cancelled', createdAt: _day(10), lines: [(9, 999999)]),
      ];

      // Hand-computed expectation: (2,000 − 300) + (1,100) = 2,800 → 280000.
      const expected = 280000;

      final s = surfacesFor(orders);

      expect(s.home, expected);
      expect(s.profit, expected);
      expect(s.recon, expected);
      // The AC: all three agree.
      expect({s.home, s.profit, s.recon}, {expected});
      // …and the reconciliation's P&L split still reconciles to the headline,
      // so the gross + discount card and the Total Sales card cannot disagree.
      expect(
        s.reconData.totalRevenueKobo - s.reconData.discountsKobo,
        expected,
      );
    });

    test('a locked store scopes all three surfaces to the SAME figure (#195)',
        () {
      // The bug: with a store locked, Home and Recon showed the store while the
      // Profit report showed the whole business.
      final orders = [
        _order(
          status: 'pending',
          createdAt: _day(10),
          lines: [(2, 100000)], // ₦2,000 in store s1
          discountKobo: 30000, // − ₦300, charged to s1
        ),
        _order(
          status: 'pending',
          createdAt: _day(10),
          lines: [(5, 100000)], // ₦5,000 in the OTHER store
          discountKobo: 100000,
          storeId: 's2',
        ),
      ];

      final locked = surfacesFor(orders, inScope: (s) => s == 's1');
      expect({locked.home, locked.profit, locked.recon}, {170000});

      // All Stores is the business-wide figure — the same three surfaces again.
      final all = surfacesFor(orders);
      expect({all.home, all.profit, all.recon}, {170000 + 400000});
    });

    test('the reconciliation headline IS the shared helper, not its own loop',
        () {
      // The regression guard: whatever the roll-up's internal revenue loop
      // does, `totalSalesKobo` must equal `computeTotalSalesKobo` over the same
      // orders, span and scope. A future edit to either side that changes the
      // answer fails here.
      final orders = [
        _order(
          status: 'pending',
          createdAt: _day(10),
          lines: [(3, 45000), (1, 120000)],
          discountKobo: 15000,
          crateDepositPaidKobo: 250000,
          amountPaidKobo: 300000,
        ),
        _order(
          status: 'completed',
          createdAt: _day(10),
          lines: [(2, 60000)],
          quickSale: true,
          storeId: 's2',
        ),
        _order(status: 'cancelled', createdAt: _day(10), lines: [(4, 80000)]),
        // Outside the span — must be excluded by BOTH sides.
        _order(status: 'pending', createdAt: _day(12), lines: [(7, 90000)]),
      ];

      for (final scope in <bool Function(String?)>[
        _anyStore,
        (s) => s == 's1',
        (s) => s == 's2',
      ]) {
        final s = surfacesFor(
          orders,
          inSpan: (t) => t == _day(10),
          inScope: scope,
        );
        expect(s.recon, s.profit);
        expect(
          s.reconData.totalRevenueKobo - s.reconData.discountsKobo,
          s.recon,
        );
      }
    });
  });

  group('splitPaidNowOnCredit — paid-now vs on-credit (#176 story 29)', () {
    test('a fully-paid order is all paid-now, nothing on credit', () {
      final s = splitPaidNowOnCredit(
        goodsNet: 100000, amountPaid: 100000, depositHeld: 0);
      expect(s.paidNow, 100000);
      expect(s.onCredit, 0);
    });

    test('a partial payment splits at the goods net; the deposit is excluded '
        'from paid-now', () {
      // Paid ₦800 of which ₦200 is deposit → ₦600 toward ₦1,000 goods.
      final s = splitPaidNowOnCredit(
        goodsNet: 100000, amountPaid: 80000, depositHeld: 20000);
      expect(s.paidNow, 60000);
      expect(s.onCredit, 40000);
    });

    test('a pure credit sale is entirely on credit', () {
      final s = splitPaidNowOnCredit(
        goodsNet: 100000, amountPaid: 0, depositHeld: 0);
      expect(s.paidNow, 0);
      expect(s.onCredit, 100000);
    });

    test('paidNow + onCredit always equals goodsNet (the identity)', () {
      for (final (net, paid, dep) in [
        (100000, 80000, 20000),
        (50000, 50000, 0),
        (75000, 0, 0),
        (120000, 200000, 30000), // overpaid — capped at net
      ]) {
        final s = splitPaidNowOnCredit(
          goodsNet: net, amountPaid: paid, depositHeld: dep);
        expect(s.paidNow + s.onCredit, net);
      }
    });
  });
}
