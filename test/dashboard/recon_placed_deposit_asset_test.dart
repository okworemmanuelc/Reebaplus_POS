// recon_placed_deposit_asset_test.dart
//
// #215 (PRD #203, ADR 0023 rules 1 and 2; amends ADR 0014) — the slice that
// makes supplier crate money VISIBLE.
//
// ADR 0023 finding #1 states the bug in one sentence: hand a depot ₦180,000 and
// every money figure in the app reads exactly the same afterwards. #212 started
// writing the legs; this slice is where they finally land on a figure an owner
// reads. Three claims, and the third is the one most likely to be "fixed" back
// into a bug by someone reasonable:
//
//   1. **It is an ASSET.** A Placed Deposit enters `businessNetPositionKobo`.
//      The money is still the owner's — refundable, merely held elsewhere.
//
//   2. **It never reduces profit.** Not an expense, not a refund, not a cost.
//      ADR 0023 rejected booking it as one: profit would sag on delivery days
//      and spike inexplicably on the day a supplier relationship ends.
//
//   3. **It sits OUTSIDE `cashInKobo` / `cashOutKobo` / net cash movement**, on
//      a line of its own. This is the exact treatment `cashCrateDepositsKobo`
//      has had since #175 for the CUSTOMER leg, and the symmetry is the whole
//      argument. "But the money really left the drawer" is true — and equally
//      true of the customer leg, which this codebase deliberately excludes
//      anyway. #212 put the placement into `cashOutKobo` once and had to revert
//      it. If you are reading this because you are about to fold it back in,
//      fold BOTH legs in or neither; a card that treats the two ends of one
//      story differently is incoherent.
//
// Method — deliberately the shape of `recon_van_sale_exclusion_test.dart`, the
// established pattern for "this money is excluded from that total": compute the
// SAME period twice, once without the crate money and once with, and assert
// every headline figure is byte-identical except the ones this slice owns. A
// per-figure test would pass while the money leaked into a total nobody
// thought to name.
//
// The store-scope half is driven through the real `computeReconData` in a
// ProviderScope, because "business-wide under a locked store" is a claim about
// PROVIDER WIRING — no store read on the way in — and a pure-function test
// cannot see wiring at all.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/crates/crate_deposit_ledger_types.dart';
import 'package:reebaplus_pos/core/crates/crate_deposit_position.dart';
import 'package:reebaplus_pos/core/crates/crate_money_arrangement.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/stores/van_store.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';

const _biz = 'biz';
const _lagos = 'store-lagos';
const _abuja = 'store-abuja';
const _star = 'mfr-star';
final _day = DateTime(2026, 7, 30, 10);

// ₦3,500 a crate; 60 crates placed with Ade Depot, 20 with Chidi Stores.
const _rateKobo = 350000;
const _adeCrates = 60;
const _chidiCrates = 20;
const _adeKobo = _adeCrates * _rateKobo; // ₦210,000
const _chidiKobo = _chidiCrates * _rateKobo; // ₦70,000

StoreData _store(String id) => StoreData(
  id: id,
  businessId: _biz,
  name: 'Branch $id',
  location: null,
  kind: kStoreKindStore,
  isDeleted: false,
  createdAt: DateTime.utc(2026, 1, 1),
  lastUpdatedAt: DateTime.utc(2026, 1, 1),
);

BusinessData _crateBusiness() => BusinessData(
  id: _biz,
  name: 'Mama Ngozi Drinks',
  type: 'Beer Distributor',
  phone: null,
  email: null,
  logoUrl: null,
  timezone: 'Africa/Lagos',
  onboardingComplete: true,
  createdAt: DateTime.utc(2026, 1, 1),
  lastUpdatedAt: DateTime.utc(2026, 1, 1),
  ownerId: null,
  tracksEmptyCrates: true,
  subscriptionStatus: 'active',
  subscriptionPlan: null,
  trialEndsAt: null,
  currentPeriodEnd: null,
);

ManufacturerData _star_(String arrangement) => ManufacturerData(
  id: _star,
  businessId: _biz,
  name: 'Star Lager',
  emptyCrateStock: 0,
  depositAmountKobo: _rateKobo,
  crateMoneyArrangement: arrangement,
  isDeleted: false,
  createdAt: DateTime.utc(2026, 1, 1),
  lastUpdatedAt: DateTime.utc(2026, 1, 1),
);

