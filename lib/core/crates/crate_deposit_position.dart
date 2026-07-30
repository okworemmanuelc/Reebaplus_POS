/// The supplier crate-deposit arithmetic — one **pure function** over plain
/// data (#212, PRD #203, ADR 0023 rules 1, 2 and 4).
///
/// This is the ONE read seam for the outflow half of the crate story. Slices
/// #213 (settlement), #214 (standing float), #215 (business worth + the
/// reconciliation card), #216 and #217 all read through it, so the arithmetic
/// lives in exactly one place and cannot fork into a second, disagreeing
/// number — which is precisely finding #3 of ADR 0023 ("two numbers that never
/// meet") and the reason that finding exists at all.
///
/// It is deliberately shaped like [computeVanTripPosition]
/// (`lib/core/van_sales/van_trip_position.dart`): a manager is about to decide,
/// on the strength of these figures, whether a depot is sitting on ₦180,000 of
/// theirs or nothing. Math that decides that must be exercisable without a
/// widget, a database or a provider container — so it takes ledger rows and
/// counts as VALUES and returns one immutable answer. There is no `AppDatabase`
/// in this file's imports and there never may be.
///
/// **Scope is the caller's choice, and it matters.** ADR 0023 rules 2 and 4
/// split the two axes on purpose:
///
///  * the **money** is held per `(supplier, manufacturer)` — only the supplier
///    you actually paid can pay you back — so [CrateDepositPosition.placedDepositKobo]
///    is only meaningful when [computeCrateDepositPosition] is fed one pair's
///    movements;
///  * the **shortfall** is brand-level (one manufacturer, ALL suppliers),
///    because crates are fungible and the app must not guess whose crate went
///    missing. Attributing a loss to a supplier is something settlement does,
///    not something a report infers.
///
/// Feeding it a whole-brand set of movements and a whole-brand crate count
/// gives the brand roll-up; feeding it one pair's gives that pair's placed
/// money and that pair's (necessarily approximate) share of the count. The
/// function does not know which you did, so say so at the call site.
library;

import 'package:reebaplus_pos/core/crates/crate_deposit_ledger_types.dart';
import 'package:reebaplus_pos/core/crates/crate_money_arrangement.dart';

// ── Inputs ───────────────────────────────────────────────────────────────────

/// One row of the Placed Deposit ledger (`supplier_crate_deposits`), reduced to
/// the three fields the position needs.
///
/// [signedAmountKobo] is POSITIVE when money went out to the supplier and is
/// now sitting with them, NEGATIVE when money came back to us. The balance is
/// the signed sum, exactly as the driver ledger's balance is — there is no
/// second "current balance" column anywhere for it to disagree with.
///
/// [crateCount] is signed the same way: +N on a placement covering N crates,
/// −N on a release covering N. It is 0 on the standing-float movements (#214),
/// which move money without covering any particular crates, and on a standalone
/// money settlement (#213) that carries no goods.
class CrateDepositMovement {
  /// One of [kCrateDepositMovementTypes].
  final String movementType;

  /// + = placed with the supplier; − = returned to us.
  final int signedAmountKobo;

  /// Crates this money movement covers, signed like [signedAmountKobo].
  final int crateCount;

  const CrateDepositMovement({
    required this.movementType,
    required this.signedAmountKobo,
    this.crateCount = 0,
  });
}

/// One deposit money leg that has been RAISED but not yet decided — a row of
/// `supplier_crate_deposit_requests` still at `pending` (#212, ADR 0023 rule 6).
///
/// It is money the business will probably owe out, and it is deliberately NOT
/// inside [CrateDepositPosition.placedDepositKobo]: nothing has moved yet, and
/// a book entry appears only when money genuinely moved. It is reported beside
/// the balance so a screen can say "₦180,000 placed, ₦42,000 awaiting your
/// confirmation" rather than silently understating.
class PendingCrateDeposit {
  /// One of [kCrateDepositRequestKinds].
  final String kind;

  /// What the request asks for, before any adjustment the approver makes.
  final int requestedAmountKobo;

  /// Crates the request covers.
  final int crateCount;

  const PendingCrateDeposit({
    required this.kind,
    required this.requestedAmountKobo,
    this.crateCount = 0,
  });
}

