/// The Crate Money Arrangement — the single place the app decides whether crate
/// money moves for a brand at all, and when (#211, PRD #203, ADR 0023 rule 3).
///
/// Every crate has two ends. The customer end (money a customer leaves with us)
/// has been modelled since PRD #155. The supplier end — the money *we* leave
/// with a depot for *their* crates — is what PRD #203 builds, and it is not a
/// property of the business: a real distributor runs several arrangements side
/// by side across their brands. One brand's depot takes a deposit on every
/// delivery, the next holds a lump sum that never moves, the third just swaps
/// crate for crate and never touches money. So the arrangement lives on the
/// manufacturer.
///
/// **Every existing manufacturer is [none].** That is the release gate for the
/// whole of PRD #203: with every brand on `none`, no later slice can move a
/// figure, because none of them do anything for a `none` brand. Nothing is ever
/// backfilled, and switching a brand on never restates history (ADR 0021) — the
/// new treatment applies from the day the owner flips it, forward.
///
/// This file holds the ONLY interpretation of the stored strings. The column is
/// `manufacturers.crate_money_arrangement`; the per-crate rate it is valued at
/// stays `manufacturers.deposit_amount_kobo` (ADR 0023 rule 2), never
/// `crate_size_groups.deposit_amount_kobo`, which is dead.
library;

/// Swap only — crate for crate, no money ever changes hands. The default, and
/// what every manufacturer reads as until an owner says otherwise.
const String kCrateMoneyArrangementNone = 'none';

/// A deposit is placed with the supplier on each delivery and returned on each
/// hand-back.
const String kCrateMoneyArrangementPerDelivery = 'per_delivery';

/// A lump sum placed with the supplier once. It moves only on a real top-up or
/// a real payout — never on an ordinary delivery or hand-back.
const String kCrateMoneyArrangementStandingFloat = 'standing_float';

/// The closed set `manufacturers.crate_money_arrangement` may hold. Mirrors the
/// cloud CHECK constraint in
/// `supabase/migrations/0171_crate_money_arrangement.sql`.
const List<String> kCrateMoneyArrangements = [
  kCrateMoneyArrangementNone,
  kCrateMoneyArrangementPerDelivery,
  kCrateMoneyArrangementStandingFloat,
];

/// The typed form of `manufacturers.crate_money_arrangement`.
///
/// Call sites should switch on this rather than compare the raw string, so a
/// fourth arrangement (should one ever exist) fails to compile rather than
/// falling into a silent `else`.
enum CrateMoneyArrangement {
  /// [kCrateMoneyArrangementNone].
  none(
    kCrateMoneyArrangementNone,
    label: 'Swap only',
    summary: 'No money changes hands. Crates go out, empties come back.',
    onSwitchOn:
        'Crate money stops being tracked for this brand from today. '
        'Deliveries and hand-backs will only move crate counts.',
  ),

  /// [kCrateMoneyArrangementPerDelivery].
  perDelivery(
    kCrateMoneyArrangementPerDelivery,
    label: 'Deposit on every delivery',
    summary:
        'You pay a deposit for the crates on each delivery, and get it back '
        'when you return the empties.',
    onSwitchOn:
        'From today, every delivery of this brand will record the crate '
        'deposit you paid, and every batch of empties you hand back will '
        'record the money coming back.',
  ),

  /// [kCrateMoneyArrangementStandingFloat].
  standingFloat(
    kCrateMoneyArrangementStandingFloat,
    label: 'One standing deposit',
    summary:
        'You paid one lump sum once. It only changes when you top it up or '
        'the supplier pays some back.',
    onSwitchOn:
        'From today, the money you have sitting with this supplier is '
        'tracked as yours. Deliveries and hand-backs will not move it — only '
        'a real top-up or a real payout will.',
  );

  const CrateMoneyArrangement(
    this.wire, {
    required this.label,
    required this.summary,
    required this.onSwitchOn,
  });

  /// The value stored in the column and pushed to the cloud.
  final String wire;

  /// Short owner-facing name, e.g. for a radio row title.
  final String label;

  /// One plain sentence describing the arrangement itself.
  final String summary;

  /// Plain-language statement of what choosing this changes, written for a shop
  /// owner. Always paired with [kCrateMoneyHistoryNotice] at the point of
  /// choosing, because "what changes" is only half the promise.
  final String onSwitchOn;

  /// True for [none] — the "no money moves" arrangement. Every money-moving
  /// path in PRD #203 short-circuits on this.
  bool get movesMoney => this != CrateMoneyArrangement.none;
}

/// The promise that goes beside every arrangement change: switching a brand on
/// or off never rewrites a closed day (ADR 0021, ADR 0023 "Rejected
/// alternatives").
const String kCrateMoneyHistoryNotice =
    'Your past figures do not change. Sales, profit and reports for days '
    'already gone stay exactly as they are — this only affects deliveries and '
    'returns from today onwards.';

/// Reads a stored `crate_money_arrangement` string.
///
/// Anything unrecognised — a null from a cloud row written before 0171, a value
/// a future client introduced — reads as [CrateMoneyArrangement.none]. Failing
/// closed here is deliberate: an unknown arrangement must never be treated as
/// "move money", because a wrong money movement is far more expensive than a
/// missed one, and `none` is the state every tenant is already in.
CrateMoneyArrangement crateMoneyArrangementOf(String? value) {
  for (final a in CrateMoneyArrangement.values) {
    if (a.wire == value) return a;
  }
  return CrateMoneyArrangement.none;
}
