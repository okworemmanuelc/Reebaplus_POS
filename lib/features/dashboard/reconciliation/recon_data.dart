import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:reebaplus_pos/core/crates/crate_deposit_ledger_types.dart';
import 'package:reebaplus_pos/core/crates/crate_deposit_position.dart';
import 'package:reebaplus_pos/core/crates/crate_shortage.dart';
import 'package:reebaplus_pos/core/crates/crate_shortfall.dart';
import 'package:reebaplus_pos/core/crates/crate_money_arrangement.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/online_orders/pay_on_delivery.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/vat_settings.dart';
import 'package:reebaplus_pos/core/stores/van_store.dart';
import 'package:reebaplus_pos/core/inventory_reasons.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/report_revenue.dart';

// Re-exports keep every existing `recon_data.dart` import working (#574).
export 'package:reebaplus_pos/core/inventory_reasons.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_inputs_adapter.dart';
export 'package:reebaplus_pos/features/dashboard/reconciliation/recon_inputs_adapter.dart';

part 'recon_day_close.dart';
part 'recon_loss_valuation.dart';

/// Shared aggregation engine for the Daily Reconciliation (§25.9).
///
/// The report is store-scoped (the §12.1 active-store picker) and groupable by
/// Day / Week / Month / Year. This file holds the date-bucket math and the
/// roll-up compute both the list and the detail screens read, so the money math
/// lives in exactly one place (the former separate Business Statement, §25.10,
/// was merged here on 2026-06-07).

// ── Grouping ─────────────────────────────────────────────────────────────────

enum ReconGrouping { day, week, month, year }

extension ReconGroupingX on ReconGrouping {
  String get label => switch (this) {
    ReconGrouping.day => 'Day',
    ReconGrouping.week => 'Week',
    ReconGrouping.month => 'Month',
    ReconGrouping.year => 'Year',
  };

  /// The next-finer grouping the drill-down descends into (null at Day, the leaf).
  ReconGrouping? get finer => switch (this) {
    ReconGrouping.year => ReconGrouping.month,
    ReconGrouping.month => ReconGrouping.week,
    ReconGrouping.week => ReconGrouping.day,
    ReconGrouping.day => null,
  };

  /// Inclusive start of the bucket [d] falls in. Weeks start Sunday (matches
  /// `date_period.dart` / §30.11).
  DateTime startOf(DateTime d) {
    final day = DateTime(d.year, d.month, d.day);
    switch (this) {
      case ReconGrouping.day:
        return day;
      case ReconGrouping.week:
        return day.subtract(Duration(days: day.weekday % 7)); // Sun=0…Sat=6
      case ReconGrouping.month:
        return DateTime(d.year, d.month, 1);
      case ReconGrouping.year:
        return DateTime(d.year, 1, 1);
    }
  }

  /// Exclusive end of a bucket that began at [start].
  DateTime endOf(DateTime start) {
    switch (this) {
      case ReconGrouping.day:
        return start.add(const Duration(days: 1));
      case ReconGrouping.week:
        return start.add(const Duration(days: 7));
      case ReconGrouping.month:
        return DateTime(start.year, start.month + 1, 1);
      case ReconGrouping.year:
        return DateTime(start.year + 1, 1, 1);
    }
  }

  /// Human label for the bucket beginning at [start].
  String labelFor(DateTime start) {
    switch (this) {
      case ReconGrouping.day:
        return DateFormat('EEE, d MMM yyyy').format(start);
      case ReconGrouping.week:
        final end = start.add(const Duration(days: 6));
        return 'Week of ${DateFormat('d MMM').format(start)} – '
            '${DateFormat('d MMM yyyy').format(end)}';
      case ReconGrouping.month:
        return DateFormat('MMMM yyyy').format(start);
      case ReconGrouping.year:
        return DateFormat('yyyy').format(start);
    }
  }
}

/// The DAY-CLOSE store predicate as a pure function of the van set — everything
/// in the business except the vans (#191, ADR 0022).
///
/// Factored out of [reconStoreFilter] so a caller that has no `WidgetRef` — the
/// day-review sweep behind [changedReviewedDaysProvider], which runs inside a
/// plain `Provider` — shares the ONE definition of "business-wide" instead of
/// re-deriving it. A second copy is exactly how the badge on the list and the
/// badge inside the day would come to disagree about which stores count.
bool Function(String?) businessWideStoreFilter(VanStores vans) =>
    (storeId) => !vans.isVan(storeId);

// ── Buckets (list cards + drill-down breakdown) ──────────────────────────────

class ReconBucket {
  ReconBucket({
    required this.start,
    required this.endExclusive,
    required this.grouping,
    required this.label,
    required this.itemsSold,
    required this.hasShortage,
  });

  final DateTime start;
  final DateTime endExclusive;
  final ReconGrouping grouping;
  final String label;
  final int itemsSold;
  final bool hasShortage;
}

class _BucketAccum {
  _BucketAccum(this.start, this.end);
  final DateTime start;
  final DateTime end;
  int itemsSold = 0;
  bool hasShortage = false;
}

/// Buckets (at [grouping]) that have data within `[start, endExclusive)` — one
/// per Day/Week/Month/Year that recorded sales or a stock count in the active
/// store scope, newest first. `start`/`end` null = unbounded (the top-level list).
List<ReconBucket> buildReconBuckets(
  WidgetRef ref, {
  DateTime? start,
  DateTime? endExclusive,
  required ReconGrouping grouping,
}) {
  final orders = ref.watch(allOrdersProvider).valueOrNull ?? const [];
  final counts = ref.watch(allStockCountsProvider).valueOrNull ?? const [];
  final inScope = reconStoreFilter(ref);
  bool inSpan(DateTime t) =>
      (start == null || !t.isBefore(start)) &&
      (endExclusive == null || t.isBefore(endExclusive));

  final byBucket = <int, _BucketAccum>{};
  _BucketAccum bucketOf(DateTime d) {
    final s = grouping.startOf(d);
    return byBucket.putIfAbsent(
      s.millisecondsSinceEpoch,
      () => _BucketAccum(s, grouping.endOf(s)),
    );
  }

  // #549 — a cancelled sale stays on its original day and its reversal is a
  // negative entry on the cancel day (see [saleDayEntries]).
  for (final e in saleDayEntries(orders)) {
    if (!inSpan(e.day)) continue;
    _BucketAccum? acc;
    for (final i in e.o.items) {
      if (!inScope(i.item.storeId)) continue;
      acc ??= bucketOf(e.day);
      acc.itemsSold += e.sign * i.item.quantity;
    }
  }

  // Collapse re-saved counts to the latest session per (store, date) so a
  // shortage corrected in a later count of the same day stops flagging.
  final sorted = [...counts]
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  final seen = <String>{};
  for (final c in sorted) {
    if (!inScope(c.storeId)) continue;
    final day = DateTime.tryParse(c.businessDate);
    if (day == null || !inSpan(day)) continue;
    if (!seen.add('${c.businessDate}|${c.storeId}')) continue;
    final acc = bucketOf(day);
    if (c.shortageUnits > 0) acc.hasShortage = true;
  }

  return byBucket.values
      .map(
        (a) => ReconBucket(
          start: a.start,
          endExclusive: a.end,
          grouping: grouping,
          label: grouping.labelFor(a.start),
          itemsSold: a.itemsSold,
          hasShortage: a.hasShortage,
        ),
      )
      .toList()
    ..sort((a, b) => b.start.compareTo(a.start));
}

// ── Full roll-up (detail screen) ─────────────────────────────────────────────

class ReconShortLine {
  ReconShortLine({
    required this.name,
    required this.system,
    required this.actual,
    required this.diff,
  });
  final String name;
  final int system;
  final int actual;
  final int diff;
}

/// The van channel's contribution to one period's closing report (#147,
/// van-sales spec §8.2, ADR 0019 decision 3).
///
/// Four figures and a caveat, all **additive**: nothing here changes an
/// existing line, because van orders are already excluded from every per-store
/// figure (#140/#142) and `van_remittance` lands in no existing payment bucket
/// (#144). This exists so the road channel stops being invisible, not so it can
/// be mixed back in.
///
/// **Every field is optional-defaulted on purpose.** When the crate pass (#207)
/// lands it adds `depositsHeldKobo` here and no call site changes — the same
/// additive shape `ReconData`'s own #176 fields use.
class ReconVanRollup {
  const ReconVanRollup({
    this.salesKobo = 0,
    this.remittedKobo = 0,
    this.cashRemittedKobo = 0,
    this.profitKobo = 0,
    this.cogsKobo = 0,
    this.openRevenueKobo = 0,
    this.openTripCount = 0,
    this.closedTripCount = 0,
  });

  /// **Van Sales (aggregated)** — the period's road revenue at load price,
  /// attributed through each trip's SOURCE WAREHOUSE. One line, no detail: the
  /// per-order story stays on the driver profile.
  final int salesKobo;

  /// Everything drivers handed in this period, any tender — the money that
  /// actually arrived. Counted on each payment row's own `created_at`, like
  /// every other line in the cash card.
  final int remittedKobo;

  /// The CASH-tender subset of [remittedKobo] — the "Cash from drivers" line,
  /// and the only part that belongs in a cash-MOVEMENT figure. A bank transfer
  /// is real money but it never touches the drawer.
  final int cashRemittedKobo;

  /// **Van profit (closed trips)** — `Σ profit_kobo` over the trips whose
  /// `closed_at` falls in the period, read straight off the persisted close
  /// artifact. **Never re-derived**: a trip's profit is a settlement outcome
  /// decided by a manager's write-off calls at a moment in time, and
  /// re-deriving it later would let a cost edit silently restate a settled trip
  /// (ADR 0019's rejected alternative #3).
  final int profitKobo;

  /// The same closed trips' `Σ cogs_kobo`, so the report can show what the
  /// profit is net of without a second read.
  final int cogsKobo;

  /// Road revenue in the period belonging to trips that have NOT closed —
  /// the caveat's figure. Revenue is recognised at the sale, profit at the
  /// close, so a trip open across a month boundary genuinely splits (spec
  /// §9.4 #18); the caveat is what stops that from looking like a mistake.
  final int openRevenueKobo;

  final int openTripCount;
  final int closedTripCount;

  /// True when anything van-related happened in the period — the card's render
  /// condition.
  bool get hasActivity =>
      salesKobo != 0 ||
      remittedKobo != 0 ||
      profitKobo != 0 ||
      openTripCount != 0 ||
      closedTripCount != 0;

  /// True when the report must print the open-trip caveat instead of implying
  /// the period's van profit is complete.
  bool get hasOpenTripCaveat => openRevenueKobo != 0;

  /// The caveat, verbatim (spec §5.4 / §8.2). Takes the app-wide money
  /// formatter so the sentence follows the CEO-chosen currency.
  String caveatLine(String Function(num) formatMoney) =>
      '${formatMoney(openRevenueKobo / 100)} van revenue awaiting trip close — '
      'profit not yet booked.';
}