// ── Output ───────────────────────────────────────────────────────────────────

/// The whole crate-deposit position of one scope at a moment in time.
class CrateDepositPosition {
  /// The arrangement the figures were computed under. `none` forces every
  /// money figure to 0 — see [computeCrateDepositPosition].
  final CrateMoneyArrangement arrangement;

  /// `manufacturers.deposit_amount_kobo` — the single canonical per-crate rate
  /// (ADR 0023 rule 2). NEVER `crate_size_groups.deposit_amount_kobo`, which is
  /// a dead column with zero readers.
  final int ratePerCrateKobo;

  /// **The asset.** Money of ours currently sitting with the supplier, as the
  /// signed sum of the ledger. Never negative in a healthy book; a negative
  /// value means more was taken back than was ever placed and is surfaced
  /// rather than clamped, because clamping would hide a real defect.
  final int placedDepositKobo;

  /// Crates that money is currently covering (signed sum of `crate_count`).
  final int placedCrates;

  /// Money legs raised and awaiting a money-permitted role. NOT part of
  /// [placedDepositKobo] — see [PendingCrateDeposit].
  final int pendingDepositKobo;

  /// Crates covered by those pending legs.
  final int pendingCrates;

  /// Empties we still owe the supplier(s) for full crates delivered —
  /// `SUM(supplier_crate_ledger.quantity_delta)` over the scope.
  final int cratesOwed;

  /// Empties physically on hand for this brand.
  final int emptiesOnHand;

  /// **The warning, not the loss** (ADR 0023 rules 4 and 5). Crates owed that
  /// are not sitting in the yard: `cratesOwed − emptiesOnHand`, floored at 0.
  /// It is a suspicion — crates turn up behind the store, a driver returns
  /// late, a count was wrong — and it hits profit only when somebody
  /// deliberately writes it off, which is #216's job, not this function's.
  ///
  /// **0 when the caller did not ask a shortfall question** — see
  /// [computeCrateDepositPosition]'s `emptiesOnHand`. A shortfall is a
  /// BRAND-level figure across every supplier; asking it of one supplier's
  /// slice would answer a question nobody posed.
  final int shortfallCrates;

  /// [shortfallCrates] at [ratePerCrateKobo].
  final int shortfallValueKobo;

  /// Crates we owe that NO placed money is standing behind:
  /// `cratesOwed − placedCrates`, floored at 0.
  ///
  /// **Disclosure only.** For a brand switched to `per_delivery` today it is
  /// large and correct: every crate received before the switch was received
  /// under `none`, and ADR 0021 forbids restating that history. It exists so
  /// #215's card can show the two numbers ADR 0023 finding #3 says never meet —
  /// notional crate debt and real money paid — side by side, instead of
  /// quietly reporting one as the other.
  final int unbackedCrates;

  /// [unbackedCrates] at [ratePerCrateKobo].
  final int unbackedValueKobo;

  const CrateDepositPosition({
    required this.arrangement,
    required this.ratePerCrateKobo,
    required this.placedDepositKobo,
    required this.placedCrates,
    required this.pendingDepositKobo,
    required this.pendingCrates,
    required this.cratesOwed,
    required this.emptiesOnHand,
    required this.shortfallCrates,
    required this.shortfallValueKobo,
    required this.unbackedCrates,
    required this.unbackedValueKobo,
  });

  /// The all-zero position — what a `none` brand always reads.
  static const CrateDepositPosition zero = CrateDepositPosition(
    arrangement: CrateMoneyArrangement.none,
    ratePerCrateKobo: 0,
    placedDepositKobo: 0,
    placedCrates: 0,
    pendingDepositKobo: 0,
    pendingCrates: 0,
    cratesOwed: 0,
    emptiesOnHand: 0,
    shortfallCrates: 0,
    shortfallValueKobo: 0,
    unbackedCrates: 0,
    unbackedValueKobo: 0,
  );

  /// True when this brand's crate money moves at all.
  bool get movesMoney => arrangement.movesMoney;

  /// True when a shortfall was ASKED FOR and is non-zero. False whenever the
  /// caller passed no `emptiesOnHand` — absence of an answer is never a claim
  /// that nothing is missing.
  bool get hasShortfall => shortfallCrates > 0;

