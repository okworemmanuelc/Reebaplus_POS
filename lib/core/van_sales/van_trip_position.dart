/// The van trip reconciliation math — one **pure function** over plain data
/// (#145, van-sales spec §6, ADR 0019).
///
/// This is deliberately shaped unlike `computeReconData`, which takes a
/// `WidgetRef` and reads ~16 providers. The trip position is settlement math: a
/// manager is about to decide, on the strength of these numbers, whether a
/// driver owes ₦192,500 or nothing. Math that decides that must be exercisable
/// without a widget, a database or a provider container — so it takes lots,
/// sales, returns and ledger rows as values and returns one immutable answer
/// (spec §13 seam 1).
///
/// **The tie-out invariant is the reason the function exists.** Two independent
/// computations meet here: the driver's balance is the signed sum of an
/// append-only ledger, while the outstanding position is derived from the lots,
/// the sales and the returns. [VanTripPosition.tieOutDeltaKobo] is their
/// difference and it must be 0 — if the two ever disagree, one of them is
/// wrong, and the fixture suite says so on every constructed case.
library;

import 'package:reebaplus_pos/core/database/app_database.dart';

// ── Inputs ───────────────────────────────────────────────────────────────────

/// One priced load lot, as dispatched (`van_trip_lots`).
///
/// [quantity] is the ORIGINAL dispatched count, never `qty_remaining`: the
/// position replays the trip from what left the warehouse, so the return cursor
/// is an output of the math rather than an input to it.
class VanPositionLot {
  final String lotId;
  final String productId;
  final int quantity;
  final int loadPriceKobo;
  final int unitCostKobo;
  final DateTime dispatchedAt;

  const VanPositionLot({
    required this.lotId,
    required this.productId,
    required this.quantity,
    required this.loadPriceKobo,
    required this.unitCostKobo,
    required this.dispatchedAt,
  });
}

/// One road-sale line on a recognised order (`order_items` of an order whose
/// status passes `orderCountsAsSale`).
///
/// [rungValueKobo] is what the terminal actually charged. It is carried
/// separately from the load-price valuation because the two are allowed to
/// differ: a driver's street markup is off-book by design (spec §9.2 #9), and
/// the reconciliation values the goods at what the driver signed for.
class VanPositionSaleLine {
  final String productId;
  final int quantity;
  final int rungValueKobo;

  const VanPositionSaleLine({
    required this.productId,
    required this.quantity,
    required this.rungValueKobo,
  });
}

/// One recorded return (`van_return_events`).
///
/// [creditKobo] and [costKobo] are the SNAPSHOTS the return wrote (#143), never
/// recomputed here — a later cost edit must not restate a settled return.
class VanPositionReturn {
  final String productId;
  final int quantity;
  final String condition;
  final int creditKobo;
  final int costKobo;

  const VanPositionReturn({
    required this.productId,
    required this.quantity,
    required this.condition,
    required this.creditKobo,
    required this.costKobo,
  });

  bool get isGood => condition == kVanReturnConditionGood;
}

/// One manufacturer's empty-crate shells on the trip, with the deposit rate
/// they are valued at (#207, spec §11, ADR 0019's deferred crate pass).
///
/// **Why the grain is the manufacturer and not the lot or the product.** The
/// deposit rate is `Manufacturers.deposit_amount_kobo` — canonical per brand,
/// with `Products.empty_crate_value_kobo` only mirroring it — so a rate keyed
/// any finer would be the same number written down several times, free to
/// drift. More importantly the *floor* has to be applied at this grain:
/// **shells of one brand are fungible**. A driver who carries out 40 Star
/// shells on a morning lot and 20 more on an afternoon restock, and brings 55
/// back, has lost 5 Star shells — not "0 on one lot and 5 on the other", and
/// certainly not a loss on one Star product cancelled by a surplus on another.
/// This is the same reasoning `CrateShortfall` states for the supplier side:
/// crates are fungible, and a number that guesses which crate went missing is a
/// number someone will dispute.
///
/// [shellsOut] and [shellsBack] are the memo counts v1 already writes
/// (`van_trip_lots.shells_out`, `van_return_events.shells_back`), grouped by
/// the product's manufacturer. Lines that repeat a [manufacturerId] are folded
/// together **before** the floor is applied, so a caller may pass one line per
/// lot or one line per brand and get the same answer.
///
/// [depositRateKobo] is what one shell of this brand is worth. 0 is legitimate
/// — a manufacturer with no deposit configured, or a business that does not run
/// deposits at all — and simply means the loss is counted but not valued.
class VanPositionShellLine {
  final String manufacturerId;
  final int shellsOut;
  final int shellsBack;
  final int depositRateKobo;

