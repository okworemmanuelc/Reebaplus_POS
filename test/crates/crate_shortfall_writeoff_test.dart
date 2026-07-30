// crate_shortfall_writeoff_test.dart
//
// #216 / PRD #203, ADR 0023 rules 4 and 5 — the Crate Shortfall, and the
// deliberate act of accepting the loss.
//
// The whole slice turns on ONE distinction, and every group below is a way of
// pinning it:
//
//   A SHORTFALL IS A WARNING. Crates owed minus empties on hand, valued at the
//   brand rate. It is derived on every read, so it SHRINKS BY ITSELF when
//   crates turn up behind the store — nobody has to remember to clear it. It
//   touches no total: not profit, not worth, not cash.
//
//   A WRITE-OFF IS THE LOSS. The deliberate, dated decision that the crates are
//   not coming back. THAT is what reaches profit, on the day it was taken, at
//   the rate snapshotted then — and nothing anywhere takes it automatically.
//
// And one thing about scope that #212 designed the seam to make unrepresentable:
// a shortfall is BRAND-level. Two suppliers of one brand contribute to one
// shortfall and neither is named in it, because crates are fungible and
// guessing whose went missing invents a fact the supplier will dispute.

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/crates/crate_deposit_position.dart';
import 'package:reebaplus_pos/core/crates/crate_money_arrangement.dart';
import 'package:reebaplus_pos/core/crates/crate_shortfall.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';
import 'package:reebaplus_pos/shared/services/supplier_crate_service.dart';