  /// True when a money leg is waiting on a money-permitted role.
  bool get hasPending => pendingDepositKobo != 0 || pendingCrates != 0;

  /// True when nothing of ours is with the supplier and nothing is pending.
  bool get isSettled => placedDepositKobo == 0 && !hasPending;

  /// **The tie-out.** How far the money actually placed is from what the crates
  /// on the books would be worth at today's rate: `placedDeposit −
  /// cratesOwed × rate`. Zero on a brand that has run entirely under
  /// `per_delivery` since its first delivery; negative by the pre-switch
  /// history otherwise. Reported, never corrected — correcting it would restate
  /// history, which ADR 0021 forbids.
  int get notionalDeltaKobo => placedDepositKobo - cratesOwed * ratePerCrateKobo;
}

// ── The business-wide roll-up (#215) ─────────────────────────────────────────
//
// The reconciliation's sixth card and the Business worth asset both need ONE
// business-wide answer to "how much of my money are my suppliers sitting on?".
// That answer is a SUM OF POSITIONS, never a second derivation: every figure
// below is added up from [CrateDepositPosition] values that
// [computeCrateDepositPosition] produced, so the card, the supplier screen and
// the refund cap cannot fork into three disagreeing numbers (ADR 0023
// finding #3). Aggregation lives here rather than in the DAO for the same
// reason the position itself does — it is arithmetic an owner acts on, and it
// must be exercisable with no database.

/// One `(supplier, brand)` slice of the business-wide roll-up: the pair's
/// [CrateDepositPosition] plus the two names a card needs to render it.
class CrateDepositHolding {
  final String supplierId;
  final String supplierName;
  final String manufacturerId;
  final String manufacturerName;
  final CrateDepositPosition position;

  const CrateDepositHolding({
    required this.supplierId,
    required this.supplierName,
    required this.manufacturerId,
    required this.manufacturerName,
    required this.position,
  });
}

/// What ONE supplier is holding, across every brand of theirs that moves crate
/// money. The unit the card's "by supplier" half is rendered from — a depot
/// invoices the business for all their brands at once, so this is the level an
/// owner argues at.
class CrateDepositSupplierTotal {
  final String supplierId;
  final String supplierName;

  /// Money of ours this supplier is currently sitting on.
  final int placedDepositKobo;

  /// Money legs raised against this supplier and still awaiting a
  /// money-permitted role. NOT part of [placedDepositKobo] — nothing has moved.
  final int pendingDepositKobo;

  /// Crates owed to this supplier that no placed money stands behind, valued at
  /// the brand rate. Disclosure only (see [CrateDepositPosition.unbackedCrates]).
  final int unbackedValueKobo;

  /// The brands behind the figures, sorted by name.
  final List<CrateDepositHolding> brands;

  const CrateDepositSupplierTotal({
    required this.supplierId,
    required this.supplierName,
    required this.placedDepositKobo,
    required this.pendingDepositKobo,
    required this.unbackedValueKobo,
    required this.brands,
  });
}

/// Every supplier's crate-money position at once — the business-wide,
/// point-in-time answer the reconciliation card and Business worth read.
///
/// **Business-wide is not an implementation detail, it is the decision.**
/// Supplier crate money is a company obligation: the depot invoices the
/// business, not the branch. Splitting it per store would repeat the defect
/// `CRATE_TRACKING_AUDIT` C4 already names — point-in-time business-wide crate
/// figures presented inside a store-scoped report — and would let two branches
/// each believe the same money is theirs. So there is no store axis in this
/// type at all, and the card that renders it says "business-wide" on its face
/// even when a store is locked.
class CrateDepositRollup {
  /// One entry per `(supplier, brand)` pair that moves crate money, sorted by
  /// supplier then brand. Brands on the default `none` arrangement contribute
  /// [CrateDepositPosition.zero] and are dropped, so a business that has never
  /// switched a brand on rolls up to [empty].
  final List<CrateDepositSupplierTotal> bySupplier;

  /// **The asset.** Every supplier's placed money, summed. This is what enters
  /// `businessNetPositionKobo` — the money is still the owner's, merely held
  /// elsewhere (ADR 0023 rule 1).
  final int placedDepositKobo;