  const VanPositionShellLine({
    required this.manufacturerId,
    this.shellsOut = 0,
    this.shellsBack = 0,
    this.depositRateKobo = 0,
  });
}

/// One driver-ledger row (`driver_ledger_entries`), reduced to the two fields
/// the position needs: what kind of money movement it was, and which way.
class VanPositionLedgerEntry {
  final String type;
  final int signedAmountKobo;

  const VanPositionLedgerEntry({
    required this.type,
    required this.signedAmountKobo,
  });
}

// ── Outputs ──────────────────────────────────────────────────────────────────

/// One product's unaccounted-for goods: what left, never came back, and was
/// never rung.
class VanShortageLine {
  final String productId;

  /// `loaded − sold − good returns − damaged`, in units.
  final int units;

  /// Those units at the load prices they were loaded at (FIFO — the newest
  /// lots are the ones presumed missing, because the oldest are presumed sold).
  final int valueKobo;

  /// Those same units at their lots' SNAPSHOTTED cost — the company-loss basis
  /// if the shortage is written off (spec §5.5).
  final int costKobo;

  /// The distinct load prices the shortage draws from, oldest lot first. One
  /// entry for the ordinary single-price run; two when a restock repriced.
  final List<int> loadPricesKobo;

  const VanShortageLine({
    required this.productId,
    required this.units,
    required this.valueKobo,
    required this.costKobo,
    required this.loadPricesKobo,
  });
}

/// One manufacturer's shells that went out and did not come back, valued at
/// that brand's deposit rate (#207).
///
/// **Disclosure only.** See [VanTripPosition.shellsLostValueKobo] — this line
/// is a statement about crates, not a debt. Nothing here reaches the driver's
/// balance.
class VanShellLossLine {
  final String manufacturerId;

  /// `shellsOut − shellsBack` for this brand, **floored at 0**: bringing back
  /// more shells than went out is a surplus, not a negative loss, and a
  /// surplus on one brand never nets off a loss on another.
  final int units;

  /// `Manufacturers.deposit_amount_kobo` for this brand, as supplied.
  final int depositRateKobo;

  /// `units × depositRateKobo`.
  final int valueKobo;

  const VanShellLossLine({
    required this.manufacturerId,
    required this.units,
    required this.depositRateKobo,
    required this.valueKobo,
  });
}

/// The whole position of one trip at a moment in time (spec §6.1 / §6.2).
class VanTripPosition {
  // ── Units ────────────────────────────────────────────────────────────────
  final int loadedUnits;
  final int soldUnits;
  final int goodReturnedUnits;
  final int damagedUnits;
  final int shortageUnits;

  // ── At load price (the single valuation of the reconciliation) ───────────
  final int loadedValueKobo;

  /// The sold units valued at the LOAD prices they drew from, FIFO. This is
  /// the accountability figure — what the driver owes for the goods — and it is
  /// what the tie-out balances against.
  final int soldValueKobo;

  /// What the terminal actually rang (Σ recognised order net amounts). Equal to
  /// [soldValueKobo] on an ordinary run; a difference is the driver's off-book
  /// street markup (spec §9.2 #9), surfaced rather than silently absorbed.
  final int rungValueKobo;

