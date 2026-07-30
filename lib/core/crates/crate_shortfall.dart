/// The **Crate Shortfall** — the loss side of the supplier crate loop (#216,
/// PRD #203, ADR 0023 rules 4 and 5).
///
/// A Shortfall is the gap between the crates we owe suppliers and the empties
/// actually standing in the yard, valued at the manufacturer's rate. Two things
/// about it are decisions, not implementation details, and both are enforced by
/// the shapes in this file rather than by prose:
///
/// **1. It is BRAND-level and deliberately unattributed.** Crates are fungible.
/// Hold 100 Coke crates from Depot A and 100 from Depot B, lose ten, and
/// nothing on earth says whose they were. Guessing — oldest-first, pro-rata —
/// manufactures a number the supplier will dispute, and a pro-rata split moves
/// one supplier's balance whenever an unrelated supplier's count changes. So
/// [CrateShortfall] carries a `manufacturerId` and **no `supplierId`**: there is
/// no field for an attribution to be written into. Attribution happens exactly
/// once, at settlement, when the business actually comes up short with a
/// specific supplier.
///
/// **2. It is a WARNING, not a booked loss.** Crates turn up behind the store, a
/// driver returns late, a count was wrong. So a Shortfall never touches profit
/// by itself, and it **shrinks by itself when crates reappear** — because it is
/// derived from today's counts every time it is read, never stored as an
/// absolute. What IS stored is the [CrateShortfallWriteOff]: the deliberate,
/// dated, attributed act of accepting the loss. That is the same reasoning ADR
/// 0019 used to make a van write-off a persisted decision rather than a screen
/// calculation — a settlement outcome someone decided at a moment in time must
/// not be re-derived later, or a subsequent count silently restates it.
///
/// **Nothing here writes off on a timer.** There is no age input, no staleness
/// threshold and no expiry: an open shortfall of any age reads the same. Profit
/// must never be reduced by a decision nobody made.
///
/// The arithmetic reads through [computeCrateDepositPosition] — the ONE seam
/// (#212) — rather than subtracting counts itself, so the shortfall the card
/// shows and the shortfall the supplier screen implies cannot fork into two
/// disagreeing numbers. There is no `AppDatabase` in this file's imports and
/// there never may be.
library;

import 'package:reebaplus_pos/core/crates/crate_deposit_position.dart';
import 'package:reebaplus_pos/core/crates/crate_money_arrangement.dart';

// ── The persisted decision ───────────────────────────────────────────────────

/// One row of `crate_shortfall_writeoffs`, reduced to the four fields the
/// arithmetic needs.
///
/// [ratePerCrateKobo] is SNAPSHOTTED at the moment the write-off is taken. A
/// deposit rate edited next month must not restate the profit of a day already
/// closed (ADR 0021), and the loss booked is `crateCount × ratePerCrateKobo`
/// forever after — never `crateCount × today's rate`.
///
/// [crateCount] is signed. A write-off is positive; the **compensating row** for
/// a write-off taken in error, or for crates that turned up after being written
/// off, is negative. It is never an edit and never a delete: the ledger is
/// append-only, and a reversal books a GAIN on the day it is decided rather than
/// rewriting the day the loss was accepted.
class CrateShortfallWriteOff {
  final String manufacturerId;

  /// + = crates accepted as lost; − = a compensating reversal.
  final int crateCount;

  /// The rate the loss was valued at, snapshotted when the decision was taken.
  final int ratePerCrateKobo;

  /// The day the decision was taken — the day the loss hits profit.
  final DateTime writtenOffAt;

  const CrateShortfallWriteOff({
    required this.manufacturerId,
    required this.crateCount,
    required this.ratePerCrateKobo,
    required this.writtenOffAt,
  });

  /// The money this decision books, at the snapshotted rate.
  int get valueKobo => crateCount * ratePerCrateKobo;
}

// ── The derived warning ──────────────────────────────────────────────────────

/// One brand's crate shortfall at a moment in time — **across every supplier of
/// that brand**, which is the only scope at which the question is honest.
class CrateShortfall {
  final String manufacturerId;
  final String manufacturerName;

  /// The brand's arrangement. `none` forces every figure here to 0 — see
  /// [computeCrateShortfall].
  final CrateMoneyArrangement arrangement;

  /// `manufacturers.deposit_amount_kobo` (ADR 0023 rule 2).
  final int ratePerCrateKobo;

  /// Empties we owe EVERY supplier of this brand: `SUM(quantity_delta)` over
  /// the whole brand's `supplier_crate_ledger`.
  final int cratesOwed;

  /// Empties physically in the yard for this brand, business-wide.
  final int emptiesOnHand;

