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

/// What recording a driver's cash handed in did (#144).
///
/// Both ids are returned because the two legs are the point: the ledger credit
/// is what moves the driver's balance toward zero, and the payment row is what
/// puts the money into the business's cash books. A caller that sees only one
/// of them is looking at half a remittance.
class VanRemittanceResult {
  /// The appended `driver_ledger_entries` row (a CREDIT).
  final String ledgerEntryId;

  /// The appended `payment_transactions` row, typed `van_remittance` and
  /// store-stamped to the trip's SOURCE WAREHOUSE.
  final String paymentTransactionId;

  /// The magnitude recorded (kobo, always > 0).
  final int amountKobo;

  /// The driver's cross-trip balance AFTER this credit. Negative = still owes.
  final int driverBalanceKoboAfter;

  const VanRemittanceResult({
    required this.ledgerEntryId,
    required this.paymentTransactionId,
    required this.amountKobo,
    required this.driverBalanceKoboAfter,
  });
}

/// Thrown when a remittance is pointed at a trip that is not open (#144).
///
/// A closed trip is never edited in place (spec §9.4 #16); a residual carries
/// forward on the driver's cross-trip balance and every later correction is a
/// new signed ledger row, posted by the reconcile slice. [message] is
/// user-facing copy — the caller shows it verbatim.
class VanTripNotOpenException implements Exception {
  final String tripId;
  final String message;

  const VanTripNotOpenException({required this.tripId, required this.message});

  @override
  String toString() => message;
}

/// What a checkout needs to know about the location it is being rung on
/// (#142, van-sales spec §5.3 / §5.6, ADR 0019 decision 2).
///
/// One value answers both questions a sale write has to ask, so they can never
/// be answered inconsistently:
///
///  * [isVanSale] — **suppress the money legs?** A road sale writes no
///    `payment_transactions` row and books no per-sale COGS. This keys on the
///    STORE being a van, never on [tripId], because the store is the physical
///    fact: goods that are on a van are on a van whether or not the bookkeeping
///    tag was written. A guard that keyed on the tag would let an untagged road
///    sale inflate "Cash sales" — precisely the failure ADR 0019 exists to stop.
///  * [tripId] — **what does the order get tagged with?** Attribution only:
///    #145's close artifact and #147's aggregated "Van Sales" line read it.
///
/// The two are deliberately independent. [isVanSale] can be true with a null
/// [tripId] (a van whose trip is not open) and the sale is still stripped of its
/// payment row — suppression fails SAFE.
class VanSaleContext {
  /// True when the sale is being rung on a van location.
  final bool isVanSale;

  /// The open trip on that van, or null (not a van, or the van is home).
  final String? tripId;

  /// An ordinary shop sale: money legs written as usual, no tag.
  const VanSaleContext.store() : isVanSale = false, tripId = null;

  /// A road sale on a van, optionally attributable to [tripId].
  const VanSaleContext.van(this.tripId) : isVanSale = true;
}

/// One line of a return, as the manager **physically counted it** (#143,
/// van-sales spec §4.5 / §7.3).
///
/// There is deliberately no "everything that's left" convenience anywhere near
/// this class. With unsynced driver sales in flight, a system-derived default
/// turns those sales into over-returns and misstates the shortage — so the count
/// is typed, and [VanTripsDao.recordReturn] blocks anything above what is still
/// out (spec §9.3 #11).
class VanReturnLine {
  final String productId;

  /// Units physically counted back in. Must be > 0.
  final int quantity;

  /// One of [kVanReturnConditions]. `good` credits the driver and restores
  /// sellable warehouse stock; `damaged` credits NOTHING and books a loss.
  final String condition;

  /// Empty-crate shells coming back with this line (spec §11 — counting only).
  final int shellsBack;

  /// Write-only seam for the later crate pass — no UI sets it in v1. Null means
  /// "never captured", deliberately different from 0.
  final int? crateShells;

  /// The **client idempotency key** for this line: the `van_return_events.id`
  /// the row will be written under. Minted ONCE by the caller (when the form
  /// row is created) and re-used across every retry, so a double-tap or a retry
  /// after the app was killed mid-write re-uses it and the whole call becomes a
  /// no-op — never a second credit.
  ///
  /// The row's own primary key doubles as the key, so returns need no extra
  /// column to be replay-safe. Null (the test/ad-hoc path) mints a fresh id and
  /// gives up the guarantee.
  final String? eventId;

  const VanReturnLine({
    required this.productId,
    required this.quantity,
    required this.condition,
    this.shellsBack = 0,
    this.crateShells,
    this.eventId,
  });

  bool get isGood => condition == kVanReturnConditionGood;
}

/// One lot segment a return consumed — the per-lot record #145 reads.
///
/// A return that spans two lots at different costs produces TWO segments, and
/// both the credit and the warehouse re-batch are computed per segment at that
/// segment's own figures. Never a blended average (spec §5.2): blending would
/// put units back into the warehouse queue at a cost they never had, and the
/// error would only surface as a wrong margin on some later sale.
class VanLotConsumption {
  final String lotId;
  final String productId;

  /// Units drawn from THIS lot.
  final int quantity;

  /// That lot's load price (the credit basis for a good return).
  final int loadPriceKobo;

  /// That lot's snapshotted unit cost (the re-batch basis for a good return,
  /// the loss basis for a damaged one).
  final int unitCostKobo;