class ReconData {
  ReconData({
    required this.totalRevenueKobo,
    required this.costedRevenueKobo,
    required this.cogsKobo,
    required this.discountsKobo,
    required this.vatEnabled,
    required this.vatRateBps,
    required this.vatKobo,
    required this.itemsSold,
    required this.skus,
    required this.uncostedItems,
    required this.refundsKobo,
    required this.cashSalesKobo,
    required this.cashDebtsCollectedKobo,
    required this.cashRefundsKobo,
    required this.cashExpensesKobo,
    required this.cashSupplierPaidKobo,
    required this.cashCrateDepositsKobo,
    // #215 — the supplier leg of the crate-deposit story. Both are
    // optional-defaulted like every other additive field, so the pure-getter
    // test harness and every existing construction site stay valid.
    this.cashCrateDepositsPlacedKobo = 0,
    this.crateDeposits = CrateDepositRollup.empty,
    // #216 — the warning, and the loss somebody accepted. Optional-defaulted
    // like every other additive field.
    this.crateShortages = CrateShortageRollup.empty,
    this.crateShortfallWrittenOffKobo = 0,
    this.crateForfeitNettedKobo = 0,
    required this.bestStaff,
    required this.bestStaffKobo,
    required this.expensesKobo,
    required this.expensesCount,
    required this.damageUnits,
    required this.damageCostKobo,
    required this.damageRetailKobo,
    required this.crateDamageDepositKobo,
    required this.hasStockCount,
    required this.productsCounted,
    required this.shortageCount,
    required this.shortageUnits,
    required this.surplusCount,
    required this.surplusUnits,
    required this.shortageCostKobo,
    required this.shortageRetailKobo,
    required this.shortages,
    required this.goodsReceivedKobo,
    required this.supplierPaidKobo,
    required this.totalOwedKobo,
    // #432 — report-only, optional-defaulted like the other additive fields.
    this.payOnDeliveryUncollectedKobo = 0,
    required this.showCrates,
    required this.crateUnits,
    required this.crateDepositKobo,
    required this.heldCrateDepositsKobo,
    required this.supplierCrateDebtKobo,
    required this.supplierPayableKobo,
    required this.inventoryOnHandKobo,
    // #170 #7b: dispatched-not-received stock value (optional, default 0 so the
    // pure-getter test harness stays source-compatible).
    this.inTransitValueKobo = 0,
    required this.uncostedInventoryItems,
    required this.surplusCostKobo,
    required this.stockOpeningKobo,
    required this.stockReceivedKobo,
    required this.stockCogsKobo,
    required this.stockDamagesKobo,
    required this.stockExpiredKobo,
    required this.stockOtherMovementsKobo,
    required this.stockExpectedClosingKobo,
    required this.topItems,
    required this.manufacturerEmpties,
    // #176 report-truth additions — all optional-defaulted (like
    // inTransitValueKobo) so the pure-getter test harness stays source-compatible.
    this.salesPaidNowKobo = 0,
    this.salesOnCreditKobo = 0,
    this.forfeitIncomeKobo = 0,
    this.uncostedTakingsKobo = 0,
    this.stockTransfersKobo = 0,
    this.stockCountAdjustmentsKobo = 0,
    this.stockDeletionsKobo = 0,
    // #200 / US 20 — the two legacy-valuation row counts that drive the
    // "valued at today's cost" footnotes. Optional-defaulted like the above.
    this.legacyValuedDamageRows = 0,
    this.legacyValuedShortageRows = 0,
    // #193 — the same write-off money as a positive P&L loss magnitude.
    this.deletionCostKobo = 0,
    this.vatBasis = VatBasis.inclusive,
    // #147 — the van channel's rollup. Optional-defaulted like the #170/#176
    // additions above, so every existing construction site stays valid.
    this.van = const ReconVanRollup(),
    // #195 — the headline Total Sales, resolved through `computeTotalSalesKobo`.
    // REQUIRED, unlike the additive fields above: the whole point of the issue
    // is that there is no second way to arrive at this figure, and an
    // optional-defaulted one would let a construction site quietly fall back to
    // the derivation the issue removed. See [totalSalesKobo].
    required this.totalSalesKobo,
  });

  final int totalRevenueKobo;
  final int costedRevenueKobo;
  final int cogsKobo;
  /// Period discounts given on counted sales (`orders.discountKobo`, summed in
  /// scope + span). `order_items.unitPriceKobo` is the GROSS list price, so the
  /// revenue sums above are gross of discount; this is subtracted in the P&L so
  /// profit isn't overstated by the discount given (the order's real payable is
  /// `netAmountKobo = gross − discount`). Contra-revenue, not an expense.
  final int discountsKobo;

  // ── VAT (opt-in, per-business — OFF by default) ──────────────────────────
  // Surfaced only when the business has enabled VAT in Settings (§10.1). Phase 1
  // reports the VAT **due on the period's net sales** (gross − discounts) at the
  // configured rate — it is a pass-through liability, NOT revenue or an expense,
  // so it does not enter the P&L profit math. Adding VAT to the cart/receipt at
  // checkout is a later slice; until then this is the obligation on recorded
  // sales, computed by [computeVatKobo].
  final bool vatEnabled;
  final int vatRateBps; // basis points (750 = 7.5%)
  final int vatKobo; // VAT due on net sales this period (0 when disabled)
  /// The basis the VAT figure was computed on (inclusive/exclusive, #176).
  /// Inclusive by default: most SME prices already include VAT, and the
  /// exclusive formula overstated the liability by (1+r).
  final VatBasis vatBasis;

  final int itemsSold;
  final int skus;
  final int uncostedItems;
  final int refundsKobo;
  // ── Cash-flow summary (ADR 0014, business-wide) ──────────────────────────
  // Derived cash MOVEMENT for the period from tender-tagged flows (`method ==
  // 'cash'`), NOT a drawer count (Hard Rule #8: no cash balance, no float, no
  // Close Day). `payment_transactions` is the unified physical-cash ledger and
  // has no storeId, so these are business-wide (like outstanding customer debt).
  final int cashSalesKobo; // IN — payment_transactions type 'sale'
  final int cashDebtsCollectedKobo; // IN — type 'wallet_topup' (debt paid in cash)
  final int cashRefundsKobo; // OUT — type 'refund'
  final int cashExpensesKobo; // OUT — type 'expense'
  final int cashSupplierPaidKobo; // OUT — supplier_ledger payment_* (not in pay-txns)
  /// HELD (not operating cash) — cash `crate_deposit` rows collected this period
  /// net of returns (#175). Refundable customer money the drawer physically
  /// holds but the business never earns, so it is shown as its own line and is
  /// deliberately OUTSIDE cashIn / cashOut / net cash movement (never banked as a
  /// sale). A cancelled deposit sale posts a negative `crate_deposit` row, so a
  /// same-period collect-then-cancel nets to zero here.
  final int cashCrateDepositsKobo;

  /// PLACED (not operating cash) — cash `crate_deposit_out` rows this period,
  /// net of releases (#215, ADR 0023 rule 1). The SUPPLIER-side mirror of
  /// [cashCrateDepositsKobo], and it gets the same treatment for the same
  /// reason: refundable money passing through the drawer that the business
  /// never spends, so it is shown on its own line and is deliberately OUTSIDE
  /// cashIn / cashOut / net cash movement.
  ///
  /// **Keeping it out of `cashOutKobo` is the decision, not an oversight.** The
  /// argument for putting it in ("the money really left the drawer") applies
  /// word for word to the customer leg above, which this codebase deliberately
  /// excludes anyway — treating the two legs differently would make the cash
  /// card incoherent, and #212 tried it and reverted. A Placed Deposit is an
  /// asset that changed shape (cash → money with the depot), never a cost, so
  /// it must never look like an expense and must never reduce profit.
  ///
  /// Signed like the ledger it comes from: POSITIVE when money went out to
  /// suppliers, NEGATIVE when more came back than went out this period. A
  /// same-period place-then-settle therefore nets to zero here, exactly as a
  /// collect-then-cancel does on the customer line.
  final int cashCrateDepositsPlacedKobo;

  /// #215 — what every supplier is holding of the owner's money right now, in
  /// total and by supplier, rolled up from [computeCrateDepositPosition].
  ///
  /// Point-in-time and **business-wide even under a locked store**: supplier
  /// crate money is a company obligation (the depot invoices the business, not
  /// the branch), and splitting it per store would repeat the defect
  /// `CRATE_TRACKING_AUDIT` C4 names. [CrateDepositRollup.empty] for a
  /// non-crate business and for every business whose brands are all on the
  /// default `none` arrangement.
  final CrateDepositRollup crateDeposits;

  /// **The asset.** [CrateDepositRollup.placedDepositKobo], hoisted so
  /// [businessNetPositionKobo] and the CSV read one name.
  int get placedCrateDepositsKobo => crateDeposits.placedDepositKobo;

  /// #296 — **the warning**: crates found missing at a count, per brand, not
  /// yet written off (PRD #284 decision 7). The same per-brand read the
  /// manufacturer screen shows, in the same store scope.
  ///
  /// Point-in-time. It is a suspicion, not a loss, so **it appears in no total
  /// on this object** — not profit, not worth, not cash. A later count finding
  /// the crates shrinks it; a write-off moves it into [crateShortfallWrittenOffKobo].
  final CrateShortageRollup crateShortages;

  /// #216 — **the loss somebody accepted**, in this period (ADR 0023 rule 5).
  ///
  /// The write-off decisions dated inside `[start, endExclusive)`, each valued
  /// at the rate snapshotted when it was taken. This is the ONE figure PRD #203
  /// puts into profit: everything else it books is a refundable Placed Deposit,
  /// an asset that changed shape and can never be a cost. A write-off is the
  /// opposite — the moment an owner says the crates are not coming back — so it
  /// is a realized loss and sits with [crateDamageDepositKobo] and
  /// [deletionCostKobo] in [netProfitKobo] and [periodNetResultKobo].
  ///
  /// **Dated by decision, not by discovery.** A shortfall that opened in March
  /// and was accepted in July reduces JULY's profit. That is the whole reason
  /// the decision is persisted rather than re-derived (ADR 0019's reasoning,
  /// ADR 0021's no-restatement rule): a later count must never move a loss
  /// somebody has already taken responsibility for.
  ///
  /// Older `manual` and `customer_forfeit` rows count only on a brand that
  /// moves money. `count_shortage` rows (#296) count for every brand, net of
  /// reversals, which book a gain on the day they are taken — so this can be
  /// negative in a period that only reversed.
  final int crateShortfallWrittenOffKobo;

  /// #217 — **the part of [crateShortfallWrittenOffKobo] a customer forfeit
  /// raised**, in this period (ADR 0023 finding #4).
  ///
  /// A kept crate deposit is income (#176). But on a brand where a deposit was
  /// genuinely placed with a depot, the crate the customer kept is one the
  /// business can never hand back, and it was charged at the SAME rate the
  /// depot holds — so the gain and the loss are the same size and the pair nets
  /// to **zero**. This is that loss, and [forfeitIncomeKobo] is the gain it
  /// cancels.
  ///
  /// **A DISCLOSURE FIGURE, NOT A DEDUCTION.** It is already counted inside
  /// [crateShortfallWrittenOffKobo] and must never be subtracted a second time.
  /// It exists so the reconciliation can tell an owner, in plain words, why a
  /// deposit they kept stopped showing up as profit — because a correct figure
  /// nobody can account for is exactly how a correct figure gets reported as a
  /// bug.
  ///
  /// **Forward only.** A forfeit settled before a brand was switched on has no
  /// netting row and never grows one, so this figure reads 0 for every closed
  /// day that predates the switch-on. A report spanning that date shows both
  /// treatments — pure income before, netted after — and that is by design
  /// (ADR 0021: a setting flipped today never rewrites a day already closed).
  ///
  /// 0 for every `none` brand: no deposit was ever placed for those crates, so
  /// keeping the customer's money is a real gain and stays pure income.
  final int crateForfeitNettedKobo;

  final String? bestStaff;
  final int bestStaffKobo;
  final int expensesKobo;
  final int expensesCount;
  final int damageUnits;
  final int damageCostKobo;
  final int damageRetailKobo;
  /// §17.2 crate-aware: refundable crate deposit forfeited by damages flagged
  /// "crate lost with item" / "stored empty damaged", valued at the
  /// per-manufacturer deposit rate. A realized loss, separate from the bottle's
  /// own cost (`damageCostKobo`).
  final int crateDamageDepositKobo;
  // ── Physical stock count (#186: ONE basis for every figure here) ──────────
  // All of these come from the count SESSIONS that won their day: the latest
  // `stock_counts` row per `businessDate|storeId`, bucketed on `businessDate`.
  // A day counted twice reports its LATEST count and nothing else, in units and
  // in money alike — so a recount that comes out matching reads zero variance
  // instead of flagging the earlier count's money as unexplained.
  final bool hasStockCount;
  final int productsCounted;
  final int shortageCount;
  final int shortageUnits;
  final int surplusCount;
  final int surplusUnits;

  /// The winning sessions' shortage at the write-time FIFO cost (#182), summed
  /// per session by [countSessionShortage] from the `stock_adjustments` rows
  /// that session wrote ([countShortageRowsBySession]).
  ///
  /// Two things are true at once and both matter. The money is **frozen**: it is
  /// what the units cost when they went missing, so editing a buying price today
  /// cannot restate last month's variance (the exception is disclosed by
  /// [legacyValuedShortageRows]). And the money is **session-based**: it counts
  /// only the count each day ended on, exactly like [shortageUnits] beside it
  /// (#186). Cumulative shrinkage across every save of a day lives on the stock
  /// card's [stockCountAdjustmentsKobo] line instead.
  final int shortageCostKobo;

  final int shortageRetailKobo;
  final List<ReconShortLine> shortages;
  final int goodsReceivedKobo;
  final int supplierPaidKobo;
  final int totalOwedKobo;

  /// #432 — "Pay on delivery not yet collected": what live Pay on delivery
  /// orders still have to collect, business-wide and point-in-time like
  /// [totalOwedKobo]. REPORT-ONLY: it is already inside the customer debt
  /// above, so it enters no total, no net position and no cash figure (Hard
  /// Rule #8 — there is no cash balance to explain).
  final int payOnDeliveryUncollectedKobo;
  final bool showCrates;
  final int crateUnits;
  final int crateDepositKobo;

