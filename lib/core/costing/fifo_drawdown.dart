/// Pure FIFO cost draw-down (Epic 2 / FIFO batch costing — ADR 0005, issue #38).
///
/// This file is deliberately **widget-free and DB-free**: it takes a plain
/// snapshot of a per-(product, store) cost-batch queue and an ordered set of
/// sale-line quantities and returns each line's COGS plus how much was drawn
/// from each batch. The DAO layer reads/writes the queue around it; the UI
/// never touches it. Keeping it pure is what makes the batch-costing maths
/// exhaustively unit-testable with no database.
library;

/// One cost batch as seen by the draw-down. Oldest-first ordering of the queue
/// is the **caller's** responsibility (the DAO orders by `received_at`, then
/// `id`); this function consumes the list in the order given.
class FifoBatch {
  /// Units still on the shelf from this batch — the most that can be drawn.
  final int qtyRemaining;

  /// Per-unit cost in kobo. `0` marks an **uncosted** batch: units drawn from
  /// it contribute 0 to COGS (they are still drawn — the batch is decremented —
  /// they just cost nothing until a real cost is backfilled, issue #41).
  final int costKobo;

  const FifoBatch({required this.qtyRemaining, required this.costKobo});
}

/// The outcome of drawing an ordered set of sale-line quantities against a
/// batch queue. Every list is index-aligned with its input (lines with
/// [lineCogsKobo]/[lineShortfall], batches with [batchConsumption]).
class FifoDrawResult {
  /// COGS (total kobo) for each requested line, in input order. Sums the
  /// per-unit cost of every batch slice the line consumed — including a partial
  /// split that spans two or more batches. Units the queue could **not** cover
  /// (see [lineShortfall]) contribute 0 here; the caller decides how to cost a
  /// shortfall (e.g. fall back to the product's scalar cost).
  final List<int> lineCogsKobo;

  /// Units the queue ran out of stock for, per line, in input order. `0` on the
  /// happy path (the queue fully covers the sale).
  final List<int> lineShortfall;

  /// Units drawn from each input batch, in input order. The caller subtracts
  /// these from each batch's `qty_remaining`.
  final List<int> batchConsumption;

  const FifoDrawResult({
    required this.lineCogsKobo,
    required this.lineShortfall,
    required this.batchConsumption,
  });
}

/// Draw [lineQuantities] down [batches] oldest-first, computing each line's
/// COGS as the weighted cost of the batch(es) its units came from — including
/// partial splits across a batch boundary. An uncosted (cost-0) batch
/// contributes 0. The queue is consumed sequentially across the lines, so two
/// lines of the same product share (and continue) one draw-down.
///
/// Never throws and never mutates its inputs: a dry queue simply reports the
/// uncovered units in [FifoDrawResult.lineShortfall].
FifoDrawResult fifoDrawDown(
  List<FifoBatch> batches,
  List<int> lineQuantities,
) {
  final consumption = List<int>.filled(batches.length, 0);
  final lineCogs = List<int>.filled(lineQuantities.length, 0);
  final lineShort = List<int>.filled(lineQuantities.length, 0);

  var batchIdx = 0;
  // Units still available in the batch currently at the front of the queue.
  var availInBatch = batches.isEmpty ? 0 : batches[0].qtyRemaining;

  for (var li = 0; li < lineQuantities.length; li++) {
    var need = lineQuantities[li];
    if (need < 0) need = 0; // defensive; sale quantities are always positive
    var cogs = 0;

    while (need > 0 && batchIdx < batches.length) {
      if (availInBatch <= 0) {
        // Front batch exhausted (or a 0-qty batch slipped in) — advance.
        batchIdx++;
        if (batchIdx < batches.length) availInBatch = batches[batchIdx].qtyRemaining;
        continue;
      }
      final take = need < availInBatch ? need : availInBatch;
      consumption[batchIdx] += take;
      cogs += take * batches[batchIdx].costKobo;
      availInBatch -= take;
      need -= take;
    }

    lineCogs[li] = cogs;
    lineShort[li] = need; // whatever the queue could not cover
  }

  return FifoDrawResult(
    lineCogsKobo: lineCogs,
    lineShortfall: lineShort,
    batchConsumption: consumption,
  );
}