/// The cash leg #212 writes beside every deposit ledger row. POSITIVE = money
/// went out to the supplier (see [kPaymentTypeCrateDepositOut]).
PaymentTransactionData _placementPayment({
  required String id,
  required int amountKobo,
  String method = 'cash',
  String? storeId = _lagos,
}) => PaymentTransactionData(
  id: id,
  businessId: _biz,
  storeId: storeId,
  amountKobo: amountKobo,
  method: method,
  type: kPaymentTypeCrateDepositOut,
  orderId: null,
  shipmentId: null,
  expenseId: null,
  walletTxnId: null,
  deliveryId: null,
  vanTripId: null,
  crateDepositId: 'dep-$id',
  performedBy: null,
  voidedAt: null,
  voidedBy: null,
  voidReason: null,
  createdAt: _day,
  lastUpdatedAt: _day,
);

/// One `(supplier, brand)` holding, routed through the ONE pure seam. Nothing
/// in this file computes a deposit balance itself — that is the rule the slice
/// ships under, and a test that re-derived it would stop catching a fork.
CrateDepositHolding _holding({
  required String supplierId,
  required String supplierName,
  required int amountKobo,
  required int crates,
  String arrangement = kCrateMoneyArrangementPerDelivery,
  int cratesOwed = 0,
  int pendingKobo = 0,
}) => CrateDepositHolding(
  supplierId: supplierId,
  supplierName: supplierName,
  manufacturerId: _star,
  manufacturerName: 'Star Lager',
  position: computeCrateDepositPosition(
    arrangement: crateMoneyArrangementOf(arrangement),
    ratePerCrateKobo: _rateKobo,
    movements: [
      CrateDepositMovement(
        movementType: kCrateDepositMovementPlacement,
        signedAmountKobo: amountKobo,
        crateCount: crates,
      ),
    ],
    pending: [
      if (pendingKobo != 0)
        PendingCrateDeposit(
          kind: kCrateDepositMovementPlacement,
          requestedAmountKobo: pendingKobo,
        ),
    ],
    cratesOwed: cratesOwed,
  ),
);

ReconInputs _inputs({
  CrateDepositRollup crateDeposits = CrateDepositRollup.empty,
  List<PaymentTransactionData> payments = const [],
}) => ReconInputs(
  manufacturers: [_star_(kCrateMoneyArrangementPerDelivery)],
  showCrates: true,
  crateDeposits: crateDeposits,
  payments: payments,
  isCeo: true,
);

/// Every headline figure this money could conceivably leak into. Named
/// exhaustively rather than sampled, because the failure mode is a total nobody
/// thought to check.
Map<String, int> _figures(ReconData d) => {
  'totalSalesKobo': d.totalSalesKobo,
  'totalRevenueKobo': d.totalRevenueKobo,
  'cogsKobo': d.cogsKobo,
  'grossProfitKobo': d.grossProfitKobo,
  'netProfitKobo': d.netProfitKobo,
  'periodNetResultKobo': d.periodNetResultKobo,
  'expensesKobo': d.expensesKobo,
  'refundsKobo': d.refundsKobo,
  'discountsKobo': d.discountsKobo,
  'damageCostKobo': d.damageCostKobo,
  'cashSalesKobo': d.cashSalesKobo,
  'cashDebtsCollectedKobo': d.cashDebtsCollectedKobo,
  'cashRefundsKobo': d.cashRefundsKobo,
  'cashExpensesKobo': d.cashExpensesKobo,
  'cashSupplierPaidKobo': d.cashSupplierPaidKobo,
  'cashCrateDepositsKobo': d.cashCrateDepositsKobo,
  'cashInKobo': d.cashInKobo,
  'cashOutKobo': d.cashOutKobo,
  'netCashMovementKobo': d.netCashMovementKobo,
  'supplierPaidKobo': d.supplierPaidKobo,
  'supplierPayableKobo': d.supplierPayableKobo,
  'inventoryOnHandKobo': d.inventoryOnHandKobo,
  'crateDepositKobo': d.crateDepositKobo,
  'heldCrateDepositsKobo': d.heldCrateDepositsKobo,
  'supplierCrateDebtKobo': d.supplierCrateDebtKobo,
};

