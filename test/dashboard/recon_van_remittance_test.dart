// recon_van_remittance_test.dart
//
// #144 (PRD #139 as amended by #161 / ADR 0019 decision 2, van-sales spec §4.7,
// §8.2), **re-pointed by #147**.
//
// What #144 pinned: a `van_remittance` row moved NO figure at all, because the
// line that reads it had not shipped yet. #147 shipped it, so the claim changes
// shape — and this file changes with it, deliberately, rather than being
// weakened:
//
//   · a remittance moves EXACTLY TWO things — "Cash from drivers" and the cash
//     card totals that contain it. It is real money physically arriving, and
//     ADR 0019 decision 2 exists precisely so the owner's cash figure counts it
//     on the day it lands. It behaves like a debt collected in cash, not a
//     sale.
//   · every OTHER figure is still byte-identical. That is the original claim
//     and it is the one that matters most: the quiet failure mode is a type
//     switch with a trailing `else` (or a report that sums payment rows
//     regardless of type) folding remitted cash into "Cash sales" — double
//     counting road revenue that was already recognised when the driver rang
//     it, on top of a day's real takings.
//
// Method: compute the reconciliation TWICE over the same day — once with only
// an ordinary cash sale, once with that sale PLUS a remittance — and compare
// the whole figure set. The two expected movers are named; everything else must
// not budge.
//
// The compute reads ~15 providers; overriding `currentBusinessIdProvider` with
// null makes every business-scoped one emit its `whenAbsent` value without
// touching a database (the guard in business_scoped_stream.dart), so only the
// payment feed and the store-filter inputs need real values.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/stores/van_store.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';

const _biz = 'biz';
const _warehouse = 'wh';
const _van = 'van';
final _day = DateTime(2026, 7, 26, 10);

StoreData _store(String id, {String kind = kStoreKindStore}) => StoreData(
  id: id,
  businessId: _biz,
  name: 'Location $id',
  location: null,
  kind: kind,
  isDeleted: false,
  createdAt: DateTime.utc(2026, 1, 1),
  lastUpdatedAt: DateTime.utc(2026, 1, 1),
);

PaymentTransactionData _payment({
  required String id,
  required String type,
  required int amountKobo,
  String method = 'cash',
  String? storeId = _warehouse,
  String? orderId,
  String? vanTripId,
}) {
  return PaymentTransactionData(
    id: id,
    businessId: _biz,
    storeId: storeId,
    amountKobo: amountKobo,
    method: method,
    type: type,
    orderId: orderId,
    shipmentId: null,
    expenseId: null,
    walletTxnId: null,
    deliveryId: null,
    vanTripId: vanTripId,
    performedBy: null,
    voidedAt: null,
    voidedBy: null,
    voidReason: null,
    createdAt: _day,
    lastUpdatedAt: _day,
  );
}

/// Every headline figure the day close freezes, plus the cash-card lines that
/// `dailyClosingFiguresFrom` does not carry — the full surface a stray payment
/// type could disturb.
Map<String, int> _figures(ReconData d) => {
  'totalSalesKobo': d.totalSalesKobo,
  'refundsKobo': d.refundsKobo,
  'discountsKobo': d.discountsKobo,
  'cogsKobo': d.cogsKobo,
  'grossProfitKobo': d.grossProfitKobo,
  'netProfitKobo': d.netProfitKobo,
  'expensesKobo': d.expensesKobo,
  'damageCostKobo': d.damageCostKobo,
  'cashSalesKobo': d.cashSalesKobo,
  'cashDebtsCollectedKobo': d.cashDebtsCollectedKobo,
  'cashRefundsKobo': d.cashRefundsKobo,
  'cashExpensesKobo': d.cashExpensesKobo,
  'cashCrateDepositsKobo': d.cashCrateDepositsKobo,
  'cashSupplierPaidKobo': d.cashSupplierPaidKobo,
  'cashInKobo': d.cashInKobo,
  'cashOutKobo': d.cashOutKobo,
  'netCashMovementKobo': d.netCashMovementKobo,
  'totalOwedKobo': d.totalOwedKobo,
  // #147 — the two figures a remittance is now ALLOWED to move, named so the
  // comparison below can subtract them explicitly instead of silently.
  'cashFromDriversKobo': d.cashFromDriversKobo,
  'vanRemittedKobo': d.van.remittedKobo,
};

/// The figures a remittance must leave alone — the whole set minus the three it
/// is supposed to move (the two van lines and the cash totals that contain
/// them).
Map<String, int> _untouchedFigures(ReconData d) => Map.of(_figures(d))
  ..remove('cashFromDriversKobo')
  ..remove('vanRemittedKobo')
  ..remove('cashInKobo')
  ..remove('netCashMovementKobo');

