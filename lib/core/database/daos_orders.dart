part of 'daos.dart';

@DriftAccessor(
  tables: [
    Orders,
    OrderItems,
    Products,
    Customers,
    SavedCarts,
    Categories,
    Inventory,
    StockTransactions,
    PaymentTransactions,
    WalletTransactions,
    CustomerWallets,
    Businesses,
    // §13.4 — read the per-brand deposit rate (Manufacturers.depositAmountKobo)
    // to snapshot it onto order_crate_lines at sale.
    Manufacturers,
  ],
)
class OrdersDao extends DatabaseAccessor<AppDatabase>
    with _$OrdersDaoMixin, BusinessScopedDao<AppDatabase> {
  OrdersDao(super.db);

  // ── Reads ──────────────────────────────────────────────────────────────────

  /// Every `payment_transactions` row for this business — the unified physical-
  /// cash tender ledger (`type` in {sale, wallet_topup, refund, expense}, each
  /// carrying its `method`). Newest first. Voided rows are kept; callers filter
  /// on `voidedAt`. This table has no `storeId`, so the Daily Reconciliation
  /// cash-flow summary that reads it (ADR 0014) is business-wide.
  Stream<List<PaymentTransactionData>> watchAllPaymentTransactions() {
    return (select(paymentTransactions)
          ..where((p) => whereBusiness(p))
          ..orderBy([(p) => OrderingTerm.desc(p.createdAt)]))
        .watch();
  }

  Future<OrderData?> findById(String id) {
    return (select(orders)
          ..where((o) => o.id.equals(id) & whereBusiness(o))
          ..limit(1))
        .getSingleOrNull();
  }

  Stream<List<OrderData>> watchPendingOrders() {
    return (select(orders)
          ..where((o) => whereBusiness(o) & o.status.equals('pending'))
          ..orderBy([(o) => OrderingTerm.desc(o.createdAt)]))
        .watch();
  }

  Stream<List<OrderData>> watchAllOrders() {
    return (select(orders)
          ..where((o) => whereBusiness(o))
          ..orderBy([(o) => OrderingTerm.desc(o.createdAt)]))
        .watch();
  }

  /// True once this business has at least one order row — the "Make a sale"
  /// signal for the Get-started checklist (issue #31 / Seam 3). A cheap
  /// COUNT(*) mapped to a bool and distinct-filtered so it only notifies on the
  /// empty → non-empty flip, mirroring the products-exist feed. Any order
  /// counts: a checkout recognizes revenue immediately, and even a later-voided
  /// sale still means the user has been through a checkout at least once.
  Stream<bool> watchAnyOrderExists() {
    final countCol = orders.id.count();
    return (selectOnly(orders)
          ..addColumns([countCol])
          ..where(whereBusiness(orders)))
        .watchSingle()
        .map((row) => (row.read(countCol) ?? 0) > 0)
        .distinct();
  }

  Stream<List<OrderData>> watchOrdersByStore(String? storeId) {
    return (select(orders)
          ..where((o) {
            final expr = whereBusiness(o);
            if (storeId != null) {
              return expr & o.storeId.equals(storeId);
            }
            return expr;
          })
          ..orderBy([(o) => OrderingTerm.desc(o.createdAt)]))
        .watch();
  }

  Stream<List<OrderData>> watchCompletedOrders() {
    return (select(orders)
          ..where((o) => whereBusiness(o) & o.status.equals('completed'))
          ..orderBy([(o) => OrderingTerm.desc(o.createdAt)]))
        .watch();
  }

  Stream<List<OrderData>> watchCancelledOrders() {
    return (select(orders)
          ..where((o) => whereBusiness(o) & o.status.equals('cancelled'))
          ..orderBy([(o) => OrderingTerm.desc(o.createdAt)]))
        .watch();
  }

  Stream<List<OrderData>> watchOrdersByCustomer(String customerId) {
    return (select(orders)
          ..where((o) => whereBusiness(o) & o.customerId.equals(customerId))
          ..orderBy([(o) => OrderingTerm.desc(o.createdAt)]))
        .watch();
  }

  // ── N+1 fix: single joined query + fold ────────────────────────────────────

  Stream<List<OrderWithItems>> watchAllOrdersWithItems({String? storeId}) {
    final query = select(orders).join([
      leftOuterJoin(orderItems, orderItems.orderId.equalsExp(orders.id)),
      leftOuterJoin(customers, customers.id.equalsExp(orders.customerId)),
      leftOuterJoin(products, products.id.equalsExp(orderItems.productId)),
    ]);
    query.where(whereBusiness(orders));
    if (storeId != null) {
      query.where(orders.storeId.equals(storeId));
    }
    query.orderBy([OrderingTerm.desc(orders.createdAt)]);

    return query.watch().map((rows) {
      // Fold flat join rows into structured OrderWithItems
      final Map<String, OrderWithItems> result = {};
      for (final row in rows) {
        final order = row.readTable(orders);
        final item = row.readTableOrNull(orderItems);
        final customer = row.readTableOrNull(customers);
        final product = row.readTableOrNull(products);

        result.putIfAbsent(order.id, () => OrderWithItems(order, [], customer));

        // Keep the line even when product is null — a Quick Sale (§12.3) has no
        // product; its name comes from the order item's price snapshot via
        // OrderItemDataWithProductData.displayName.
        if (item != null) {
          result[order.id]!.items.add(
            OrderItemDataWithProductData(item, product),
          );
        }
      }
      return result.values.toList();
    });
  }

  Stream<List<OrderWithItems>> watchPendingOrdersWithItems({String? storeId}) {
    final query = select(orders).join([
      leftOuterJoin(orderItems, orderItems.orderId.equalsExp(orders.id)),
      leftOuterJoin(customers, customers.id.equalsExp(orders.customerId)),
      leftOuterJoin(products, products.id.equalsExp(orderItems.productId)),
    ]);
    query.where(whereBusiness(orders) & orders.status.equals('pending'));
    if (storeId != null) {
      query.where(orders.storeId.equals(storeId));
    }
    query.orderBy([OrderingTerm.desc(orders.createdAt)]);

    return query.watch().map((rows) {
      final Map<String, OrderWithItems> result = {};
      for (final row in rows) {
        final order = row.readTable(orders);
        final item = row.readTableOrNull(orderItems);
        final customer = row.readTableOrNull(customers);
        final product = row.readTableOrNull(products);

        result.putIfAbsent(order.id, () => OrderWithItems(order, [], customer));

        if (item != null) {
          result[order.id]!.items.add(
            OrderItemDataWithProductData(item, product),
          );
        }
      }
      return result.values.toList();
    });
  }

  Future<List<OrderWithItems>> getOrdersPage({
    required String status,
    String? storeId,
    DateTime? from,
    DateTime? to,
    String? search,
    ({DateTime createdAt, String id})? cursor,
    int limit = 30,
  }) async {
    final query = select(orders).join([
      leftOuterJoin(customers, customers.id.equalsExp(orders.customerId)),
    ]);

    final Expression<bool> statusPredicate;
    if (status == 'cancelled') {
      // Refunded orders represent reversed sales and are grouped under the Cancelled tab.
      statusPredicate = orders.status.isIn(const ['cancelled', 'refunded']);
    } else {
      statusPredicate = orders.status.equals(status);
    }
    var predicate = whereBusiness(orders) & statusPredicate;

    if (storeId != null) {
      predicate = predicate & orders.storeId.equals(storeId);
    }

    final Expression<DateTime> orderDateExpr;
    if (status == 'completed') {
      orderDateExpr = coalesce([orders.completedAt, orders.createdAt]);
    } else if (status == 'cancelled') {
      orderDateExpr = coalesce([orders.cancelledAt, orders.createdAt]);
    } else {
      orderDateExpr = orders.createdAt;
    }

    if (from != null) {
      predicate = predicate & orderDateExpr.isBiggerOrEqualValue(from);
    }
    if (to != null) {
      predicate = predicate & orderDateExpr.isSmallerThanValue(to);
    }

    if (search != null && search.isNotEmpty) {
      final term = '%$search%';
      predicate = predicate & (
        orders.orderNumber.like(term) |
        orders.id.like(term) |
        customers.name.like(term)
      );
    }

    if (cursor != null) {
      predicate = predicate & (
        orders.createdAt.isSmallerThanValue(cursor.createdAt) |
        (orders.createdAt.equals(cursor.createdAt) & orders.id.isSmallerThanValue(cursor.id))
      );
    }

    query.where(predicate);

    query.orderBy([
      OrderingTerm.desc(orders.createdAt),
      OrderingTerm.desc(orders.id),
    ]);

    query.limit(limit);

    final rows = await query.get();
    if (rows.isEmpty) return const [];

    final ordersList = rows.map((r) => r.readTable(orders)).toList();
    final orderIds = ordersList.map((o) => o.id).toList();

    final itemsQuery = select(orders).join([
      leftOuterJoin(orderItems, orderItems.orderId.equalsExp(orders.id)),
      leftOuterJoin(customers, customers.id.equalsExp(orders.customerId)),
      leftOuterJoin(products, products.id.equalsExp(orderItems.productId)),
    ]);
    itemsQuery.where(orders.id.isIn(orderIds));
    itemsQuery.orderBy([
      OrderingTerm.desc(orders.createdAt),
      OrderingTerm.desc(orders.id),
    ]);

    final itemsRows = await itemsQuery.get();

    final Map<String, OrderWithItems> result = {};
    for (final row in rows) {
      final order = row.readTable(orders);
      final customer = row.readTableOrNull(customers);
      result[order.id] = OrderWithItems(order, [], customer);
    }

    for (final row in itemsRows) {
      final order = row.readTable(orders);
      final item = row.readTableOrNull(orderItems);
      final product = row.readTableOrNull(products);

      if (item != null && result.containsKey(order.id)) {
        result[order.id]!.items.add(
          OrderItemDataWithProductData(item, product),
        );
      }
    }

    return orderIds.map((id) => result[id]!).toList();
  }

  Stream<List<OrderWithItems>> watchOrdersPage({
    required String status,
    String? storeId,
    DateTime? from,
    DateTime? to,
    String? search,
    int limit = 30,
  }) {
    final query = select(orders).join([
      leftOuterJoin(customers, customers.id.equalsExp(orders.customerId)),
    ]);

    final Expression<bool> statusPredicate;
    if (status == 'cancelled') {
      // Refunded orders represent reversed sales and are grouped under the Cancelled tab.
      statusPredicate = orders.status.isIn(const ['cancelled', 'refunded']);
    } else {
      statusPredicate = orders.status.equals(status);
    }
    var predicate = whereBusiness(orders) & statusPredicate;

    if (storeId != null) {
      predicate = predicate & orders.storeId.equals(storeId);
    }

    final Expression<DateTime> orderDateExpr;
    if (status == 'completed') {
      orderDateExpr = coalesce([orders.completedAt, orders.createdAt]);
    } else if (status == 'cancelled') {
      orderDateExpr = coalesce([orders.cancelledAt, orders.createdAt]);
    } else {
      orderDateExpr = orders.createdAt;
    }

    if (from != null) {
      predicate = predicate & orderDateExpr.isBiggerOrEqualValue(from);
    }
    if (to != null) {
      predicate = predicate & orderDateExpr.isSmallerThanValue(to);
    }

    if (search != null && search.isNotEmpty) {
      final term = '%$search%';
      predicate = predicate & (
        orders.orderNumber.like(term) |
        orders.id.like(term) |
        customers.name.like(term)
      );
    }

    query.where(predicate);

    query.orderBy([
      OrderingTerm.desc(orders.createdAt),
      OrderingTerm.desc(orders.id),
    ]);

    query.limit(limit);

    return query.watch().switchMap((rows) {
      if (rows.isEmpty) return Stream.value(const <OrderWithItems>[]);

      final ordersList = rows.map((r) => r.readTable(orders)).toList();
      final orderIds = ordersList.map((o) => o.id).toList();

      final itemsQuery = select(orders).join([
        leftOuterJoin(orderItems, orderItems.orderId.equalsExp(orders.id)),
        leftOuterJoin(customers, customers.id.equalsExp(orders.customerId)),
        leftOuterJoin(products, products.id.equalsExp(orderItems.productId)),
      ]);
      itemsQuery.where(orders.id.isIn(orderIds));
      itemsQuery.orderBy([
        OrderingTerm.desc(orders.createdAt),
        OrderingTerm.desc(orders.id),
      ]);

      return itemsQuery.watch().map((itemsRows) {
        final Map<String, OrderWithItems> result = {};
        for (final r in rows) {
          final order = r.readTable(orders);
          final customer = r.readTableOrNull(customers);
          result[order.id] = OrderWithItems(order, [], customer);
        }

        for (final row in itemsRows) {
          final order = row.readTable(orders);
          final item = row.readTableOrNull(orderItems);
          final product = row.readTableOrNull(products);

          if (item != null && result.containsKey(order.id)) {
            result[order.id]!.items.add(
              OrderItemDataWithProductData(item, product),
            );
          }
        }

        return orderIds.map((id) => result[id]!).toList();
      });
    });
  }

  Stream<OrdersStats> watchOrdersStats({
    required String status,
    String? storeId,
    DateTime? from,
    DateTime? to,
    String? search,
  }) {
    final query = selectOnly(orders).join([
      leftOuterJoin(customers, customers.id.equalsExp(orders.customerId)),
    ]);

    final Expression<bool> statusPredicate;
    if (status == 'cancelled') {
      // Refunded orders represent reversed sales and are grouped under the Cancelled tab.
      statusPredicate = orders.status.isIn(const ['cancelled', 'refunded']);
    } else {
      statusPredicate = orders.status.equals(status);
    }
    var predicate = whereBusiness(orders) & statusPredicate;

    if (storeId != null) {
      predicate = predicate & orders.storeId.equals(storeId);
    }

    final Expression<DateTime> orderDateExpr;
    if (status == 'completed') {
      orderDateExpr = coalesce([orders.completedAt, orders.createdAt]);
    } else if (status == 'cancelled') {
      orderDateExpr = coalesce([orders.cancelledAt, orders.createdAt]);
    } else {
      orderDateExpr = orders.createdAt;
    }

    if (from != null) {
      predicate = predicate & orderDateExpr.isBiggerOrEqualValue(from);
    }
    if (to != null) {
      predicate = predicate & orderDateExpr.isSmallerThanValue(to);
    }

    if (search != null && search.isNotEmpty) {
      final term = '%$search%';
      predicate = predicate & (
        orders.orderNumber.like(term) |
        orders.id.like(term) |
        customers.name.like(term)
      );
    }

    query.where(predicate);

    final countCol = orders.id.count();
    final amountSum = orders.netAmountKobo.sum();
    final paidSum = orders.amountPaidKobo.sum();
    final depositSum = orders.crateDepositPaidKobo.sum();
    const refundedCol = CustomExpression<int>(
      "SUM(CASE WHEN orders.status = 'refunded' THEN 1 ELSE 0 END)",
    );

    query.addColumns([countCol, amountSum, paidSum, depositSum, refundedCol]);

    return query.watchSingle().map((row) {
      return OrdersStats(
        count: row.read(countCol) ?? 0,
        totalAmountKobo: row.read(amountSum) ?? 0,
        amountPaidKobo: row.read(paidSum) ?? 0,
        crateDepositPaidKobo: row.read(depositSum) ?? 0,
        refundedCount: row.read(refundedCol) ?? 0,
      );
    });
  }


  // ── Writes ─────────────────────────────────────────────────────────────────

  /// Enqueues the FULL order row for sync. Per-column order updates build a
  /// partial companion; a partial `orders` upsert omits NOT NULL columns
  /// (order_number, total_amount_kobo, …) and the cloud rejects it (23502).
  Future<void> _enqueueFullOrder(String id) async {
    final row = await (select(
      orders,
    )..where((o) => o.id.equals(id) & whereBusiness(o))).getSingleOrNull();
    if (row != null) {
      await db.syncDao.enqueueUpsert('orders', row.toCompanion(true));
    }
  }

  Future<void> assignRider(String orderId, String riderName) async {
    final now = DateTime.now();
    final comp = OrdersCompanion(
      id: Value(orderId),
      riderName: Value(riderName),
      lastUpdatedAt: Value(now),
    );
    await (update(
      orders,
    )..where((o) => o.id.equals(orderId) & whereBusiness(o))).write(comp);
    await _enqueueFullOrder(orderId);
  }

  /// Atomic order + items + inventory + ledger + payment + wallet in a single txn.
  /// Returns the new order ID.
  ///
  /// For a registered [customerId] the wallet double-entry is derived here from
  /// [totalAmountKobo], [amountPaidKobo], and [crateDepositPaidByManufacturer]
  /// (see [_postSaleWalletLegs]) — the customer's position is net (paid − total),
  /// so a wallet/partial/credit sale simply pays less than the total and the
  /// wallet goes negative by the balance owed. Walk-ins ([customerId] == null)
  /// never touch the wallet.
  Future<String> createOrder({
    required OrdersCompanion order,
    required List<OrderItemsCompanion> items,
    String? customerId,
    required int amountPaidKobo,
    required int totalAmountKobo,
    required String staffId,
    String? storeId,
    String paymentMethod = 'cash',
    // §13.4 — deposit actually paid at checkout, per manufacturer/brand. Empty
    // = no per-brand deposit captured yet (every crate brand is "no deposit" →
    // crate-track). Ring 3 checkout UI populates this.
    Map<String, int> crateDepositPaidByManufacturer = const {},
  }) {
    return db.transaction(() async {
      final orderId = order.id.present ? order.id.value : UuidV7.generate();

      final flagValue = await db.systemConfigDao.get(
        'feature.domain_rpcs_v2.record_sale',
      );
      final useDomainRpc = flagValue == 'true' || flagValue == '"true"';

      // Order header gets written locally on both paths so the UI flips
      // immediately. The id is the server's idempotency key.
      final orderWithTime = order.copyWith(
        id: Value(orderId),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await into(orders).insert(orderWithTime);

      // Inventory cache deduction with the stock guard. Done before
      // dispatch so an offline overdraw fails fast and the user sees the
      // failure synchronously. The server's `inventory_after` overwrites
      // these values when the response lands.
      for (final item in items) {
        final qty = item.quantity.value;
        final productId = item.productId.value;
        // Quick-sale line (§26.4): no product → bypass inventory entirely
        // (no deduction, no insufficient-stock check).
        if (productId == null) continue;
        final whId = item.storeId.value;

        final rowsAffected = await customUpdate(
          'UPDATE inventory SET quantity = quantity - ? '
          'WHERE business_id = ? AND product_id = ? '
          'AND store_id = ? AND quantity >= ?',
          variables: [
            Variable(qty),
            Variable(requireBusinessId()),
            Variable(productId),
            Variable(whId),
            Variable(qty),
          ],
          updates: {inventory},
        );
        if (rowsAffected == 0) {
          throw InsufficientStockException(
            productId: productId,
            requested: qty,
          );
        }
      }

      // Epic 2 / ADR 0005 — FIFO cost draw-down. Snapshot each line's
      // provisional per-unit COGS from the local batch queue and decrement the
      // consumed cost_batches (both within this sale transaction). Quick-sale
      // lines (no product) are excluded — they stay uncosted. Runs on BOTH sync
      // paths: pos_record_sale_v2 does not own the batch queue (#39 adds that
      // server-side), so the client decrements + pushes cost_batches directly.
      // COGS is the local batch-queue view only; units with no batch are
      // uncosted (0), matching the server (see CostBatchesDao.drawDownSale).
      final costLines = <SaleCostLine>[];
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        final pid = item.productId.value;
        if (pid == null) continue; // quick sale: no product, no batch
        costLines.add(
          SaleCostLine(
            index: i,
            productId: pid,
            storeId: item.storeId.value,
            quantity: item.quantity.value,
          ),
        );
      }
      final provisionalCogs = await db.costBatchesDao.drawDownSale(costLines);
      // Re-snapshot the provisional COGS onto the order lines; every downstream
      // write (local order_items and the v1/v2 push payloads) uses these.
      final costedItems = [
        for (var i = 0; i < items.length; i++)
          provisionalCogs.containsKey(i)
              ? items[i].copyWith(buyingPriceKobo: Value(provisionalCogs[i]!))
              : items[i],
      ];
      items = costedItems;

      // §13.4 crate dispatch + per-brand deposit record. For a REGISTERED
      // customer, record the crates taken at the sale, per brand:
      //   • write an order_crate_lines row (crates taken + the deposit RATE
      //     snapshot + the deposit PAID) — the Confirm Crate Returns modal reads
      //     this to classify full / part / no-deposit and settle returns;
      //   • for NO-DEPOSIT brands (depositPaid == 0, "crate-track") record an
      //     'issued' ledger row + balance increment, so a later return nets to
      //     zero — this is the fix for the "returned everything but still shows
      //     owing" bug.
      // Brands paid for in money ("money-track") DON'T get a crate balance
      // (decision 5: paid money → settle in money; the held deposit lives in the
      // wallet, added in Ring 6). Walk-ins hold no crate balance (rule #14).
      // Runs on BOTH sync paths: these rows are client-authored (pos_record_sale_v2
      // does not mint them). Crates per brand = bottle/track-empties line
      // quantities grouped by manufacturer (unit.toLowerCase() == 'bottle' &&
      // trackEmpties), the same basis the modal uses. The deposit rate is
      // per-manufacturer (Manufacturers.depositAmountKobo) — the crate value is
      // shared across a manufacturer's products.
      // §13.4 / rule #13 — crate tracking is Bar / Beer Distributor only. Guard
      // the whole block on the business type (the write-boundary enforcement):
      // even if a non-crate business somehow has a bottle+trackEmpties product
      // (the product-creation toggle now blocks new ones, but legacy/edge rows
      // may exist), it must NOT accrue crate ledger / order_crate_lines rows.
      final crateBiz =
          await (select(businesses)
                ..where((b) => b.id.equals(requireBusinessId()))
                ..limit(1))
              .getSingleOrNull();
      if (customerId != null &&
          isCrateBusiness(crateBiz?.type) &&
          (crateBiz?.tracksEmptyCrates ?? true)) {
        final cratesByManufacturer = <String, int>{};
        for (final item in items) {
          final productId = item.productId.value;
          if (productId == null) continue; // quick-sale line: no product
          final product =
              await (select(products)
                    ..where((p) => p.id.equals(productId) & whereBusiness(p))
                    ..limit(1))
                  .getSingleOrNull();
          if (product == null) continue;
          final mfrId = product.manufacturerId;
          if (mfrId == null) continue;
          if (product.unit.toLowerCase() != 'bottle' || !product.trackEmpties) {
            continue;
          }
          cratesByManufacturer.update(
            mfrId,
            (v) => v + item.quantity.value,
            ifAbsent: () => item.quantity.value,
          );
        }
        for (final entry in cratesByManufacturer.entries) {
          final mfrId = entry.key;
          final crates = entry.value;
          final mfr =
              await (select(manufacturers)
                    ..where((m) => m.id.equals(mfrId) & whereBusiness(m))
                    ..limit(1))
                  .getSingleOrNull();
          final rateKobo = mfr?.depositAmountKobo ?? 0;
          final depositPaid = crateDepositPaidByManufacturer[mfrId] ?? 0;

          await db.orderCrateLinesDao.insertLine(
            OrderCrateLinesCompanion.insert(
              businessId: requireBusinessId(),
              orderId: orderId,
              manufacturerId: mfrId,
              cratesTaken: crates,
              depositRateKobo: Value(rateKobo),
              depositPaidKobo: Value(depositPaid),
            ),
          );

          if (depositPaid == 0) {
            await db.crateLedgerDao.recordCrateIssueByCustomer(
              customerId: customerId,
              manufacturerId: mfrId,
              quantity: crates,
              performedBy: staffId,
              orderId: orderId,
            );
          }
        }
      }

      // §14.3 wallet double-entry — client-authored on BOTH sync paths
      // (invariant #3: wallet ledgers are append-only/derived, never
      // server-minted). pos_record_sale_v2 owns only the oversell-safe
      // stock/order/items/payment and receives no wallet amount, so these legs
      // must be posted here, before the path split. Walk-ins are a no-op.
      await _postSaleWalletLegs(
        customerId: customerId,
        orderId: orderId,
        staffId: staffId,
        totalAmountKobo: totalAmountKobo,
        amountPaidKobo: amountPaidKobo,
        paymentMethod: paymentMethod,
        crateDepositPaidByManufacturer: crateDepositPaidByManufacturer,
      );

      if (useDomainRpc) {
        // v2 thin-intent: server mints order_items, stock_tx, payment_tx,
        // and wallet_tx ids (gen_random_uuid). _applyDomainResponse is
        // the sole writer of those rows locally — no client-side mirror
        // until the RPC returns, otherwise local would gain duplicates
        // when the cloud ids land on next pull.
        final orderJson = serializeInsertable(orderWithTime);
        // Thin item shape — server computes total_kobo from quantity *
        // unit_price and mints the order_item id itself.
        final thinItems = items.map((item) {
          final ij = serializeInsertable(item);
          return <String, dynamic>{
            'product_id': ij['product_id'],
            'quantity': ij['quantity'],
            'unit_price_kobo': ij['unit_price_kobo'],
            if (ij.containsKey('buying_price_kobo'))
              'buying_price_kobo': ij['buying_price_kobo'],
            if (ij.containsKey('price_snapshot'))
              'price_snapshot': ij['price_snapshot'],
          };
        }).toList();

        // Resolve the sale-level store: explicit arg wins, otherwise
        // fall back to the first item's. The v2 RPC requires a single
        // store for both the order header and the stock movements.
        final saleStoreId = storeId ?? items.first.storeId.value;

        final payload = <String, dynamic>{
          'p_business_id': requireBusinessId(),
          'p_actor_id': staffId,
          'p_order_id': orderId,
          'p_order_number': orderJson['order_number'],
          'p_store_id': saleStoreId,
          'p_payment_type': orderJson['payment_type'],
          'p_items': thinItems,
          if (orderJson.containsKey('status')) 'p_status': orderJson['status'],
          if (customerId != null) 'p_customer_id': customerId,
          if (orderJson.containsKey('discount_kobo'))
            'p_discount_kobo': orderJson['discount_kobo'],
          'p_amount_paid_kobo': amountPaidKobo,
          if (orderJson.containsKey('crate_deposit_paid_kobo'))
            'p_crate_deposit_paid_kobo': orderJson['crate_deposit_paid_kobo'],
          if (orderJson.containsKey('rider_name'))
            'p_rider_name': orderJson['rider_name'],
          if (orderJson.containsKey('barcode'))
            'p_barcode': orderJson['barcode'],
          if (amountPaidKobo > 0) 'p_payment_method': paymentMethod,
          // The wallet ledger is client-authored on BOTH paths (invariant #3):
          // the full double-entry is posted by _postSaleWalletLegs before this
          // split, so the RPC's wallet branch stays a no-op — no wallet amount is
          // forwarded. (pos_record_sale_v2's single p_wallet_amount_kobo debit
          // cannot express a register-as-credit sale, so we never use it.)
        };
        await db.syncDao.enqueue(
          'domain:pos_record_sale_v2',
          jsonEncode(payload),
        );
        return orderId;
      }

      // v1 (flag-OFF) path: full local mirror + per-table upserts.
      await db.syncDao.enqueueUpsert('orders', orderWithTime);

      for (final item in items) {
        final itemId = item.id.present ? item.id.value : UuidV7.generate();
        final itemWithTime = item.copyWith(
          id: Value(itemId),
          orderId: Value(orderId),
          lastUpdatedAt: Value(DateTime.now()),
        );
        await into(orderItems).insert(itemWithTime);
        await db.syncDao.enqueueUpsert('order_items', itemWithTime);
      }

      for (final item in items) {
        final productId = item.productId.value;
        // Quick-sale line (§26.4): no product → no stock_transactions row.
        if (productId == null) continue;
        final txId = UuidV7.generate();
        final txComp = StockTransactionsCompanion.insert(
          id: Value(txId),
          businessId: requireBusinessId(),
          productId: productId,
          locationId: storeId ?? item.storeId.value,
          quantityDelta: -item.quantity.value,
          movementType: 'sale',
          orderId: Value(orderId),
          performedBy: Value(staffId),
          lastUpdatedAt: Value(DateTime.now()),
        );
        await into(stockTransactions).insert(txComp);
        await db.syncDao.enqueueUpsert('stock_transactions', txComp);
      }

      if (amountPaidKobo > 0) {
        final payId = UuidV7.generate();
        final payComp = PaymentTransactionsCompanion.insert(
          id: Value(payId),
          businessId: requireBusinessId(),
          amountKobo: amountPaidKobo,
          method: paymentMethod,
          type: 'sale',
          orderId: Value(orderId),
          performedBy: Value(staffId),
          lastUpdatedAt: Value(DateTime.now()),
        );
        await into(paymentTransactions).insert(payComp);
        await db.syncDao.enqueueUpsert('payment_transactions', payComp);
      }

      // NOTE: the wallet double-entry was posted by _postSaleWalletLegs above,
      // before the v1/v2 split — client-authored on both paths (invariant #3).

      // v1 also enqueues the updated inventory cache so the cloud converges.
      for (final item in items) {
        final productId = item.productId.value;
        // Quick-sale line (§26.4): no product → no inventory row to converge.
        if (productId == null) continue;
        final whId = item.storeId.value;
        final invRow =
            await (select(inventory)..where(
                  (t) =>
                      t.productId.equals(productId) &
                      t.storeId.equals(whId) &
                      whereBusiness(t),
                ))
                .getSingle();
        await db.syncDao.enqueueUpsert('inventory', invRow);
      }

      return orderId;
    });
  }

  /// §14.3 full wallet ledger (rule #4): every registered sale runs through
  /// the wallet. Post TWO legs — a debit for the order total (goods leave)
  /// and a credit for the amount paid at checkout (money in) — so the net
  /// (paid − total) is the customer's position: 0 when fully paid, negative
  /// when they owe. This includes fully-paid cash sales (debit total +
  /// credit total, net 0), so the wallet history is complete. The credit leg
  /// records the money against the customer's wallet. It reuses the existing
  /// top-up reference types (by method, mirroring WalletService) so no CHECK
  /// widening is needed. Walk-ins (customerId == null) never touch the wallet
  /// (rule #14).
  ///
  /// Client-authored on BOTH sync paths (invariant #3: wallet ledgers are
  /// append-only / derived, never server-minted). `pos_record_sale_v2` owns
  /// only the oversell-safe stock/order/items/payment and is passed NO wallet
  /// amount — its single `p_wallet_amount_kobo` debit cannot express a
  /// register-as-credit sale (it guards on an existing positive balance and
  /// would reject the customer owing money), so the full double-entry lives
  /// here for v1 and v2 alike. Must be called INSIDE the createOrder
  /// transaction, before the path split.
  Future<void> _postSaleWalletLegs({
    required String? customerId,
    required String orderId,
    required String staffId,
    required int totalAmountKobo,
    required int amountPaidKobo,
    required String paymentMethod,
    required Map<String, int> crateDepositPaidByManufacturer,
  }) async {
    if (customerId == null) return;
    final cid = customerId;
    final wallet =
        await (select(customerWallets)
              ..where(
                (w) =>
                    whereBusiness(w) &
                    w.customerId.equals(cid) &
                    w.isDeleted.not(),
              )
              ..limit(1))
            .getSingleOrNull();
    if (wallet == null) {
      throw StateError('Customer $cid has no wallet — cannot post sale');
    }

    // §14.3 — both legs of the sale are one event, so stamp them with the
    // SAME created_at. The wallet history is newest-first; on this tie the
    // DISPLAY query (WalletTransactionsDao.watchHistory) puts the order
    // DEBIT above the payment CREDIT via signed_amount_kobo ASC, so the
    // order charge (the last step of the sale) sits at the top. Net
    // (paid − total) is unchanged by the timestamp/ordering.
    final legTime = DateTime.now();

    // §13.4 Ring 6 — held-deposit carve-out. The deposit actually paid at
    // checkout (sum of the per-brand map) is refundable money the business
    // HOLDS, not goods revenue and not spendable wallet credit. So it must
    // not inflate the goods debt nor count as spendable. We carve it out of
    // BOTH legs and re-post it as a single `crate_deposit` held credit:
    //   • goods debit   = totalAmountKobo − depositHeld  (the real purchase)
    //   • goods credit  = amountPaidKobo  − depositHeld  (cash toward goods)
    //   • held credit   = depositHeld                    (deposit family)
    // Net SPENDABLE = (paid − held) − (total − held) = paid − total — exactly
    // the same position as before; only the deposit slice moves to the held
    // bucket (excluded from the spendable balance, §5 read-side). When no
    // deposit was paid this reduces to the original two legs unchanged.
    // [totalAmountKobo] is the grand total (goods + deposit) the checkout
    // passes, and the checkout guards paid ≥ deposit, so neither leg goes
    // negative; clamp defensively anyway.
    final depositHeldKobo = crateDepositPaidByManufacturer.values
        .fold<int>(0, (s, v) => s + v)
        .clamp(0, totalAmountKobo);
    final goodsDebitKobo = totalAmountKobo - depositHeldKobo;
    final goodsCreditKobo = (amountPaidKobo - depositHeldKobo).clamp(
      0,
      amountPaidKobo,
    );
    //
    // Leg 1 — debit the goods total (the purchase leaves the wallet).
    final debitComp = WalletTransactionsCompanion.insert(
      id: Value(UuidV7.generate()),
      businessId: requireBusinessId(),
      walletId: wallet.id,
      customerId: cid,
      type: 'debit',
      amountKobo: goodsDebitKobo,
      signedAmountKobo: -goodsDebitKobo,
      referenceType: 'order_payment',
      orderId: Value(orderId),
      performedBy: Value(staffId),
      createdAt: Value(legTime),
      lastUpdatedAt: Value(legTime),
    );
    await into(walletTransactions).insert(debitComp);
    await db.syncDao.enqueueUpsert('wallet_transactions', debitComp);

    // Leg 2 — credit the cash applied to goods (money into the wallet).
    // Skipped when nothing is left after the deposit carve-out (pure
    // credit / pay-from-wallet sale, or the payment only covered deposit).
    if (goodsCreditKobo > 0) {
      final creditComp = WalletTransactionsCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: requireBusinessId(),
        walletId: wallet.id,
        customerId: cid,
        type: 'credit',
        amountKobo: goodsCreditKobo,
        signedAmountKobo: goodsCreditKobo,
        referenceType: paymentMethod == 'cash'
            ? 'topup_cash'
            : 'topup_transfer',
        orderId: Value(orderId),
        performedBy: Value(staffId),
        createdAt: Value(legTime),
        lastUpdatedAt: Value(legTime),
      );
      await into(walletTransactions).insert(creditComp);
      await db.syncDao.enqueueUpsert('wallet_transactions', creditComp);
    }

    // Leg 3 — the held deposit (refundable, excluded from spendable). One
    // `crate_deposit` credit for the whole sale's paid deposit; the per-brand
    // split lives on order_crate_lines for the return modal to settle.
    if (depositHeldKobo > 0) {
      final heldComp = WalletTransactionsCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: requireBusinessId(),
        walletId: wallet.id,
        customerId: cid,
        type: 'credit',
        amountKobo: depositHeldKobo,
        signedAmountKobo: depositHeldKobo,
        referenceType: 'crate_deposit',
        orderId: Value(orderId),
        performedBy: Value(staffId),
        createdAt: Value(legTime),
        lastUpdatedAt: Value(legTime),
      );
      await into(walletTransactions).insert(heldComp);
      await db.syncDao.enqueueUpsert('wallet_transactions', heldComp);
    }
  }

  /// §13.4 Ring 5 — settle a MONEY-TRACK brand's deposit when its crates come
  /// back at Confirm. The brand's held deposit (`paidKobo`, posted as one
  /// `crate_deposit` credit at the sale) is fully resolved here:
  ///   • forfeit = deposit value of the crates KEPT ((taken − returned) × rate),
  ///     capped at what was paid → a `crate_deposit_forfeited` debit. That debit
  ///     is the ONLY record of the kept deposit; reports sum it as income
  ///     (forfeit = reports-only, user decision 2026-06-05). No new income row.
  ///   • refund = the rest of the held deposit the forfeit didn't consume →
  ///     a `crate_deposit_refunded` debit (drops held) PLUS either a
  ///     `crate_refund` spendable credit (refund to the wallet) or a
  ///     payment_transactions 'refund' cash-out row (refund as cash).
  ///   • shortfall = when the kept crates are worth MORE than a PARTIAL deposit,
  ///     the extra is a normal spendable wallet debt (`adjustment` debit,
  ///     decision 6).
  /// After this the order's deposit-family rows net to 0 (held fully resolved).
  /// Stock (addEmptyCrates) and the no-deposit crate-track path are the caller's
  /// job — this only moves money. Walk-ins never reach here (no wallet).
  Future<void> settleCrateDepositReturn({
    required String customerId,
    required String manufacturerId,
    required String orderId,
    required int takenCrates,
    required int returnedCrates,
    required int rateKobo,
    required int paidKobo,
    required bool refundAsCash,
    required String performedBy,
  }) async {
    if (paidKobo <= 0) return; // not money-track — nothing to settle
    final kept = takenCrates - returnedCrates < 0
        ? 0
        : (takenCrates - returnedCrates > takenCrates
              ? takenCrates
              : takenCrates - returnedCrates);
    final forfeitValue = kept * rateKobo;
    final forfeitRecorded = forfeitValue < paidKobo ? forfeitValue : paidKobo;
    final refundAmount = paidKobo - forfeitRecorded;
    final extraDebt = forfeitValue > paidKobo ? forfeitValue - paidKobo : 0;

    await transaction(() async {
      final wallet =
          await (select(customerWallets)
                ..where(
                  (w) =>
                      whereBusiness(w) &
                      w.customerId.equals(customerId) &
                      w.isDeleted.not(),
                )
                ..limit(1))
              .getSingleOrNull();
      if (wallet == null) {
        throw StateError(
          'Customer $customerId has no wallet — cannot settle crate deposit',
        );
      }
      final legTime = DateTime.now();

      Future<void> postWallet(int signed, String refType) async {
        final comp = WalletTransactionsCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: requireBusinessId(),
          walletId: wallet.id,
          customerId: customerId,
          type: signed >= 0 ? 'credit' : 'debit',
          amountKobo: signed.abs(),
          signedAmountKobo: signed,
          referenceType: refType,
          orderId: Value(orderId),
          performedBy: Value(performedBy),
          createdAt: Value(legTime),
          lastUpdatedAt: Value(legTime),
        );
        await into(walletTransactions).insert(comp);
        await db.syncDao.enqueueUpsert('wallet_transactions', comp);
      }

      // Forfeit: held → income (reports sum the forfeited rows).
      if (forfeitRecorded > 0) {
        await postWallet(-forfeitRecorded, 'crate_deposit_forfeited');
      }

      // Refund: drop the rest of the held deposit, then return it as wallet
      // credit (spendable) or cash (payment row, no spendable change).
      if (refundAmount > 0) {
        final refundedTxnId = UuidV7.generate();
        final refundedComp = WalletTransactionsCompanion.insert(
          id: Value(refundedTxnId),
          businessId: requireBusinessId(),
          walletId: wallet.id,
          customerId: customerId,
          type: 'debit',
          amountKobo: refundAmount,
          signedAmountKobo: -refundAmount,
          referenceType: 'crate_deposit_refunded',
          orderId: Value(orderId),
          performedBy: Value(performedBy),
          createdAt: Value(legTime),
          lastUpdatedAt: Value(legTime),
        );
        await into(walletTransactions).insert(refundedComp);
        await db.syncDao.enqueueUpsert('wallet_transactions', refundedComp);

        if (refundAsCash) {
          // payment_transactions requires EXACTLY ONE reference (order/shipment/
          // expense/wallet_txn/delivery). Link via the wallet txn — which itself
          // carries the orderId — mirroring WalletService's topup payment row.
          final payComp = PaymentTransactionsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: requireBusinessId(),
            amountKobo: refundAmount,
            method: 'cash',
            type: 'refund',
            performedBy: Value(performedBy),
            walletTxnId: Value(refundedTxnId),
            lastUpdatedAt: Value(legTime),
          );
          await into(paymentTransactions).insert(payComp);
          await db.syncDao.enqueueUpsert('payment_transactions', payComp);
        } else {
          await postWallet(refundAmount, 'crate_refund');
        }
      }

      // Shortfall: kept crates worth more than a partial deposit → wallet debt.
      if (extraDebt > 0) {
        await postWallet(-extraDebt, 'adjustment');
      }
    });
  }

  Future<void> markCompleted(String orderId, [String? staffId]) {
    return db.transaction(() async {
      final comp = OrdersCompanion(
        id: Value(orderId),
        status: const Value('completed'),
        staffId: staffId != null ? Value(staffId) : const Value.absent(),
        completedAt: Value(DateTime.now().toUtc()),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await (update(
        orders,
      )..where((o) => o.id.equals(orderId) & whereBusiness(o))).write(comp);
      await _enqueueFullOrder(orderId);
    });
  }

  /// Cancel/refund an order (§19.7): append compensating stock rows, void the
  /// payments, and reverse both wallet legs so the customer's wallet returns to
  /// its pre-sale balance. Inventory is restored.
  Future<void> markCancelled(
    String orderId,
    String reason,
    String staffId,
  ) async {
    final flagValue = await db.systemConfigDao.get(
      'feature.domain_rpcs_v2.cancel_order',
    );
    final useDomainRpc = flagValue == 'true' || flagValue == '"true"';

    return db.transaction(() async {
      final now = DateTime.now();

      // Update order status (both v1 and v2 paths flip the header locally
      // for immediate UI feedback).
      final ordComp = OrdersCompanion(
        id: Value(orderId),
        status: const Value('cancelled'),
        cancellationReason: Value(reason),
        cancelledAt: Value(now.toUtc()),
        lastUpdatedAt: Value(now),
      );
      await (update(
        orders,
      )..where((o) => o.id.equals(orderId) & whereBusiness(o))).write(ordComp);

      if (useDomainRpc) {
        // v2 path: thin envelope. The server mints UUIDs for compensating
        // stock_tx, refund payments, and wallet credits; _applyDomainResponse
        // inserts those rows locally from the RPC response so local and
        // cloud row ids stay in sync. While the queue is pending, local
        // shows the order as cancelled but the stock / payment / wallet
        // ledgers haven't been adjusted yet — they land when the RPC
        // returns or, if offline, when sync drains the outbox.
        final payload = <String, dynamic>{
          'p_business_id': requireBusinessId(),
          'p_actor_id': staffId,
          'p_order_id': orderId,
          'p_cancellation_reason': reason,
          // R2: until pos_cancel_order mints the wallet payment-leg reversal,
          // don't enable feature.domain_rpcs_v2.cancel_order.
        };
        await db.syncDao.enqueue(
          'domain:pos_cancel_order',
          jsonEncode(payload),
        );
        return;
      }

      // v1 path: full local mirror + per-table enqueues.
      await _enqueueFullOrder(orderId);

      // Stock: append COMPENSATING rows (ledger is append-only)
      final saleRows =
          await (select(stockTransactions)..where(
                (s) =>
                    s.orderId.equals(orderId) &
                    s.movementType.equals('sale') &
                    s.voidedAt.isNull(),
              ))
              .get();
      for (final row in saleRows) {
        final compId = UuidV7.generate();
        final compTx = StockTransactionsCompanion.insert(
          id: Value(compId),
          businessId: requireBusinessId(),
          productId: row.productId,
          locationId: row.locationId,
          quantityDelta: -row.quantityDelta, // positive (return)
          movementType: 'return',
          orderId: Value(orderId),
          performedBy: Value(staffId),
          lastUpdatedAt: Value(DateTime.now()),
        );
        await into(stockTransactions).insert(compTx);
        await db.syncDao.enqueueUpsert('stock_transactions', compTx);

        // Restore inventory
        await customUpdate(
          'UPDATE inventory SET quantity = quantity + ? '
          'WHERE business_id = ? AND product_id = ? AND store_id = ?',
          variables: [
            Variable(-row.quantityDelta),
            Variable(requireBusinessId()),
            Variable(row.productId),
            Variable(row.locationId),
          ],
          updates: {inventory},
        );

        final invRow =
            await (select(inventory)..where(
                  (t) =>
                      t.productId.equals(row.productId) &
                      t.storeId.equals(row.locationId) &
                      whereBusiness(t),
                ))
                .getSingle();
        await db.syncDao.enqueueUpsert('inventory', invRow);
      }

      // Payment: void metadata ONLY (never append a new payment row)
      await (update(
        paymentTransactions,
      )..where((p) => p.orderId.equals(orderId) & p.voidedAt.isNull())).write(
        PaymentTransactionsCompanion(
          voidedAt: Value(now.toUtc()),
          voidedBy: Value(staffId),
          voidReason: Value('order_cancelled: $reason'),
          lastUpdatedAt: Value(now),
        ),
      );
      final updatedPays = await (select(
        paymentTransactions,
      )..where((p) => p.orderId.equals(orderId) & whereBusiness(p))).get();
      for (final pay in updatedPays) {
        await db.syncDao.enqueueUpsert('payment_transactions', pay);
      }

      // Wallet: reverse BOTH legs the sale posted (§14.3) so the customer's
      // wallet returns to its exact pre-sale balance. createOrder debited the
      // order total (the purchase) and, when anything was paid now, credited the
      // amount paid (the payment). We append the opposite of each leg (the
      // ledger is append-only — never mutate): the debit becomes a 'refund'
      // credit, the payment-credit becomes a 'void' debit. Net wallet effect =
      // +total − paid, undoing the sale's −(total − paid). Walk-in orders have
      // no wallet legs, so this is a no-op for them.
      final saleWalletLegs =
          await (select(walletTransactions)..where(
                (t) =>
                    whereBusiness(t) &
                    t.orderId.equals(orderId) &
                    t.referenceType.isNotIn(const ['refund', 'void']),
              ))
              .get();
      for (final leg in saleWalletLegs) {
        final toCredit = leg.type == 'debit';
        final compReverse = WalletTransactionsCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: requireBusinessId(),
          walletId: leg.walletId,
          customerId: leg.customerId,
          type: toCredit ? 'credit' : 'debit',
          amountKobo: leg.amountKobo,
          signedAmountKobo: toCredit ? leg.amountKobo : -leg.amountKobo,
          referenceType: toCredit ? 'refund' : 'void',
          orderId: Value(orderId),
          performedBy: Value(staffId),
          lastUpdatedAt: Value(now),
        );
        await into(walletTransactions).insert(compReverse);
        await db.syncDao.enqueueUpsert('wallet_transactions', compReverse);
      }
    });
  }

  /// Completely undoes a sale the server PERMANENTLY REJECTED (an oversell:
  /// `pos_record_sale_v2` raised `insufficient_stock` / `inventory_row_missing`
  /// because a concurrent till took the last unit). Unlike [markCancelled] —
  /// which compensates a sale the cloud ACCEPTED and therefore pushes the
  /// reversal — a rejected sale never reached the cloud (the RPC rolled back its
  /// own transaction, and on the v2 path the local order/wallet/inventory writes
  /// were never enqueued as table rows). So this reversal is **purely local and
  /// never enqueued**: it just returns this device to its pre-sale state. The
  /// original sale's orphaned outbox rows stay visible on the Sync Issues screen
  /// (Invariant #12 — surfaced, never silently destroyed).
  ///
  /// [items] are the sold lines (product/store/qty) — sourced from the cart on
  /// the foreground path, or from the orphaned envelope's `p_items` on the
  /// background (cashier-tapped Cancel) path, because a v2 sale writes no local
  /// `order_items` to read back. Idempotent: a no-op if the order is already
  /// cancelled or absent.
  Future<void> reverseRejectedSaleLocal({
    required String orderId,
    required List<({String productId, String storeId, int quantity})> items,
    required String staffId,
  }) async {
    await db.transaction(() async {
      final order = await (select(
        orders,
      )..where((o) => o.id.equals(orderId) & whereBusiness(o))).getSingleOrNull();
      // Idempotent: nothing to undo if the order is gone or already reversed.
      if (order == null || order.status == 'cancelled') return;

      final now = DateTime.now();

      // 1. Cancel the order header (local-only — the v2 order never pushed).
      await (update(orders)..where((o) => o.id.equals(orderId))).write(
        OrdersCompanion(
          status: const Value('cancelled'),
          cancellationReason: const Value('rejected_by_server'),
          cancelledAt: Value(now.toUtc()),
          lastUpdatedAt: Value(now),
        ),
      );

      // 2. Refund the optimistic inventory pre-check deduction. Sourced from
      // [items] (a v2 sale writes no local stock_transactions to rewind). No
      // enqueue: on the v2 path the cloud's inventory_after is authoritative and
      // this cache re-converges on the next pull.
      for (final line in items) {
        await customUpdate(
          'UPDATE inventory SET quantity = quantity + ?, last_updated_at = ? '
          'WHERE business_id = ? AND product_id = ? AND store_id = ?',
          variables: [
            Variable<int>(line.quantity),
            Variable<DateTime>(now),
            Variable<String>(requireBusinessId()),
            Variable<String>(line.productId),
            Variable<String>(line.storeId),
          ],
          updates: {inventory},
        );
      }

      // 3. Reverse the §14.3 wallet double-entry so the customer's balance
      // returns to its exact pre-sale value. Same shape as [markCancelled]
      // (debit → 'refund' credit, credit → 'void' debit; net effect
      // +total − paid), but LOCAL-ONLY: the cloud never held these legs, so
      // pushing compensations would just FK-fail against the rejected order.
      // Walk-in sales have no wallet legs → this is a no-op.
      final saleWalletLegs =
          await (select(walletTransactions)..where(
                (t) =>
                    whereBusiness(t) &
                    t.orderId.equals(orderId) &
                    t.referenceType.isNotIn(const ['refund', 'void']),
              ))
              .get();
      for (final leg in saleWalletLegs) {
        final toCredit = leg.type == 'debit';
        final compReverse = WalletTransactionsCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: requireBusinessId(),
          walletId: leg.walletId,
          customerId: leg.customerId,
          type: toCredit ? 'credit' : 'debit',
          amountKobo: leg.amountKobo,
          signedAmountKobo: toCredit ? leg.amountKobo : -leg.amountKobo,
          referenceType: toCredit ? 'refund' : 'void',
          orderId: Value(orderId),
          performedBy: Value(staffId),
          createdAt: Value(now),
          lastUpdatedAt: Value(now),
        );
        await into(walletTransactions).insert(compReverse);
        // Intentionally NOT enqueued — local-only reversal of a rejected sale.
      }
    });
  }

  /// Builds the next order number for this business+device.
  ///
  /// `ORD-NNNNNN-XXXXXX` (master plan §30.8.1): `NNNNNN` is this device's
  /// running order count, `XXXXXX` is the stable per-device [deviceTag]. The
  /// tag is what makes the code unique across offline tills — the count alone
  /// collides because two offline devices both count locally. See BUILD_LOG
  /// Session 122.
  Future<String> generateOrderNumber(String deviceTag) async {
    final count =
        await (selectOnly(orders)
              ..where(whereBusiness(orders))
              ..addColumns([orders.id.count()]))
            .map((row) => row.read(orders.id.count()) ?? 0)
            .getSingle();
    return formatOrderNumber(count, deviceTag);
  }

  /// Heals a legacy order-number collision (§30.8.1). A pre-device-tag offline
  /// order can carry a number the cloud already holds under a different id; its
  /// upload then fails with the `(business_id, order_number)` duplicate-key
  /// error AND, because the local copy still occupies that number, the cloud's
  /// colliding order can never restore here (its children FK-orphan every pull).
  /// Appending THIS device's [deviceTag] turns the number into the standard
  /// `ORD-NNNNNN-XXXXXX` form, unique to this device, and re-enqueues it: the
  /// renumbered order uploads cleanly and the freed number lets the cloud's
  /// order land on the next pull. Both sales survive. Returns the new number, or
  /// null if the order is gone or already carries this device's tag (idempotent).
  Future<String?> renumberForCollisionHeal(
    String orderId,
    String deviceTag,
  ) async {
    final order = await (select(
      orders,
    )..where((t) => t.id.equals(orderId) & whereBusiness(t))).getSingleOrNull();
    if (order == null) return null;
    // Idempotency: don't double-append if a prior heal already tagged it.
    if (order.orderNumber.endsWith('-$deviceTag')) return null;
    final newNumber = '${order.orderNumber}-$deviceTag';
    await (update(
      orders,
    )..where((t) => t.id.equals(orderId) & whereBusiness(t))).write(
      OrdersCompanion(
        orderNumber: Value(newNumber),
        lastUpdatedAt: Value(DateTime.now()),
      ),
    );
    // Re-enqueue a FULL row so the cloud upsert carries every NOT NULL column.
    final updated = await (select(
      orders,
    )..where((t) => t.id.equals(orderId) & whereBusiness(t))).getSingle();
    await db.syncDao.enqueueUpsert('orders', updated.toCompanion(true));
    return newNumber;
  }

  // ── Timezone-aware analytics ───────────────────────────────────────────────

  Future<ProductSalesSummary> getSalesSummaryForProduct(
    String productId,
  ) async {
    final business = await (select(
      businesses,
    )..where((b) => whereBusiness(b))).getSingleOrNull();
    final tzName = business?.timezone ?? 'UTC';

    tz.Location location;
    try {
      location = tz.getLocation(tzName);
    } on tz.LocationNotFoundException {
      debugPrint('[OrdersDao] Invalid timezone "$tzName", falling back to UTC');
      location = tz.UTC;
    }

    final now = tz.TZDateTime.now(location);
    final todayStart = tz.TZDateTime(
      location,
      now.year,
      now.month,
      now.day,
    ).toUtc();
    final weekStart = tz.TZDateTime(
      location,
      now.year,
      now.month,
      now.day - 6,
    ).toUtc();
    final monthStart = tz.TZDateTime(location, now.year, now.month, 1).toUtc();

    final query =
        select(orderItems).join([
          innerJoin(orders, orders.id.equalsExp(orderItems.orderId)),
        ])..where(
          orderItems.productId.equals(productId) &
              // Revenue is recognized at checkout ('pending'), not at the
              // ceremonial Confirm ('completed'). Count any non-reversed sale.
              orders.status.isIn(const ['pending', 'completed']) &
              whereBusiness(orders),
        );

    final rows = await query.get();

    int todayUnits = 0, todayRevKobo = 0;
    int weekUnits = 0, weekRevKobo = 0;
    int monthUnits = 0, monthRevKobo = 0;

    for (final row in rows) {
      final item = row.readTable(orderItems);
      final order = row.readTable(orders);
      final date = order.createdAt.toUtc();

      if (!date.isBefore(monthStart)) {
        monthUnits += item.quantity;
        monthRevKobo += item.totalKobo;
      }
      if (!date.isBefore(weekStart)) {
        weekUnits += item.quantity;
        weekRevKobo += item.totalKobo;
      }
      if (!date.isBefore(todayStart)) {
        todayUnits += item.quantity;
        todayRevKobo += item.totalKobo;
      }
    }

    return ProductSalesSummary(
      todayUnits: todayUnits,
      todayRevenueKobo: todayRevKobo,
      weekUnits: weekUnits,
      weekRevenueKobo: weekRevKobo,
      monthUnits: monthUnits,
      monthRevenueKobo: monthRevKobo,
    );
  }

  // ── Cart staleness ─────────────────────────────────────────────────────────

  /// Compare each cart line's snapshot (productId, version, unitPriceKobo)
  /// against the live product row. Returns one [CartStaleItem] per drift —
  /// either the version was bumped (price/details changed since the line was
  /// added) or the resolved selling price differs.
  ///
  /// Single SELECT for the whole list (no N+1).
  Future<List<CartStaleItem>> checkCartStaleness(
    List<CartLineSnapshot> lines,
  ) async {
    if (lines.isEmpty) return const [];
    final ids = lines.map((l) => l.productId).toList();
    final rows =
        await (select(products)..where(
              (p) => p.id.isIn(ids) & p.isDeleted.not() & whereBusiness(p),
            ))
            .get();
    final byId = {for (final p in rows) p.id: p};

    final stale = <CartStaleItem>[];
    for (final line in lines) {
      final p = byId[line.productId];
      if (p == null) continue; // product gone; UI handles separately
      // Re-price against the SAME tier the line was priced at, so a correct
      // wholesaler line is not falsely flagged stale and reverted to retailer.
      final currentPriceKobo = line.priceTier == 'wholesaler'
          ? p.wholesalerPriceKobo
          : p.retailerPriceKobo;
      if (p.version != line.cartVersion ||
          currentPriceKobo != line.cartUnitPriceKobo) {
        stale.add(
          CartStaleItem(
            productId: p.id,
            productName: p.name,
            cartVersion: line.cartVersion,
            currentVersion: p.version,
            oldPriceKobo: line.cartUnitPriceKobo,
            newPriceKobo: currentPriceKobo,
          ),
        );
      }
    }
    return stale;
  }

  // ── Saved Carts ────────────────────────────────────────────────────────────

  /// Saved carts visible to [cashierId] (§13.5): only that cashier's own,
  /// and only those not yet expired (24h TTL). Legacy rows with a null
  /// [cashierId]/expiresAt are treated as un-scoped, un-expiring so pre-v17
  /// saved carts remain recallable.
  ///
  /// When [storeId] is non-null the list is confined to that store's saved
  /// carts (plus null-store legacy/All-Stores rows) so the Recall list follows
  /// the side-bar store (§12.1). A null [storeId] ("All Stores") returns every
  /// store's saved carts.
  Stream<List<SavedCartData>> watchSavedCarts(
    String? cashierId, {
    String? storeId,
  }) {
    final cutoff = DateTime.now();
    return (select(savedCarts)
          ..where(
            (c) =>
                whereBusiness(c) &
                (c.cashierId.isNull() | c.cashierId.equals(cashierId ?? '')) &
                (c.expiresAt.isNull() | c.expiresAt.isBiggerThanValue(cutoff)) &
                (storeId == null
                    ? const Constant(true)
                    : (c.storeId.isNull() | c.storeId.equals(storeId))),
          )
          ..orderBy([(c) => OrderingTerm.desc(c.createdAt)]))
        .watch();
  }

  Future<String> saveCart(SavedCartsCompanion companion) async {
    final id = companion.id.present ? companion.id.value : UuidV7.generate();
    // Stamp a 24h expiry (§13.5) unless the caller set one explicitly.
    final withExpiry = companion.expiresAt.present
        ? companion
        : companion.copyWith(
            expiresAt: Value(DateTime.now().add(const Duration(hours: 24))),
          );
    final row = withExpiry.copyWith(id: Value(id));
    await into(savedCarts).insert(row);
    // saved_carts is in `_syncedTenantTables` per app_database.dart, so the
    // §5 invariant requires the cloud to see this write. Without the
    // enqueue, multi-device cart resume silently breaks.
    await db.syncDao.enqueueUpsert('saved_carts', row);
    return id;
  }

  Future<void> deleteSavedCart(String id) async {
    await (delete(savedCarts)..where((c) => c.id.equals(id))).go();
    await db.syncDao.enqueueDelete('saved_carts', id);
  }

  /// Hard-deletes expired saved carts (§13.5) through [deleteSavedCart] so the
  /// cloud forgets them too (enqueues a tombstone per row). Call opportunistically
  /// — e.g. when the Recall list is opened.
  Future<void> deleteExpiredCarts() async {
    final cutoff = DateTime.now();
    final expired =
        await (select(savedCarts)..where(
              (c) =>
                  whereBusiness(c) &
                  c.expiresAt.isNotNull() &
                  c.expiresAt.isSmallerOrEqualValue(cutoff),
            ))
            .get();
    for (final row in expired) {
      await deleteSavedCart(row.id);
    }
  }

  Future<SavedCartData?> getSavedCart(String id) {
    return (select(savedCarts)
          ..where((c) => c.id.equals(id))
          ..limit(1))
        .getSingleOrNull();
  }
}

