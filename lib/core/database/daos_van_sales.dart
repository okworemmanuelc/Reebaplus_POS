part of 'daos.dart';

/// One line of a Load Van dispatch, as the UI collects it (#141).
///
/// [loadPriceKobo] is PER UNIT and is the driver's accountability price — it
/// defaults to the product's retail tier at the picker and is editable per line
/// before dispatch. It is deliberately NOT derived at write time: the whole
/// reconciliation values loads, returns, shortages and write-offs at the price
/// the manager and driver agreed at the tailgate, not at whatever the catalogue
/// says later.
class VanLoadLine {
  final String productId;
  final int quantity;
  final int loadPriceKobo;

  /// Empty-crate shells leaving with this line (van-sales spec §11). A memo
  /// count only in v1 — no deposit money, no crate-pool write.
  final int shellsOut;

  const VanLoadLine({
    required this.productId,
    required this.quantity,
    required this.loadPriceKobo,
    this.shellsOut = 0,
  });

  int get lineValueKobo => quantity * loadPriceKobo;
}

/// What a dispatch did — or, on an idempotent replay, what it had already done.
class VanDispatchResult {
  /// The trip the lots landed on (newly opened by this call unless
  /// [alreadyApplied]).
  final String tripId;

  /// The client idempotency key this dispatch was written under.
  final String dispatchEventId;

  /// True when this call found the key already applied and wrote NOTHING — a
  /// retry after a timeout, or a double-tap. The caller shows the same success
  /// state either way; what it must not do is debit again.
  final bool alreadyApplied;

  /// The lots this dispatch wrote (or, on a replay, the lots it found).
  final List<VanTripLotData> lots;

  /// Total load-price value dispatched — exactly the driver's new debit, and
  /// exactly `−balance` immediately after a first load.
  final int totalLoadValueKobo;

  /// Products whose source batches were genuinely uncosted, so their lot
  /// carries `unit_cost_kobo == 0`. Surfaced by the caller in the app's
  /// existing Uncosted transparency bucket — an uncosted load must never
  /// silently become free goods (spec §9.1 #2).
  final List<String> uncostedProductIds;

  const VanDispatchResult({
    required this.tripId,
    required this.dispatchEventId,
    required this.alreadyApplied,
    required this.lots,
    required this.totalLoadValueKobo,
    required this.uncostedProductIds,
  });
}

/// Thrown when a load would open a SECOND trip on a van or a driver that is
/// already out (van-sales spec §4.2).
///
/// This is the client's first line of defence; the cloud's two partial-unique
/// indexes (`WHERE status = 'open'`) are the second, for the two-offline-devices
/// case the client cannot see. [message] is user-facing copy — the caller shows
/// it verbatim.
class VanTripAlreadyOpenException implements Exception {
  /// The trip that is already open.
  final String openTripId;

  /// True when the clash is on the van, false when it is on the driver.
  final bool onVan;

  final String message;

  const VanTripAlreadyOpenException({
    required this.openTripId,
    required this.onVan,
    required this.message,
  });

  @override
  String toString() => message;
}

/// Thrown when the generic stock-transfer cancel is pointed at a van leg
/// (van-sales spec §7.2).
///
/// A van load is a transfer leg, but cancelling it through the generic path
/// would detach it from its trip and its ledger debit — the goods would come
/// back on paper while the driver stayed debited. Corrections are **return
/// events, not cancels**, and [message] says so.
class VanLegNotCancellableException implements Exception {
  final String message;

  const VanLegNotCancellableException(this.message);

  @override
  String toString() => message;
}

