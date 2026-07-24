part of 'daos.dart';

/// One sale line's costing inputs for [CostBatchesDao.drawDownSale].
class SaleCostLine {
  /// The line's position in the caller's item list — echoed back as the key of
  /// the returned per-unit COGS map so the caller can snapshot it onto the
  /// matching order line.
  final int index;
  final String productId;
  final String storeId;
  final int quantity;

  const SaleCostLine({
    required this.index,
    required this.productId,
    required this.storeId,
    required this.quantity,
  });
}

/// A prepared, explicit offer to backfill the past **uncosted** sales of a
/// product whose cost just became real (ADR 0005 "Cost backfill", issue #41).
///
/// Built by [CostBatchesDao.onCostBecameReal] at the `0 → first real value`
/// transition, shown to the user as a one-time prompt ("You sold N units before
/// recording a cost. Apply ₦X to those past sales?"), and — only if accepted —
/// committed by [CostBatchesDao.applyCostBackfill]. It names exactly the
/// recognized sale lines that are still uncosted (`buying_price_kobo == 0`):
/// lines that drew from the now-costed uncosted batch AND pre-FIFO
/// migration-era lines that drew from no batch at all are one and the same set
/// — both are simply uncosted history for this product. Quick Sale lines carry
/// no product, so they are never in this set and stay uncosted.
class CostBackfillOffer {
  final String productId;

  /// The real per-unit cost (kobo) now recorded for the product — what each
  /// uncosted line's snapshot would be restated to.
  final int newCostKobo;

  /// The recognized, still-uncosted sale lines this offer would restate. Empty
  /// when there is nothing to backfill (the caller shows no prompt).
  final List<String> lineIds;

  /// Total units across [lineIds] — the "you sold N units" figure for the
  /// prompt copy.
  final int unitsUncosted;

  const CostBackfillOffer({
    required this.productId,
    required this.newCostKobo,
    required this.lineIds,
    required this.unitsUncosted,
  });

  bool get isEmpty => lineIds.isEmpty;
}

