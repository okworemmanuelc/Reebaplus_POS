// van_trip_position_test.dart
//
// #145 (PRD #139 as amended by #161 / ADR 0019, van-sales spec §5.5, §6, §11) —
// exhaustive fixtures for `computeVanTripPosition`, the pure settlement math.
//
// No database, no widgets, no providers: the function takes plain data by
// design (spec §13 seam 1), because a manager is about to decide on the
// strength of these numbers whether a driver owes ₦192,500 or nothing. Style
// follows `test/dashboard/recon_data_test.dart`.
//
// Two claims are asserted on EVERY constructed case, via `_assertInvariants`:
//
//   · the tie-out `outstanding == −balance`. Two independent computations meet
//     in this function — the append-only ledger's signed sum, and the position
//     derived from lots, sales and returns. If they ever disagree, one of them
//     is wrong (spec §6.1).
//   · the double-count guard `profit == recovered − cogs`. The shortage and
//     damaged units are inside `consumed`, so their cost is ALREADY in COGS;
//     `shortageLossKobo` / `damageLossKobo` are disclosure fields. Any report
//     that subtracts them again is wrong (spec §6.3).

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/van_sales/van_trip_position.dart';

// Kobo. The spec's worked trip is in naira; ×100 throughout.
const _loadPrice = 1150000; // ₦11,500 per crate
const _unitCost = 1000000; // ₦10,000 per crate

const _star = 'prod-star';
const _gulder = 'prod-gulder';

final _mon = DateTime(2026, 7, 20, 8);
final _wed = DateTime(2026, 7, 22, 8);

VanPositionLot _lot({
  required String lotId,
  String productId = _star,
  required int quantity,
  int loadPriceKobo = _loadPrice,
  int unitCostKobo = _unitCost,
  DateTime? dispatchedAt,
}) => VanPositionLot(
  lotId: lotId,
  productId: productId,
  quantity: quantity,
  loadPriceKobo: loadPriceKobo,
  unitCostKobo: unitCostKobo,
  dispatchedAt: dispatchedAt ?? _mon,
);

VanPositionSaleLine _sale({
  String productId = _star,
  required int quantity,
  int? rungValueKobo,
}) => VanPositionSaleLine(
  productId: productId,
  quantity: quantity,
  rungValueKobo: rungValueKobo ?? quantity * _loadPrice,
);

VanPositionReturn _good({
  String productId = _star,
  required int quantity,
  int? creditKobo,
  int? costKobo,
}) => VanPositionReturn(
  productId: productId,
  quantity: quantity,
  condition: kVanReturnConditionGood,
  creditKobo: creditKobo ?? quantity * _loadPrice,
  costKobo: costKobo ?? quantity * _unitCost,
);

VanPositionReturn _damaged({
  String productId = _star,
  required int quantity,
  int? costKobo,
}) => VanPositionReturn(
  productId: productId,
  quantity: quantity,
  condition: kVanReturnConditionDamaged,
  creditKobo: 0,
  costKobo: costKobo ?? quantity * _unitCost,
);

// #207 — the deposit rate is per MANUFACTURER (`Manufacturers`
// `.depositAmountKobo` is canonical; `Products.emptyCrateValueKobo` mirrors it),
// so the shell inputs are keyed by brand, not by product or by lot.
const _starBrand = 'mfr-star';
const _gulderBrand = 'mfr-gulder';
const _starShellRate = 180000; // ₦1,800 deposit per crate
const _gulderShellRate = 250000; // ₦2,500 — a second brand, a different rate

VanPositionShellLine _shells({
  String manufacturerId = _starBrand,
  int out = 0,
  int back = 0,
  int depositRateKobo = _starShellRate,
}) => VanPositionShellLine(
  manufacturerId: manufacturerId,
  shellsOut: out,
  shellsBack: back,
  depositRateKobo: depositRateKobo,
);

VanPositionLedgerEntry _debit(String type, int amountKobo) =>
    VanPositionLedgerEntry(type: type, signedAmountKobo: -amountKobo);

VanPositionLedgerEntry _credit(String type, int amountKobo) =>
    VanPositionLedgerEntry(type: type, signedAmountKobo: amountKobo);

/// The two invariants that hold on every position, asserted everywhere.
void _assertInvariants(VanTripPosition p, {required String label}) {
  expect(
    p.tieOutDeltaKobo,
    0,
    reason:
        '$label: outstanding (${p.outstandingKobo}) must equal −balance '
        '(${-p.balanceKobo}). The derived position and the append-only ledger '
        'are two independent computations of the same money; a gap means one '
        'of them is wrong (spec §6.1).',
  );
  expect(
    p.outstandingKobo,
    p.unremittedCashKobo +
        p.shortageOwedKobo +
        p.damageOwedKobo -
        p.residualCreditKobo,
    reason: '$label: the three-way split must partition the outstanding balance',
  );
  expect(
    p.profitKobo,
    p.recoveredKobo - p.cogsKobo,
    reason:
        '$label: profit is recovered − cogs. The shortage and damage loss '
        'lines are DISCLOSURE — their cost is already inside cogs, so '
        'subtracting them again double-counts (spec §6.3).',
  );
}