  /// §13.4 / #163 — crate-deposit money the business is still HOLDING for
  /// customers: the `crate_deposit` wallet family net (taken − refunded −
  /// forfeited), business-wide. A liability the net position nets out — it is
  /// owed back the moment a customer returns their crates, so counting the
  /// physical empties as an asset without subtracting it overstates worth. 0 for
  /// a non-crate business (no deposit-family rows exist).
  final int heldCrateDepositsKobo;

  /// #163 — crate debt the business owes SUPPLIERS for the full crates they
  /// delivered, valued at the current per-manufacturer deposit rate (derived
  /// `SUM(quantity_delta × depositAmountKobo)` over `supplier_crate_ledger`). A
  /// liability the net position nets out — the crate-side analogue of the
  /// money-side [supplierPayableKobo]. 0 for a non-crate business.
  final int supplierCrateDebtKobo;

  final int supplierPayableKobo;
  final int inventoryOnHandKobo;

  /// #170 #7b: value of stock dispatched between stores but not yet received
  /// (in_transit transfers, at the cost that rode each transfer). An asset that
  /// used to vanish between dispatch and receipt — now counted in Business worth.
  final int inTransitValueKobo;
  final int uncostedInventoryItems;
  final int surplusCostKobo;

  // ── Stock flow-equation card (ADR 0014, at current cost) ─────────────────
  // Opening@cost + Goods received − COGS − Damages − Expired (± Other) =
  // Expected closing (the perpetual SYSTEM figure), then Variance = Physical
  // count − Expected. Reconstructed from the `stock_transactions` ledger by
  // rewinding recorded deltas from the current on-hand figure, so the equation
  // ties out by construction (see [computeReconData]). Every term is valued at
  // the product's CURRENT buying price — cost is time-varying under FIFO (ADR
  // 0005) and only current stock is valued today, so this states a current-cost
  // basis rather than pretending to historical-cost precision. CEO-only (§25.3).
  final int stockOpeningKobo; // system stock at period start × current cost
  final int stockReceivedKobo; // goods received in period × current cost
  final int stockCogsKobo; // units sold in period × current cost
  final int stockDamagesKobo; // non-expired damages in period × current cost
  final int stockExpiredKobo; // expired removals in period × current cost
  /// Signed residual: transfers, count reconciliations, and any adjustment not
  /// classified as a sale / receipt / damage / expiry. Keeps the flow equation
  /// tying to the system figure without silently folding these into opening.
  final int stockOtherMovementsKobo;
  final int stockExpectedClosingKobo; // system stock at period end × current cost

  // ── #176 report-truth additions ──────────────────────────────────────────
  /// The goods portion of Total Sales actually paid at checkout this period
  /// (amountPaid − deposit, capped at the order's goods net). Split from
  /// [salesOnCreditKobo] on the sales card so a Manager stops over-expecting the
  /// drawer by the credit amount (PRD #155 story 29). `salesPaidNow +
  /// salesOnCredit == totalSalesKobo` by construction.
  final int salesPaidNowKobo;

  /// The goods portion of Total Sales left UNPAID this period (booked as customer
  /// debt) — the credit the drawer will never see today. See [salesPaidNowKobo].
  final int salesOnCreditKobo;

  /// Forfeit income (#176 / PRD #155 story 7): crate deposits the business kept
  /// this period because the customer never returned the crates — money
  /// legitimately earned. Summed from `crate_deposit_forfeited` wallet rows on
  /// their own `created_at` day, business-wide (wallet rows have no store),
  /// gated on [showCrates]. Added to [netProfitKobo] — previously invisible in
  /// the P&L while crate LOSSES were subtracted.
  ///
  /// **#217 does not touch this figure, deliberately.** A kept deposit really
  /// was kept, on every brand, and hiding it would lose the fact that the money
  /// came in. What #217 adds is the OTHER half on an opted-in brand — the crate
  /// that will never go back to the depot, booked as
  /// [crateForfeitNettedKobo] — so the pair nets to zero rather than the income
  /// disappearing. On a `none` brand there is no other half and this stays pure
  /// gain, which is the release gate.
  final int forfeitIncomeKobo;

  /// Quick-sale (Uncosted) takings included in the profit picture (#176 / PRD
  /// #155 story 27): revenue on lines with no recorded buying price
  /// (`totalRevenueKobo − costedRevenueKobo`). Added to [netProfitKobo] as pure
  /// margin (no COGS is recorded for them — the transparency footnote counts the
  /// items) so money in the drawer is never missing from the result. It does NOT
  /// enter [grossProfitKobo]/[grossMarginPct] (those stay costed-only so the
  /// margin reads true).
  final int uncostedTakingsKobo;

  // Stock card "Other movements" broken out by cause (#176 / PRD #155 story 30)
  // so an unlabeled residual can't hide a loss. Each is the signed value (at
  // current cost) of that movement class within the period; together with the
  // true residual [stockOtherMovementsKobo] they partition what used to be one
  // "Other movements" line, and still fold into [stockDerivedClosingKobo].
  final int stockTransfersKobo; // transfer_in / transfer_out legs

  /// Daily-count reconciliation adjustments, at CURRENT cost and over **every**
  /// row in the period — deliberately a different basis from the P&L's
  /// [shortageCostKobo], which #182 moved onto the #170 write-time snapshot and
  /// #186 moved onto the winning count session. #200 asked whether this line
  /// should follow it. It must not, on its own, for three reasons in ascending
  /// weight:
  ///
  ///  1. This term is built from **void-filtered** `stock_transactions`, while
  ///     the snapshot lives on `stock_adjustments`, which has **no void column**.
  ///     Reaching across would need the void filter carried over by hand (the
  ///     adjustment id is already joined for the reason, so it is *possible*) —
  ///     get it wrong and a VOIDED count correction contributes money with no
  ///     matching units. That money-vs-units divergence is #186's subject.
  ///  2. [stockDamagesKobo] has the identical property, so converting only this
  ///     line would put two bases inside ONE card.
  ///  3. Decisive: the flow equation ties to the perpetual system figure **by
  ///     construction** only while every term shares one basis (opening is the
  ///     rewind of the period's deltas — see [stockDerivedClosingKobo]). Swap one
  ///     term and the rendered column stops adding up to Expected closing, which
  ///     is a worse report failure than the one being fixed.
  ///
  /// So the card keeps one basis and now SAYS so, on screen and in the export:
  /// one event reports two labelled figures instead of two silent ones.
  ///
  /// **#186 settled this and left the line exactly where it stands.** It moved
  /// the *variance card's* shortage onto the count session so the money and the
  /// units there stop contradicting each other; this term stayed all-rows at
  /// current cost, and its three reasons above still hold word for word. That is
  /// not an oversight — it is the useful half of what the old shortage basis was
  /// doing: this line is the CUMULATIVE view (every save of every day, whatever
  /// a later recount concluded), and after #186 it is the only place that view
  /// survives. Deleting it would take a day's total shrinkage with it.
  final int stockCountAdjustmentsKobo;

  final int stockDeletionsKobo; // product-delete write-offs (#170 #7c)

  // ── #200 / PRD #155 US 20: label the current-cost fallback ────────────────
  // #170 froze every new loss at the cost it actually drew, so a later
  // buying-price edit can't restate it. Rows written BEFORE #170 recorded only a
  // quantity, so they still fall back to today's cost ([lossValueKobo]) — the
  // one case where a past loss figure is NOT frozen. That was documented in
  // dartdoc only; these counts put it on the report, where the person reading
  // the money can see it.
  /// Rows inside [damageCostKobo] valued at today's cost (no write-time
  /// snapshot). 0 = the whole Damages figure is frozen.
  final int legacyValuedDamageRows;

  /// Rows inside [shortageCostKobo] valued at today's cost (no write-time
  /// snapshot). 0 = the whole shortage/variance figure is frozen.
  ///
  /// Counted per winning session (#186), so it describes exactly the rows the
  /// money summed — including the case where a session had no attributable rows
  /// at all and its own count lines were valued at current cost instead
  /// ([countSessionShortage]). A footnote that outlived, or undercounted, the
  /// figure it annotates would be worse than no footnote.
  final int legacyValuedShortageRows;

  /// The product-delete write-off booked as a period LOSS (#193) — the cost of
  /// stock still on the shelf when a product was deleted, valued at the FIFO
  /// snapshot the write-off recorded ([productDeleteLossKobo]).
  ///
  /// A POSITIVE magnitude, exactly like [damageCostKobo] and [shortageCostKobo],
  /// so [netProfitKobo] and [periodNetResultKobo] subtract it as one more loss
  /// line in the same family. Deleting a product with stock on it destroys real
  /// value the business paid for, so it counts against the period result rather
  /// than being listed for information only.
  ///
  /// **Not the same figure as [stockDeletionsKobo]**, and deliberately so — the
  /// pair mirrors [damageCostKobo] (P&L, write-time snapshot) vs
  /// [stockDamagesKobo] (stock card, current cost). ADR 0014 pins the stock card
  /// to current cost "on purpose" so its closing identity ties to the rewound
  /// perpetual figure, while its 2026-07-25 addendum puts every *loss* surface on
  /// the snapshot. One consequence is disclosed rather than hidden: because a
  /// deleted product is filtered out of every current-cost lookup, the stock
  /// card's own Product-deletions term still reads ₦0 (it is "uncosted" by that
  /// card's rule) even though this figure — the one that reaches the P&L, the net
  /// result and the frozen day close — carries the full value.
  final int deletionCostKobo;

  /// The van channel's four report lines (#147). Purely additive — see
  /// [ReconVanRollup].
  final ReconVanRollup van;

  final List<({String name, int qty})> topItems;
  final List<({String manufacturerName, int count, int valueKobo})> manufacturerEmpties;

  /// The configured VAT rate as a display percentage ("7.5"), for card labels.
  String get vatRateLabel =>
      VatConfig(enabled: vatEnabled, rateBps: vatRateBps).ratePercentLabel;

  /// The active VAT basis label ("inclusive"/"exclusive"), for card labels.
  String get vatBasisLabel =>
      vatBasis == VatBasis.inclusive ? 'inclusive' : 'exclusive';

  /// The single headline **Total Sales** for the period (#176 / PRD #155 story
  /// 28): item-line gross MINUS discounts, deposit-exclusive. The Home
  /// dashboard, the Daily Reconciliation and the Profit report report the SAME
  /// number for a day because all three resolve it through the ONE helper
  /// [computeTotalSalesKobo] — [reconDataFrom] calls it and hands the result in
  /// here (#195). It used to be a getter deriving the figure from this file's
  /// own sales loop as `totalRevenueKobo − discountsKobo`, which was equal only
  /// "by construction" with nothing enforcing it. `totalRevenueKobo` stays the
  /// gross intermediate the P&L card keeps beside its discount line, and
  /// `test/dashboard/report_revenue_test.dart` pins the two against each other
  /// on the real compute path.
  final int totalSalesKobo;

  /// Costed revenue net of discounts given — the real money earned on costed
  /// lines. `costedRevenueKobo` is gross (Σ qty × gross unitPrice), so we
  /// subtract the period's discounts to get what was actually charged.
  int get netRevenueKobo => costedRevenueKobo - discountsKobo;
  int get grossProfitKobo => netRevenueKobo - cogsKobo;

  /// Net profit for the period. Starts from the costed [grossProfitKobo], then
  /// ADDS the two earnings the audit found invisible — quick-sale
  /// [uncostedTakingsKobo] (money in the drawer with no recorded cost, PRD #155
  /// story 27) and [forfeitIncomeKobo] (kept crate deposits, story 7) — before
  /// netting out expenses and losses. Quick-sale takings are excluded from COGS
  /// (none is recorded) and from gross margin, per the transparency footnote.
  ///
  /// [deletionCostKobo] joins Damages as a loss line (#193): stock written off
  /// because its product was deleted is value the business paid for and no longer
  /// has, so it belongs in the result and not merely in a stock-card note.
  /// **#217 — and this is where a forfeit stops being reported as a gain it
  /// isn't.** [forfeitIncomeKobo] still adds the deposit the business kept, but
  /// on an opted-in brand [crateShortfallWrittenOffKobo] now also carries the
  /// crate that will never go back to the depot, at the same rate. The two are
  /// the same size, so the pair contributes ZERO. On a `none` brand no netting
  /// row exists and the income stands alone, exactly as before.
  ///
  /// [crateShortfallWrittenOffKobo] joins them (#216): crates the owner has
  /// deliberately accepted as lost are deposit value the business will not get
  /// back, and the day they said so is the day it costs them. It is the only
  /// crate-money figure in PRD #203 that may touch this line — a Placed Deposit
  /// is refundable and can never reduce profit — and it enters only on the
  /// owner's decision, never on a timer.
  int get netProfitKobo =>
      grossProfitKobo +
      uncostedTakingsKobo +
      forfeitIncomeKobo -
      expensesKobo -
      damageCostKobo -
      crateDamageDepositKobo -
      crateShortfallWrittenOffKobo -
      deletionCostKobo;