  final int goodReturnValueKobo;
  final int damageValueKobo;
  final int shortageValueKobo;
  final int remittedKobo;
  final int shortageWriteoffKobo;
  final int damageWriteoffKobo;

  // ── Balance and its three-way split ──────────────────────────────────────
  /// The LEDGER's own answer: `Σ signed_amount_kobo`. Negative = the driver
  /// owes. Never derived — this is the append-only truth.
  final int balanceKobo;

  /// The DERIVED answer: unremitted cash + shortage + damage still owed, less
  /// any surplus credit. Must equal `−balanceKobo` (see [tieOutDeltaKobo]).
  final int outstandingKobo;

  /// Road takings not yet handed in.
  final int unremittedCashKobo;

  /// Shortage the driver is still liable for (after write-offs and after any
  /// cash that over-covered the road takings).
  final int shortageOwedKobo;

  /// Damage the driver is still liable for, same treatment.
  final int damageOwedKobo;

  /// Credit left over once all three buckets are cleared — a driver who has
  /// handed in more than they owe.
  final int residualCreditKobo;

  // ── Cost and the close artifact's P&L legs ───────────────────────────────
  final int loadedCostKobo;
  final int goodReturnCostKobo;

  /// `loadedCost − goodReturnCost` — spec §5.2's `Σ consumed lot units × that
  /// lot's unit cost`, with `consumed = loaded − good returns` (so sold,
  /// shortage AND damaged units are all inside it).
  final int cogsKobo;

  /// **Disclosure only.** The shortage at cost. Its value is ALREADY inside
  /// [cogsKobo]; a report that subtracts it again double-counts (spec §6.3).
  final int shortageLossKobo;

  /// **Disclosure only**, same as [shortageLossKobo].
  final int damageLossKobo;

  /// Units on this trip whose lot carries `unit_cost_kobo == 0` because the
  /// source warehouse had no costed batch to draw at dispatch (spec §9.1 #2).
  ///
  /// Loading uncosted goods is allowed — but it must never be silent. Those
  /// units contribute **nothing** to [cogsKobo], so this trip's profit is
  /// **overstated** by whatever they actually cost. Left undisclosed they read
  /// as free goods and the close artifact reports a profit nobody earned.
  ///
  /// This is the trip's arm of the same Uncosted transparency the store-side
  /// reports use (`ReconData.uncostedItems`). It cannot flow into that bucket
  /// directly — van orders are excluded from every per-store figure by design
  /// (§8.1) and road lines deliberately carry `buying_price_kobo == 0` (§5.6) —
  /// so the disclosure has to live where van P&L lives: here, and on the
  /// reconcile screen before Confirm.
  final int uncostedUnits;

  /// Load-price value actually recovered: remittances + good returns.
  final int recoveredKobo;

  /// `recovered − cogs`. The write-off lines are NOT subtracted — the
  /// written-off units are inside `consumed`, so their cost is already in
  /// [cogsKobo] (spec §6.3's double-count guard).
  final int profitKobo;

  // ── Shell memo (spec §11 — counting only, no money) ──────────────────────
  final int shellsOut;
  final int shellsBack;

  // ── Shell loss, valued (#207) ────────────────────────────────────────────
  /// Shells that went out and did not come back, summed over the brands in
  /// [shellLosses] — so the floor is applied **per manufacturer** before the
  /// sum (a surplus of one brand's shells does not pay for another's loss).
  ///
  /// This is not the same quantity as [shellsDifference], and deliberately so:
  /// that one is the trip's raw memo arithmetic, unfloored and unattributed,
  /// and it goes negative when more shells come back than went out. Where a
  /// trip carries one brand and the memo totals agree with the lines, the two
  /// agree. 0 when the caller supplies no shell lines, which is every caller
  /// until the crate-cargo slice of #207 wires them.
  final int shellsLostUnits;

