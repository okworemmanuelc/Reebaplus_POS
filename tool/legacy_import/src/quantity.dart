/// Quantity and money arithmetic for the import. The target schema (#627) keeps
/// quantities as `double precision` on a 0.25 grid with a CHECK per column.
library;

const double _gridTolerance = 1e-9;

/// True when [qty] sits on the 0.25 grid the target columns accept.
bool isQuarterStep(double qty) {
  final scaled = qty * 4;
  return (scaled - scaled.roundToDouble()).abs() < _gridTolerance;
}

/// [qty] snapped onto the grid, clearing float noise from summed values.
double snapToQuarter(double qty) => (qty * 4).roundToDouble() / 4;

/// The SQL literal for a quantity: `5`, `0.5`, `-1.25`. Throws off the grid, so
/// a value the #627 CHECK would reject fails here rather than mid-transaction.
String qtyLiteral(double qty) {
  if (!isQuarterStep(qty)) {
    throw ArgumentError.value(qty, 'qty', 'is not a multiple of 0.25');
  }
  final snapped = snapToQuarter(qty);
  if (snapped == snapped.truncateToDouble()) {
    return snapped.toInt().toString();
  }
  return snapped.toString();
}

/// unit price × quantity in whole kobo, half-up (away from zero for a negative
/// quantity, so a reversal exactly cancels its original).
int lineValueKobo({required int unitKobo, required double qty}) {
  final magnitude = (unitKobo * qty.abs() + 0.5).floor();
  return qty < 0 ? -magnitude : magnitude;
}