/// The `cost_batches` FIFO queue (Epic 2 / ADR 0005). Owns reading the queue,
/// drawing it down at a sale, and keeping `Products.buyingPriceKobo` as a
/// derived display cache over it. The costing maths lives in the pure
/// [fifoDrawDown]; this DAO is only the DB glue around it.
@DriftAccessor(tables: [CostBatches, Products, OrderItems, Orders])
class CostBatchesDao extends DatabaseAccessor<AppDatabase>
    with _$CostBatchesDaoMixin, BusinessScopedDao<AppDatabase> {
  CostBatchesDao(super.db);

  /// The live FIFO queue for a (product, store): batches with stock remaining,
  /// oldest-first by `received_at` then `id` (a total, device-stable order).
  Future<List<CostBatchData>> queueFor(String productId, String storeId) {
    return (select(costBatches)
          ..where(
            (b) =>
                whereBusiness(b) &
                b.productId.equals(productId) &
                b.storeId.equals(storeId) &
                b.qtyRemaining.isBiggerThanValue(0),
          )
          ..orderBy([
            (b) => OrderingTerm(expression: b.receivedAt),
            (b) => OrderingTerm(expression: b.id),
          ]))
        .get();
  }

  // ─── Batch creation on inflow (ADR 0005 "Cost Batch", issue #42) ───────────

  /// Push one new Cost Batch onto a (product, store) FIFO queue for a stock
  /// **inflow** — the producer for the queue that [drawDownSale] consumes. Both
  /// inflow sites call this: Add Product's opening stock and Receive Stock. F1
  /// (#37) only seeds opening batches via the migration and F2 (#38) only draws
  /// the queue down; without this, any product created or restocked after the
  /// migration would draw from no batch and sell at 0 COGS until a cost is
  /// backfilled (ADR 0005).
  ///
  /// Each inflow is its **own** FIFO layer: this always inserts a fresh batch
  /// (a distinct [UuidV7] id, never merged into an existing one), so oldest-first
  /// draw-down honours arrival order. [costKobo] 0 is a valid **uncosted** batch
  /// (a blank/skipped buying price), consistent with F1/F2 — the #41 prompted
  /// backfill later resolves it; no double-count, since an uncosted line and its
  /// backfill are the same set.
  ///
  /// Follows F1's conventions and [[project_synced_write_explicit_id]]: every
  /// synced-and-defaulted column (id, received_at, created_at, last_updated_at)
  /// is set explicitly so the pushed row carries the same id the cloud stores —
  /// the server never mints a second id on push. **Must** be called inside the
  /// caller's inventory-increment transaction so the queue total for a
  /// (product, store) can never drift from on-hand quantity.
  ///
  /// [receivedAt] is the FIFO ordering key (defaults to now for opening stock;
  /// Receive Stock passes the receipt date). A non-positive [quantity] inserts
  /// nothing — no units entered, so there is no batch to cost.
  Future<void> recordInflowBatch({
    required String productId,
    required String storeId,
    required int quantity,
    required int costKobo,
    DateTime? receivedAt,
  }) async {
    if (quantity <= 0) return;
    final now = DateTime.now();
    final row = CostBatchesCompanion.insert(
      id: Value(UuidV7.generate()),
      businessId: requireBusinessId(),
      productId: productId,
      storeId: storeId,
      qtyRemaining: quantity,
      qtyOriginal: quantity,
      costKobo: Value(costKobo < 0 ? 0 : costKobo),
      receivedAt: Value(receivedAt ?? now),
      createdAt: Value(now),
      lastUpdatedAt: Value(now),
    );
    await into(costBatches).insert(row);
    await db.syncDao.enqueueUpsert('cost_batches', row);
  }

  /// Draw a sale's lines down their FIFO cost queues and return each line's
  /// provisional **per-unit** COGS (kobo), keyed by [SaleCostLine.index]. The
  /// caller snapshots that value into `OrderItems.buyingPriceKobo` (which is
  /// per-unit — reports multiply it by quantity).
  ///
  /// Side effects, all within the caller's sale transaction:
  ///  • decrements `qty_remaining` on every consumed batch and enqueues each
  ///    batch's upsert (single-till/online is the happy path; the server takes
  ///    ownership of consumption in #39);
  ///  • recomputes each touched product's scalar `buying_price_kobo` display
  ///    cache to its oldest remaining **costed** batch (see
  ///    [_recomputeScalarCost]).
  ///
  /// COGS is **exactly the local batch-queue view** (ADR 0005 "Provisional
  /// COGS"): units the queue can't cover — a product with no batch yet, or a
  /// partially covered line — are **uncosted** (contribute 0), matching the
  /// server's authoritative recost (migration 0133) so a provisional line and
  /// its correction agree. An uncosted (cost-0) batch likewise contributes 0 for
  /// the units it covers. There is deliberately no scalar fallback — a scalar
  /// value the server would later overwrite to 0 on sync is the "vanishing
  /// trust" failure ADR 0005 avoids.
  Future<Map<int, int>> drawDownSale(List<SaleCostLine> lines) async {
    if (lines.isEmpty) return const {};
    final perUnitByIndex = <int, int>{};

    // Group by (product, store): each group draws one shared queue, in the
    // caller's line order (so two lines of the same product continue the draw).
    final groups = <String, List<SaleCostLine>>{};
    for (final line in lines) {
      groups
          .putIfAbsent('${line.productId} ${line.storeId}', () => [])
          .add(line);
    }

    final touchedProducts = <String>{};
    for (final group in groups.values) {
      final productId = group.first.productId;
      final storeId = group.first.storeId;
      touchedProducts.add(productId);

      final batchRows = await queueFor(productId, storeId);
      final batches = batchRows
          .map(
            (b) =>
                FifoBatch(qtyRemaining: b.qtyRemaining, costKobo: b.costKobo),
          )
          .toList(growable: false);

      final result = fifoDrawDown(
        batches,
        group.map((l) => l.quantity).toList(growable: false),
      );

      // Per-line provisional per-unit COGS from the batch queue (uncovered units
      // contribute 0 — uncosted). The per-unit rounding is
      // `round(line_total / qty)` — round-half-away-from-zero, which is exactly
      // Dart's double.round() — to match the server's authoritative recost
      // (migration 0133 / ADR 0005) so a provisional line and its correction
      // agree when the queue covered the line and no cross-till re-ordering
      // happened.
      for (var i = 0; i < group.length; i++) {
        final line = group[i];
        perUnitByIndex[line.index] = line.quantity > 0
            ? (result.lineCogsKobo[i] / line.quantity).round()
            : 0;
      }

      // Decrement every consumed batch and enqueue its push.
      for (var bi = 0; bi < batchRows.length; bi++) {
        final consumed = result.batchConsumption[bi];
        if (consumed <= 0) continue;
        final row = batchRows[bi];
        await (update(costBatches)..where((t) => t.id.equals(row.id))).write(
          CostBatchesCompanion(
            qtyRemaining: Value(row.qtyRemaining - consumed),
            lastUpdatedAt: Value(DateTime.now()),
          ),
        );
        final updated = await (select(
          costBatches,
        )..where((t) => t.id.equals(row.id))).getSingle();
        await db.syncDao.enqueueUpsert('cost_batches', updated);
      }
    }

    for (final productId in touchedProducts) {
      await _recomputeScalarCost(productId);
    }

    return perUnitByIndex;
  }

  /// Draw a NON-sale outflow of [quantity] units down the (product, store) FIFO
  /// queue oldest-first and return the total cost (kobo) drawn — the shared
  /// primitive behind money-integrity #7 (#170, PRD #155): a valued loss
  /// (damage / count-shortage / product-delete write-off, #7a) SNAPSHOTS this
  /// figure onto its `stock_adjustments` row, and a transfer dispatch (#7b)
  /// RIDES it onto the transfer so the receiving store's batch is created at the
  /// same cost.
  ///
  /// Same batch bookkeeping as [drawDownSale] — decrements every consumed
  /// batch's `qty_remaining`, enqueues each for sync, and recomputes the scalar
  /// display cache — so the queue total can never drift from on-hand. Uncovered
  /// units (a dry or partially-covered queue) contribute **0**, exactly as an
  /// uncosted sale line does, so the snapshot never invents cost the batches
  /// don't hold. A non-positive [quantity] draws nothing and returns 0.
  ///
  /// **Must** run inside the caller's inventory transaction (the same rule as
  /// [recordInflowBatch] / [drawDownSale]).
  Future<int> drawDownOutflow(
    String productId,
    String storeId,
    int quantity,
  ) async {
    if (quantity <= 0) return 0;

    final batchRows = await queueFor(productId, storeId);
    final batches = batchRows
        .map((b) => FifoBatch(qtyRemaining: b.qtyRemaining, costKobo: b.costKobo))
        .toList(growable: false);

    final result = fifoDrawDown(batches, [quantity]);
    final drawnKobo = result.lineCogsKobo.first;

    for (var bi = 0; bi < batchRows.length; bi++) {
      final consumed = result.batchConsumption[bi];
      if (consumed <= 0) continue;
      final row = batchRows[bi];
      await (update(costBatches)..where((t) => t.id.equals(row.id))).write(
        CostBatchesCompanion(
          qtyRemaining: Value(row.qtyRemaining - consumed),
          lastUpdatedAt: Value(DateTime.now()),
        ),
      );
      final updated = await (select(
        costBatches,
      )..where((t) => t.id.equals(row.id))).getSingle();
      await db.syncDao.enqueueUpsert('cost_batches', updated);
    }

    await _recomputeScalarCost(productId);
    return drawnKobo;
  }

  /// `Products.buyingPriceKobo` is a display cache over the batch queue (ADR
  /// 0005) — re-point it at the cost of the product's oldest remaining
  /// **costed** batch (across stores). Uncosted (cost-0) batches are skipped and
  /// the scalar is left untouched when nothing costed remains, so a user-entered
  /// price is never clobbered to 0 by an uncosted batch (the 0→real-value
  /// transition is #41's explicit backfill). Only writes when the value changes,
  /// to keep sync churn down.
  Future<void> _recomputeScalarCost(String productId) async {
    final oldestCosted =
        await (select(costBatches)
              ..where(
                (b) =>
                    whereBusiness(b) &
                    b.productId.equals(productId) &
                    b.qtyRemaining.isBiggerThanValue(0) &
                    b.costKobo.isBiggerThanValue(0),
              )
              ..orderBy([
                (b) => OrderingTerm(expression: b.receivedAt),
                (b) => OrderingTerm(expression: b.id),
              ])
              ..limit(1))
            .getSingleOrNull();
    if (oldestCosted == null) return;

    final product =
        await (select(products)
              ..where((p) => p.id.equals(productId) & whereBusiness(p))
              ..limit(1))
            .getSingleOrNull();
    if (product == null ||
        product.buyingPriceKobo == oldestCosted.costKobo) {
      return;
    }

    await (update(products)
          ..where((p) => p.id.equals(productId) & whereBusiness(p)))
        .write(
          ProductsCompanion(
            buyingPriceKobo: Value(oldestCosted.costKobo),
            lastUpdatedAt: Value(DateTime.now()),
          ),
        );
    final updated = await (select(
      products,
    )..where((p) => p.id.equals(productId) & whereBusiness(p))).getSingle();
    await db.syncDao.enqueueUpsert('products', updated);
  }

  // ─── Prompted cost backfill (ADR 0005 "Cost backfill", issue #41) ──────────

  /// Handle a product's cost going **0 → first real value** (a transition the
  /// caller detects — an uncosted product finally getting a cost recorded).
  ///
  /// Two things happen at this transition:
  ///  1. Every still-**uncosted** batch of the product (`cost_kobo == 0`) is
  ///     costed to [newCostKobo] and re-pushed, so *future* sales draw the real
  ///     cost and the scalar cache is consistent. This is gap-only — a batch
  ///     that already carries a real cost is never overwritten — and it is what
  ///     makes the backfill fire **once per batch**: after this the batch is no
  ///     longer uncosted, so a later real→real edit cannot re-trigger the
  ///     transition.
  ///  2. The past uncosted sales that predate the cost are gathered into a
  ///     [CostBackfillOffer] for the caller to prompt on. Restating those lines
  ///     is a separate, user-consented step ([applyCostBackfill]); costing the
  ///     batches for the future happens here regardless of that choice.
  ///
  /// Returns an empty offer (batches still costed) when there is nothing to
  /// backfill. Does nothing to batches when [newCostKobo] is not positive
  /// (defensive — the caller only invokes this on a real value).
  Future<CostBackfillOffer> onCostBecameReal(
    String productId,
    int newCostKobo,
  ) async {
    if (newCostKobo > 0) {
      final uncostedBatches =
          await (select(costBatches)
                ..where(
                  (b) =>
                      whereBusiness(b) &
                      b.productId.equals(productId) &
                      b.costKobo.equals(0),
                ))
              .get();
      for (final b in uncostedBatches) {
        await (update(costBatches)..where((t) => t.id.equals(b.id))).write(
          CostBatchesCompanion(
            costKobo: Value(newCostKobo),
            lastUpdatedAt: Value(DateTime.now()),
          ),
        );
        final updated = await (select(
          costBatches,
        )..where((t) => t.id.equals(b.id))).getSingle();
        await db.syncDao.enqueueUpsert('cost_batches', updated);
      }
    }
    return _planBackfill(productId, newCostKobo);
  }

  /// The recognized, still-uncosted sale lines of [productId] — the "gaps" a
  /// backfill would fill. A line qualifies when its snapshot is `0`
  /// (`buying_price_kobo == 0`), it belongs to a non-reversed order
  /// (`status IN ('pending','completed')` — the app's revenue statuses; a
  /// cancelled/refunded order's line is a reversed sale), and it carries a
  /// product (Quick Sale lines have `product_id NULL` and are excluded by the
  /// `product_id` match). Whether such a line drew from a now-costed uncosted
  /// batch or from no batch at all (pre-FIFO, migration-era) is immaterial —
  /// both are uncosted history and both restate at [newCostKobo].
  Future<CostBackfillOffer> _planBackfill(
    String productId,
    int newCostKobo,
  ) async {
    final rows =
        await (select(orderItems).join([
          innerJoin(orders, orders.id.equalsExp(orderItems.orderId)),
        ])..where(
              whereBusiness(orderItems) &
                  orderItems.productId.equals(productId) &
                  orderItems.buyingPriceKobo.equals(0) &
                  orders.status.isIn(const ['pending', 'completed']),
            ))
            .get();

    final ids = <String>[];
    var units = 0;
    for (final row in rows) {
      final item = row.readTable(orderItems);
      ids.add(item.id);
      units += item.quantity;
    }
    return CostBackfillOffer(
      productId: productId,
      newCostKobo: newCostKobo,
      lineIds: ids,
      unitsUncosted: units,
    );
  }

  /// Commit a backfill the user accepted. Restates each still-uncosted line's
  /// snapshot to [CostBackfillOffer.newCostKobo] and re-pushes it, then writes
  /// **one** Activity Log row for the whole backfill. Returns the number of
  /// lines actually restated.
  ///
  /// The write is **gap-only, re-checked at the row** (`buying_price_kobo == 0`
  /// in the WHERE), so a line another till already costed between the offer and
  /// the tap — or a repeat tap — never clobbers a real snapshot. Each line stays
  /// in its own order, so its restated profit lands in that sale's **original
  /// period** (nothing about the order's timestamp changes). The [description]
  /// is the caller's copy (localized/currency-formatted at the UI, per ADR
  /// 0005); this DAO owns only the atomic restate-and-audit.
  Future<int> applyCostBackfill(
    CostBackfillOffer offer, {
    required String description,
    String? staffId,
  }) async {
    if (offer.isEmpty) return 0;
    final now = DateTime.now();
    var restated = 0;
    for (final lineId in offer.lineIds) {
      final n =
          await (update(orderItems)..where(
                (t) =>
                    t.id.equals(lineId) &
                    whereBusiness(t) &
                    t.buyingPriceKobo.equals(0),
              ))
              .write(
                OrderItemsCompanion(
                  buyingPriceKobo: Value(offer.newCostKobo),
                  lastUpdatedAt: Value(now),
                ),
              );
      if (n == 0) continue; // already costed by a peer, or a double-tap
      restated++;
      final updated = await (select(
        orderItems,
      )..where((t) => t.id.equals(lineId))).getSingle();
      await db.syncDao.enqueueUpsert('order_items', updated);
    }

    if (restated > 0) {
      await db.activityLogDao.logActivity(
        action: 'cost.backfill',
        description: description,
        staffId: staffId,
        entityType: 'product',
        entityId: offer.productId,
        after: {
          'lines_restated': restated,
          'cost_per_unit_kobo': offer.newCostKobo,
        },
      );
    }
    return restated;
  }

  // ─── Server correction audit (ADR 0005 "batch-boundary reconciliation", #40) ─

  /// The single rolled-up Activity Log row for a sync batch's server-authoritative
  /// COGS corrections (Epic 2 / ADR 0005, #40). [totalRecosted] is the batch's
  /// total re-costed sale-line count; [perProduct] maps productId → its re-costed
  /// count (only products that actually changed). Corrections are **audited, never
  /// prompted** — the sync correction flow calls this once per batch and only when
  /// something changed, so there is no per-sale nag. A no-op when nothing was
  /// re-costed.
  Future<void> logRecostReconciliation({
    required int totalRecosted,
    required Map<String, int> perProduct,
  }) async {
    if (totalRecosted <= 0) return;
    final productIds = perProduct.keys.toList();

    final String description;
    final String? entityId;
    if (productIds.length == 1) {
      final name = await _productName(productIds.first) ?? 'a product';
      description =
          '$totalRecosted ${totalRecosted == 1 ? 'sale' : 'sales'} of $name '
          're-costed on sync — batch-boundary reconciliation';
      entityId = productIds.first;
    } else {
      // A batch spanning several products stays ONE row (never a per-sale nag).
      description =
          '$totalRecosted sales across ${productIds.length} products re-costed '
          'on sync — batch-boundary reconciliation';
      entityId = null;
    }

    await db.activityLogDao.logActivity(
      action: 'cost.recosted_on_sync',
      description: description,
      // Deliberately no storeId: a sync batch can span stores, so the row is
      // business-wide (the activity-log store filter would otherwise hide it).
      // Only a single-product batch carries an entity reference.
      entityType: entityId == null ? null : 'product',
      entityId: entityId,
    );
  }

  /// The business-scoped display name of [productId], or null when the product
  /// isn't held locally (e.g. a peer re-costed a product this device never
  /// pulled) — the caller falls back to a generic label.
  Future<String?> _productName(String productId) async {
    final row =
        await (select(products)
              ..where((p) => p.id.equals(productId) & whereBusiness(p))
              ..limit(1))
            .getSingleOrNull();
    return row?.name;
  }
}
