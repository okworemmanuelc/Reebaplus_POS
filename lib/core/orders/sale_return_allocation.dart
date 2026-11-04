// #732 — which lines a return of a sale consumes. Pure: no database, no clock,
// so two phones given the same rows always pick the same lines.
//
// Goods added to a completed sale by an edit (ADR 0035 addendum) sit on PLUS
// lines of an adjustment, at the price and cost of the day they were added. A
// sale's goods are therefore one or more lines per product, and the cashier asks
// for "3 of this product", never for a particular line:
//   * returnable = original lines + every plus line - every minus line;
//   * a return consumes ORIGINAL lines first, then added lines, oldest
//     adjustment first, each at its own price and cost.

import 'dart:math' as math;

/// One line of a sale's goods: an original sale line, or an edit's plus line.
class ReturnableLine {
  const ReturnableLine({
    required this.lineId,
    required this.storeId,
    required this.sold,
    required this.returned,
    required this.unitPriceKobo,
    required this.buyingPriceKobo,
    this.productId,
    this.addedAt,
    this.name = '',
    this.allowParts = false,
  });

  final String lineId;

  /// Null for a Quick Sale line, which is never pooled with another line.
  final String? productId;
  final String storeId;
  final double sold;

  /// Units already returned: the minus lines pointing at this line.
  final double returned;
  final int unitPriceKobo;
  final int buyingPriceKobo;

  /// When an edit added this line; null on an original sale line.
  final DateTime? addedAt;
  final String name;
  final bool allowParts;

  bool get isAdded => addedAt != null;
  double get standing => math.max(0.0, sold - returned);
}

/// All the lines of one product on a sale, in the order a return consumes them.
/// The Return and Edit sheets show one row per [ReturnableGoods].
class ReturnableGoods {
  const ReturnableGoods(this.lines);

  /// Never empty.
  final List<ReturnableLine> lines;

  ReturnableLine get first => lines.first;

  /// The id the sheets use for this row.
  String get lineId => first.lineId;

  double get sold => lines.fold<double>(0, (s, l) => s + l.sold);
  double get standing => lines.fold<double>(0, (s, l) => s + l.standing);
  bool get hasAdded => lines.any((l) => l.isAdded);
}

/// Whether anything was added to or returned from a sale since it was made, so
/// a whole return of it has to be a final adjustment, not the full Return.
bool saleHasAdjustments(List<ReturnableGoods> goods) =>
    goods.any((g) => g.hasAdded || g.standing < g.sold - 1e-9);

/// [lines] sorted the way a return consumes them, grouped per product and store.
/// Rows keep the order of their first line, so originals come first.
List<ReturnableGoods> groupReturnableLines(Iterable<ReturnableLine> lines) {
  final sorted = lines.toList()..sort(_consumptionOrder);
  final groups = <String, List<ReturnableLine>>{};
  for (final l in sorted) {
    final key = l.productId == null
        ? 'quick:${l.lineId}'
        : '${l.productId}|${l.storeId}';
    groups.putIfAbsent(key, () => []).add(l);
  }
  return [for (final g in groups.values) ReturnableGoods(g)];
}

int _consumptionOrder(ReturnableLine a, ReturnableLine b) {
  if (a.isAdded != b.isAdded) return a.isAdded ? 1 : -1;
  if (a.isAdded) {
    final byDate = a.addedAt!.compareTo(b.addedAt!);
    if (byDate != 0) return byDate;
  }
  // Line ids tie-break, so every phone agrees.
  return a.lineId.compareTo(b.lineId);
}

/// Which lines of [goods] a return of [quantity] units consumes (line id ->
/// units, only above 0). Throws [ArgumentError] when [quantity] is more than
/// [ReturnableGoods.standing]: the caller refuses that first.
Map<String, double> allocateReturn(ReturnableGoods goods, double quantity) {
  if (quantity > goods.standing + 1e-9) {
    throw ArgumentError.value(quantity, 'quantity', 'more than is standing');
  }
  return _consume(
    [for (final l in goods.lines) (id: l.lineId, available: l.standing)],
    quantity,
  );
}

/// Which of the lines in [allocated] (from [allocateReturn]) carry [damaged]
/// units, in the same order, so a write-off is costed from the line consumed.
Map<String, double> allocateDamaged(
  ReturnableGoods goods,
  Map<String, double> allocated,
  double damaged,
) => _consume(
  [
    for (final l in goods.lines)
      if ((allocated[l.lineId] ?? 0) > 0)
        (id: l.lineId, available: allocated[l.lineId]!),
  ],
  damaged,
);

Map<String, double> _consume(
  List<({String id, double available})> lines,
  double quantity,
) {
  final out = <String, double>{};
  var left = quantity;
  for (final l in lines) {
    if (left <= 1e-9) break;
    final take = math.min(left, l.available);
    if (take <= 0) continue;
    out[l.id] = take;
    left -= take;
  }
  return out;
}