  /// **Disclosure only.** [shellsLostUnits] at the manufacturer deposit rate —
  /// the ~₦63,000 of shells the spec §6.3 worked trip loses while closing at
  /// "balance 0 = settled" (spec §11, ADR 0019).
  ///
  /// It is deliberately **outside every money identity in this class**. It is
  /// not in [balanceKobo], not in [outstandingKobo], not in [shortageOwedKobo],
  /// not in [cogsKobo] and not in [profitKobo]. Whether a driver actually OWES
  /// for a lost shell is a money-model decision — it would need a driver-ledger
  /// entry type, a write-off path and an amendment to ADR 0019 — and until that
  /// decision is taken and booked, this figure states the exposure without
  /// asserting a debt. A screen adds it to a total at its peril: the tie-out
  /// `outstanding == −balance` is what would break.
  final int shellsLostValueKobo;

  /// Per-manufacturer detail behind [shellsLostValueKobo], largest value first.
  /// Brands that lost nothing are absent.
  final List<VanShellLossLine> shellLosses;

  final List<VanShortageLine> shortages;

  const VanTripPosition({
    required this.loadedUnits,
    required this.soldUnits,
    required this.goodReturnedUnits,
    required this.damagedUnits,
    required this.shortageUnits,
    required this.loadedValueKobo,
    required this.soldValueKobo,
    required this.rungValueKobo,
    required this.goodReturnValueKobo,
    required this.damageValueKobo,
    required this.shortageValueKobo,
    required this.remittedKobo,
    required this.shortageWriteoffKobo,
    required this.damageWriteoffKobo,
    required this.balanceKobo,
    required this.outstandingKobo,
    required this.unremittedCashKobo,
    required this.shortageOwedKobo,
    required this.damageOwedKobo,
    required this.residualCreditKobo,
    required this.loadedCostKobo,
    required this.goodReturnCostKobo,
    required this.cogsKobo,
    required this.shortageLossKobo,
    required this.damageLossKobo,
    this.uncostedUnits = 0,
    required this.recoveredKobo,
    required this.profitKobo,
    required this.shellsOut,
    required this.shellsBack,
    this.shellsLostUnits = 0,
    this.shellsLostValueKobo = 0,
    this.shellLosses = const [],
    required this.shortages,
  });

  /// Shells that went out and did not come back (spec §11) — the trip's raw
  /// memo arithmetic, which goes negative when more came back than went out.
  /// The point of the memo is that a trip cannot close at "balance 0 = settled"
  /// having silently lost every crate. For the floored, per-brand, valued
  /// answer see [shellsLostUnits] / [shellsLostValueKobo].
  int get shellsDifference => shellsOut - shellsBack;

  /// True when any brand's shells went out and did not come back — the
  /// reconcile screen's condition for showing the shell-loss line at all.
  bool get hasShellLoss => shellsLostUnits > 0;

  /// True when the driver owes nothing and is owed nothing.
  bool get isSettled => balanceKobo == 0;

  /// **The tie-out.** `outstanding + balance`, which is 0 when the derived
  /// position and the append-only ledger agree. A non-zero value means one of
  /// them is wrong — a lot written without its ledger debit, a credit posted
  /// without its return event, or a void that moved the balance without a
  /// matching physical fact.
  int get tieOutDeltaKobo => outstandingKobo + balanceKobo;

  /// True when the two independent computations agree (see [tieOutDeltaKobo]).
  bool get tiesOut => tieOutDeltaKobo == 0;

  /// True when anything at all is still unsettled — the reconcile screen's
  /// "this trip will close with a balance" condition.
  bool get hasResidual => balanceKobo != 0;

  /// True when any of this trip's goods left the warehouse with no recorded
  /// cost, so [cogsKobo] is understated and [profitKobo] overstated by an
  /// unknown amount. The reconcile screen must say so before Confirm — see
  /// [uncostedUnits].
  bool get hasUncostedUnits => uncostedUnits > 0;
}

// ── The computation ──────────────────────────────────────────────────────────

