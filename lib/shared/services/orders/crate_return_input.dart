/// Input to **Confirm** (ADR 0004): one brand's counted-back empties. The
/// `CrateReturnModal` collects these (crate counting is UI), then hands them to
/// `OrderCommands.confirm`, which performs the settlement writes. The modal no
/// longer writes to the DB itself.
class CrateReturnLine {
  final String manufacturerId;

  /// Crates the customer took at the sale (`order_crate_lines.cratesTaken`).
  final int takenCrates;

  /// Crates counted back at Confirm.
  final int returnedCrates;

  /// Deposit rate per crate (snapshot from the sale).
  final int rateKobo;

  /// Deposit actually paid for this brand at the sale. `> 0` = money-track
  /// (settle in money); `0` = crate-track (net the issued balance).
  final int paidKobo;

  const CrateReturnLine({
    required this.manufacturerId,
    required this.takenCrates,
    required this.returnedCrates,
    required this.rateKobo,
    required this.paidKobo,
  });

  bool get isMoneyTrack => paidKobo > 0;
}

/// The modal → screen handoff bundle for a confirmed crate-return count.
/// `null` from the modal means the cashier dismissed/skipped Confirm; an empty
/// [lines] means the order had nothing crate-tracked (proceed straight to the
/// status flip).
class CrateReturnResult {
  final List<CrateReturnLine> lines;

  /// How a money-track refund is paid back: credit balance (false) or cash
  /// out of the till (true).
  final bool refundAsCash;

  const CrateReturnResult({required this.lines, required this.refundAsCash});

  static const empty = CrateReturnResult(lines: [], refundAsCash: false);
}