class ProductSalesSummary {
  final int todayUnits;
  final int todayRevenueKobo;
  final int weekUnits;
  final int weekRevenueKobo;
  final int monthUnits;
  final int monthRevenueKobo;

  const ProductSalesSummary({
    required this.todayUnits,
    required this.todayRevenueKobo,
    required this.weekUnits,
    required this.weekRevenueKobo,
    required this.monthUnits,
    required this.monthRevenueKobo,
  });

  factory ProductSalesSummary.empty() => const ProductSalesSummary(
    todayUnits: 0,
    todayRevenueKobo: 0,
    weekUnits: 0,
    weekRevenueKobo: 0,
    monthUnits: 0,
    monthRevenueKobo: 0,
  );
}

class OrdersStats {
  final int count;
  final int totalAmountKobo;
  final int amountPaidKobo;
  final int crateDepositPaidKobo;
  final int refundedCount;

  const OrdersStats({
    required this.count,
    required this.totalAmountKobo,
    required this.amountPaidKobo,
    required this.crateDepositPaidKobo,
    required this.refundedCount,
  });

  factory OrdersStats.empty() => const OrdersStats(
        count: 0,
        totalAmountKobo: 0,
        amountPaidKobo: 0,
        crateDepositPaidKobo: 0,
        refundedCount: 0,
      );
}