  /// Money legs raised and awaiting confirmation, summed. Deliberately outside
  /// [placedDepositKobo] and outside business worth: a book entry appears only
  /// when money genuinely moved.
  final int pendingDepositKobo;

  /// Crates owed that no placed money stands behind, valued at the brand rates.
  /// The gap ADR 0023 finding #3 says never gets shown — reported beside the
  /// money rather than instead of it.
  final int unbackedValueKobo;

  const CrateDepositRollup({
    required this.bySupplier,
    required this.placedDepositKobo,
    required this.pendingDepositKobo,
    required this.unbackedValueKobo,
  });

  /// What a business with every brand at `none` reads — and what every existing
  /// tenant reads until an owner deliberately switches a brand on.
  static const CrateDepositRollup empty = CrateDepositRollup(
    bySupplier: [],
    placedDepositKobo: 0,
    pendingDepositKobo: 0,
    unbackedValueKobo: 0,
  );

  /// True when there is any crate money to show at all — the gate the card is
  /// rendered behind, so a swap-only business never grows a sixth card.
  bool get hasMoney =>
      placedDepositKobo != 0 ||
      pendingDepositKobo != 0 ||
      unbackedValueKobo != 0;

  /// True when a money leg is waiting on a money-permitted role somewhere.
  bool get hasPending => pendingDepositKobo != 0;
}

/// Roll [holdings] up into the business-wide answer.
///
/// Pairs whose position moves no money are dropped rather than rendered at
/// zero: a `none` brand is not "settled", it is *not in this story at all*, and
/// a card listing it would invite an owner to reconcile a figure that will
/// never move. Suppliers left with no money-moving brand disappear with them.
CrateDepositRollup rollUpCrateDepositPositions(
  List<CrateDepositHolding> holdings,
) {
  final live = holdings.where((h) => h.position.movesMoney).toList();
  if (live.isEmpty) return CrateDepositRollup.empty;

  final bySupplierId = <String, List<CrateDepositHolding>>{};
  for (final h in live) {
    (bySupplierId[h.supplierId] ??= <CrateDepositHolding>[]).add(h);
  }

  var placedDepositKobo = 0;
  var pendingDepositKobo = 0;
  var unbackedValueKobo = 0;
  final bySupplier = <CrateDepositSupplierTotal>[];

  for (final entry in bySupplierId.entries) {
    final brands = entry.value
      ..sort((a, b) => a.manufacturerName.compareTo(b.manufacturerName));
    var placed = 0;
    var pending = 0;
    var unbacked = 0;
    for (final h in brands) {
      placed += h.position.placedDepositKobo;
      pending += h.position.pendingDepositKobo;
      unbacked += h.position.unbackedValueKobo;
    }
    placedDepositKobo += placed;
    pendingDepositKobo += pending;
    unbackedValueKobo += unbacked;
    bySupplier.add(
      CrateDepositSupplierTotal(
        supplierId: entry.key,
        supplierName: brands.first.supplierName,
        placedDepositKobo: placed,
        pendingDepositKobo: pending,
        unbackedValueKobo: unbacked,
        brands: brands,
      ),
    );
  }

  // Biggest holder first — the supplier sitting on the most of the owner's
  // money is the one they will ring.
  bySupplier.sort((a, b) {
    final byMoney = b.placedDepositKobo.compareTo(a.placedDepositKobo);
    return byMoney != 0 ? byMoney : a.supplierName.compareTo(b.supplierName);
  });

  return CrateDepositRollup(
    bySupplier: bySupplier,
    placedDepositKobo: placedDepositKobo,
    pendingDepositKobo: pendingDepositKobo,
    unbackedValueKobo: unbackedValueKobo,
  );
}

// ── The computation ──────────────────────────────────────────────────────────

