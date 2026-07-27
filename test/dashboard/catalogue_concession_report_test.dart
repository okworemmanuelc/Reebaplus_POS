// catalogue_concession_report_test.dart
//
// PRD #155 US 32 (#200) — "record the concession against the catalogue price, so
// that under-the-counter discounting is visible in margin review."
//
// The column (`order_items.catalogue_price_kobo`, migration 0158), the checkout
// write and the cloud RPC parity (0160) all landed under #176/#183, but nothing
// in the app ever READ the column: `rg cataloguePriceKobo lib` returned the
// schema and the write and nothing else, so the give-away stayed invisible and
// the story was unmet. These tests pin the reader's money math — the two pure
// helpers the Profit report accumulates per line and per period.
//
// A concession is NOT `orders.discount_kobo` (§13.3): that discount is explicit,
// order-level, and already netted out of Total Sales. A concession is the quiet
// version — the unit price itself was overridden at the till — which is exactly
// why margin review needs its own figure for it.

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/report_revenue.dart';

DateTime _day(int d) => DateTime(2026, 7, d);

/// One order whose lines are `(qty, chargedKobo, cataloguePriceKobo?)`.
/// A null catalogue price is what the writer stores when the line went out AT
/// list price (and for product-less quick sales) — i.e. "no concession", never
/// "unknown".
OrderWithItems _order({
  required String status,
  required DateTime createdAt,
  required List<(int qty, int chargedKobo, int? catalogueKobo)> lines,
  String? storeId = 's1',
  bool uncosted = false,
}) {
  final gross = lines.fold<int>(0, (s, l) => s + l.$1 * l.$2);
  final orderId = 'o-${createdAt.day}-${lines.length}-$storeId-$status';
  final order = OrderData(
    id: orderId,
    businessId: 'b1',
    orderNumber: 'ORD-$orderId',
    customerId: null,
    totalAmountKobo: gross,
    discountKobo: 0,
    netAmountKobo: gross,
    amountPaidKobo: gross,
    paymentType: 'cash',
    status: status,
    riderName: 'Pick-up Order',
    cancellationReason: null,
    barcode: null,
    staffId: null,
    storeId: storeId,
    confirmedBy: null,
    crateDepositPaidKobo: 0,
    completedAt: null,
    cancelledAt: null,
    createdAt: createdAt,
    lastUpdatedAt: createdAt,
  );
  return OrderWithItems(
    order,
    [
      for (var i = 0; i < lines.length; i++)
        OrderItemDataWithProductData(
          OrderItemData(
            id: '$orderId-$i',
            businessId: 'b1',
            orderId: orderId,
            productId: 'p$i',
            storeId: storeId ?? 's1',
            quantity: lines[i].$1,
            unitPriceKobo: lines[i].$2,
            // An uncosted line is one whose buying price was never recorded.
            buyingPriceKobo: uncosted ? 0 : 5000,
            totalKobo: lines[i].$1 * lines[i].$2,
            cataloguePriceKobo: lines[i].$3,
            priceSnapshot: null,
            createdAt: createdAt,
            lastUpdatedAt: createdAt,
          ),
          null,
        ),
    ],
    null,
  );
}

void main() {
  group('lineConcessionKobo — one sold line', () {
    test('no catalogue price means no concession (sold at list)', () {
      expect(
        lineConcessionKobo(
          cataloguePriceKobo: null,
          unitPriceKobo: 100000,
          quantity: 3,
        ),
        0,
      );
    });

    test('below list: catalogue − charged, times the quantity', () {
      // List ₦1,000, sold at ₦850, three of them → ₦450 given away.
      expect(
        lineConcessionKobo(
          cataloguePriceKobo: 100000,
          unitPriceKobo: 85000,
          quantity: 3,
        ),
        45000,
      );
    });

    test('above list stays SIGNED, so a markup cannot hide a give-away', () {
      // Sold ₦200 ABOVE list. Clamping this to 0 would let one line's markup
      // silently cancel another line's discount in the period total.
      expect(
        lineConcessionKobo(
          cataloguePriceKobo: 100000,
          unitPriceKobo: 120000,
          quantity: 1,
        ),
        -20000,
      );
    });

    test('a zero-quantity line contributes nothing', () {
      expect(
        lineConcessionKobo(
          cataloguePriceKobo: 100000,
          unitPriceKobo: 50000,
          quantity: 0,
        ),
        0,
      );
    });
  });

  group('computeCatalogueConcessionKobo — a period', () {
    test('sums every discounted line and ignores the at-list ones', () {
      final o = _order(
        status: 'pending',
        createdAt: _day(10),
        lines: [
          (2, 85000, 100000), // ₦300 below list
          (1, 50000, null), // at list — no concession
          (4, 20000, 25000), // ₦200 below list
        ],
      );
      expect(computeCatalogueConcessionKobo([o]), 30000 + 20000);
    });

    test('an uncosted line\'s concession still counts', () {
      // The Profit report EXCLUDES uncosted lines from revenue/COGS/margin, but a
      // price cut on one is still a price cut — dropping it would leave exactly
      // the give-away this story exists to surface invisible.
      final uncosted = _order(
        status: 'pending',
        createdAt: _day(10),
        lines: [(2, 40000, 50000)],
        uncosted: true,
      );
      expect(computeCatalogueConcessionKobo([uncosted]), 20000);
    });

    test('a cancelled order is not a sale, so it gives nothing away', () {
      final live = _order(
        status: 'pending',
        createdAt: _day(10),
        lines: [(1, 85000, 100000)],
      );
      final dead = _order(
        status: 'cancelled',
        createdAt: _day(10),
        lines: [(1, 85000, 100000)],
      );
      expect(computeCatalogueConcessionKobo([live, dead]), 15000);
    });

    test('respects the period filter', () {
      final inSpan = _order(
        status: 'pending',
        createdAt: _day(10),
        lines: [(1, 85000, 100000)],
      );
      final outOfSpan = _order(
        status: 'pending',
        createdAt: _day(20),
        lines: [(1, 60000, 100000)],
      );
      expect(
        computeCatalogueConcessionKobo(
          [inSpan, outOfSpan],
          inSpan: (createdAt) => createdAt.day == 10,
        ),
        15000,
      );
    });

    test('respects the store filter, per line', () {
      final mine = _order(
        status: 'pending',
        createdAt: _day(10),
        lines: [(1, 85000, 100000)],
        storeId: 's1',
      );
      final theirs = _order(
        status: 'pending',
        createdAt: _day(10),
        lines: [(1, 60000, 100000)],
        storeId: 's2',
      );
      expect(
        computeCatalogueConcessionKobo(
          [mine, theirs],
          inScope: (storeId) => storeId == 's1',
        ),
        15000,
      );
    });

    test('a period with no overridden price reports nothing', () {
      final o = _order(
        status: 'pending',
        createdAt: _day(10),
        lines: [(3, 100000, null)],
      );
      expect(computeCatalogueConcessionKobo([o]), 0);
    });

    test('a markup nets against a give-away, and the sign says which won', () {
      final below = _order(
        status: 'pending',
        createdAt: _day(10),
        lines: [(1, 90000, 100000)], // ₦100 given away
      );
      final above = _order(
        status: 'pending',
        createdAt: _day(11),
        lines: [(1, 130000, 100000)], // ₦300 over list
      );
      expect(computeCatalogueConcessionKobo([below, above]), -20000);
    });
  });
}
