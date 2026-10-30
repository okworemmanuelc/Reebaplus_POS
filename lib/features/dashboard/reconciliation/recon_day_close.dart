part of 'recon_data.dart';

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
