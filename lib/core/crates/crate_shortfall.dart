/// **Booked crate losses** — the rows of `crate_shortfall_writeoffs` and the
/// money they put into profit (#216, #217, #296; ADR 0023 rule 5, PRD #284
/// decision 7).
///
/// A write-off is a persisted decision, dated by when it was taken and valued
/// at the crate value SNAPSHOTTED on the row, so no later count or crate value
/// change restates it (ADR 0021). A reversal is a compensating negative row
/// booked on its own day.
///
/// The warning a write-off answers is the count-based Crate Shortage
/// (`crate_shortage.dart`). The depot-gap Crate Shortfall this file used to
/// derive was retired by PRD #284; its `manual` rows stay booked in their
/// periods.
///
/// Nothing here writes off on a timer. Profit is never reduced by a decision
/// nobody made. There is no `AppDatabase` in this file's imports.
library;

import 'package:reebaplus_pos/core/crates/crate_money_arrangement.dart';

// ── Where a write-off came from (#217) ───────────────────────────────────────

/// Somebody stood in front of the depot-gap Crate Shortfall card and accepted
/// the loss (#216). Retired by PRD #284: nothing writes these any more, and the
/// rows already booked stay on their own days.
const String kCrateWriteOffSourceManual = 'manual';

/// The shortfall a **customer forfeit** raises automatically (#217).
///
/// When a customer never brings the crates back, the business keeps their
/// deposit — booked as income since #176. But on a brand where a deposit was
/// genuinely placed with a depot, that crate is one the business now cannot
/// hand back, and the app charged the customer the *same*
/// `manufacturers.deposit_amount_kobo` it owes the supplier. So the gain and
/// the loss are the same size and the forfeit nets to **zero**.
///
/// This is not a "decision nobody made" of the kind rule 5 forbids. Nothing
/// fires on a timer and nothing sweeps old shortfalls: the row is written in the
/// same transaction as the forfeit itself, by the person who settled it, about
/// crates that demonstrably left with a customer who paid for them. It is the
/// second half of one event, not a later opinion about it.
const String kCrateWriteOffSourceCustomerForfeit = 'customer_forfeit';

/// A write-off taken against the **count-based Crate Shortage** (PRD #284
/// decision 7): crates found missing at a count, for every brand whatever its
/// arrangement. Written from #296 on. The older [kCrateWriteOffSourceManual]
/// and [kCrateWriteOffSourceCustomerForfeit] rows are history only and never
/// net against this figure.
const String kCrateWriteOffSourceCountShortage = 'count_shortage';

/// The closed set `crate_shortfall_writeoffs.source` may hold. Mirrors the cloud
/// CHECK in `supabase/migrations/0179_crate_count_movements.sql` (first issued
/// by 0176).
const List<String> kCrateWriteOffSources = [
  kCrateWriteOffSourceManual,
  kCrateWriteOffSourceCustomerForfeit,
  kCrateWriteOffSourceCountShortage,
];

/// How a booked crate loss came to be booked.
enum CrateWriteOffSource {
  /// An owner accepted it on the Crate Shortfall card.
  manual(kCrateWriteOffSourceManual),

  /// A customer kept the crates and their deposit with them (#217).
  customerForfeit(kCrateWriteOffSourceCustomerForfeit),

  /// Crates found missing at a count were accepted as lost (PRD #284).
  countShortage(kCrateWriteOffSourceCountShortage);

  const CrateWriteOffSource(this.wire);

  /// The stored string.
  final String wire;
}

