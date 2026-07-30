import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:reebaplus_pos/core/crates/crate_deposit_ledger_types.dart';
import 'package:reebaplus_pos/core/crates/crate_deposit_position.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/vat_settings.dart';
import 'package:reebaplus_pos/core/stores/van_store.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/report_revenue.dart';
import 'package:reebaplus_pos/shared/models/order_status.dart';

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

/// The store-scope predicate shared by every reconciliation read: the §12.1
/// active store (a concrete store), else the viewer's full selectable set
/// ("All Stores" for an all-stores viewer; a confined Manager's assigned stores).
///
/// **Vans are out of scope** (#140, van-sales spec §8.1). Road sales are
/// recognised as revenue when the driver rings them, but they carry no cost
/// against them until the trip closes, so letting them into the All-Stores
/// aggregate would inflate every figure this filter guards. They surface
/// instead as one aggregated "Van Sales" line (#147). Note this is about
/// *revenue and per-store figures* only: van **stock** still counts towards
/// All-Stores inventory value and business worth (§4.1), which is why
/// `inventoryOnHandKobo` below is scoped by the locked store — or unscoped on a
/// [businessWide] compute — rather than by this predicate.
///
/// [businessWide] is the DAY-CLOSE basis (#191, ADR 0022): it ignores both the
/// active lock and the viewer's confinement, so every store in the business
/// counts. A persisted day close is ONE durable record of what the whole
/// business's day looked like, and it is FIRST-WRITER-WINS — whoever opens the
/// finished day first must therefore freeze the same figures, whatever store
/// they happened to be locked to. Vans stay out even here: business-wide is not
/// "vans too".
bool Function(String?) reconStoreFilter(
  WidgetRef ref, {
  bool businessWide = false,
}) {
  final selectableIds = ref
      .watch(selectableStoresProvider)
      .map((s) => s.id)
      .toSet();
  final canAll = ref.watch(canViewAllStoresProvider);
  final active = ref.watch(lockedStoreProvider).value;
  final vans = ref.watch(vanStoresProvider);
  final wide = businessWideStoreFilter(vans);
  return (storeId) {
    if (!wide(storeId)) return false; // vans are out at every scope
    if (businessWide) return true; // the whole business (incl. legacy null-store)
    if (active != null) return storeId == active;
    if (canAll) return true; // All-Stores aggregate (incl. legacy null-store)
    return storeId != null && selectableIds.contains(storeId);
  };
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

/// A stock adjustment is a damage/loss when its reason names one. Catches both
/// recording paths (§17.2): Record Damages stamps `damage:<key>`; a Manager/CEO
/// manual removal stores the free-text reason ("Theft", "Damage"…). Excludes
/// count reconciliations ("Daily stock count adjustment"), deletion sweeps and
/// `initial_stock`, so a shortage is never double-counted as a damage.
bool isDamageReason(String reason) {
  final r = reason.toLowerCase();
  return r.startsWith('damage') ||
      r.startsWith('theft') ||
      r.startsWith('expired') ||
      r.startsWith('spilled') ||
      r.startsWith('broken');
}

/// A damage/loss reason that specifically names expiry (spoilage past date).
/// The ADR 0014 stock flow-equation card breaks **Expired** out of Damages as
/// its own line. Record Damages stamps `damage:expired` (`stock_count_screen`);
/// a Manager/CEO free-text removal stores "Expired". Both contain "expired", so
/// match on that, case-insensitively. Callers pair this with [isDamageReason]:
/// a non-expired damage is `isDamageReason(r) && !isExpiredReason(r)`.
bool isExpiredReason(String reason) => reason.toLowerCase().contains('expired');

/// A stock-increment reason that names a goods RECEIPT (stock coming in), for
/// the ADR 0014 flow-equation "Goods received" line. Both Receive Stock and Add
/// Product opening stock route through `adjustStock` with the reason "Stock
/// received"; a few synonyms are accepted for robustness. Count reconciliations
/// ("Daily stock count adjustment") and manual removals are deliberately NOT
/// receipts — they fall to the "other movements" residual.
bool isReceiptReason(String reason) {
  final r = reason.toLowerCase();
  return r.contains('received') ||
      r.contains('receipt') ||
      r.contains('restock') ||
      r.contains('opening') ||
      r.contains('initial');
}

/// The machine reason a product-delete write-off stamps (#170 #7c) — matches
/// `InventoryDao.productDeletedReason` verbatim, kept as a local const so the
/// pure recon compute needn't reach into the DAO layer. #176 breaks these rows
/// out of the stock card's "Other movements" residual as their own labelled
/// line ("Product deletions") so a delete can't hide a loss unlabeled.
const String kProductDeletedReason = 'product_deleted';

/// A product-delete write-off adjustment (#170 #7c / #176). Exact match on the
/// machine reason — never a substring, so a free-text "deleted extra" removal
/// stays in the residual.
bool isProductDeleteReason(String reason) => reason == kProductDeletedReason;

/// A daily-stock-count reconciliation adjustment ("Daily stock count
/// adjustment", `stock_count_screen`) — the count-correction class #176 breaks
/// out of the stock card's "Other movements" residual as its own line ("Count
/// corrections"). Matches the "stock count" phrase (not a bare "count", which
/// would also catch "dis**count**"/"ac**count**" in a free-text removal reason).
bool isCountReconciliationReason(String reason) =>
    reason.toLowerCase().contains('stock count');

/// §17.2 crate-aware damages — FULL crate lost. When a damaged tracked-bottle
/// product also forfeits its refundable crate deposit because the full crate
/// (item + its container) was lost, Record Damages appends this suffix to the
/// `damage:<key>` reason. The held-empties pool is untouched — that container
/// was never a returned empty — so only the deposit is forfeited on the
/// Statement. The suffix keeps the `damage:` prefix so [isDamageReason] still
/// classifies the row. Deposit basis is 1 tracked bottle unit = 1 crate (the
/// same basis `watchFullCratesByManufacturer`/`createOrder` use).
///
/// The other fate — a STORED empty was damaged — is a crate-only loss: no drink
/// is involved, so it removes no bottle stock and writes no stock_adjustment. It
/// is recorded purely as a `damaged` crate_ledger movement
/// ([InventoryDao.recordEmptyCrateDamage]); its forfeited deposit is summed from
/// that ledger in [computeReconData], not from a damage reason.
const String kCrateLostSuffix = '+cratelost';

/// True when a damage reason forfeits the per-crate deposit (a full crate lost).
bool damageForfeitsFullCrate(String reason) =>
    reason.toLowerCase().contains(kCrateLostSuffix);

/// Value a stock loss (damage / count-shortage / product-delete write-off) for
/// the P&L (#170 #7a). Prefers [snapshotValueKobo] — the FIFO cost the mutator
/// drew down and recorded AT WRITE TIME — so a later cost-price edit can never
/// restate a past loss. A legacy quantity-only row (written before #170) has no
/// snapshot, so it falls back to [units] × [currentCostKobo] (today's rate) —
/// the deliberately-labelled fallback. `null` current cost counts as 0.
int lossValueKobo(int? snapshotValueKobo, int units, int? currentCostKobo) =>
    snapshotValueKobo ?? (units * (currentCostKobo ?? 0));

/// Value the daily-stock-count SHORTAGE loss for the P&L / variance card from
/// the #170 write-time snapshot (#182) — the deferral #170 left open (audit
/// #30). A stock count applies each shortage line through
/// `InventoryDao.adjustStock` with the reason "Daily stock count adjustment" (a
/// decrease), which draws the FIFO queue down oldest-first and records the drawn
/// cost on the `stock_adjustments` row (`value_kobo`). Summing those snapshots —
/// exactly as the Damages figure already does via [lossValueKobo] — means a
/// later product-cost edit can never restate a past period's shortage/variance
/// figure. Legacy quantity-only rows (written before #170, no snapshot) fall
/// back to current cost, per [lossValueKobo]. Only count-reconciliation removals
/// in span + scope are summed; the `isCountReconciliationReason` guard is
/// disjoint from `isDamageReason`, so a shortage is never double-counted as a
/// damage. Surplus (a gain) draws down no queue and carries no snapshot, so it
/// stays current-cost in the caller.
int countShortageLossKobo(
  Iterable<StockAdjustmentData> adjustments, {
  required Map<String, ProductData> productById,
  required bool Function(DateTime) inSpan,
  required bool Function(String?) inScope,
}) {
  var total = 0;
  for (final a in countShortageRows(
    adjustments,
    inSpan: inSpan,
    inScope: inScope,
  )) {
    final units = -a.quantityDiff;
    total += lossValueKobo(
      a.valueKobo,
      units,
      productById[a.productId]?.buyingPriceKobo,
    );
  }
  return total;
}

/// The count-reconciliation SHORTAGE rows inside [inSpan] + [inScope] — the one
/// definition of "which rows are a count shortage", so the money
/// ([countShortageLossKobo]) and the footnote that discloses how it was valued
/// ([legacyValuedRowCount]) can never disagree about the row set they describe.
Iterable<StockAdjustmentData> countShortageRows(
  Iterable<StockAdjustmentData> adjustments, {
  required bool Function(DateTime) inSpan,
  required bool Function(String?) inScope,
}) => _lossRows(
  adjustments,
  isLoss: isCountReconciliationReason,
  inSpan: inSpan,
  inScope: inScope,
);

/// The damage/loss rows inside [inSpan] + [inScope] — the [countShortageRows]
/// twin for the Damages figure, so its money and its footnote also describe one
/// row set. Disjoint from [countShortageRows] by reason, so a loss is never
/// counted as both.
Iterable<StockAdjustmentData> damageLossRows(
  Iterable<StockAdjustmentData> adjustments, {
  required bool Function(DateTime) inSpan,
  required bool Function(String?) inScope,
}) => _lossRows(
  adjustments,
  isLoss: isDamageReason,
  inSpan: inSpan,
  inScope: inScope,
);

/// A loss is a DECREASE whose reason [isLoss] classifies, inside span + scope.
Iterable<StockAdjustmentData> _lossRows(
  Iterable<StockAdjustmentData> adjustments, {
  required bool Function(String) isLoss,
  required bool Function(DateTime) inSpan,
  required bool Function(String?) inScope,
}) => adjustments.where(
  (a) =>
      isLoss(a.reason) &&
      a.quantityDiff < 0 &&
      inSpan(a.createdAt) &&
      inScope(a.storeId),
);

/// How many of [rows] were valued at TODAY's cost rather than at the cost drawn
/// when they were written — i.e. how many carry no `value_kobo` snapshot and so
/// took [lossValueKobo]'s legacy fallback (#200 / PRD #155 US 20).
///
/// #170 made every new loss snapshot its own cost, but rows written before it
/// only ever recorded a quantity. Their money therefore moves whenever someone
/// edits the product's buying price — the one case where a past loss figure is
/// NOT frozen. The story asked for that fallback to be *labelled*, not just
/// documented, so this count drives the report footnote. Zero means every row in
/// the figure carries its own write-time cost and the figure cannot be restated.
int legacyValuedRowCount(Iterable<StockAdjustmentData> rows) =>
    rows.where((a) => a.valueKobo == null).length;

// ── Expense date basis (#155 US 34 / #198) ───────────────────────────────────
//
// An expense row carries TWO dates and they answer different questions:
//   • `expense_date` — the day the owner says the money was spent, chosen in
//     the §20.2 date picker. This is the REPORTING basis.
//   • `created_at`   — the moment the row was keyed into the app. This is the
//     CUSTODY basis: when the money actually left the drawer.
// Saturday's diesel keyed in on Tuesday is one spend with two honest dates, and
// each figure names which one it uses ([expenseReportingDate] vs
// [cashMovementDate]) so the two can never silently drift apart again.

/// The date an expense is REPORTED on — the user-picked `expense_date`.
///
/// Every expense figure in the app now shares this basis: the Expenses screen
/// and its monthly budget (`expenses_screen.dart`), the Home dashboard's Total
/// Expenses (`home_screen.dart`) and — since #198 — the reconciliation P&L /
/// Business Statement. Before #198 the P&L alone summed on `created_at`, so a
/// backdated expense landed in a different period on every screen (#155 US 34;
/// `MONEY_FLOW_AUDIT.md` § Expenses).
///
/// Never null: the column is NOT NULL with a `now()` default both in Drift and
/// in the cloud (`0073_expenses_full.sql`), and legacy rows were backfilled
/// from `created_at` on both sides (Drift v31 `columnTransformer`, then the 0073
/// `UPDATE`). So there is no null case to fall back for — an un-picked date
/// already reads as the record time.
DateTime expenseReportingDate(ExpenseData e) => e.expenseDate;

/// The date a cash tender is counted on in the cash-flow card — its own
/// `created_at`, i.e. the moment the money moved through the drawer.
///
/// **The deliberate exception to [expenseReportingDate]** (#155 US 34 / #198).
/// The cash card states cash MOVEMENT, so custody timing wins: cash left the
/// drawer when it left the drawer, and backdating a receipt cannot un-empty a
/// till that was already counted. That is why an expense entered today for last
/// week shows in last week's P&L but in THIS period's "Expenses paid (cash)" —
/// the two figures are answering different questions, and the reconciliation
/// screen prints that in plain words under both cards.
DateTime cashMovementDate(PaymentTransactionData p) => p.createdAt;

/// Sum the period's expenses for the P&L / Business Statement: approved only
/// (§20.4 — pending awaits the CEO and rejected is never spend), not
/// soft-deleted, in store scope, and — the #198 fix — in span on the
/// user-picked [expenseReportingDate] rather than the record time.
({int totalKobo, int count}) approvedExpensesInPeriod(
  Iterable<ExpenseData> expenses, {
  required bool Function(DateTime) inSpan,
  required bool Function(String?) inScope,
}) {
  var totalKobo = 0;
  var count = 0;
  for (final e in expenses) {
    if (e.isDeleted || e.status != 'approved') continue;
    if (!inSpan(expenseReportingDate(e)) || !inScope(e.storeId)) continue;
    totalKobo += e.amountKobo;
    count++;
  }
  return (totalKobo: totalKobo, count: count);
}

/// Value the product-delete WRITE-OFF loss (#170 #7c) from the write-time
/// snapshot (#193) — the deferral #176 left open. Finalising a delete runs each
/// store's remaining stock through `InventoryDao.adjustStock` with the machine
/// reason `product_deleted` (`InventoryDao.writeOffAllStockForDelete`), which
/// draws the FIFO queue down oldest-first and records the drawn cost on the
/// `stock_adjustments` row (`value_kobo`).
///
/// The snapshot is the only basis that can value this loss at all: the product is
/// soft-deleted the instant the write-off lands, so the recon engine's
/// `productById` map — built from NON-deleted products (`isDeleted.not()`) — can
/// never resolve a cost for it again. Valuing it at "current cost" therefore
/// yields 0 forever, which is exactly how a real loss came to read ₦0 (#193).
/// This is the same treatment Damages ([lossValueKobo]) and count shortages
/// ([countShortageLossKobo]) already get, and ADR 0014's 2026-07-25 addendum
/// prescribes it for every *loss* surface: a later cost edit cannot restate a
/// past period's loss. Legacy quantity-only rows (pre-#170, no snapshot) fall
/// back to current cost per [lossValueKobo], which still resolves whenever the
/// product is somehow still live.
///
/// Only in-span, in-scope REMOVALS count, and the reason match is exact
/// ([isProductDeleteReason]) so a free-text "deleted extra" removal stays in the
/// stock card's residual.
int productDeleteLossKobo(
  Iterable<StockAdjustmentData> adjustments, {
  required Map<String, ProductData> productById,
  required bool Function(DateTime) inSpan,
  required bool Function(String?) inScope,
}) {
  var total = 0;
  for (final a in adjustments) {
    if (!isProductDeleteReason(a.reason) || a.quantityDiff >= 0) continue;
    if (!inSpan(a.createdAt) || !inScope(a.storeId)) continue;
    total += lossValueKobo(
      a.valueKobo,
      -a.quantityDiff,
      productById[a.productId]?.buyingPriceKobo,
    );
  }
  return total;
}

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

  for (final o in orders) {
    // Revenue is recognized at checkout (status 'pending'), not at the
    // ceremonial Confirm ('completed'). Count any non-reversed sale.
    if (!orderCountsAsSale(o.order.status) || !inSpan(o.order.createdAt)) {
      continue;
    }
    _BucketAccum? acc;
    for (final i in o.items) {
      if (!inScope(i.item.storeId)) continue;
      acc ??= bucketOf(o.order.createdAt);
      acc.itemsSold += i.item.quantity;
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
  final bool hasStockCount;
  final int productsCounted;
  final int shortageCount;
  final int shortageUnits;
  final int surplusCount;
  final int surplusUnits;
  final int shortageCostKobo;
  final int shortageRetailKobo;
  final List<ReconShortLine> shortages;
  final int goodsReceivedKobo;
  final int supplierPaidKobo;
  final int totalOwedKobo;
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

  /// Daily-count reconciliation adjustments, at CURRENT cost — deliberately a
  /// different basis from the P&L's [shortageCostKobo], which #182 moved onto the
  /// #170 write-time snapshot. #200 asked whether this line should follow it. It
  /// must not, on its own, for three reasons in ascending weight:
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
  /// one event reports two labelled figures instead of two silent ones. A real
  /// basis change has to convert the whole card at once — #186.
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
  int get netProfitKobo =>
      grossProfitKobo +
      uncostedTakingsKobo +
      forfeitIncomeKobo -
      expensesKobo -
      damageCostKobo -
      crateDamageDepositKobo -
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

  /// Variance = Physical count − Expected closing, valued at current cost:
  /// a surplus (physical over system) is positive, a shortage negative. This is
  /// the count discrepancy the recorded flows did NOT explain — the independent
  /// signal the closing report surfaces. Uses the same count figures as the
  /// stock audit (`surplus`/`shortage` at cost). Meaningful only when a physical
  /// count exists in the period ([hasStockCount]).
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

/// Full reconciliation roll-up for `[start, endExclusive)` in the active store
/// scope. `isCeo` only gates the supplier-ledger flows (the rest is computed
/// either way; the screen decides which figures to show per the cost wall).
///
/// [businessWide] computes the whole business instead — the basis a persisted
/// day close freezes and compares against (#191, ADR 0022). It ignores the
/// active lock and the viewer's confinement (see [reconStoreFilter]) and reads
/// the UNSCOPED stock totals, so the frozen record never depends on which store
/// the first opener happened to be in. Every other caller wants the default.
///
/// This is the **gather** half only (#195): every `ref.watch` lives here and the
/// arithmetic lives in the pure [reconDataFrom]. Keep it that way — a provider
/// read that sneaks into the math is a figure that can no longer be tested.
ReconData computeReconData(
  WidgetRef ref, {
  DateTime? start,
  DateTime? endExclusive,
  required bool isCeo,
  bool businessWide = false,
}) {
  // Inventory-on-hand must honour the active-store scope like every other
  // figure here (§12.1): pass the locked store so a single-store view doesn't
  // sum every store's stock (null = All Stores). The products list itself is
  // unaffected — only the stock totals are store-filtered — so `productById`
  // (used for damage/shortage/surplus cost lookups) stays complete.
  // A business-wide compute (#191) reads the unscoped totals, matching its
  // store predicate below.
  final storeScope =
      businessWide ? null : ref.watch(lockedStoreProvider).value;
  // Crate reads stay behind the opt-in gate, so a business that tracks no
  // crates opens no crate stream at all (the conditional watch is deliberate).
  final showCrates = businessTracksCrates(ref.watch(currentBusinessProvider));
  return reconDataFrom(
    ReconInputs(
      orders: ref.watch(allOrdersProvider).valueOrNull ?? const [],
      expenses: ref.watch(allExpensesProvider).valueOrNull ?? const [],
      adjustments:
          ref.watch(allStockAdjustmentsProvider).valueOrNull ?? const [],
      supplierLedger:
          ref.watch(allSupplierLedgerEntriesProvider).valueOrNull ?? const [],
      payments:
          ref.watch(allPaymentTransactionsProvider).valueOrNull ?? const [],
      stockTxns:
          ref.watch(allStockTransactionsProvider).valueOrNull ?? const [],
      stockCounts: ref.watch(allStockCountsProvider).valueOrNull ?? const [],
      productsWithStock:
          ref.watch(productsWithStockProvider(storeScope)).valueOrNull ??
          const [],
      creditBalancesKobo:
          ref.watch(creditBalancesKoboProvider).valueOrNull ?? const {},
      manufacturers:
          ref.watch(allManufacturersProvider).valueOrNull ?? const [],
      emptyCrateCounts:
          ref.watch(emptyCratesByManufacturerProvider).valueOrNull ?? const {},
      crateDamages: ref.watch(allCrateDamagesProvider).valueOrNull ?? const [],
      usersById: ref.watch(usersByBusinessProvider).valueOrNull ?? const {},
      inTransitTransfers:
          ref.watch(allInTransitTransfersProvider).valueOrNull ?? const [],
      vanTrips: ref.watch(allVanTripsProvider).valueOrNull ?? const [],
      crateForfeitRows: showCrates
          ? (ref.watch(crateForfeitRowsProvider).valueOrNull ?? const [])
          : const [],
      vat: ref.watch(vatConfigProvider).valueOrNull ?? VatConfig.off,
      showCrates: showCrates,
      heldCrateDepositsKobo: showCrates
          ? (ref.watch(crateDepositSummaryProvider).valueOrNull?.heldKobo ?? 0)
          : 0,
      supplierCrateDebtKobo: showCrates
          ? (ref.watch(supplierCrateDebtValueKoboProvider).valueOrNull ?? 0)
          : 0,
      // #215 — business-wide by design. Note the absence of a store read here:
      // unlike the stock totals above, this is NOT scoped by `storeScope`, and
      // `businessWide` makes no difference to it either. The depot invoices the
      // business, not the branch.
      crateDeposits: showCrates
          ? (ref.watch(businessCrateDepositRollupProvider).valueOrNull ??
                CrateDepositRollup.empty)
          : CrateDepositRollup.empty,
      isCeo: isCeo,
      inScope: reconStoreFilter(ref, businessWide: businessWide),
      start: start,
      endExclusive: endExclusive,
    ),
  );
}

/// The reconciliation roll-up itself — **pure** over [ReconInputs] (#195), so
/// every figure it derives can be pinned by a unit test with no widget, no
/// database and no `WidgetRef`. [computeReconData] is the provider-reading
/// wrapper.
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
  for (final o in orders) {
    // Recognized at checkout ('pending'), not at Confirm ('completed'). A
    // cancelled order is excluded here (orderCountsAsSale is false) — its money
    // reversal is booked as a real refund payment row, summed below.
    if (!orderCountsAsSale(o.order.status) || !inSpan(o.order.createdAt)) {
      continue;
    }
    // Order-level discount (contra-revenue). Scoped by the ORDER's store — the
    // one rule that decides it lives in [orderDiscountKobo] (#195), so the P&L
    // card's discount line and the Total Sales headline cannot disagree about
    // which store wears a discount.
    final orderInScope = inScope(o.order.storeId);
    discountsKobo += orderDiscountKobo(o, inScope: inScope);
    var orderRevenue = 0;
    for (final i in o.items) {
      if (!inScope(i.item.storeId)) continue;
      final lineRev = i.item.quantity * i.item.unitPriceKobo;
      totalRevenueKobo += lineRev;
      orderRevenue += lineRev;
      itemsSold += i.item.quantity;
      final product = i.product;
      if (product == null || i.item.buyingPriceKobo <= 0) {
        uncostedItems += i.item.quantity;
      } else {
        costedRevenueKobo += lineRev;
        cogsKobo += i.item.quantity * i.item.buyingPriceKobo;
        skuSet.add(product.id);
      }
      // Rank top items by units sold across every identifiable product —
      // including ones with no recorded buying price. Truly ad-hoc lines (no
      // linked product) carry no SKU/name to rank, so they're omitted.
      if (product != null) {
        final cur = byProduct[product.id];
        byProduct[product.id] = (
          name: product.name,
          qty: (cur?.qty ?? 0) + i.item.quantity,
        );
      }
    }
    if (orderRevenue > 0) {
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
    salesPaidNowKobo += split.paidNow;
    salesOnCreditKobo += split.onCredit;
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
  final topItemsList = byProduct.entries
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
    if (damageForfeitsFullCrate(a.reason)) {
      crateDamageDepositKobo += units * (depositByMfr[p?.manufacturerId] ?? 0);
    }
  }
  // §17.2 crate-aware: a STORED empty damaged writes no stock_adjustment (no
  // drink lost) — only a `damaged` crate_ledger movement. Forfeit its deposit
  // here so the Statement still recognises the loss. The pool debit it also
  // makes is reflected separately in "Empty crates held" (the stock view), so
  // the period P&L (flow) and the held-empties asset (stock) never double-count
  // the same crate.
  for (final c in crateDamages) {
    if (c.voidedAt != null) continue;
    if (!inSpan(c.createdAt) || !inScope(c.storeId)) continue;
    final lostEmpties = -c.quantityDelta;
    if (lostEmpties <= 0) continue;
    crateDamageDepositKobo +=
        lostEmpties * (depositByMfr[c.manufacturerId] ?? 0);
  }

  // ── Stock audit + shortage value (latest count per store/date in span) ───
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
  final shortages = <ReconShortLine>[];
  for (final c in dayCounts) {
    if (!seenCount.add('${c.businessDate}|${c.storeId}')) continue;
    hasStockCount = true;
    productsCounted += c.productsCounted;
    shortageCount += c.shortageCount;
    shortageUnits += c.shortageUnits;
    surplusCount += c.surplusCount;
    surplusUnits += c.surplusUnits;
    for (final l
        in (jsonDecode(c.linesJson) as List).cast<Map<String, dynamic>>()) {
      final diff = (l['d'] as num).toInt();
      final p = productById[l['p'] as String?];
      if (diff > 0) {
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
  // #182 — value the count-shortage loss at the FIFO cost SNAPSHOTTED when the
  // count was saved (`stock_adjustments.value_kobo`, #170), NOT today's cost, so
  // a later product-cost edit can't restate a past period's shortage/variance.
  // Mirrors the Damages loop above; units/lines/retail stay count-sourced. The
  // adjustment rows are the truth for the money — the count session's `linesJson`
  // carries no snapshot — so a deleted product's shortage keeps its value too.
  final shortageCostKobo = countShortageLossKobo(
    adjustments,
    productById: productById,
    inSpan: inSpan,
    inScope: inScope,
  );
  // #200 / US 20 — how many of those rows had NO snapshot and so were valued at
  // today's cost. Drives the report footnote that labels the fallback.
  final legacyValuedShortageRows = legacyValuedRowCount(
    countShortageRows(adjustments, inSpan: inSpan, inScope: inScope),
  );

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
  if (showCrates) {
    heldCrateDepositsKobo = input.heldCrateDepositsKobo;
    supplierCrateDebtKobo = input.supplierCrateDebtKobo;
    crateDeposits = input.crateDeposits;
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
  for (final o in orders) {
    final tripId = o.order.vanTripId;
    if (tripId == null) continue;
    if (!orderCountsAsSale(o.order.status) || !inSpan(o.order.createdAt)) {
      continue;
    }
    final trip = tripById[tripId];
    if (trip == null || !inScope(trip.sourceStoreId)) continue;
    // The order's own net is the road-takings figure the trip reconciles
    // against (`watchSoldValueKoboForTrip` uses the same basis), and a road
    // sale carries no discount in v1.
    vanSalesKobo += o.order.netAmountKobo;
    // "Open in the period": still open, or closed only AFTER this period ended
    // — the month-straddling case (spec §9.4 #18). Revenue lands in the ring
    // month, profit in the close month, and the caveat says so.
    final closedAfterPeriod =
        trip.closedAt == null ||
        (endExclusive != null && !trip.closedAt!.isBefore(endExclusive));
    if (closedAfterPeriod) {
      vanOpenRevenueKobo += o.order.netAmountKobo;
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

// ── Persisted day close (#174, PRD #155, ADR 0021 §2) ────────────────────────

/// Maps the computed [ReconData] onto the frozen figure set a `daily_closings`
/// snapshot persists (#174). ONE place defines WHICH figures a day close freezes,
/// so the write (`DailyClosingsDao.snapshotIfAbsent`) and the delta badges
/// ([reconClosingComparison]) can never drift apart. Only PERIOD-scoped figures
/// are frozen — the point-in-time "…now" figures (business worth, empties held,
/// on-hand) are deliberately excluded: they are meant to reflect the present, so
/// badging them against a past review would be noise, not signal.
///
/// **#147 adds NO van field here, deliberately.** The three van figures each
/// fail the test this set applies:
///
///  * **Van profit is already a persisted artifact.** `van_trips.profit_kobo`
///    is frozen at close and a restatement is already visible (`restated_at`
///    plus an audit row). Freezing a second copy in `daily_closings` would put
///    the same settled number in two places — the "two queues, two opinions"
///    failure ADR 0019 exists to avoid — and the delta badge would report a
///    restatement that the trip row already discloses better.
///  * **Van revenue on an open trip is EXPECTED to move.** That is what the
///    caveat line says out loud. Badging it as "changed since review" would
///    turn a designed behaviour into a recurring alarm.
///  * **Cash from drivers needs no new field**: it is inside [ReconData.cashInKobo]
///    and [ReconData.netCashMovementKobo], both of which are already frozen
///    here — so a remittance that lands after a day was reviewed badges the
///    cash card exactly like any other late cash movement, with no schema
///    change and no migration.
DailyClosingFigures dailyClosingFiguresFrom(ReconData d) => DailyClosingFigures(
  // #176 — freeze the unified NET headline (item lines − discounts), so the
  // Sales-card delta badge compares the SAME "Total Sales" the card displays.
  totalSalesKobo: d.totalSalesKobo,
  refundsKobo: d.refundsKobo,
  discountsKobo: d.discountsKobo,
  cogsKobo: d.cogsKobo,
  grossProfitKobo: d.grossProfitKobo,
  netProfitKobo: d.netProfitKobo,
  expensesKobo: d.expensesKobo,
  damagesCostKobo: d.damageCostKobo,
  cashSalesKobo: d.cashSalesKobo,
  cashInKobo: d.cashInKobo,
  cashOutKobo: d.cashOutKobo,
  netCashMovementKobo: d.netCashMovementKobo,
  stockCogsKobo: d.stockCogsKobo,
  stockExpectedClosingKobo: d.stockExpectedClosingKobo,
  itemsSold: d.itemsSold,
  shortageUnits: d.shortageUnits,
);

/// One reconciliation card's AS-REVIEWED vs CURRENT figure, for the persisted
/// day-close delta badge (#174). [reviewed] is the frozen snapshot value;
/// [current] is the live recomputed value. A non-zero [delta] means the day's
/// figure moved AFTER it was reviewed — a late sync, a cancel, a backdated entry
/// — so the card shows the badge; an unchanged figure shows none.
class ReconFigureDelta {
  const ReconFigureDelta({required this.reviewed, required this.current});
  final int reviewed;
  final int current;
  int get delta => current - reviewed;
  bool get changed => delta != 0;
}

/// The as-reviewed-vs-current comparison between a persisted `daily_closings`
/// snapshot and the live figures recomputed for the same finished day (#174).
///
/// **Covers the WHOLE frozen figure set (#192).** [dailyClosingFiguresFrom]
/// freezes sixteen figures; until #192 only four of them were ever compared, so a
/// day whose expenses, refunds or damages moved after review read as unchanged on
/// every surface that asked. The rule is now mechanical — one delta per frozen
/// column, in the same order — so adding a figure to the frozen set and forgetting
/// to compare it is no longer possible without leaving a hole visible in this
/// class.
///
/// Which of them a viewer is actually SHOWN is a separate question the screen
/// answers per card and per role (the §25.3 cost wall): see [all] and
/// `daily_reconciliation_detail_screen.dart`. Comparing a figure is cheap and
/// honest; rendering it to someone who may not see cost is not.
///
/// Built by [reconClosingComparisonOrNull] for any FINISHED Day bucket that has a
/// snapshot, at EVERY viewing scope. Both sides are BUSINESS-WIDE (#191, ADR
/// 0022): the snapshot froze the whole business's day, so the live side is the
/// `businessWide: true` compute — never the viewer's store-scoped figures, which
/// would badge a scope difference as if history had moved.
class ReconClosingComparison {
  const ReconClosingComparison({
    required this.reviewedAt,
    required this.reviewedBy,
    required this.totalSales,
    required this.refunds,
    required this.discounts,
    required this.cogs,
    required this.grossProfit,
    required this.netProfit,
    required this.expenses,
    required this.damagesCost,
    required this.cashSales,
    required this.cashIn,
    required this.cashOut,
    required this.netCashMovement,
    required this.stockCogs,
    required this.stockExpectedClosing,
    required this.itemsSold,
    required this.shortageUnits,
  });

  final DateTime reviewedAt;
  final String? reviewedBy;

  // ── Money figures, in `DailyClosingFigures` order ────────────────────────
  final ReconFigureDelta totalSales; // Sales summary card
  final ReconFigureDelta refunds; // Sales summary card
  final ReconFigureDelta discounts; // Profit & Loss card (CEO)
  final ReconFigureDelta cogs; // Profit & Loss card (CEO)
  final ReconFigureDelta grossProfit; // Profit & Loss card (CEO)
  final ReconFigureDelta netProfit; // Profit & Loss card (CEO)
  final ReconFigureDelta expenses; // P&L (CEO) / Debts & expenses (Manager)
  final ReconFigureDelta damagesCost; // Profit & Loss card (CEO)
  final ReconFigureDelta cashSales; // Cash flow card (CEO)
  final ReconFigureDelta cashIn; // Cash flow card (CEO)
  final ReconFigureDelta cashOut; // Cash flow card (CEO)
  final ReconFigureDelta netCashMovement; // Cash flow card (CEO)
  final ReconFigureDelta stockCogs; // Stock reconciliation card (CEO)
  final ReconFigureDelta stockExpectedClosing; // Stock reconciliation card (CEO)

  // ── Unit counts (never money — safe to show behind the cost wall) ────────
  final ReconFigureDelta itemsSold; // Sales summary card
  final ReconFigureDelta shortageUnits; // Stock card, both roles

  /// The figures derivable from the day's OWN rows alone — every frozen figure
  /// except [stockExpectedClosing].
  ///
  /// Expected closing is reconstructed by rewinding every stock movement recorded
  /// at or after the period end from the CURRENT on-hand figure, so it is the one
  /// frozen figure that cannot be recomputed from a single day's rows. The
  /// reconciliation LIST sweep ([changedReviewedDaysProvider]) feeds each day only
  /// its own rows — that is what keeps the sweep one pass over the data instead of
  /// one full pass per reviewed day — so it asks [anyDayLocalChanged], and the
  /// day's own detail screen (which computes the real thing) asks [anyChanged].
  ///
  /// Listed out rather than filtered out of [all]: matching a member by identity
  /// would be at the mercy of `const` canonicalisation collapsing two equal
  /// deltas into one object, and silently exclude the wrong figure.
  List<ReconFigureDelta> get dayLocal => [
    totalSales,
    refunds,
    discounts,
    cogs,
    grossProfit,
    netProfit,
    expenses,
    damagesCost,
    cashSales,
    cashIn,
    cashOut,
    netCashMovement,
    stockCogs,
    itemsSold,
    shortageUnits,
  ];

  bool get anyDayLocalChanged => dayLocal.any((d) => d.changed);

  /// Every compared figure — [dayLocal] plus the one figure only a full compute
  /// can answer for — so a caller can ask a question about the whole frozen set
  /// without re-listing it (and drifting from it).
  List<ReconFigureDelta> get all => [...dayLocal, stockExpectedClosing];

  /// True when ANY frozen figure has moved since the review — the day changed
  /// after it was banked against.
  bool get anyChanged => all.any((d) => d.changed);
}

/// Builds the as-reviewed-vs-current comparison from a persisted [snapshot] and
/// the [live] figures for the same finished day (#174). Pure over its two inputs
/// so the delta math is unit-testable without a widget.
///
/// One entry per frozen column (#192) — read it side by side with
/// [dailyClosingFiguresFrom], which is the write half of the same list.
ReconClosingComparison reconClosingComparison(
  DailyClosingData snapshot,
  ReconData live,
) => ReconClosingComparison(
  reviewedAt: snapshot.reviewedAt,
  reviewedBy: snapshot.reviewedBy,
  totalSales: ReconFigureDelta(
    reviewed: snapshot.totalSalesKobo,
    current: live.totalSalesKobo, // #176 — net headline, matches the frozen basis
  ),
  refunds: ReconFigureDelta(
    reviewed: snapshot.refundsKobo,
    current: live.refundsKobo,
  ),
  discounts: ReconFigureDelta(
    reviewed: snapshot.discountsKobo,
    current: live.discountsKobo,
  ),
  cogs: ReconFigureDelta(reviewed: snapshot.cogsKobo, current: live.cogsKobo),
  grossProfit: ReconFigureDelta(
    reviewed: snapshot.grossProfitKobo,
    current: live.grossProfitKobo,
  ),
  netProfit: ReconFigureDelta(
    reviewed: snapshot.netProfitKobo,
    current: live.netProfitKobo,
  ),
  expenses: ReconFigureDelta(
    reviewed: snapshot.expensesKobo,
    current: live.expensesKobo,
  ),
  damagesCost: ReconFigureDelta(
    reviewed: snapshot.damagesCostKobo,
    current: live.damageCostKobo,
  ),
  cashSales: ReconFigureDelta(
    reviewed: snapshot.cashSalesKobo,
    current: live.cashSalesKobo,
  ),
  cashIn: ReconFigureDelta(
    reviewed: snapshot.cashInKobo,
    current: live.cashInKobo,
  ),
  cashOut: ReconFigureDelta(
    reviewed: snapshot.cashOutKobo,
    current: live.cashOutKobo,
  ),
  netCashMovement: ReconFigureDelta(
    reviewed: snapshot.netCashMovementKobo,
    current: live.netCashMovementKobo,
  ),
  stockCogs: ReconFigureDelta(
    reviewed: snapshot.stockCogsKobo,
    current: live.stockCogsKobo,
  ),
  stockExpectedClosing: ReconFigureDelta(
    reviewed: snapshot.stockExpectedClosingKobo,
    current: live.stockExpectedClosingKobo,
  ),
  itemsSold: ReconFigureDelta(
    reviewed: snapshot.itemsSold,
    current: live.itemsSold,
  ),
  shortageUnits: ReconFigureDelta(
    reviewed: snapshot.shortageUnits,
    current: live.shortageUnits,
  ),
);

/// The comparison a reconciliation view renders its reviewed banner + delta
/// badges from — null when the day has no snapshot (it was never reviewed), so
/// an unreviewed day renders exactly as it did before #174.
///
/// **Not gated on the snapshot's store scope (#191, ADR 0022).** A day close is
/// business-wide and first-writer-wins, so [businessWideLive] must be the
/// `businessWide: true` compute and the badges show at EVERY viewing scope. The
/// legacy `store_scope_id` column — non-null on rows frozen before #191, which
/// is why All Stores went permanently badge-blind for them — is deliberately
/// never read: treating it as business-wide makes the fix retroactive, with no
/// production data change.
ReconClosingComparison? reconClosingComparisonOrNull(
  DailyClosingData? snapshot,
  ReconData businessWideLive,
) => snapshot == null
    ? null
    : reconClosingComparison(snapshot, businessWideLive);

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
    (o) => [o.order.createdAt],
    wanted,
  );
  final expensesByDay = _byCandidateDay<ExpenseWithCategory>(
    ref.watch(allExpensesProvider).valueOrNull ?? const [],
    (e) => [e.expense.expenseDate, e.expense.createdAt],
    wanted,
  );
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