  const VanLotConsumption({
    required this.lotId,
    required this.productId,
    required this.quantity,
    required this.loadPriceKobo,
    required this.unitCostKobo,
  });

  int get creditKobo => quantity * loadPriceKobo;
  int get costKobo => quantity * unitCostKobo;
}

/// What recording a return did — or, on an idempotent replay, what it had
/// already done (#143).
class VanReturnResult {
  final String tripId;

  /// The `van_return_events` rows written (one per line), in the caller's line
  /// order.
  final List<VanReturnEventData> events;

  /// The lot segments the whole return consumed, oldest lot first. Exposed
  /// because the per-lot detail is not recoverable from the event rows alone —
  /// #145's reconcile screen shows which prices a credit drew from.
  final List<VanLotConsumption> consumed;

  /// Total driver-ledger credit posted (good lines only; damaged credit 0).
  final int totalCreditKobo;

  /// Total snapshotted cost basis drawn, across BOTH conditions.
  final int totalCostKobo;

  /// The driver's cross-trip balance AFTER the credits. Negative = still owes.
  final int driverBalanceKoboAfter;

  /// True when this call found the lines' ids already written and did NOTHING.
  final bool alreadyApplied;

  const VanReturnResult({
    required this.tripId,
    required this.events,
    required this.consumed,
    required this.totalCreditKobo,
    required this.totalCostKobo,
    required this.driverBalanceKoboAfter,
    required this.alreadyApplied,
  });
}

/// Thrown when a return would send back more of a product than is still out on
/// the trip (van-sales spec §9.3 #11).
///
/// This is the teeth behind the forced physical count: without the block, a
/// mistyped count silently over-credits the driver and manufactures stock the
/// warehouse never received. [message] is user-facing copy — the caller shows it
/// verbatim.
class VanOverReturnException implements Exception {
  final String productId;

  /// What the manager typed.
  final int requested;

  /// What is still out on the trip for that product.
  final int stillOut;

  final String message;