  /// The raw gap, straight out of [computeCrateDepositPosition]:
  /// `cratesOwed − emptiesOnHand`, floored at 0. **This is the figure that
  /// shrinks by itself** — hand back crates and `cratesOwed` falls; find crates
  /// and `emptiesOnHand` rises. Either way the gap closes with nobody deciding
  /// anything.
  final int rawShortfallCrates;

  /// The net of every write-off decision ever taken on this brand (positive
  /// write-offs minus any compensating reversals). A count, not money: the money
  /// each decision booked was fixed at ITS OWN snapshotted rate on ITS OWN day,
  /// and is not recoverable from a rate multiplied by this total.
  final int writtenOffCrates;

  /// **What is still open** — the warning an owner has not yet dealt with:
  /// `rawShortfallCrates − writtenOffCrates`, floored at 0.
  ///
  /// Floored, because a brand whose crates reappear after a write-off does not
  /// become owed a negative shortfall. The write-off already hit profit on its
  /// own day and stays there (ADR 0021 — a settled day is never restated); the
  /// reappearance is simply an open shortfall of zero from then on.
  final int openShortfallCrates;

  /// [openShortfallCrates] at [ratePerCrateKobo] — the warning in money.
  final int openShortfallValueKobo;

  /// When the most recent write-off on this brand was taken, and by whom. Null
  /// until somebody accepts a loss. Carried so the card can answer "who wrote
  /// off a shortage and when" without a second query.
  final DateTime? lastWrittenOffAt;
  final String? lastWrittenOffBy;

  const CrateShortfall({
    required this.manufacturerId,
    required this.manufacturerName,
    required this.arrangement,
    required this.ratePerCrateKobo,
    required this.cratesOwed,
    required this.emptiesOnHand,
    required this.rawShortfallCrates,
    required this.writtenOffCrates,
    required this.openShortfallCrates,
    required this.openShortfallValueKobo,
    this.lastWrittenOffAt,
    this.lastWrittenOffBy,
  });

  /// True when there is still a gap nobody has dealt with.
  bool get isOpen => openShortfallCrates > 0;

  /// True when somebody has accepted a loss on this brand at some point.
  bool get hasWriteOff => writtenOffCrates != 0;
}

/// Compute one brand's shortfall from plain data.
///
/// [cratesOwed] and [emptiesOnHand] **must both be summed over the same
/// brand-level scope** — every supplier of the brand, and the business-wide
/// yard. #212 made `emptiesOnHand` nullable on [computeCrateDepositPosition]
/// precisely so that mixing a pair-keyed `cratesOwed` with a business-wide
/// empties count is unrepresentable rather than merely discouraged; this
/// function is the caller that legitimately has both at brand level, so it is
/// the only place in the app that passes the argument at all.
///
/// **A `none` brand reads all zeros.** The short-circuit lives inside
/// [computeCrateDepositPosition] (a shortfall is the money-at-risk warning of
/// rules 4 and 5, and a swap-only brand has no money at risk), and the
/// write-off total is suppressed here for the same reason: residue from a brand
/// that was switched on, used, then switched back off must never move a figure
/// for an owner who has said "this brand does not move money". The rows are not
/// deleted and reappear intact the moment the brand is switched on again. That
/// is the release gate for the whole of PRD #203, and it is why an all-`none`
/// business reads byte-identical figures with this slice in place.
///
/// The physical crate counts a `none` brand does carry are unchanged and still
/// read from the crate screens they always did.
CrateShortfall computeCrateShortfall({
  required String manufacturerId,
  required String manufacturerName,
  required CrateMoneyArrangement arrangement,
  required int ratePerCrateKobo,
  required int cratesOwed,
  required int emptiesOnHand,
  int writtenOffCrates = 0,
  DateTime? lastWrittenOffAt,
  String? lastWrittenOffBy,
}) {
  // THE seam. The gap is not subtracted here — it is asked of the one function
  // every other crate-money figure is asked of, so the card, the supplier
  // screen and this warning cannot drift (ADR 0023 finding #3).
  final position = computeCrateDepositPosition(
    arrangement: arrangement,
    ratePerCrateKobo: ratePerCrateKobo,
    cratesOwed: cratesOwed,
    emptiesOnHand: emptiesOnHand,
  );

  final moves = arrangement.movesMoney;
  final rawShortfallCrates = position.shortfallCrates;
  final netWrittenOff = moves ? writtenOffCrates : 0;
  final open = _max0(rawShortfallCrates - netWrittenOff);

  return CrateShortfall(
    manufacturerId: manufacturerId,
    manufacturerName: manufacturerName,
    arrangement: arrangement,
    ratePerCrateKobo: position.ratePerCrateKobo,
    cratesOwed: moves ? cratesOwed : 0,
    emptiesOnHand: moves ? emptiesOnHand : 0,
    rawShortfallCrates: rawShortfallCrates,
    writtenOffCrates: netWrittenOff,
    openShortfallCrates: open,
    openShortfallValueKobo: open * position.ratePerCrateKobo,
    lastWrittenOffAt: moves ? lastWrittenOffAt : null,
    lastWrittenOffBy: moves ? lastWrittenOffBy : null,
  );
}

