// recon_van_remittance_test.dart
//
// #144 (PRD #139 as amended by #161 / ADR 0019 decision 2, van-sales spec §4.7,
// §8.2) — the new `van_remittance` payment type must land in NO existing
// reconciliation bucket.
//
// Adding the "Cash from drivers" line is #147's job. This slice's obligation is
// narrower and more important: introducing a seventh payment type must not move
// a single figure the owner already reads. The failure mode this guards is the
// quiet one — a type-switch written with a trailing `else` (or a report that
// sums payment rows regardless of type) would silently fold remitted cash into
// "Cash sales", double-counting road revenue that was already recognised when
// the driver rang it, on top of a day's real takings.
//
// Method: compute the reconciliation TWICE over the same day — once with only
// an ordinary cash sale, once with that sale PLUS a remittance — and assert
// every headline figure is byte-identical. That is a stronger claim than
// checking `cashSalesKobo` alone, because it covers the buckets a future reader
// would forget to check.
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
};

Future<ReconData> computeWith(
  WidgetTester tester,
  List<PaymentTransactionData> payments,
) async {
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

  testWidgets('a van_remittance row moves NO existing reconciliation figure',
      (tester) async {
    final without = _figures(await computeWith(tester, [saleRow]));
    final with_ = _figures(await computeWith(tester, [saleRow, remittanceRow]));

    expect(
      with_,
      equals(without),
      reason:
          'van_remittance belongs to no existing bucket — it gets its own '
          '"Cash from drivers" line in #147. Any figure that moved here means '
          'a type switch grew a trailing else, or a report started summing '
          'payment rows regardless of type.',
    );
  });

  testWidgets('"Cash sales" stays sale-only', (tester) async {
    final d = await computeWith(tester, [saleRow, remittanceRow]);

    expect(
      d.cashSalesKobo,
      5000000,
      reason:
          'the counter sale only — road takings were already recognised as '
          'revenue when the driver rang them (ADR 0019)',
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

  testWidgets('a remittance is invisible even when its store IS in scope',
      (tester) async {
    // The remittance is store-stamped to the SOURCE WAREHOUSE, which passes
    // `reconStoreFilter` — so the type check is the only thing keeping it out
    // of the figures. Kill the type check and this test goes red.
    final d = await computeWith(tester, [remittanceRow]);

    expect(d.cashSalesKobo, 0);
    expect(d.cashInKobo, 0);
    expect(d.netCashMovementKobo, 0);
    expect(d.totalSalesKobo, 0);
  });
}
