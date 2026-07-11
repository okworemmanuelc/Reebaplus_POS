part of 'daos.dart';

@DriftAccessor(tables: [Suppliers, Products, Categories, Stores, Manufacturers])
class CatalogDao extends DatabaseAccessor<AppDatabase>
    with _$CatalogDaoMixin, BusinessScopedDao<AppDatabase> {
  CatalogDao(super.db);

  Stream<List<SupplierData>> watchAllSupplierDatas() {
    return (select(suppliers)
          ..where((t) => whereBusiness(t) & t.isDeleted.not())
          ..orderBy([(t) => OrderingTerm(expression: t.name)]))
        .watch();
  }

  Future<List<SupplierData>> getAllSuppliers() {
    return (select(suppliers)
          ..where((t) => whereBusiness(t) & t.isDeleted.not())
          ..orderBy([(t) => OrderingTerm(expression: t.name)]))
        .get();
  }

  Future<String> insertSupplier(SuppliersCompanion companion) async {
    final id = UuidV7.generate();
    final row = companion.copyWith(
      id: Value(id),
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(suppliers).insert(row);
    await db.syncDao.enqueueUpsert('suppliers', row);
    return id;
  }

  /// One supplier, live (header for the Supplier Details screen). Null once
  /// soft-deleted or out of business scope.
  Stream<SupplierData?> watchSupplierById(String id) {
    return (select(suppliers)
          ..where((t) => t.id.equals(id) & whereBusiness(t) & t.isDeleted.not())
          ..limit(1))
        .watchSingleOrNull();
  }

  /// Edit a supplier (§21.5/§21.7 — CEO only, enforced at the UI). Writes the
  /// passed columns, then full-row enqueues: a partial suppliers upsert would
  /// omit the NOT NULL name/business_id (Postgres 23502).
  Future<void> updateSupplier(SuppliersCompanion companion) async {
    final id = companion.id.value;
    final comp = companion.copyWith(lastUpdatedAt: Value(DateTime.now()));
    await (update(
      suppliers,
    )..where((t) => t.id.equals(id) & whereBusiness(t))).write(comp);
    final row = await (select(
      suppliers,
    )..where((t) => t.id.equals(id) & whereBusiness(t))).getSingleOrNull();
    if (row != null) {
      await db.syncDao.enqueueUpsert('suppliers', row.toCompanion(true));
    }
  }

  /// Soft-delete a supplier (hard rule #9 — suppliers are soft-delete only,
  /// §21.7). Routed through enqueueUpsert so the tombstone syncs.
  Future<void> softDeleteSupplier(String id) async {
    final now = DateTime.now();
    await (update(
      suppliers,
    )..where((t) => t.id.equals(id) & whereBusiness(t))).write(
      SuppliersCompanion(
        isDeleted: const Value(true),
        lastUpdatedAt: Value(now),
      ),
    );
    final row = await (select(
      suppliers,
    )..where((t) => t.id.equals(id) & whereBusiness(t))).getSingleOrNull();
    if (row != null) {
      await db.syncDao.enqueueUpsert('suppliers', row.toCompanion(true));
    }
  }

  Future<String> insertProduct(ProductsCompanion companion) async {
    final id = UuidV7.generate();
    final row = companion.copyWith(
      id: Value(id),
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(products).insert(row);
    await db.syncDao.enqueueUpsert('products', row);
    return id;
  }

  /// Combined product + optional initial-stock create. Replaces the
  /// `insertProduct(...)` + `adjustStock(...)` two-step pattern with one
  /// transactional local write + one domain envelope when the
  /// `feature.domain_rpcs_v2.create_product` flag is on. Without the
  /// flag, behaviour is identical to the legacy two-step path (3-4
  /// outbox rows). With the flag, it's one row.
  Future<String> insertProductWithInitialStock(
    ProductsCompanion companion, {
    int? initialStock,
    String? storeId,
    String? performedBy,
  }) async {
    final id = UuidV7.generate();
    final productRow = companion.copyWith(
      id: Value(id),
      lastUpdatedAt: Value(DateTime.now()),
    );

    final flagValue = await db.systemConfigDao.get(
      'feature.domain_rpcs_v2.create_product',
    );
    final useDomainRpc = flagValue == 'true' || flagValue == '"true"';
    final hasInitialStock =
        initialStock != null && initialStock > 0 && storeId != null;
    // Epic 2 / #42: the opening Cost Batch's cost = the entered buying price
    // (0 → an uncosted batch, consistent with F1/F2).
    final openingCostKobo = productRow.buyingPriceKobo.present
        ? productRow.buyingPriceKobo.value
        : 0;

    await transaction(() async {
      // Product row goes in locally for both paths (UI immediate; the
      // server's authoritative row arrives via _applyDomainResponse and
      // overwrites by id when the v2 RPC returns).
      await into(products).insert(productRow);

      if (useDomainRpc) {
        // Inventory cache local update (UI immediate). On the v2 path
        // we do NOT mirror stock_adjustments / stock_transactions
        // locally — the server mints them with gen_random_uuid() and
        // the response is the sole writer of those rows locally.
        if (hasInitialStock) {
          await customInsert(
            'INSERT INTO inventory (id, business_id, product_id, store_id, quantity) '
            'VALUES (?, ?, ?, ?, ?) '
            'ON CONFLICT(business_id, product_id, store_id) DO UPDATE SET '
            'quantity = quantity + excluded.quantity',
            variables: [
              Variable(UuidV7.generate()),
              Variable(requireBusinessId()),
              Variable(id),
              Variable(storeId),
              Variable(initialStock),
            ],
            updates: {db.inventory},
          );
        }

        // Build the thin-intent payload from the companion's serialized
        // (snake_case) JSON. Drift's `toColumns(nullToAbsent: true)`
        // skips absent + null-valued fields, so we only forward keys the
        // caller actually set; the v2 RPC supplies SQL DEFAULTs for the
        // rest.
        final productJson = serializeInsertable(productRow);
        final payload = <String, dynamic>{
          'p_business_id': requireBusinessId(),
          'p_actor_id': performedBy,
          'p_product_id': id,
          'p_name': productJson['name'],
          if (productJson.containsKey('unit')) 'p_unit': productJson['unit'],
          if (productJson.containsKey('subtitle'))
            'p_subtitle': productJson['subtitle'],
          if (productJson.containsKey('sku')) 'p_sku': productJson['sku'],
          if (productJson.containsKey('size')) 'p_size': productJson['size'],
          if (productJson.containsKey('retailer_price_kobo'))
            'p_retailer_price_kobo': productJson['retailer_price_kobo'],
          if (productJson.containsKey('wholesaler_price_kobo'))
            'p_wholesaler_price_kobo': productJson['wholesaler_price_kobo'],
          if (productJson.containsKey('buying_price_kobo'))
            'p_buying_price_kobo': productJson['buying_price_kobo'],
          if (productJson.containsKey('category_id'))
            'p_category_id': productJson['category_id'],
          if (productJson.containsKey('crate_size_group_id'))
            'p_crate_size_group_id': productJson['crate_size_group_id'],
          if (productJson.containsKey('manufacturer_id'))
            'p_manufacturer_id': productJson['manufacturer_id'],
          if (productJson.containsKey('supplier_id'))
            'p_supplier_id': productJson['supplier_id'],
          if (productJson.containsKey('low_stock_threshold'))
            'p_low_stock_threshold': productJson['low_stock_threshold'],
          if (productJson.containsKey('track_empties'))
            'p_track_empties': productJson['track_empties'],
          if (productJson.containsKey('allow_fractional_sales'))
            'p_allow_fractional_sales': productJson['allow_fractional_sales'],
          if (productJson.containsKey('image_path'))
            'p_image_path': productJson['image_path'],
          if (productJson.containsKey('expiry_date'))
            'p_expiry_date': productJson['expiry_date'],
          if (hasInitialStock)
            'p_initial_stock': <String, dynamic>{
              'store_id': storeId,
              'quantity': initialStock,
            },
        };
        await db.syncDao.enqueue(
          'domain:pos_create_product_v2',
          jsonEncode(payload),
        );

        // Epic 2 / #42: opening Cost Batch, enqueued AFTER the product-create
        // envelope so the batch's push (which FK-references the product) lands
        // once the server has minted the product. Same transaction as the
        // inventory increment above → the queue can't drift from on-hand.
        if (hasInitialStock) {
          await db.costBatchesDao.recordInflowBatch(
            productId: id,
            storeId: storeId,
            quantity: initialStock,
            costKobo: openingCostKobo,
          );
        }
        return;
      }

      // v1 (flag-OFF) path: full local mirror + per-table upserts.
      await db.syncDao.enqueueUpsert('products', productRow);

      if (hasInitialStock) {
        final adjId = UuidV7.generate();
        final adjComp = StockAdjustmentsCompanion.insert(
          id: Value(adjId),
          businessId: requireBusinessId(),
          productId: id,
          storeId: storeId,
          quantityDiff: initialStock,
          reason: 'initial_stock',
          performedBy: Value(performedBy),
          lastUpdatedAt: Value(DateTime.now()),
        );
        await db.into(db.stockAdjustments).insert(adjComp);
        await db.syncDao.enqueueUpsert('stock_adjustments', adjComp);

        final txId = UuidV7.generate();
        final txComp = StockTransactionsCompanion.insert(
          id: Value(txId),
          businessId: requireBusinessId(),
          productId: id,
          locationId: storeId,
          quantityDelta: initialStock,
          movementType: 'adjustment',
          adjustmentId: Value(adjId),
          performedBy: Value(performedBy),
          lastUpdatedAt: Value(DateTime.now()),
        );
        await db.into(db.stockTransactions).insert(txComp);
        await db.syncDao.enqueueUpsert('stock_transactions', txComp);

        await customInsert(
          'INSERT INTO inventory (id, business_id, product_id, store_id, quantity) '
          'VALUES (?, ?, ?, ?, ?) '
          'ON CONFLICT(business_id, product_id, store_id) DO UPDATE SET '
          'quantity = quantity + excluded.quantity',
          variables: [
            Variable(UuidV7.generate()),
            Variable(requireBusinessId()),
            Variable(id),
            Variable(storeId),
            Variable(initialStock),
          ],
          updates: {db.inventory},
        );
        final invRow =
            await (db.select(db.inventory)..where(
                  (t) =>
                      t.productId.equals(id) &
                      t.storeId.equals(storeId) &
                      t.businessId.equals(requireBusinessId()),
                ))
                .getSingle();
        await db.syncDao.enqueueUpsert('inventory', invRow);

        // Epic 2 / #42: opening Cost Batch for the initial stock, enqueued after
        // the products upsert above so its FK-to-product push resolves. Same
        // transaction as the inventory increment → queue can't drift from
        // on-hand.
        await db.costBatchesDao.recordInflowBatch(
          productId: id,
          storeId: storeId,
          quantity: initialStock,
          costKobo: openingCostKobo,
        );
      }
    });
    return id;
  }

  Future<String> insertCategory(CategoriesCompanion companion) async {
    final id = UuidV7.generate();
    final row = companion.copyWith(
      id: Value(id),
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(categories).insert(row);
    await db.syncDao.enqueueUpsert('categories', row);
    return id;
  }

  Future<List<ManufacturerData>> getAllManufacturers() {
    return (select(manufacturers)
          ..where((t) => whereBusiness(t) & t.isDeleted.not())
          ..orderBy([(t) => OrderingTerm(expression: t.name)]))
        .get();
  }

  Stream<List<ProductData>> watchAvailableProductDatas({String? categoryId}) {
    final query = select(products)
      ..where(
        (t) =>
            whereBusiness(t) & t.isDeleted.not() & t.isAvailable.equals(true),
      )
      ..orderBy([(t) => OrderingTerm(expression: t.name)]);
    if (categoryId != null) {
      query.where((t) => t.categoryId.equals(categoryId));
    }
    return query.watch();
  }

  Future<ProductData?> findById(String id) {
    return (select(
      products,
    )..where((t) => t.id.equals(id) & whereBusiness(t))).getSingleOrNull();
  }

  Future<ProductData?> findByName(String name) {
    return (select(products)
          ..where(
            (t) => t.name.equals(name) & whereBusiness(t) & t.isDeleted.not(),
          )
          ..limit(1))
        .getSingleOrNull();
  }

  /// Look up a product by its [barcode] (#113 — foundation for scanning, #118).
  /// Returns the first business-scoped, non-deleted match, or null. Barcodes are
  /// softly unique (no DB UNIQUE — that would jam the offline outbox), so a
  /// collision is possible; callers that need to warn on one compare the match's
  /// id to the product being edited. An empty [barcode] never matches.
  Future<ProductData?> findProductByBarcode(String barcode) {
    final trimmed = barcode.trim();
    if (trimmed.isEmpty) return Future.value(null);
    return (select(products)
          ..where(
            (t) =>
                t.barcode.equals(trimmed) &
                whereBusiness(t) &
                t.isDeleted.not(),
          )
          ..limit(1))
        .getSingleOrNull();
  }

  Future<void> softDeleteProduct(String productId) async {
    // Soft-delete: flip is_deleted and push it as an UPSERT, never a hard
    // tombstone. A `products:delete` makes the cloud run `DELETE FROM products`,
    // which violates `inventory_product_id_fkey` (inventory rows still
    // reference the product) and the delete sticks in the queue retrying
    // forever. Per CLAUDE.md §5 + hard rule #9, soft-deletes go through
    // enqueueUpsert. The companion carries id + business_id so the cloud's
    // partial upsert updates is_deleted on the existing row.
    final comp = ProductsCompanion(
      id: Value(productId),
      businessId: Value(requireBusinessId()),
      isDeleted: const Value(true),
      lastUpdatedAt: Value(DateTime.now()),
    );
    await (update(
      products,
    )..where((t) => t.id.equals(productId) & whereBusiness(t))).write(comp);
    // Full-row enqueue: a partial products upsert omits the NOT NULL name → 23502.
    await _enqueueFullProduct(productId);
  }

  Future<void> updateProductDetails(
    String productId, {
    required String name,
    String? manufacturerId,
    required int buyingPriceKobo,
    required int retailerPriceKobo,
    required int wholesalerPriceKobo,
    int? emptyCrateValueKobo,
    String? categoryId,
    String? unit,
    bool? trackEmpties,
    bool? allowFractionalSales,
    int? lowStockThreshold,
    // Sentinel-defaulted: omit to leave the legacy local image_path untouched.
    // #78 photos live in image_url + the ProductImageService cache, never here,
    // so the POS grid (which renders image_path) stays photo-free.
    Object? imagePath = _unset,
    int? monthlyTargetUnits,
    // Optional cosmetic / metadata fields. Wrapped with present-check
    // sentinels so the caller can leave any of them out and the column
    // stays untouched (Value.absent vs Value(null) — the latter would
    // null-out the column).
    Object? subtitle = _unset,
    Object? colorHex = _unset,
    Object? supplierId = _unset,
    Object? size = _unset,
    Object? expiryDate = _unset,
    // Optional product barcode (#113). Sentinel-defaulted like the cosmetic
    // fields above: omit to leave the column untouched. A concrete String (or
    // null to clear locally) is written; a set value pushes because the partial
    // companion enqueued below serializes present, non-null values.
    Object? barcode = _unset,
  }) async {
    final now = DateTime.now();
    final comp = ProductsCompanion(
      id: Value(productId),
      name: Value(name),
      manufacturerId: Value(manufacturerId),
      buyingPriceKobo: Value(buyingPriceKobo),
      retailerPriceKobo: Value(retailerPriceKobo),
      wholesalerPriceKobo: Value(wholesalerPriceKobo),
      emptyCrateValueKobo: emptyCrateValueKobo == null
          ? const Value.absent()
          : Value(emptyCrateValueKobo),
      categoryId: Value(categoryId),
      unit: unit == null ? const Value.absent() : Value(unit),
      trackEmpties: trackEmpties == null
          ? const Value.absent()
          : Value(trackEmpties),
      allowFractionalSales: allowFractionalSales == null
          ? const Value.absent()
          : Value(allowFractionalSales),
      lowStockThreshold: lowStockThreshold == null
          ? const Value.absent()
          : Value(lowStockThreshold),
      monthlyTargetUnits: monthlyTargetUnits == null
          ? const Value.absent()
          : Value(monthlyTargetUnits),
      imagePath: identical(imagePath, _unset)
          ? const Value.absent()
          : Value(imagePath as String?),
      subtitle: identical(subtitle, _unset)
          ? const Value.absent()
          : Value(subtitle as String?),
      colorHex: identical(colorHex, _unset)
          ? const Value.absent()
          : Value(colorHex as String?),
      supplierId: identical(supplierId, _unset)
          ? const Value.absent()
          : Value(supplierId as String?),
      size: identical(size, _unset)
          ? const Value.absent()
          : Value(size as String?),
      expiryDate: identical(expiryDate, _unset)
          ? const Value.absent()
          : Value(expiryDate as DateTime?),
      barcode: identical(barcode, _unset)
          ? const Value.absent()
          : Value(barcode as String?),
      lastUpdatedAt: Value(now),
    );
    await (update(
      products,
    )..where((t) => t.id.equals(productId) & whereBusiness(t))).write(comp);
    await db.syncDao.enqueueUpsert('products', comp);
  }

  /// Writes the cloud [imageUrl] (or null to clear) onto [productId] and
  /// enqueues the product for sync so the photo converges cross-device (#78).
  /// Called after a successful image upload — on Add/Update Product, the detail
  /// screen, and by the offline retry flush once connectivity returns.
  ///
  /// Enqueues the FULL row (via [_enqueueFullProduct]) rather than a partial
  /// `{image_url}` upsert: the outbox coalesces one pending row per
  /// `(action_type, id)`, so a partial upsert queued right after a full
  /// `updateProductDetails` upsert would REPLACE it and silently drop the
  /// concurrent name/price edits. Re-reading and pushing every column keeps
  /// those edits (and satisfies the cloud's NOT NULL columns).
  Future<void> setProductImageUrl(String productId, String? imageUrl) async {
    await (update(products)
          ..where((t) => t.id.equals(productId) & whereBusiness(t)))
        .write(
      ProductsCompanion(
        imageUrl: Value(imageUrl),
        lastUpdatedAt: Value(DateTime.now()),
      ),
    );
    await _enqueueFullProduct(productId);
  }

  Future<void> updateProductPrices(
    String productId, {
    required int buyingPriceKobo,
    required int retailerPriceKobo,
    required int wholesalerPriceKobo,
  }) async {
    final now = DateTime.now();
    final comp = ProductsCompanion(
      id: Value(productId),
      buyingPriceKobo: Value(buyingPriceKobo),
      retailerPriceKobo: Value(retailerPriceKobo),
      wholesalerPriceKobo: Value(wholesalerPriceKobo),
      lastUpdatedAt: Value(now),
    );
    await (update(products)
          ..where((t) => t.id.equals(productId) & whereBusiness(t)))
        .write(comp);
    await _enqueueFullProduct(productId);
  }

  Future<List<String>> getUniqueProductUnits() async {
    final query = selectOnly(products, distinct: true)
      ..addColumns([products.unit])
      ..where(whereBusiness(products) & products.isDeleted.not());
    final rows = await query.get();
    return rows.map((r) => r.read(products.unit)!).toList();
  }

  Future<void> updateMonthlyTarget(String productId, int targetUnits) async {
    final now = DateTime.now();
    final comp = ProductsCompanion(
      id: Value(productId),
      monthlyTargetUnits: Value(targetUnits),
      lastUpdatedAt: Value(now),
    );
    await (update(
      products,
    )..where((t) => t.id.equals(productId) & whereBusiness(t))).write(comp);
    await _enqueueFullProduct(productId);
  }

  int getPriceForTier(ProductData product, String group) {
    switch (group) {
      case 'wholesaler':
        return product.wholesalerPriceKobo;
      default:
        return product.retailerPriceKobo;
    }
  }

  /// Enqueues the FULL manufacturer row for sync. The per-column update methods
  /// below write only the changed column locally, but a partial `manufacturers`
  /// upsert omits the NOT NULL `name`, which the cloud rejects (23502). Reading
  /// the row back and enqueuing every column keeps the cloud insert valid.
  Future<void> _enqueueFullManufacturer(String id) async {
    final row = await (select(
      manufacturers,
    )..where((t) => t.id.equals(id) & whereBusiness(t))).getSingleOrNull();
    if (row != null) {
      await db.syncDao.enqueueUpsert('manufacturers', row.toCompanion(true));
    }
  }

  /// Enqueues the FULL product row for sync. Per-column product updates and the
  /// soft-delete build a partial companion; a partial `products` upsert omits the
  /// NOT NULL `name`, which the cloud rejects (23502). Re-read + enqueue all cols.
  Future<void> _enqueueFullProduct(String id) async {
    final row = await (select(
      products,
    )..where((t) => t.id.equals(id) & whereBusiness(t))).getSingleOrNull();
    if (row != null) {
      await db.syncDao.enqueueUpsert('products', row.toCompanion(true));
    }
  }

  Future<void> updateManufacturerEmptyCrateValue(
    String manufacturerId,
    int valueKobo,
  ) async {
    final now = DateTime.now();
    final comp = ManufacturersCompanion(
      id: Value(manufacturerId),
      depositAmountKobo: Value(valueKobo),
      lastUpdatedAt: Value(now),
    );
    await (update(manufacturers)
          ..where((t) => t.id.equals(manufacturerId) & whereBusiness(t)))
        .write(comp);
    // Full-row enqueue: a partial upsert would omit the NOT NULL name → 23502.
    await _enqueueFullManufacturer(manufacturerId);
  }

  Future<void> updateTrackEmpties(String productId, bool value) async {
    final now = DateTime.now();
    final comp = ProductsCompanion(
      id: Value(productId),
      trackEmpties: Value(value),
      lastUpdatedAt: Value(now),
    );
    await (update(
      products,
    )..where((t) => t.id.equals(productId) & whereBusiness(t))).write(comp);
    await _enqueueFullProduct(productId);
  }
}
