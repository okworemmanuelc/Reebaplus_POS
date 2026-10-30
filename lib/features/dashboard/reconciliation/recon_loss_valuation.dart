part of 'recon_data.dart';

/// Value a stock loss (damage / count-shortage / product-delete write-off) for
/// the P&L (#170 #7a). Prefers [snapshotValueKobo] — the FIFO cost the mutator
/// drew down and recorded AT WRITE TIME — so a later cost-price edit can never
/// restate a past loss. A legacy quantity-only row (written before #170) has no
/// snapshot, so it falls back to [units] × [currentCostKobo] (today's rate) —
/// the deliberately-labelled fallback. `null` current cost counts as 0.
int lossValueKobo(int? snapshotValueKobo, int units, int? currentCostKobo) =>
    snapshotValueKobo ?? (units * (currentCostKobo ?? 0));

/// Value an already-selected set of count-shortage rows from the #170
/// write-time snapshot (#182) — the deferral #170 left open (audit #30).
///
/// A stock count applies each shortage line through `InventoryDao.adjustStock`
/// with the reason "Daily stock count adjustment" (a decrease), which draws the
/// FIFO queue down oldest-first and records the drawn cost on the
/// `stock_adjustments` row (`value_kobo`). Summing those snapshots — exactly as
/// the Damages figure already does via [lossValueKobo] — means a later
/// product-cost edit can never restate a past period's shortage/variance figure.
/// Legacy quantity-only rows (written before #170, no snapshot) fall back to
/// current cost, per [lossValueKobo]. Surplus (a gain) draws down no queue and
/// carries no snapshot, so it stays current-cost in the caller.
///
/// **Selecting the rows is a separate decision from valuing them, and #186 moved
/// only the selection.** This reducer values whatever it is handed;
/// [countShortageRowsBySession] decides which rows a period's figure is built
/// from. Splitting the two is what let the basis change without touching the
/// valuation the #182 regression guard pins.
int countShortageRowsValueKobo(
  Iterable<StockAdjustmentData> rows, {
  required Map<String, ProductData> productById,
}) {
  var total = 0;
  for (final a in rows) {
    total += lossValueKobo(
      a.valueKobo,
      -a.quantityDiff,
      productById[a.productId]?.buyingPriceKobo,
    );
  }
  return total;
}

/// The count-reconciliation SHORTAGE rows inside [inSpan] + [inScope] — the one
/// definition of "which rows are a count shortage", so the money
/// ([countShortageRowsValueKobo]) and the footnote that discloses how it was
/// valued ([legacyValuedRowCount]) can never disagree about the row set they
/// describe. The `isCountReconciliationReason` guard is disjoint from
/// `isDamageReason`, so a shortage is never double-counted as a damage.
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

// ── Count shortage: one basis for the money and the units (#186) ─────────────
//
// The variance card reports ONE event — a daily stock count — as several
// figures, and until #186 they stood on two different bases. The money
// ([ReconData.shortageCostKobo]) summed EVERY count-reconciliation
// `stock_adjustments` row in the period, filtered on the row's `created_at` and
// not deduped; the units, retail value, per-product lines and products-counted
// came from the count SESSION, deduped to the LATEST session per
// `businessDate|storeId` and filtered on `businessDate`. Two ways for one card
// to contradict itself:
//
//  1. **Same-day recount.** Every Save Count writes a fresh adjustment row per
//     changed line (`stock_count_screen.dart`), so a day counted twice
//     accumulated money from both saves while the units showed only the latest.
//     A recount that came out matching still raised an integrity flag, over
//     money the latest count says is not missing.
//  2. **Backdated / day-boundary count.** A count saved after midnight, or for
//     a past day, put its units in the `businessDate` period and its money in
//     the `created_at` one — two periods each reporting half the event.
//
// **Decision (#186): the money follows the units — latest deduped session,
// bucketed on `businessDate`.** Recorded in ADR 0014's 2026-07-30 addendum. The
// short form of the reasoning: it is the only basis under which a matching
// latest count reads zero variance; `surplusCostKobo` is session-sourced and
// CANNOT move to the adjustment rows (a gain draws no batch, so there is no
// snapshot to sum), and `stockVarianceKobo` is `surplus − shortage`, so only a
// session-based shortage puts both halves of the subtraction on one basis; and
// `productsCounted` / `shortageCount` only a session knows at all. Cumulative
// shrinkage across every save of a day is not lost — it is the stock card's
// "Count corrections" line ([ReconData.stockCountAdjustmentsKobo]), which stays
// all-rows at current cost on purpose so the flow equation still ties out.
//
// What did NOT change: the money is still valued at the write-time FIFO
// snapshot (#182). Only which rows are summed moved.

/// Deliberately span-free attribution: a shortage row is placed by the SESSION
/// that wrote it, never by the reporting period. Filtering rows by the period
/// first is precisely what put a backdated count's money in a different period
/// from its units.
bool _anyTime(DateTime _) => true;