class OrderWithItems {
  final OrderData order;
  final List<OrderItemDataWithProductData> items;
  final CustomerData? customer;
  OrderWithItems(this.order, this.items, this.customer);
}

class OrderItemDataWithProductData {
  final OrderItemData item;

  /// Null for a Quick Sale line (§12.3) — an item not in inventory has no
  /// product. Use [displayName] for a label that works in both cases.
  final ProductData? product;
  OrderItemDataWithProductData(this.item, this.product);

  /// The line's display name: the product name when present, otherwise the
  /// name captured in the order item's price snapshot (Quick Sale), otherwise
  /// a generic "Quick Sale" label.
  String get displayName {
    final p = product;
    if (p != null) return p.name;
    final snap = item.priceSnapshot;
    if (snap != null) {
      try {
        final decoded = jsonDecode(snap);
        if (decoded is Map && decoded['name'] is String) {
          return decoded['name'] as String;
        }
      } catch (_) {}
    }
    return 'Quick Sale';
  }
}

class InsufficientStockException implements Exception {
  final String productId;
  final int requested;
  const InsufficientStockException({
    required this.productId,
    required this.requested,
  });
  @override
  String toString() =>
      'InsufficientStockException: product $productId, requested $requested';
}

class CartStaleItem {
  final String productId;
  final String productName;
  final int cartVersion;
  final int currentVersion;
  final int oldPriceKobo;
  final int newPriceKobo;
  const CartStaleItem({
    required this.productId,
    required this.productName,
    required this.cartVersion,
    required this.currentVersion,
    required this.oldPriceKobo,
    required this.newPriceKobo,
  });
}