/// Compute a trip's whole position from plain data (spec §6).
///
/// The valuation rule, stated once because everything else follows from it:
/// **units leave a trip by drawing its lots down FIFO**, in this order —
/// returns first (they are dated events that already moved the cursor), then
/// sales, and whatever is left over is the shortage. So the oldest goods are
/// presumed sold and the newest are presumed missing, which makes
/// `loaded = good returns + damage + sold + shortage` true by construction at
/// both the total and the per-product level, and makes the tie-out exact even
/// when a restock repriced a product mid-run.
///
/// [shells] is the crate-shell memo grouped by manufacturer, carrying the
/// deposit rate each brand's shells are valued at (#207, spec §11). It is
/// **read and reported, and it enters nothing else in this function** — no
/// balance, no outstanding, no COGS, no profit. See
/// [VanTripPosition.shellsLostValueKobo] for why that is a decision and not an
/// omission.
VanTripPosition computeVanTripPosition({
  required List<VanPositionLot> lots,
  required List<VanPositionSaleLine> sales,
  required List<VanPositionReturn> returns,
  required List<VanPositionLedgerEntry> ledger,
  int shellsOut = 0,
  int shellsBack = 0,
  List<VanPositionShellLine> shells = const [],
}) {
  // ── Group by product; the FIFO order is the dispatch order. ──────────────
  final lotsByProduct = <String, List<VanPositionLot>>{};
  for (final lot in lots) {
    (lotsByProduct[lot.productId] ??= <VanPositionLot>[]).add(lot);
  }
  for (final list in lotsByProduct.values) {
    list.sort((a, b) {
      final byDate = a.dispatchedAt.compareTo(b.dispatchedAt);
      return byDate != 0 ? byDate : a.lotId.compareTo(b.lotId);
    });
  }

  final soldUnitsBy = <String, int>{};
  var rungValueKobo = 0;
  for (final s in sales) {
    if (s.quantity <= 0) continue;
    soldUnitsBy[s.productId] = (soldUnitsBy[s.productId] ?? 0) + s.quantity;
    rungValueKobo += s.rungValueKobo;
  }

  final goodUnitsBy = <String, int>{};
  final damagedUnitsBy = <String, int>{};
  final goodCreditBy = <String, int>{};
  var goodReturnValueKobo = 0;
  var goodReturnCostKobo = 0;
  var damageLossKobo = 0;
  var goodReturnedUnits = 0;
  var damagedUnits = 0;
  for (final r in returns) {
    if (r.quantity <= 0) continue;
    if (r.isGood) {
      goodUnitsBy[r.productId] = (goodUnitsBy[r.productId] ?? 0) + r.quantity;
      goodCreditBy[r.productId] =
          (goodCreditBy[r.productId] ?? 0) + r.creditKobo;
      goodReturnValueKobo += r.creditKobo;
      goodReturnCostKobo += r.costKobo;
      goodReturnedUnits += r.quantity;
    } else {
      damagedUnitsBy[r.productId] =
          (damagedUnitsBy[r.productId] ?? 0) + r.quantity;
      // The damaged units' cost is the snapshot the return wrote — the company
      // loss basis (spec §5.5). It is a DISCLOSURE figure: those units are
      // inside `consumed`, so their cost is already in COGS.
      damageLossKobo += r.costKobo;
      damagedUnits += r.quantity;
    }
  }

  // ── Per product: replay the lots. ────────────────────────────────────────
  var loadedUnits = 0;
  var loadedValueKobo = 0;
  var loadedCostKobo = 0;
  var uncostedUnits = 0;
  var soldUnits = 0;
  var soldValueKobo = 0;
  var damageValueKobo = 0;
  var shortageUnits = 0;
  var shortageValueKobo = 0;
  var shortageLossKobo = 0;
  final shortages = <VanShortageLine>[];

  final productIds = <String>{...lotsByProduct.keys, ...soldUnitsBy.keys};
  for (final productId in productIds) {
    final productLots = lotsByProduct[productId] ?? const <VanPositionLot>[];
    final cursor = _FifoCursor(productLots);

    var productLoadedUnits = 0;
    for (final lot in productLots) {
      productLoadedUnits += lot.quantity;
      loadedValueKobo += lot.quantity * lot.loadPriceKobo;
      loadedCostKobo += lot.quantity * lot.unitCostKobo;
      // §9.1 #2 — a lot dispatched with no costed batch behind it contributes
      // nothing to COGS. Count the units so close can disclose it rather than
      // report a profit that is really just missing cost.
      if (lot.unitCostKobo == 0) uncostedUnits += lot.quantity;
    }
    loadedUnits += productLoadedUnits;

    final good = goodUnitsBy[productId] ?? 0;
    final damaged = damagedUnitsBy[productId] ?? 0;
    final sold = soldUnitsBy[productId] ?? 0;
    soldUnits += sold;

    // 1. Returns move the cursor first — both conditions, because a damaged
    //    unit is off the van too and its lot is consumed exactly like a good
    //    one's (`recordReturn` draws for both).
    final returnedDraw = cursor.take(good + damaged);
    // The good half's credit is the SNAPSHOT the return wrote; the damaged
    // half's load-price value is what is left of the drawn value once that
    // credit is taken out. Drawing them together is what makes this exact
    // regardless of the order the two conditions were recorded in — FIFO value
    // over a total quantity does not depend on how it was split.
    final goodCredit = goodCreditBy[productId] ?? 0;
    final damagedValue = returnedDraw.valueKobo - goodCredit;
    damageValueKobo += damagedValue > 0 ? damagedValue : 0;

    // 2. Sales draw next — the oldest remaining goods are presumed sold.
    final soldDraw = cursor.take(sold);
    soldValueKobo += soldDraw.valueKobo;

    // 3. Whatever the cursor still holds never came back and was never rung.
    final shortDraw = cursor.takeRest();
    if (shortDraw.units > 0) {
      shortageUnits += shortDraw.units;
      shortageValueKobo += shortDraw.valueKobo;
      shortageLossKobo += shortDraw.costKobo;
      shortages.add(
        VanShortageLine(
          productId: productId,
          units: shortDraw.units,
          valueKobo: shortDraw.valueKobo,
          costKobo: shortDraw.costKobo,
          loadPricesKobo: shortDraw.loadPricesKobo,
        ),
      );
    }
  }
  shortages.sort((a, b) => b.valueKobo.compareTo(a.valueKobo));

  // ── The ledger's own answer. ─────────────────────────────────────────────
  var balanceKobo = 0;
  var remittedKobo = 0;
  var shortageWriteoffKobo = 0;
  var damageWriteoffKobo = 0;
  for (final e in ledger) {
    balanceKobo += e.signedAmountKobo;
    switch (e.type) {
      case kDriverLedgerTypePaymentCash:
      case kDriverLedgerTypePaymentTransfer:
        remittedKobo += e.signedAmountKobo;
      case kDriverLedgerTypeShortageWriteoff:
        shortageWriteoffKobo += e.signedAmountKobo;
      case kDriverLedgerTypeDamageWriteoff:
        damageWriteoffKobo += e.signedAmountKobo;
    }
  }

  // ── The three-way split (spec §6.1). ─────────────────────────────────────
  // A waterfall rather than three independent subtractions, because credits do
  // not respect bucket boundaries: cash handed in pays the road takings it came
  // from first, then whatever is still owed on damage, then the shortage. A
  // typed write-off hits its own bucket and its excess (a write-off larger than
  // the exposure) joins the general pool rather than manufacturing a negative
  // line. The identity below holds by construction in every case:
  //
  //   outstanding = unremitted + damageOwed + shortageOwed − residualCredit
  //               = (sold + damage + shortage) − remitted − write-offs
  //               = loadedValue − goodReturns − remitted − write-offs
  //               = −balance
  final damageWriteoffApplied = damageWriteoffKobo < damageValueKobo
      ? damageWriteoffKobo
      : damageValueKobo;
  final shortageWriteoffApplied = shortageWriteoffKobo < shortageValueKobo
      ? shortageWriteoffKobo
      : shortageValueKobo;
  var pool =
      remittedKobo +
      (damageWriteoffKobo - damageWriteoffApplied) +
      (shortageWriteoffKobo - shortageWriteoffApplied);

  final damageExposure = damageValueKobo - damageWriteoffApplied;
  final shortageExposure = shortageValueKobo - shortageWriteoffApplied;

  final unremittedCashKobo = _max0(soldValueKobo - pool);
  pool = _max0(pool - soldValueKobo);
  final damageOwedKobo = _max0(damageExposure - pool);
  pool = _max0(pool - damageExposure);
  final shortageOwedKobo = _max0(shortageExposure - pool);
  final residualCreditKobo = _max0(pool - shortageExposure);

  final outstandingKobo =
      unremittedCashKobo +
      damageOwedKobo +
      shortageOwedKobo -
      residualCreditKobo;

  // ── The close artifact's P&L. ────────────────────────────────────────────
  final cogsKobo = loadedCostKobo - goodReturnCostKobo;
  final recoveredKobo = remittedKobo + goodReturnValueKobo;

  // ── Shell loss at the manufacturer deposit rate (#207). ──────────────────
  // Read the money constraint on [VanTripPosition.shellsLostValueKobo] before
  // touching this block: nothing computed here may reach `balance`,
  // `outstanding`, the three-way split, `cogs` or `profit`. It is a statement
  // about crates that left and did not return, sitting BESIDE the settlement
  // rather than inside it — exactly as `shortageLossKobo` and `damageLossKobo`
  // sit beside COGS.
  //
  // Fold by manufacturer first, THEN floor: shells of one brand are fungible
  // across lots, so a shortfall on the morning lot and a surplus on the
  // afternoon restock are one net figure, while a surplus of one BRAND never
  // pays for the loss of another.
  final shellsOutBy = <String, int>{};
  final shellsBackBy = <String, int>{};
  final shellRateBy = <String, int>{};
  for (final s in shells) {
    shellsOutBy[s.manufacturerId] =
        (shellsOutBy[s.manufacturerId] ?? 0) + s.shellsOut;
    shellsBackBy[s.manufacturerId] =
        (shellsBackBy[s.manufacturerId] ?? 0) + s.shellsBack;
    // The rate belongs to the brand, so repeated lines carry the same number;
    // the first non-zero one wins rather than the last, so a line that omits
    // the rate cannot blank out one that supplied it.
    if ((shellRateBy[s.manufacturerId] ?? 0) == 0) {
      shellRateBy[s.manufacturerId] = s.depositRateKobo;
    }
  }
  var shellsLostUnits = 0;
  var shellsLostValueKobo = 0;
  final shellLosses = <VanShellLossLine>[];
  for (final entry in shellsOutBy.entries) {
    final lost = _max0(entry.value - (shellsBackBy[entry.key] ?? 0));
    if (lost == 0) continue;
    final rateKobo = shellRateBy[entry.key] ?? 0;
    shellsLostUnits += lost;
    shellsLostValueKobo += lost * rateKobo;
    shellLosses.add(
      VanShellLossLine(
        manufacturerId: entry.key,
        units: lost,
        depositRateKobo: rateKobo,
        valueKobo: lost * rateKobo,
      ),
    );
  }
  shellLosses.sort((a, b) {
    final byValue = b.valueKobo.compareTo(a.valueKobo);
    return byValue != 0 ? byValue : a.manufacturerId.compareTo(b.manufacturerId);
  });

  return VanTripPosition(
    loadedUnits: loadedUnits,
    soldUnits: soldUnits,
    goodReturnedUnits: goodReturnedUnits,
    damagedUnits: damagedUnits,
    shortageUnits: shortageUnits,
    loadedValueKobo: loadedValueKobo,
    soldValueKobo: soldValueKobo,
    rungValueKobo: rungValueKobo,
    goodReturnValueKobo: goodReturnValueKobo,
    damageValueKobo: damageValueKobo,
    shortageValueKobo: shortageValueKobo,
    remittedKobo: remittedKobo,
    shortageWriteoffKobo: shortageWriteoffKobo,
    damageWriteoffKobo: damageWriteoffKobo,
    balanceKobo: balanceKobo,
    outstandingKobo: outstandingKobo,
    unremittedCashKobo: unremittedCashKobo,
    shortageOwedKobo: shortageOwedKobo,
    damageOwedKobo: damageOwedKobo,
    residualCreditKobo: residualCreditKobo,
    loadedCostKobo: loadedCostKobo,
    goodReturnCostKobo: goodReturnCostKobo,
    cogsKobo: cogsKobo,
    shortageLossKobo: shortageLossKobo,
    damageLossKobo: damageLossKobo,
    uncostedUnits: uncostedUnits,
    recoveredKobo: recoveredKobo,
    // recovered − cogs. The loss lines are NOT subtracted again: the shortage
    // and damaged units are inside `consumed`, so their cost is already in
    // `cogs` (spec §6.3's double-count guard, pinned by the fixture suite).
    profitKobo: recoveredKobo - cogsKobo,
    shellsOut: shellsOut,
    shellsBack: shellsBack,
    // Disclosure. Deliberately absent from `outstanding`, `balance`, the
    // three-way split and `profit` above — see the field's own doc.
    shellsLostUnits: shellsLostUnits,
    shellsLostValueKobo: shellsLostValueKobo,
    shellLosses: List.unmodifiable(shellLosses),
    shortages: List.unmodifiable(shortages),
  );
}