  // ── Cash-flow summary getters (ADR 0014) ─────────────────────────────────
  /// **Cash from drivers** (#147, spec §8.2) — the period's cash-tender
  /// `van_remittance` rows, on the day the money arrived.
  ///
  /// It is IN [cashInKobo] and it is a separate line from "Cash sales", and
  /// both facts matter. A road sale writes no payment row at all (ADR 0019
  /// decision 2), so this is the one moment van money enters the cash books —
  /// leaving it out would understate the drawer by every naira a driver handed
  /// in, which is the failure the whole decision exists to fix. Folding it INTO
  /// "Cash sales" would be the opposite failure: it would double-count road
  /// revenue that was already recognised when the driver rang it. It behaves
  /// exactly like [cashDebtsCollectedKobo] — a debt settled in cash, not a new
  /// sale.
  int get cashFromDriversKobo => van.cashRemittedKobo;

  int get cashInKobo =>
      cashSalesKobo + cashDebtsCollectedKobo + cashFromDriversKobo;
  int get cashOutKobo =>
      cashRefundsKobo + cashExpensesKobo + cashSupplierPaidKobo;
  /// Expected net cash movement for the period (in − out). Not a cash balance —
  /// there is no opening float to add it to (Hard Rule #8).
  int get netCashMovementKobo => cashInKobo - cashOutKobo;
  bool get hasCashActivity => cashInKobo != 0 || cashOutKobo != 0;

  // ── Stock flow-equation getters (ADR 0014) ───────────────────────────────
  /// Expected closing rebuilt from the flow lines the card renders. Equal to
  /// [stockExpectedClosingKobo] by construction (opening is the rewind of the
  /// period's deltas from the system closing), so displaying both proves the
  /// equation ties out.
  int get stockDerivedClosingKobo =>
      stockOpeningKobo +
      stockReceivedKobo -
      stockCogsKobo -
      stockDamagesKobo -
      stockExpiredKobo +
      // #176 — the former single "Other movements" residual, now partitioned by
      // cause (transfers / count corrections / product deletions) plus whatever
      // remains truly unclassified. Their sum equals the old residual, so the
      // equation still ties to the perpetual system figure by construction.
      stockTransfersKobo +
      stockCountAdjustmentsKobo +
      stockDeletionsKobo +
      stockOtherMovementsKobo;

  /// Variance = Physical count − Expected closing: a surplus (physical over
  /// system) is positive, a shortage negative. This is the count discrepancy the
  /// recorded flows did NOT explain — the independent signal the closing report
  /// surfaces. Meaningful only when a physical count exists in the period
  /// ([hasStockCount]).
  ///
  /// **Both halves are the winning count sessions' (#186)**, which is what makes
  /// the subtraction mean anything: a day whose latest count matched contributes
  /// 0 to each side, so a corrected day reads zero variance and raises no
  /// integrity flag rather than flagging money an earlier count already
  /// superseded. The surplus half is at current cost because a gain draws no
  /// FIFO batch and so has no snapshot to read; the shortage half is at the cost
  /// each loss actually drew (#182).
  int get stockVarianceKobo => surplusCostKobo - shortageCostKobo;

  // ── Integrity flag (ADR 0014 slice 3) ────────────────────────────────────
  // Reconciles reported P&L profit against the independent physical stock
  // count, deriving the gap entirely from recorded flows + the count — no new
  // persistence. A true "Δ net position = profit" identity can't close (no cash
  // leg under Hard Rule #8, no stored period-start snapshot), so the flag
  // instead surfaces the one thing the flows did NOT record: the stock-count
  // variance. Reported profit is built only from sales / COGS / discounts /
  // expenses / damages, so a count shortfall is a RECORDING error (unbooked
  // shrinkage / theft / miscount) the profit figure never reflected — not a
  // separate real loss.

  /// Reported net profit reconciled against the physical count: P&L profit plus
  /// the stock-count variance the flows never booked. Equals [netProfitKobo]
  /// when the count matches the flows (a surplus lifts it, a shortage cuts it).
  int get integrityAdjustedProfitKobo => netProfitKobo + stockVarianceKobo;

  /// True when a physical count was taken and it does not match the recorded
  /// flows — an unexplained gap worth flagging. Without a count there is nothing
  /// independent to reconcile against, so this is false.
  bool get hasIntegrityGap => hasStockCount && stockVarianceKobo != 0;

  /// Whether any stock movement or on-hand value exists to render the card.
  bool get hasStockFlow =>
      stockOpeningKobo != 0 ||
      stockExpectedClosingKobo != 0 ||
      stockReceivedKobo != 0 ||
      stockCogsKobo != 0 ||
      stockDamagesKobo != 0 ||
      stockExpiredKobo != 0 ||
      stockTransfersKobo != 0 ||
      stockCountAdjustmentsKobo != 0 ||
      stockDeletionsKobo != 0 ||
      stockOtherMovementsKobo != 0;

  /// Net result for the period (flow). Folds the inventory-on-hand asset and the
  /// supplier flows (goods received / paid to suppliers / refunds) that used to
  /// sit in the separate "Business worth" and "Other context flows" cards into a
  /// single roll-up, then nets out the period's expenses and losses. The
  /// _netResultCard renders this exact breakdown line-for-line.
  int get periodNetResultKobo =>
      inventoryOnHandKobo +
      goodsReceivedKobo -
      supplierPaidKobo -
      refundsKobo -
      expensesKobo -
      damageCostKobo -
      crateDamageDepositKobo -
      // #216 — an accepted crate loss is realized, on the day it was accepted.
      crateShortfallWrittenOffKobo -
      // #193 — deleted-product write-offs sit with Damages and Shortages as a
      // realized loss, not as an unbooked stock-card footnote.
      deletionCostKobo -
      shortageCostKobo;
  /// Point-in-time net worth, honest about crate liabilities (#163) and
  /// in-transit stock (#170 #7b). ASSETS: inventory at cost, stock dispatched
  /// between stores but not yet received ([inTransitValueKobo] — value that used
  /// to vanish between dispatch and receipt), the empty crates we physically
  /// hold ([crateDepositKobo], valued at deposit), and money customers owe us.
  /// LIABILITIES netted out: what we owe suppliers for goods
  /// ([supplierPayableKobo]), the crate deposits we still hold for customers
  /// ([heldCrateDepositsKobo] — owed back on return), and the crate debt we owe
  /// suppliers ([supplierCrateDebtKobo]). Booking the crate asset while ignoring
  /// the matching deposit/supplier liabilities overstated worth; both legs are
  /// now subtracted.
  ///
  /// **#215 adds the Placed Deposit as an ASSET** ([placedCrateDepositsKobo]):
  /// money paid to a supplier for their crates is still the owner's — it is
  /// refundable, merely held elsewhere (ADR 0023 rule 1). Before this slice it
  /// left the drawer and vanished from worth entirely, while
  /// [supplierCrateDebtKobo] drifted NEGATIVE for want of a receipt leg and
  /// *inflated* worth from the other side (ADR 0023 finding #2). #210 fixed the
  /// drift at source by posting the receipt leg on Receive Stock; this line
  /// books the money that answers it. For a brand backed since its first
  /// delivery the two now roughly cancel, which is what "worth is unchanged
  /// when you place a deposit" means arithmetically.
  ///
  /// The historically-negative balances live tenants already carry are NOT
  /// clamped here. ADR 0023's Consequences say so explicitly — clamping would
  /// restate a figure every `none` business reads today, breaking PRD #203's
  /// release gate to paper over a drift #210 has already stopped.
  int get businessNetPositionKobo =>
      inventoryOnHandKobo +
      inTransitValueKobo +
      totalOwedKobo +
      crateDepositKobo +
      placedCrateDepositsKobo -
      supplierPayableKobo -
      heldCrateDepositsKobo -
      supplierCrateDebtKobo;

  /// Supplier account position (§21): all payments made to suppliers minus all
  /// goods received, point-in-time. The inverse of [supplierPayableKobo] and
  /// identical to `SupplierLedgerDao.getBalanceKobo` (SUM of signed entries).
  ///   • positive (green) → money we paid the supplier IN ADVANCE (a
  ///     prepayment) — NOT money we hold on their behalf;
  ///   • negative (red)   → a debt WE owe the supplier for unpaid goods.
  /// Display this signed value — never relabel an advance payment as "owed".
  int get supplierAccountBalanceKobo => -supplierPayableKobo;

  /// Gross margin as a 1-dp percentage string ("0.0" when there's no net
  /// revenue). Measured against net revenue (after discounts), so the margin
  /// reflects money actually earned. Shared by the P&L card and the CSV export.
  String get grossMarginPct => netRevenueKobo > 0
      ? (grossProfitKobo / netRevenueKobo * 100).toStringAsFixed(1)
      : '0.0';

  bool get isEmpty =>
      totalRevenueKobo == 0 &&
      expensesKobo == 0 &&
      damageUnits == 0 &&
      shortageUnits == 0 &&
      !hasStockCount &&
      goodsReceivedKobo == 0 &&
      supplierPaidKobo == 0 &&
      refundsKobo == 0 &&
      totalOwedKobo == 0 &&
      crateUnits == 0;
}

/// Everything one reconciliation roll-up READS — the row sets, the settings,
/// the period span and the store predicate — gathered into one value so the
/// money math itself ([reconDataFrom]) is a **pure function of its inputs**
/// (#195).
///
/// Before this split, [computeReconData] could only run inside a widget holding
/// a live `WidgetRef`, so the one figure three screens must agree on
/// (`totalSalesKobo`) had no test that could catch it drifting — the #176
/// acceptance test had to fabricate a `ReconData` from figures it computed
/// itself. Now a test constructs [ReconInputs] and calls [reconDataFrom].
///
/// Every field is optional-defaulted (empty / off / any-store), exactly like
/// [ReconData]'s own additive fields, so a test supplies only the rows the
/// figure under test depends on and every existing call site stays valid when a
/// later slice adds an input.
class ReconInputs {
  const ReconInputs({
    this.orders = const [],
    this.expenses = const [],
    this.adjustments = const [],
    this.supplierLedger = const [],
    this.payments = const [],
    this.stockTxns = const [],
    this.stockCounts = const [],
    this.productsWithStock = const [],
    this.creditBalancesKobo = const {},
    this.manufacturers = const [],
    this.emptyCrateCounts = const {},
    this.crateDamages = const [],
    this.usersById = const {},
    this.inTransitTransfers = const [],
    this.vanTrips = const [],
    this.crateForfeitRows = const [],
    this.vat = VatConfig.off,
    this.showCrates = false,
    this.heldCrateDepositsKobo = 0,
    this.supplierCrateDebtKobo = 0,
    this.crateDeposits = CrateDepositRollup.empty,
    this.crateShortages = CrateShortageRollup.empty,
    this.crateShortfallWriteOffs = const [],
    this.payOnDelivery = const [],
    this.isCeo = false,
    this.inScope = _everyStore,
    this.start,
    this.endExclusive,
  });

  final List<OrderWithItems> orders;
  final List<ExpenseWithCategory> expenses;
  final List<StockAdjustmentData> adjustments;
  final List<SupplierLedgerEntryData> supplierLedger;
  final List<PaymentTransactionData> payments;
  final List<StockTransactionData> stockTxns;
  final List<StockCountData> stockCounts;

  /// Products with their stock totals **already scoped** to the compute's store
  /// basis (the locked store, or unscoped for a business-wide compute).
  final List<ProductDataWithStock> productsWithStock;

  final Map<String, int> creditBalancesKobo;
  final List<ManufacturerData> manufacturers;
  final Map<String, int> emptyCrateCounts;

  /// §17.2 crate-aware: `damaged` crate_ledger rows — the stored-empty fate, a
  /// crate-only loss that writes no stock_adjustment.
  final List<CrateLedgerData> crateDamages;

  final Map<String, UserData> usersById;
  final List<StockTransferData> inTransitTransfers;
  final List<VanTripData> vanTrips;

