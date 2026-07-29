// recon_deposit_release_test.dart
//
// #190 — a crate-deposit RELEASE must move exactly one reconciliation line.
//
// The deposit paths that hand money back (Confirm's
// `OrdersDao.settleCrateDepositReturn` and §18.3's
// `CreditLedgerService.refundCash`) used to post a POSITIVE `refund` payment
// row. That put held money into two places it never belonged:
//
//   · "Refunds" on the Sales summary card — a sales refund that never
//     happened, for a collection that was never in Cash sales; and
//   · `periodNetResultKobo`, which SUBTRACTS `refundsKobo` — so returning a
//     ₦2,500 deposit read as a flat ₦2,500 loss, for money the business only
//     ever held on the customer's behalf.
//
// Meanwhile the line that SHOULD have moved — "Crate deposits held (cash)",
// which sums `crate_deposit` rows — never netted down, so held deposits grew
// forever. Same-period collect-then-return still tied at the drawer total (the
// two errors cancel), which is exactly why this was invisible; across periods
// it does not net at all.
//
// The fix types the release as a NEGATIVE `crate_deposit` — the in-family
// reversal `markCancelled` already documented. This file pins the REPORT
// consequence rather than the row shape (the DAO tests pin that): computing the
// same day with and without the release row, the ONLY figure allowed to differ
// is the held-deposit line, and it must net to zero.
//
// Method and provider-override strategy follow `recon_van_remittance_test.dart`
// — overriding `currentBusinessIdProvider` with null makes every business-scoped
// provider emit its `whenAbsent` value without touching a database, so only the
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
const _store = 'store-1';
final _day = DateTime(2026, 7, 29, 10);

StoreData _storeRow(String id) => StoreData(
  id: id,
  businessId: _biz,
  name: 'Location $id',
  location: null,
  kind: kStoreKindStore,
  isDeleted: false,
  createdAt: DateTime.utc(2026, 1, 1),
  lastUpdatedAt: DateTime.utc(2026, 1, 1),
);

PaymentTransactionData _payment({
  required String id,
  required String type,
  required int amountKobo,
  String method = 'cash',
  String? orderId,
  String? walletTxnId,
}) => PaymentTransactionData(
  id: id,
  businessId: _biz,
  storeId: _store,
  amountKobo: amountKobo,
  method: method,
  type: type,
  orderId: orderId,
  shipmentId: null,
  expenseId: null,
  walletTxnId: walletTxnId,
  deliveryId: null,
  vanTripId: null,
  performedBy: null,
  voidedAt: null,
  voidedBy: null,
  voidReason: null,
  createdAt: _day,
  lastUpdatedAt: _day,
);

/// Every figure a stray payment type could disturb, including the two the bug
/// actually corrupted (`refundsKobo` and the net result it feeds).
Map<String, int> _figures(ReconData d) => {
  'totalSalesKobo': d.totalSalesKobo,
  'refundsKobo': d.refundsKobo,
  'netProfitKobo': d.netProfitKobo,
  'periodNetResultKobo': d.periodNetResultKobo,
  'cashSalesKobo': d.cashSalesKobo,
  'cashDebtsCollectedKobo': d.cashDebtsCollectedKobo,
  'cashRefundsKobo': d.cashRefundsKobo,
  'cashExpensesKobo': d.cashExpensesKobo,
  'cashCrateDepositsKobo': d.cashCrateDepositsKobo,
  'cashInKobo': d.cashInKobo,
  'cashOutKobo': d.cashOutKobo,
  'netCashMovementKobo': d.netCashMovementKobo,
};

Future<ReconData> computeWith(
  WidgetTester tester,
  List<PaymentTransactionData> payments,
) async {
  // Tear the previous ProviderScope down first, so a second compute in the same
  // test cannot read the first's stream value and pass vacuously.
  await tester.pumpWidget(const SizedBox.shrink());
  late ReconData out;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentBusinessIdProvider.overrideWithValue(null),
        allPaymentTransactionsProvider.overrideWith(
          (ref) => Stream.value(payments),
        ),
        selectableStoresProvider.overrideWithValue([_storeRow(_store)]),
        canViewAllStoresProvider.overrideWithValue(true),
        lockedStoreProvider.overrideWith((ref) => ValueNotifier<String?>(null)),
        vanStoresProvider.overrideWithValue(VanStores.of([_storeRow(_store)])),
      ],
      child: Consumer(
        builder: (_, ref, _) {
          out = computeReconData(
            ref,
            start: DateTime(2026, 7, 29),
            endExclusive: DateTime(2026, 7, 30),
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
  // A ₦2,500 deposit collected at checkout (#175 writes this row).
  final collection = _payment(
    id: 'pay-deposit',
    type: 'crate_deposit',
    amountKobo: 250000,
    orderId: 'ord-1',
  );
  // The release the crates coming back triggers — the row #190 retyped.
  final release = _payment(
    id: 'pay-deposit-release',
    type: 'crate_deposit',
    amountKobo: -250000,
    walletTxnId: 'wtx-refunded',
  );
  // What the release USED to be, kept as the counter-example below.
  final asRefund = _payment(
    id: 'pay-deposit-release',
    type: 'refund',
    amountKobo: 250000,
    walletTxnId: 'wtx-refunded',
  );

  testWidgets('a deposit release moves NOTHING except the held-deposit line',
      (tester) async {
    final held = await computeWith(tester, [collection]);
    final released = await computeWith(tester, [collection, release]);

    final untouched = Map.of(_figures(released))
      ..remove('cashCrateDepositsKobo');
    expect(
      untouched,
      equals(Map.of(_figures(held))..remove('cashCrateDepositsKobo')),
      reason:
          'handing a deposit back is not a sale, not a refund, and not a loss '
          '— it releases money the business only held. Any other figure that '
          'moved here means the release leaked out of its own family again.',
    );
  });

  testWidgets('the held-deposit line nets to zero on release', (tester) async {
    final held = await computeWith(tester, [collection]);
    final released = await computeWith(tester, [collection, release]);

    expect(held.cashCrateDepositsKobo, 250000,
        reason: 'collected but not yet returned — still held');
    expect(released.cashCrateDepositsKobo, 0,
        reason: 'collect then return in one period nets the held line to zero');
  });

  testWidgets('the release is invisible to Refunds and the period net result',
      (tester) async {
    final released = await computeWith(tester, [collection, release]);

    expect(released.refundsKobo, 0,
        reason: 'the collection was never in Cash sales, so its release must '
            'never appear in Cash refunds');
    expect(released.cashRefundsKobo, 0);
    expect(released.periodNetResultKobo, 0,
        reason: 'no revenue was ever recognised for a held deposit, so '
            'returning it cannot be a loss');
  });

  testWidgets('typing the same release `refund` is what broke both lines',
      (tester) async {
    // The counter-example, so the regression states its own failure mode: the
    // pre-#190 row shape shows a phantom ₦2,500 refund AND a ₦2,500 loss, while
    // the held line stays stuck at the full deposit.
    final wrong = await computeWith(tester, [collection, asRefund]);

    expect(wrong.refundsKobo, 250000);
    expect(wrong.periodNetResultKobo, -250000);
    expect(wrong.cashCrateDepositsKobo, 250000,
        reason: 'and the held line never nets down');
  });
}