Future<ReconData> computeWith(
  WidgetTester tester,
  List<PaymentTransactionData> payments,
) async {
  // Tear the previous ProviderScope down first: two computes in one test would
  // otherwise share a container and the second could read the first's stream
  // value, which would make a comparison test pass vacuously.
  await tester.pumpWidget(const SizedBox.shrink());
  late ReconData out;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // No business bound ⇒ every business-scoped provider emits its
        // `whenAbsent` value and never reaches for a database.
        currentBusinessIdProvider.overrideWithValue(null),
        allPaymentTransactionsProvider.overrideWith(
          (ref) => Stream.value(payments),
        ),
        // reconStoreFilter's four inputs — All Stores, van excluded.
        selectableStoresProvider.overrideWithValue([_store(_warehouse)]),
        canViewAllStoresProvider.overrideWithValue(true),
        lockedStoreProvider.overrideWith(
          (ref) => ValueNotifier<String?>(null),
        ),
        vanStoresProvider.overrideWithValue(
          VanStores.of([_store(_warehouse), _store(_van, kind: kStoreKindVan)]),
        ),
      ],
      child: Consumer(
        builder: (_, ref, _) {
          out = computeReconData(
            ref,
            start: DateTime(2026, 7, 26),
            endExclusive: DateTime(2026, 7, 27),
            isCeo: true,
          );
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  await tester.pump();
  return out;
}

void main() {
  final saleRow = _payment(
    id: 'pay-sale',
    type: 'sale',
    amountKobo: 5000000, // ₦50,000 taken over the counter
    orderId: 'ord-1',
  );
  final remittanceRow = _payment(
    id: 'pay-remit',
    type: kPaymentTypeVanRemittance,
    amountKobo: 90000000, // ₦900,000 handed in by a driver
    vanTripId: 'trip-1',
  );

  testWidgets('a van_remittance row moves NOTHING except its own lines',
      (tester) async {
    final without = await computeWith(tester, [saleRow]);
    final with_ = await computeWith(tester, [saleRow, remittanceRow]);

    expect(
      _untouchedFigures(with_),
      equals(_untouchedFigures(without)),
      reason:
          'a remittance belongs to exactly one bucket. Any OTHER figure that '
          'moved here means a type switch grew a trailing else, or a report '
          'started summing payment rows regardless of type — which would '
          'double-count road revenue that was already recognised when the '
          'driver rang it.',
    );
  });

  testWidgets('the remittance is the whole of the movement it causes',
      (tester) async {
    final without = await computeWith(tester, [saleRow]);
    final with_ = await computeWith(tester, [saleRow, remittanceRow]);

    // #147 — the money physically arrived, so the cash card must show it. The
    // delta is exactly the remittance and nothing more.
    expect(with_.cashFromDriversKobo - without.cashFromDriversKobo, 90000000);
    expect(with_.van.remittedKobo - without.van.remittedKobo, 90000000);
    expect(with_.cashInKobo - without.cashInKobo, 90000000);
    expect(
      with_.netCashMovementKobo - without.netCashMovementKobo,
      90000000,
    );
  });

  testWidgets('"Cash sales" stays sale-only', (tester) async {
    final d = await computeWith(tester, [saleRow, remittanceRow]);

    expect(
      d.cashSalesKobo,
      5000000,
      reason:
          'the counter sale only — road takings were already recognised as '
          'revenue when the driver rang them (ADR 0019). Folding the '
          'remittance in here would count the same money twice.',
    );
    expect(d.cashDebtsCollectedKobo, 0);
    expect(d.cashRefundsKobo, 0);
    expect(d.cashExpensesKobo, 0);
    expect(d.cashCrateDepositsKobo, 0);
    expect(
      d.refundsKobo,
      0,
      reason: 'the refunds loop is type-exact and must not see a remittance',
    );
  });

  testWidgets('a remittance is never revenue, however it is scoped',
      (tester) async {
    // The remittance is store-stamped to the SOURCE WAREHOUSE, which passes
    // `reconStoreFilter` — so the TYPE check is the only thing keeping it out
    // of the sales figures. Kill it and this test goes red.
    final d = await computeWith(tester, [remittanceRow]);

    expect(d.cashSalesKobo, 0);
    expect(d.totalSalesKobo, 0);
    expect(d.totalRevenueKobo, 0);
    expect(d.itemsSold, 0);
    expect(d.netProfitKobo, 0, reason: 'settling a debt earns nothing');
    // It IS cash in, and only cash in.
    expect(d.cashFromDriversKobo, 90000000);
    expect(d.cashInKobo, 90000000);
    expect(d.netCashMovementKobo, 90000000);
  });

  testWidgets('a non-cash remittance is handed in but not cash movement',
      (tester) async {
    final transfer = _payment(
      id: 'pay-remit-transfer',
      type: kPaymentTypeVanRemittance,
      amountKobo: 40000000,
      method: 'transfer',
      vanTripId: 'trip-1',
    );
    final d = await computeWith(tester, [transfer]);

    expect(d.van.remittedKobo, 40000000, reason: 'the money did arrive');
    expect(
      d.cashFromDriversKobo,
      0,
      reason: 'the cash card is what could be counted in the drawer',
    );
    expect(d.cashInKobo, 0);
  });
}