void main() {
  const businessId = 'biz-1';
  const managerId = 'user-manager';
  const storeId = 'store-1';
  const supplierA = 'sup-a';
  const supplierB = 'sup-b';
  // ₦3,500 a crate.
  const rate = 350000;
  const moneyBrand = 'mfr-money';
  const floatBrand = 'mfr-float';
  const swapBrand = 'mfr-swap';

  // ══════════════════════════════════════════════════════════════════════════
  // 1. THE ARITHMETIC — pure, no database.
  // ══════════════════════════════════════════════════════════════════════════

  group('shortfall arithmetic', () {
    CrateShortfall shortfall({
      required int owed,
      required int onHand,
      int writtenOff = 0,
      CrateMoneyArrangement arrangement = CrateMoneyArrangement.perDelivery,
      int ratePerCrateKobo = rate,
    }) => computeCrateShortfall(
      manufacturerId: moneyBrand,
      manufacturerName: 'Star Lager',
      arrangement: arrangement,
      ratePerCrateKobo: ratePerCrateKobo,
      cratesOwed: owed,
      emptiesOnHand: onHand,
      writtenOffCrates: writtenOff,
    );

    test('is crates owed minus empties on hand, valued at the brand rate', () {
      final s = shortfall(owed: 100, onHand: 90);
      expect(s.rawShortfallCrates, 10);
      expect(s.openShortfallCrates, 10);
      expect(s.openShortfallValueKobo, 10 * rate); // ₦35,000
      expect(s.isOpen, isTrue);
    });

    test('is zero when the yard covers the debt, and never negative', () {
      // More empties than we owe is not a shortfall of −20; it is no shortfall.
      // A negative would flow into the money figure and read as a gain.
      final s = shortfall(owed: 80, onHand: 100);
      expect(s.rawShortfallCrates, 0);
      expect(s.openShortfallCrates, 0);
      expect(s.openShortfallValueKobo, 0);
      expect(s.isOpen, isFalse);
    });

    test('reads through computeCrateDepositPosition — the ONE seam', () {
      // The gap is not subtracted in the shortfall module; it is asked of the
      // function every other crate-money figure is asked of. If a later slice
      // forks a second derivation, this equality is what breaks.
      const owed = 100;
      const onHand = 73;
      final viaSeam = computeCrateDepositPosition(
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        cratesOwed: owed,
        emptiesOnHand: onHand,
      );
      final s = shortfall(owed: owed, onHand: onHand);
      expect(s.rawShortfallCrates, viaSeam.shortfallCrates);
      expect(s.openShortfallValueKobo, viaSeam.shortfallValueKobo);
    });

    test('a `none` brand has no shortfall at all, whatever its counts say', () {
      // The release gate. A swap-only brand moves no money, so it has no money
      // at risk — and the physical counts it does carry are read from the crate
      // screens, not from here.
      final s = shortfall(
        owed: 100,
        onHand: 10,
        writtenOff: 50,
        arrangement: CrateMoneyArrangement.none,
      );
      expect(s.rawShortfallCrates, 0);
      expect(s.openShortfallCrates, 0);
      expect(s.openShortfallValueKobo, 0);
      expect(s.cratesOwed, 0);
      expect(s.writtenOffCrates, 0);
      expect(s.isOpen, isFalse);
    });

    test('a rate of zero gives a crate count with no money behind it', () {
      final s = shortfall(owed: 100, onHand: 90, ratePerCrateKobo: 0);
      expect(s.openShortfallCrates, 10);
      expect(s.openShortfallValueKobo, 0);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // 2. IT SHRINKS BY ITSELF — the reason it is derived and not stored.
  // ══════════════════════════════════════════════════════════════════════════

  group('shrinkage on reappearance, with NO write-off', () {
    test('crates turning up close the shortfall with nobody deciding anything',
        () {
      // Ten crates missing on Monday.
      final monday = computeCrateShortfall(
        manufacturerId: moneyBrand,
        manufacturerName: 'Star Lager',
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        cratesOwed: 100,
        emptiesOnHand: 90,
      );
      expect(monday.openShortfallCrates, 10);
      expect(monday.openShortfallValueKobo, 10 * rate);

      // Six turn up behind the store on Tuesday. Nothing was written off, no
      // correcting row was posted, nobody pressed anything — the yard count
      // simply rose and the SAME derivation now answers differently.
      final tuesday = computeCrateShortfall(
        manufacturerId: moneyBrand,
        manufacturerName: 'Star Lager',
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        cratesOwed: 100,
        emptiesOnHand: 96,
      );
      expect(tuesday.openShortfallCrates, 4);
      expect(tuesday.openShortfallValueKobo, 4 * rate);
      expect(tuesday.hasWriteOff, isFalse);

      // The last four turn up on Wednesday.
      final wednesday = computeCrateShortfall(
        manufacturerId: moneyBrand,
        manufacturerName: 'Star Lager',
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        cratesOwed: 100,
        emptiesOnHand: 100,
      );
      expect(wednesday.isOpen, isFalse);
      expect(wednesday.openShortfallValueKobo, 0);
    });

    test('handing empties back closes it from the other side too', () {
      // Owing less is as good as holding more: 40 empties handed to the depot
      // drops the debt AND the yard by 40, so a square brand stays square.
      final before = computeCrateShortfall(
        manufacturerId: moneyBrand,
        manufacturerName: 'Star Lager',
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        cratesOwed: 100,
        emptiesOnHand: 100,
      );
      final after = computeCrateShortfall(
        manufacturerId: moneyBrand,
        manufacturerName: 'Star Lager',
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        cratesOwed: 60,
        emptiesOnHand: 60,
      );
      expect(before.isOpen, isFalse);
      expect(after.isOpen, isFalse);
    });

    test('a write-off never reopens: crates found afterwards floor it at zero',
        () {
      // 10 missing, all 10 accepted as lost. Then all 10 turn up.
      // The raw gap is 0 and 10 are written off, so the open figure would be
      // −10 unfloored. It is 0. The loss already hit profit on ITS day and
      // stays there — ADR 0021 forbids restating a closed day, so a late
      // discovery does not un-book it.
      final s = computeCrateShortfall(
        manufacturerId: moneyBrand,
        manufacturerName: 'Star Lager',
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        cratesOwed: 100,
        emptiesOnHand: 100,
        writtenOffCrates: 10,
      );
      expect(s.rawShortfallCrates, 0);
      expect(s.writtenOffCrates, 10);
      expect(s.openShortfallCrates, 0);
      expect(s.isOpen, isFalse);
    });

    test('a partial write-off leaves the rest open and visible', () {
      final s = computeCrateShortfall(
        manufacturerId: moneyBrand,
        manufacturerName: 'Star Lager',
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        cratesOwed: 100,
        emptiesOnHand: 85,
        writtenOffCrates: 6,
      );
      expect(s.rawShortfallCrates, 15);
      expect(s.openShortfallCrates, 9);
      expect(s.openShortfallValueKobo, 9 * rate);
      expect(s.isOpen, isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // 3. THE LOSS — typed so it hits profit, on the day it was taken.
  // ══════════════════════════════════════════════════════════════════════════

  group('the write-off books the loss on the day it was taken', () {
    final july = DateTime.utc(2026, 7, 15);
    final august = DateTime.utc(2026, 8, 3);
    const arrangements = {moneyBrand: CrateMoneyArrangement.perDelivery};

    test('it lands in the period the DECISION was taken, not the discovery',
        () {
      // A shortfall that opened in March and was accepted in July reduces
      // JULY's profit. That is the whole reason the decision is persisted.
      final writeOffs = [
        CrateShortfallWriteOff(
          manufacturerId: moneyBrand,
          crateCount: 10,
          ratePerCrateKobo: rate,
          writtenOffAt: july,
        ),
      ];

      // July's report sees it.
      expect(
        crateShortfallWriteOffKobo(
          writeOffs: writeOffs,
          arrangementByManufacturerId: arrangements,
          start: DateTime.utc(2026, 7, 1),
          endExclusive: DateTime.utc(2026, 8, 1),
        ),
        10 * rate,
      );
      // June's does not.
      expect(
        crateShortfallWriteOffKobo(
          writeOffs: writeOffs,
          arrangementByManufacturerId: arrangements,
          start: DateTime.utc(2026, 6, 1),
          endExclusive: DateTime.utc(2026, 7, 1),
        ),
        0,
      );
      // And neither does August's — the loss does not follow the shortfall
      // forward into every later period.
      expect(
        crateShortfallWriteOffKobo(
          writeOffs: writeOffs,
          arrangementByManufacturerId: arrangements,
          start: DateTime.utc(2026, 8, 1),
          endExclusive: DateTime.utc(2026, 9, 1),
        ),
        0,
      );
    });

    test('the window is half-open: the end instant belongs to the next period',
        () {
      final boundary = DateTime.utc(2026, 8, 1);
      final w = [
        CrateShortfallWriteOff(
          manufacturerId: moneyBrand,
          crateCount: 1,
          ratePerCrateKobo: rate,
          writtenOffAt: boundary,
        ),
      ];
      expect(
        crateShortfallWriteOffKobo(
          writeOffs: w,
          arrangementByManufacturerId: arrangements,
          start: DateTime.utc(2026, 7, 1),
          endExclusive: boundary,
        ),
        0,
      );
      expect(
        crateShortfallWriteOffKobo(
          writeOffs: w,
          arrangementByManufacturerId: arrangements,
          start: boundary,
          endExclusive: DateTime.utc(2026, 9, 1),
        ),
        rate,
      );
    });

    test('each decision keeps ITS OWN snapshotted rate — no restatement', () {
      // July's loss was 10 crates at ₦3,500. August's rate is ₦5,000. July's
      // figure must not move: a rate edited later cannot rewrite a closed day.
      const augustRate = 500000;
      final writeOffs = [
        CrateShortfallWriteOff(
          manufacturerId: moneyBrand,
          crateCount: 10,
          ratePerCrateKobo: rate,
          writtenOffAt: july,
        ),
        CrateShortfallWriteOff(
          manufacturerId: moneyBrand,
          crateCount: 4,
          ratePerCrateKobo: augustRate,
          writtenOffAt: august,
        ),
      ];
      expect(
        crateShortfallWriteOffKobo(
          writeOffs: writeOffs,
          arrangementByManufacturerId: arrangements,
          start: DateTime.utc(2026, 7, 1),
          endExclusive: DateTime.utc(2026, 8, 1),
        ),
        10 * rate,
      );
      expect(
        crateShortfallWriteOffKobo(
          writeOffs: writeOffs,
          arrangementByManufacturerId: arrangements,
          start: DateTime.utc(2026, 8, 1),
          endExclusive: DateTime.utc(2026, 9, 1),
        ),
        4 * augustRate,
      );
    });

    test('a compensating NEGATIVE row books a gain on ITS day, not a rewrite',
        () {
      // Crates written off in July turn up in August. The ledger is
      // append-only, so July stays as it was and August carries the reversal.
      final writeOffs = [
        CrateShortfallWriteOff(
          manufacturerId: moneyBrand,
          crateCount: 10,
          ratePerCrateKobo: rate,
          writtenOffAt: july,
        ),
        CrateShortfallWriteOff(
          manufacturerId: moneyBrand,
          crateCount: -10,
          ratePerCrateKobo: rate,
          writtenOffAt: august,
        ),
      ];
      expect(
        crateShortfallWriteOffKobo(
          writeOffs: writeOffs,
          arrangementByManufacturerId: arrangements,
          start: DateTime.utc(2026, 7, 1),
          endExclusive: DateTime.utc(2026, 8, 1),
        ),
        10 * rate,
        reason: 'July is a closed day and must read exactly as it did',
      );
      expect(
        crateShortfallWriteOffKobo(
          writeOffs: writeOffs,
          arrangementByManufacturerId: arrangements,
          start: DateTime.utc(2026, 8, 1),
          endExclusive: DateTime.utc(2026, 9, 1),
        ),
        -10 * rate,
        reason: 'the reversal is a gain in the month it was decided',
      );
    });

    test('a `none` brand books nothing, and an unknown brand fails closed', () {
      final writeOffs = [
        CrateShortfallWriteOff(
          manufacturerId: swapBrand,
          crateCount: 10,
          ratePerCrateKobo: rate,
          writtenOffAt: july,
        ),
        CrateShortfallWriteOff(
          manufacturerId: 'mfr-vanished',
          crateCount: 10,
          ratePerCrateKobo: rate,
          writtenOffAt: july,
        ),
      ];
      expect(
        crateShortfallWriteOffKobo(
          writeOffs: writeOffs,
          arrangementByManufacturerId: const {
            swapBrand: CrateMoneyArrangement.none,
          },
        ),
        0,
        reason:
            'a swap-only brand has no shortfall to accept, and a brand missing '
            'from the map reads `none` rather than booking a loss',
      );
    });

    test('it reaches netProfit and periodNetResult, and NOTHING else', () {
      // The typing question, asserted rather than promised. A Placed Deposit is
      // an asset and can never cut profit; this is the one thing in PRD #203
      // that can, so it must land in exactly those two lines and no other.
      ReconData dataWith(int writtenOffKobo) => reconDataFrom(
        ReconInputs(
          showCrates: true,
          manufacturers: [
            ManufacturerData(
              id: moneyBrand,
              businessId: businessId,
              name: 'Star Lager',
              emptyCrateStock: 0,
              depositAmountKobo: rate,
              crateMoneyArrangement: kCrateMoneyArrangementPerDelivery,
              isDeleted: false,
              createdAt: july,
              lastUpdatedAt: july,
            ),
          ],
          crateShortfallWriteOffs: writtenOffKobo == 0
              ? const []
              : [
                  CrateShortfallWriteoffData(
                    id: 'wo-1',
                    businessId: businessId,
                    manufacturerId: moneyBrand,
                    storeId: storeId,
                    crateCount: writtenOffKobo ~/ rate,
                    source: kCrateWriteOffSourceManual,
                    ratePerCrateKobo: rate,
                    note: null,
                    performedBy: managerId,
                    createdAt: july,
                    lastUpdatedAt: july,
                  ),
                ],
          start: DateTime.utc(2026, 7, 1),
          endExclusive: DateTime.utc(2026, 8, 1),
        ),
      );

      final none = dataWith(0);
      final booked = dataWith(10 * rate);

      expect(booked.crateShortfallWrittenOffKobo, 10 * rate);
      expect(
        booked.netProfitKobo,
        none.netProfitKobo - 10 * rate,
        reason: 'an accepted crate loss is a realized loss',
      );
      expect(
        booked.periodNetResultKobo,
        none.periodNetResultKobo - 10 * rate,
      );

      // It is NOT cash: nobody handed anything over when the owner accepted the
      // loss, so no cash line may move.
      expect(booked.cashInKobo, none.cashInKobo);
      expect(booked.cashOutKobo, none.cashOutKobo);
      expect(booked.netCashMovementKobo, none.netCashMovementKobo);
      expect(
        booked.cashCrateDepositsPlacedKobo,
        none.cashCrateDepositsPlacedKobo,
      );
      // It is NOT an expense and NOT a refund — the #190/#201 family defect.
      expect(booked.expensesKobo, none.expensesKobo);
      expect(booked.refundsKobo, none.refundsKobo);
      // And it does not touch point-in-time worth: the crate left the yard when
      // it went missing, and worth already fell then. This books the P&L half.
      expect(
        booked.businessNetPositionKobo,
        none.businessNetPositionKobo,
      );
    });

    test('a non-crate business books nothing even with rows present', () {
      final d = reconDataFrom(
        ReconInputs(
          showCrates: false,
          manufacturers: [
            ManufacturerData(
              id: moneyBrand,
              businessId: businessId,
              name: 'Star Lager',
              emptyCrateStock: 0,
              depositAmountKobo: rate,
              crateMoneyArrangement: kCrateMoneyArrangementPerDelivery,
              isDeleted: false,
              createdAt: july,
              lastUpdatedAt: july,
            ),
          ],
          crateShortfallWriteOffs: [
            CrateShortfallWriteoffData(
              id: 'wo-1',
              businessId: businessId,
              manufacturerId: moneyBrand,
              storeId: storeId,
              crateCount: 10,
              source: kCrateWriteOffSourceManual,
              ratePerCrateKobo: rate,
              note: null,
              performedBy: managerId,
              createdAt: july,
              lastUpdatedAt: july,
            ),
          ],
        ),
      );
      expect(d.crateShortfallWrittenOffKobo, 0);
      expect(d.netProfitKobo, 0);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // 4. UNATTRIBUTED — two suppliers of one brand.
  // ══════════════════════════════════════════════════════════════════════════

  group('two suppliers of one brand stay unattributed', () {
    test('the type has no supplier axis for an attribution to be written into',
        () {
      // The structural half. `CrateShortfall` names a manufacturer and nothing
      // else; there is no `supplierId` field to guess into.
      final s = computeCrateShortfall(
        manufacturerId: moneyBrand,
        manufacturerName: 'Star Lager',
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        cratesOwed: 200,
        emptiesOnHand: 190,
      );
      expect(s.manufacturerId, moneyBrand);
      expect(
        s.toString().toLowerCase().contains('supplier'),
        isFalse,
        reason: 'nothing about a shortfall names a supplier',
      );
    });

    test('one brand from two depots gives ONE shortfall, not a split', () {
      // 100 crates from Depot A and 100 from Depot B; ten go missing. Nothing
      // says whose they were. The brand is short ten — full stop. A pro-rata
      // split would put five on each and then move Depot A's balance whenever
      // Depot B took a delivery.
      final s = computeCrateShortfall(
        manufacturerId: moneyBrand,
        manufacturerName: 'Star Lager',
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        cratesOwed: 200, // 100 + 100, summed across BOTH depots
        emptiesOnHand: 190,
      );
      expect(s.cratesOwed, 200);
      expect(s.openShortfallCrates, 10);
      expect(s.openShortfallValueKobo, 10 * rate);

      final rollup = rollUpCrateShortfalls([s]);
      expect(rollup.brands, hasLength(1));
      expect(rollup.openCrates, 10);
    });

    test('an unrelated depot delivering does not move the other depot', () {
      // The pro-rata failure mode, pinned. Depot B receives 50 more crates.
      // Under any attribution scheme Depot A's share of the loss would change.
      // Here the BRAND's numbers move and no supplier's do, because no
      // supplier has a share.
      final before = computeCrateShortfall(
        manufacturerId: moneyBrand,
        manufacturerName: 'Star Lager',
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        cratesOwed: 200,
        emptiesOnHand: 190,
      );
      final after = computeCrateShortfall(
        manufacturerId: moneyBrand,
        manufacturerName: 'Star Lager',
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        // Depot B's 50 full crates arrive; the empties for them are not back
        // yet, so both the debt and the gap rise by 50 at BRAND level.
        cratesOwed: 250,
        emptiesOnHand: 190,
      );
      expect(before.openShortfallCrates, 10);
      expect(after.openShortfallCrates, 60);
      // Neither figure was ever apportioned, so there is nothing to have
      // silently re-apportioned.
      expect(before.manufacturerId, after.manufacturerId);
    });

    test('the pair-level seam still refuses to answer the question', () {
      // #212's guarantee, re-pinned here because #216 is the slice that could
      // have been tempted to pass a business-wide yard to a pair-scoped read.
      final pair = computeCrateDepositPosition(
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        cratesOwed: 100, // ONE supplier's slice
        // emptiesOnHand deliberately omitted — the caller is not asking a
        // shortfall question at this scope.
      );
      expect(pair.shortfallCrates, 0);
      expect(pair.hasShortfall, isFalse);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // 5. THE ROLL-UP.
  // ══════════════════════════════════════════════════════════════════════════

  group('the business-wide roll-up', () {
    CrateShortfall brand(
      String id,
      String name,
      int owed,
      int onHand, {
      CrateMoneyArrangement arrangement = CrateMoneyArrangement.perDelivery,
      int brandRate = rate,
      int writtenOff = 0,
    }) => computeCrateShortfall(
      manufacturerId: id,
      manufacturerName: name,
      arrangement: arrangement,
      ratePerCrateKobo: brandRate,
      cratesOwed: owed,
      emptiesOnHand: onHand,
      writtenOffCrates: writtenOff,
    );

    test('sums open shortfalls at each brand\'s own rate, biggest first', () {
      final rollup = rollUpCrateShortfalls([
        brand(moneyBrand, 'Star Lager', 100, 96), // 4 × ₦3,500 = ₦14,000
        brand('mfr-gulder', 'Gulder', 50, 40, brandRate: 300000), // 10 × ₦3,000
      ]);
      expect(rollup.openCrates, 14);
      expect(rollup.openValueKobo, 4 * rate + 10 * 300000);
      expect(rollup.brands.first.manufacturerName, 'Gulder'); // ₦30,000 > ₦14,000
      expect(rollup.hasShortfall, isTrue);
    });

    test('square and fully-written-off brands are dropped, not listed at zero',
        () {
      final rollup = rollUpCrateShortfalls([
        brand(moneyBrand, 'Star Lager', 100, 100),
        brand('mfr-gulder', 'Gulder', 50, 40, writtenOff: 10),
      ]);
      expect(rollup.brands, isEmpty);
      expect(rollup.hasShortfall, isFalse);
      expect(rollup.openValueKobo, 0);
    });

    test('an all-`none` business rolls up to empty — the release gate', () {
      final rollup = rollUpCrateShortfalls([
        brand(
          swapBrand,
          'Trophy',
          100,
          10,
          arrangement: CrateMoneyArrangement.none,
        ),
      ]);
      expect(rollup, same(CrateShortfallRollup.empty));
      expect(rollup.hasShortfall, isFalse);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // 6. THE WRITE PATH — through CratePoolDao, against a real database.
  // ══════════════════════════════════════════════════════════════════════════

  group('the write path', () {
    late AppDatabase db;

    Future<void> seed() async {
      db.businessIdResolver = () => businessId;
      await db
          .into(db.businesses)
          .insert(
            BusinessesCompanion.insert(id: const Value(businessId), name: 'Biz'),
          );
      await db
          .into(db.users)
          .insert(
            UsersCompanion.insert(
              id: const Value(managerId),
              businessId: businessId,
              name: 'Manager',
              pin: '1234',
            ),
          );
      await db
          .into(db.stores)
          .insert(
            StoresCompanion.insert(
              id: const Value(storeId),
              businessId: businessId,
              name: 'Main Store',
            ),
          );
      const brands = {
        moneyBrand: ('Star Lager', kCrateMoneyArrangementPerDelivery),
        floatBrand: ('Gulder', kCrateMoneyArrangementStandingFloat),
        swapBrand: ('Trophy', kCrateMoneyArrangementNone),
      };
      for (final e in brands.entries) {
        await db
            .into(db.manufacturers)
            .insert(
              ManufacturersCompanion.insert(
                id: Value(e.key),
                businessId: businessId,
                name: e.value.$1,
                depositAmountKobo: const Value(rate),
                crateMoneyArrangement: Value(e.value.$2),
              ),
            );
      }
      for (final s in [supplierA, supplierB]) {
        await db
            .into(db.suppliers)
            .insert(
              SuppliersCompanion.insert(
                id: Value(s),
                businessId: businessId,
                name: 'Depot $s',
              ),
            );
      }
    }

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      await seed();
    });

    tearDown(() => db.close());

    test('a write-off persists the DECISION with its snapshotted rate, actor '
        'and date — and no cash leg', () async {
      final id = await db.cratePoolDao.writeOffCrateShortfall(
        manufacturerId: moneyBrand,
        crateCount: 7,
        performedBy: managerId,
        storeId: storeId,
        note: 'Never came back off the Ojota run',
      );
      expect(id, isNotNull);

      final rows = await db.select(db.crateShortfallWriteoffs).get();
      expect(rows, hasLength(1));
      expect(rows.single.manufacturerId, moneyBrand);
      expect(rows.single.crateCount, 7);
      expect(rows.single.ratePerCrateKobo, rate);
      expect(rows.single.performedBy, managerId);
      expect(rows.single.note, isNotNull);

      // NO payment row. Nobody handed anything over — the money left (or never
      // arrived) long ago, and a `crate_deposit_out` row here would show cash
      // moving that never moved.
      final payments = await db.select(db.paymentTransactions).get();
      expect(payments, isEmpty);
      // And no Placed Deposit movement either: the deposit is still with the
      // depot, and attributing this loss to one of them is exactly what rule 4
      // forbids.
      final deposits = await db.select(db.supplierCrateDeposits).get();
      expect(deposits, isEmpty);
    });

    test('it enqueues for sync', () async {
      await db.cratePoolDao.writeOffCrateShortfall(
        manufacturerId: moneyBrand,
        crateCount: 3,
        performedBy: managerId,
      );
      final queued = await db
          .customSelect(
            "SELECT payload FROM sync_queue "
            "WHERE action_type LIKE 'crate_shortfall_writeoffs:%'",
          )
          .get();
      expect(queued, isNotEmpty);
      final payload = queued.last.read<String>('payload');
      expect(payload, contains('rate_per_crate_kobo'));
      expect(payload, contains('crate_count'));
    });

    test('a `none` brand cannot be written off at all', () async {
      // The release gate at the write boundary. A swap-only brand has no
      // shortfall, so there is nothing to accept, and a stray call cannot cut
      // its profit.
      final id = await db.cratePoolDao.writeOffCrateShortfall(
        manufacturerId: swapBrand,
        crateCount: 5,
        performedBy: managerId,
      );
      expect(id, isNull);
      expect(await db.select(db.crateShortfallWriteoffs).get(), isEmpty);
    });

    test('a non-positive count and an unknown brand write nothing', () async {
      expect(
        await db.cratePoolDao.writeOffCrateShortfall(
          manufacturerId: moneyBrand,
          crateCount: 0,
          performedBy: managerId,
        ),
        isNull,
      );
      expect(
        await db.cratePoolDao.writeOffCrateShortfall(
          manufacturerId: 'mfr-nope',
          crateCount: 5,
          performedBy: managerId,
        ),
        isNull,
      );
      expect(await db.select(db.crateShortfallWriteoffs).get(), isEmpty);
    });

    test('the ledger is append-only — a booked loss cannot be edited away',
        () async {
      await db.cratePoolDao.writeOffCrateShortfall(
        manufacturerId: moneyBrand,
        crateCount: 7,
        performedBy: managerId,
      );
      final row = (await db.select(db.crateShortfallWriteoffs).get()).single;
      await expectLater(
        (db.update(db.crateShortfallWriteoffs)
              ..where((t) => t.id.equals(row.id)))
            .write(const CrateShortfallWriteoffsCompanion(
              crateCount: Value(1),
            )),
        throwsA(anything),
        reason: 'the immutable trigger freezes every column but last_updated_at',
      );
    });

    test('NOTHING writes off automatically — no timer, no sweep, no backfill',
        () async {
      // The behavioural half of "profit must never be reduced by a decision
      // nobody made". A brand that is short 20 crates, left completely alone.
      await db.cratePoolDao.recordReceiveFromSupplier(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        quantity: 20,
        performedBy: managerId,
        storeId: storeId,
      );
      // Time passes; the app opens, reads, re-reads.
      final first = await db.cratePoolDao.watchCrateShortfallRollup().first;
      final second = await db.cratePoolDao.watchCrateShortfallRollup().first;

      expect(first.openCrates, 20);
      expect(second.openCrates, 20, reason: 'reading it changes nothing');
      // And after all that, not one write-off row exists.
      expect(
        await db.select(db.crateShortfallWriteoffs).get(),
        isEmpty,
        reason:
            'a shortfall of any age is still only a warning until somebody '
            'deliberately accepts it',
      );
    });

    test('the structural half: nothing in lib/ writes off without being asked',
        () {
      // The one write verb is `writeOffCrateShortfall`, and its only callers
      // are the reconciliation card\'s button and tests. If a later slice adds a
      // scheduler, a migration backfill or an "auto-accept after N days" sweep,
      // it lands here first.
      const allowedCallers = {
        'lib/core/database/daos_crates.dart', // the verb itself
        'lib/features/dashboard/screens/daily_reconciliation_detail_screen.dart',
      };
      final found = <String>{};
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.endsWith('.g.dart')) continue;
        if (entity.readAsStringSync().contains('writeOffCrateShortfall')) {
          found.add(entity.path.replaceAll(r'\', '/'));
        }
      }
      expect(
        found.difference(allowedCallers),
        isEmpty,
        reason:
            'a new caller of the write-off verb. If it is a timer, a scheduled '
            'sweep or a migration backfill, it must not exist: ADR 0023 rule 5 '
            'says profit is never reduced by a decision nobody made.',
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // 7. A FLOAT BRAND — the shortfall rises, the money does not move.
  // ══════════════════════════════════════════════════════════════════════════

  group('a float brand\'s losses raise a shortfall but move no money', () {
    late AppDatabase db;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      db.businessIdResolver = () => businessId;
      await db
          .into(db.businesses)
          .insert(
            BusinessesCompanion.insert(id: const Value(businessId), name: 'Biz'),
          );
      await db
          .into(db.users)
          .insert(
            UsersCompanion.insert(
              id: const Value(managerId),
              businessId: businessId,
              name: 'Manager',
              pin: '1234',
            ),
          );
      await db
          .into(db.stores)
          .insert(
            StoresCompanion.insert(
              id: const Value(storeId),
              businessId: businessId,
              name: 'Main Store',
            ),
          );
      await db
          .into(db.manufacturers)
          .insert(
            ManufacturersCompanion.insert(
              id: const Value(floatBrand),
              businessId: businessId,
              name: 'Gulder',
              depositAmountKobo: const Value(rate),
              crateMoneyArrangement: const Value(
                kCrateMoneyArrangementStandingFloat,
              ),
            ),
          );
      await db
          .into(db.suppliers)
          .insert(
            SuppliersCompanion.insert(
              id: const Value(supplierA),
              businessId: businessId,
              name: 'Ade Depot',
            ),
          );
    });

    tearDown(() => db.close());

    test('crates going missing raise the warning and move nothing else',
        () async {
      // 30 full crates arrive on a float brand. #214 pinned that this moves no
      // money: a lump sum placed once does not move because a lorry arrived.
      await db.cratePoolDao.recordReceiveFromSupplier(
        supplierId: supplierA,
        manufacturerId: floatBrand,
        quantity: 30,
        performedBy: managerId,
        storeId: storeId,
      );
      // 25 empties come back to the yard; 5 never do.
      await db.cratePoolDao.addEmptiesToPool(
        floatBrand,
        25,
        storeId: storeId,
      );

      final rollup = await db.cratePoolDao.watchCrateShortfallRollup().first;
      expect(rollup.openCrates, 5);
      expect(rollup.openValueKobo, 5 * rate);
      expect(rollup.brands.single.manufacturerName, 'Gulder');

      // And NOT ONE naira moved. The supplier has deducted nothing — booking a
      // loss now would show money leaving that nobody took. The float is eaten
      // as headroom, and the warning is what says so.
      expect(await db.select(db.supplierCrateDeposits).get(), isEmpty);
      expect(await db.select(db.paymentTransactions).get(), isEmpty);
      expect(
        await db.select(db.supplierCrateDepositRequests).get(),
        isEmpty,
        reason: 'a float brand admits no per-delivery money leg (#214)',
      );
    });

    test('a float brand CAN be written off, and still moves no money',
        () async {
      await db.cratePoolDao.recordReceiveFromSupplier(
        supplierId: supplierA,
        manufacturerId: floatBrand,
        quantity: 30,
        performedBy: managerId,
        storeId: storeId,
      );
      await db.cratePoolDao.addEmptiesToPool(floatBrand, 25, storeId: storeId);

      final id = await db.cratePoolDao.writeOffCrateShortfall(
        manufacturerId: floatBrand,
        crateCount: 5,
        performedBy: managerId,
        storeId: storeId,
      );
      expect(id, isNotNull, reason: 'accepting a loss is not a money movement');

      final after = await db.cratePoolDao.watchCrateShortfallRollup().first;
      expect(after.hasShortfall, isFalse, reason: 'the warning is dealt with');
      // The loss is booked; the float itself is untouched.
      expect(await db.select(db.supplierCrateDeposits).get(), isEmpty);
      expect(await db.select(db.paymentTransactions).get(), isEmpty);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // 8. THE EMPTIES-POOL GAP #213 LEFT — the regression that makes the figure
  //    honest.
  // ══════════════════════════════════════════════════════════════════════════

  group('a standalone settlement moves BOTH legs', () {
    late AppDatabase db;

    Future<void> seed() async {
      db.businessIdResolver = () => businessId;
      await db
          .into(db.businesses)
          .insert(
            BusinessesCompanion.insert(id: const Value(businessId), name: 'Biz'),
          );
      await db
          .into(db.users)
          .insert(
            UsersCompanion.insert(
              id: const Value(managerId),
              businessId: businessId,
              name: 'Manager',
              pin: '1234',
            ),
          );
      await db
          .into(db.stores)
          .insert(
            StoresCompanion.insert(
              id: const Value(storeId),
              businessId: businessId,
              name: 'Main Store',
            ),
          );
      const brands = {
        moneyBrand: ('Star Lager', kCrateMoneyArrangementPerDelivery),
        swapBrand: ('Trophy', kCrateMoneyArrangementNone),
      };
      for (final e in brands.entries) {
        await db
            .into(db.manufacturers)
            .insert(
              ManufacturersCompanion.insert(
                id: Value(e.key),
                businessId: businessId,
                name: e.value.$1,
                depositAmountKobo: const Value(rate),
                crateMoneyArrangement: Value(e.value.$2),
              ),
            );
      }
      await db
          .into(db.suppliers)
          .insert(
            SuppliersCompanion.insert(
              id: const Value(supplierA),
              businessId: businessId,
              name: 'Ade Depot',
            ),
          );
    }

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      await seed();
    });

    tearDown(() => db.close());

    test('it drops the yard as well as the debt, so a real shortfall survives',
        () async {
      // THE BUG #213 FLAGGED AND DID NOT FIX. 100 crates received, 90 empties
      // back in the yard: the brand is genuinely 10 short.
      await db.cratePoolDao.recordReceiveFromSupplier(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        quantity: 100,
        performedBy: managerId,
        storeId: storeId,
      );
      await db.cratePoolDao.addEmptiesToPool(moneyBrand, 90, storeId: storeId);
      expect(
        (await db.cratePoolDao.watchCrateShortfallRollup().first).openCrates,
        10,
      );

      // Now a settlement run carries 40 empties to the depot. Before the fix
      // this dropped `cratesOwed` to 60 while the yard still claimed 90, so the
      // shortfall read max(0, 60 − 90) = 0 — a real loss silently erased and
      // profit overstated by ₦35,000.
      await db.cratePoolDao.recordCrateSettlement(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        storeId: storeId,
        crateCount: 40,
        performedBy: managerId,
      );

      final pool = await db.cratePoolDao
          .watchEmptiesPoolByManufacturer()
          .first;
      expect(pool[moneyBrand], 50, reason: 'the empties left the yard');

      final after = await db.cratePoolDao.watchCrateShortfallRollup().first;
      expect(
        after.openCrates,
        10,
        reason:
            'settling is not finding: handing back 40 of the 90 you hold '
            'leaves you exactly as short as you were',
      );
      expect(after.openValueKobo, 10 * rate);
    });

    test('a settlement with no crates on the truck moves no empties', () async {
      // A pure money settlement — a closing account, a refund owed from a
      // previous trip. There are no crates on it, so the yard must not move.
      await db.cratePoolDao.addEmptiesToPool(moneyBrand, 30, storeId: storeId);
      await db.cratePoolDao.recordCrateSettlement(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        storeId: storeId,
        crateCount: 0,
        performedBy: managerId,
        refundAmountKobo: 500000,
      );
      final pool = await db.cratePoolDao
          .watchEmptiesPoolByManufacturer()
          .first;
      expect(pool[moneyBrand], 30);
    });

    test('a `none` brand is untouched: it never reaches the settlement verb',
        () async {
      // #213 left the gap because it did not want to change what the button
      // does for `none` brands. It does not: the settlement sheet routes to
      // `recordSettlement` only on the `per_delivery` branch, and a swap-only
      // brand takes the untouched pre-#203 `recordReturn` path, which still
      // moves the supplier ledger alone.
      final service = SupplierCrateService(db);
      await db.cratePoolDao.addEmptiesToPool(swapBrand, 30, storeId: storeId);
      await service.recordReturn(
        supplierId: supplierA,
        supplierName: 'Ade Depot',
        manufacturerId: swapBrand,
        manufacturerName: 'Trophy',
        quantity: 10,
        staffId: managerId,
        storeId: storeId,
      );

      final pool = await db.cratePoolDao
          .watchEmptiesPoolByManufacturer()
          .first;
      expect(
        pool[swapBrand],
        30,
        reason:
            'the pre-#203 manual return has never moved the yard, and #216 did '
            'not change that',
      );
      // The supplier debt still fell, exactly as it always did.
      final debt = await db.cratePoolDao.watchSupplierCrateDebt(supplierA).first;
      expect(debt.single.balance, -10);
      // And no money was involved anywhere.
      expect(await db.select(db.supplierCrateDeposits).get(), isEmpty);
      expect(await db.select(db.paymentTransactions).get(), isEmpty);
    });
  });
}