  const VanOverReturnException({
    required this.productId,
    required this.requested,
    required this.stillOut,
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
@DriftAccessor(
  tables: [
    VanTrips,
    VanTripLots,
    VanReturnEvents,
    DriverLedgerEntries,
    Stores,
    PaymentTransactions,
    Orders,
  ],
)
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

  /// Resolve what a sale on [storeId] is: an ordinary shop sale, or a road sale
  /// and which trip it belongs to (#142, spec §5.3).
  ///
  /// The ONE seam `OrdersDao.createOrder` consults before it decides whether to
  /// write a payment row, draw a FIFO cost queue, or stamp a trip tag. It exists
  /// so the three decisions cannot drift apart: they are all downstream of the
  /// same two facts, read once, inside the sale transaction.
  ///
  /// A null [storeId] (a legacy, store-less order) is never a van.
  Future<VanSaleContext> saleContextForStore(String? storeId) async {
    if (storeId == null || storeId.isEmpty) {
      return const VanSaleContext.store();
    }
    if (!await isVanStoreId(storeId)) return const VanSaleContext.store();
    // A van with no open trip still suppresses the money legs — the stock is on
    // a van either way, and only the ATTRIBUTION is missing. (The terminal
    // blocks selling in that state, spec §9.2 #6; this is the write-boundary
    // backstop for it.)
    final trip = await openTripForVan(storeId);
    return VanSaleContext.van(trip?.id);
  }

  // ── Driver terminal reads (#142, spec §9.2) ──────────────────────────────

  /// The road price list for [tripId]: productId → load price (kobo).
  ///
  /// The driver sells at the price they SIGNED FOR, not the catalogue tier
  /// (spec §5.1 — the load price is "the single valuation for the whole
  /// reconciliation", so pricing the road off anything else would make sold
  /// value and loaded value incomparable and break the tie-out).
  ///
  /// When a product was loaded twice at two prices (a restock at a new price,
  /// #143), the **oldest lot's** price wins — the same FIFO rule a good return
  /// credits at (spec §9.3 #10), so one product has one road price and the two
  /// halves of the reconciliation agree.
  Future<Map<String, int>> loadPricesForTrip(String tripId) async {
    return _pricesFromLots(await lotsForTrip(tripId));
  }

  /// Live [loadPricesForTrip] — the terminal's price list, which grows the
  /// moment a restock lands (#143).
  Stream<Map<String, int>> watchLoadPricesForTrip(String tripId) {
    return watchLotsForTrip(tripId).map(_pricesFromLots);
  }

  /// [lotsForTrip] is already ordered oldest dispatch first, so the FIRST lot
  /// seen for a product is the oldest and `putIfAbsent` keeps it.
  ///
  /// **Decision (#143, the open question #142 flagged): `qty_remaining` does NOT
  /// feed this lookup.** Now that returns move the cursor, the road price could
  /// have been made to skip exhausted lots — "price off the oldest lot that
  /// still has units on it". It deliberately does not, for three reasons:
  ///
  ///  1. *The price is a promise, not a derived figure.* The driver signed for a
  ///     price at the tailgate. Skipping exhausted lots would let a MANAGER's
  ///     return entry, recorded on a different device, silently re-price the
  ///     driver's terminal mid-route — a price change nobody on the road asked
  ///     for and nobody can see coming.
  ///  2. *There is no physical fact to anchor it.* Units on a van are fungible.
  ///     `qty_remaining` says which lot a RETURN CREDIT drew from (a valuation
  ///     rule), not which crates are still on the shelf. Pricing off it would be
  ///     reading a bookkeeping cursor as a physical inventory.
  ///  3. *It would make the tie-out order-dependent.* `soldValue` and
  ///     `loadedValue` are only comparable (spec §6.1) if one product has one
  ///     road price for the whole run. A price that moves whenever a return
  ///     lands makes the same unit worth different amounts depending on when the
  ///     manager typed the count.
  ///
  /// Consequence, stated plainly: if the oldest lot is fully returned and only a
  /// restock at a NEW price is still on board, the driver keeps selling at the
  /// old price for the rest of the run. That is stable and explainable — and it
  /// is the same rule the credit side uses — where a jumping price would be
  /// neither.
  Map<String, int> _pricesFromLots(List<VanTripLotData> lots) {
    final prices = <String, int>{};
    for (final lot in lots) {
      prices.putIfAbsent(lot.productId, () => lot.loadPriceKobo);
    }
    return prices;
  }

  /// The orders rung on [tripId], newest first — the driver's read-only run
  /// list, and the set #145's close artifact values as `sold`.
  ///
  /// Cancelled/refunded orders are included: the driver sees their whole run,
  /// and the caller decides what counts as revenue via [orderCountsAsSale]
  /// (never a `== 'completed'` filter — see
  /// `[[project_revenue_recognized_at_checkout]]`).
  Stream<List<OrderData>> watchSalesForTrip(String tripId) {
    return (select(orders)
          ..where((o) => whereBusiness(o) & o.vanTripId.equals(tripId))
          ..orderBy([
            (o) =>
                OrderingTerm(expression: o.createdAt, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  /// Live road takings for [tripId] — `Σ net_amount_kobo` over its RECOGNISED
  /// orders (`orderCountsAsSale`), which at load price is `soldValue` in the
  /// spec's §6.1 identities.
  ///
  /// Note what this is NOT: it is not cash the business holds. A road sale
  /// writes no payment row (ADR 0019 decision 2) — this figure is what the
  /// driver has taken in on the road and still owes, and it only becomes cash
  /// when a manager records the remittance (#144).
  Stream<int> watchSoldValueKoboForTrip(String tripId) {
    return watchSalesForTrip(tripId).map(
      (rows) => rows
          .where((o) => orderCountsAsSale(o.status))
          .fold<int>(0, (sum, o) => sum + o.netAmountKobo),
    );
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

  // ── Restock (#143, spec §7 "OPEN · restock") ──────────────────────────────

  /// Load more goods onto an **already-open** trip — the mid-run reload.
  ///
  /// A restock is not a different kind of event from a load; it is the SAME
  /// dispatch against a trip that already exists. It therefore runs through the
  /// very same [_dispatchLinesOnto] seam — batch draw-down, cost snapshot onto
  /// a fresh priced lot, warehouse → van move, driver-ledger debit, shell memo —
  /// with only the ledger [kDriverLedgerTypeRestock] type telling the two apart
  /// in history. #141 factored that seam out for exactly this reason: a restock
  /// must not be able to grow a second, subtly different dispatch path that
  /// forgets (say) the cost snapshot and silently zeroes the trip's COGS.
  ///
  /// Each restock is **its own dated event** — a new lot at a possibly new
  /// price, never a mutation of an existing one (spec §4.3: lots are never
  /// edited in place except `qty_remaining`). A trip may take any number.
  ///
  /// The goods come from the trip's own `source_store_id`: v1 is one warehouse
  /// per trip (spec §4.2), which is what lets the good-return re-batch and the
  /// remittance both know where things belong without a per-lot lookup.
  ///
  /// **Idempotent on [dispatchEventId]**, identically to [dispatchLoad] — mint
  /// the key once, before the first attempt, and re-use it across retries.
  ///
  /// Throws [StateError] when the trip does not exist, [VanTripNotOpenException]
  /// when it is already closed (a closed trip is never edited in place, spec
  /// §9.4 #16), [ArgumentError] on a degenerate load, and
  /// [InsufficientStockException] when the warehouse cannot cover a line — in
  /// which case NOTHING is written.
  Future<VanDispatchResult> restockTrip({
    required String tripId,
    required List<VanLoadLine> lines,
    required String performedBy,
    required String dispatchEventId,
    DateTime? dispatchedAt,
  }) async {
    final merged = _collapseLines(lines);
    if (merged.isEmpty) {
      throw ArgumentError('A restock needs at least one line with a quantity.');
    }

    // Idempotency probe outside the transaction, same as [dispatchLoad]: the
    // common replay is a retry of a call that already committed, and it should
    // cost one indexed read rather than a transaction.
    final replay = await _existingDispatch(dispatchEventId);
    if (replay != null) return replay;

    final now = dispatchedAt ?? DateTime.now();

    return transaction(() async {
      final raced = await _existingDispatch(dispatchEventId);
      if (raced != null) return raced;

      final trip = await getTrip(tripId);
      if (trip == null) throw StateError('Trip $tripId not found.');
      if (trip.status != kVanTripStatusOpen) {
        throw VanTripNotOpenException(
          tripId: tripId,
          message:
              'This trip is already closed. Load the driver\'s next trip '
              'instead.',
        );
      }

      final applied = await _dispatchLinesOnto(
        tripId: tripId,
        vanStoreId: trip.vanStoreId,
        driverUserId: trip.driverUserId,
        sourceStoreId: trip.sourceStoreId,
        lines: merged,
        performedBy: performedBy,
        dispatchEventId: dispatchEventId,
        entryType: kDriverLedgerTypeRestock,
        now: now,
      );

      // The shell memo ACCUMULATES onto the trip — a restock adds shells, it
      // does not restate the run's total.
      await (update(vanTrips)
            ..where((t) => t.id.equals(tripId) & whereBusiness(t)))
          .write(
            VanTripsCompanion(
              shellsOut: Value(trip.shellsOut + applied.shellsOut),
              lastUpdatedAt: Value(DateTime.now()),
            ),
          );
      final tripRow = await (select(
        vanTrips,
      )..where((t) => t.id.equals(tripId) & whereBusiness(t))).getSingle();
      await db.syncDao.enqueueUpsert('van_trips', tripRow.toCompanion(true));

      await db.activityLogDao.logActivity(
        action: 'van.restock',
        description:
            'Van restocked with '
            '${formatCurrency(applied.totalLoadValueKobo / 100)} of goods',
        staffId: performedBy,
        storeId: trip.sourceStoreId,
        entityType: 'van_trip',
        entityId: tripId,
      );

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

  // ── Returns (#143, spec §4.5 / §5.2 / §5.5 / §7.3 / §9.3) ─────────────────

  /// Every return recorded on [tripId], oldest first.
  Future<List<VanReturnEventData>> returnsForTrip(String tripId) {
    return (select(vanReturnEvents)
          ..where((r) => whereBusiness(r) & r.tripId.equals(tripId))
          ..orderBy([
            (r) => OrderingTerm(expression: r.recordedAt),
            (r) => OrderingTerm(expression: r.id),
          ]))
        .get();
  }

  /// Live [returnsForTrip] — newest first, for the on-screen list.
  Stream<List<VanReturnEventData>> watchReturnsForTrip(String tripId) {
    return (select(vanReturnEvents)
          ..where((r) => whereBusiness(r) & r.tripId.equals(tripId))
          ..orderBy([
            (r) =>
                OrderingTerm(expression: r.recordedAt, mode: OrderingMode.desc),
            (r) => OrderingTerm(expression: r.id, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  /// The COST the whole trip was loaded with — `Σ lot.quantity ×
  /// lot.unit_cost_kobo`, at the snapshots taken when each lot drove off.
  ///
  /// **This is half of #145's COGS.** The other half is the good returns:
  ///
  /// ```
  /// cogs_kobo = loadedCostKoboForTrip(trip)
  ///           − (returnTotalsForTrip(trip).goodCostKobo)
  /// ```
  ///
  /// which is exactly spec §5.2's `Σ consumed lot units × that lot's unit cost`
  /// with `consumed = loaded − good returns`, computed per lot rather than
  /// blended — because each good return's `cost_kobo` is itself the per-segment
  /// sum of the lots it actually drew. Damaged units stay INSIDE `consumed`
  /// (the business lost them), so their cost is already in COGS and
  /// `damage_loss_kobo` is a disclosure figure, never a second subtraction
  /// (spec §6.3's double-count guard).
  Future<int> loadedCostKoboForTrip(String tripId) async {
    final lots = await lotsForTrip(tripId);
    var total = 0;
    for (final lot in lots) {
      total += lot.quantity * lot.unitCostKobo;
    }
    return total;
  }

  /// The trip's returns rolled up the way #145 and #147 need them.
  ///
  /// Split by condition because the two are different money events: good returns
  /// are half of `recovered_kobo` (the other half is remittances) and reduce
  /// COGS; damaged ones recover nothing and are the `damage_loss_kobo`
  /// disclosure at cost.
  Future<
    ({
      int goodUnits,
      int goodCreditKobo,
      int goodCostKobo,
      int damagedUnits,
      int damagedCostKobo,
      int shellsBack,
    })
  >
  returnTotalsForTrip(String tripId) async {
    final rows = await returnsForTrip(tripId);
    var goodUnits = 0;
    var goodCredit = 0;
    var goodCost = 0;
    var damagedUnits = 0;
    var damagedCost = 0;
    var shells = 0;
    for (final r in rows) {
      shells += r.shellsBack;
      if (r.condition == kVanReturnConditionGood) {
        goodUnits += r.quantity;
        goodCredit += r.creditKobo;
        goodCost += r.costKobo;
      } else {
        damagedUnits += r.quantity;
        damagedCost += r.costKobo;
      }
    }
    return (
      goodUnits: goodUnits,
      goodCreditKobo: goodCredit,
      goodCostKobo: goodCost,
      damagedUnits: damagedUnits,
      damagedCostKobo: damagedCost,
      shellsBack: shells,
    );
  }

  /// productId → units still out on [tripId] (`Σ qty_remaining`).
  ///
  /// **The over-return CEILING, never a suggested quantity.** The return form
  /// must not pre-fill from this — with unsynced driver sales in flight it is
  /// "what the system thinks is left", which is precisely the figure spec §7.3
  /// forbids putting in front of a manager. It exists so [recordReturn] can
  /// reject a count above what physically went out, and so an error message can
  /// say by how much.
  Future<Map<String, int>> unitsStillOutForTrip(String tripId) async {
    final lots = await lotsForTrip(tripId);
    final out = <String, int>{};
    for (final lot in lots) {
      out[lot.productId] = (out[lot.productId] ?? 0) + lot.qtyRemaining;
    }
    return out;
  }

  /// Record goods coming back off a van — **one transaction for every leg**
  /// (#143, van-sales spec §4.5 / §5.2 / §5.5).
  ///
  /// Per line, the trip's lots for that product are drawn down **oldest lot
  /// first** ([VanTripLots.qtyRemaining] is that cursor) and split into
  /// [VanLotConsumption] segments. Then, by condition:
  ///
  /// **Good** — the money-critical path:
  ///  1. the driver is CREDITED `Σ segment units × that segment's LOAD PRICE`
  ///     (spec §9.3 #10 — an item loaded twice at two prices credits at the
  ///     oldest lot's price first),
  ///  2. the units go straight back into **sellable** warehouse stock, and
  ///  3. the warehouse is re-batched **one cost batch PER SEGMENT, each at that
  ///     segment's own snapshotted `unit_cost_kobo`** — never a blended average.
  ///     This step is what makes those units' next sale book real COGS instead
  ///     of zero: without it the goods re-enter cost-less and every later sale
  ///     of them shows pure margin (ADR 0019 decision 1).
  ///
  /// **Damaged** — deliberately asymmetric:
  ///  * **no credit at all** (`credit_kobo == 0`, enforced by the table CHECK):
  ///    the driver signed for these goods and still owes for them,
  ///  * the units **never re-enter sellable stock** — they leave the van and
  ///    stop there, and
  ///  * the company loss is booked through the app's existing damage-adjustment
  ///    pattern at the **snapshotted cost, not the load price** (spec §5.5).
  ///    Booking load price would overstate the loss by a margin the business
  ///    never earned. The van store holds no cost batches by design, so the
  ///    basis is handed to `adjustStock` explicitly rather than drawn from a
  ///    queue that would answer 0.
  ///
  /// Returning **more than is still out** is rejected with
  /// [VanOverReturnException] and nothing is written (spec §9.3 #11). That block
  /// is what makes the forced physical count a real control rather than a
  /// formality.
  ///
  /// Idempotent when every line carries a [VanReturnLine.eventId]: the row's own
  /// primary key is the key, so a retry finds the ids already written and
  /// returns the original result without crediting twice.
  ///
  /// Throws [StateError] when the trip is missing, [VanTripNotOpenException]
  /// when it is closed (spec §9.3 #13 — a return after close is impossible;
  /// corrections are compensating ledger entries), and [ArgumentError] on an
  /// empty/degenerate return or an unknown condition.
  Future<VanReturnResult> recordReturn({
    required String tripId,
    required List<VanReturnLine> lines,
    required String performedBy,
    DateTime? recordedAt,
  }) async {
    final merged = _collapseReturnLines(lines);
    if (merged.isEmpty) {
      throw ArgumentError('A return needs at least one line with a quantity.');
    }

    final replay = await _existingReturn(tripId, merged);
    if (replay != null) return replay;

    final now = recordedAt ?? DateTime.now();

    return transaction(() async {
      final raced = await _existingReturn(tripId, merged);
      if (raced != null) return raced;

      final trip = await getTrip(tripId);
      if (trip == null) throw StateError('Trip $tripId not found.');
      if (trip.status != kVanTripStatusOpen) {
        throw VanTripNotOpenException(
          tripId: tripId,
          message:
              'This trip is already closed, so nothing can be returned '
              'against it.',
        );
      }

      final events = <VanReturnEventData>[];
      final consumedAll = <VanLotConsumption>[];
      var totalCredit = 0;
      var totalCost = 0;
      var totalShells = 0;

      for (final line in merged) {
        // 1. Draw this trip's lots for the product down, OLDEST FIRST. Both
        //    conditions draw: a damaged unit is off the van too, and its cost
        //    basis is a lot snapshot exactly like a good one's. Leaving the
        //    cursor untouched for damage would let the same units be returned
        //    again as "good" and credited a second time.
        final segments = await _drawLotsForReturn(
          tripId: tripId,
          productId: line.productId,
          quantity: line.quantity,
          now: now,
        );
        consumedAll.addAll(segments);

        final creditKobo = line.isGood
            ? segments.fold<int>(0, (sum, s) => sum + s.creditKobo)
            : 0;
        final costKobo = segments.fold<int>(0, (sum, s) => sum + s.costKobo);

        // 2. The event row — both money legs written ONCE from the snapshots,
        //    so a later cost edit can never restate a settled return.
        final eventId = line.eventId ?? UuidV7.generate();
        final event = VanReturnEventsCompanion.insert(
          id: Value(eventId),
          businessId: requireBusinessId(),
          tripId: tripId,
          productId: line.productId,
          quantity: line.quantity,
          condition: line.condition,
          creditKobo: Value(creditKobo),
          costKobo: Value(costKobo),
          shellsBack: Value(line.shellsBack),
          crateShells: Value(line.crateShells),
          recordedAt: Value(now),
          recordedBy: Value(performedBy),
          createdAt: Value(now),
          lastUpdatedAt: Value(now),
        );
        await into(vanReturnEvents).insert(event);
        await db.syncDao.enqueueUpsert('van_return_events', event);

        if (line.isGood) {
          // 3. Off the van, into SELLABLE warehouse stock — immediately. Both
          //    legs `trackCost: false`: the van has no queue to draw, and the
          //    warehouse's inflow is re-batched per segment below, at the costs
          //    the goods left with (a generic inflow would create ONE batch at
          //    cost 0 and undo the whole point).
          await db.inventoryDao.adjustStock(
            line.productId,
            trip.vanStoreId,
            -line.quantity,
            'Van return — off the van',
            performedBy,
            movementType: 'transfer_out',
            trackCost: false,
          );
          // The reason deliberately avoids the word "received": this leg lands
          // on the WAREHOUSE, which IS inside every per-store figure, and
          // `isReceiptReason` would file it under "Goods received" — inflating
          // purchases with goods that were only ever moved. (#141's van-side
          // leg can say "received" safely because a van store is excluded.)
          await db.inventoryDao.adjustStock(
            line.productId,
            trip.sourceStoreId,
            line.quantity,
            'Van return — back in stock',
            performedBy,
            movementType: 'transfer_in',
            trackCost: false,
          );

          // 4. ONE cost batch PER SEGMENT, each at its own snapshotted cost
          //    (spec §5.2). A return spanning two lots re-enters the queue as
          //    two layers, so the next sale of those units draws the cost they
          //    actually carried rather than an average of two.
          for (final seg in segments) {
            await db.costBatchesDao.recordInflowBatch(
              productId: line.productId,
              storeId: trip.sourceStoreId,
              quantity: seg.quantity,
              costKobo: seg.unitCostKobo,
              receivedAt: now,
            );
          }

          // 5. The ledger CREDIT — this is what moves the running balance the
          //    moment the return is logged.
          await db.driverLedgerDao.postEntry(
            driverUserId: trip.driverUserId,
            tripId: tripId,
            type: kDriverLedgerTypeReturnGood,
            amountKobo: creditKobo,
            isCredit: true,
            referenceType: kDriverLedgerRefReturn,
            referenceId: eventId,
            activityDate: now,
            performedBy: performedBy,
          );
        } else {
          // Damaged: off the van and nowhere else. NO warehouse leg, NO cost
          // batch, NO ledger row — the driver stays liable at load price. The
          // company loss is booked at the SNAPSHOTTED cost, handed over
          // explicitly because the van store has no FIFO queue to draw (ADR
          // 0019) and drawing an empty one would silently book the loss at 0.
          await db.inventoryDao.adjustStock(
            line.productId,
            trip.vanStoreId,
            -line.quantity,
            kVanReturnDamageReason,
            performedBy,
            trackCost: false,
            outflowValueKobo: costKobo,
          );
        }

        events.add(
          await (select(
            vanReturnEvents,
          )..where((r) => r.id.equals(eventId))).getSingle(),
        );
        totalCredit += creditKobo;
        totalCost += costKobo;
        totalShells += line.shellsBack;
      }

      // The shell memo ACCUMULATES onto the trip across every return (spec §11).
      if (totalShells > 0) {
        await (update(vanTrips)
              ..where((t) => t.id.equals(tripId) & whereBusiness(t)))
            .write(
              VanTripsCompanion(
                shellsBack: Value(trip.shellsBack + totalShells),
                lastUpdatedAt: Value(DateTime.now()),
              ),
            );
        final tripRow = await (select(
          vanTrips,
        )..where((t) => t.id.equals(tripId) & whereBusiness(t))).getSingle();
        await db.syncDao.enqueueUpsert('van_trips', tripRow.toCompanion(true));
      }

      await db.activityLogDao.logActivity(
        action: 'van.return',
        description: totalCredit > 0
            ? 'Van return recorded — '
                  '${formatCurrency(totalCredit / 100)} credited to the driver'
            : 'Damaged van return recorded — no credit',
        staffId: performedBy,
        storeId: trip.sourceStoreId,
        entityType: 'van_trip',
        entityId: tripId,
      );

      return VanReturnResult(
        tripId: tripId,
        events: events,
        consumed: consumedAll,
        totalCreditKobo: totalCredit,
        totalCostKobo: totalCost,
        driverBalanceKoboAfter: await db.driverLedgerDao.getBalanceKobo(
          trip.driverUserId,
        ),
        alreadyApplied: false,
      );
    });
  }

  /// Sum duplicate (product, condition) lines into one and drop the degenerate
  /// ones, preserving first-appearance order. Good and damaged lines of the same
  /// product stay SEPARATE — they are different money events.
  List<VanReturnLine> _collapseReturnLines(List<VanReturnLine> lines) {
    final byKey = <String, VanReturnLine>{};
    for (final line in lines) {
      if (!kVanReturnConditions.contains(line.condition)) {
        throw ArgumentError('Unknown return condition: ${line.condition}');
      }
      if (line.quantity <= 0) continue;
      final key = '${line.productId} ${line.condition}';
      final existing = byKey[key];
      byKey[key] = existing == null
          ? line
          : VanReturnLine(
              productId: line.productId,
              quantity: existing.quantity + line.quantity,
              condition: line.condition,
              shellsBack: existing.shellsBack + line.shellsBack,
              crateShells: line.crateShells ?? existing.crateShells,
              // The FIRST id wins: it is the one a retry will carry.
              eventId: existing.eventId ?? line.eventId,
            );
    }
    return byKey.values.toList(growable: false);
  }

  /// The already-applied result when every id in [lines] is present, or null
  /// when the return is fresh. Reconstructed from the rows themselves, so it
  /// survives the app being killed mid-retry and holds no in-memory state.
  ///
  /// A PARTIAL match cannot happen — the write is one transaction — so any hit
  /// means the whole return landed.
  Future<VanReturnResult?> _existingReturn(
    String tripId,
    List<VanReturnLine> lines,
  ) async {
    final ids = [
      for (final l in lines)
        if (l.eventId != null) l.eventId!,
    ];
    if (ids.isEmpty || ids.length != lines.length) return null;

    final rows =
        await (select(vanReturnEvents)
              ..where((r) => whereBusiness(r) & r.id.isIn(ids)))
            .get();
    if (rows.isEmpty) return null;

    var credit = 0;
    var cost = 0;
    for (final r in rows) {
      credit += r.creditKobo;
      cost += r.costKobo;
    }
    final driverUserId = (await getTrip(tripId))?.driverUserId;
    return VanReturnResult(
      tripId: tripId,
      events: rows,
      // The per-lot split is not reconstructible from the event rows, and a
      // replay writes nothing, so there is nothing honest to report here.
      consumed: const [],
      totalCreditKobo: credit,
      totalCostKobo: cost,
      driverBalanceKoboAfter: driverUserId == null
          ? 0
          : await db.driverLedgerDao.getBalanceKobo(driverUserId),
      alreadyApplied: true,
    );
  }

  /// Draw [quantity] units of [productId] off [tripId]'s lots, **oldest lot
  /// first**, decrementing each lot's `qty_remaining` and returning what each
  /// segment was worth. **Must** run inside the caller's transaction.
  ///
  /// Throws [VanOverReturnException] when the lots cannot cover the count —
  /// checked BEFORE anything is written, so a rejected return leaves the cursor
  /// exactly as it found it.
  Future<List<VanLotConsumption>> _drawLotsForReturn({
    required String tripId,
    required String productId,
    required int quantity,
    required DateTime now,
  }) async {
    final lots =
        await (select(vanTripLots)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    t.tripId.equals(tripId) &
                    t.productId.equals(productId) &
                    t.qtyRemaining.isBiggerThanValue(0),
              )
              ..orderBy([
                (t) => OrderingTerm(expression: t.dispatchedAt),
                (t) => OrderingTerm(expression: t.id),
              ]))
            .get();

    final stillOut = lots.fold<int>(0, (sum, l) => sum + l.qtyRemaining);
    if (quantity > stillOut) {
      throw VanOverReturnException(
        productId: productId,
        requested: quantity,
        stillOut: stillOut,
        message: stillOut == 0
            ? 'None of that drink is still out on this trip, so it cannot be '
                  'returned. Check the count.'
            : 'Only $stillOut of that drink is still out on this trip — you '
                  'cannot return $quantity. Check the count.',
      );
    }

    final segments = <VanLotConsumption>[];
    var left = quantity;
    for (final lot in lots) {
      if (left <= 0) break;
      final take = left < lot.qtyRemaining ? left : lot.qtyRemaining;
      await (update(vanTripLots)
            ..where((t) => t.id.equals(lot.id) & whereBusiness(t)))
          .write(
            VanTripLotsCompanion(
              qtyRemaining: Value(lot.qtyRemaining - take),
              lastUpdatedAt: Value(now),
            ),
          );
      final updated = await (select(
        vanTripLots,
      )..where((t) => t.id.equals(lot.id))).getSingle();
      await db.syncDao.enqueueUpsert(
        'van_trip_lots',
        updated.toCompanion(true),
      );

      segments.add(
        VanLotConsumption(
          lotId: lot.id,
          productId: productId,
          quantity: take,
          loadPriceKobo: lot.loadPriceKobo,
          unitCostKobo: lot.unitCostKobo,
        ),
      );
      left -= take;
    }
    return segments;
  }

  // ── Remittances (#144, spec §4.7 / §5.3, ADR 0019 decision 2) ─────────────

  /// Every `van_remittance` payment row on [tripId], newest first — what the
  /// driver has handed in on this run.
  Stream<List<PaymentTransactionData>> watchRemittancesForTrip(String tripId) {
    return (select(paymentTransactions)
          ..where(
            (p) =>
                whereBusiness(p) &
                p.vanTripId.equals(tripId) &
                p.type.equals(kPaymentTypeVanRemittance),
          )
          ..orderBy([(p) => OrderingTerm.desc(p.createdAt)]))
        .watch();
  }

  /// The load-price value [tripId] has actually recovered in cash — `Σ` its
  /// un-voided remittances. #145's close artifact reads it as one half of
  /// `recovered_kobo` (the other half is good returns).
  Future<int> remittedKoboForTrip(String tripId) async {
    final rows =
        await (select(paymentTransactions)..where(
              (p) =>
                  whereBusiness(p) &
                  p.vanTripId.equals(tripId) &
                  p.type.equals(kPaymentTypeVanRemittance) &
                  p.voidedAt.isNull(),
            ))
            .get();
    var total = 0;
    for (final r in rows) {
      total += r.amountKobo;
    }
    return total;
  }

  /// Record cash a driver handed in against [tripId] — **both legs, in ONE
  /// transaction** (#144, van-sales spec §5.3).
  ///
  /// The two legs are the whole slice:
  ///  1. a driver-ledger **credit** (`payment_cash` / `payment_transfer`),
  ///     which is what moves the balance toward zero, and
  ///  2. a real `payment_transactions` row typed [kPaymentTypeVanRemittance],
  ///     `store_id` = the trip's **source warehouse** (never the van), and
  ///     `van_trip_id` = the trip.
  ///
  /// Leg 2 exists because of ADR 0019 decision 2: a road sale writes no payment
  /// row at all (#142), so this is the ONE moment van money enters the cash
  /// books. Writing only the ledger credit — which is what the original plan
  /// did — leaves remitted cash in a ledger the reconciliation never reads, and
  /// the owner's cash figure never learns the money arrived. They are one
  /// transaction for the same reason dispatch is: half a remittance is worse
  /// than none, because it looks settled.
  ///
  /// The payment row's `store_id` is the source warehouse and NOT the van: cash
  /// physically comes back to the yard, and stamping the van would put the money
  /// on a location that is excluded from every per-store figure — it would
  /// vanish.
  ///
  /// [method] is a `payment_transactions.method` value (`cash` | `transfer` |
  /// `pos` | `other` from the picker). Only `cash` books the ledger row as
  /// [kDriverLedgerTypePaymentCash]; every other tender is
  /// [kDriverLedgerTypePaymentTransfer], because the ledger's axis is *how the
  /// money moved*, of which the spec models exactly two.
  ///
  /// [paidOn] dates BOTH legs (the ledger's `activity_date` and the payment
  /// row's `created_at`, which is the day "Cash from drivers" counts it on).
  /// It defaults to now; note the cloud owns `created_at` on push
  /// (`scrubCreatedAt`), so a back-dated remittance keeps its date locally and
  /// takes the cloud's arrival stamp after a restore — the same divergence
  /// every dated payment row on this table already carries.
  ///
  /// Throws [ArgumentError] on a non-positive amount or an unknown method,
  /// [StateError] when the trip does not exist, and [VanTripNotOpenException]
  /// when it is already closed (spec §9.4 #16 — a closed trip is never edited
  /// in place).
  ///
  /// **A driver can never call this**: the only surface is behind
  /// `Gates.vanManage`, which a Driver-role user does not hold (spec §9.5 #21).
  Future<VanRemittanceResult> recordDriverPayment({
    required String tripId,
    required int amountKobo,
    required String method,
    required String performedBy,
    DateTime? paidOn,
    String? receiptPath,
    String? referenceNote,
  }) async {
    if (amountKobo <= 0) {
      throw ArgumentError('A payment must be greater than zero.');
    }
    if (!kVanRemittanceMethods.contains(method)) {
      throw ArgumentError('Unknown payment method: $method');
    }
    final now = paidOn ?? DateTime.now();

    return transaction(() async {
      final trip = await getTrip(tripId);
      if (trip == null) {
        throw StateError('Trip $tripId not found.');
      }
      if (trip.status != kVanTripStatusOpen) {
        throw VanTripNotOpenException(
          tripId: tripId,
          message:
              'This trip is already closed. Record the payment against the '
              'driver\'s current trip instead.',
        );
      }

      // Leg 2 FIRST — the ledger row references it, and a reference to a row
      // that does not exist yet is how audit trails rot.
      final paymentId = UuidV7.generate();
      final payment = PaymentTransactionsCompanion.insert(
        id: Value(paymentId),
        businessId: requireBusinessId(),
        // The SOURCE WAREHOUSE, never the van (see the doc comment).
        storeId: Value(trip.sourceStoreId),
        amountKobo: amountKobo,
        method: method,
        type: kPaymentTypeVanRemittance,
        vanTripId: Value(tripId),
        performedBy: Value(performedBy),
        // Explicit — this row is dated by the day the money arrived, and the
        // cash card counts it on its own `created_at`
        // ([[project_synced_write_explicit_id]]).
        createdAt: Value(now),
        lastUpdatedAt: Value(now),
      );
      await into(paymentTransactions).insert(payment);
      await db.syncDao.enqueueUpsert('payment_transactions', payment);

      // Leg 1 — the ledger CREDIT that moves the balance toward zero.
      final ledgerEntryId = await db.driverLedgerDao.postEntry(
        driverUserId: trip.driverUserId,
        tripId: tripId,
        type: method == 'cash'
            ? kDriverLedgerTypePaymentCash
            : kDriverLedgerTypePaymentTransfer,
        amountKobo: amountKobo,
        isCredit: true,
        referenceType: kDriverLedgerRefPayment,
        referenceId: paymentId,
        activityDate: now,
        performedBy: performedBy,
        paymentMethod: method,
        receiptPath: receiptPath,
        referenceNote: referenceNote,
      );

      await db.activityLogDao.logActivity(
        action: 'van.payment',
        description:
            'Driver payment of ${formatCurrency(amountKobo / 100)} '
            'recorded ($method)',
        staffId: performedBy,
        storeId: trip.sourceStoreId,
        entityType: 'van_trip',
        entityId: tripId,
      );

      return VanRemittanceResult(
        ledgerEntryId: ledgerEntryId,
        paymentTransactionId: paymentId,
        amountKobo: amountKobo,
        driverBalanceKoboAfter: await db.driverLedgerDao.getBalanceKobo(
          trip.driverUserId,
        ),
      );
    });
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