  /// Non-voided `crate_deposit_forfeited` wallet rows — the forfeit-income
  /// source (#176). Empty for a non-crate business.
  final List<WalletTransactionData> crateForfeitRows;

  final VatConfig vat;

  /// Whether this business tracks empty crates at all — gates every crate
  /// figure below.
  final bool showCrates;

  /// Point-in-time crate liabilities, already derived by their own ledger
  /// providers (business-wide, so there is nothing left to scope or sum here).
  final int heldCrateDepositsKobo;
  final int supplierCrateDebtKobo;

  /// #215 — the business-wide Placed Deposit roll-up, already computed through
  /// [computeCrateDepositPosition] by its own provider. Business-wide by
  /// decision, not by convenience: supplier crate money is a company
  /// obligation, so it is not scoped by [inScope] here or anywhere else.
  final CrateDepositRollup crateDeposits;

  /// #296 — the count-based Crate Shortage per brand, already folded by its
  /// own provider in the compute's store scope. Handed in whole.
  final CrateShortageRollup crateShortages;

  /// #216 — every Crate Shortfall write-off decision, UNWINDOWED. The period
  /// filter is applied by [crateShortfallWriteOffKobo] inside [reconDataFrom],
  /// like every other row set here, so the "booked on the day it was taken"
  /// rule is exercised by the pure math rather than by a query.
  final List<CrateShortfallWriteoffData> crateShortfallWriteOffs;

  /// #432 — every Pay on delivery order with what it has collected
  /// (point-in-time, business-wide). Feeds the report-only line only.
  final List<PayOnDeliveryOrder> payOnDelivery;

  /// Gates the supplier-ledger flows only; every other figure is computed
  /// either way and the screen decides what to show per the cost wall.
  final bool isCeo;

  /// The store predicate every figure is filtered through — [reconStoreFilter]
  /// in production. Defaults to every store so a test need not build one.
  final bool Function(String? storeId) inScope;

  final DateTime? start;
  final DateTime? endExclusive;

  /// Whether [t] falls in the half-open period `[start, endExclusive)`. Null
  /// ends are unbounded (the all-time roll-up).
  bool inSpan(DateTime t) =>
      (start == null || !t.isBefore(start!)) &&
      (endExclusive == null || t.isBefore(endExclusive!));
}

bool _everyStore(String? _) => true;

/// The reconciliation roll-up itself — **pure** over [ReconInputs] (#195), so
/// every figure it derives can be pinned by a unit test with no widget, no
/// database and no `WidgetRef`. [computeReconData] is the provider-reading
/// wrapper.
/// The engine entry point (#574): pure over [ReconInputs]. Alias of
/// [reconDataFrom], which stays so existing callers and tests don't churn.
ReconData reconcile(ReconInputs inputs) => reconDataFrom(inputs);