void main() {
  group('spec §6.3 — the worked trip, to the kobo', () {
    // Star 60cl. Warehouse batch 200 @ ₦10,000 cost. Mon: load 100 @ ₦11,500
    // with 100 shells. Tue: sell 60. Wed: restock 40, sell 30. Thu: 45 good
    // back (65 shells), 3 damaged, remit ₦900,000, close.
    late VanTripPosition p;

    setUp(() {
      p = computeVanTripPosition(
        lots: [
          _lot(lotId: 'lot-mon', quantity: 100, dispatchedAt: _mon),
          _lot(lotId: 'lot-wed', quantity: 40, dispatchedAt: _wed),
        ],
        sales: [_sale(quantity: 60), _sale(quantity: 30)],
        returns: [_good(quantity: 45), _damaged(quantity: 3)],
        ledger: [
          _debit(kDriverLedgerTypeLoad, 100 * _loadPrice),
          _debit(kDriverLedgerTypeRestock, 40 * _loadPrice),
          _credit(kDriverLedgerTypeReturnGood, 45 * _loadPrice),
          _credit(kDriverLedgerTypePaymentCash, 90000000),
        ],
        shellsOut: 100,
        shellsBack: 65,
      );
    });

    test('the load-price identities (§6.1)', () {
      expect(p.loadedValueKobo, 161000000); // ₦1,610,000
      expect(p.soldValueKobo, 103500000); // ₦1,035,000
      expect(p.goodReturnValueKobo, 51750000); // ₦517,500
      expect(p.remittedKobo, 90000000); // ₦900,000
      expect(p.balanceKobo, -19250000); // the driver owes ₦192,500
    });

    test('the three-way breakdown of what is still owed', () {
      expect(p.shortageUnits, 2); // 140 − 90 − 45 − 3
      expect(p.shortageValueKobo, 2300000); // ₦23,000
      expect(p.damagedUnits, 3);
      expect(p.damageValueKobo, 3450000); // ₦34,500
      expect(p.unremittedCashKobo, 13500000); // ₦135,000
      expect(p.outstandingKobo, 19250000); // ₦192,500 ✓ == −balance
      _assertInvariants(p, label: 'worked trip');
    });

    test('the close artifact (§6.3)', () {
      // consumed = 140 − 45 = 95 units at ₦10,000 cost each
      expect(p.cogsKobo, 95000000); // ₦950,000
      expect(p.recoveredKobo, 141750000); // ₦1,417,500
      expect(p.shortageLossKobo, 2000000); // ₦20,000 — 2 × cost
      expect(p.damageLossKobo, 3000000); // ₦30,000 — 3 × cost
      expect(p.profitKobo, 46750000); // ₦467,500
    });

    test('the shell memo surfaces the 35 crates nobody would have missed', () {
      // The point of §11: without this, the trip reads "settled" having lost
      // ~₦63,000 of deposit-value shells and the data to reconstruct it never
      // existed.
      expect(p.shellsOut, 100);
      expect(p.shellsBack, 65);
      expect(p.shellsDifference, 35);
    });

    test('the per-product shortage line names its lot prices', () {
      expect(p.shortages, hasLength(1));
      final line = p.shortages.single;
      expect(line.productId, _star);
      expect(line.units, 2);
      expect(line.valueKobo, 2300000);
      expect(line.costKobo, 2000000);
      expect(line.loadPricesKobo, [_loadPrice]);
    });
  });

  group('the tie-out holds across the shapes a real trip takes', () {
    test('a perfectly settled trip closes at zero', () {
      final p = computeVanTripPosition(
        lots: [_lot(lotId: 'l1', quantity: 10)],
        sales: [_sale(quantity: 6)],
        returns: [_good(quantity: 4)],
        ledger: [
          _debit(kDriverLedgerTypeLoad, 10 * _loadPrice),
          _credit(kDriverLedgerTypeReturnGood, 4 * _loadPrice),
          _credit(kDriverLedgerTypePaymentCash, 6 * _loadPrice),
        ],
      );

      expect(p.isSettled, isTrue);
      expect(p.balanceKobo, 0);
      expect(p.outstandingKobo, 0);
      expect(p.shortageUnits, 0);
      expect(p.shortages, isEmpty);
      _assertInvariants(p, label: 'settled');
    });

    test('a load with nothing rung and nothing back is all shortage', () {
      final p = computeVanTripPosition(
        lots: [_lot(lotId: 'l1', quantity: 10)],
        sales: const [],
        returns: const [],
        ledger: [_debit(kDriverLedgerTypeLoad, 10 * _loadPrice)],
      );

      expect(p.shortageUnits, 10);
      expect(p.shortageValueKobo, 10 * _loadPrice);
      expect(p.shortageLossKobo, 10 * _unitCost);
      expect(p.unremittedCashKobo, 0);
      expect(p.shortageOwedKobo, 10 * _loadPrice);
      _assertInvariants(p, label: 'all shortage');
    });

    test('unrung sales surface as shortage and keep the driver liable', () {
      // The AC in words: the driver sold 4 crates off-book. Nothing was rung,
      // so the system cannot call it a sale — it calls it a shortage, and the
      // driver stays liable for the full load price.
      final p = computeVanTripPosition(
        lots: [_lot(lotId: 'l1', quantity: 10)],
        sales: [_sale(quantity: 6)],
        returns: const [],
        ledger: [
          _debit(kDriverLedgerTypeLoad, 10 * _loadPrice),
          _credit(kDriverLedgerTypePaymentCash, 6 * _loadPrice),
        ],
      );

      expect(p.soldUnits, 6);
      expect(p.shortageUnits, 4);
      expect(p.unremittedCashKobo, 0, reason: 'the rung sales were remitted');
      expect(p.shortageOwedKobo, 4 * _loadPrice);
      expect(p.outstandingKobo, 4 * _loadPrice);
      _assertInvariants(p, label: 'unrung');
    });

    test('two products each get their own shortage line', () {
      final p = computeVanTripPosition(
        lots: [
          _lot(lotId: 'l1', quantity: 10),
          _lot(lotId: 'l2', productId: _gulder, quantity: 20),
        ],
        sales: [_sale(quantity: 8), _sale(productId: _gulder, quantity: 15)],
        returns: [_good(quantity: 1)],
        ledger: [
          _debit(kDriverLedgerTypeLoad, 30 * _loadPrice),
          _credit(kDriverLedgerTypeReturnGood, 1 * _loadPrice),
        ],
      );

      expect(p.shortageUnits, 6); // 1 Star + 5 Gulder
      expect(p.shortages, hasLength(2));
      // Sorted by value, largest first — the line a manager should look at.
      expect(p.shortages.first.productId, _gulder);
      expect(p.shortages.first.units, 5);
      expect(p.shortages.last.productId, _star);
      expect(p.shortages.last.units, 1);
      _assertInvariants(p, label: 'two products');
    });

    test('a restock at a NEW price values each unit at the lot it left on', () {
      // 10 @ ₦11,500 Monday, then 10 @ ₦12,000 Wednesday. Return 4 (FIFO, so
      // the oldest lot's price), sell 12, and 4 go missing. The missing ones are
      // the NEWEST — the oldest are presumed sold — so they are valued at the
      // restock price.
      const newPrice = 1200000;
      const newCost = 1050000;
      final p = computeVanTripPosition(
        lots: [
          _lot(lotId: 'l1', quantity: 10, dispatchedAt: _mon),
          _lot(
            lotId: 'l2',
            quantity: 10,
            loadPriceKobo: newPrice,
            unitCostKobo: newCost,
            dispatchedAt: _wed,
          ),
        ],
        sales: [_sale(quantity: 12)],
        returns: [_good(quantity: 4)],
        ledger: [
          _debit(kDriverLedgerTypeLoad, 10 * _loadPrice),
          _debit(kDriverLedgerTypeRestock, 10 * newPrice),
          _credit(kDriverLedgerTypeReturnGood, 4 * _loadPrice),
        ],
      );

      expect(p.loadedValueKobo, 10 * _loadPrice + 10 * newPrice);
      // 6 left on lot 1 + 6 from lot 2.
      expect(p.soldValueKobo, 6 * _loadPrice + 6 * newPrice);
      expect(p.shortageUnits, 4);
      expect(p.shortageValueKobo, 4 * newPrice);
      expect(p.shortageLossKobo, 4 * newCost);
      expect(p.shortages.single.loadPricesKobo, [newPrice]);
      _assertInvariants(p, label: 'two-price restock');
    });

    test('a return spanning two lots credits FIFO and still ties out', () {
      const newPrice = 1200000;
      final p = computeVanTripPosition(
        lots: [
          _lot(lotId: 'l1', quantity: 5, dispatchedAt: _mon),
          _lot(
            lotId: 'l2',
            quantity: 5,
            loadPriceKobo: newPrice,
            dispatchedAt: _wed,
          ),
        ],
        sales: const [],
        // 7 back: 5 at the old price + 2 at the new one, exactly what
        // `recordReturn`'s per-segment credit writes.
        returns: [_good(quantity: 7, creditKobo: 5 * _loadPrice + 2 * newPrice)],
        ledger: [
          _debit(kDriverLedgerTypeLoad, 5 * _loadPrice),
          _debit(kDriverLedgerTypeRestock, 5 * newPrice),
          _credit(
            kDriverLedgerTypeReturnGood,
            5 * _loadPrice + 2 * newPrice,
          ),
        ],
      );

      expect(p.goodReturnValueKobo, 5 * _loadPrice + 2 * newPrice);
      expect(p.shortageUnits, 3);
      expect(p.shortageValueKobo, 3 * newPrice);
      _assertInvariants(p, label: 'two-lot return');
    });

    test('the rung value is carried beside the load-price valuation', () {
      // Spec §9.2 #9: the driver's street markup is off-book by design. The
      // reconciliation values the goods at what they signed for; what the
      // terminal recorded is surfaced, never quietly used as the basis.
      final p = computeVanTripPosition(
        lots: [_lot(lotId: 'l1', quantity: 10)],
        sales: [_sale(quantity: 10, rungValueKobo: 10 * _loadPrice + 3000000)],
        returns: const [],
        ledger: [
          _debit(kDriverLedgerTypeLoad, 10 * _loadPrice),
          _credit(kDriverLedgerTypePaymentCash, 10 * _loadPrice),
        ],
      );

      expect(p.soldValueKobo, 10 * _loadPrice);
      expect(p.rungValueKobo, 10 * _loadPrice + 3000000);
      expect(p.isSettled, isTrue);
      _assertInvariants(p, label: 'street markup');
    });
  });

  group('write-offs are dual-valued (spec §5.5)', () {
    // 10 out, 5 sold and remitted, 3 damaged, 2 short. Both losses written off
    // at LOAD PRICE on the ledger; the company loss stays at COST.
    VanTripPosition build({
      int shortageWriteoff = 0,
      int damageWriteoff = 0,
    }) => computeVanTripPosition(
      lots: [_lot(lotId: 'l1', quantity: 10)],
      sales: [_sale(quantity: 5)],
      returns: [_damaged(quantity: 3)],
      ledger: [
        _debit(kDriverLedgerTypeLoad, 10 * _loadPrice),
        _credit(kDriverLedgerTypePaymentCash, 5 * _loadPrice),
        if (shortageWriteoff > 0)
          _credit(kDriverLedgerTypeShortageWriteoff, shortageWriteoff),
        if (damageWriteoff > 0)
          _credit(kDriverLedgerTypeDamageWriteoff, damageWriteoff),
      ],
    );

    test('without write-offs the driver carries both losses', () {
      final p = build();
      expect(p.shortageUnits, 2);
      expect(p.shortageOwedKobo, 2 * _loadPrice);
      expect(p.damageOwedKobo, 3 * _loadPrice);
      expect(p.outstandingKobo, 5 * _loadPrice);
      _assertInvariants(p, label: 'no write-off');
    });

    test('a write-off credits at load price and clears only its own bucket', () {
      final p = build(damageWriteoff: 3 * _loadPrice);

      expect(p.damageWriteoffKobo, 3 * _loadPrice);
      expect(p.damageOwedKobo, 0, reason: 'the damage was forgiven');
      expect(
        p.shortageOwedKobo,
        2 * _loadPrice,
        reason: 'a damage write-off must not forgive the shortage',
      );
      expect(p.outstandingKobo, 2 * _loadPrice);
      _assertInvariants(p, label: 'damage written off');
    });

    test('forgiving everything settles the trip', () {
      final p = build(
        damageWriteoff: 3 * _loadPrice,
        shortageWriteoff: 2 * _loadPrice,
      );

      expect(p.isSettled, isTrue);
      expect(p.outstandingKobo, 0);
      _assertInvariants(p, label: 'all written off');
    });

    test('a write-off never moves profit — the cost is already in COGS', () {
      // The double-count guard, stated as a comparison: forgiving ₦57,500 of
      // debt changes what the DRIVER owes and nothing about what the business
      // earned, because the goods left either way.
      final without = build();
      final with_ = build(
        damageWriteoff: 3 * _loadPrice,
        shortageWriteoff: 2 * _loadPrice,
      );

      expect(with_.profitKobo, without.profitKobo);
      expect(with_.cogsKobo, without.cogsKobo);
      expect(with_.recoveredKobo, without.recoveredKobo);
      // The disclosure lines are unchanged too — they describe the goods, not
      // the forgiveness.
      expect(with_.shortageLossKobo, 2 * _unitCost);
      expect(with_.damageLossKobo, 3 * _unitCost);
    });
  });

  group('over-payment and credit', () {
    test('cash beyond the road takings pays down damage, then shortage', () {
      // 10 out, 5 sold, 3 damaged, 2 short, and the driver hands in the LOT.
      final p = computeVanTripPosition(
        lots: [_lot(lotId: 'l1', quantity: 10)],
        sales: [_sale(quantity: 5)],
        returns: [_damaged(quantity: 3)],
        ledger: [
          _debit(kDriverLedgerTypeLoad, 10 * _loadPrice),
          _credit(kDriverLedgerTypePaymentCash, 9 * _loadPrice),
        ],
      );

      expect(p.unremittedCashKobo, 0);
      expect(p.damageOwedKobo, 0);
      expect(p.shortageOwedKobo, 1 * _loadPrice);
      expect(p.outstandingKobo, 1 * _loadPrice);
      _assertInvariants(p, label: 'waterfall');
    });

    test('a driver in credit reports a residual credit, not a negative line', () {
      final p = computeVanTripPosition(
        lots: [_lot(lotId: 'l1', quantity: 10)],
        sales: [_sale(quantity: 10)],
        returns: const [],
        ledger: [
          _debit(kDriverLedgerTypeLoad, 10 * _loadPrice),
          _credit(kDriverLedgerTypePaymentCash, 12 * _loadPrice),
        ],
      );

      expect(p.balanceKobo, 2 * _loadPrice); // positive = in credit
      expect(p.unremittedCashKobo, 0);
      expect(p.shortageOwedKobo, 0);
      expect(p.damageOwedKobo, 0);
      expect(p.residualCreditKobo, 2 * _loadPrice);
      expect(p.outstandingKobo, -2 * _loadPrice);
      _assertInvariants(p, label: 'in credit');
    });
  });

  group('uncosted and degenerate loads', () {
    test('an uncosted lot books zero COGS without inventing a cost', () {
      // Spec §9.1 #2 — a product with no cost batch loads at unit_cost 0. It
      // must not silently become free goods: profit reads as the whole
      // recovered value, which is exactly what an uncosted line means.
      final p = computeVanTripPosition(
        lots: [_lot(lotId: 'l1', quantity: 10, unitCostKobo: 0)],
        sales: [_sale(quantity: 10)],
        returns: const [],
        ledger: [
          _debit(kDriverLedgerTypeLoad, 10 * _loadPrice),
          _credit(kDriverLedgerTypePaymentCash, 10 * _loadPrice),
        ],
      );

      expect(p.cogsKobo, 0);
      expect(p.recoveredKobo, 10 * _loadPrice);
      expect(p.profitKobo, 10 * _loadPrice);
      _assertInvariants(p, label: 'uncosted');
    });

    test('an empty trip is all zeroes and still ties out', () {
      final p = computeVanTripPosition(
        lots: const [],
        sales: const [],
        returns: const [],
        ledger: const [],
      );

      expect(p.loadedValueKobo, 0);
      expect(p.balanceKobo, 0);
      expect(p.outstandingKobo, 0);
      expect(p.isSettled, isTrue);
      expect(p.shortages, isEmpty);
      _assertInvariants(p, label: 'empty');
    });

    test('a restatement pair nets to zero on the balance', () {
      // Spec §9.4 #15 — the compensating pair exists for the audit trail and
      // the artifact correction, not to move the balance.
      final p = computeVanTripPosition(
        lots: [_lot(lotId: 'l1', quantity: 10)],
        sales: [_sale(quantity: 10)],
        returns: const [],
        ledger: [
          _debit(kDriverLedgerTypeLoad, 10 * _loadPrice),
          _credit(kDriverLedgerTypeRestatement, 2 * _loadPrice),
          _debit(kDriverLedgerTypeRestatement, 2 * _loadPrice),
        ],
      );

      expect(p.balanceKobo, -10 * _loadPrice);
      expect(p.unremittedCashKobo, 10 * _loadPrice);
      _assertInvariants(p, label: 'restated');
    });
  });

  group('spec §9.1 #2 — uncosted goods are disclosed, never silent', () {
    test('a lot with no cost behind it is counted, and COGS excludes it', () {
      // The warehouse had no costed batch for these units, so dispatch drew
      // nothing and stamped unit_cost 0. They are real goods that really left,
      // and the driver really signed for them at load price — but they cost
      // the books nothing, so the profit below is NOT ₦115,000 of margin.
      final p = computeVanTripPosition(
        lots: [_lot(lotId: 'l1', quantity: 10, unitCostKobo: 0)],
        sales: [_sale(quantity: 10)],
        returns: const [],
        ledger: [
          _debit(kDriverLedgerTypeLoad, 10 * _loadPrice),
          _credit(kDriverLedgerTypePaymentCash, 10 * _loadPrice),
        ],
      );

      expect(p.uncostedUnits, 10);
      expect(p.hasUncostedUnits, isTrue);
      expect(
        p.cogsKobo,
        0,
        reason: 'nothing was drawn, so nothing can be booked as cost',
      );
      expect(
        p.profitKobo,
        10 * _loadPrice,
        reason:
            'the whole recovery reads as profit precisely BECAUSE the cost is '
            'missing — which is why the screen must say so',
      );
      _assertInvariants(p, label: 'uncosted');
    });

    test('only the uncosted lot counts when a trip mixes both', () {
      final p = computeVanTripPosition(
        lots: [
          _lot(lotId: 'l1', quantity: 6), // costed
          _lot(lotId: 'l2', quantity: 4, unitCostKobo: 0, dispatchedAt: _wed),
        ],
        sales: [_sale(quantity: 10)],
        returns: const [],
        ledger: [_debit(kDriverLedgerTypeLoad, 10 * _loadPrice)],
      );

      expect(p.uncostedUnits, 4);
      expect(p.cogsKobo, 6 * _unitCost);
      _assertInvariants(p, label: 'mixed costed/uncosted');
    });

    test('a fully costed trip discloses nothing', () {
      final p = computeVanTripPosition(
        lots: [_lot(lotId: 'l1', quantity: 10)],
        sales: [_sale(quantity: 10)],
        returns: const [],
        ledger: [_debit(kDriverLedgerTypeLoad, 10 * _loadPrice)],
      );

      expect(p.uncostedUnits, 0);
      expect(p.hasUncostedUnits, isFalse);
      _assertInvariants(p, label: 'fully costed');
    });

    test('units returned good still count — the load was uncosted', () {
      // The disclosure is about the LOAD, not about what was consumed: a
      // returned uncosted unit re-batches the warehouse at 0 too, so the
      // problem follows the goods rather than being cancelled by the return.
      final p = computeVanTripPosition(
        lots: [_lot(lotId: 'l1', quantity: 10, unitCostKobo: 0)],
        sales: const [],
        returns: [_good(quantity: 10, costKobo: 0)],
        ledger: [
          _debit(kDriverLedgerTypeLoad, 10 * _loadPrice),
          _credit(kDriverLedgerTypeReturnGood, 10 * _loadPrice),
        ],
      );

      expect(p.uncostedUnits, 10);
      expect(p.balanceKobo, 0, reason: 'everything came back — settled');
      _assertInvariants(p, label: 'uncosted, all returned');
    });
  });

  group('#207 — shell loss valued at the manufacturer deposit rate', () {
    // A trip that settles EXACTLY: 10 loaded, 10 sold, every naira handed in.
    // Every money figure on it is 0 or fully covered, which is what makes it
    // the right fixture for the valuation — a shell value that leaked into the
    // settlement would be impossible to miss, and it is the literal §11 case:
    // "balance 0 = settled" while the shells never came back.
    VanTripPosition settledWithShells(
      List<VanPositionShellLine> shells, {
      int shellsOut = 0,
      int shellsBack = 0,
    }) => computeVanTripPosition(
      lots: [_lot(lotId: 'l1', quantity: 10)],
      sales: [_sale(quantity: 10)],
      returns: const [],
      ledger: [
        _debit(kDriverLedgerTypeLoad, 10 * _loadPrice),
        _credit(kDriverLedgerTypePaymentCash, 10 * _loadPrice),
      ],
      shellsOut: shellsOut,
      shellsBack: shellsBack,
      shells: shells,
    );

    // The same trip, but the driver is short: 10 out, 8 sold, 1 good back, 1
    // damaged, ₦57,500 remitted against ₦92,000 of takings. Balance −₦46,000.
    VanTripPosition owingWithShells(List<VanPositionShellLine> shells) =>
        computeVanTripPosition(
          lots: [_lot(lotId: 'l1', quantity: 10)],
          sales: [_sale(quantity: 8)],
          returns: [_good(quantity: 1), _damaged(quantity: 1)],
          ledger: [
            _debit(kDriverLedgerTypeLoad, 10 * _loadPrice),
            _credit(kDriverLedgerTypeReturnGood, 1 * _loadPrice),
            _credit(kDriverLedgerTypePaymentCash, 5 * _loadPrice),
          ],
          shells: shells,
        );

    test('35 shells never came back — ₦63,000, on a trip that says settled', () {
      // Spec §11 / ADR 0019, made into money: the §6.3 worked trip's shell
      // memo, now at ₦1,800 a crate.
      final p = settledWithShells([
        _shells(out: 100, back: 65),
      ], shellsOut: 100, shellsBack: 65);

      expect(p.shellsLostUnits, 35);
      expect(p.shellsLostValueKobo, 6300000); // ₦63,000
      expect(p.hasShellLoss, isTrue);
      expect(p.shellLosses, hasLength(1));
      final line = p.shellLosses.single;
      expect(line.manufacturerId, _starBrand);
      expect(line.units, 35);
      expect(line.depositRateKobo, _starShellRate);
      expect(line.valueKobo, 6300000);
      expect(
        p.isSettled,
        isTrue,
        reason:
            'the whole point of §11: the ledger says settled while ₦63,000 of '
            'deposit value drove off and did not come back',
      );
      _assertInvariants(p, label: 'shell loss on a settled trip');
    });

    test('every shell back is nothing to disclose', () {
      final p = settledWithShells([
        _shells(out: 40, back: 40),
      ], shellsOut: 40, shellsBack: 40);

      expect(p.shellsLostUnits, 0);
      expect(p.shellsLostValueKobo, 0);
      expect(p.hasShellLoss, isFalse);
      expect(
        p.shellLosses,
        isEmpty,
        reason: 'a brand that lost nothing gets no line',
      );
      _assertInvariants(p, label: 'no shell loss');
    });

    test('more shells back than out is a surplus, never a negative loss', () {
      // A driver who collects strays off the route brings back more than they
      // took. That is not a −₦27,000 credit against the business.
      final p = settledWithShells([
        _shells(out: 40, back: 55),
      ], shellsOut: 40, shellsBack: 55);

      expect(p.shellsLostUnits, 0);
      expect(p.shellsLostValueKobo, 0);
      expect(p.shellLosses, isEmpty);
      expect(
        p.shellsDifference,
        -15,
        reason:
            'the raw memo still reports the surplus — it is the VALUED figure '
            'that floors, so no screen can read a negative loss as money owed '
            'to the driver',
      );
      _assertInvariants(p, label: 'shell surplus');
    });

    test('a mixed-brand load values each brand at its own rate', () {
      // Star ₦1,800, Gulder ₦2,500 — one weighted average across the load
      // would be wrong in kobo for both.
      final p = settledWithShells([
        _shells(out: 60, back: 40), // 20 lost × ₦1,800 = ₦36,000
        _shells(
          manufacturerId: _gulderBrand,
          out: 30,
          back: 25,
          depositRateKobo: _gulderShellRate,
        ), // 5 lost × ₦2,500 = ₦12,500
      ], shellsOut: 90, shellsBack: 65);

      expect(p.shellsLostUnits, 25);
      expect(p.shellsLostValueKobo, 4850000); // ₦48,500
      expect(p.shellLosses, hasLength(2));
      expect(
        p.shellLosses.map((l) => l.manufacturerId),
        [_starBrand, _gulderBrand],
        reason: 'largest value first, like the shortage lines',
      );
      expect(p.shellLosses.first.valueKobo, 3600000); // ₦36,000
      expect(p.shellLosses.last.valueKobo, 1250000); // ₦12,500
      expect(p.shellLosses.last.depositRateKobo, _gulderShellRate);
      _assertInvariants(p, label: 'mixed-brand shell loss');
    });

    test('one brand’s surplus never pays for another brand’s loss', () {
      // Shells are fungible WITHIN a brand and not across it — a Gulder crate
      // does not replace a Star crate. The trip memo nets to zero here and
      // would report a clean trip; the valued figure does not.
      final p = settledWithShells([
        _shells(out: 40, back: 10), // 30 Star lost
        _shells(
          manufacturerId: _gulderBrand,
          out: 10,
          back: 40, // 30 Gulder surplus
          depositRateKobo: _gulderShellRate,
        ),
      ], shellsOut: 50, shellsBack: 50);

      expect(
        p.shellsDifference,
        0,
        reason: 'the unattributed memo cancels the two brands out',
      );
      expect(p.shellsLostUnits, 30);
      expect(p.shellsLostValueKobo, 5400000); // 30 × ₦1,800 = ₦54,000
      expect(p.shellLosses, hasLength(1));
      expect(p.shellLosses.single.manufacturerId, _starBrand);
      _assertInvariants(p, label: 'cross-brand surplus');
    });

    test('lines repeating a brand fold together before the floor', () {
      // The caller may pass one line per lot and one per return event — the
      // grain `van_trip_lots` and `van_return_events` actually store — and get
      // the same answer as one pre-grouped line per brand. Shells of one brand
      // are fungible across the lots they rode out on.
      final p = settledWithShells([
        _shells(out: 40), // morning lot
        _shells(out: 20), // afternoon restock
        _shells(back: 55), // one return event
      ], shellsOut: 60, shellsBack: 55);

      expect(p.shellsLostUnits, 5);
      expect(p.shellsLostValueKobo, 900000); // ₦9,000
      expect(
        p.shellLosses,
        hasLength(1),
        reason: 'one brand is one line however many lots it rode out on',
      );
      _assertInvariants(p, label: 'folded shell lines');
    });

    test('a brand with no deposit configured is counted, never valued', () {
      final p = settledWithShells([
        _shells(out: 10, depositRateKobo: 0),
      ], shellsOut: 10);

      expect(p.shellsLostUnits, 10);
      expect(p.shellsLostValueKobo, 0);
      expect(p.hasShellLoss, isTrue);
      expect(
        p.shellLosses.single.valueKobo,
        0,
        reason:
            'a business that runs no deposits still gets the count — silence '
            'would be the §11 failure all over again',
      );
      _assertInvariants(p, label: 'unpriced shells');
    });

    test('the valuation is DISCLOSURE ONLY — it moves no money figure', () {
      // The constraint the whole slice hangs on. Whether a driver OWES for a
      // lost shell is a money-model decision that amends ADR 0019 and has not
      // been taken. Until it is, this figure states the exposure beside the
      // settlement, exactly as `shortageLossKobo` / `damageLossKobo` state
      // theirs beside COGS.
      const figures = <String, int Function(VanTripPosition)>{
        'balanceKobo': _balance,
        'outstandingKobo': _outstanding,
        'unremittedCashKobo': _unremitted,
        'shortageOwedKobo': _shortageOwed,
        'damageOwedKobo': _damageOwed,
        'residualCreditKobo': _residualCredit,
        'shortageValueKobo': _shortageValue,
        'damageValueKobo': _damageValue,
        'soldValueKobo': _soldValue,
        'loadedValueKobo': _loadedValue,
        'goodReturnValueKobo': _goodReturnValue,
        'recoveredKobo': _recovered,
        'cogsKobo': _cogs,
        'profitKobo': _profit,
        'shortageLossKobo': _shortageLoss,
        'damageLossKobo': _damageLoss,
      };

      final cases = <String, (VanTripPosition, VanTripPosition)>{
        // A trip that owes: the shell value must not join the debt…
        'owing': (
          owingWithShells(const []),
          owingWithShells([_shells(out: 100, back: 65)]),
        ),
        // …and a trip that owes nothing must not be dragged into owing.
        'settled': (
          settledWithShells(const []),
          settledWithShells([_shells(out: 100, back: 65)]),
        ),
      };

      for (final c in cases.entries) {
        final (without, withShells) = c.value;
        expect(
          withShells.shellsLostValueKobo,
          6300000,
          reason: '${c.key}: the fixture must actually value something',
        );
        expect(without.shellsLostValueKobo, 0);
        for (final f in figures.entries) {
          expect(
            f.value(withShells),
            f.value(without),
            reason:
                '${c.key}: ${f.key} moved when shell lines were added. The '
                'shell valuation is disclosure only (#207) — folding it into '
                'the settlement breaks outstanding == −balance and charges a '
                'driver for a debt nobody has decided they owe.',
          );
        }
        _assertInvariants(withShells, label: '${c.key} with shells');
        _assertInvariants(without, label: '${c.key} without shells');
      }

      // Named once, so the guard is not only a loop: the driver owes ₦46,000
      // for goods, and not one kobo more for the ₦63,000 of missing shells.
      final owing = cases['owing']!.$2;
      expect(owing.balanceKobo, -4 * _loadPrice); // −₦46,000
      expect(owing.outstandingKobo, 4 * _loadPrice);
      expect(owing.shellsLostValueKobo, 6300000);
    });
  });
}

// Field readers for the disclosure guard above. Top-level so the map can be
// `const` — closures cannot be.
int _balance(VanTripPosition p) => p.balanceKobo;
int _outstanding(VanTripPosition p) => p.outstandingKobo;
int _unremitted(VanTripPosition p) => p.unremittedCashKobo;
int _shortageOwed(VanTripPosition p) => p.shortageOwedKobo;
int _damageOwed(VanTripPosition p) => p.damageOwedKobo;
int _residualCredit(VanTripPosition p) => p.residualCreditKobo;
int _shortageValue(VanTripPosition p) => p.shortageValueKobo;
int _damageValue(VanTripPosition p) => p.damageValueKobo;
int _soldValue(VanTripPosition p) => p.soldValueKobo;
int _loadedValue(VanTripPosition p) => p.loadedValueKobo;
int _goodReturnValue(VanTripPosition p) => p.goodReturnValueKobo;
int _recovered(VanTripPosition p) => p.recoveredKobo;
int _cogs(VanTripPosition p) => p.cogsKobo;
int _profit(VanTripPosition p) => p.profitKobo;
int _shortageLoss(VanTripPosition p) => p.shortageLossKobo;
int _damageLoss(VanTripPosition p) => p.damageLossKobo;