/// Compute a crate-deposit position from plain data.
///
/// [movements] are the Placed Deposit ledger rows for the scope; [pending] the
/// undecided requests; [cratesOwed] the signed sum of the supplier crate
/// ledger. [ratePerCrateKobo] is `manufacturers.deposit_amount_kobo`.
///
/// **[emptiesOnHand] is nullable, and that is load-bearing.** The empties pool
/// (`manufacturers.empty_crate_stock`) is BRAND-level and business-wide, while
/// [cratesOwed] is whatever scope the caller summed — usually ONE
/// `(supplier, manufacturer)` pair. Subtracting the whole brand's yard from one
/// supplier's debt is not a small inaccuracy: with two suppliers of the same
/// brand it double-subtracts, so each supplier reads a shortfall of ~0 while
/// the brand is genuinely short. Pass `null` (the default) to say "I am not
/// asking a shortfall question at this scope" and get 0; pass it only when
/// [cratesOwed] was summed over the SAME brand-level scope. ADR 0023 rule 4
/// puts the shortfall at brand level precisely because crates are fungible and
/// attributing a loss to one supplier invents a fact.
///
/// **A `none` brand returns [CrateDepositPosition.zero] and reads nothing
/// else.** That is the release gate for the whole of PRD #203, expressed as
/// code rather than as a promise: with every manufacturer defaulted to `none`
/// (#211), every figure this seam can produce is 0, so the eight slices can
/// ship to live production without moving a tenant's numbers. It short-circuits
/// BEFORE looking at the movements on purpose — a `none` brand should have none,
/// and if a stray row ever appears (a brand switched on, used, then switched
/// back off) the owner's stated arrangement wins over the residue. The rows are
/// not deleted and reappear intact the moment the brand is switched on again.
///
/// The shortfall is a COUNT question, so it too is suppressed under `none`: it
/// is the money-at-risk warning of rules 4 and 5, and a swap-only brand has no
/// money at risk. The physical crate counts a `none` brand does carry are
/// unchanged and still read from the crate screens they always did.
///
/// [unbackedCrates] has no such caveat: it is `cratesOwed − placedCrates`, both
/// of which the caller summed over the same scope by construction, so it is
/// meaningful at pair level and at brand level alike.
CrateDepositPosition computeCrateDepositPosition({
  required CrateMoneyArrangement arrangement,
  required int ratePerCrateKobo,
  List<CrateDepositMovement> movements = const [],
  List<PendingCrateDeposit> pending = const [],
  int cratesOwed = 0,
  int? emptiesOnHand,
}) {
  if (!arrangement.movesMoney) return CrateDepositPosition.zero;

  final rate = ratePerCrateKobo > 0 ? ratePerCrateKobo : 0;

  var placedDepositKobo = 0;
  var placedCrates = 0;
  for (final m in movements) {
    placedDepositKobo += m.signedAmountKobo;
    placedCrates += m.crateCount;
  }

  // Signed by KIND, exactly as the ledger is. `requested_amount_kobo` and
  // `crate_count` are both `>= 0` by CHECK, so the direction has to come from
  // somewhere — and a pending `release` or `float_payout` is money coming BACK
  // to us. Summing those additively would report a supplier about to refund us
  // as a supplier about to be paid, which is the sign error this whole family
  // exists to avoid. #212 only ever raises `placement`; the two slices that
  // raise the others inherit this correct.
  var pendingDepositKobo = 0;
  var pendingCrates = 0;
  for (final p in pending) {
    final outward = crateDepositMovementIsOutward(p.kind);
    pendingDepositKobo += outward
        ? p.requestedAmountKobo
        : -p.requestedAmountKobo;
    pendingCrates += outward ? p.crateCount : -p.crateCount;
  }

  // Only when the caller supplied a same-scope empties count. See the doc
  // above: a null here is "not asking", never "nothing is missing".
  final shortfallCrates = emptiesOnHand == null
      ? 0
      : _max0(cratesOwed - emptiesOnHand);
  final unbackedCrates = _max0(cratesOwed - placedCrates);

  return CrateDepositPosition(
    arrangement: arrangement,
    ratePerCrateKobo: rate,
    placedDepositKobo: placedDepositKobo,
    placedCrates: placedCrates,
    pendingDepositKobo: pendingDepositKobo,
    pendingCrates: pendingCrates,
    cratesOwed: cratesOwed,
    emptiesOnHand: emptiesOnHand ?? 0,
    shortfallCrates: shortfallCrates,
    shortfallValueKobo: shortfallCrates * rate,
    unbackedCrates: unbackedCrates,
    unbackedValueKobo: unbackedCrates * rate,
  );
}

int _max0(int v) => v > 0 ? v : 0;