ReconData reconDataFrom(ReconInputs input) {
  final orders = input.orders;
  final expenses = input.expenses;
  final adjustments = input.adjustments;
  final ledger = input.supplierLedger;
  final payments = input.payments;
  final stockTxns = input.stockTxns;
  final counts = input.stockCounts;
  final productsWS = input.productsWithStock;
  final balances = input.creditBalancesKobo;
  final manufacturers = input.manufacturers;
  final crateCounts = input.emptyCrateCounts;
  final crateDamages = input.crateDamages;
  final users = input.usersById;
  final vat = input.vat;
  final isCeo = input.isCeo;
  final endExclusive = input.endExclusive;

  final productById = {for (final p in productsWS) p.product.id: p.product};
  final inScope = input.inScope;
  bool inSpan(DateTime t) => input.inSpan(t);

  // ── Sales / P&L (mirrors the Profit Report's costed-line model) ──────────
  var totalRevenueKobo = 0;
  var costedRevenueKobo = 0;
  var cogsKobo = 0;
  var discountsKobo = 0;
  var itemsSold = 0;
  var uncostedItems = 0;
  // #176 — split Total Sales into the goods actually paid now vs left on credit,
  // so the sales card stops over-expecting the drawer by the credit amount.
  var salesPaidNowKobo = 0;
  var salesOnCreditKobo = 0;
  final skuSet = <String>{};
  final byStaff = <String?, int>{};
  final byProduct = <String, ({String name, int qty})>{};
  // #549 — recognized at checkout ('pending'), not at Confirm ('completed'). A
  // CANCELLED sale still counts on its creation day and ALSO books a negative
  // entry of the same amounts on its cancel day ([saleDayEntries]), so a return
  // never moves a day that was already reviewed. Every amount below is
  // multiplied by `sign`. The refund payment row stays a cash movement on the
  // refund day (`refundsKobo`, cash card) and is NOT deducted from profit again.
  for (final e in saleDayEntries(orders)) {
    if (!inSpan(e.day)) continue;
    final o = e.o;
    final sign = e.sign;
    // Order-level discount (contra-revenue). Scoped by the ORDER's store — the
    // one rule that decides it lives in [orderDiscountKobo] (#195), so the P&L
    // card's discount line and the Total Sales headline cannot disagree about
    // which store wears a discount.
    final orderInScope = inScope(o.order.storeId);
    discountsKobo += sign * orderDiscountKobo(o, inScope: inScope);
    var orderRevenue = 0;
    for (final i in o.items) {
      if (!inScope(i.item.storeId)) continue;
      final lineRev = i.item.quantity * i.item.unitPriceKobo;
      totalRevenueKobo += sign * lineRev;
      orderRevenue += sign * lineRev;
      itemsSold += sign * i.item.quantity;
      final product = i.product;
      if (product == null || i.item.buyingPriceKobo <= 0) {
        uncostedItems += sign * i.item.quantity;
      } else {
        costedRevenueKobo += sign * lineRev;
        cogsKobo += sign * i.item.quantity * i.item.buyingPriceKobo;
        skuSet.add(product.id);
      }
      // Rank top items by units sold across every identifiable product —
      // including ones with no recorded buying price. Truly ad-hoc lines (no
      // linked product) carry no SKU/name to rank, so they're omitted.
      if (product != null) {
        final cur = byProduct[product.id];
        byProduct[product.id] = (
          name: product.name,
          qty: (cur?.qty ?? 0) + sign * i.item.quantity,
        );
      }
    }
    if (orderRevenue != 0) {
      byStaff.update(
        o.order.staffId,
        (v) => v + orderRevenue,
        ifAbsent: () => orderRevenue,
      );
    }
    // #176 — paid-now vs on-credit split of this order's contribution to Total
    // Sales. `goodsNet` is exactly the order's Total-Sales share, taken from
    // the SAME helper the headline sums (#195) rather than re-derived here, so
    // `paidNow + onCredit == totalSalesKobo` holds by construction and not by
    // coincidence. `goodsPaid` = what was tendered toward the GOODS (amountPaid
    // − deposit held, capped at the goods net); the rest is debt.
    final goodsNet = orderGoodsNetKobo(o, inScope: inScope);
    final split = splitPaidNowOnCredit(
      goodsNet: goodsNet,
      amountPaid: o.order.amountPaidKobo,
      depositHeld: orderInScope ? o.order.crateDepositPaidKobo : 0,
    );
    salesPaidNowKobo += sign * split.paidNow;
    salesOnCreditKobo += sign * split.onCredit;
  }
  String? bestStaff;
  var bestStaffKobo = 0;
  byStaff.forEach((staffId, v) {
    if (v > bestStaffKobo) {
      bestStaffKobo = v;
      bestStaff = staffId == null
          ? 'Unassigned'
          : (users[staffId]?.name ?? 'Staff');
    }
  });
  // #549 — a day that only holds a cancel's negative entry has non-positive
  // quantities; those never rank as a "top item".
  final topItemsList = byProduct.entries
      .where((e) => e.value.qty > 0)
      .map((e) => (name: e.value.name, qty: e.value.qty))
      .toList()
    ..sort((a, b) => b.qty.compareTo(a.qty));
  final topItems = topItemsList.take(3).toList();

  // ── VAT due on net sales (only when the business has enabled VAT) ─────────
  // Base = gross sales − discounts (scope-consistent with the sums above). A
  // pass-through liability computed on recorded sales; it does not affect the
  // P&L profit lines.
  final vatKobo = vat.enabled
      ? computeVatKobo(
          totalRevenueKobo - discountsKobo,
          vat.rateBps,
          basis: vat.basis,
        )
      : 0;

  // ── Inventory on hand at cost (point-in-time) ────────────────────────────
  var inventoryOnHandKobo = 0;
  var uncostedInventoryItems = 0;
  for (final p in productsWS) {
    if (p.product.buyingPriceKobo <= 0) {
      uncostedInventoryItems += p.totalStock;
    } else {
      inventoryOnHandKobo += p.totalStock * p.product.buyingPriceKobo;
    }
  }

  // ── In-transit stock value (#170 #7b, point-in-time) ─────────────────────
  // Stock dispatched between stores but not yet received: removed from the
  // source's inventory row, not yet added to the destination — so it counts in
  // neither store's on-hand and, before #7b, was valued nowhere. The cost that
  // rode each transfer (`cost_kobo`, legacy NULL → 0) restores it to Business
  // worth. Included when EITHER endpoint is in the active store scope (so a
  // locked source store still sees what it dispatched); business-wide under All
  // Stores.
  final inTransitTransfers = input.inTransitTransfers;
  var inTransitValueKobo = 0;
  for (final t in inTransitTransfers) {
    if (inScope(t.fromLocationId) || inScope(t.toLocationId)) {
      inTransitValueKobo += t.costKobo ?? 0;
    }
  }

  // ── Stock flow-equation at current cost (ADR 0014) ───────────────────────
  // Opening@cost + Goods received − COGS − Damages − Expired (± Other) =
  // Expected closing (the perpetual SYSTEM figure), then Variance = Physical −
  // Expected (the stock-count discrepancy). Opening and expected-closing are
  // reconstructed by rewinding the recorded `stock_transactions` deltas from
  // the current on-hand figure, so the equation ties to the system by
  // construction. Every term is valued at the product's CURRENT buying price —
  // cost is time-varying under FIFO (ADR 0005) and only current stock is valued
  // today, so this states a current-cost basis rather than faking historical
  // precision. Store scope is applied per row's `locationId` like every figure
  // here. Receipts (Receive Stock / opening stock) and manual adjustments share
  // movementType 'adjustment', so they're split by the linked reason; anything
  // unclassified (transfers, count reconciliations) is kept in an "other
  // movements" residual so nothing is silently folded into opening.
  final reasonByAdjustmentId = {for (final a in adjustments) a.id: a.reason};
  final currentUnits = {
    for (final p in productsWS) p.product.id: p.totalStock,
  };
  final afterEndUnits = <String, int>{}; // deltas at/after period end (rewind)
  final periodDelta = <String, int>{}; // net delta within the period
  final receivedUnits = <String, int>{};
  final soldUnits = <String, int>{};
  final damagedUnits = <String, int>{};
  final expiredUnits = <String, int>{};
  // #176 — the former single "other movements" residual, split by cause so an
  // unlabeled residual can't hide a loss: store transfers, daily-count
  // reconciliations, and product-delete write-offs each get their own bucket,
  // with `otherDelta` keeping only genuinely unclassified movement.
  final transfersDelta = <String, int>{};
  final countAdjDelta = <String, int>{};
  final deletionsDelta = <String, int>{};
  final otherDelta = <String, int>{}; // signed residual within the period
  void add(Map<String, int> m, String k, int v) => m[k] = (m[k] ?? 0) + v;
  for (final t in stockTxns) {
    if (t.voidedAt != null || !inScope(t.locationId)) continue;
    final pid = t.productId;
    final delta = t.quantityDelta;
    if (endExclusive != null && !t.createdAt.isBefore(endExclusive)) {
      add(afterEndUnits, pid, delta);
    }
    if (!inSpan(t.createdAt)) continue;
    add(periodDelta, pid, delta);
    final mt = t.movementType;
    if (mt == 'sale' || mt == 'return') {
      // A return (stock restored) nets against units sold.
      add(soldUnits, pid, -delta);
    } else if (mt == 'received' || mt == 'restock') {
      add(receivedUnits, pid, delta);
    } else if (mt == 'adjustment' || mt == 'adjusted') {
      final reason = t.adjustmentId == null
          ? ''
          : (reasonByAdjustmentId[t.adjustmentId] ?? '');
      if (isExpiredReason(reason)) {
        add(expiredUnits, pid, -delta);
      } else if (isDamageReason(reason)) {
        add(damagedUnits, pid, -delta);
      } else if (isReceiptReason(reason)) {
        add(receivedUnits, pid, delta);
      } else if (isProductDeleteReason(reason)) {
        add(deletionsDelta, pid, delta);
      } else if (isCountReconciliationReason(reason)) {
        add(countAdjDelta, pid, delta);
      } else {
        add(otherDelta, pid, delta);
      }
    } else if (mt.startsWith('transfer')) {
      // transfer_in / transfer_out legs — quantity moving between stores.
      add(transfersDelta, pid, delta);
    } else {
      // Anything genuinely unclassified stays in the residual.
      add(otherDelta, pid, delta);
    }
  }
  // #193 — the delete write-off as a P&L LOSS, valued from each row's OWN
  // write-time `value_kobo` snapshot. Deliberately NOT the basis of the stock
  // card's `stockDeletionsKobo` term below: ADR 0014 fixes that card on current
  // cost so its closing identity ties to the rewound perpetual figure, exactly as
  // `stockDamagesKobo` (current cost) and `damageCostKobo` (snapshot) already
  // split. See [productDeleteLossKobo].
  final deletionCostKobo = productDeleteLossKobo(
    adjustments,
    productById: productById,
    inSpan: inSpan,
    inScope: inScope,
  );
  var stockOpeningKobo = 0;
  var stockReceivedKobo = 0;
  var stockCogsKobo = 0;
  var stockDamagesKobo = 0;
  var stockExpiredKobo = 0;
  var stockTransfersKobo = 0;
  var stockCountAdjustmentsKobo = 0;
  var stockDeletionsKobo = 0;
  var stockOtherMovementsKobo = 0;
  var stockExpectedClosingKobo = 0;
  final flowPids = <String>{
    ...currentUnits.keys,
    ...periodDelta.keys,
    ...afterEndUnits.keys,
  };
  for (final pid in flowPids) {
    final cost = productById[pid]?.buyingPriceKobo ?? 0;
    if (cost <= 0) continue; // uncosted units carry no value (P&L footnote)
    final closing = (currentUnits[pid] ?? 0) - (afterEndUnits[pid] ?? 0);
    final opening = closing - (periodDelta[pid] ?? 0);
    stockOpeningKobo += opening * cost;
    stockExpectedClosingKobo += closing * cost;
    stockReceivedKobo += (receivedUnits[pid] ?? 0) * cost;
    stockCogsKobo += (soldUnits[pid] ?? 0) * cost;
    stockDamagesKobo += (damagedUnits[pid] ?? 0) * cost;
    stockExpiredKobo += (expiredUnits[pid] ?? 0) * cost;
    stockTransfersKobo += (transfersDelta[pid] ?? 0) * cost;
    // #200 — stays at CURRENT cost on purpose; see [stockCountAdjustmentsKobo].
    stockCountAdjustmentsKobo += (countAdjDelta[pid] ?? 0) * cost;
    stockDeletionsKobo += (deletionsDelta[pid] ?? 0) * cost;
    stockOtherMovementsKobo += (otherDelta[pid] ?? 0) * cost;
  }

  // ── Expenses (approved, in span, in scope) ───────────────────────────────
  // #198 (#155 US 34): in span on the user-picked `expense_date`
  // ([expenseReportingDate]), NOT the record time it used to use — so
  // Saturday's diesel keyed in on Tuesday is reported in Saturday's period here
  // exactly as it already was on the Expenses screen, the budget and Home.
  //
  // The cash-flow card below deliberately does NOT follow this basis: it counts
  // the drawer movement on its own record time ([cashMovementDate]), because
  // custody timing is the question a cash figure answers. So these two expense
  // figures can legitimately differ for the same money — the screen says so
  // under both cards (`daily_reconciliation_detail_screen.dart`).
  //
  // One-off consequence of the switch: a day CLOSED before #198 froze its
  // `expensesKobo` on the old record-time basis (`dailyClosingFiguresFrom`,
  // first-writer-wins in `DailyClosingsDao`). Re-opening such a day can
  // therefore show an as-reviewed-vs-current delta (#174) on Expenses / Net
  // profit that is this basis correction, not money that moved. This fix does
  // NOT back-patch frozen closes — a persisted close is the record of what was
  // reviewed. Whether the delta view should label a basis change as such is the
  // day-close / delta issues' call, not this one's.
  final periodExpenses = approvedExpensesInPeriod(
    expenses.map((e) => e.expense),
    inSpan: inSpan,
    inScope: inScope,
  );
  final expensesKobo = periodExpenses.totalKobo;
  final expensesCount = periodExpenses.count;

  // ── Damages (reason names a loss; a removal) ─────────────────────────────
  // §17.2 crate-aware: a damage flagged +cratelost / +crateempty also forfeits
  // the per-crate refundable deposit (1 tracked bottle unit = 1 crate). The
  // deposit rate is per-manufacturer (Manufacturers.depositAmountKobo).
  final depositByMfr = {for (final m in manufacturers) m.id: m.depositAmountKobo};
  var damageUnits = 0;
  var damageCostKobo = 0;
  var damageRetailKobo = 0;
  var crateDamageDepositKobo = 0;
  final damageRows =
      damageLossRows(adjustments, inSpan: inSpan, inScope: inScope).toList();
  // #200 / US 20 — how many of those rows take the current-cost fallback, so the
  // report can LABEL them instead of the fallback living only in dartdoc. Read
  // off the SAME row list the money below sums, so the two cannot drift.
  final legacyValuedDamageRows = legacyValuedRowCount(damageRows);
  for (final a in damageRows) {
    final units = -a.quantityDiff;
    final p = productById[a.productId];
    damageUnits += units;
    // #170 #7a: value the loss at the FIFO cost SNAPSHOTTED when the damage was
    // recorded (`value_kobo`), so a later cost-price edit can't rewrite a past
    // loss. Legacy quantity-only rows (no snapshot, written before #170) keep
    // the current-cost fallback — the deliberately-labelled behaviour.
    damageCostKobo += lossValueKobo(a.valueKobo, units, p?.buyingPriceKobo);
    damageRetailKobo += units * (p?.retailerPriceKobo ?? 0);
    // #299: the crate shell's loss is valued once from the crate leg's snapshot
    // (full_crate_damage in crateDamages below). The stock adjustment carries the
    // drink loss only, replacing the +cratelost today's-rate valuation path.
  }
  // §17.2, #297, #299 crate-aware: stored empty damage (`damaged`) and full crate
  // damage (`full_crate_damage`) movements forfeit their deposit here so the
  // Statement recognises the shell loss from their snapshotted rate. The pool
  // debit damaged empties make is reflected separately in "Empty crates held" (the
  // stock view), so the period P&L (flow) and the held-empties asset (stock) never
  // double-count the same crate.
  for (final c in crateDamages) {
    if (c.voidedAt != null) continue;
    if (!inSpan(c.createdAt) || !inScope(c.storeId)) continue;
    final lostEmpties = -c.quantityDelta;
    if (lostEmpties <= 0) continue;
    final rate = c.ratePerCrateKobo ?? (depositByMfr[c.manufacturerId] ?? 0);
    crateDamageDepositKobo += lostEmpties * rate;
  }

  // ── Stock audit + shortage value (latest count per store/date in span) ───
  // #186 — the MONEY is summed inside this same loop now, so every figure on the
  // card (units, retail, lines, products counted, and the cost) comes from the
  // one set of winning sessions, bucketed on `businessDate`. Attribution of the
  // valued `stock_adjustments` rows to their session happens first, over ALL
  // counts and ALL adjustments: the windows are bounded by neighbouring
  // sessions, never by the reporting period (see [countShortageRowsBySession]).
  final shortageRowsBySession = countShortageRowsBySession(
    counts,
    adjustments,
    inScope: inScope,
  );
  final dayCounts =
      counts
          .where(
            (c) =>
                inScope(c.storeId) &&
                inSpan(DateTime.tryParse(c.businessDate) ?? DateTime(0)),
          )
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  final seenCount = <String>{};
  var hasStockCount = false;
  var productsCounted = 0;
  var shortageCount = 0;
  var shortageUnits = 0;
  var surplusCount = 0;
  var surplusUnits = 0;
  var surplusCostKobo = 0;
  var shortageRetailKobo = 0;
  // #182 — the shortage loss is valued at the FIFO cost SNAPSHOTTED when the
  // count was saved (`stock_adjustments.value_kobo`, #170), NOT today's cost, so
  // a later product-cost edit can't restate a past period's shortage/variance.
  // #186 changed WHICH rows are summed (the winning session's, not every row in
  // the period) and changed nothing about how they are valued.
  var shortageCostKobo = 0;
  // #200 / US 20 — how many of those rows had NO snapshot and so were valued at
  // today's cost. Drives the report footnote that labels the fallback.
  var legacyValuedShortageRows = 0;
  final shortages = <ReconShortLine>[];
  for (final c in dayCounts) {
    if (!seenCount.add('${c.businessDate}|${c.storeId}')) continue;
    hasStockCount = true;
    productsCounted += c.productsCounted;
    shortageCount += c.shortageCount;
    shortageUnits += c.shortageUnits;
    surplusCount += c.surplusCount;
    surplusUnits += c.surplusUnits;
    final money = countSessionShortage(
      c,
      attributedRows: shortageRowsBySession[c.id] ?? const [],
      productById: productById,
    );
    shortageCostKobo += money.lossKobo;
    legacyValuedShortageRows += money.legacyValuedRows;
    for (final l
        in (jsonDecode(c.linesJson) as List).cast<Map<String, dynamic>>()) {
      final diff = (l['d'] as num).toInt();
      final p = productById[l['p'] as String?];
      if (diff > 0) {
        // A surplus draws down no FIFO queue, so there is no snapshot to sum:
        // this one figure is current-cost by nature, not by choice.
        surplusCostKobo += diff * (p?.buyingPriceKobo ?? 0);
      }
      if (diff >= 0) continue;
      final units = -diff;
      shortageRetailKobo += units * (p?.retailerPriceKobo ?? 0);
      shortages.add(
        ReconShortLine(
          name: l['n'] as String? ?? 'Product',
          system: (l['s'] as num).toInt(),
          actual: (l['a'] as num).toInt(),
          diff: diff,
        ),
      );
    }
  }

  // ── Supplier ledger flows (CEO only) ─────────────────────────────────────
  var goodsReceivedKobo = 0;
  var supplierPaidKobo = 0;
  var supplierPayableKobo = 0;
  if (isCeo) {
    for (final l in ledger) {
      // Skip both halves of a voided pair (original carries voidedAt; the
      // compensating reversal is referenceType 'void') for clean gross flows.
      if (l.voidedAt != null || l.referenceType == 'void') continue;
      if (!inScope(l.storeId)) continue;
      
      if (l.referenceType == 'invoice') {
        supplierPayableKobo += l.amountKobo;
      } else if (l.referenceType.startsWith('payment_')) {
        supplierPayableKobo -= l.amountKobo;
      }

      if (!inSpan(l.activityDate)) continue;
      if (l.referenceType == 'invoice') {
        goodsReceivedKobo += l.amountKobo;
      } else if (l.referenceType.startsWith('payment_')) {
        supplierPaidKobo += l.amountKobo;
      }
    }
  }

  // ── Refunds (P&L contra + net-result outflow) ────────────────────────────
  // Every real refund payment row in the period, any tender — the amount
  // actually paid back to customers. Derived from the append-only payment
  // ledger (`type == 'refund'`), NOT the retired `orders.status == 'refunded'`
  // (a status nothing writes, so the old figure read ₦0 forever — #172). A
  // cancelled sale posts a dated refund cash-out row on the cancel day
  // (OrdersDao.markCancelled), so refunds land on the day money left and a
  // reviewed/banked sale day never silently shrinks. Scoped by the row's store
  // (legacy null-store rows fold into the All-Stores aggregate, as elsewhere)
  // and by its own created_at day.
  var refundsKobo = 0;
  for (final p in payments) {
    if (p.voidedAt != null) continue;
    if (p.type != 'refund') continue;
    if (!inSpan(p.createdAt)) continue;
    if (!inScope(p.storeId)) continue;
    refundsKobo += p.amountKobo;
  }

  // ── Cash-flow summary (ADR 0014; business-wide, tender-tagged) ───────────
  // Expected cash MOVEMENT for the period from recorded cash tenders — NOT a
  // drawer count (Hard Rule #8: no float, no counted cash). payment_transactions
  // is the unified physical-cash ledger (sale / wallet_topup / refund / expense,
  // each with a `method`). New rows carry a nullable storeId (#169) but this
  // card does not filter on it yet (legacy rows are null), so it stays
  // business-wide. Each row is counted on its OWN `created_at` day (inSpan
  // below), the invariant the money-correction slices rely on.
  // Crate deposits (a refundable held liability) are kept OUT of operating cash
  // (sales + debts collected) but summed on their own `crate_deposit` line
  // (#175) so the drawer can be tied WITH the held money broken out — never
  // banked as a sale. `method` casing drifts ('Cash'/'cash'), so match
  // case-insensitively. A cancelled deposit sale posts a negative `crate_deposit`
  // row, so the held line nets a same-period collect-then-cancel to zero.
  //
  // #198 — DELIBERATE EXCEPTION to the expense reporting basis. Every other
  // expense figure in the app is on the user-picked `expense_date`
  // ([expenseReportingDate]); "Expenses paid (cash)" here stays on the payment
  // row's own record time ([cashMovementDate]) because this card states cash
  // CUSTODY: cash left the drawer when it left the drawer, and backdating a
  // receipt cannot un-empty a till that was already counted. Keep it that way —
  // the divergence is disclosed to the CEO on the reconciliation screen, under
  // both the Profit & Loss and the Cash flow cards.
  var cashSalesKobo = 0;
  var cashDebtsCollectedKobo = 0;
  var cashRefundsKobo = 0;
  var cashExpensesKobo = 0;
  var cashCrateDepositsKobo = 0;
  // #215 — the supplier leg, and it lands on its OWN line for the same reason
  // the customer leg above does: refundable money passing through the drawer,
  // never operating cash. Note where it does NOT go — not `cashExpensesKobo`,
  // not `cashOutKobo`, not the net. #212 put it in cash-out once and reverted:
  // the "it really left the drawer" argument applies identically to
  // `crate_deposit`, which this card has excluded since #175, and two legs of
  // one story treated asymmetrically make the card incoherent.
  var cashCrateDepositsPlacedKobo = 0;
  for (final p in payments) {
    if (p.voidedAt != null) continue;
    if (p.method.toLowerCase() != 'cash') continue;
    if (!inSpan(cashMovementDate(p))) continue;
    if (p.type == 'sale') {
      cashSalesKobo += p.amountKobo;
    } else if (p.type == 'wallet_topup') {
      cashDebtsCollectedKobo += p.amountKobo;
    } else if (p.type == 'refund') {
      cashRefundsKobo += p.amountKobo;
    } else if (p.type == 'expense') {
      cashExpensesKobo += p.amountKobo;
    } else if (p.type == 'crate_deposit') {
      cashCrateDepositsKobo += p.amountKobo;
    } else if (p.type == kPaymentTypeCrateDepositOut) {
      // Signed at the source: + when money went out to the supplier, − when a
      // settlement or float payout brought it back.
      cashCrateDepositsPlacedKobo += p.amountKobo;
    }
  }
  // Supplier payments made in cash — the one cash-out NOT in payment_transactions
  // (recorded only on the supplier ledger). Business-wide, in span, to match the
  // rest of the cash card.
  var cashSupplierPaidKobo = 0;
  for (final l in ledger) {
    if (l.voidedAt != null || l.referenceType == 'void') continue;
    if (!l.referenceType.startsWith('payment_')) continue;
    if (!inSpan(l.activityDate)) continue;
    if ((l.paymentMethod ?? '').toLowerCase() != 'cash') continue;
    cashSupplierPaidKobo += l.amountKobo;
  }

  // ── Outstanding customer debt (business-wide — wallets aren't per store) ──
  final totalOwedKobo = balances.values
      .where((b) => b < 0)
      .fold<int>(0, (s, b) => s - b);

  // ── Empty crates held (Bar / Beer Distributor only; point-in-time) ───────
  final showCrates = input.showCrates;
  var crateUnits = 0;
  var crateDepositKobo = 0;
  final manufacturerEmpties = <({String manufacturerName, int count, int valueKobo})>[];
  if (showCrates) {
    final depositById = {
      for (final m in manufacturers) m.id: m.depositAmountKobo,
    };
    final mfrNameById = {
      for (final m in manufacturers) m.id: m.name,
    };
    crateCounts.forEach((mfrId, count) {
      if (count > 0) {
        crateUnits += count;
        final value = count * (depositById[mfrId] ?? 0);
        crateDepositKobo += value;
        manufacturerEmpties.add((
          manufacturerName: mfrNameById[mfrId] ?? 'Unknown',
          count: count,
          valueKobo: value,
        ));
      }
    });
  }

  // ── Crate liabilities (#163) — netted against the empties asset above ────
  // The empties we physically hold ([crateDepositKobo]) are only ours to the
  // extent we don't owe them elsewhere: we owe customers back the deposits they
  // paid ([crate_deposit] wallet family net), and we owe suppliers empties for
  // the full crates they delivered (derived supplier crate ledger × current
  // deposit rate). Both are business-wide (wallets / supplier crate debt aren't
  // per store, like [totalOwedKobo]) and ledger-derived — trustworthy only now
  // that #158–#162 made the balances the ledger's, not a stored cache. Gated on
  // [showCrates] so a non-crate business carries no crate legs (they're 0
  // anyway — no deposit-family rows, no supplier crate ledger).
  var heldCrateDepositsKobo = 0;
  var supplierCrateDebtKobo = 0;
  // #215 — the Placed Deposit ASSET, the third crate leg. Same gate, same
  // business-wide basis, and computed entirely upstream by
  // [computeCrateDepositPosition]: nothing here re-derives it.
  var crateDeposits = CrateDepositRollup.empty;
  // #216 — the WARNING (point-in-time, in no total) and the LOSS SOMEBODY TOOK
  // (this period, in profit). Same gate, same business-wide basis. The warning
  // arrives already computed through `computeCrateShortfall`; the loss is the
  // one thing computed here, and it is computed by the pure helper beside the
  // seam rather than by a sum written out in this file.
  var crateShortages = CrateShortageRollup.empty;
  var crateShortfallWrittenOffKobo = 0;
  // #217 — the slice of the line above that a CUSTOMER FORFEIT raised. Not a
  // second deduction: it is already inside `crateShortfallWrittenOffKobo` and
  // must never be subtracted again. It exists so the report can say, in words,
  // why a kept deposit stopped reading as profit.
  var crateForfeitNettedKobo = 0;
  if (showCrates) {
    heldCrateDepositsKobo = input.heldCrateDepositsKobo;
    supplierCrateDebtKobo = input.supplierCrateDebtKobo;
    crateDeposits = input.crateDeposits;
    crateShortages = input.crateShortages;
    final writeOffs = [
      for (final w in input.crateShortfallWriteOffs)
        CrateShortfallWriteOff(
          manufacturerId: w.manufacturerId,
          storeId: w.storeId,
          crateCount: w.crateCount,
          // The rate SNAPSHOTTED when the decision was taken, never today's.
          // A brand whose deposit rate rises next month must not restate the
          // profit of a day already closed (ADR 0021).
          ratePerCrateKobo: w.ratePerCrateKobo,
          writtenOffAt: w.createdAt,
          // #217 — where the loss came from. The SAME rows on the SAME line;
          // only the disclosure split below reads it.
          source: crateWriteOffSourceOf(w.source),
        ),
    ];
    // Fail closed: a brand missing from this map reads `none` and books
    // nothing. `manufacturers` is the same unfiltered business-wide list the
    // empties valuation above uses.
    final arrangementByManufacturerId = {
      for (final m in manufacturers)
        m.id: crateMoneyArrangementOf(m.crateMoneyArrangement),
    };
    crateShortfallWrittenOffKobo = crateShortfallWriteOffKobo(
      writeOffs: writeOffs,
      arrangementByManufacturerId: arrangementByManufacturerId,
      start: input.start,
      endExclusive: endExclusive,
      inScope: input.inScope,
    );
    // The SAME window and the SAME gate, narrowed to one origin — so the split
    // can never exceed the whole, and a period with no forfeits reads 0 without
    // a special case.
    crateForfeitNettedKobo = crateShortfallWriteOffKobo(
      writeOffs: writeOffs,
      arrangementByManufacturerId: arrangementByManufacturerId,
      start: input.start,
      endExclusive: endExclusive,
      onlySource: CrateWriteOffSource.customerForfeit,
      inScope: input.inScope,
    );
  }

  // ── Forfeit income (#176 / PRD #155 story 7) ─────────────────────────────
  // Crate deposits KEPT this period because the customer never returned the
  // crates — money legitimately earned that the P&L never counted (while crate
  // LOSSES were subtracted). Summed from `crate_deposit_forfeited` wallet rows
  // on their OWN `created_at` day (each row is a negative debit, so take the
  // absolute value), business-wide (wallet rows have no store), gated on
  // showCrates. Added to netProfitKobo below.
  var forfeitIncomeKobo = 0;
  if (showCrates) {
    final forfeitRows = input.crateForfeitRows;
    for (final w in forfeitRows) {
      if (w.voidedAt != null || !inSpan(w.createdAt)) continue;
      forfeitIncomeKobo += -w.signedAmountKobo; // debit → positive income
    }
  }

  // ── Quick-sale (Uncosted) takings (#176 / PRD #155 story 27) ─────────────
  // Revenue on lines with no recorded buying price — money in the drawer that
  // the profit picture excluded entirely. Included in netProfitKobo as pure
  // margin (no COGS is recorded; the transparency footnote counts the items),
  // but NOT in grossProfit/margin (those stay costed-only). By construction
  // this is Total (gross) revenue minus the costed-line revenue.
  final uncostedTakingsKobo = totalRevenueKobo - costedRevenueKobo;

  // ── The single Total Sales definition (#195 / PRD #155 US 28) ────────────
  // Resolved through the SAME helper the Home dashboard and the Profit report
  // call, over the same orders / span / store predicate — so the three surfaces
  // agree because they run one function, not because three loops happen to
  // agree today. The gross + discount split above stays for the P&L card; this
  // is the net headline. `computeReconData`'s own loop and the helper are pinned
  // equal by `test/dashboard/report_revenue_test.dart`.
  final totalSalesKobo = computeTotalSalesKobo(
    orders,
    inSpan: inSpan,
    inScope: inScope,
  );

  // ── The van channel's rollup (#147, spec §8.2) ───────────────────────────
  // Four additive lines. Every one of them is attributed through the trip's
  // SOURCE WAREHOUSE, never the van: a van fails `inScope` by construction
  // (#140), so an order or a payment that only knew its own store would be
  // invisible on every scope including All Stores.
  final vanTrips = input.vanTrips;
  final tripById = {for (final t in vanTrips) t.id: t};

  var vanSalesKobo = 0;
  var vanOpenRevenueKobo = 0;
  final openTrips = <String>{};
  for (final e in saleDayEntries(orders)) {
    final o = e.o;
    final tripId = o.order.vanTripId;
    if (tripId == null) continue;
    if (!inSpan(e.day)) continue;
    final trip = tripById[tripId];
    if (trip == null || !inScope(trip.sourceStoreId)) continue;
    // The order's own net is the road-takings figure the trip reconciles
    // against (`watchSoldValueKoboForTrip` uses the same basis), and a road
    // sale carries no discount in v1.
    vanSalesKobo += e.sign * o.order.netAmountKobo;
    // "Open in the period": still open, or closed only AFTER this period ended
    // — the month-straddling case (spec §9.4 #18). Revenue lands in the ring
    // month, profit in the close month, and the caveat says so.
    final closedAfterPeriod =
        trip.closedAt == null ||
        (endExclusive != null && !trip.closedAt!.isBefore(endExclusive));
    if (closedAfterPeriod) {
      vanOpenRevenueKobo += e.sign * o.order.netAmountKobo;
      openTrips.add(tripId);
    }
  }

  // Profit is READ from the persisted close artifact, never re-derived (ADR
  // 0019 decision 3). A trip closed in the period contributes its whole
  // artifact, including revenue it rang in an earlier month — that is what
  // "profit at close" means.
  var vanProfitKobo = 0;
  var vanCogsKobo = 0;
  var closedTripCount = 0;
  for (final t in vanTrips) {
    final closedAt = t.closedAt;
    if (closedAt == null || !inSpan(closedAt)) continue;
    if (!inScope(t.sourceStoreId)) continue;
    vanProfitKobo += t.profitKobo;
    vanCogsKobo += t.cogsKobo;
    closedTripCount++;
  }

  // Cash from drivers: the period's `van_remittance` rows, on their OWN
  // created_at day, scoped by `store_id` — which #144 stamps to the source
  // warehouse precisely so this passes the ordinary store filter.
  var vanRemittedKobo = 0;
  var vanCashRemittedKobo = 0;
  for (final p in payments) {
    if (p.voidedAt != null) continue;
    if (p.type != kPaymentTypeVanRemittance) continue;
    if (!inSpan(p.createdAt) || !inScope(p.storeId)) continue;
    vanRemittedKobo += p.amountKobo;
    if (p.method.toLowerCase() == 'cash') vanCashRemittedKobo += p.amountKobo;
  }

  return ReconData(
    totalRevenueKobo: totalRevenueKobo,
    // #195 — the headline comes from the shared helper, not from this file's
    // own subtraction. See [ReconData.totalSalesKobo].
    totalSalesKobo: totalSalesKobo,
    costedRevenueKobo: costedRevenueKobo,
    cogsKobo: cogsKobo,
    discountsKobo: discountsKobo,
    vatEnabled: vat.enabled,
    vatRateBps: vat.rateBps,
    vatKobo: vatKobo,
    vatBasis: vat.basis,
    itemsSold: itemsSold,
    skus: skuSet.length,
    uncostedItems: uncostedItems,
    refundsKobo: refundsKobo,
    cashSalesKobo: cashSalesKobo,
    cashDebtsCollectedKobo: cashDebtsCollectedKobo,
    cashRefundsKobo: cashRefundsKobo,
    cashExpensesKobo: cashExpensesKobo,
    cashSupplierPaidKobo: cashSupplierPaidKobo,
    cashCrateDepositsKobo: cashCrateDepositsKobo,
    cashCrateDepositsPlacedKobo: cashCrateDepositsPlacedKobo,
    crateDeposits: crateDeposits,
    crateShortages: crateShortages,
    crateShortfallWrittenOffKobo: crateShortfallWrittenOffKobo,
    crateForfeitNettedKobo: crateForfeitNettedKobo,
    bestStaff: bestStaff,
    bestStaffKobo: bestStaffKobo,
    expensesKobo: expensesKobo,
    expensesCount: expensesCount,
    damageUnits: damageUnits,
    damageCostKobo: damageCostKobo,
    damageRetailKobo: damageRetailKobo,
    crateDamageDepositKobo: crateDamageDepositKobo,
    hasStockCount: hasStockCount,
    productsCounted: productsCounted,
    shortageCount: shortageCount,
    shortageUnits: shortageUnits,
    surplusCount: surplusCount,
    surplusUnits: surplusUnits,
    shortageCostKobo: shortageCostKobo,
    shortageRetailKobo: shortageRetailKobo,
    shortages: shortages,
    goodsReceivedKobo: goodsReceivedKobo,
    supplierPaidKobo: supplierPaidKobo,
    totalOwedKobo: totalOwedKobo,
    payOnDeliveryUncollectedKobo: payOnDeliveryUncollectedKobo(
      input.payOnDelivery,
    ),
    showCrates: showCrates,
    crateUnits: crateUnits,
    crateDepositKobo: crateDepositKobo,
    heldCrateDepositsKobo: heldCrateDepositsKobo,
    supplierCrateDebtKobo: supplierCrateDebtKobo,
    supplierPayableKobo: supplierPayableKobo,
    inventoryOnHandKobo: inventoryOnHandKobo,
    inTransitValueKobo: inTransitValueKobo,
    uncostedInventoryItems: uncostedInventoryItems,
    surplusCostKobo: surplusCostKobo,
    stockOpeningKobo: stockOpeningKobo,
    stockReceivedKobo: stockReceivedKobo,
    stockCogsKobo: stockCogsKobo,
    stockDamagesKobo: stockDamagesKobo,
    stockExpiredKobo: stockExpiredKobo,
    stockOtherMovementsKobo: stockOtherMovementsKobo,
    stockExpectedClosingKobo: stockExpectedClosingKobo,
    topItems: topItems,
    manufacturerEmpties: manufacturerEmpties,
    // #176 report-truth additions.
    salesPaidNowKobo: salesPaidNowKobo,
    salesOnCreditKobo: salesOnCreditKobo,
    forfeitIncomeKobo: forfeitIncomeKobo,
    uncostedTakingsKobo: uncostedTakingsKobo,
    stockTransfersKobo: stockTransfersKobo,
    stockCountAdjustmentsKobo: stockCountAdjustmentsKobo,
    stockDeletionsKobo: stockDeletionsKobo,
    // #200 / US 20 — the legacy-valuation disclosure counts.
    legacyValuedDamageRows: legacyValuedDamageRows,
    legacyValuedShortageRows: legacyValuedShortageRows,
    // #193 — the same write-off, as the positive P&L loss magnitude.
    deletionCostKobo: deletionCostKobo,
    // #147 — the van channel's four additive lines.
    van: ReconVanRollup(
      salesKobo: vanSalesKobo,
      remittedKobo: vanRemittedKobo,
      cashRemittedKobo: vanCashRemittedKobo,
      profitKobo: vanProfitKobo,
      cogsKobo: vanCogsKobo,
      openRevenueKobo: vanOpenRevenueKobo,
      openTripCount: openTrips.length,
      closedTripCount: closedTripCount,
    ),
  );
}