int _max0(int v) => v > 0 ? v : 0;

/// What one FIFO draw consumed.
class _Draw {
  final int units;
  final int valueKobo;
  final int costKobo;
  final List<int> loadPricesKobo;

  const _Draw(this.units, this.valueKobo, this.costKobo, this.loadPricesKobo);
}

/// A per-product FIFO cursor over one product's lots. Successive [take] calls
/// continue where the previous left off, so returns, sales and the shortage
/// residual all draw from one queue rather than three independent replays that
/// could each claim the same unit.
class _FifoCursor {
  _FifoCursor(this._lots) : _remaining = [for (final l in _lots) l.quantity];

  final List<VanPositionLot> _lots;
  final List<int> _remaining;

  _Draw take(int quantity) {
    if (quantity <= 0) return const _Draw(0, 0, 0, <int>[]);
    var left = quantity;
    var units = 0;
    var value = 0;
    var cost = 0;
    final prices = <int>[];
    for (var i = 0; i < _lots.length && left > 0; i++) {
      final available = _remaining[i];
      if (available <= 0) continue;
      final takeQty = left < available ? left : available;
      _remaining[i] = available - takeQty;
      units += takeQty;
      value += takeQty * _lots[i].loadPriceKobo;
      cost += takeQty * _lots[i].unitCostKobo;
      if (!prices.contains(_lots[i].loadPriceKobo)) {
        prices.add(_lots[i].loadPriceKobo);
      }
      left -= takeQty;
    }
    if (left > 0 && _lots.isNotEmpty) {
      // More units left the trip than were ever loaded onto it — an oversell
      // the van's stock guard should have refused (spec §9.2 #7), or a sale
      // that arrived against a trip whose lots never synced. Value the
      // uncovered units at the newest lot's price so the figure is not silently
      // zero; the tie-out delta is what surfaces the anomaly.
      final last = _lots.last;
      units += left;
      value += left * last.loadPriceKobo;
      cost += left * last.unitCostKobo;
      if (!prices.contains(last.loadPriceKobo)) prices.add(last.loadPriceKobo);
    }
    return _Draw(units, value, cost, prices);
  }

  /// Everything the cursor still holds.
  _Draw takeRest() {
    var units = 0;
    for (final r in _remaining) {
      units += r;
    }
    return take(units);
  }
}
