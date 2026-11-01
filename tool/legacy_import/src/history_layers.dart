/// Cost layers that keep imported history safe from the cloud FIFO re-cost.
///
/// `pos_recost_pairs` runs after every sale push and replays every live sale
/// line of a product + store through `cost_batches.qty_original`, oldest first,
/// overwriting `order_items.buying_price_kobo`. Delivery layers cannot survive
/// that: the cost rule picks the latest delivery price while FIFO picks the
/// oldest unconsumed layer, and history outsells deliveries (stock also arrived
/// through van returns and adjustments), so the replay would restate past
/// profit, run on into the opening layer, and cost the shortfall at 0.
///
/// So history gets its own layers: they hold exactly the units history sold, in
/// exactly replay order, at exactly each line's cost. The replay then gives every
/// line back the cost it already has and stops at the opening layer, which is
/// left whole for new sales. Every layer has `qty_remaining = 0`, so the live
/// draw-downs (phone and `_checkout_draw_fifo`) never see them.
library;

/// A live sale line of one product + store.
class ReplayLine {
  final String lineId;
  final String orderId;
  final DateTime soldAt;
  final double qty;
  final int costKobo;

  const ReplayLine({
    required this.lineId,
    required this.orderId,
    required this.soldAt,
    required this.qty,
    required this.costKobo,
  });
}

class HistoryLayer {
  final double qty;
  final int costKobo;
  final DateTime receivedAt;

  const HistoryLayer({
    required this.qty,
    required this.costKobo,
    required this.receivedAt,
  });
}

/// The replay's own order: `ORDER BY o.created_at, o.id, oi.id` (0228). uuid
/// text compares the same way Postgres compares uuid bytes.
List<ReplayLine> replayOrder(Iterable<ReplayLine> lines) {
  return lines.toList()..sort((x, y) {
    final byTime = x.soldAt.compareTo(y.soldAt);
    if (byTime != 0) return byTime;
    final byOrder = x.orderId.compareTo(y.orderId);
    if (byOrder != 0) return byOrder;
    return x.lineId.compareTo(y.lineId);
  });
}

/// Layers for one product + store: consecutive lines at the same cost share a
/// layer. `received_at` strictly rises, because the replay orders layers by
/// `received_at, id` and a uuid tiebreak would shuffle runs of different cost.
///
/// Throws if the layers would reach [cutover], where the opening layer sits.
List<HistoryLayer> buildHistoryLayers({
  required Iterable<ReplayLine> lines,
  required DateTime cutover,
}) {
  final layers = <HistoryLayer>[];
  ReplayLine? runStart;
  var runQty = 0.0;
  DateTime? previous;

  void closeRun() {
    final start = runStart;
    if (start == null) return;
    final earliest = previous?.add(const Duration(microseconds: 1));
    final receivedAt = earliest != null && earliest.isAfter(start.soldAt)
        ? earliest
        : start.soldAt;
    if (!receivedAt.isBefore(cutover)) {
      throw StateError('History layer at $receivedAt reaches cutover $cutover');
    }
    layers.add(
      HistoryLayer(
        qty: runQty,
        costKobo: start.costKobo,
        receivedAt: receivedAt,
      ),
    );
    previous = receivedAt;
  }

  for (final line in replayOrder(lines)) {
    if (runStart?.costKobo != line.costKobo) {
      closeRun();
      runStart = line;
      runQty = 0;
    }
    runQty += line.qty;
  }
  closeRun();
  return layers;
}
