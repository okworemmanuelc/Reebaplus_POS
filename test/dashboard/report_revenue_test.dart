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

  group('Single Total Sales across the three surfaces (#176 AC)', () {
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

      // The one helper both the Home dashboard and the Profit report call.
      final homeSurface = computeTotalSalesKobo(orders);
      final profitSurface =
          computeTotalSalesKobo(orders, inSpan: (_) => true);

      // The reconciliation surface: totalRevenueKobo (gross item lines) −
      // discountsKobo, its documented `totalSalesKobo` getter. Feed the same
      // gross + discount the recon compute derives, computed INDEPENDENTLY here.
      final grossLines = orders
          .where((o) => o.order.status != 'cancelled')
          .expand((o) => o.items)
          .fold<int>(0, (s, i) => s + i.item.quantity * i.item.unitPriceKobo);
      final discounts = orders
          .where((o) => o.order.status != 'cancelled')
          .fold<int>(0, (s, o) => s + o.order.discountKobo);
      final reconSurface = ReconData(
        totalRevenueKobo: grossLines,
        costedRevenueKobo: 0,
        cogsKobo: 0,
        discountsKobo: discounts,
        vatEnabled: false,
        vatRateBps: 0,
        vatKobo: 0,
        itemsSold: 0,
        skus: 0,
        uncostedItems: 0,
        refundsKobo: 0,
        cashSalesKobo: 0,
        cashDebtsCollectedKobo: 0,
        cashRefundsKobo: 0,
        cashExpensesKobo: 0,
        cashSupplierPaidKobo: 0,
        cashCrateDepositsKobo: 0,
        bestStaff: null,
        bestStaffKobo: 0,
        expensesKobo: 0,
        expensesCount: 0,
        damageUnits: 0,
        damageCostKobo: 0,
        damageRetailKobo: 0,
        crateDamageDepositKobo: 0,
        hasStockCount: false,
        productsCounted: 0,
        shortageCount: 0,
        shortageUnits: 0,
        surplusCount: 0,
        surplusUnits: 0,
        shortageCostKobo: 0,
        shortageRetailKobo: 0,
        shortages: const [],
        goodsReceivedKobo: 0,
        supplierPaidKobo: 0,
        totalOwedKobo: 0,
        showCrates: false,
        crateUnits: 0,
        crateDepositKobo: 0,
        heldCrateDepositsKobo: 0,
        supplierCrateDebtKobo: 0,
        supplierPayableKobo: 0,
        inventoryOnHandKobo: 0,
        uncostedInventoryItems: 0,
        surplusCostKobo: 0,
        stockOpeningKobo: 0,
        stockReceivedKobo: 0,
        stockCogsKobo: 0,
        stockDamagesKobo: 0,
        stockExpiredKobo: 0,
        stockOtherMovementsKobo: 0,
        stockExpectedClosingKobo: 0,
        topItems: const [],
        manufacturerEmpties: const [],
      ).totalSalesKobo;

      expect(homeSurface, expected);
      expect(profitSurface, expected);
      expect(reconSurface, expected);
      // The AC: all three agree.
      expect({homeSurface, profitSurface, reconSurface}, {expected});
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