class CartLineSnapshot {
  final String productId;
  final int cartVersion;
  final int cartUnitPriceKobo;

  /// The price tier the line was priced at ('retailer' | 'wholesaler').
  /// Defaults to 'retailer' so pre-tier callers/tests stay valid and legacy
  /// or Quick-Sale lines compare against the retailer column.
  final String priceTier;
  const CartLineSnapshot({
    required this.productId,
    required this.cartVersion,
    required this.cartUnitPriceKobo,
    this.priceTier = 'retailer',
  });
}

class CrateBalanceEntry {
  // v28/v29: crate balances are keyed by manufacturer (§13.4), not crate size.
  final String manufacturerId;
  final String manufacturerName;
  final int balance;
  CrateBalanceEntry({
    required this.manufacturerId,
    required this.manufacturerName,
    required this.balance,
  });
}

@DriftAccessor(tables: [OrderCrateLines])
class OrderCrateLinesDao extends DatabaseAccessor<AppDatabase>
    with _$OrderCrateLinesDaoMixin, BusinessScopedDao<AppDatabase> {
  OrderCrateLinesDao(super.db);

  /// All crate lines for an order (one per brand). Drives the Confirm Crate
  /// Returns modal — crates taken, deposit rate snapshot, and deposit paid
  /// (which decides full / part / no-deposit per brand, §13.4).
  Future<List<OrderCrateLineData>> getForOrder(String orderId) {
    return (select(
      orderCrateLines,
    )..where((t) => whereBusiness(t) & t.orderId.equals(orderId))).get();
  }

  Stream<List<OrderCrateLineData>> watchForOrder(String orderId) {
    return (select(
      orderCrateLines,
    )..where((t) => whereBusiness(t) & t.orderId.equals(orderId))).watch();
  }

  /// Resolve the store a manual crate return should be credited to (§16.8.1):
  /// the store of the customer's most recent order that carried crates for
  /// [manufacturerId]. Empties are credited to "the store the order was created
  /// from" so per-store balances stay accurate regardless of the active store.
  /// Returns null when the customer has no store-stamped order for that brand
  /// (caller falls back to the active store).
  Future<String?> resolveStoreForCustomerManufacturer({
    required String customerId,
    required String manufacturerId,
  }) async {
    final lineOrderIds =
        await (select(orderCrateLines)..where(
              (t) =>
                  whereBusiness(t) & t.manufacturerId.equals(manufacturerId),
            ))
            .map((r) => r.orderId)
            .get();
    if (lineOrderIds.isEmpty) return null;
    final order =
        await (db.select(db.orders)
              ..where(
                (o) =>
                    o.businessId.equals(requireBusinessId()) &
                    o.customerId.equals(customerId) &
                    o.id.isIn(lineOrderIds) &
                    o.storeId.isNotNull(),
              )
              ..orderBy([(o) => OrderingTerm.desc(o.createdAt)])
              ..limit(1))
            .getSingleOrNull();
    return order?.storeId;
  }

  /// Record one (order, brand) crate line at sale (§13.4) and enqueue it for
  /// sync. Routed through the DAO so the write reaches the cloud (CLAUDE.md §5).
  /// Stamps business_id + last_updated_at like the other synced-table writers.
  Future<void> insertLine(OrderCrateLinesCompanion line) async {
    // Set the id EXPLICITLY so the local insert and the enqueued cloud upsert
    // share it. Without this, the local insert uses the table's clientDefault
    // (a fresh uuid) while the enqueued companion has id Absent → the cloud
    // mints a DIFFERENT id → its echo/pull tries to insert that id and collides
    // with the local row on the UNIQUE(business_id, order_id, manufacturer_id)
    // constraint (SqliteException 2067). Every other DAO sets id before write.
    final row = line.copyWith(
      id: line.id.present ? line.id : Value(UuidV7.generate()),
      businessId: Value(requireBusinessId()),
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(orderCrateLines).insert(row);
    await db.syncDao.enqueueUpsert('order_crate_lines', row);
  }
}

@DriftAccessor(tables: [QuickSaleRequests])
class QuickSaleRequestsDao extends DatabaseAccessor<AppDatabase>
    with _$QuickSaleRequestsDaoMixin, BusinessScopedDao<AppDatabase> {
  QuickSaleRequestsDao(super.db);

  /// All still-pending Quick Sale requests for the business, newest first.
  /// Approver-side store scoping (a Manager only sees their store's requests) is
  /// applied in the UI, mirroring the stock-approvals pattern (§16.6.1).
  Stream<List<QuickSaleRequestData>> watchPending() {
    return (select(quickSaleRequests)
          ..where((t) => whereBusiness(t) & t.status.equals('pending'))
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  /// Watch a single request by id — the cashier's modal observes this to react
  /// when a Manager/CEO approves or rejects (the status flip arrives via the
  /// realtime/pull sync path on the cashier's device). Emits null if the row
  /// doesn't exist locally yet.
  Stream<QuickSaleRequestData?> watchRequest(String id) {
    return (select(
      quickSaleRequests,
    )..where((t) => t.id.equals(id) & whereBusiness(t))).watchSingleOrNull();
  }

  /// §12.3.1 — a cashier (role below Manager) submits a Quick Sale for approval.
  /// Writes a `pending` row only (nothing reaches the cart yet) and fires an
  /// approval-request notification to the CEO and the Manager(s) of the active
  /// selling store. If no Manager is tied to that store, only the CEO is
  /// notified (same audience rule as stock approvals, §16.6.1). Returns the new
  /// request id so the caller can watch it.
  Future<String> requestQuickSale({
    required String storeId,
    required String itemName,
    required double quantity,
    required int unitPriceKobo,
    required String summary,
    required String? requestedBy,
  }) async {
    final row = QuickSaleRequestsCompanion.insert(
      id: Value(UuidV7.generate()),
      businessId: requireBusinessId(),
      storeId: storeId,
      itemName: itemName,
      quantity: quantity,
      unitPriceKobo: unitPriceKobo,
      summary: summary,
      requestedBy: Value(requestedBy),
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(quickSaleRequests).insert(row);
    await db.syncDao.enqueueUpsert('quick_sale_requests', row);

    await db.activityLogDao.log(
      action: 'quick_sale_requested',
      description: 'Requested Quick Sale approval: $summary',
      staffId: requestedBy,
      storeId: storeId,
    );

    // Approval audience: CEO (never store-assigned) + Manager(s) of this store.
    final ceoIds = await db.userBusinessesDao.getUserIdsForRoleSlugs(['ceo']);
    final managerIds = await db.userBusinessesDao.getUserIdsForRoleSlugs([
      'manager',
    ]);
    final storeUserIds = (await db.userStoresDao.getUserIdsForStore(
      storeId,
    )).toSet();
    final storeManagerIds = managerIds.where(storeUserIds.contains);
    for (final uid in <String>{...ceoIds, ...storeManagerIds}) {
      await db.notificationsDao.fireNotification(
        type: 'quick_sale_approval.requested',
        message: 'Quick Sale approval needed: $summary',
        severity: 'info',
        linkedRecordId: row.id.value,
        recipientUserId: uid,
      );
    }
    return row.id.value;
  }

  /// Approve a pending Quick Sale request: flip the row to `approved` and notify
  /// the cashier. A Quick Sale bypasses inventory (§26.4), so approval moves NO
  /// stock — the cashier's device drops the item into the cart when it sees the
  /// status flip via [watchRequest].
  Future<void> approveRequest({
    required String requestId,
    required String approverId,
  }) async {
    String? requestedBy;
    String? summary;
    var didApprove = false;

    await transaction(() async {
      final req =
          await (select(quickSaleRequests)
                ..where((t) => t.id.equals(requestId) & whereBusiness(t)))
              .getSingleOrNull();
      if (req == null || req.status != 'pending') return;

      final now = DateTime.now();
      final affected =
          await (update(quickSaleRequests)..where(
                (t) =>
                    t.id.equals(requestId) &
                    whereBusiness(t) &
                    t.status.equals('pending'),
              ))
              .write(
                QuickSaleRequestsCompanion(
                  status: const Value('approved'),
                  approvedBy: Value(approverId),
                  approvedAt: Value(now),
                  lastUpdatedAt: Value(now),
                ),
              );
      if (affected == 0) return; // lost the race
      didApprove = true;
      requestedBy = req.requestedBy;
      summary = req.summary;

      final updated = await (select(
        quickSaleRequests,
      )..where((t) => t.id.equals(requestId) & whereBusiness(t))).getSingle();
      await db.syncDao.enqueueUpsert(
        'quick_sale_requests',
        updated.toCompanion(true),
      );

      await db.activityLogDao.log(
        action: 'quick_sale_request_approved',
        description: 'Approved Quick Sale: ${req.summary}',
        staffId: approverId,
        storeId: req.storeId,
      );
    });

    if (didApprove && requestedBy != null) {
      await db.notificationsDao.fireNotification(
        type: 'quick_sale_approval.approved',
        message: 'Your Quick Sale was approved — $summary',
        severity: 'info',
        linkedRecordId: requestId,
        recipientUserId: requestedBy,
      );
    }
  }

  /// Reject a pending request — nothing reaches the cart. The optional [reason]
  /// is shown to the cashier in the rejection notification and recorded in the
  /// activity log. Notifies the cashier (their modal closes on the flip).
  Future<void> rejectRequest({
    required String requestId,
    required String approverId,
    String? reason,
  }) async {
    final trimmedReason = reason?.trim();
    final hasReason = trimmedReason != null && trimmedReason.isNotEmpty;
    String? requestedBy;
    var didReject = false;

    await transaction(() async {
      final req =
          await (select(quickSaleRequests)
                ..where((t) => t.id.equals(requestId) & whereBusiness(t)))
              .getSingleOrNull();
      if (req == null || req.status != 'pending') return;
      final now = DateTime.now();
      final affected =
          await (update(quickSaleRequests)..where(
                (t) =>
                    t.id.equals(requestId) &
                    whereBusiness(t) &
                    t.status.equals('pending'),
              ))
              .write(
                QuickSaleRequestsCompanion(
                  status: const Value('rejected'),
                  approvedBy: Value(approverId),
                  approvedAt: Value(now),
                  lastUpdatedAt: Value(now),
                ),
              );
      if (affected == 0) return;
      didReject = true;
      requestedBy = req.requestedBy;

      final updated = await (select(
        quickSaleRequests,
      )..where((t) => t.id.equals(requestId) & whereBusiness(t))).getSingle();
      await db.syncDao.enqueueUpsert(
        'quick_sale_requests',
        updated.toCompanion(true),
      );

      await db.activityLogDao.log(
        action: 'quick_sale_request_rejected',
        description:
            'Rejected Quick Sale: ${req.summary}'
            '${hasReason ? ' — Reason: $trimmedReason' : ''}',
        staffId: approverId,
        storeId: req.storeId,
      );
    });

    if (didReject && requestedBy != null) {
      await db.notificationsDao.fireNotification(
        type: 'quick_sale_approval.rejected',
        message:
            'Your Quick Sale was rejected'
            '${hasReason ? ' — $trimmedReason' : '.'}',
        severity: 'warning',
        linkedRecordId: requestId,
        recipientUserId: requestedBy,
      );
    }
  }

  /// Withdraw a still-pending request (the cashier closed the waiting modal).
  /// Flips to `cancelled` so it leaves the approvers' pending list and can no
  /// longer be approved into the cart. No notification — the cashier acted.
  Future<void> cancelRequest({required String requestId}) async {
    await transaction(() async {
      final req =
          await (select(quickSaleRequests)
                ..where((t) => t.id.equals(requestId) & whereBusiness(t)))
              .getSingleOrNull();
      if (req == null || req.status != 'pending') return;
      final now = DateTime.now();
      final affected =
          await (update(quickSaleRequests)..where(
                (t) =>
                    t.id.equals(requestId) &
                    whereBusiness(t) &
                    t.status.equals('pending'),
              ))
              .write(
                QuickSaleRequestsCompanion(
                  status: const Value('cancelled'),
                  lastUpdatedAt: Value(now),
                ),
              );
      if (affected == 0) return;

      final updated = await (select(
        quickSaleRequests,
      )..where((t) => t.id.equals(requestId) & whereBusiness(t))).getSingle();
      await db.syncDao.enqueueUpsert(
        'quick_sale_requests',
        updated.toCompanion(true),
      );

      await db.activityLogDao.log(
        action: 'quick_sale_request_cancelled',
        description: 'Withdrew Quick Sale request: ${req.summary}',
        staffId: req.requestedBy,
        storeId: req.storeId,
      );
    });
  }
}