// ── The business-wide roll-up ────────────────────────────────────────────────

/// Every brand's open shortfall at once — the point-in-time warning the
/// reconciliation card renders beside #215's Placed Deposit figures.
///
/// Business-wide with no store axis, exactly like [CrateDepositRollup] and for
/// the same reason: supplier crate money is a company obligation, and splitting
/// it per store would repeat the defect `CRATE_TRACKING_AUDIT` C4 names.
class CrateShortfallRollup {
  /// One entry per brand with an OPEN shortfall, biggest money first. A brand
  /// that is square, or whose shortfall has been fully written off, is dropped
  /// rather than listed at zero — a warning list of non-warnings trains an
  /// owner to ignore it.
  final List<CrateShortfall> brands;

  /// Crates missing across every brand, still open.
  final int openCrates;

  /// [openCrates] valued at each brand's own rate.
  final int openValueKobo;

  const CrateShortfallRollup({
    required this.brands,
    required this.openCrates,
    required this.openValueKobo,
  });

  /// What every business whose brands are all `none` reads — which is every
  /// live tenant until an owner deliberately switches a brand on.
  static const CrateShortfallRollup empty = CrateShortfallRollup(
    brands: [],
    openCrates: 0,
    openValueKobo: 0,
  );

  /// True when anything is missing that nobody has dealt with.
  bool get hasShortfall => openCrates > 0;
}

/// Roll [shortfalls] up into the business-wide warning.
///
/// Brands whose arrangement moves no money are dropped before anything else, so
/// a swap-only business rolls up to [CrateShortfallRollup.empty] no matter what
/// its crate counts say.
CrateShortfallRollup rollUpCrateShortfalls(List<CrateShortfall> shortfalls) {
  final open = shortfalls
      .where((s) => s.arrangement.movesMoney && s.isOpen)
      .toList();
  if (open.isEmpty) return CrateShortfallRollup.empty;

  var openCrates = 0;
  var openValueKobo = 0;
  for (final s in open) {
    openCrates += s.openShortfallCrates;
    openValueKobo += s.openShortfallValueKobo;
  }

  // Biggest loss first — the brand costing the owner the most is the one they
  // will go looking behind the store for.
  open.sort((a, b) {
    final byMoney = b.openShortfallValueKobo.compareTo(a.openShortfallValueKobo);
    return byMoney != 0
        ? byMoney
        : a.manufacturerName.compareTo(b.manufacturerName);
  });

  return CrateShortfallRollup(
    brands: open,
    openCrates: openCrates,
    openValueKobo: openValueKobo,
  );
}

// ── The booked loss ──────────────────────────────────────────────────────────

/// **The one figure in PRD #203 that genuinely hits profit** (ADR 0023 rule 5):
/// the write-off decisions taken inside `[start, endExclusive)`, valued at the
/// rate each was snapshotted with.
///
/// Everything else the PRD books is a Placed Deposit — an asset that changed
/// shape, refundable, and therefore never a cost. A write-off is the opposite:
/// it is the moment an owner says the crates are not coming back, so the money
/// standing behind them is gone. It is a realized loss and it belongs in the
/// period's profit exactly like `crateDamageDepositKobo` does.
///
/// **Dated by decision, not by discovery.** The filter is on
/// [CrateShortfallWriteOff.writtenOffAt], so a shortfall that opened in March
/// and was accepted in July reduces JULY's profit. That is the point of
/// persisting the decision: the loss lands on the day somebody took
/// responsibility for it, and no later count moves it (ADR 0021).
///
/// A brand whose [arrangementByManufacturerId] entry does not move money
/// contributes nothing — the same release gate as everywhere else. A brand
/// missing from the map is treated as `none` (fail closed): an unreadable
/// arrangement must never book a loss.
int crateShortfallWriteOffKobo({
  required Iterable<CrateShortfallWriteOff> writeOffs,
  required Map<String, CrateMoneyArrangement> arrangementByManufacturerId,
  DateTime? start,
  DateTime? endExclusive,
}) {
  var total = 0;
  for (final w in writeOffs) {
    final arrangement =
        arrangementByManufacturerId[w.manufacturerId] ??
        CrateMoneyArrangement.none;
    if (!arrangement.movesMoney) continue;
    if (start != null && w.writtenOffAt.isBefore(start)) continue;
    if (endExclusive != null && !w.writtenOffAt.isBefore(endExclusive)) continue;
    total += w.valueKobo;
  }
  return total;
}

int _max0(int v) => v > 0 ? v : 0;