void main() {
  final adeOnly = rollUpCrateDepositPositions([
    _holding(
      supplierId: 'sup-ade',
      supplierName: 'Ade Depot',
      amountKobo: _adeKobo,
      crates: _adeCrates,
      cratesOwed: _adeCrates,
    ),
  ]);
  final twoSuppliers = rollUpCrateDepositPositions([
    _holding(
      supplierId: 'sup-ade',
      supplierName: 'Ade Depot',
      amountKobo: _adeKobo,
      crates: _adeCrates,
      cratesOwed: _adeCrates,
    ),
    _holding(
      supplierId: 'sup-chidi',
      supplierName: 'Chidi Stores',
      amountKobo: _chidiKobo,
      crates: _chidiCrates,
      cratesOwed: _chidiCrates,
    ),
  ]);

  group('a Placed Deposit is an asset, and nothing else', () {
    test('it lifts business worth by exactly what was placed', () {
      final before = reconDataFrom(_inputs());
      final after = reconDataFrom(
        _inputs(
          crateDeposits: adeOnly,
          payments: [_placementPayment(id: 'p1', amountKobo: _adeKobo)],
        ),
      );

      expect(before.placedCrateDepositsKobo, 0);
      expect(after.placedCrateDepositsKobo, _adeKobo);
      expect(
        after.businessNetPositionKobo,
        before.businessNetPositionKobo + _adeKobo,
        reason:
            'the money is still the owner\'s — refundable, merely held by the '
            'depot (ADR 0023 rule 1). Before #215 it left the drawer and '
            'vanished from worth entirely.',
      );
    });

    test('placing it moves NO other figure — above all not profit', () {
      // The van-exclusion shape: same period, computed twice.
      final without = _figures(reconDataFrom(_inputs()));
      final with_ = _figures(
        reconDataFrom(
          _inputs(
            crateDeposits: twoSuppliers,
            payments: [
              _placementPayment(id: 'p1', amountKobo: _adeKobo),
              _placementPayment(id: 'p2', amountKobo: _chidiKobo),
            ],
          ),
        ),
      );

      expect(
        with_,
        equals(without),
        reason:
            'a Placed Deposit is refundable money that changed shape, not a '
            'cost. A figure that moved means it leaked into a total it must '
            'never reach. If `netProfitKobo` moved, the app is now telling an '
            'owner that paying a crate deposit made them poorer — the exact '
            'misstatement ADR 0023 rejected booking it as an expense to avoid.',
      );
    });

    test('the pending leg is money that has NOT moved: outside worth and '
        'outside the cash line', () {
      // ADR 0023 rule 6 — a book entry appears only when money genuinely
      // moved. A leg awaiting a manager is disclosed beside the balance, never
      // inside it.
      final rollup = rollUpCrateDepositPositions([
        _holding(
          supplierId: 'sup-ade',
          supplierName: 'Ade Depot',
          amountKobo: _adeKobo,
          crates: _adeCrates,
          pendingKobo: 4200000, // ₦42,000 awaiting confirmation
        ),
      ]);
      final d = reconDataFrom(
        _inputs(
          crateDeposits: rollup,
          payments: [_placementPayment(id: 'p1', amountKobo: _adeKobo)],
        ),
      );

      expect(d.crateDeposits.pendingDepositKobo, 4200000);
      expect(d.placedCrateDepositsKobo, _adeKobo);
      expect(d.cashCrateDepositsPlacedKobo, _adeKobo);
      expect(
        d.businessNetPositionKobo,
        reconDataFrom(_inputs()).businessNetPositionKobo + _adeKobo,
      );
    });
  });

  group('the cash line is its own line, outside the net', () {
    ReconData placed({int amountKobo = _adeKobo, String method = 'cash'}) =>
        reconDataFrom(
          _inputs(
            crateDeposits: adeOnly,
            payments: [
              _placementPayment(
                id: 'p1',
                amountKobo: amountKobo,
                method: method,
              ),
            ],
          ),
        );

    test('the placement lands on `cashCrateDepositsPlacedKobo` and on nothing '
        'else', () {
      final d = placed();
      expect(d.cashCrateDepositsPlacedKobo, _adeKobo);

      // The three totals it must never touch. `cashOutKobo` is the one #212
      // got wrong and reverted, and it is the one a well-meaning reader will
      // "fix" back — see this file's header before you do.
      expect(d.cashOutKobo, 0);
      expect(d.cashInKobo, 0);
      expect(d.netCashMovementKobo, 0);
      // Nor the neighbouring cash-out buckets it superficially resembles.
      expect(d.cashExpensesKobo, 0);
      expect(d.cashSupplierPaidKobo, 0);
      expect(d.cashRefundsKobo, 0);
      // Nor the CUSTOMER leg. Two ends of one story, two separate lines.
      expect(d.cashCrateDepositsKobo, 0);
    });

    test('the two crate-deposit legs get identical treatment — that symmetry '
        'IS the design', () {
      // Both refundable, both through the drawer, both outside the net. If a
      // later change puts one inside `cashIn`/`cashOut`, this fails and it
      // should: the card is only coherent if the two ends match.
      final customerLeg = reconDataFrom(
        ReconInputs(
          showCrates: true,
          isCeo: true,
          payments: [
            PaymentTransactionData(
              id: 'p-cust',
              businessId: _biz,
              storeId: _lagos,
              amountKobo: 500000,
              method: 'cash',
              type: 'crate_deposit',
              orderId: null,
              shipmentId: null,
              expenseId: null,
              walletTxnId: null,
              deliveryId: null,
              vanTripId: null,
              crateDepositId: null,
              performedBy: null,
              voidedAt: null,
              voidedBy: null,
              voidReason: null,
              createdAt: _day,
              lastUpdatedAt: _day,
            ),
          ],
        ),
      );
      expect(customerLeg.cashCrateDepositsKobo, 500000);
      expect(customerLeg.cashInKobo, 0);
      expect(customerLeg.cashOutKobo, 0);
      expect(customerLeg.netCashMovementKobo, 0);

      final supplierLeg = placed();
      expect(supplierLeg.cashCrateDepositsPlacedKobo, _adeKobo);
      expect(supplierLeg.cashInKobo, 0);
      expect(supplierLeg.cashOutKobo, 0);
      expect(supplierLeg.netCashMovementKobo, 0);
    });

    test('a settlement in the same period nets the line back down', () {
      // Signed at the source: − when money came back to us (#213/#214).
      final d = reconDataFrom(
        _inputs(
          crateDeposits: adeOnly,
          payments: [
            _placementPayment(id: 'p1', amountKobo: _adeKobo),
            _placementPayment(id: 'p2', amountKobo: -_adeKobo),
          ],
        ),
      );
      expect(d.cashCrateDepositsPlacedKobo, 0);
      expect(d.netCashMovementKobo, 0);
    });

    test('a transfer-tender placement is not on the CASH line at all', () {
      // The cash card states cash CUSTODY. A deposit paid by transfer never
      // touched the drawer.
      expect(placed(method: 'transfer').cashCrateDepositsPlacedKobo, 0);
    });
  });

  group('the sixth card: in total, and by supplier', () {
    test('it names who is holding what, biggest holder first', () {
      final d = reconDataFrom(
        _inputs(
          crateDeposits: twoSuppliers,
          payments: [
            _placementPayment(id: 'p1', amountKobo: _adeKobo),
            _placementPayment(id: 'p2', amountKobo: _chidiKobo),
          ],
        ),
      );

      expect(d.crateDeposits.placedDepositKobo, _adeKobo + _chidiKobo);
      expect(
        d.crateDeposits.bySupplier.map((s) => s.supplierName),
        ['Ade Depot', 'Chidi Stores'],
        reason: 'the supplier sitting on the most of the owner\'s money is the '
            'one they will ring',
      );
      expect(d.crateDeposits.bySupplier.first.placedDepositKobo, _adeKobo);
      expect(d.crateDeposits.bySupplier.last.placedDepositKobo, _chidiKobo);
      // The total is the sum of the parts, by construction.
      expect(
        d.crateDeposits.bySupplier.fold<int>(
          0,
          (s, x) => s + x.placedDepositKobo,
        ),
        d.crateDeposits.placedDepositKobo,
      );
      expect(d.placedCrateDepositsKobo, d.crateDeposits.placedDepositKobo);
    });

    test('a `none` brand is dropped, not rendered at zero — so the card never '
        'appears for a swap-only business', () {
      // THE RELEASE GATE, at the card. `none` is not "settled"; it is not in
      // this story at all, and a zero row would invite an owner to reconcile a
      // figure that will never move.
      final rollup = rollUpCrateDepositPositions([
        _holding(
          supplierId: 'sup-ade',
          supplierName: 'Ade Depot',
          amountKobo: _adeKobo,
          crates: _adeCrates,
          arrangement: kCrateMoneyArrangementNone,
        ),
      ]);
      expect(rollup.bySupplier, isEmpty);
      expect(rollup.placedDepositKobo, 0);
      expect(rollup.hasMoney, isFalse, reason: 'the card renders on hasMoney');

      final d = reconDataFrom(_inputs(crateDeposits: rollup));
      expect(d.placedCrateDepositsKobo, 0);
      expect(d.crateDeposits.hasMoney, isFalse);
    });

    test('a non-crate business carries no crate money at all', () {
      final d = reconDataFrom(
        ReconInputs(
          showCrates: false,
          isCeo: true,
          crateDeposits: twoSuppliers,
        ),
      );
      expect(d.placedCrateDepositsKobo, 0);
      expect(d.crateDeposits.hasMoney, isFalse);
    });

    test('crates owed with no deposit behind them are DISCLOSED, never netted '
        'into the money', () {
      // ADR 0023 finding #3 — "two numbers that never meet". A brand switched
      // on today owes hundreds of crates received under `none`; ADR 0021
      // forbids restating that history, so the gap is shown beside the money
      // rather than silently reported as it.
      final rollup = rollUpCrateDepositPositions([
        _holding(
          supplierId: 'sup-ade',
          supplierName: 'Ade Depot',
          amountKobo: _adeKobo,
          crates: _adeCrates,
          cratesOwed: _adeCrates + 40, // 40 crates predate the switch-on
        ),
      ]);
      expect(rollup.unbackedValueKobo, 40 * _rateKobo);
      expect(
        rollup.placedDepositKobo,
        _adeKobo,
        reason: 'the disclosure must not move the money figure',
      );
    });
  });

  group('business-wide, even under a locked store', () {
    // The claim is about WIRING: `computeReconData` must read the crate-money
    // roll-up from a business-scoped provider that never consults the active
    // store. Supplier crate money is a company obligation — the depot invoices
    // the business, not the branch — and splitting it per store would repeat
    // `CRATE_TRACKING_AUDIT` C4 and let two branches each claim the same money.
    Future<ReconData> computeUnder(
      WidgetTester tester, {
      required String? lockedStoreId,
    }) async {
      await tester.pumpWidget(const SizedBox.shrink());
      late ReconData out;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentBusinessIdProvider.overrideWithValue(null),
            currentBusinessProvider.overrideWith((ref) => _crateBusiness()),
            businessCrateDepositRollupProvider.overrideWith(
              (ref) => Stream.value(twoSuppliers),
            ),
            allPaymentTransactionsProvider.overrideWith(
              (ref) => Stream.value([
                _placementPayment(id: 'p1', amountKobo: _adeKobo),
                // Stamped to the OTHER branch, to prove the figure does not
                // follow the store the money happened to be paid from.
                _placementPayment(
                  id: 'p2',
                  amountKobo: _chidiKobo,
                  storeId: _abuja,
                ),
              ]),
            ),
            selectableStoresProvider.overrideWithValue([
              _store(_lagos),
              _store(_abuja),
            ]),
            canViewAllStoresProvider.overrideWithValue(true),
            lockedStoreProvider.overrideWith(
              (ref) => ValueNotifier<String?>(lockedStoreId),
            ),
            vanStoresProvider.overrideWithValue(
              VanStores.of([_store(_lagos), _store(_abuja)]),
            ),
          ],
          child: Consumer(
            builder: (_, ref, _) {
              out = computeReconData(
                ref,
                start: DateTime(2026, 7, 30),
                endExclusive: DateTime(2026, 7, 31),
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

    testWidgets('all three scopes read the same figure', (tester) async {
      final allStores = await computeUnder(tester, lockedStoreId: null);
      final lagos = await computeUnder(tester, lockedStoreId: _lagos);
      final abuja = await computeUnder(tester, lockedStoreId: _abuja);

      const expected = _adeKobo + _chidiKobo;
      for (final entry in {
        'All Stores': allStores,
        'Lagos': lagos,
        'Abuja': abuja,
      }.entries) {
        expect(
          entry.value.placedCrateDepositsKobo,
          expected,
          reason:
              '${entry.key} must read the whole business. A per-store figure '
              'would let Lagos and Abuja each believe the same depot money is '
              'theirs (CRATE_TRACKING_AUDIT C4).',
        );
        expect(
          entry.value.crateDeposits.bySupplier.length,
          2,
          reason: '${entry.key}: the by-supplier breakdown is business-wide too',
        );
        expect(
          entry.value.cashCrateDepositsPlacedKobo,
          expected,
          reason:
              '${entry.key}: the cash line is business-wide like the rest of '
              'the cash card (payment_transactions has no store scope here)',
        );
        // …and it still never reaches the net, whatever the scope.
        expect(entry.value.netCashMovementKobo, 0);
      }
    });
  });
}