/// Read a stored `source`, **failing closed to [CrateWriteOffSource.manual]**.
///
/// The opposite direction of travel from [crateMoneyArrangementOf], and for the
/// same reason read backwards: every value here books the same money, so an
/// unreadable one must not vanish from the P&L. It lands in the bucket an owner
/// is asked to explain by hand, which is the loud outcome, not the quiet one.
CrateWriteOffSource crateWriteOffSourceOf(String? wire) {
  for (final s in CrateWriteOffSource.values) {
    if (s.wire == wire) return s;
  }
  return CrateWriteOffSource.manual;
}

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

  /// The store the decision was taken at. Scopes a `count_shortage` row, which
  /// answers one store's count; older sources are business-wide.
  final String? storeId;

  /// + = crates accepted as lost; − = a compensating reversal.
  final int crateCount;

  /// The rate the loss was valued at, snapshotted when the decision was taken.
  final int ratePerCrateKobo;

  /// The day the decision was taken — the day the loss hits profit.
  final DateTime writtenOffAt;

  /// Where the decision came from (#217). Display and disclosure only: BOTH
  /// sources book the same loss on the same line, because a crate that is not
  /// coming back costs the same whether an owner accepted it on a card or a
  /// customer drove off with it. What the split buys is the owner-facing
  /// sentence — "this much of it is deposits customers kept" — which is the
  /// difference between a figure that reads as a bug and one that reads as an
  /// explanation.
  final CrateWriteOffSource source;

  const CrateShortfallWriteOff({
    required this.manufacturerId,
    this.storeId,
    required this.crateCount,
    required this.ratePerCrateKobo,
    required this.writtenOffAt,
    this.source = CrateWriteOffSource.manual,
  });

  /// The money this decision books, at the snapshotted rate.
  int get valueKobo => crateCount * ratePerCrateKobo;
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
/// A `manual` or `customer_forfeit` row on a brand whose
/// [arrangementByManufacturerId] entry does not move money contributes nothing
/// — the #203 release gate. A brand missing from the map is treated as `none`
/// (fail closed). A `count_shortage` row books for every brand (PRD #284
/// decision 7) and is kept only when [inScope] accepts its store.
///
/// [onlySource] narrows the total to one origin (#217) — for DISCLOSURE ONLY.
/// The P&L reads the unfiltered total; the reconciliation card uses the
/// `customerForfeit` slice to tell the owner, in words, why a kept deposit
/// stopped showing up as profit.
int crateShortfallWriteOffKobo({
  required Iterable<CrateShortfallWriteOff> writeOffs,
  required Map<String, CrateMoneyArrangement> arrangementByManufacturerId,
  DateTime? start,
  DateTime? endExclusive,
  CrateWriteOffSource? onlySource,
  bool Function(String? storeId)? inScope,
}) {
  var total = 0;
  for (final w in writeOffs) {
    if (w.source == CrateWriteOffSource.countShortage) {
      // A counted shortage is a crate the business owned and lost, whatever
      // the brand's arrangement (PRD #284 decision 7), and it belongs to the
      // store whose count found it.
      if (inScope != null && !inScope(w.storeId)) continue;
    } else {
      final arrangement =
          arrangementByManufacturerId[w.manufacturerId] ??
          CrateMoneyArrangement.none;
      if (!arrangement.movesMoney) continue;
    }
    if (onlySource != null && w.source != onlySource) continue;
    if (start != null && w.writtenOffAt.isBefore(start)) continue;
    if (endExclusive != null && !w.writtenOffAt.isBefore(endExclusive)) continue;
    total += w.valueKobo;
  }
  return total;
}

// ── The forfeit netting (#217, ADR 0023 finding #4 and rule 5) ───────────────

/// **How many crates a customer forfeit takes out of the yard for good** — and
/// therefore the size of the Shortfall that forfeit raises.
///
/// The whole of slice #217 is this one decision, and it is a pure function of
/// two facts so that the moment of truth is testable without a database and
/// impossible to re-derive differently somewhere else:
///
///   * **[arrangement] moves money** — a deposit was genuinely placed with a
///     depot for these crates, so a crate that never comes back is money the
///     business will not get back either. The forfeit nets to zero.
///   * **[arrangement] is `none`** — nobody was ever paid a deposit for these
///     crates. They were the business's own to lose, so keeping the customer's
///     money is a REAL gain and it stays pure income, exactly as it read before
///     PRD #203 existed. This is the release gate, expressed as arithmetic.
///
/// The count is the crates KEPT, never the money. The money follows at the
/// manufacturer's rate snapshotted on the day (`CrateShortfallWriteOff`), which
/// is what makes a rate edited next month unable to restate a closed day.
///
/// **Nothing here consults a date.** Whether a past forfeit was netted is not a
/// question this function — or any report — ever asks: it is settled once, in
/// the same transaction as the forfeit, by whether a row was written at all.
/// That is the whole of the no-restatement guarantee, and it lives in the write
/// path rather than here on purpose. A reader that re-decided from today's
/// arrangement would rewrite last March's profit the moment a brand was
/// switched on, which ADR 0021 forbids outright.
int crateForfeitShortfallCrates({
  required CrateMoneyArrangement arrangement,
  required int keptCrates,
}) {
  if (!arrangement.movesMoney) return 0;
  return keptCrates > 0 ? keptCrates : 0;
}