// ── Changed-since-review, outside the day (#192) ─────────────────────────────

/// The `YYYY-MM-DD` natural key for [d]'s calendar day — the same string
/// `daily_closings.business_date` carries and the detail screen derives from its
/// bucket start, so a key built here matches a snapshot row exactly.
String reconDayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Files [rows] under every calendar day they could possibly report on, keeping
/// only the days in [wanted].
///
/// [datesOf] returns EVERY date a row carries, not the one basis the figure uses:
/// an expense reports on `expense_date` but its cash leg moves on `created_at`,
/// and re-encoding that per-figure rule here is exactly how the sweep would come
/// to disagree with [reconDataFrom]. Filing a row under a day it does not
/// actually belong to is harmless — [reconDataFrom] applies the real basis
/// through its own `inSpan` — so this deliberately over-includes and lets the one
/// implementation of the money math have the last word.
Map<String, List<T>> _byCandidateDay<T>(
  Iterable<T> rows,
  Iterable<DateTime> Function(T) datesOf,
  Set<String> wanted,
) {
  final out = <String, List<T>>{};
  if (wanted.isEmpty) return out;
  for (final row in rows) {
    for (final d in datesOf(row)) {
      final key = reconDayKey(d);
      if (!wanted.contains(key)) continue;
      (out[key] ??= <T>[]).add(row);
    }
  }
  return out;
}

