part of 'daos.dart';

@DriftAccessor(
  tables: [
    Products,
    Inventory,
    Stores,
    CrateSizeGroups,
    Manufacturers,
    Categories,
    StockAdjustments,
    StockTransactions,
    CrateLedger,
  ],
)
class InventoryDao extends DatabaseAccessor<AppDatabase>
    with _$InventoryDaoMixin, BusinessScopedDao<AppDatabase> {
  InventoryDao(super.db);

  /// Every applied stock adjustment for the business, newest first. Drives the
  /// §25.10 Business Statement / Store Reconciliation damages roll-up — damages
  /// are the adjustments whose `reason` is tagged `damage:<key>` (§17.2) with a
  /// negative `quantityDiff`. Business-scoped.
  Stream<List<StockAdjustmentData>> watchAllAdjustments() {
    return (select(stockAdjustments)
          ..where((t) => whereBusiness(t))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .watch();
  }

  /// Every `damaged` empty-crate movement for the business, newest first
  /// (§17.2 crate-aware damages — the stored-empty fate written by
  /// [recordEmptyCrateDamage]). These carry no stock_adjustment because no drink
  /// is lost, so the §25.10 Statement sums their forfeited deposit from here
  /// instead. Business-scoped.
  Stream<List<CrateLedgerData>> watchAllCrateDamages() {
    return (select(crateLedger)
          ..where((t) => whereBusiness(t) & t.movementType.equals('damaged'))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .watch();
  }

  Stream<List<ManufacturerData>> watchAllManufacturers() {
    return (select(manufacturers)
          ..where((t) => whereBusiness(t) & t.isDeleted.not())
          ..orderBy([(t) => OrderingTerm(expression: t.name)]))
        .watch();
  }

  Future<List<ManufacturerData>> getAllManufacturers() {
    return (select(manufacturers)
          ..where((t) => whereBusiness(t) & t.isDeleted.not())
          ..orderBy([(t) => OrderingTerm(expression: t.name)]))
        .get();
  }

  Future<String> insertManufacturer(ManufacturersCompanion companion) async {
    final id = UuidV7.generate();
    final row = companion.copyWith(
      id: Value(id),
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(manufacturers).insert(row);
    await db.syncDao.enqueueUpsert('manufacturers', row);
    return id;
  }

  /// Enqueues the FULL manufacturer row for sync. A partial `manufacturers`
  /// upsert omits the NOT NULL `name`, which the cloud rejects (23502), so the
  /// per-column updates below read the row back and enqueue every column.
  Future<void> _enqueueFullManufacturer(String id) async {
    final row = await (select(
      manufacturers,
    )..where((t) => t.id.equals(id) & whereBusiness(t))).getSingleOrNull();
    if (row != null) {
      await db.syncDao.enqueueUpsert('manufacturers', row.toCompanion(true));
    }
  }

  /// Manually set a manufacturer's empty-crate count (management dialog).
  /// Delegates to the Crate Pool seam (#157), which records the correction as a
  /// reconciling ledger delta and maintains the scalar + per-store caches.
  Future<void> updateManufacturerStock(
    String id,
    int newStock, {
    String? storeId,
  }) async {
    await db.cratePoolDao.recordManualCountCorrection(
      id,
      newStock,
      storeId: storeId,
    );
  }

  Future<void> updateManufacturerDeposit(String id, int depositKobo) async {
    final now = DateTime.now();
    final comp = ManufacturersCompanion(
      id: Value(id),
      depositAmountKobo: Value(depositKobo),
      lastUpdatedAt: Value(now),
    );
    await (update(
      manufacturers,
    )..where((t) => t.id.equals(id) & whereBusiness(t))).write(comp);
    await _enqueueFullManufacturer(id);
  }

  Future<List<ProductDataWithStock>> getProductsWithStock({
    String? storeId,
  }) async {
    final ps =
        await (select(products)
              ..where((t) => whereBusiness(t) & t.isDeleted.not())
              ..orderBy([(t) => OrderingTerm(expression: t.name)]))
            .get();
    final invQuery = select(inventory)..where((t) => whereBusiness(t));
    if (storeId != null) {
      invQuery.where((t) => t.storeId.equals(storeId));
    }
    final invs = await invQuery.get();
    final totals = <String, int>{};
    for (final i in invs) {
      totals[i.productId] = (totals[i.productId] ?? 0) + i.quantity;
    }
    return ps
        .map(
          (p) =>
              ProductDataWithStock(product: p, totalStock: totals[p.id] ?? 0),
        )
        .toList();
  }

  Stream<List<ProductDataWithStock>> _watchProductsWithStock({
    String? categoryId,
    String? storeId,
    bool lowStockOnly = false,
  }) {
    final productsQuery = select(products)
      ..where((t) => whereBusiness(t) & t.isDeleted.not())
      ..orderBy([(t) => OrderingTerm(expression: t.name)]);
    if (categoryId != null) {
      productsQuery.where((t) => t.categoryId.equals(categoryId));
    }
    final invQuery = select(inventory)..where((t) => whereBusiness(t));
    if (storeId != null) {
      invQuery.where((t) => t.storeId.equals(storeId));
    }
    return Rx.combineLatest2<
      List<ProductData>,
      List<InventoryData>,
      List<ProductDataWithStock>
    >(productsQuery.watch(), invQuery.watch(), (ps, invs) {
      final totals = <String, int>{};
      for (final i in invs) {
        totals[i.productId] = (totals[i.productId] ?? 0) + i.quantity;
      }
      final out = ps
          .map(
            (p) =>
                ProductDataWithStock(product: p, totalStock: totals[p.id] ?? 0),
          )
          .toList();
      if (lowStockOnly) {
        return out
            .where((e) => e.totalStock <= e.product.lowStockThreshold)
            .toList();
      }
      return out;
    });
  }

  Stream<List<ProductDataWithStock>> watchProductsByCategory(
    String? categoryId,
  ) => _watchProductsWithStock(categoryId: categoryId);

  Stream<List<ProductDataWithStock>> watchProductsByStore(String storeId) =>
      _watchProductsWithStock(storeId: storeId);

  Stream<List<ProductDataWithStock>> watchAllProductDatasWithStock() =>
      _watchProductsWithStock();

  /// Live products-with-stock for a store scope where null = All Stores. Lets
  /// the Product Details screen refresh in real time across either scope (§5).
  Stream<List<ProductDataWithStock>> watchProductsWithStock({
    String? storeId,
  }) => _watchProductsWithStock(storeId: storeId);

  Stream<List<ProductDataWithStock>> watchLowStockProductDatas() =>
      _watchProductsWithStock(lowStockOnly: true);

  Stream<List<ProductDataWithStock>> watchProductDatasWithStockByStore(
    String storeId,
  ) => _watchProductsWithStock(storeId: storeId);

  // No callers as of PR 4a; empty crates aren't tracked per-store in the
  // current schema (manufacturer- and crate-group-scoped only). Returns 0 so
  // any future caller renders cleanly until PR 4c rewires crate aggregates.
  Stream<int> watchTotalEmptyCratesByStore(String? storeId) =>
      Stream<int>.value(0);

  /// Adjust on-hand inventory by [delta] for ([productId], [storeId]).
  /// Append-only: writes a `stock_adjustments` row + a `stock_transactions`
  /// ledger row referencing it, then UPSERTs the inventory cache. Negative
  /// delta is guarded against quantity going negative.
  ///
  /// [movementType] defaults to 'adjustment'. Pass 'transfer_out' or
  /// 'transfer_in' for stock transfer legs (§16.8.1), along with [refId]
  /// = the StockTransfers.id (maps to stock_transactions.transfer_id in the
  /// v2 RPC via ref_type='transfer').
  Future<void> adjustStock(
    String productId,
    String storeId,
    int delta,
    String note,
    String? staffId, {
    String movementType = 'adjustment',
    String? refId,
  }) async {
    if (delta == 0) return;
    await transaction(() async {
      // v2 path: emit a single `domain:pos_inventory_delta_v2` envelope.
      // The server mints stock_adjustments + stock_transactions rows
      // (`gen_random_uuid()`) and returns them via `_applyDomainResponse`,
      // which is the sole writer of those rows locally so ids match
      // cloud exactly.
      final flagValue = await db.systemConfigDao.get(
        'feature.domain_rpcs_v2.inventory_delta',
      );
      final useDomainRpc = flagValue == 'true' || flagValue == '"true"';

      // Inventory cache always updates locally for immediate UI feedback;
      // the RPC's `inventory_after` overwrites with the server's
      // authoritative value when the response lands. We deliberately do
      // NOT set `last_updated_at` here — the `bump_inventory_last_updated_at`
      // trigger writes an integer epoch, which is what Drift's deserialiser
      // expects. Setting it via SQL `CURRENT_TIMESTAMP` would store ISO
      // text and break later reads.
      if (delta >= 0) {
        await customInsert(
          'INSERT INTO inventory (id, business_id, product_id, store_id, quantity) '
          'VALUES (?, ?, ?, ?, ?) '
          'ON CONFLICT(business_id, product_id, store_id) DO UPDATE SET '
          'quantity = quantity + excluded.quantity',
          variables: [
            Variable(UuidV7.generate()),
            Variable(requireBusinessId()),
            Variable(productId),
            Variable(storeId),
            Variable(delta),
          ],
          updates: {inventory},
        );
      } else {
        // Decrement with stock guard.
        final rowsAffected = await customUpdate(
          'UPDATE inventory SET quantity = quantity + ? '
          'WHERE business_id = ? AND product_id = ? AND store_id = ? '
          'AND quantity >= ?',
          variables: [
            Variable(delta),
            Variable(requireBusinessId()),
            Variable(productId),
            Variable(storeId),
            Variable(-delta),
          ],
          updates: {inventory},
        );
        if (rowsAffected == 0) {
          throw InsufficientStockException(
            productId: productId,
            requested: -delta,
          );
        }
      }

      if (useDomainRpc) {
        // Pre-allocate movement_id for idempotency: server's replay check
        // matches this id against existing stock_transactions.id.
        final movementId = UuidV7.generate();
        final movement = <String, dynamic>{
          'movement_id': movementId,
          'product_id': productId,
          'store_id': storeId,
          'quantity_delta': delta,
          'movement_type': movementType,
          'reason': note,
        };
        if (refId != null) {
          movement['ref_type'] = 'transfer';
          movement['ref_id'] = refId;
        }
        final bundle = <String, dynamic>{
          'p_business_id': requireBusinessId(),
          'p_actor_id': staffId,
          'p_movements': [movement],
        };
        await db.syncDao.enqueue(
          'domain:pos_inventory_delta_v2',
          jsonEncode(bundle),
        );
        return;
      }

      // v1 (flag-OFF) path: full local mirror + per-table upserts.
      // Transfer legs: write a stock_transactions row referencing the
      // transfer (no stock_adjustments row — transfers are not adjustments).
      final txId = UuidV7.generate();
      final isTransfer =
          movementType == 'transfer_out' || movementType == 'transfer_in';
      StockTransactionsCompanion txComp;
      if (isTransfer && refId != null) {
        txComp = StockTransactionsCompanion.insert(
          id: Value(txId),
          businessId: requireBusinessId(),
          productId: productId,
          locationId: storeId,
          quantityDelta: delta,
          movementType: movementType,
          transferId: Value(refId),
          performedBy: Value(staffId),
          lastUpdatedAt: Value(DateTime.now()),
        );
      } else {
        final adjustmentId = UuidV7.generate();
        final adjComp = StockAdjustmentsCompanion.insert(
          id: Value(adjustmentId),
          businessId: requireBusinessId(),
          productId: productId,
          storeId: storeId,
          quantityDiff: delta,
          reason: note,
          performedBy: Value(staffId),
          lastUpdatedAt: Value(DateTime.now()),
        );
        await into(stockAdjustments).insert(adjComp);
        await db.syncDao.enqueueUpsert('stock_adjustments', adjComp);

        txComp = StockTransactionsCompanion.insert(
          id: Value(txId),
          businessId: requireBusinessId(),
          productId: productId,
          locationId: storeId,
          quantityDelta: delta,
          movementType: movementType,
          adjustmentId: Value(adjustmentId),
          performedBy: Value(staffId),
          lastUpdatedAt: Value(DateTime.now()),
        );
      }
      await into(stockTransactions).insert(txComp);
      await db.syncDao.enqueueUpsert('stock_transactions', txComp);

      final invRow =
          await (select(inventory)..where(
                (t) =>
                    t.productId.equals(productId) &
                    t.storeId.equals(storeId) &
                    whereBusiness(t),
              ))
              .getSingle();
      await db.syncDao.enqueueUpsert('inventory', invRow);
    });
  }

  Stream<List<CategoryData>> watchAllCategories() {
    return (select(categories)
          ..where((t) => whereBusiness(t) & t.isDeleted.not())
          ..orderBy([(t) => OrderingTerm(expression: t.name)]))
        .watch();
  }

  /// One-shot business-scoped category list. Use for category pickers that
  /// read once so a multi-business device can't surface — and FK-reference —
  /// another business's category.
  Future<List<CategoryData>> getAllCategories() {
    return (select(categories)
          ..where((t) => whereBusiness(t) & t.isDeleted.not())
          ..orderBy([(t) => OrderingTerm(expression: t.name)]))
        .get();
  }

  Stream<List<CrateSizeGroupData>> watchAllCrateSizeGroups() {
    return (select(crateSizeGroups)
          ..where((t) => whereBusiness(t) & t.isDeleted.not())
          ..orderBy([(t) => OrderingTerm(expression: t.name)]))
        .watch();
  }

  Future<List<CrateSizeGroupData>> getAllCrateSizeGroups() {
    return (select(crateSizeGroups)
          ..where((t) => whereBusiness(t) & t.isDeleted.not())
          ..orderBy([(t) => OrderingTerm(expression: t.name)]))
        .get();
  }

  Future<void> updateCrateGroupStock(String groupId, int newStock) async {
    final now = DateTime.now();
    final comp = CrateSizeGroupsCompanion(
      id: Value(groupId),
      emptyCrateStock: Value(newStock),
      lastUpdatedAt: Value(now),
    );
    await (update(
      crateSizeGroups,
    )..where((t) => t.id.equals(groupId) & whereBusiness(t))).write(comp);
    // Full-row enqueue: a partial crate_size_groups upsert omits NOT NULL name.
    final fullGroup = await (select(
      crateSizeGroups,
    )..where((t) => t.id.equals(groupId) & whereBusiness(t))).getSingleOrNull();
    if (fullGroup != null) {
      await db.syncDao.enqueueUpsert(
        'crate_size_groups',
        fullGroup.toCompanion(true),
      );
    }
  }

  /// Increment a manufacturer's empty-crate stock counter. Used by the
  /// receive-delivery and crate-return flows to credit the physical pool of
  /// returnable crates held against a manufacturer. Delegates to the Crate Pool
  /// seam (#157).
  Future<void> addEmptyCrates(
    String manufacturerId,
    int quantity, {
    String? storeId,
  }) async {
    await db.cratePoolDao.addEmptiesToPool(
      manufacturerId,
      quantity,
      storeId: storeId,
    );
  }

  /// Debit a manufacturer's empty-crate pool because STORED empties were
  /// damaged/lost (§17.2 crate-aware damages, the `+crateempty` fate). The pool
  /// is clamped at zero. Note: the "full crate lost" (`+cratelost`) fate does
  /// NOT call this — that container was never in the returned-empties pool, so
  /// it only forfeits the deposit on the Statement (derived from the damage
  /// reason in `computeReconData`). Delegates to the Crate Pool seam (#157).
  Future<void> recordEmptyCrateDamage(
    String manufacturerId,
    int quantity, {
    String? storeId,
  }) async {
    await db.cratePoolDao.recordDamage(
      manufacturerId,
      quantity,
      storeId: storeId,
    );
  }

  /// Stream the per-manufacturer count of full bottles in stock, derived
  /// from inventory rows joined with products on `manufacturer_id`.
  ///
  /// When [storeId] is non-null the count is confined to that store's inventory
  /// (§16.8.1 Phase 2 — the Empty Crates tab shows per-store figures when a
  /// store is active). When null it sums every store (business-wide / "All
  /// Stores").
  Stream<Map<String, int>> watchFullCratesByManufacturer({String? storeId}) {
    // Only returnable-BOTTLE stock counts as full crates — the same basis
    // createOrder uses to issue crate rows (unit == 'bottle' && trackEmpties).
    // Without this filter a manufacturer's PET / Can / etc. inventory (e.g. a
    // Coca-Cola PET) was counted as full crates, tracking empties that never
    // exist for non-bottle packaging.
    var predicate =
        whereBusiness(inventory) &
        whereBusiness(products) &
        products.manufacturerId.isNotNull() &
        products.isDeleted.not() &
        products.unit.lower().equals('bottle') &
        products.trackEmpties.equals(true);
    if (storeId != null) {
      predicate = predicate & inventory.storeId.equals(storeId);
    }
    final query =
        select(inventory).join([
          innerJoin(products, products.id.equalsExp(inventory.productId)),
        ])..where(predicate);
    return query.watch().map((rows) {
      final out = <String, int>{};
      for (final row in rows) {
        final mfrId = row.readTable(products).manufacturerId;
        if (mfrId == null) continue;
        final qty = row.readTable(inventory).quantity;
        out[mfrId] = (out[mfrId] ?? 0) + qty;
      }
      return out;
    });
  }

  /// Stream per-manufacturer empty-crate stock from the manufacturers cache.
  Stream<Map<String, int>> watchEmptyCratesByManufacturer() {
    return (select(manufacturers)
          ..where((t) => whereBusiness(t) & t.isDeleted.not()))
        .watch()
        .map((rows) => {for (final m in rows) m.id: m.emptyCrateStock});
  }

  /// Stream the total empty-crate assets across all manufacturers — used by
  /// the inventory dashboard summary card.
  Stream<int> watchTotalCrateAssets() {
    return (select(manufacturers)
          ..where((t) => whereBusiness(t) & t.isDeleted.not()))
        .watch()
        .map((rows) => rows.fold<int>(0, (sum, m) => sum + m.emptyCrateStock));
  }

  Future<List<ProductStockWithStore>> getProductsStockPerStore({
    String? storeId,
  }) async {
    final ps = await (select(
      products,
    )..where((t) => whereBusiness(t) & t.isDeleted.not())).get();
    final whs = await (select(
      stores,
    )..where((t) => whereBusiness(t) & t.isDeleted.not())).get();
    final invQuery = select(inventory)..where((t) => whereBusiness(t));
    if (storeId != null) {
      invQuery.where((t) => t.storeId.equals(storeId));
    }
    final invs = await invQuery.get();
    final productById = {for (final p in ps) p.id: p};
    final storeById = {for (final w in whs) w.id: w};
    final out = <ProductStockWithStore>[];
    for (final i in invs) {
      final p = productById[i.productId];
      final w = storeById[i.storeId];
      if (p == null || w == null) continue;
      out.add(
        ProductStockWithStore(
          storeId: w.id,
          storeName: w.name,
          product: p,
          totalStock: i.quantity,
        ),
      );
    }
    out.sort((a, b) => a.product.name.compareTo(b.product.name));
    return out;
  }
}

class ProductDataWithStock {
  final ProductData product;
  final int totalStock;
  ProductDataWithStock({required this.product, required this.totalStock});
}

class ProductStockWithStore {
  final String storeId;
  final String storeName;
  final ProductData product;
  final int totalStock;
  const ProductStockWithStore({
    required this.storeId,
    required this.storeName,
    required this.product,
    required this.totalStock,
  });
}

class ManufacturerCrateStats {
  final String manufacturer;
  final int totalBottles;
  final int emptyCrates;
  final int totalValueKobo;

  ManufacturerCrateStats({
    required this.manufacturer,
    required this.totalBottles,
    required this.emptyCrates,
    required this.totalValueKobo,
  });

  int get fullCratesEquiv => totalBottles;
  int get totalCrateAssets => totalBottles + emptyCrates;
}

@DriftAccessor(tables: [StockTransactions, Products, Users, Stores, Inventory])
class StockLedgerDao extends DatabaseAccessor<AppDatabase>
    with _$StockLedgerDaoMixin, BusinessScopedDao<AppDatabase> {
  StockLedgerDao(super.db);

  Future<int> getCurrentStock(String productId, String locationId) async {
    final row =
        await (select(inventory)
              ..where(
                (i) =>
                    whereBusiness(i) &
                    i.productId.equals(productId) &
                    i.storeId.equals(locationId),
              )
              ..limit(1))
            .getSingleOrNull();
    return row?.quantity ?? 0;
  }

  Stream<int> watchCurrentStock(String productId, String locationId) {
    return (select(inventory)
          ..where(
            (i) =>
                whereBusiness(i) &
                i.productId.equals(productId) &
                i.storeId.equals(locationId),
          )
          ..limit(1))
        .watchSingleOrNull()
        .map((row) => row?.quantity ?? 0);
  }

  Future<void> insertTransaction(StockTransactionsCompanion companion) async {
    final txId = companion.id.present ? companion.id.value : UuidV7.generate();
    final row = companion.copyWith(
      id: Value(txId),
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(stockTransactions).insert(row);
    await db.syncDao.enqueueUpsert('stock_transactions', row);
  }

  Stream<List<StockTransactionData>> watchLedger(String productId) {
    return (select(stockTransactions)
          ..where(
            (s) =>
                whereBusiness(s) &
                s.productId.equals(productId) &
                s.voidedAt.isNull(),
          )
          ..orderBy([(s) => OrderingTerm.desc(s.createdAt)]))
        .watch();
  }

  /// Every non-voided stock movement for the business (raw ledger rows, no
  /// joins). Feeds the Daily Reconciliation stock flow-equation card (ADR
  /// 0014): opening and expected-closing stock are reconstructed by rewinding
  /// these deltas from the current on-hand figure, valued at current cost.
  /// Store scope is applied in the report from each row's `locationId`.
  Stream<List<StockTransactionData>> watchAllTransactions() {
    return (select(stockTransactions)
          ..where((s) => whereBusiness(s) & s.voidedAt.isNull())
          ..orderBy([(s) => OrderingTerm.desc(s.createdAt)]))
        .watch();
  }

  // ── Filtered queries with joined product/user/store names ──────────

  JoinedSelectStatement<HasResultSet, dynamic> _buildFilteredQuery({
    String? storeId,
    DateTime? startDate,
    DateTime? endDate,
    String? movementType,
    ({DateTime createdAt, String id})? cursor,
    int? limit,
  }) {
    final query = select(stockTransactions).join([
      innerJoin(products, products.id.equalsExp(stockTransactions.productId)),
      innerJoin(users, users.id.equalsExp(stockTransactions.performedBy)),
      leftOuterJoin(stores, stores.id.equalsExp(stockTransactions.locationId)),
    ]);
    query.where(
      whereBusiness(stockTransactions) & stockTransactions.voidedAt.isNull(),
    );
    if (storeId != null) {
      query.where(stockTransactions.locationId.equals(storeId));
    }
    if (startDate != null) {
      query.where(stockTransactions.createdAt.isBiggerOrEqualValue(startDate));
    }
    if (endDate != null) {
      query.where(stockTransactions.createdAt.isSmallerOrEqualValue(endDate));
    }
    if (movementType != null) {
      query.where(stockTransactions.movementType.equals(movementType));
    }
    if (cursor != null) {
      query.where(
        stockTransactions.createdAt.isSmallerThanValue(cursor.createdAt) |
            (stockTransactions.createdAt.equals(cursor.createdAt) &
                stockTransactions.id.isSmallerThanValue(cursor.id)),
      );
    }
    query.orderBy([
      OrderingTerm.desc(stockTransactions.createdAt),
      OrderingTerm.desc(stockTransactions.id),
    ]);
    if (limit != null) {
      query.limit(limit);
    }
    return query;
  }

  StockTransactionWithDetails _mapRow(TypedResult row) {
    final s = row.readTable(stockTransactions);
    final p = row.readTable(products);
    final u = row.readTable(users);
    final w = row.readTableOrNull(stores);
    return StockTransactionWithDetails(
      transactionId: s.id,
      productId: s.productId,
      productName: p.name,
      movementType: s.movementType,
      quantityDelta: s.quantityDelta,
      performedByName: u.name,
      locationId: s.locationId,
      storeName: w?.name,
      referenceId: s.orderId ?? s.transferId ?? s.adjustmentId ?? s.shipmentId,
      createdAt: s.createdAt,
      unitPriceKobo: p.retailerPriceKobo,
    );
  }

  Stream<List<StockTransactionWithDetails>> watchAllTransactionsFiltered({
    String? storeId,
    DateTime? startDate,
    DateTime? endDate,
    String? movementType,
  }) {
    return _buildFilteredQuery(
      storeId: storeId,
      startDate: startDate,
      endDate: endDate,
      movementType: movementType,
    ).watch().map((rows) => rows.map(_mapRow).toList());
  }

  Future<List<StockTransactionWithDetails>> getTransactionsFiltered({
    String? storeId,
    DateTime? startDate,
    DateTime? endDate,
    String? movementType,
  }) async {
    final rows = await _buildFilteredQuery(
      storeId: storeId,
      startDate: startDate,
      endDate: endDate,
      movementType: movementType,
    ).get();
    return rows.map(_mapRow).toList();
  }

  Future<List<StockTransactionWithDetails>> getTransactionsPage({
    String? storeId,
    DateTime? startDate,
    DateTime? endDate,
    String? movementType,
    ({DateTime createdAt, String id})? cursor,
    int limit = 30,
  }) async {
    final rows = await _buildFilteredQuery(
      storeId: storeId,
      startDate: startDate,
      endDate: endDate,
      movementType: movementType,
      cursor: cursor,
      limit: limit,
    ).get();
    return rows.map(_mapRow).toList();
  }

  Stream<List<StockTransactionWithDetails>> watchTransactionsPage({
    String? storeId,
    DateTime? startDate,
    DateTime? endDate,
    String? movementType,
    int limit = 30,
  }) {
    return _buildFilteredQuery(
      storeId: storeId,
      startDate: startDate,
      endDate: endDate,
      movementType: movementType,
      limit: limit,
    ).watch().map((rows) => rows.map(_mapRow).toList());
  }

  Stream<StockHistoryStats> watchTransactionsStats({
    String? storeId,
    DateTime? startDate,
    DateTime? endDate,
    String? movementType,
  }) {
    final query = selectOnly(stockTransactions);
    query.where(
      whereBusiness(stockTransactions) & stockTransactions.voidedAt.isNull(),
    );
    if (storeId != null) {
      query.where(stockTransactions.locationId.equals(storeId));
    }
    if (startDate != null) {
      query.where(stockTransactions.createdAt.isBiggerOrEqualValue(startDate));
    }
    if (endDate != null) {
      query.where(stockTransactions.createdAt.isSmallerOrEqualValue(endDate));
    }
    if (movementType != null) {
      query.where(stockTransactions.movementType.equals(movementType));
    }

    const totalInCol = CustomExpression<int>(
      'SUM(CASE WHEN stock_transactions.quantity_delta > 0 THEN stock_transactions.quantity_delta ELSE 0 END)',
    );
    const totalOutCol = CustomExpression<int>(
      'SUM(CASE WHEN stock_transactions.quantity_delta < 0 THEN -stock_transactions.quantity_delta ELSE 0 END)',
    );
    final countCol = stockTransactions.id.count();

    query.addColumns([totalInCol, totalOutCol, countCol]);

    return query.watchSingle().map((row) {
      return StockHistoryStats(
        totalIn: row.read(totalInCol) ?? 0,
        totalOut: row.read(totalOutCol) ?? 0,
        count: row.read(countCol) ?? 0,
      );
    });
  }

  Future<PeriodStockSummary> getPeriodSummary({
    String? storeId,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final txns = await getTransactionsFiltered(
      storeId: storeId,
      startDate: startDate,
      endDate: endDate,
    );
    int totalIn = 0, totalOut = 0, adjustments = 0, flagged = 0;
    for (final t in txns) {
      if (t.quantityDelta > 0) {
        totalIn += t.quantityDelta;
      } else {
        totalOut += t.quantityDelta.abs();
      }
      if (t.isAdjustment) adjustments++;
    }
    return PeriodStockSummary(
      totalIn: totalIn,
      totalOut: totalOut,
      adjustmentCount: adjustments,
      flaggedCount: flagged,
      transactionCount: txns.length,
    );
  }

  Future<List<StockTransactionWithBalance>> getRunningBalanceForProduct(
    String productId, {
    String? storeId,
  }) async {
    final query = select(stockTransactions)
      ..where(
        (s) =>
            whereBusiness(s) &
            s.productId.equals(productId) &
            s.voidedAt.isNull(),
      )
      ..orderBy([(s) => OrderingTerm.asc(s.createdAt)]);
    if (storeId != null) {
      query.where((s) => s.locationId.equals(storeId));
    }
    final txns = await query.get();
    int balance = 0;
    final result = <StockTransactionWithBalance>[];
    for (final txn in txns) {
      final prev = balance;
      balance += txn.quantityDelta;
      result.add(
        StockTransactionWithBalance(
          transaction: txn,
          previousBalance: prev,
          newBalance: balance,
          isFlagged: balance < 0,
        ),
      );
    }
    return result;
  }

  Future<PeriodReconciliation> getPeriodReconciliation({
    required String storeId,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    // Get all transactions for this store, sorted by time
    final allTxns =
        await (select(stockTransactions)
              ..where(
                (s) =>
                    whereBusiness(s) &
                    s.locationId.equals(storeId) &
                    s.voidedAt.isNull(),
              )
              ..orderBy([(s) => OrderingTerm.asc(s.createdAt)]))
            .get();

    int openingStock = 0;
    int stockIn = 0;
    int stockOut = 0;

    for (final txn in allTxns) {
      if (txn.createdAt.isBefore(startDate)) {
        openingStock += txn.quantityDelta;
      } else if (!txn.createdAt.isAfter(endDate)) {
        if (txn.quantityDelta > 0) {
          stockIn += txn.quantityDelta;
        } else {
          stockOut += txn.quantityDelta.abs();
        }
      }
    }

    final expectedClosing = openingStock + stockIn - stockOut;

    // Get current actual stock from inventory table
    final invRows = await (select(
      inventory,
    )..where((i) => whereBusiness(i) & i.storeId.equals(storeId))).get();
    final actualClosing = invRows.fold<int>(0, (s, r) => s + r.quantity);

    return PeriodReconciliation(
      openingStock: openingStock,
      stockIn: stockIn,
      stockOut: stockOut,
      expectedClosing: expectedClosing,
      actualClosing: actualClosing,
      variance: actualClosing - expectedClosing,
    );
  }

  Future<List<ProductBelowROP>> getProductsBelowROP(String locationId) async {
    final ps = await (select(
      products,
    )..where((p) => whereBusiness(p) & p.isDeleted.not())).get();
    final invs = await (select(
      inventory,
    )..where((i) => whereBusiness(i) & i.storeId.equals(locationId))).get();
    final stockMap = <String, int>{};
    for (final i in invs) {
      stockMap[i.productId] = (stockMap[i.productId] ?? 0) + i.quantity;
    }
    final result = <ProductBelowROP>[];
    for (final p in ps) {
      final stock = stockMap[p.id] ?? 0;
      // ROP = avgDailySales * leadTimeDays + safetyStockQty
      final rop = p.avgDailySales * p.leadTimeDays + p.safetyStockQty;
      if (stock < rop) {
        result.add(
          ProductBelowROP(
            productId: p.id,
            productName: p.name,
            currentStock: stock,
            rop: rop,
          ),
        );
      }
    }
    return result;
  }
}

class ProductBelowROP {
  final String productId;
  final String productName;
  final int currentStock;
  final double rop;

  ProductBelowROP({
    required this.productId,
    required this.productName,
    required this.currentStock,
    required this.rop,
  });
}

class StockTransactionWithDetails {
  final String transactionId;
  final String productId;
  final String productName;
  final String movementType;
  final int quantityDelta;
  final String performedByName;
  final String locationId;
  final String? storeName;
  final String? referenceId;
  final DateTime createdAt;
  final int unitPriceKobo;

  StockTransactionWithDetails({
    required this.transactionId,
    required this.productId,
    required this.productName,
    required this.movementType,
    required this.quantityDelta,
    required this.performedByName,
    required this.locationId,
    this.storeName,
    this.referenceId,
    required this.createdAt,
    required this.unitPriceKobo,
  });

  int get valueKobo => quantityDelta.abs() * unitPriceKobo;
  bool get isInflow => quantityDelta > 0;
  bool get isOutflow => quantityDelta < 0;
  bool get isAdjustment => movementType == 'adjustment';

  String get movementLabel {
    switch (movementType) {
      case 'sale':
        return 'Sale';
      case 'return':
        return 'Return';
      case 'damage':
        return 'Damaged';
      case 'transfer_out':
        return 'Transfer Out';
      case 'transfer_in':
        return 'Transfer In';
      case 'purchase_received':
        return 'Stock Received';
      case 'adjustment':
        return 'Adjustment';
      case 'transfer_cancelled':
        return 'Transfer Cancelled';
      default:
        return movementType;
    }
  }
}

class StockTransactionWithBalance {
  final StockTransactionData transaction;
  final int previousBalance;
  final int newBalance;
  final bool isFlagged;

  StockTransactionWithBalance({
    required this.transaction,
    required this.previousBalance,
    required this.newBalance,
    required this.isFlagged,
  });
}

class PeriodStockSummary {
  final int totalIn;
  final int totalOut;
  final int adjustmentCount;
  final int flaggedCount;
  final int transactionCount;

  PeriodStockSummary({
    required this.totalIn,
    required this.totalOut,
    required this.adjustmentCount,
    required this.flaggedCount,
    required this.transactionCount,
  });
}

class StockHistoryStats {
  final int totalIn;
  final int totalOut;
  final int count;

  const StockHistoryStats({
    required this.totalIn,
    required this.totalOut,
    required this.count,
  });

  factory StockHistoryStats.empty() => const StockHistoryStats(
        totalIn: 0,
        totalOut: 0,
        count: 0,
      );
}

class PeriodReconciliation {
  final int openingStock;
  final int stockIn;
  final int stockOut;
  final int expectedClosing;
  final int actualClosing;
  final int variance;

  PeriodReconciliation({
    required this.openingStock,
    required this.stockIn,
    required this.stockOut,
    required this.expectedClosing,
    required this.actualClosing,
    required this.variance,
  });

  bool get hasVariance => variance != 0;
}

@DriftAccessor(tables: [StockTransfers, StockTransactions])
class StockTransferDao extends DatabaseAccessor<AppDatabase>
    with _$StockTransferDaoMixin, BusinessScopedDao<AppDatabase> {
  StockTransferDao(super.db);

  // ── Create ──────────────────────────────────────────────────────────────

  /// Dispatch a product from [fromStoreId] to [toStoreId] (§16.8.1).
  ///
  /// Returns the new transfer id.
  ///
  /// Contract:
  /// - Both stores must belong to this business and differ.
  /// - [quantity] must be a positive integer.
  /// - The source inventory is decremented immediately at dispatch. If the
  ///   source has insufficient stock the server rejects the `transfer_out`
  ///   movement and this method throws [InsufficientStockException].
  /// - The header + inventory envelope are enqueued inside one local
  ///   transaction so they reach the queue together.
  /// - In-transit stock is un-sellable by construction: it is removed from
  ///   the source's inventory row but not added to the destination until
  ///   [receiveTransfer] is called.
  Future<String> createTransfer({
    required String fromStoreId,
    required String toStoreId,
    required String productId,
    required int quantity,
    required String initiatedBy,
  }) async {
    if (fromStoreId == toStoreId) {
      throw ArgumentError('Source and destination stores must differ.');
    }
    if (quantity <= 0) {
      throw ArgumentError('Quantity must be positive.');
    }

    final transferId = UuidV7.generate();
    final now = DateTime.now();

    await transaction(() async {
      // 1. Write the header row (in_transit).
      final header = StockTransfersCompanion.insert(
        id: Value(transferId),
        businessId: requireBusinessId(),
        fromLocationId: fromStoreId,
        toLocationId: toStoreId,
        productId: productId,
        quantity: quantity,
        status: const Value('in_transit'),
        initiatedBy: initiatedBy,
        initiatedAt: Value(now),
        lastUpdatedAt: Value(now),
      );
      await into(stockTransfers).insert(header);
      await db.syncDao.enqueueUpsert('stock_transfers', header);

      // 2. Decrement source inventory (transfer_out). The adjustStock helper
      //    handles both the v2 domain-RPC path and the legacy flag-off path,
      //    and guards negative stock (throws InsufficientStockException).
      await db.inventoryDao.adjustStock(
        productId,
        fromStoreId,
        -quantity,
        'Transfer out to ${toStoreId.substring(0, 8)}…',
        initiatedBy,
        movementType: 'transfer_out',
        refId: transferId,
      );
    });

    // 3. Activity log.
    await db.activityLogDao.log(
      action: 'stock_transfer_dispatched',
      description:
          'Dispatched $quantity unit(s) of $productId '
          'from $fromStoreId → $toStoreId',
      staffId: initiatedBy,
      storeId: fromStoreId,
      productId: productId,
    );

    // 4. Notify destination (CEO + all users assigned to the dest store).
    final ceoIds = await db.userBusinessesDao.getUserIdsForRoleSlugs(['ceo']);
    final destUserIds = (await db.userStoresDao.getUserIdsForStore(
      toStoreId,
    )).toSet();
    for (final uid in <String>{
      ...ceoIds,
      ...destUserIds,
    }..remove(initiatedBy)) {
      await db.notificationsDao.fireNotification(
        type: 'stock_transfer.dispatched',
        message: 'Incoming transfer: $quantity unit(s) arriving at your store.',
        severity: 'info',
        linkedRecordId: transferId,
        recipientUserId: uid,
      );
    }

    return transferId;
  }

  // ── Receive ─────────────────────────────────────────────────────────────

  /// Confirm receipt of transfer [transferId] at the destination store.
  ///
  /// Increments destination inventory and stamps [receivedBy]/receivedAt.
  /// Throws [StateError] if the transfer is not in_transit.
  Future<void> receiveTransfer({
    required String transferId,
    required String receivedBy,
  }) async {
    String? fromStoreId;
    String? toStoreId;
    String? productId;
    int? quantity;

    await transaction(() async {
      final transfer =
          await (select(stockTransfers)
                ..where((t) => t.id.equals(transferId) & whereBusiness(t)))
              .getSingleOrNull();

      if (transfer == null) {
        throw StateError('Transfer $transferId not found.');
      }
      if (transfer.status != 'in_transit') {
        throw StateError(
          'Transfer $transferId is ${transfer.status}, not in_transit.',
        );
      }

      fromStoreId = transfer.fromLocationId;
      toStoreId = transfer.toLocationId;
      productId = transfer.productId;
      quantity = transfer.quantity;

      final now = DateTime.now();

      // 1. Increment destination inventory (transfer_in).
      await db.inventoryDao.adjustStock(
        transfer.productId,
        transfer.toLocationId,
        transfer.quantity,
        'Transfer in from ${transfer.fromLocationId.substring(0, 8)}…',
        receivedBy,
        movementType: 'transfer_in',
        refId: transferId,
      );

      // 2. Flip header → received.
      final updated = transfer
          .toCompanion(true)
          .copyWith(
            status: const Value('received'),
            receivedBy: Value(receivedBy),
            receivedAt: Value(now),
            lastUpdatedAt: Value(now),
          );
      await (update(stockTransfers)
            ..where((t) => t.id.equals(transferId) & whereBusiness(t)))
          .write(updated);
      final row = await (select(
        stockTransfers,
      )..where((t) => t.id.equals(transferId) & whereBusiness(t))).getSingle();
      await db.syncDao.enqueueUpsert('stock_transfers', row.toCompanion(true));
    });

    // 3. Activity log.
    await db.activityLogDao.log(
      action: 'stock_transfer_received',
      description:
          'Received $quantity unit(s) of $productId '
          'at $toStoreId from $fromStoreId',
      staffId: receivedBy,
      storeId: toStoreId,
      productId: productId,
    );

    // 4. Notify sender.
    final transfer =
        await (select(stockTransfers)
              ..where((t) => t.id.equals(transferId) & whereBusiness(t)))
            .getSingleOrNull();
    if (transfer != null) {
      await db.notificationsDao.fireNotification(
        type: 'stock_transfer.received',
        message: 'Your transfer of $quantity unit(s) was confirmed received.',
        severity: 'info',
        linkedRecordId: transferId,
        recipientUserId: transfer.initiatedBy,
      );
    }
  }

  // ── Cancel ──────────────────────────────────────────────────────────────

  /// Cancel an in-transit transfer and restore the source inventory.
  ///
  /// Throws [StateError] if the transfer is not in_transit.
  Future<void> cancelTransfer({
    required String transferId,
    required String cancelledBy,
  }) async {
    await transaction(() async {
      final transfer =
          await (select(stockTransfers)
                ..where((t) => t.id.equals(transferId) & whereBusiness(t)))
              .getSingleOrNull();

      if (transfer == null) {
        throw StateError('Transfer $transferId not found.');
      }
      if (transfer.status != 'in_transit') {
        throw StateError(
          'Transfer $transferId is ${transfer.status}, not in_transit.',
        );
      }

      // 1. Restore source inventory via a compensating transfer_in leg.
      //    (The ledger CHECK allows 'transfer_in'; no 'transfer_cancelled' type.)
      await db.inventoryDao.adjustStock(
        transfer.productId,
        transfer.fromLocationId,
        transfer.quantity,
        'Transfer cancelled — restoring source stock',
        cancelledBy,
        movementType: 'transfer_in',
        refId: transferId,
      );

      // 2. Flip header → cancelled.
      final now = DateTime.now();
      final updated = transfer
          .toCompanion(true)
          .copyWith(
            status: const Value('cancelled'),
            lastUpdatedAt: Value(now),
          );
      await (update(stockTransfers)
            ..where((t) => t.id.equals(transferId) & whereBusiness(t)))
          .write(updated);
      final row = await (select(
        stockTransfers,
      )..where((t) => t.id.equals(transferId) & whereBusiness(t))).getSingle();
      await db.syncDao.enqueueUpsert('stock_transfers', row.toCompanion(true));
    });

    // 3. Activity log.
    await db.activityLogDao.log(
      action: 'stock_transfer_cancelled',
      description: 'Cancelled transfer $transferId; source stock restored.',
      staffId: cancelledBy,
    );
  }

  /// Moves [quantity] empty crates of [manufacturerId] from [fromStoreId] to
  /// [toStoreId] atomically (Phase 3, §16.9). Executed at dispatch time — no
  /// separate confirm step for crates (they travel with the product shipment).
  /// Delegates to the Crate Pool seam (#157), which owns the crate_ledger +
  /// store_crate_balances writes and the `domain:pos_transfer_crates` envelope.
  Future<void> transferCrates({
    required String transferId,
    required String fromStoreId,
    required String toStoreId,
    required String manufacturerId,
    required int quantity,
    required String performedBy,
  }) async {
    await transaction(() async {
      await db.cratePoolDao.transferBetweenStores(
        transferId: transferId,
        fromStoreId: fromStoreId,
        toStoreId: toStoreId,
        manufacturerId: manufacturerId,
        quantity: quantity,
        performedBy: performedBy,
      );
    });
  }

  // ── Request → Dispatch → Reject (requester-initiated flow, §16.8.2) ────────

  /// Raise a stock-transfer REQUEST from the requesting store [toStoreId] to the
  /// holder store [fromStoreId]. Writes a `pending` header and nothing else —
  /// NO inventory or crate movement happens until the holder dispatches. Field
  /// meaning is unchanged: `fromLocationId` holds the goods (source),
  /// `toLocationId` needs them (requester). `initiatedBy` is the requester.
  ///
  /// Returns the new transfer id. Notifies the holder store's users + the CEO.
  Future<String> requestTransfer({
    required String fromStoreId,
    required String toStoreId,
    required String productId,
    required int quantity,
    required String requestedBy,
  }) async {
    if (fromStoreId == toStoreId) {
      throw ArgumentError('Source and destination stores must differ.');
    }
    if (quantity <= 0) {
      throw ArgumentError('Quantity must be positive.');
    }

    final transferId = UuidV7.generate();
    final now = DateTime.now();

    await transaction(() async {
      final header = StockTransfersCompanion.insert(
        id: Value(transferId),
        businessId: requireBusinessId(),
        fromLocationId: fromStoreId,
        toLocationId: toStoreId,
        productId: productId,
        quantity: quantity,
        status: const Value('pending'),
        initiatedBy: requestedBy,
        initiatedAt: Value(now),
        createdAt: Value(now),
        lastUpdatedAt: Value(now),
      );
      await into(stockTransfers).insert(header);
      await db.syncDao.enqueueUpsert('stock_transfers', header);
    });

    await db.activityLogDao.log(
      action: 'stock_transfer_requested',
      description:
          'Requested $quantity unit(s) of $productId '
          'from $fromStoreId → $toStoreId',
      staffId: requestedBy,
      storeId: toStoreId,
      productId: productId,
    );

    // Notify the holder store (its assigned users) + the CEO that a request
    // is waiting for them to accept and dispatch.
    final ceoIds = await db.userBusinessesDao.getUserIdsForRoleSlugs(['ceo']);
    final holderUserIds = (await db.userStoresDao.getUserIdsForStore(
      fromStoreId,
    )).toSet();
    for (final uid in <String>{
      ...ceoIds,
      ...holderUserIds,
    }..remove(requestedBy)) {
      await db.notificationsDao.fireNotification(
        type: 'stock_transfer.requested',
        message: 'Stock request: $quantity unit(s) requested from your store.',
        severity: 'info',
        linkedRecordId: transferId,
        recipientUserId: uid,
      );
    }

    return transferId;
  }

  /// Accept a `pending` request on the holder side and DISPATCH it: optionally
  /// alter [quantity] to match availability, decrement the source inventory
  /// (`transfer_out`, which throws [InsufficientStockException] on shortfall),
  /// and flip the header → `in_transit`. The requester then confirms receipt.
  ///
  /// Throws [StateError] if the transfer is not `pending`.
  Future<void> dispatchTransfer({
    required String transferId,
    required String dispatchedBy,
    int? quantity,
    int emptyCratesToSend = 0,
  }) async {
    if (quantity != null && quantity <= 0) {
      throw ArgumentError('Quantity must be positive.');
    }
    if (emptyCratesToSend < 0) {
      throw ArgumentError('emptyCratesToSend cannot be negative.');
    }

    String? fromStoreId;
    String? toStoreId;
    String? productId;
    int? dispatchedQty;

    await transaction(() async {
      final transfer =
          await (select(stockTransfers)
                ..where((t) => t.id.equals(transferId) & whereBusiness(t)))
              .getSingleOrNull();
      if (transfer == null) {
        throw StateError('Transfer $transferId not found.');
      }
      if (transfer.status != 'pending') {
        throw StateError(
          'Transfer $transferId is ${transfer.status}, not pending.',
        );
      }

      fromStoreId = transfer.fromLocationId;
      toStoreId = transfer.toLocationId;
      productId = transfer.productId;
      dispatchedQty = quantity ?? transfer.quantity;
      final now = DateTime.now();

      // 1. Decrement source inventory (transfer_out). Guards negative stock.
      await db.inventoryDao.adjustStock(
        transfer.productId,
        transfer.fromLocationId,
        -dispatchedQty!,
        'Transfer out to ${transfer.toLocationId.substring(0, 8)}…',
        dispatchedBy,
        movementType: 'transfer_out',
        refId: transferId,
      );

      // 2. Flip header → in_transit, persisting any altered quantity.
      final updated = transfer
          .toCompanion(true)
          .copyWith(
            status: const Value('in_transit'),
            quantity: Value(dispatchedQty!),
            lastUpdatedAt: Value(now),
          );
      await (update(stockTransfers)
            ..where((t) => t.id.equals(transferId) & whereBusiness(t)))
          .write(updated);
      final row = await (select(
        stockTransfers,
      )..where((t) => t.id.equals(transferId) & whereBusiness(t))).getSingle();
      await db.syncDao.enqueueUpsert('stock_transfers', row.toCompanion(true));

      // 3. Move empties if requested.
      if (emptyCratesToSend > 0) {
        final product = await db.catalogDao.findById(transfer.productId);
        if (product == null) {
          throw StateError('Product ${transfer.productId} not found.');
        }
        final isEligible = product.unit?.toLowerCase() == 'bottle' && product.trackEmpties;
        if (!isEligible) {
          throw StateError(
            'Product ${product.name} is not crate eligible (unit: ${product.unit}, trackEmpties: ${product.trackEmpties}).',
          );
        }
        final manufacturerId = product.manufacturerId;
        if (manufacturerId == null) {
          throw StateError('Product ${product.name} does not have a manufacturerId.');
        }

        await db.cratePoolDao.transferBetweenStores(
          transferId: transferId,
          fromStoreId: fromStoreId!,
          toStoreId: toStoreId!,
          manufacturerId: manufacturerId,
          quantity: emptyCratesToSend,
          performedBy: dispatchedBy,
        );
      }
    });

    await db.activityLogDao.log(
      action: 'stock_transfer_dispatched',
      description:
          'Dispatched $dispatchedQty unit(s) of $productId '
          'from $fromStoreId → $toStoreId'
          '${emptyCratesToSend > 0 ? " + $emptyCratesToSend empty crate(s)" : ""}',
      staffId: dispatchedBy,
      storeId: fromStoreId,
      productId: productId,
    );

    // Notify the requester that their goods are on the way.
    final transfer =
        await (select(stockTransfers)
              ..where((t) => t.id.equals(transferId) & whereBusiness(t)))
            .getSingleOrNull();
    if (transfer != null) {
      await db.notificationsDao.fireNotification(
        type: 'stock_transfer.dispatched',
        message:
            'Your request was dispatched: $dispatchedQty unit(s) on the way.',
        severity: 'info',
        linkedRecordId: transferId,
        recipientUserId: transfer.initiatedBy,
      );
    }
  }

  /// Reject a `pending` request (holder declines). Flips the header →
  /// `cancelled`. No inventory change (none ever happened for a pending row).
  ///
  /// Throws [StateError] if the transfer is not `pending`.
  Future<void> rejectRequest({
    required String transferId,
    required String rejectedBy,
  }) async {
    String? requesterId;

    await transaction(() async {
      final transfer =
          await (select(stockTransfers)
                ..where((t) => t.id.equals(transferId) & whereBusiness(t)))
              .getSingleOrNull();
      if (transfer == null) {
        throw StateError('Transfer $transferId not found.');
      }
      if (transfer.status != 'pending') {
        throw StateError(
          'Transfer $transferId is ${transfer.status}, not pending.',
        );
      }

      requesterId = transfer.initiatedBy;
      final now = DateTime.now();
      final updated = transfer
          .toCompanion(true)
          .copyWith(
            status: const Value('cancelled'),
            lastUpdatedAt: Value(now),
          );
      await (update(stockTransfers)
            ..where((t) => t.id.equals(transferId) & whereBusiness(t)))
          .write(updated);
      final row = await (select(
        stockTransfers,
      )..where((t) => t.id.equals(transferId) & whereBusiness(t))).getSingle();
      await db.syncDao.enqueueUpsert('stock_transfers', row.toCompanion(true));
    });

    await db.activityLogDao.log(
      action: 'stock_transfer_rejected',
      description: 'Rejected pending transfer request $transferId.',
      staffId: rejectedBy,
    );

    if (requesterId != null) {
      await db.notificationsDao.fireNotification(
        type: 'stock_transfer.rejected',
        message: 'Your stock request was declined by the holding store.',
        severity: 'info',
        linkedRecordId: transferId,
        recipientUserId: requesterId!,
      );
    }
  }

  // ── Watch ────────────────────────────────────────────────────────────────

  /// Transfers currently in_transit FROM [fromStoreId] (the outgoing queue).
  Stream<List<StockTransferData>> watchOutgoing(String fromStoreId) {
    return (select(stockTransfers)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.fromLocationId.equals(fromStoreId) &
                t.status.equals('in_transit'),
          )
          ..orderBy([
            (t) => OrderingTerm(
              expression: t.initiatedAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .watch();
  }

  /// Transfers currently in_transit TO [toStoreId] (the incoming confirm queue).
  Stream<List<StockTransferData>> watchIncoming(String toStoreId) {
    return (select(stockTransfers)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.toLocationId.equals(toStoreId) &
                t.status.equals('in_transit'),
          )
          ..orderBy([
            (t) => OrderingTerm(
              expression: t.initiatedAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .watch();
  }

  /// Business-wide received + cancelled transfers, newest first.
  Stream<List<StockTransferData>> watchHistory() {
    return (select(stockTransfers)
          ..where(
            (t) => whereBusiness(t) & t.status.isIn(['received', 'cancelled']),
          )
          ..orderBy([
            (t) => OrderingTerm(
              expression: t.initiatedAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .watch();
  }

  /// All in_transit transfers for a set of store ids — used by the viewer-
  /// scoped provider (CEO sees all; a store-assigned user sees their stores).
  Stream<List<StockTransferData>> watchIncomingForStores(
    List<String> storeIds,
  ) {
    if (storeIds.isEmpty) return const Stream.empty();
    return (select(stockTransfers)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.toLocationId.isIn(storeIds) &
                t.status.equals('in_transit'),
          )
          ..orderBy([
            (t) => OrderingTerm(
              expression: t.initiatedAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .watch();
  }

  /// All in_transit outgoing transfers for a set of store ids.
  Stream<List<StockTransferData>> watchOutgoingForStores(
    List<String> storeIds,
  ) {
    if (storeIds.isEmpty) return const Stream.empty();
    return (select(stockTransfers)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.fromLocationId.isIn(storeIds) &
                t.status.equals('in_transit'),
          )
          ..orderBy([
            (t) => OrderingTerm(
              expression: t.initiatedAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .watch();
  }

  /// Business-wide all in_transit transfers (incoming + outgoing), newest
  /// first. The viewer-scoped providers in stream_providers.dart filter this
  /// in memory so CEO vs store-user scoping never requires re-querying.
  Stream<List<StockTransferData>> watchAllInTransit() {
    return (select(stockTransfers)
          ..where((t) => whereBusiness(t) & t.status.equals('in_transit'))
          ..orderBy([
            (t) => OrderingTerm(
              expression: t.initiatedAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .watch();
  }

  /// Business-wide `pending` transfer requests (raised, not yet dispatched),
  /// newest first. The viewer-scoped request providers in stream_providers.dart
  /// filter this in memory: incoming-requests by `fromLocationId` (holder side),
  /// outgoing-requests by `toLocationId` (requester side).
  Stream<List<StockTransferData>> watchAllPending() {
    return (select(stockTransfers)
          ..where((t) => whereBusiness(t) & t.status.equals('pending'))
          ..orderBy([
            (t) => OrderingTerm(
              expression: t.initiatedAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .watch();
  }

  /// `pending` requests this store must fulfil — others asking [holderStoreId]
  /// to send (`fromLocationId == holderStoreId`). The store-details hub's
  /// "Incoming Requests" section (Accept & dispatch / Reject).
  Stream<List<StockTransferData>> watchPendingForHolderStore(
    String holderStoreId,
  ) {
    return (select(stockTransfers)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.fromLocationId.equals(holderStoreId) &
                t.status.equals('pending'),
          )
          ..orderBy([
            (t) => OrderingTerm(
              expression: t.initiatedAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .watch();
  }

  /// `pending` requests [requesterStoreId] raised but that have not been
  /// dispatched yet (`toLocationId == requesterStoreId`). The store-details
  /// hub's outstanding "My Requests" section.
  Stream<List<StockTransferData>> watchPendingFromStore(
    String requesterStoreId,
  ) {
    return (select(stockTransfers)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.toLocationId.equals(requesterStoreId) &
                t.status.equals('pending'),
          )
          ..orderBy([
            (t) => OrderingTerm(
              expression: t.initiatedAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .watch();
  }

  /// Watch received and cancelled transfers involving the store in either direction,
  /// sorted newest first.
  Stream<List<StockTransferData>> watchHistoryForStore(String storeId) {
    return (select(stockTransfers)
          ..where((t) =>
              whereBusiness(t) &
              (t.fromLocationId.equals(storeId) | t.toLocationId.equals(storeId)) &
              t.status.isIn(['received', 'cancelled']))
          ..orderBy([
            (t) => OrderingTerm(
                  expression: t.initiatedAt,
                  mode: OrderingMode.desc,
                ),
          ]))
        .watch();
  }
}

@DriftAccessor(tables: [StockAdjustmentRequests])
class StockAdjustmentRequestsDao extends DatabaseAccessor<AppDatabase>
    with _$StockAdjustmentRequestsDaoMixin, BusinessScopedDao<AppDatabase> {
  StockAdjustmentRequestsDao(super.db);

  /// All still-pending requests for the business, newest first. Approver-side
  /// store scoping (a Manager only sees their store's requests) is applied in
  /// the UI, mirroring the home/inventory store-lock pattern.
  Stream<List<StockAdjustmentRequestData>> watchPending() {
    return (select(stockAdjustmentRequests)
          ..where((t) => whereBusiness(t) & t.status.equals('pending'))
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  /// §16.6.1 — a stock keeper submits an Add/Remove for approval. Writes a
  /// `pending` row only (inventory is untouched until approval) and fires an
  /// approval-request notification to the CEO and the Manager(s) of the
  /// affected store. If no Manager is tied to that store, only the CEO is
  /// notified (same audience rule as the old §26.4 post-hoc notice).
  Future<void> requestStockAdjustment({
    required String productId,
    required String storeId,
    required int quantityDiff,
    required String reason,
    required String summary,
    required String? requestedBy,
  }) async {
    final row = StockAdjustmentRequestsCompanion.insert(
      id: Value(UuidV7.generate()),
      businessId: requireBusinessId(),
      productId: productId,
      storeId: storeId,
      quantityDiff: quantityDiff,
      reason: reason,
      summary: summary,
      requestedBy: Value(requestedBy),
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(stockAdjustmentRequests).insert(row);
    await db.syncDao.enqueueUpsert('stock_adjustment_requests', row);

    await db.activityLogDao.log(
      action: 'stock_adjustment_requested',
      description: 'Requested approval: $summary',
      staffId: requestedBy,
      storeId: storeId,
      productId: productId,
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
    final isRemove = quantityDiff < 0;
    for (final uid in <String>{...ceoIds, ...storeManagerIds}) {
      await db.notificationsDao.fireNotification(
        type: 'stock_approval.requested',
        message: 'Approval needed: $summary',
        severity: isRemove ? 'warning' : 'info',
        linkedRecordId: row.id.value,
        recipientUserId: uid,
      );
    }
  }

  /// Approve a pending request: apply the real inventory change via
  /// `adjustStock` (keeping the atomic delta envelope), flip the row to
  /// `approved`, and notify the requester. Throws (rolling back the whole
  /// transaction) if the adjustment can't be applied — e.g. a Remove that would
  /// take stock negative — leaving the request `pending` for a retry.
  Future<void> approveRequest({
    required String requestId,
    required String approverId,
  }) async {
    String? requestedBy;
    String? summary;
    var didApprove = false;

    await transaction(() async {
      final req =
          await (select(stockAdjustmentRequests)
                ..where((t) => t.id.equals(requestId) & whereBusiness(t)))
              .getSingleOrNull();
      if (req == null || req.status != 'pending') return;

      // Apply the actual stock movement (atomic via pos_inventory_delta_v2).
      await db.inventoryDao.adjustStock(
        req.productId,
        req.storeId,
        req.quantityDiff,
        req.reason,
        req.requestedBy,
      );

      final now = DateTime.now();
      final affected =
          await (update(stockAdjustmentRequests)..where(
                (t) =>
                    t.id.equals(requestId) &
                    whereBusiness(t) &
                    t.status.equals('pending'),
              ))
              .write(
                StockAdjustmentRequestsCompanion(
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
        stockAdjustmentRequests,
      )..where((t) => t.id.equals(requestId) & whereBusiness(t))).getSingle();
      await db.syncDao.enqueueUpsert(
        'stock_adjustment_requests',
        updated.toCompanion(true),
      );

      await db.activityLogDao.log(
        action: 'stock_adjustment_approved',
        description: 'Approved stock change: ${req.summary}',
        staffId: approverId,
        storeId: req.storeId,
        productId: req.productId,
      );
    });

    if (didApprove && requestedBy != null) {
      await db.notificationsDao.fireNotification(
        type: 'stock_approval.approved',
        message: 'Your stock request was approved & applied — $summary',
        severity: 'info',
        linkedRecordId: requestId,
        recipientUserId: requestedBy,
      );
    }
  }

  /// Reject a pending request — no inventory movement. The optional [reason]
  /// (why it was rejected) is shown to the requester in the rejection
  /// notification and recorded in the activity log. Notifies the requester.
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
          await (select(stockAdjustmentRequests)
                ..where((t) => t.id.equals(requestId) & whereBusiness(t)))
              .getSingleOrNull();
      if (req == null || req.status != 'pending') return;
      final now = DateTime.now();
      final affected =
          await (update(stockAdjustmentRequests)..where(
                (t) =>
                    t.id.equals(requestId) &
                    whereBusiness(t) &
                    t.status.equals('pending'),
              ))
              .write(
                StockAdjustmentRequestsCompanion(
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
        stockAdjustmentRequests,
      )..where((t) => t.id.equals(requestId) & whereBusiness(t))).getSingle();
      await db.syncDao.enqueueUpsert(
        'stock_adjustment_requests',
        updated.toCompanion(true),
      );

      await db.activityLogDao.log(
        action: 'stock_adjustment_rejected',
        description:
            'Rejected stock change: ${req.summary}'
            '${hasReason ? ' — Reason: $trimmedReason' : ''}',
        staffId: approverId,
        storeId: req.storeId,
        productId: req.productId,
      );
    });

    if (didReject && requestedBy != null) {
      await db.notificationsDao.fireNotification(
        type: 'stock_approval.rejected',
        message:
            'Your stock request was rejected'
            '${hasReason ? ' — $trimmedReason' : '.'}',
        severity: 'warning',
        linkedRecordId: requestId,
        recipientUserId: requestedBy,
      );
    }
  }
}

@DriftAccessor(tables: [StockCounts])
class StockCountsDao extends DatabaseAccessor<AppDatabase>
    with _$StockCountsDaoMixin, BusinessScopedDao<AppDatabase> {
  StockCountsDao(super.db);

  /// Persists one saved Daily Stock Count session (§17.3) — the stock-audit
  /// snapshot the Daily Reconciliation Report (Ring 3, §25.9) reads.
  /// [changedLines] are the products whose actual ≠ system, each a map
  /// {p,n,s,a,d} = product id / name / system / actual / diff (diff = actual −
  /// system); matched lines are omitted but counted in [productsCounted]. The
  /// shortage/surplus roll-up is derived here so the report (and the unit test)
  /// can read it without re-parsing the JSON. Synced via enqueueUpsert (§5).
  Future<String> recordCount({
    required String? storeId,
    required String businessDate,
    required int productsCounted,
    required List<Map<String, dynamic>> changedLines,
    String? countedBy,
  }) async {
    var shortageCount = 0;
    var surplusCount = 0;
    var shortageUnits = 0;
    var surplusUnits = 0;
    for (final line in changedLines) {
      final d = (line['d'] as num).toInt();
      if (d < 0) {
        shortageCount++;
        shortageUnits += -d;
      } else if (d > 0) {
        surplusCount++;
        surplusUnits += d;
      }
    }
    final now = DateTime.now();
    final row = StockCountsCompanion.insert(
      id: Value(UuidV7.generate()),
      businessId: requireBusinessId(),
      storeId: Value(storeId),
      businessDate: businessDate,
      productsCounted: productsCounted,
      shortageCount: shortageCount,
      surplusCount: surplusCount,
      shortageUnits: shortageUnits,
      surplusUnits: surplusUnits,
      linesJson: jsonEncode(changedLines),
      countedBy: Value(countedBy),
      createdAt: Value(now),
      lastUpdatedAt: Value(now),
    );
    await into(stockCounts).insert(row);
    await db.syncDao.enqueueUpsert('stock_counts', row);
    return row.id.value;
  }

  /// Every saved count for the business, newest first — the rows the Daily
  /// Reconciliation Report (§25.9) and the Stock Count History sheet render.
  Stream<List<StockCountData>> watchAllForBusiness() {
    return (select(stockCounts)
          ..where((t) => whereBusiness(t))
          ..orderBy([
            (t) => OrderingTerm.desc(t.businessDate),
            (t) => OrderingTerm.desc(t.createdAt),
          ]))
        .watch();
  }

  /// Saved counts for a given store + day (the report's per-day drill-down).
  Future<List<StockCountData>> getForDay(String? storeId, String businessDate) {
    return (select(stockCounts)..where((t) {
          final base = whereBusiness(t) & t.businessDate.equals(businessDate);
          return storeId == null ? base : base & t.storeId.equals(storeId);
        }))
        .get();
  }
}
