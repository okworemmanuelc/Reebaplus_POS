// crate_money_arrangement_test.dart
//
// #211 / PRD #203, ADR 0023 rule 3 — the Crate Money Arrangement, and above all
// its DEFAULT.
//
// The setting itself is small: three values on a manufacturer saying whether
// crate money moves for that brand and when. What matters is that every
// manufacturer that already exists reads `none`, because that default is the
// release gate for all eight slices of PRD #203 — it is what lets the money
// slices behind it ship to live production without moving a single tenant's
// figures.
//
// So this suite pins four things:
//   1. `none` is what you get: on insert, on a NULL/garbage cloud value, and
//      after the 77→78 upgrade (that last one lives in
//      test/database/migration_upgrade_test.dart, which owns the on-disk
//      upgrade path).
//   2. THE RELEASE GATE — a business whose every manufacturer is `none`
//      produces the same reconciliation figures it produced before this slice
//      existed, to the kobo.
//   3. The setting has no readers outside its own module, the schema, the sync
//      registry, the one write method and the picker — so there is no path by
//      which it could move a figure yet.
//   4. The write boundary round-trips and enqueues.

import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/crates/crate_deposit_ledger_types.dart';
import 'package:reebaplus_pos/core/crates/crate_deposit_position.dart';
import 'package:reebaplus_pos/core/crates/crate_money_arrangement.dart';
import 'package:reebaplus_pos/core/crates/crate_shortfall.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';