/// Which count SESSION wrote each count-reconciliation shortage row (#186),
/// keyed by `stock_counts.id`.
///
/// `stock_adjustments` carries **no `count_id`** — there is no stored link from
/// a shortage row back to the count that applied it, and adding one would be a
/// Drift + cloud migration for what is a reporting-basis question. The link is
/// recoverable from the write ORDER instead: `_saveCount` applies each changed
/// line through `InventoryDao.adjustStock` and only THEN calls
/// `StockCountsDao.recordCount` (`stock_count_screen.dart`), so every row a
/// session wrote carries a `created_at` at or before that session's own, and
/// after the previous session's. A row therefore belongs to the EARLIEST
/// session of its own store whose `created_at` is not before the row's.
///
/// **Known imperfections, all documented rather than papered over:**
///  * A save whose `recordCount` never ran (the mid-loop
///    `InsufficientStockException` path applies some lines, then throws) leaves
///    rows with no session of their own; they attach to the NEXT session for
///    that store. Dropping them instead would hide stock that really did move.
///  * Rows with no later session at all stay unattributed. That is the
///    consistent answer, not a leak: with no session there are no units either,
///    so both halves of the card stay silent together.
///  * Two saves inside the SAME second for one store (the clock is
///    second-resolution — both tables store epoch seconds) cannot be told
///    apart, and their rows all attach to the earlier session. A human keying a
///    second count cannot hit that; a test can, so tests stamp their own
///    timestamps.
///  * A session with a NULL `store_id` (legacy rows, and devices with no store
///    at all) owns nothing: `stock_adjustments.store_id` is NOT NULL, so no row
///    can match it. Such a session falls to [countSessionShortage]'s labelled
///    current-cost fallback.
///
/// [inScope] applies to both sides — a row and its session must each be in the
/// viewer's store scope, exactly as every other figure on the card is.
Map<String, List<StockAdjustmentData>> countShortageRowsBySession(
  Iterable<StockCountData> sessions,
  Iterable<StockAdjustmentData> adjustments, {
  required bool Function(String?) inScope,
}) {
  final byStore = <String?, List<StockCountData>>{};
  for (final c in sessions) {
    if (!inScope(c.storeId)) continue;
    (byStore[c.storeId] ??= <StockCountData>[]).add(c);
  }
  for (final list in byStore.values) {
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  final out = <String, List<StockAdjustmentData>>{};
  for (final a in countShortageRows(
    adjustments,
    inSpan: _anyTime,
    inScope: inScope,
  )) {
    final owner = _firstSessionAtOrAfter(byStore[a.storeId], a.createdAt);
    if (owner == null) continue;
    (out[owner.id] ??= <StockAdjustmentData>[]).add(a);
  }
  return out;
}

/// The first session in [sessions] (ascending by `createdAt`) whose `createdAt`
/// is not before [t] — a binary search, so attributing a shop's whole history
/// stays O(rows · log sessions) instead of a nested scan on a report screen.
StockCountData? _firstSessionAtOrAfter(
  List<StockCountData>? sessions,
  DateTime t,
) {
  if (sessions == null || sessions.isEmpty) return null;
  var lo = 0;
  var hi = sessions.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (sessions[mid].createdAt.isBefore(t)) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo < sessions.length ? sessions[lo] : null;
}

/// One count session's SHORTAGE money and the disclosure that goes with it
/// (#186) — the pair [ReconData.shortageCostKobo] and
/// [ReconData.legacyValuedShortageRows] are summed from, once per WINNING
/// session (the latest for its business date and store).
///
/// [attributedRows] are that session's rows from [countShortageRowsBySession];
/// they are valued at their write-time snapshot by [countShortageRowsValueKobo],
/// so #182 survives the basis change untouched.
///
/// **The fallback keeps money and units from ever disagreeing about PRESENCE.**
/// If no row could be attributed — a legacy session whose device never wrote
/// adjustments, a peer's session whose rows have not synced yet, a null-store
/// session — the session's own `linesJson` shortage lines are valued at current
/// cost and every one of them is counted as legacy-valued, so the report footnote
/// says out loud that this figure moves with the buying price (#200 / PRD #155
/// US 20). Silence would have been the worse answer: units short with ₦0 beside
/// them is the exact divergence #186 exists to end.
///
/// A shortage of genuinely uncosted stock still values at ₦0 with units above 0.
/// That is a valuation fact (nobody recorded what those units cost), not a basis
/// divergence, and it reads the same on the Damages line.
({int lossKobo, int legacyValuedRows}) countSessionShortage(
  StockCountData session, {
  required Iterable<StockAdjustmentData> attributedRows,
  required Map<String, ProductData> productById,
}) {
  final rows = attributedRows.toList();
  if (rows.isNotEmpty) {
    return (
      lossKobo: countShortageRowsValueKobo(rows, productById: productById),
      legacyValuedRows: legacyValuedRowCount(rows),
    );
  }
  var lossKobo = 0;
  var legacyValuedRows = 0;
  for (final l
      in (jsonDecode(session.linesJson) as List).cast<Map<String, dynamic>>()) {
    final diff = (l['d'] as num).toInt();
    if (diff >= 0) continue;
    final p = productById[l['p'] as String?];
    lossKobo += -diff * (p?.buyingPriceKobo ?? 0);
    legacyValuedRows++;
  }
  return (lossKobo: lossKobo, legacyValuedRows: legacyValuedRows);
}

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