/// Van trips and their priced load lots (#141, PRD #139 / ADR 0019).
///
/// Owns the dispatch transaction — the one place where a van load's five
/// effects happen together or not at all: the FIFO cost draw-down on the source
/// warehouse, the cost SNAPSHOT onto the lot, the stock move warehouse → van,
/// the lot insert, and the driver-ledger debit. ADR 0019's consequence note is
/// the reason they are one transaction: *"if a dispatch ever writes a lot
/// without drawing the source batches down, that trip's COGS is silently wrong
/// and nothing downstream will catch it."*
@DriftAccessor(tables: [VanTrips, VanTripLots, DriverLedgerEntries, Stores])
class VanTripsDao extends DatabaseAccessor<AppDatabase>
    with _$VanTripsDaoMixin, BusinessScopedDao<AppDatabase> {
  VanTripsDao(super.db);

  // ── Reads ────────────────────────────────────────────────────────────────

  /// The open trip on [vanStoreId], or null when the van is home.
  Future<VanTripData?> openTripForVan(String vanStoreId) {
    return (select(vanTrips)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.vanStoreId.equals(vanStoreId) &
                t.status.equals(kVanTripStatusOpen),
          )
          ..limit(1))
        .getSingleOrNull();
  }

  /// The open trip [driverUserId] is out on, or null when they are not out.
  /// Cross-van: a driver may hold at most one open trip anywhere.
  Future<VanTripData?> openTripForDriver(String driverUserId) {
    return (select(vanTrips)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.driverUserId.equals(driverUserId) &
                t.status.equals(kVanTripStatusOpen),
          )
          ..limit(1))
        .getSingleOrNull();
  }

  /// Every open trip in the business, newest first — the Van Sales hub's live
  /// "who is out" feed.
  Stream<List<VanTripData>> watchOpenTrips() {
    return (select(vanTrips)
          ..where(
            (t) => whereBusiness(t) & t.status.equals(kVanTripStatusOpen),
          )
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.openedAt, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  /// Every trip (open and closed) for one van, newest first.
  Stream<List<VanTripData>> watchTripsForVan(String vanStoreId) {
    return (select(vanTrips)
          ..where((t) => whereBusiness(t) & t.vanStoreId.equals(vanStoreId))
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.openedAt, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  Future<VanTripData?> getTrip(String tripId) {
    return (select(
      vanTrips,
    )..where((t) => whereBusiness(t) & t.id.equals(tripId))).getSingleOrNull();
  }

  Stream<VanTripData?> watchTrip(String tripId) {
    return (select(
      vanTrips,
    )..where((t) => whereBusiness(t) & t.id.equals(tripId))).watchSingleOrNull();
  }

  /// A trip's load lots in FIFO order (oldest dispatch first, id as the stable
  /// tiebreak) — the order a good return credits against (#143) and the order
  /// #145 consumes for COGS.
  Future<List<VanTripLotData>> lotsForTrip(String tripId) {
    return (select(vanTripLots)
          ..where((t) => whereBusiness(t) & t.tripId.equals(tripId))
          ..orderBy([
            (t) => OrderingTerm(expression: t.dispatchedAt),
            (t) => OrderingTerm(expression: t.id),
          ]))
        .get();
  }

  /// Live [lotsForTrip].
  Stream<List<VanTripLotData>> watchLotsForTrip(String tripId) {
    return (select(vanTripLots)
          ..where((t) => whereBusiness(t) & t.tripId.equals(tripId))
          ..orderBy([
            (t) => OrderingTerm(expression: t.dispatchedAt),
            (t) => OrderingTerm(expression: t.id),
          ]))
        .watch();
  }

  /// Total load-price value dispatched onto [tripId] — `Σ quantity × load
  /// price`. The figure the driver signed for.
  Future<int> loadedValueKoboForTrip(String tripId) async {
    final lots = await lotsForTrip(tripId);
    var total = 0;
    for (final lot in lots) {
      total += lot.quantity * lot.loadPriceKobo;
    }
    return total;
  }

  /// True when [storeId] is a van. The DAO-layer form of the van predicate —
  /// the UI holds `StoreData` rows and uses `isVanStore`, but a write path only
  /// has an id and must not reach up into the providers to resolve one.
  Future<bool> isVanStoreId(String storeId) async {
    final row =
        await (select(stores)
              ..where((t) => whereBusiness(t) & t.id.equals(storeId))
              ..limit(1))
            .getSingleOrNull();
    return row != null && isVanStore(row);
  }

  // ── Load-below-cost warning (spec §9.1 #1) ────────────────────────────────

  /// The subset of [lines] whose load price is below what those goods currently
  /// cost the business — **as a set of product ids and nothing else**.
  ///
  /// The return type is the whole point. The warning at dispatch must not
  /// reveal the cost figure to a role behind the cost wall
  /// (`reports.see_cost_prices` / `products.edit_buying_price`), so this seam
  /// hands back *which lines* are underwater and never *by how much*. A caller
  /// cannot leak a number it was never given.
  ///
  /// Read-only: it peeks the FIFO queue without drawing it down, so calling it
  /// on every keystroke is safe. An uncosted product (nothing costed in the
  /// queue) is never "below cost" — it is uncosted, which is a different
  /// disclosure with a different message (spec §9.1 #2).
  Future<Set<String>> productsPricedBelowCost({
    required String sourceStoreId,
    required List<VanLoadLine> lines,
  }) async {
    final below = <String>{};
    for (final line in lines) {
      if (line.quantity <= 0) continue;
      final peeked = await db.costBatchesDao.peekOutflowCostKobo(
        line.productId,
        sourceStoreId,
        line.quantity,
      );
      if (peeked <= 0) continue; // uncosted — a different disclosure
      final perUnit = (peeked / line.quantity).round();
      if (line.loadPriceKobo < perUnit) below.add(line.productId);
    }
    return below;
  }

  // ── Dispatch ─────────────────────────────────────────────────────────────

  /// Load [vanStoreId] for [driverUserId] out of [sourceStoreId] — open the
  /// trip and dispatch every line, in ONE transaction (#141).
  ///
  /// Per line, in order:
  ///  1. move the stock warehouse → van (the existing inventory path, so the
  ///     stock guard still throws [InsufficientStockException] on an overload),
  ///  2. draw the source warehouse's FIFO cost batches down through
  ///     [CostBatchesDao.drawDownOutflow] — the same non-sale outflow primitive
  ///     transfer dispatch and valued damages use,
  ///  3. SNAPSHOT `unit_cost_kobo = round(drawn / quantity)` onto the lot,
  ///  4. insert the priced lot,
  ///  5. post the driver-ledger **debit** for the line's full load-price value.
  ///
  /// **No cost batch is created on the van store** (ADR 0019): the lot snapshot
  /// is the van's cost truth, and a van-side queue would put the same goods in
  /// two places and make COGS depend on offline sync order.
  ///
  /// **Idempotent on [dispatchEventId]** (spec §7.1). A retry after a timeout
  /// or a double-tap re-uses the key; this call then finds it already applied,
  /// writes nothing, and returns the original result with
  /// [VanDispatchResult.alreadyApplied] set. A second debit is the failure this
  /// prevents — the caller MUST generate the key once, before the first attempt,
  /// and re-use it across retries.
  ///
  /// Throws [VanTripAlreadyOpenException] when the van or the driver already
  /// holds an open trip, and [ArgumentError] on an empty/degenerate load.
  ///
  /// Duplicate product lines are COLLAPSED (quantities and shells summed, the
  /// LAST price winning) so one dispatch writes at most one lot per product —
  /// which is what makes the `UNIQUE (dispatch_event_id, product_id)` idempotency
  /// constraint enforceable rather than merely intended.
  Future<VanDispatchResult> dispatchLoad({
    required String vanStoreId,
    required String driverUserId,
    required String sourceStoreId,
    required List<VanLoadLine> lines,
    required String performedBy,
    required String dispatchEventId,
    DateTime? dispatchedAt,
  }) async {
    if (vanStoreId == sourceStoreId) {
      throw ArgumentError('A van cannot load from itself.');
    }
    final merged = _collapseLines(lines);
    if (merged.isEmpty) {
      throw ArgumentError('A load needs at least one line with a quantity.');
    }

    // Idempotency probe OUTSIDE the write transaction: the common replay is a
    // retry of a call that already committed, and it should cost one indexed
    // read, not a transaction. The probe repeats inside the transaction so a
    // genuine race still resolves to one write.
    final replay = await _existingDispatch(dispatchEventId);
    if (replay != null) return replay;

    final now = dispatchedAt ?? DateTime.now();

    return transaction(() async {
      final raced = await _existingDispatch(dispatchEventId);
      if (raced != null) return raced;

      // One open trip per van AND per driver. Checked inside the transaction so
      // two dispatches on one device serialise; the cloud partial-unique
      // indexes cover the two-offline-devices case this cannot see.
      final vanOpen = await openTripForVan(vanStoreId);
      if (vanOpen != null) {
        throw VanTripAlreadyOpenException(
          openTripId: vanOpen.id,
          onVan: true,
          message:
              'This van is already out on a trip. Reconcile and close that '
              'trip before loading it again.',
        );
      }
      final driverOpen = await openTripForDriver(driverUserId);
      if (driverOpen != null) {
        throw VanTripAlreadyOpenException(
          openTripId: driverOpen.id,
          onVan: false,
          message:
              'This driver is already out on a trip. Reconcile and close that '
              'trip before sending them out again.',
        );
      }

      // 1. Open the trip. Every synced-and-defaulted column is set explicitly
      //    so the pushed row carries the id the cloud stores
      //    ([[project_synced_write_explicit_id]]).
      final tripId = UuidV7.generate();
      final trip = VanTripsCompanion.insert(
        id: Value(tripId),
        businessId: requireBusinessId(),
        vanStoreId: vanStoreId,
        driverUserId: driverUserId,
        sourceStoreId: sourceStoreId,
        status: const Value(kVanTripStatusOpen),
        openedAt: Value(now),
        openedBy: Value(performedBy),
        createdAt: Value(now),
        lastUpdatedAt: Value(now),
      );
      await into(vanTrips).insert(trip);

      // 2. Dispatch the lines onto it.
      final applied = await _dispatchLinesOnto(
        tripId: tripId,
        vanStoreId: vanStoreId,
        driverUserId: driverUserId,
        sourceStoreId: sourceStoreId,
        lines: merged,
        performedBy: performedBy,
        dispatchEventId: dispatchEventId,
        entryType: kDriverLedgerTypeLoad,
        now: now,
      );

      // 3. Roll the shell memo up onto the trip and push the header ONCE, now
      //    that it is final (the same shape transfer dispatch uses for
      //    `cost_kobo`).
      await (update(vanTrips)
            ..where((t) => t.id.equals(tripId) & whereBusiness(t)))
          .write(
            VanTripsCompanion(
              shellsOut: Value(applied.shellsOut),
              lastUpdatedAt: Value(DateTime.now()),
            ),
          );
      final tripRow = await (select(
        vanTrips,
      )..where((t) => t.id.equals(tripId) & whereBusiness(t))).getSingle();
      await db.syncDao.enqueueUpsert('van_trips', tripRow.toCompanion(true));

      return VanDispatchResult(
        tripId: tripId,
        dispatchEventId: dispatchEventId,
        alreadyApplied: false,
        lots: applied.lots,
        totalLoadValueKobo: applied.totalLoadValueKobo,
        uncostedProductIds: applied.uncostedProductIds,
      );
    });
  }

  /// Sum duplicate lines of the same product into one, and drop the degenerate
  /// ones. Input order of first appearance is preserved so the written lots
  /// match what the manager typed.
  List<VanLoadLine> _collapseLines(List<VanLoadLine> lines) {
    final byProduct = <String, VanLoadLine>{};
    for (final line in lines) {
      if (line.quantity <= 0) continue;
      if (line.loadPriceKobo < 0) {
        throw ArgumentError('A load price cannot be negative.');
      }
      final existing = byProduct[line.productId];
      byProduct[line.productId] = existing == null
          ? line
          : VanLoadLine(
              productId: line.productId,
              quantity: existing.quantity + line.quantity,
              // Last price wins — the manager's most recent edit for that
              // product is the one they meant.
              loadPriceKobo: line.loadPriceKobo,
              shellsOut: existing.shellsOut + line.shellsOut,
            );
    }
    return byProduct.values.toList(growable: false);
  }

  /// The already-applied result for [dispatchEventId], or null when the key is
  /// fresh. Reconstructed from the lots themselves, so it is correct even after
  /// the app was killed mid-retry and holds no in-memory state.
  Future<VanDispatchResult?> _existingDispatch(String dispatchEventId) async {
    final lots =
        await (select(vanTripLots)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    t.dispatchEventId.equals(dispatchEventId),
              )
              ..orderBy([
                (t) => OrderingTerm(expression: t.dispatchedAt),
                (t) => OrderingTerm(expression: t.id),
              ]))
            .get();
    if (lots.isEmpty) return null;

    var total = 0;
    final uncosted = <String>[];
    for (final lot in lots) {
      total += lot.quantity * lot.loadPriceKobo;
      if (lot.unitCostKobo == 0) uncosted.add(lot.productId);
    }
    return VanDispatchResult(
      tripId: lots.first.tripId,
      dispatchEventId: dispatchEventId,
      alreadyApplied: true,
      lots: lots,
      totalLoadValueKobo: total,
      uncostedProductIds: uncosted,
    );
  }

  /// Write [lines] onto an existing [tripId]: stock move, cost draw-down + lot
  /// snapshot, lot insert, ledger debit. **Must** run inside a transaction.
  ///
  /// Split out from [dispatchLoad] because #143's restock is exactly this call
  /// against an already-open trip with `entryType: restock` — the seam is here
  /// so a restock can never grow a second, subtly different dispatch path.
  Future<
    ({
      List<VanTripLotData> lots,
      int totalLoadValueKobo,
      int shellsOut,
      List<String> uncostedProductIds,
    })
  >
  _dispatchLinesOnto({
    required String tripId,
    required String vanStoreId,
    required String driverUserId,
    required String sourceStoreId,
    required List<VanLoadLine> lines,
    required String performedBy,
    required String dispatchEventId,
    required String entryType,
    required DateTime now,
  }) async {
    final lots = <VanTripLotData>[];
    final uncosted = <String>[];
    var totalValue = 0;
    var totalShells = 0;

    for (final line in lines) {
      // 1. Move the stock warehouse → van. `trackCost: false` on BOTH legs:
      //    the outflow's cost is drawn explicitly below (so it can be
      //    snapshotted onto the lot), and the van side must create no cost
      //    batch at all (ADR 0019). Passing a transfer movement type with no
      //    refId writes the `stock_adjustments` parent row that
      //    `stock_transactions`' exactly-one-parent CHECK requires while still
      //    typing the ledger row as the transfer leg it physically is — a van
      //    load deliberately writes NO `stock_transfers` header (spec §7.2: the
      //    lot IS the leg, and a header would be a second, detachable
      //    representation of the same movement).
      await db.inventoryDao.adjustStock(
        line.productId,
        sourceStoreId,
        -line.quantity,
        'Van load — dispatched to van',
        performedBy,
        movementType: 'transfer_out',
        trackCost: false,
      );
      await db.inventoryDao.adjustStock(
        line.productId,
        vanStoreId,
        line.quantity,
        'Van load — received on van',
        performedBy,
        movementType: 'transfer_in',
        trackCost: false,
      );

      // 2. Draw the source warehouse's FIFO batches down and SNAPSHOT the
      //    per-unit cost onto the lot. Uncovered units draw 0 — genuinely
      //    uncosted, never invented.
      final drawnKobo = await db.costBatchesDao.drawDownOutflow(
        line.productId,
        sourceStoreId,
        line.quantity,
      );
      final unitCostKobo = (drawnKobo / line.quantity).round();
      if (unitCostKobo == 0) uncosted.add(line.productId);

      // 3. The priced lot.
      final lotId = UuidV7.generate();
      final lot = VanTripLotsCompanion.insert(
        id: Value(lotId),
        businessId: requireBusinessId(),
        tripId: tripId,
        productId: line.productId,
        quantity: line.quantity,
        qtyRemaining: line.quantity,
        loadPriceKobo: line.loadPriceKobo,
        unitCostKobo: Value(unitCostKobo),
        dispatchedAt: Value(now),
        dispatchEventId: dispatchEventId,
        shellsOut: Value(line.shellsOut),
        createdAt: Value(now),
        lastUpdatedAt: Value(now),
      );
      await into(vanTripLots).insert(lot);
      await db.syncDao.enqueueUpsert('van_trip_lots', lot);

      // 4. The driver-ledger DEBIT for the line's full load-price value. This
      //    is the "they signed for the van" leg; a later SALE writes nothing
      //    here, which is what keeps the balance a clean measure of
      //    `loaded − returned − paid`.
      await db.driverLedgerDao.postEntry(
        driverUserId: driverUserId,
        tripId: tripId,
        type: entryType,
        amountKobo: line.lineValueKobo,
        isCredit: false,
        referenceType: kDriverLedgerRefLot,
        referenceId: lotId,
        activityDate: now,
        performedBy: performedBy,
      );

      lots.add(
        await (select(
          vanTripLots,
        )..where((t) => t.id.equals(lotId))).getSingle(),
      );
      totalValue += line.lineValueKobo;
      totalShells += line.shellsOut;
    }

    return (
      lots: lots,
      totalLoadValueKobo: totalValue,
      shellsOut: totalShells,
      uncostedProductIds: uncosted,
    );
  }
}

/// The driver consignment ledger (#141, van-sales spec §4.4).
///
/// Balance = `SUM(signed_amount_kobo)`; **negative = the driver owes**. There is
/// no cached balance column anywhere — the sum IS the balance, so it cannot
/// drift from the rows that justify it, and every later slice (#143 returns,
/// #144 remittances, #145 write-offs) moves it by appending one signed row.
///
/// Modelled on [SupplierLedgerDao] down to the void semantics: the original is
/// marked voided AND an opposite-sign compensating row is appended, so the
/// balance nets out without any row ever being edited or deleted.
@DriftAccessor(tables: [DriverLedgerEntries, VanTrips, Users])
class DriverLedgerDao extends DatabaseAccessor<AppDatabase>
    with _$DriverLedgerDaoMixin, BusinessScopedDao<AppDatabase> {
  DriverLedgerDao(super.db);

  // ── Balances ─────────────────────────────────────────────────────────────

  /// [driverUserId]'s current balance (kobo). Negative = they owe.
  ///
  /// Voided rows are deliberately NOT filtered out: a void appends an
  /// opposite-sign compensating row, so the pair already nets to zero. Filtering
  /// as well would double-reverse it (the same rule as the wallet and supplier
  /// ledgers).
  Future<int> getBalanceKobo(String driverUserId) async {
    final sumExpr = driverLedgerEntries.signedAmountKobo.sum();
    final query = selectOnly(driverLedgerEntries)
      ..addColumns([sumExpr])
      ..where(
        whereBusiness(driverLedgerEntries) &
            driverLedgerEntries.driverUserId.equals(driverUserId),
      );
    final row = await query.getSingleOrNull();
    return row?.read(sumExpr) ?? 0;
  }

  /// Live [getBalanceKobo] — the driver chip on the Van Sales hub.
  Stream<int> watchBalanceKobo(String driverUserId) {
    final sumExpr = driverLedgerEntries.signedAmountKobo.sum();
    final query = selectOnly(driverLedgerEntries)
      ..addColumns([sumExpr])
      ..where(
        whereBusiness(driverLedgerEntries) &
            driverLedgerEntries.driverUserId.equals(driverUserId),
      );
    return query.watchSingleOrNull().map((row) => row?.read(sumExpr) ?? 0);
  }

  /// driverUserId → balance (kobo), for the Drivers list (#146). Drivers with
  /// no entries at all are simply absent — the caller renders them at 0.
  Stream<Map<String, int>> watchAllBalancesKobo() {
    final sumExpr = driverLedgerEntries.signedAmountKobo.sum();
    final query = selectOnly(driverLedgerEntries)
      ..addColumns([driverLedgerEntries.driverUserId, sumExpr])
      ..where(whereBusiness(driverLedgerEntries))
      ..groupBy([driverLedgerEntries.driverUserId]);
    return query.watch().map((rows) {
      final out = <String, int>{};
      for (final r in rows) {
        final id = r.read(driverLedgerEntries.driverUserId);
        if (id != null) out[id] = r.read(sumExpr) ?? 0;
      }
      return out;
    });
  }

  /// The signed sum for ONE trip — what this trip alone has moved. #145's close
  /// artifact reads it; the DRIVER's balance stays the cross-trip
  /// [getBalanceKobo], because a residual follows the person, not the run.
  Future<int> getTripBalanceKobo(String tripId) async {
    final sumExpr = driverLedgerEntries.signedAmountKobo.sum();
    final query = selectOnly(driverLedgerEntries)
      ..addColumns([sumExpr])
      ..where(
        whereBusiness(driverLedgerEntries) &
            driverLedgerEntries.tripId.equals(tripId),
      );
    final row = await query.getSingleOrNull();
    return row?.read(sumExpr) ?? 0;
  }

  // ── History ──────────────────────────────────────────────────────────────

  /// One driver's ledger, newest first. Same deterministic tiebreak as the
  /// supplier ledger: `createdAt DESC`, then `signedAmountKobo ASC`, so a debit
  /// sorts above a credit posted in the same second.
  Stream<List<DriverLedgerEntryData>> watchHistory(String driverUserId) {
    return (select(driverLedgerEntries)
          ..where((t) => whereBusiness(t) & t.driverUserId.equals(driverUserId))
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
            (t) => OrderingTerm(
              expression: t.signedAmountKobo,
              mode: OrderingMode.asc,
            ),
          ]))
        .watch();
  }

  /// One trip's ledger, newest first — the reconcile screen's audit list.
  Stream<List<DriverLedgerEntryData>> watchTripHistory(String tripId) {
    return (select(driverLedgerEntries)
          ..where((t) => whereBusiness(t) & t.tripId.equals(tripId))
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
            (t) => OrderingTerm(
              expression: t.signedAmountKobo,
              mode: OrderingMode.asc,
            ),
          ]))
        .watch();
  }

  /// One trip's ledger as a one-shot read (the close computation's input).
  Future<List<DriverLedgerEntryData>> entriesForTrip(String tripId) {
    return (select(driverLedgerEntries)
          ..where((t) => whereBusiness(t) & t.tripId.equals(tripId))
          ..orderBy([(t) => OrderingTerm(expression: t.createdAt)]))
        .get();
  }

  // ── Writes ───────────────────────────────────────────────────────────────

  /// Append ONE signed row. The single write primitive for the whole ledger:
  /// #141's load debit, #143's return credit, #144's remittance credit and
  /// #145's write-offs all come through here, so the sign convention and the
  /// explicit-defaults rule live in exactly one place.
  ///
  /// [amountKobo] is the magnitude and must be >= 0; [isCredit] decides the
  /// sign (credit = positive = reduces what the driver owes). Returns the new
  /// row's id.
  ///
  /// **Must** be called inside the caller's transaction when it accompanies
  /// other writes (a dispatch, a remittance) — a ledger row that survives a
  /// failed stock move is worse than no row at all.
  Future<String> postEntry({
    required String driverUserId,
    String? tripId,
    required String type,
    required int amountKobo,
    required bool isCredit,
    required String referenceType,
    String? referenceId,
    required DateTime activityDate,
    String? performedBy,
    String? paymentMethod,
    String? receiptPath,
    String? referenceNote,
  }) async {
    assert(kDriverLedgerTypes.contains(type), 'unknown ledger type: $type');
    assert(
      kDriverLedgerRefTypes.contains(referenceType),
      'unknown reference type: $referenceType',
    );
    if (amountKobo < 0) {
      throw ArgumentError('A ledger amount is a magnitude and cannot be < 0.');
    }

    final now = DateTime.now();
    final id = UuidV7.generate();
    final row = DriverLedgerEntriesCompanion.insert(
      id: Value(id),
      businessId: requireBusinessId(),
      driverUserId: driverUserId,
      tripId: Value(tripId),
      type: type,
      amountKobo: amountKobo,
      signedAmountKobo: isCredit ? amountKobo : -amountKobo,
      referenceType: referenceType,
      referenceId: Value(referenceId),
      paymentMethod: Value(paymentMethod),
      receiptPath: Value(receiptPath),
      referenceNote: Value(referenceNote),
      activityDate: activityDate,
      performedBy: Value(performedBy),
      createdAt: Value(now),
      lastUpdatedAt: Value(now),
    );
    await into(driverLedgerEntries).insert(row);
    await db.syncDao.enqueueUpsert('driver_ledger_entries', row);
    return id;
  }

  /// Void [entryId]: mark the original voided AND append an opposite-sign
  /// compensating row, so the balance nets out without the append-only triggers
  /// ever being tripped.
  ///
  /// Returns true when a void was applied; false when the entry was missing or
  /// already voided (a double-void is a no-op, matching the supplier ledger).
  Future<bool> voidEntry({
    required String entryId,
    required String voidedBy,
    required String reason,
  }) async {
    return transaction(() async {
      final original =
          await (select(driverLedgerEntries)
                ..where((t) => t.id.equals(entryId) & whereBusiness(t))
                ..limit(1))
              .getSingleOrNull();
      if (original == null) return false;
      if (original.voidedAt != null) return false;

      final now = DateTime.now();
      await (update(driverLedgerEntries)
            ..where((t) => t.id.equals(entryId) & whereBusiness(t)))
          .write(
            DriverLedgerEntriesCompanion(
              voidedAt: Value(now),
              voidedBy: Value(voidedBy),
              voidReason: Value(reason),
              lastUpdatedAt: Value(now),
            ),
          );

      await postEntry(
        driverUserId: original.driverUserId,
        tripId: original.tripId,
        type: kDriverLedgerTypeVoid,
        amountKobo: original.amountKobo,
        // Flip the sign: a voided debit becomes a credit and vice versa.
        isCredit: original.signedAmountKobo < 0,
        referenceType: kDriverLedgerRefEntry,
        referenceId: entryId,
        activityDate: now,
        performedBy: voidedBy,
        referenceNote: reason,
      );

      final updatedOriginal = await (select(
        driverLedgerEntries,
      )..where((t) => t.id.equals(entryId))).getSingle();
      await db.syncDao.enqueueUpsert(
        'driver_ledger_entries',
        updatedOriginal.toCompanion(true),
      );
      return true;
    });
  }
}