/// The reviewed days whose figures have MOVED since they were reviewed, as
/// `YYYY-MM-DD` keys (#192).
///
/// Why this exists: until #192 a changed reviewed day announced itself only from
/// INSIDE that day's own detail screen, so you had to already suspect a day to
/// learn it moved. This is the same question asked from outside, for every
/// reviewed day at once, and it drives the reconciliation list's marker.
///
/// **One pass over the data, not one per day.** The rows are filed under the
/// reviewed days they could report on ([_byCandidateDay]) and each day is then
/// run through the REAL [reconDataFrom] over its own slice, so there is still
/// exactly one implementation of the money math. The cost is therefore
/// `O(rows) + O(reviewed days × products)`, not `O(reviewed days × rows)` — the
/// difference between a sweep and a freeze on a shop with a year of history.
///
/// **What it cannot see:** `stockExpectedClosing`, which is rewound from the
/// CURRENT on-hand figure over every later movement and so is not derivable from
/// one day's rows — hence [ReconClosingComparison.anyDayLocalChanged] rather than
/// `anyChanged`. A day whose ONLY movement is expected closing is still caught by
/// the day's own detail screen, which computes the real figure.
///
/// **Deliberately not wired to the Home attention dot.** `reports_attention.dart`
/// is built on the Home hot path and re-derives on every sale; this sweep re-runs
/// whenever any report row set changes, which is the right price to pay on the
/// reconciliation list (a report screen you are already reading) and the wrong
/// one on Home. The list marker is the surface #192 asked for.
final changedReviewedDaysProvider = Provider<Set<String>>((ref) {
  final snapshots =
      ref.watch(allDailyClosingsProvider).valueOrNull ?? const [];
  if (snapshots.isEmpty) return const <String>{};
  final wanted = {for (final s in snapshots) s.businessDate};

  final showCrates = businessTracksCrates(ref.watch(currentBusinessProvider));
  // The day close's own basis (#191, ADR 0022): the whole business minus the
  // vans, ignoring the active lock and the viewer's confinement, and the
  // UNSCOPED stock totals.
  final inScope = businessWideStoreFilter(ref.watch(vanStoresProvider));
  final products =
      ref.watch(productsWithStockProvider(null)).valueOrNull ?? const [];
  final manufacturers =
      ref.watch(allManufacturersProvider).valueOrNull ?? const [];

  final ordersByDay = _byCandidateDay<OrderWithItems>(
    ref.watch(allOrdersProvider).valueOrNull ?? const [],
    // #549 — a cancelled sale is also a (negative) entry on its cancel day.
    (o) => [
      o.order.createdAt,
      if (o.order.cancelledAt != null) o.order.cancelledAt!.toLocal(),
    ],
    wanted,
  );
  final expensesByDay = _byCandidateDay<ExpenseWithCategory>(
    ref.watch(allExpensesProvider).valueOrNull ?? const [],
    (e) => [e.expense.expenseDate, e.expense.createdAt],
    wanted,
  );
  // A stock adjustment carries ONE date, so this is the only day it can be
  // filed under. #186 note: a BACKDATED count's shortage rows therefore land in
  // a different slice from the session that wrote them, and that session falls
  // to [countSessionShortage]'s labelled current-cost fallback inside this sweep
  // only. Harmless by construction — the sweep compares the FROZEN figure set,
  // whose only count figure is `shortageUnits` (session-sourced, so unaffected)
  // — and the day's own detail screen, which sees every row, computes the real
  // snapshot-valued figure. Filing a row under the session's business date is
  // not possible here: nothing on the row names its session.
  final adjustmentsByDay = _byCandidateDay<StockAdjustmentData>(
    ref.watch(allStockAdjustmentsProvider).valueOrNull ?? const [],
    (a) => [a.createdAt],
    wanted,
  );
  final ledgerByDay = _byCandidateDay<SupplierLedgerEntryData>(
    ref.watch(allSupplierLedgerEntriesProvider).valueOrNull ?? const [],
    (l) => [l.activityDate, l.createdAt],
    wanted,
  );
  final paymentsByDay = _byCandidateDay<PaymentTransactionData>(
    ref.watch(allPaymentTransactionsProvider).valueOrNull ?? const [],
    (p) => [p.createdAt],
    wanted,
  );
  final stockTxnsByDay = _byCandidateDay<StockTransactionData>(
    ref.watch(allStockTransactionsProvider).valueOrNull ?? const [],
    (t) => [t.createdAt],
    wanted,
  );
  final countsByDay = _byCandidateDay<StockCountData>(
    ref.watch(allStockCountsProvider).valueOrNull ?? const [],
    (c) => [DateTime.tryParse(c.businessDate) ?? c.createdAt, c.createdAt],
    wanted,
  );
  final crateDamagesByDay = _byCandidateDay<CrateLedgerData>(
    ref.watch(allCrateDamagesProvider).valueOrNull ?? const [],
    (c) => [c.createdAt],
    wanted,
  );
  final forfeitsByDay = _byCandidateDay<WalletTransactionData>(
    showCrates
        ? (ref.watch(crateForfeitRowsProvider).valueOrNull ?? const [])
        : const <WalletTransactionData>[],
    (w) => [w.createdAt],
    wanted,
  );

  final changed = <String>{};
  for (final snapshot in snapshots) {
    final day = snapshot.businessDate;
    final start = DateTime.tryParse(day);
    if (start == null) continue;
    final live = reconDataFrom(
      ReconInputs(
        orders: ordersByDay[day] ?? const [],
        expenses: expensesByDay[day] ?? const [],
        adjustments: adjustmentsByDay[day] ?? const [],
        supplierLedger: ledgerByDay[day] ?? const [],
        payments: paymentsByDay[day] ?? const [],
        stockTxns: stockTxnsByDay[day] ?? const [],
        stockCounts: countsByDay[day] ?? const [],
        productsWithStock: products,
        manufacturers: manufacturers,
        crateDamages: crateDamagesByDay[day] ?? const [],
        crateForfeitRows: forfeitsByDay[day] ?? const [],
        showCrates: showCrates,
        // The frozen record is opener-independent (#192): compute the supplier
        // flows here exactly as the capture does, so the sweep and the day's own
        // screen can never answer from two different bases.
        isCeo: true,
        inScope: inScope,
        start: start,
        endExclusive: start.add(const Duration(days: 1)),
      ),
    );
    if (reconClosingComparison(snapshot, live).anyDayLocalChanged) {
      changed.add(day);
    }
  }
  return changed;
});
