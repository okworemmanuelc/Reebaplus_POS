/// One brand's row of the receipt's Empty Crates panel (#656): what this sale
/// took, what came back for it, and what is still owed for it.
class ReceiptCrateRow {
  const ReceiptCrateRow({
    required this.manufacturerId,
    required this.taken,
    required this.returned,
    required this.owed,
    this.totalOwed,
  });

  final String manufacturerId;
  final double taken;
  final double returned;

  /// THIS sale only: `taken - returned`, floored at 0, and 0 when the brand's
  /// shortfall was settled in money.
  final double owed;

  /// The customer's overall crates owed for the brand, set only when it differs
  /// from [owed]. Drives the "Total Star crates you owe: 6" line.
  final double? totalOwed;
}

/// The ONE place the receipt's crate maths lives (#656); the phone, text and
/// picture renderers all print its rows, so none of them computes a count.
///
/// - `owed = max(0, taken - returned)`.
/// - A brand in [settledBrands] (its deposit line was settled at Confirm: the
///   shortfall was paid for out of the deposit) owes nothing.
/// - [totalOwed] (null for a walk-in) is kept on a row only when the brand has
///   an entry and it differs from that row's `owed`.
List<ReceiptCrateRow> buildReceiptCrateRows({
  required Map<String, double> taken,
  Map<String, double>? returned,
  Set<String>? settledBrands,
  Map<String, double>? totalOwed,
}) {
  return [
    for (final e in taken.entries)
      _row(
        brand: e.key,
        taken: e.value,
        returned: returned?[e.key] ?? 0,
        settled: settledBrands?.contains(e.key) ?? false,
        total: totalOwed?[e.key],
      ),
  ];
}

ReceiptCrateRow _row({
  required String brand,
  required double taken,
  required double returned,
  required bool settled,
  required double? total,
}) {
  final shortfall = taken - returned;
  final owed = (settled || shortfall < 0) ? 0.0 : shortfall;
  return ReceiptCrateRow(
    manufacturerId: brand,
    taken: taken,
    returned: returned,
    owed: owed,
    totalOwed: (total == null || total == owed) ? null : total,
  );
}

/// The line under the crates table when the customer owes more (or less) than
/// this sale alone: "Total Star crates you owe: 6". [qty] is already formatted.
String receiptTotalOwedLine(String brand, String qty) =>
    'Total $brand crates you owe: $qty';