void main() {
  const businessId = 'biz-1';
  const star = 'mfr-star';
  const gulder = 'mfr-gulder';

  ManufacturerData mfr(
    String id,
    String name,
    int depositKobo, {
    String arrangement = kCrateMoneyArrangementNone,
  }) => ManufacturerData(
    id: id,
    businessId: businessId,
    name: name,
    emptyCrateStock: 0,
    depositAmountKobo: depositKobo,
    crateMoneyArrangement: arrangement,
    isDeleted: false,
    createdAt: DateTime.utc(2026, 1, 1),
    lastUpdatedAt: DateTime.utc(2026, 1, 1),
  );

  group('`none` is what you get', () {
    late AppDatabase db;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      db.businessIdResolver = () => businessId;
      await db
          .into(db.businesses)
          .insert(
            BusinessesCompanion.insert(
              id: const Value(businessId),
              name: 'Biz',
              type: const Value('Bar'),
            ),
          );
    });

    tearDown(() => db.close());

    test('a manufacturer created without naming an arrangement is `none`',
        () async {
      await db
          .into(db.manufacturers)
          .insert(
            ManufacturersCompanion.insert(
              id: const Value(star),
              businessId: businessId,
              name: 'Star Lager',
              depositAmountKobo: const Value(350000),
            ),
          );

      final row = await (db.select(
        db.manufacturers,
      )..where((t) => t.id.equals(star))).getSingle();
      expect(row.crateMoneyArrangement, kCrateMoneyArrangementNone);
      expect(
        crateMoneyArrangementOf(row.crateMoneyArrangement),
        CrateMoneyArrangement.none,
      );
      expect(CrateMoneyArrangement.none.movesMoney, isFalse);
    });

    test('an unreadable value fails CLOSED to `none`, never to a money mode',
        () {
      // A null from a cloud row written before 0171, a blank, a value some
      // future client invented. A wrong money movement costs far more than a
      // missed one, so anything we cannot read means "no money moves".
      for (final bad in <String?>[null, '', 'None', 'per delivery', 'float']) {
        expect(
          crateMoneyArrangementOf(bad),
          CrateMoneyArrangement.none,
          reason: '$bad must not be read as a money-moving arrangement',
        );
      }
    });

    test('the three values are the three the cloud CHECK allows', () async {
      expect(kCrateMoneyArrangements, [
        'none',
        'per_delivery',
        'standing_float',
      ]);
      expect(
        CrateMoneyArrangement.values.map((a) => a.wire),
        kCrateMoneyArrangements,
      );
      expect(
        CrateMoneyArrangement.values.where((a) => a.movesMoney).map((a) => a.wire),
        ['per_delivery', 'standing_float'],
      );

      // The client's set and the cloud's CHECK must not drift — a value the
      // client can write but the CHECK rejects jams the outbox (23514).
      final sql = await File(
        'supabase/migrations/0171_crate_money_arrangement.sql',
      ).readAsString();
      expect(
        sql,
        contains(
          "CHECK (crate_money_arrangement IN "
          "('none','per_delivery','standing_float'))",
        ),
      );
      expect(
        sql,
        contains("crate_money_arrangement text NOT NULL DEFAULT 'none'"),
        reason: 'the cloud default is the other half of the release gate',
      );
    });
  });

  group('THE RELEASE GATE — every manufacturer at `none` moves no figure', () {
    // A real crate business's day: two brands, empties on hand, deposits held
    // for customers, and crate debt owed to a supplier. Every figure below is
    // hand-computed from the domain rules, NOT snapshotted from a run — so if
    // this slice had perturbed anything (a migration that disturbed the rate, a
    // figure path that started consulting the new column) the arithmetic here
    // would disagree with the code.
    const starDeposit = 350000; // ₦3,500 a crate
    const gulderDeposit = 300000; // ₦3,000 a crate
    const starEmpties = 42;
    const gulderEmpties = 7;
    const heldForCustomers = 1400000; // ₦14,000 of customer deposits held
    const owedToSuppliers = 900000; // ₦9,000 of crate debt owed out
    // #215 — the money the arrangement now genuinely moves: a depot sitting on
    // ₦180,000 of ours for 60 crates of Star, and the cash that left the drawer
    // to place it there.
    const placedWithDepot = 18000000;
    const placedCrates = 60;
    // #216 — a shortfall the owner deliberately accepted: 4 crates of Star at
    // ₦3,500. The ONE figure in PRD #203 that reaches profit.
    const writtenOffCrates = 4;
    const writtenOffKobo = writtenOffCrates * starDeposit; // ₦14,000
    // #217 — a customer who never brought 3 crates of Star back. The deposit
    // they paid stays with the business (income since #176, on EVERY
    // arrangement), and on a switched-on brand the crate they kept raises a
    // matching shortfall so the pair nets to zero.
    const forfeitCrates = 3;
    const forfeitKobo = forfeitCrates * starDeposit; // ₦10,500

    /// A cash `crate_deposit_out` row — the payment leg #212 writes beside the
    /// deposit ledger row. Positive = money went OUT to the supplier.
    PaymentTransactionData placementPayment() => PaymentTransactionData(
      id: 'pay-placement',
      businessId: businessId,
      storeId: 'store-1',
      amountKobo: placedWithDepot,
      method: 'cash',
      type: kPaymentTypeCrateDepositOut,
      orderId: null,
      shipmentId: null,
      expenseId: null,
      walletTxnId: null,
      deliveryId: null,
      vanTripId: null,
      crateDepositId: 'dep-1',
      performedBy: null,
      voidedAt: null,
      voidedBy: null,
      voidReason: null,
      createdAt: DateTime.utc(2026, 7, 30),
      lastUpdatedAt: DateTime.utc(2026, 7, 30),
    );

    /// The `crate_deposit_forfeited` wallet debit a kept deposit writes (#176).
    /// Fed to EVERY arrangement, because a kept deposit really was kept on every
    /// brand — #217 does not suppress the income, it adds the other half.
    WalletTransactionData forfeitRow() => WalletTransactionData(
      id: 'wt-forfeit',
      businessId: businessId,
      walletId: 'wallet-1',
      customerId: 'cust-1',
      type: 'debit',
      amountKobo: forfeitKobo,
      signedAmountKobo: -forfeitKobo,
      referenceType: 'crate_deposit_forfeited',
      orderId: 'ord-1',
      customerVerified: false,
      performedBy: null,
      voidedAt: null,
      voidedBy: null,
      voidReason: null,
      createdAt: DateTime.utc(2026, 7, 30),
      lastUpdatedAt: DateTime.utc(2026, 7, 30),
    );

    /// The business as the app would actually hold it for [arrangement].
    ///
    /// The deposit ledger row is fed to EVERY arrangement, `none` included: the
    /// seam short-circuits before it reads a single movement, so residue from a
    /// brand that was switched on, used, and switched off again cannot move a
    /// figure. The PAYMENT row is gated on `movesMoney` instead, because that
    /// is where the write boundary gates it — a `none` brand admits no leg
    /// (`crateDepositKindAllowedFor`), so no `crate_deposit_out` row is ever
    /// written for one, and the cash line's allowlist dispatch is deliberately
    /// arrangement-blind.
    ReconInputs inputsWith(String arrangement) {
      final a = crateMoneyArrangementOf(arrangement);
      return ReconInputs(
        manufacturers: [
          mfr(star, 'Star Lager', starDeposit, arrangement: arrangement),
          mfr(gulder, 'Gulder', gulderDeposit, arrangement: arrangement),
        ],
        emptyCrateCounts: const {star: starEmpties, gulder: gulderEmpties},
        showCrates: true,
        heldCrateDepositsKobo: heldForCustomers,
        supplierCrateDebtKobo: owedToSuppliers,
        // Everything reads through the ONE pure seam and its roll-up — no
        // report re-derives the arithmetic (#212/#215).
        crateDeposits: rollUpCrateDepositPositions([
          CrateDepositHolding(
            supplierId: 'sup-ade',
            supplierName: 'Ade Depot',
            manufacturerId: star,
            manufacturerName: 'Star Lager',
            position: computeCrateDepositPosition(
              arrangement: a,
              ratePerCrateKobo: starDeposit,
              movements: const [
                CrateDepositMovement(
                  movementType: kCrateDepositMovementPlacement,
                  signedAmountKobo: placedWithDepot,
                  crateCount: placedCrates,
                ),
              ],
            ),
          ),
        ]),
        payments: a.movesMoney ? [placementPayment()] : const [],
        // #216 — fed to EVERY arrangement, `none` included, for exactly the
        // reason the deposit ledger row above is: the gate must be the owner's
        // stated arrangement, not the absence of a row. A brand switched on,
        // written off against, then switched back off must stop reducing
        // profit — and it does, because the write-off math reads the
        // arrangement and skips a `none` brand.
        crateShortfallWriteOffs: [
          CrateShortfallWriteoffData(
            id: 'wo-1',
            businessId: businessId,
            manufacturerId: star,
            storeId: 'store-1',
            crateCount: writtenOffCrates,
            source: kCrateWriteOffSourceManual,
            ratePerCrateKobo: starDeposit,
            note: null,
            performedBy: null,
            createdAt: DateTime.utc(2026, 7, 30),
            lastUpdatedAt: DateTime.utc(2026, 7, 30),
          ),
          // #217 — the NETTING row a customer forfeit raises. Gated on
          // `movesMoney`, like the payment row above and for the same reason:
          // this is where the WRITE BOUNDARY gates it. A `none` brand's forfeit
          // never writes one at all
          // (`CratePoolDao.recordCustomerForfeitShortfall` returns null), so a
          // fixture that fed one to `none` would be testing a state the app
          // cannot reach — and it would hide the fact that `none` keeps its
          // income because no row exists, not merely because the math skips it.
          if (a.movesMoney)
            CrateShortfallWriteoffData(
              id: 'wo-forfeit',
              businessId: businessId,
              manufacturerId: star,
              storeId: 'store-1',
              crateCount: forfeitCrates,
              source: kCrateWriteOffSourceCustomerForfeit,
              ratePerCrateKobo: starDeposit,
              note: null,
              performedBy: null,
              createdAt: DateTime.utc(2026, 7, 30),
              lastUpdatedAt: DateTime.utc(2026, 7, 30),
            ),
        ],
        // #217 — the kept deposit itself, on EVERY arrangement. This is the
        // income the netting cancels, and it is NOT arrangement-gated: the
        // customer's money was kept whatever the brand's setting says.
        crateForfeitRows: [forfeitRow()],
        isCeo: true,
      );
    }

    /// Every figure a crate-money change could conceivably disturb — now
    /// including the two #215 added, so a leak into either is caught here too.
    Map<String, int> figures(ReconData d) => {
      'crateUnits': d.crateUnits,
      'crateDepositKobo': d.crateDepositKobo,
      'heldCrateDepositsKobo': d.heldCrateDepositsKobo,
      'supplierCrateDebtKobo': d.supplierCrateDebtKobo,
      'placedCrateDepositsKobo': d.placedCrateDepositsKobo,
      'cashCrateDepositsPlacedKobo': d.cashCrateDepositsPlacedKobo,
      'crateShortfallWrittenOffKobo': d.crateShortfallWrittenOffKobo,
      // #217 — the netting, and the income it cancels. BOTH are listed: the
      // first is a figure this slice is allowed to move, the second is one it
      // must NOT, and that pairing is the point.
      'crateForfeitNettedKobo': d.crateForfeitNettedKobo,
      'forfeitIncomeKobo': d.forfeitIncomeKobo,
      'businessNetPositionKobo': d.businessNetPositionKobo,
      'periodNetResultKobo': d.periodNetResultKobo,
      'totalSalesKobo': d.totalSalesKobo,
      'netProfitKobo': d.netProfitKobo,
      'refundsKobo': d.refundsKobo,
      'expensesKobo': d.expensesKobo,
      'cashInKobo': d.cashInKobo,
      'cashOutKobo': d.cashOutKobo,
      'netCashMovementKobo': d.netCashMovementKobo,
      'inventoryOnHandKobo': d.inventoryOnHandKobo,
      'goodsReceivedKobo': d.goodsReceivedKobo,
      'supplierPaidKobo': d.supplierPaidKobo,
      'crateDamageDepositKobo': d.crateDamageDepositKobo,
    };

    /// The keys a money-moving arrangement is ALLOWED to move once a brand is
    /// switched on. Every other key in [figures] must stay byte-identical to
    /// the `none` reading — that is what "narrowed", rather than "deleted",
    /// means below.
    ///
    /// **NARROWED AGAIN BY #216, NOT DELETED.** #215 owned the first three: a
    /// Placed Deposit is an asset and a cash line, and it may never reach
    /// profit. #216 adds the three that a WRITE-OFF moves, and this is the
    /// first and only time this PRD is permitted to touch profit at all:
    ///
    ///   * `crateShortfallWrittenOffKobo` — the accepted loss itself;
    ///   * `netProfitKobo` and `periodNetResultKobo` — the two lines it lands
    ///     in, because crates the owner has accepted as lost are deposit value
    ///     the business will not get back.
    ///
    /// Note what is STILL forbidden, and why the list grew by exactly three:
    /// `cashInKobo`, `cashOutKobo`, `netCashMovementKobo`, `expensesKobo` and
    /// `refundsKobo` are all unchanged. No cash moves when an owner accepts a
    /// loss — the money left, or never arrived, long ago — and a crate loss is
    /// not an expense and not a refund (the #190/#201 family defect).
    /// `businessNetPositionKobo` moves only by #215's asset, never by the
    /// write-off: the crate left the yard when it went missing and worth fell
    /// then; this books the P&L half of an event worth already knew about.
    ///
    /// **NARROWED ONCE MORE BY #217 — the last slice of the PRD.** It adds
    /// exactly ONE key, `crateForfeitNettedKobo`, and moves no line #216 had
    /// not already opened: a forfeit nets by raising a Crate Shortfall, so it
    /// lands in `crateShortfallWrittenOffKobo` and flows to the same two profit
    /// lines. What changes is the MAGNITUDE of those three, and the magnitudes
    /// are pinned below precisely because a permitted key drifting by the wrong
    /// amount would sail through the comparison and be wrong.
    ///
    /// Note the key #217 deliberately did NOT add: `forfeitIncomeKobo`. A kept
    /// deposit really was kept, on every brand, and it reads the same at `none`
    /// and at `per_delivery`. The slice does not hide the income — it books the
    /// crate the income paid for, which is a different figure, so the two cancel
    /// instead of one of them vanishing. If a later change makes the income
    /// itself depend on the arrangement, this list is where it must be argued
    /// for, and the argument had better be very good.
    ///
    /// TO ANYONE AFTER THIS PRD: if settlement-time attribution (ADR 0023 rule
    /// 4's "attribution happens once, at settlement") is ever built, narrow this
    /// again rather than deleting it. The `none` row must keep matching the
    /// pre-slice figures forever — it is the promise the whole PRD ships on.
    const movedByThisSlice = {
      'placedCrateDepositsKobo',
      'cashCrateDepositsPlacedKobo',
      'businessNetPositionKobo',
      // #216 — the loss, and the two lines it reaches.
      'crateShortfallWrittenOffKobo',
      'netProfitKobo',
      'periodNetResultKobo',
      // #217 — the forfeit netting: a disclosure split of the loss above, and
      // the only new key this slice needs.
      'crateForfeitNettedKobo',
    };

    test('the figures a crate business reads are exactly what they were before '
        'this slice', () {
      final d = reconDataFrom(inputsWith(kCrateMoneyArrangementNone));

      // Empties held, valued at the ONE canonical rate —
      // `manufacturers.deposit_amount_kobo`. Nothing here reads
      // `crate_size_groups.deposit_amount_kobo`, which is dead.
      expect(d.crateUnits, starEmpties + gulderEmpties); // 49
      expect(
        d.crateDepositKobo,
        starEmpties * starDeposit + gulderEmpties * gulderDeposit,
      ); // 42×350000 + 7×300000 = 16,800,000
      expect(d.crateDepositKobo, 16800000);

      // Both crate liabilities still net out of worth (#163) untouched.
      expect(d.heldCrateDepositsKobo, heldForCustomers);
      expect(d.supplierCrateDebtKobo, owedToSuppliers);

      // Net worth = empties asset − deposits held for customers − crate debt
      // owed to suppliers. No inventory, no in-transit, no customer debt, no
      // supplier payable in this fixture.
      expect(
        d.businessNetPositionKobo,
        16800000 - heldForCustomers - owedToSuppliers,
      );
      expect(d.businessNetPositionKobo, 14500000);

      // Nothing became an expense or a cash movement. A Placed Deposit is an
      // ASSET, never an expense (ADR 0023 rule 1) — and at `none` there is no
      // placed deposit at all.
      expect(d.periodNetResultKobo, 0);
      expect(d.totalSalesKobo, 0);
      expect(d.expensesKobo, 0);
      expect(d.netCashMovementKobo, 0);
      expect(d.crateDamageDepositKobo, 0);

      // #217 — the ONE thing at `none` that is not zero, and it is the
      // pre-PRD behaviour, unchanged: a kept crate deposit is PURE INCOME.
      // Nobody was ever paid a deposit for those crates, so the business really
      // is ₦10,500 better off and the P&L says so. This is the release gate at
      // its sharpest — the slice that makes forfeits net must leave a swap-only
      // brand's forfeit exactly where #176 put it.
      expect(d.forfeitIncomeKobo, forfeitKobo);
      expect(d.crateForfeitNettedKobo, 0);
      expect(d.netProfitKobo, forfeitKobo);

      // #215 — and the two figures this slice added read zero at `none` even
      // though the fixture feeds it a ₦180,000 placement row. The seam
      // short-circuits before it looks at a movement, so the owner's stated
      // arrangement beats the residue.
      expect(d.placedCrateDepositsKobo, 0);
      expect(d.cashCrateDepositsPlacedKobo, 0);
      // #216 — and the accepted-loss figure reads zero at `none` too, even
      // though the fixture feeds it a 4-crate write-off row. Profit is not
      // reduced: a swap-only brand has no shortfall to accept.
      expect(d.crateShortfallWrittenOffKobo, 0);
      expect(d.crateDeposits.bySupplier, isEmpty);
      expect(d.crateDeposits.hasMoney, isFalse);
    });

    test('the setting is inert at `none`: a switched-on brand moves ONLY the '
        'figures #215, #216 and #217 own, and `none` still reads exactly as '
        'before',
        () {
      // NARROWED BY #215, NOT DELETED — this test used to assert that no
      // ReconData figure depended on the arrangement at all, and left the next
      // slice this instruction:
      //
      //   "when you make an arrangement actually move money, this test is
      //    SUPPOSED to fail for the money-moving values. That failure is your
      //    prompt to narrow it to `none` rather than delete it — the `none` row
      //    must keep matching the pre-slice figures forever, which is the
      //    promise the whole PRD ships on."
      //
      // #215 is that slice: a Placed Deposit is now an asset in business worth
      // and a cash line of its own. So the claim is narrowed in the two ways
      // the instruction asks for, and both halves are release gates:
      //
      //   1. `none` is still inert — it is the row the whole PRD ships on, and
      //      the test above pins its figures to hand-computed pre-slice values.
      //   2. a money-moving arrangement may move ONLY `movedByThisSlice`.
      //      Everything else — profit, sales, expenses, refunds, cash in, cash
      //      out, net cash movement — must be byte-identical to `none`. That is
      //      what "an asset, never an expense; it must never reduce profit"
      //      means as an assertion rather than as a promise.
      //
      // #216 was that next slice, and #217 is the last. #217 adds ONE key
      // (`crateForfeitNettedKobo`) and re-pins the three magnitudes below,
      // because a forfeit nets by raising a Shortfall and so lands on the lines
      // #216 already opened. What it must NOT move is `forfeitIncomeKobo`,
      // which is now in `figures` above precisely so that claim is checked
      // rather than assumed: the income is identical at `none` and at
      // `per_delivery`, and it is the LOSS beside it that differs.
      final atNone = figures(reconDataFrom(inputsWith(
        kCrateMoneyArrangementNone,
      )));

      for (final other in [
        kCrateMoneyArrangementPerDelivery,
        kCrateMoneyArrangementStandingFloat,
      ]) {
        final moved = figures(reconDataFrom(inputsWith(other)));

        // Every figure OUTSIDE this slice's remit is untouched.
        expect(
          Map.of(moved)..removeWhere((k, _) => movedByThisSlice.contains(k)),
          equals(Map.of(atNone)..removeWhere(
            (k, _) => movedByThisSlice.contains(k),
          )),
          reason:
              'switching a brand to $other may move business worth and the '
              'crate-money cash line, and NOTHING else. A figure that moved '
              'here is crate money leaking into a total it must never reach — '
              'above all profit, which a refundable deposit can never reduce.',
        );

        // …and the three it IS allowed to move, moved exactly as ADR 0023
        // rule 1 says: the asset is the money placed, the cash line carries the
        // same amount OUTSIDE the net, and worth rises by the asset.
        expect(moved['placedCrateDepositsKobo'], placedWithDepot);
        expect(moved['cashCrateDepositsPlacedKobo'], placedWithDepot);
        expect(
          moved['businessNetPositionKobo'],
          atNone['businessNetPositionKobo']! + placedWithDepot,
        );

        // …and the lines #216 and #217 own moved by EXACTLY the losses booked —
        // not merely "differently". A permitted key that drifted by some other
        // amount would pass the removeWhere comparison above and be wrong, so
        // every magnitude is pinned here.
        //
        // The total is the owner's 4-crate write-off PLUS the 3 crates a
        // customer kept: two origins, one line, because a crate that is not
        // coming back costs the same however it left.
        expect(
          moved['crateShortfallWrittenOffKobo'],
          writtenOffKobo + forfeitKobo,
        );
        expect(
          moved['crateForfeitNettedKobo'],
          forfeitKobo,
          reason: '#217 — the split of the line above that a forfeit raised',
        );
        // THE SLICE, as one assertion: the kept deposit is income on BOTH
        // arrangements, and on the switched-on one the crate it paid for costs
        // exactly the same — so the pair contributes zero and the only thing
        // left cutting profit is the write-off the owner actually decided.
        expect(moved['forfeitIncomeKobo'], atNone['forfeitIncomeKobo']);
        expect(
          moved['netProfitKobo']! + forfeitKobo,
          atNone['netProfitKobo']! - writtenOffKobo,
          reason:
              'add the netting back and the two arrangements differ only by '
              'the loss the owner accepted — which is what "a forfeit nets to '
              'zero" means as arithmetic',
        );
        expect(
          moved['netProfitKobo'],
          atNone['netProfitKobo']! - writtenOffKobo - forfeitKobo,
          reason:
              'an accepted crate loss is the ONE thing in PRD #203 that cuts '
              'profit, and it cuts it by the crates × the rate snapshotted on '
              'the day it was accepted',
        );
        expect(
          moved['periodNetResultKobo'],
          atNone['periodNetResultKobo']! - writtenOffKobo - forfeitKobo,
        );
        // Worth is NOT moved by the write-off — only by #215's asset. The
        // crate left the yard when it went missing and worth fell then.
        expect(
          moved['businessNetPositionKobo'],
          atNone['businessNetPositionKobo']! + placedWithDepot,
        );
      }
    });

    test('a non-crate business carries no crate figures at all, arrangement or '
        'not', () {
      // The setting is hidden for a non-crate business; the figures were
      // already zero there and must stay zero.
      final d = reconDataFrom(
        ReconInputs(
          manufacturers: [
            mfr(star, 'Star Lager', starDeposit,
                arrangement: kCrateMoneyArrangementPerDelivery),
          ],
          emptyCrateCounts: const {star: starEmpties},
          showCrates: false,
          heldCrateDepositsKobo: heldForCustomers,
          supplierCrateDebtKobo: owedToSuppliers,
        ),
      );
      expect(d.crateUnits, 0);
      expect(d.crateDepositKobo, 0);
      expect(d.heldCrateDepositsKobo, 0);
      expect(d.supplierCrateDebtKobo, 0);
      expect(d.businessNetPositionKobo, 0);
    });
  });

  group('the setting has nowhere to leak from', () {
    test('nothing in lib/ reads the arrangement except its own module, the '
        'schema, the sync registry, the write method and the picker', () {
      // The structural half of the release gate. A figure can only move if
      // something READS the column; today nothing that computes a figure does.
      // If a later slice adds a reader it lands here first, which is the
      // moment to re-check the `none` path above.
      const allowed = {
        // The domain module — the ONLY interpretation of the strings.
        'lib/core/crates/crate_money_arrangement.dart',
        // The column itself + its upgrade step.
        'lib/core/database/app_database.dart',
        'lib/core/database/app_database.g.dart',
        // Push whitelist + pull default.
        'lib/core/database/sync_registry.dart',
        // The typed import for the write boundary, and the write boundary.
        'lib/core/database/daos.dart',
        'lib/core/database/daos_catalog.dart',
        // The named gate that guards editing it.
        'lib/core/permissions/gate_registry.dart',
        // The one surface that shows and sets it.
        'lib/features/inventory/widgets/crate_money_arrangement_section.dart',
        'lib/features/inventory/screens/inventory_screen.dart',
        // #212 — THE FIRST READERS THAT ACT ON THE VALUE. Everything above this
        // line stores, syncs, guards or displays the setting; these two decide
        // money from it, so the `none` release gate below is what keeps them
        // honest:
        //   * the pure seam — a `none` arrangement short-circuits to the
        //     all-zero position before it looks at a single ledger row, so no
        //     figure it can produce depends on anything but the arrangement
        //     itself when the answer is "no money moves";
        //   * the write boundary (CratePoolDao) — `raiseCrateDepositRequest`
        //     returns null unless the arrangement admits the leg's KIND
        //     (`crateDepositKindAllowedFor`, widened by #214): a `none` brand
        //     admits nothing at all, and a `standing_float` brand admits only a
        //     top-up or a payout, so neither raises a pending deposit, writes a
        //     ledger row or moves cash on an ordinary delivery.
        // The vocabulary module names the arrangement in prose only.
        'lib/core/crates/crate_deposit_position.dart',
        'lib/core/crates/crate_deposit_ledger_types.dart',
        'lib/core/database/daos_crates.dart',
        // #213 — the settlement sheet. It reads the arrangement to decide the
        // SHAPE OF A FORM, never a figure: on a `per_delivery` brand the refund
        // is real money that waits for a manager, so the sheet asks which store
        // the trip belongs to and stops offering the legacy hand-typed deposit
        // box. A `none` brand takes the untouched pre-#203 branch, which is why
        // this reader cannot move a figure on a business that never switched a
        // brand on.
        'lib/features/inventory/screens/supplier_detail_screen.dart',
        // #216 — the Crate Shortfall. The module reads the arrangement to
        // decide whether a brand HAS a shortfall at all (a swap-only brand has
        // no money at risk, so the warning and the write-off are both
        // suppressed), and the reconciliation screen reads it only through the
        // already-computed rollup. Both are release-gated by the `none` row
        // below: every figure they can produce is 0 for a brand nobody switched
        // on, INCLUDING the one figure in this PRD that reaches profit.
        'lib/core/crates/crate_shortfall.dart',
        'lib/features/dashboard/reconciliation/recon_data.dart',
      };

      final found = <String>{};
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final text = entity.readAsStringSync();
        if (text.contains('crateMoneyArrangement') ||
            text.contains('crate_money_arrangement') ||
            text.contains('CrateMoneyArrangement')) {
          found.add(entity.path.replaceAll(r'\', '/'));
        }
      }

      expect(
        found.difference(allowed),
        isEmpty,
        reason:
            'a new file mentions the Crate Money Arrangement. If it READS the '
            'value to compute a figure, PRD #203\'s release gate needs '
            're-checking: a business with every brand at `none` must still '
            'produce the figures it produced before slice #211.',
      );
    });
  });

  group('the write boundary', () {
    late AppDatabase db;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      db.businessIdResolver = () => businessId;
      await db
          .into(db.businesses)
          .insert(
            BusinessesCompanion.insert(
              id: const Value(businessId),
              name: 'Biz',
              type: const Value('Bar'),
            ),
          );
      await db
          .into(db.manufacturers)
          .insert(
            ManufacturersCompanion.insert(
              id: const Value(star),
              businessId: businessId,
              name: 'Star Lager',
              depositAmountKobo: const Value(350000),
            ),
          );
    });

    tearDown(() => db.close());

    Future<ManufacturerData> reread() => (db.select(
      db.manufacturers,
    )..where((t) => t.id.equals(star))).getSingle();

    test('setting an arrangement persists it, bumps last_updated_at, and '
        'changes nothing else about the brand', () async {
      final before = await reread();

      await db.catalogDao.updateManufacturerCrateMoneyArrangement(
        star,
        CrateMoneyArrangement.perDelivery,
      );

      final after = await reread();
      expect(after.crateMoneyArrangement, kCrateMoneyArrangementPerDelivery);
      // The rate is untouched — the arrangement says WHETHER money moves, the
      // rate says how much (ADR 0023 rule 2). One never rewrites the other.
      expect(after.depositAmountKobo, before.depositAmountKobo);
      expect(after.name, before.name);
      expect(after.emptyCrateStock, before.emptyCrateStock);
      expect(
        after.lastUpdatedAt.isAfter(before.lastUpdatedAt) ||
            after.lastUpdatedAt.isAtSameMomentAs(before.lastUpdatedAt),
        isTrue,
      );
    });

    test('switching back to `none` is a normal edit, not a special case',
        () async {
      await db.catalogDao.updateManufacturerCrateMoneyArrangement(
        star,
        CrateMoneyArrangement.standingFloat,
      );
      expect(
        (await reread()).crateMoneyArrangement,
        kCrateMoneyArrangementStandingFloat,
      );

      await db.catalogDao.updateManufacturerCrateMoneyArrangement(
        star,
        CrateMoneyArrangement.none,
      );
      expect(
        (await reread()).crateMoneyArrangement,
        kCrateMoneyArrangementNone,
      );
    });

    test('the edit enqueues the FULL row for sync, carrying the arrangement',
        () async {
      await db.catalogDao.updateManufacturerCrateMoneyArrangement(
        star,
        CrateMoneyArrangement.perDelivery,
      );

      final queued = await db
          .customSelect(
            "SELECT action_type, payload FROM sync_queue "
            "WHERE action_type LIKE 'manufacturers:%'",
          )
          .get();
      expect(queued, isNotEmpty);
      final payload = queued.last.read<String>('payload');
      expect(payload, contains('crate_money_arrangement'));
      expect(payload, contains('per_delivery'));
      // A partial upsert would omit the NOT NULL name and the cloud would
      // reject it (23502) — the full-row enqueue is what prevents that.
      expect(payload, contains('Star Lager'));
    });

    test('the arrangement is on the manufacturers push whitelist', () {
      expect(
        kSyncPushColumns['manufacturers'],
        contains('crate_money_arrangement'),
      );
    });
  });
}
