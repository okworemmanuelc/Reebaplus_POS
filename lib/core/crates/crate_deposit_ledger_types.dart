/// The vocabulary of the supplier crate-deposit money family (#212, PRD #203,
/// ADR 0023 rule 1).
///
/// **A Placed Deposit is its own money family.** It is never a `refund`, never
/// an `expense`, never a `void`. Paying a depot for their crates drops cash and
/// raises an ASSET of the same size, because the money is still ours — it is
/// refundable, so it must never touch profit. Booking it as an expense was
/// considered and rejected in ADR 0023: profit would sag on delivery days and
/// spike inexplicably on the day a supplier relationship ends.
///
/// Releasing held money in the wrong family is not a hypothetical. It is the
/// exact defect issues #190 and #201 had to fix on the CUSTOMER side, where a
/// deposit coming back was typed `refund` and so read as a flat loss in every
/// report while "deposits held" never netted down. This file exists so the
/// supplier side cannot repeat it: there is one payment type
/// ([kPaymentTypeCrateDepositOut]) and one ledger, and the closed sets below
/// are the only values either may hold.
///
/// The wire values mirror the cloud CHECK constraints in
/// `supabase/migrations/0172_placed_deposit.sql` and the Drift
/// `customConstraints` on `SupplierCrateDeposits` /
/// `SupplierCrateDepositRequests`.
library;

import 'package:reebaplus_pos/core/crates/crate_money_arrangement.dart';

// ── The payment family ───────────────────────────────────────────────────────

/// `payment_transactions.type` for every movement of supplier crate-deposit
/// money. ONE type covers all of PRD #203, because the sign carries the
/// direction — the same in-family reversal rule #190 established for the
/// customer leg.
///
/// **Positive = money went OUT of the drawer to the supplier** (a placement, a
/// standing-float top-up). **Negative = money came BACK to us** (a settlement,
/// a float payout).
///
/// Note the sign convention is the OPPOSITE drawer direction from the
/// customer-side `crate_deposit` type, where a positive row is cash coming IN.
/// That is not an inconsistency to tidy away: each type's positive direction is
/// the direction its *original* movement goes, and the reversal is its
/// negative. Read the type before you read the sign.
///
/// `payment_transactions.amount_kobo` carries no `>= 0` CHECK precisely so this
/// works (unlike `wallet_transactions` and `supplier_ledger_entries`, which do).
const String kPaymentTypeCrateDepositOut = 'crate_deposit_out';

// ── Ledger movement types (`supplier_crate_deposits.movement_type`) ──────────

/// Money placed with a supplier on a delivery (`per_delivery`, #212).
const String kCrateDepositMovementPlacement = 'placement';

/// Money coming back when empties are handed over (`per_delivery`, #213). The
/// amount is what was ACTUALLY refunded, which may be less than what was
/// placed — a depot that short-pays is a fact to record, not to argue with.
const String kCrateDepositMovementRelease = 'release';

/// A real top-up of a standing float (`standing_float`, #214).
const String kCrateDepositMovementFloatTopup = 'float_topup';

/// A real payout back out of a standing float (`standing_float`, #214).
const String kCrateDepositMovementFloatPayout = 'float_payout';

/// A correction. The ledger is append-only, so a correction is a new,
/// opposite-signed row — never an edit and never a delete.
const String kCrateDepositMovementAdjustment = 'adjustment';

/// The closed set `supplier_crate_deposits.movement_type` may hold.
///
/// **All five are declared now, in #212, on purpose.** `release` belongs to
/// #213 and the two float types to #214, but declaring the whole set up front
/// means those slices ship as code only: widening a CHECK on an append-only
/// money ledger costs a table rebuild on every device, and this is the v71
/// driver-ledger precedent for avoiding one.
const List<String> kCrateDepositMovementTypes = [
  kCrateDepositMovementPlacement,
  kCrateDepositMovementRelease,
  kCrateDepositMovementFloatTopup,
  kCrateDepositMovementFloatPayout,
  kCrateDepositMovementAdjustment,
];

/// True when [movementType] moves money OUT to the supplier (so a positive
/// amount is expected). The remaining money-moving types bring money back.
bool crateDepositMovementIsOutward(String movementType) =>
    movementType == kCrateDepositMovementPlacement ||
    movementType == kCrateDepositMovementFloatTopup;

// ── Request kinds (`supplier_crate_deposit_requests.kind`) ───────────────────

/// The four money legs a request may ask a money-permitted role to approve.
/// The same vocabulary as the ledger, minus `adjustment` — a correction is
/// posted directly by whoever is already allowed to post money, never queued.
const List<String> kCrateDepositRequestKinds = [
  kCrateDepositMovementPlacement,
  kCrateDepositMovementRelease,
  kCrateDepositMovementFloatTopup,
  kCrateDepositMovementFloatPayout,
];

// ── Request statuses (`supplier_crate_deposit_requests.status`) ──────────────

/// Raised, awaiting a money-permitted role. The value the sync registry's
/// monotonic-status restore treats as non-terminal, so a stale snapshot can
/// never resurrect a decided request (issue #115).
const String kCrateDepositRequestPending = 'pending';

/// A money-permitted role confirmed it; both legs are written.
const String kCrateDepositRequestConfirmed = 'confirmed';

/// A money-permitted role refused the money leg. **The crate counts are
/// untouched** — the crates physically arrived whatever anyone decides about
/// the cash (ADR 0023 rule 6).
const String kCrateDepositRequestRejected = 'rejected';

/// The closed set `supplier_crate_deposit_requests.status` may hold.
const List<String> kCrateDepositRequestStatuses = [
  kCrateDepositRequestPending,
  kCrateDepositRequestConfirmed,
  kCrateDepositRequestRejected,
];

// ── Which legs an arrangement admits ─────────────────────────────────────────

/// **The arrangement decides which money legs may exist at all** (#214, ADR
/// 0023 rules 1, 3 and 4). One pure predicate, so the write path cannot drift
/// from the story the settings screen tells an owner.
///
///  * [CrateMoneyArrangement.none] — nothing. A swap-only brand moves no crate
///    money, ever. This is the release gate for the whole of PRD #203.
///  * [CrateMoneyArrangement.perDelivery] — a [kCrateDepositMovementPlacement]
///    on a delivery and a [kCrateDepositMovementRelease] when the empties go
///    home. Money follows the crates.
///  * [CrateMoneyArrangement.standingFloat] — ONLY
///    [kCrateDepositMovementFloatTopup] and
///    [kCrateDepositMovementFloatPayout]. A lump sum placed once for the right
///    to hold a supplier's crates does not move because a lorry arrived, and it
///    does not move because empties went back. **It does not move when crates
///    go missing either**: the supplier has not deducted anything, so booking a
///    loss would show money leaving that nobody took. Missing crates eat float
///    headroom and raise the brand-level Crate Shortfall (#216) instead.
///
/// [kCrateDepositMovementAdjustment] is deliberately absent: a correction is
/// never queued as a request (only a money-permitted role posts one, directly),
/// and it is legal on any brand whose arrangement moves money at all.
bool crateDepositKindAllowedFor(
  CrateMoneyArrangement arrangement,
  String kind,
) {
  switch (arrangement) {
    case CrateMoneyArrangement.none:
      return false;
    case CrateMoneyArrangement.perDelivery:
      return kind == kCrateDepositMovementPlacement ||
          kind == kCrateDepositMovementRelease;
    case CrateMoneyArrangement.standingFloat:
      return kind == kCrateDepositMovementFloatTopup ||
          kind == kCrateDepositMovementFloatPayout;
  }
}
