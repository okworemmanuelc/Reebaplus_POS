import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:rxdart/rxdart.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/business_scoped_dao.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/database/sync_helpers.dart';

part 'daos.g.dart';

/// Sentinel for "argument was not provided" on optional setter parameters,
/// distinct from "argument was provided as null". Used by methods that
/// accept partial-update payloads (e.g. `CatalogDao.updateProductDetails`)
/// to map missing args to `Value.absent()` and explicit-null args to
/// `Value(null)` — the latter clears the column, the former leaves it
/// untouched.
const Object _unset = Object();

@DriftAccessor(
  tables: [Suppliers, Products, Categories, Stores, Manufacturers],
)
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

    final flagValue =
        await db.systemConfigDao.get('feature.domain_rpcs_v2.create_product');
    final useDomainRpc = flagValue == 'true' || flagValue == '"true"';
    final hasInitialStock =
        initialStock != null && initialStock > 0 && storeId != null;

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
            'p_allow_fractional_sales':
                productJson['allow_fractional_sales'],
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
        await db.syncDao
            .enqueue('domain:pos_create_product_v2', jsonEncode(payload));
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
        final invRow = await (db.select(db.inventory)
              ..where((t) =>
                  t.productId.equals(id) &
                  t.storeId.equals(storeId) &
                  t.businessId.equals(requireBusinessId())))
            .getSingle();
        await db.syncDao.enqueueUpsert('inventory', invRow);
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
    String? imagePath,
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
      imagePath: Value(imagePath),
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
      lastUpdatedAt: Value(now),
    );
    await (update(
      products,
    )..where((t) => t.id.equals(productId) & whereBusiness(t))).write(comp);
    await db.syncDao.enqueueUpsert('products', comp);
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
    final row = await (select(manufacturers)
          ..where((t) => t.id.equals(id) & whereBusiness(t)))
        .getSingleOrNull();
    if (row != null) {
      await db.syncDao.enqueueUpsert('manufacturers', row.toCompanion(true));
    }
  }

  /// Enqueues the FULL product row for sync. Per-column product updates and the
  /// soft-delete build a partial companion; a partial `products` upsert omits the
  /// NOT NULL `name`, which the cloud rejects (23502). Re-read + enqueue all cols.
  Future<void> _enqueueFullProduct(String id) async {
    final row = await (select(products)
          ..where((t) => t.id.equals(id) & whereBusiness(t)))
        .getSingleOrNull();
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
  ],
)
class InventoryDao extends DatabaseAccessor<AppDatabase>
    with _$InventoryDaoMixin, BusinessScopedDao<AppDatabase> {
  InventoryDao(super.db);

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
    final row = await (select(manufacturers)
          ..where((t) => t.id.equals(id) & whereBusiness(t)))
        .getSingleOrNull();
    if (row != null) {
      await db.syncDao.enqueueUpsert('manufacturers', row.toCompanion(true));
    }
  }

  Future<void> updateManufacturerStock(String id, int newStock) async {
    final now = DateTime.now();
    final comp = ManufacturersCompanion(
      id: Value(id),
      emptyCrateStock: Value(newStock),
      lastUpdatedAt: Value(now),
    );
    await (update(
      manufacturers,
    )..where((t) => t.id.equals(id) & whereBusiness(t))).write(comp);
    await _enqueueFullManufacturer(id);
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

  Stream<List<ProductDataWithStock>> watchProductsByStore(
    String storeId,
  ) => _watchProductsWithStock(storeId: storeId);

  Stream<List<ProductDataWithStock>> watchAllProductDatasWithStock() =>
      _watchProductsWithStock();

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
  Future<void> adjustStock(
    String productId,
    String storeId,
    int delta,
    String note,
    String? staffId,
  ) async {
    if (delta == 0) return;
    await transaction(() async {
      // v2 path: emit a single `domain:pos_inventory_delta_v2` envelope.
      // The server mints stock_adjustments + stock_transactions rows
      // (`gen_random_uuid()`) and returns them via `_applyDomainResponse`,
      // which is the sole writer of those rows locally so ids match
      // cloud exactly.
      final flagValue = await db.systemConfigDao
          .get('feature.domain_rpcs_v2.inventory_delta');
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
        final bundle = <String, dynamic>{
          'p_business_id': requireBusinessId(),
          'p_actor_id': staffId,
          'p_movements': [
            {
              'movement_id': movementId,
              'product_id': productId,
              'store_id': storeId,
              'quantity_delta': delta,
              'movement_type': 'adjustment',
              'reason': note,
            },
          ],
        };
        await db.syncDao
            .enqueue('domain:pos_inventory_delta_v2', jsonEncode(bundle));
        return;
      }

      // v1 (flag-OFF) path: full local mirror + per-table upserts.
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

      final txId = UuidV7.generate();
      final txComp = StockTransactionsCompanion.insert(
        id: Value(txId),
        businessId: requireBusinessId(),
        productId: productId,
        locationId: storeId,
        quantityDelta: delta,
        movementType: 'adjustment',
        adjustmentId: Value(adjustmentId),
        performedBy: Value(staffId),
        lastUpdatedAt: Value(DateTime.now()),
      );
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
    final fullGroup = await (select(crateSizeGroups)
          ..where((t) => t.id.equals(groupId) & whereBusiness(t)))
        .getSingleOrNull();
    if (fullGroup != null) {
      await db.syncDao
          .enqueueUpsert('crate_size_groups', fullGroup.toCompanion(true));
    }
  }

  /// Increment a manufacturer's empty-crate stock counter. Used by the
  /// receive-delivery and crate-return flows to credit the physical pool of
  /// returnable crates held against a manufacturer.
  Future<void> addEmptyCrates(String manufacturerId, int quantity) async {
    if (quantity == 0) return;
    await customUpdate(
      'UPDATE manufacturers SET empty_crate_stock = empty_crate_stock + ?, '
      'last_updated_at = CURRENT_TIMESTAMP '
      'WHERE id = ? AND business_id = ?',
      variables: [
        Variable(quantity),
        Variable(manufacturerId),
        Variable(requireBusinessId()),
      ],
      updates: {manufacturers},
    );
    final mfrRow =
        await (select(manufacturers)
              ..where((t) => t.id.equals(manufacturerId) & whereBusiness(t)))
            .getSingle();
    await db.syncDao.enqueueUpsert('manufacturers', mfrRow);
  }

  /// Stream the per-manufacturer count of full bottles in stock, derived
  /// from inventory rows joined with products on `manufacturer_id`.
  Stream<Map<String, int>> watchFullCratesByManufacturer() {
    final query =
        select(inventory).join([
          innerJoin(products, products.id.equalsExp(inventory.productId)),
        ])..where(
          whereBusiness(inventory) &
              whereBusiness(products) &
              products.manufacturerId.isNotNull() &
              products.isDeleted.not(),
        );
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
  ],
)
class OrdersDao extends DatabaseAccessor<AppDatabase>
    with _$OrdersDaoMixin, BusinessScopedDao<AppDatabase> {
  OrdersDao(super.db);

  // ── Reads ──────────────────────────────────────────────────────────────────

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

        if (item != null && product != null) {
          result[order.id]!.items.add(
            OrderItemDataWithProductData(item, product),
          );
        }
      }
      return result.values.toList();
    });
  }

  // ── Writes ─────────────────────────────────────────────────────────────────

  /// Enqueues the FULL order row for sync. Per-column order updates build a
  /// partial companion; a partial `orders` upsert omits NOT NULL columns
  /// (order_number, total_amount_kobo, …) and the cloud rejects it (23502).
  Future<void> _enqueueFullOrder(String id) async {
    final row = await (select(orders)
          ..where((o) => o.id.equals(id) & whereBusiness(o)))
        .getSingleOrNull();
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
    await (update(orders)
          ..where((o) => o.id.equals(orderId) & whereBusiness(o)))
        .write(comp);
    await _enqueueFullOrder(orderId);
  }

  /// Atomic order + items + inventory + ledger + payment + wallet in a single txn.
  /// Returns the new order ID.
  ///
  /// [walletDebitKobo] is the amount to debit from the customer's wallet. Used
  /// for wallet payments (full balance), partial payments (the remainder put on
  /// account), and credit sales (the full total). Requires [customerId].
  Future<String> createOrder({
    required OrdersCompanion order,
    required List<OrderItemsCompanion> items,
    String? customerId,
    required int amountPaidKobo,
    required int totalAmountKobo,
    required String staffId,
    String? storeId,
    int walletDebitKobo = 0,
    String paymentMethod = 'cash',
    String? fundsAccountId,
    String? businessDate,
  }) {
    return db.transaction(() async {
      final orderId = order.id.present ? order.id.value : UuidV7.generate();

      final flagValue =
          await db.systemConfigDao.get('feature.domain_rpcs_v2.record_sale');
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
        final saleStoreId =
            storeId ?? items.first.storeId.value;

        final payload = <String, dynamic>{
          'p_business_id': requireBusinessId(),
          'p_actor_id': staffId,
          'p_order_id': orderId,
          'p_order_number': orderJson['order_number'],
          'p_store_id': saleStoreId,
          'p_payment_type': orderJson['payment_type'],
          'p_items': thinItems,
          if (orderJson.containsKey('status'))
            'p_status': orderJson['status'],
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
          if (walletDebitKobo > 0) 'p_wallet_amount_kobo': walletDebitKobo,
        };
        await db.syncDao
            .enqueue('domain:pos_record_sale_v2', jsonEncode(payload));
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
        final txId = UuidV7.generate();
        final txComp = StockTransactionsCompanion.insert(
          id: Value(txId),
          businessId: requireBusinessId(),
          productId: item.productId.value,
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

        // Funds Register credit (§14.2 / §23.5 / hard rule #5): the cash /
        // card / transfer portion that landed in the chosen account. Wallet
        // and credit sales have amountPaidKobo == 0, so they never reach here.
        // The "a paid sale MUST name an account" rule is enforced at the
        // business entry (OrderService.addOrder); here we credit when one is
        // provided. V1 path only — if `feature.domain_rpcs_v2.record_sale` is
        // ever enabled, the server must mint this row inside pos_record_sale_v2
        // instead (see Funds Register plan, risk R2).
        if (fundsAccountId != null && businessDate != null) {
          await db.fundTransactionsDao.creditSale(
            fundsAccountId: fundsAccountId,
            storeId: storeId ?? items.first.storeId.value,
            businessDate: businessDate,
            amountKobo: amountPaidKobo,
            orderId: orderId,
            paymentId: payId,
            performedBy: staffId,
          );
        }
      }

      if (walletDebitKobo > 0) {
        if (customerId == null) {
          throw ArgumentError(
            'walletDebitKobo > 0 requires a non-null customerId',
          );
        }
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
          throw StateError('Customer $customerId has no wallet — cannot debit');
        }
        final walletTxId = UuidV7.generate();
        final walletTxComp = WalletTransactionsCompanion.insert(
          id: Value(walletTxId),
          businessId: requireBusinessId(),
          walletId: wallet.id,
          customerId: customerId,
          type: 'debit',
          amountKobo: walletDebitKobo,
          signedAmountKobo: -walletDebitKobo,
          referenceType: 'order_payment',
          orderId: Value(orderId),
          performedBy: Value(staffId),
          lastUpdatedAt: Value(DateTime.now()),
        );
        await into(walletTransactions).insert(walletTxComp);
        await db.syncDao.enqueueUpsert('wallet_transactions', walletTxComp);
      }

      // v1 also enqueues the updated inventory cache so the cloud converges.
      for (final item in items) {
        final productId = item.productId.value;
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

  /// Cancel an order: append compensating stock rows + void payments.
  Future<void> markCancelled(String orderId, String reason, String staffId) async {
    final flagValue =
        await db.systemConfigDao.get('feature.domain_rpcs_v2.cancel_order');
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
        };
        await db.syncDao
            .enqueue('domain:pos_cancel_order', jsonEncode(payload));
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

      // Wallet: Refund any debit associated with the order (ledger is append-only)
      final originalDebit =
          await (select(walletTransactions)
                ..where(
                  (t) =>
                      whereBusiness(t) &
                      t.orderId.equals(orderId) &
                      t.type.equals('debit'),
                )
                ..limit(1))
              .getSingleOrNull();

      if (originalDebit != null) {
        final refundId = UuidV7.generate();
        final refundComp = WalletTransactionsCompanion.insert(
          id: Value(refundId),
          businessId: requireBusinessId(),
          walletId: originalDebit.walletId,
          customerId: originalDebit.customerId,
          type: 'credit',
          amountKobo: originalDebit.amountKobo,
          signedAmountKobo: originalDebit.amountKobo,
          referenceType: 'refund',
          orderId: Value(orderId),
          performedBy: Value(staffId),
          lastUpdatedAt: Value(DateTime.now()),
        );
        await into(walletTransactions).insert(refundComp);
        await db.syncDao.enqueueUpsert('wallet_transactions', refundComp);
      }
    });
  }

  Future<String> generateOrderNumber() async {
    final count =
        await (selectOnly(orders)
              ..where(whereBusiness(orders))
              ..addColumns([orders.id.count()]))
            .map((row) => row.read(orders.id.count()) ?? 0)
            .getSingle();
    return 'ORD-${(count + 1).toString().padLeft(6, '0')}';
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
              orders.status.equals('completed') &
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
      final currentPriceKobo = p.retailerPriceKobo;
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
  Stream<List<SavedCartData>> watchSavedCarts(String? cashierId) {
    final cutoff = DateTime.now();
    return (select(savedCarts)
          ..where(
            (c) =>
                whereBusiness(c) &
                (c.cashierId.isNull() | c.cashierId.equals(cashierId ?? '')) &
                (c.expiresAt.isNull() | c.expiresAt.isBiggerThanValue(cutoff)),
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
    final expired = await (select(savedCarts)
          ..where(
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

class OrderWithItems {
  final OrderData order;
  final List<OrderItemDataWithProductData> items;
  final CustomerData? customer;
  OrderWithItems(this.order, this.items, this.customer);
}

class OrderItemDataWithProductData {
  final OrderItemData item;
  final ProductData product;
  OrderItemDataWithProductData(this.item, this.product);
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
  const CartLineSnapshot({
    required this.productId,
    required this.cartVersion,
    required this.cartUnitPriceKobo,
  });
}

class CrateBalanceEntry {
  final String crateSizeGroupId;
  final String groupName;
  final int balance;
  CrateBalanceEntry({
    required this.crateSizeGroupId,
    required this.groupName,
    required this.balance,
  });
}

@DriftAccessor(
  tables: [
    Customers,
    CustomerCrateBalances,
    CustomerWallets,
    WalletTransactions,
    CrateSizeGroups,
  ],
)
class CustomersDao extends DatabaseAccessor<AppDatabase>
    with _$CustomersDaoMixin, BusinessScopedDao<AppDatabase> {
  CustomersDao(super.db);

  Stream<List<CustomerData>> watchAllCustomers() {
    return (select(customers)
          ..where((t) => whereBusiness(t) & t.isDeleted.not())
          ..orderBy([(t) => OrderingTerm(expression: t.name)]))
        .watch();
  }

  Stream<List<CustomerData>> watchCustomersByStore(String storeId) {
    return (select(customers)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.storeId.equals(storeId) &
                t.isDeleted.not(),
          )
          ..orderBy([(t) => OrderingTerm(expression: t.name)]))
        .watch();
  }

  Future<CustomerData?> findById(String id) {
    return (select(customers)
          ..where((t) => t.id.equals(id) & whereBusiness(t) & t.isDeleted.not())
          ..limit(1))
        .getSingleOrNull();
  }

  Future<CustomerData?> findByPhone(String phone) {
    return (select(customers)
          ..where(
            (t) => t.phone.equals(phone) & whereBusiness(t) & t.isDeleted.not(),
          )
          ..limit(1))
        .getSingleOrNull();
  }

  Stream<CustomerData?> watchCustomerById(String id) {
    return (select(customers)
          ..where((t) => t.id.equals(id) & whereBusiness(t) & t.isDeleted.not())
          ..limit(1))
        .watchSingleOrNull();
  }

  Stream<List<CrateBalanceEntry>> watchCrateBalancesWithGroups(
    String customerId,
  ) {
    final query =
        select(customerCrateBalances).join([
          innerJoin(
            crateSizeGroups,
            crateSizeGroups.id.equalsExp(customerCrateBalances.crateSizeGroupId),
          ),
        ])..where(
          whereBusiness(customerCrateBalances) &
              customerCrateBalances.customerId.equals(customerId),
        );
    return query.watch().map(
      (rows) => rows
          .map(
            (r) => CrateBalanceEntry(
              crateSizeGroupId: r.readTable(customerCrateBalances).crateSizeGroupId,
              groupName: r.readTable(crateSizeGroups).name,
              balance: r.readTable(customerCrateBalances).balance,
            ),
          )
          .toList(),
    );
  }

  Future<String> addCustomer(CustomersCompanion customer) async {
    final customerId = UuidV7.generate();
    final walletId = UuidV7.generate();

    final flagValue =
        await db.systemConfigDao.get('feature.domain_rpcs_v2.create_customer');
    final useDomainRpc = flagValue == 'true' || flagValue == '"true"';

    await transaction(() async {
      final custComp = customer.copyWith(
        id: Value(customerId),
        businessId: Value(requireBusinessId()),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await into(customers).insert(custComp);

      final walletComp = CustomerWalletsCompanion.insert(
        id: Value(walletId),
        businessId: requireBusinessId(),
        customerId: customerId,
        lastUpdatedAt: Value(DateTime.now()),
      );
      await into(customerWallets).insert(walletComp);

      if (useDomainRpc) {
        final payload = <String, dynamic>{
          'p_business_id': requireBusinessId(),
          'p_customer_id': customerId,
          'p_wallet_id': walletId,
          'p_name': custComp.name.value,
          if (custComp.phone.present) 'p_phone': custComp.phone.value,
          if (custComp.email.present) 'p_email': custComp.email.value,
          if (custComp.address.present) 'p_address': custComp.address.value,
          if (custComp.googleMapsLocation.present)
            'p_google_maps_location': custComp.googleMapsLocation.value,
          if (custComp.priceTier.present)
            'p_price_tier': custComp.priceTier.value,
          if (custComp.walletLimitKobo.present)
            'p_wallet_limit_kobo': custComp.walletLimitKobo.value,
          if (custComp.storeId.present)
            'p_store_id': custComp.storeId.value,
        };
        await db.syncDao
            .enqueue('domain:pos_create_customer', jsonEncode(payload));
      } else {
        await db.syncDao.enqueueUpsert('customers', custComp);
        await db.syncDao.enqueueUpsert('customer_wallets', walletComp);
      }
    });
    return customerId;
  }

  /// §18.4 / §18.5 + hard rule #9: soft-delete only. Flip is_deleted and push
  /// it as an UPSERT (never a hard tombstone — wallet and order history still
  /// FK-reference the customer). Full-row enqueue: a partial customers upsert
  /// omits the NOT NULL name → 23502 and would never sync.
  Future<void> softDeleteCustomer(String customerId) async {
    await (update(customers)..where(
          (t) => t.id.equals(customerId) & whereBusiness(t),
        ))
        .write(
          CustomersCompanion(
            isDeleted: const Value(true),
            lastUpdatedAt: Value(DateTime.now()),
          ),
        );
    await _enqueueFullCustomer(customerId);
  }

  /// Re-reads the full customer row (no is_deleted filter — it's used right
  /// after a soft-delete) and enqueues it as a complete upsert.
  Future<void> _enqueueFullCustomer(String id) async {
    final row = await (select(
      customers,
    )..where((t) => t.id.equals(id) & whereBusiness(t))).getSingleOrNull();
    if (row != null) {
      await db.syncDao.enqueueUpsert('customers', row.toCompanion(true));
    }
  }

  // ── Wallet forwarders ────────────────────────────────────────────────────
  // Balance is derived from the WalletTransactions ledger; the legacy
  // `customers.wallet_balance_kobo` cache column is gone. These forwarders
  // keep the customer-screen API surface stable while routing through the
  // ledger DAO.

  Future<int> getWalletBalanceKobo(String customerId) {
    return attachedDatabase.walletTransactionsDao.getBalanceKobo(customerId);
  }

  Stream<int> watchWalletBalance(String customerId) {
    return attachedDatabase.walletTransactionsDao.watchBalanceKobo(customerId);
  }

  Stream<List<WalletTransactionData>> watchWalletHistory(String customerId) {
    return attachedDatabase.walletTransactionsDao.watchHistory(customerId);
  }

  Stream<Map<String, int>> watchAllWalletBalancesKobo() {
    return attachedDatabase.walletTransactionsDao.watchAllBalancesKobo();
  }

  Future<void> updateWalletLimit(String customerId, int limitKobo) {
    return attachedDatabase.customerWalletsDao.updateWalletLimit(
      customerId,
      limitKobo,
    );
  }

  /// Append a wallet ledger entry. Used by legacy topup/refund flows in
  /// `CustomerService`. Pass an empty [staffId] when no auth context exists
  /// — it's stored as NULL.
  Future<void> updateWalletBalance({
    required String customerId,
    required int amountKobo,
    required String type,
    required String referenceType,
    String? note,
    String staffId = '',
  }) async {
    final wallet = await attachedDatabase.customerWalletsDao.getByCustomerId(
      customerId,
    );
    if (wallet == null) {
      throw StateError('Customer $customerId has no wallet');
    }
    final txId = UuidV7.generate();
    final signed = type == 'credit' ? amountKobo.abs() : -amountKobo.abs();
    final txComp = WalletTransactionsCompanion.insert(
      id: Value(txId),
      businessId: requireBusinessId(),
      walletId: wallet.id,
      customerId: customerId,
      type: type,
      amountKobo: amountKobo.abs(),
      signedAmountKobo: signed,
      referenceType: referenceType,
      performedBy: Value(staffId.isEmpty ? null : staffId),
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(walletTransactions).insert(txComp);
    await db.syncDao.enqueueUpsert('wallet_transactions', txComp);
  }
}

@DriftAccessor(tables: [Shipments, PurchaseItems, Suppliers, Products])
class ShipmentsDao extends DatabaseAccessor<AppDatabase>
    with _$ShipmentsDaoMixin, BusinessScopedDao<AppDatabase> {
  ShipmentsDao(super.db);

  /// Most recent shipment row for a given product, exposed as a small struct
  /// for the product-detail screen. Returns null when the product has never
  /// been received in a shipment.
  Future<LastShipmentInfo?> getLastShipmentForProduct(String productId) async {
    final query =
        select(purchaseItems).join([
            innerJoin(
              shipments,
              shipments.id.equalsExp(purchaseItems.purchaseId),
            ),
          ])
          ..where(
            whereBusiness(purchaseItems) &
                purchaseItems.productId.equals(productId),
          )
          ..orderBy([OrderingTerm.desc(shipments.createdAt)])
          ..limit(1);
    final row = await query.getSingleOrNull();
    if (row == null) return null;
    final item = row.readTable(purchaseItems);
    final shipment = row.readTable(shipments);
    return LastShipmentInfo(
      date: shipment.createdAt,
      quantity: item.quantity,
      unitPriceKobo: item.unitPriceKobo,
      totalKobo: item.totalKobo,
    );
  }
}

class LastShipmentInfo {
  final DateTime date;
  final int quantity;
  final int unitPriceKobo;
  final int totalKobo;

  const LastShipmentInfo({
    required this.date,
    required this.quantity,
    required this.unitPriceKobo,
    required this.totalKobo,
  });
}

@DriftAccessor(
  tables: [Expenses, ExpenseCategories, ActivityLogs, PaymentTransactions],
)
class ExpensesDao extends DatabaseAccessor<AppDatabase>
    with _$ExpensesDaoMixin, BusinessScopedDao<AppDatabase> {
  ExpensesDao(super.db);

  Stream<List<ExpenseWithCategory>> watchAll({String? storeId}) {
    final query = select(expenses).join([
      leftOuterJoin(
        expenseCategories,
        expenseCategories.id.equalsExp(expenses.categoryId),
      ),
    ]);

    query.where(whereBusiness(expenses) & expenses.isDeleted.not());
    if (storeId != null) {
      query.where(expenses.storeId.equals(storeId));
    }
    query.orderBy([OrderingTerm.desc(expenses.createdAt)]);

    return query.watch().map((rows) {
      return rows.map((row) {
        return ExpenseWithCategory(
          expense: row.readTable(expenses),
          category: row.readTableOrNull(expenseCategories),
        );
      }).toList();
    });
  }

  Stream<List<ExpenseCategoryData>> watchAllCategories() {
    return (select(expenseCategories)
          ..where((t) => whereBusiness(t) & t.isDeleted.not())
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .watch();
  }

  Future<String> resolveCategoryId(String name) async {
    final normalized = name.trim();

    final existing =
        await (select(expenseCategories)
              ..where((t) => whereBusiness(t) & t.name.equals(normalized))
              ..limit(1))
            .getSingleOrNull();

    if (existing != null) return existing.id;

    final id = UuidV7.generate();
    final catComp = ExpenseCategoriesCompanion.insert(
      id: Value(id),
      businessId: requireBusinessId(),
      name: normalized,
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(expenseCategories).insert(catComp);
    await db.syncDao.enqueueUpsert('expense_categories', catComp);
    return id;
  }

  Future<void> addExpense({
    required String categoryName,
    required int amountKobo,
    required String description,
    String? paymentMethod,
    String? reference,
    String? storeId,
    required String recordedBy,
  }) async {
    final flagValue = await db.systemConfigDao
        .get('feature.domain_rpcs_v2.record_expense');
    final useDomainRpc = flagValue == 'true' || flagValue == '"true"';

    // Match v1's existing behavior: a payment_transactions row is always
    // recorded (defaulting to 'other' when the caller didn't specify a
    // method). Keeps analytics/reporting parity across the flag flip.
    final effectivePaymentMethod = paymentMethod ?? 'other';

    await transaction(() async {
      final categoryId = await resolveCategoryId(categoryName);
      final expenseId = UuidV7.generate();
      final activityLogId = UuidV7.generate();
      final paymentId = UuidV7.generate();

      // 1. Insert Expense locally (UI-immediate).
      final expComp = ExpensesCompanion.insert(
        id: Value(expenseId),
        businessId: requireBusinessId(),
        categoryId: Value(categoryId),
        amountKobo: amountKobo,
        description: description,
        paymentMethod: Value(paymentMethod),
        recordedBy: Value(recordedBy),
        reference: Value(reference),
        storeId: Value(storeId),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await into(expenses).insert(expComp);

      // 2. Insert Activity Log locally (inlined — we need the id for the
      // v2 envelope and ActivityLogDao.log generates ids internally).
      final activityComp = ActivityLogsCompanion.insert(
        id: Value(activityLogId),
        businessId: requireBusinessId(),
        userId: Value(recordedBy),
        action: 'expense_created',
        description: 'Recorded expense: $description ($categoryName)',
        expenseId: Value(expenseId),
        storeId: Value(storeId),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await into(db.activityLogs).insert(activityComp);

      // 3. Insert Payment Transaction locally.
      final payComp = PaymentTransactionsCompanion.insert(
        id: Value(paymentId),
        businessId: requireBusinessId(),
        amountKobo: amountKobo,
        method: effectivePaymentMethod,
        type: 'expense',
        expenseId: Value(expenseId),
        performedBy: Value(recordedBy),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await into(db.paymentTransactions).insert(payComp);

      if (useDomainRpc) {
        final payload = <String, dynamic>{
          'p_business_id': requireBusinessId(),
          'p_actor_id': recordedBy,
          'p_expense_id': expenseId,
          'p_payment_id': paymentId,
          'p_activity_log_id': activityLogId,
          'p_amount_kobo': amountKobo,
          'p_description': description,
          'p_category_id': categoryId,
          'p_payment_method': effectivePaymentMethod,
          if (reference != null) 'p_reference': reference,
          if (storeId != null) 'p_store_id': storeId,
        };
        await db.syncDao
            .enqueue('domain:pos_record_expense', jsonEncode(payload));
      } else {
        await db.syncDao.enqueueUpsert('expenses', expComp);
        await db.syncDao.enqueueUpsert('activity_logs', activityComp);
        await db.syncDao.enqueueUpsert('payment_transactions', payComp);
      }
    });
  }

  Stream<int> watchTotalThisMonth() {
    return db.settingsDao.watchTimezone().switchMap((timezoneName) {
      final location = tz.getLocation(timezoneName);
      final now = tz.TZDateTime.now(location);
      final startOfMonth = tz.TZDateTime(location, now.year, now.month, 1);
      final nextMonth = tz.TZDateTime(location, now.year, now.month + 1, 1);

      final query = selectOnly(expenses)
        ..addColumns([expenses.amountKobo.sum()])
        ..where(
          whereBusiness(expenses) &
              expenses.isDeleted.not() &
              expenses.createdAt.isBiggerOrEqualValue(startOfMonth) &
              expenses.createdAt.isSmallerThanValue(nextMonth),
        );

      return query.watchSingleOrNull().map(
        (row) => row?.read(expenses.amountKobo.sum()) ?? 0,
      );
    });
  }
}

class ExpenseWithCategory {
  final ExpenseData expense;
  final ExpenseCategoryData? category;
  ExpenseWithCategory({required this.expense, this.category});
}

@DriftAccessor(tables: [SyncQueue, SyncQueueOrphans])
class SyncDao extends DatabaseAccessor<AppDatabase>
    with _$SyncDaoMixin, BusinessScopedDao<AppDatabase> {
  SyncDao(super.db);

  Future<List<SyncQueueData>> getPendingItems({
    int limit = 50,
    String? businessId,
  }) {
    // §6.8: rows scheduled for future retry (markFailed sets
    // nextAttemptAt for both regular transient and FK-deferred classes)
    // must be skipped until their window opens. Without this clause the
    // exponential backoff and FK-deferred logic in markFailed are
    // effectively no-ops — every push pass would retry every failed row
    // immediately, hammering the cloud and eating attempts.
    //
    // [businessId] lets callers (push side, sync issues screen) pin the
    // tenant filter explicitly instead of consulting the resolver. Mirrors
    // the bootstrap pattern in [enqueueUpsert] and stays safe across the
    // pre-setCurrentUser window where the resolver returns null.
    final now = DateTime.now();
    final tenantFilter = businessId != null
        ? syncQueue.businessId.equals(businessId)
        : whereBusiness(syncQueue);
    final query = select(syncQueue)
      ..where(
        (t) =>
            t.isSynced.not() &
            t.status.equals('pending') &
            tenantFilter &
            (t.nextAttemptAt.isNull() |
                t.nextAttemptAt.isSmallerOrEqualValue(now)),
      )
      ..orderBy([
        (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.asc),
      ])
      ..limit(limit);

    return query.get();
  }

  Future<void> markInProgress(String id) async {
    await (update(syncQueue)..where((t) => t.id.equals(id))).write(
      const SyncQueueCompanion(status: Value('syncing')),
    );
  }

  /// Bulk variant for batched push: flips a set of queue rows to 'syncing'
  /// in one statement. Empty input is a no-op.
  Future<void> markInProgressBatch(List<String> ids) async {
    if (ids.isEmpty) return;
    await (update(syncQueue)..where((t) => t.id.isIn(ids))).write(
      const SyncQueueCompanion(status: Value('syncing')),
    );
  }

  Future<void> markDone(String id) async {
    await (update(syncQueue)..where((t) => t.id.equals(id))).write(
      const SyncQueueCompanion(
        isSynced: Value(true),
        status: Value('completed'),
        nextAttemptAt: Value(null),
      ),
    );
  }

  /// Bulk variant for batched push: marks a set of queue rows completed in
  /// one statement. Empty input is a no-op.
  Future<void> markDoneBatch(List<String> ids) async {
    if (ids.isEmpty) return;
    await (update(syncQueue)..where((t) => t.id.isIn(ids))).write(
      const SyncQueueCompanion(
        isSynced: Value(true),
        status: Value('completed'),
        nextAttemptAt: Value(null),
      ),
    );
  }

  /// Number of FK-deferred (23503) retries before a row is promoted to
  /// permanent. After this cap the parent is presumed genuinely absent
  /// (not just lagging) and the row goes to orphans for operator review.
  static const _fkDeferredRetryCap = 3;

  Future<void> markFailed(
    String id,
    String error, {
    bool permanent = false,
    bool fkDeferred = false,
  }) async {
    final now = DateTime.now();
    final existing = await (select(
      syncQueue,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (existing == null) return;
    final attempts = existing.attempts + 1;

    // FK-deferred class (PostgreSQL 23503). Parent likely arrives on
    // the next pull, so wait longer between retries; promote to
    // permanent after the cap so a genuinely orphaned child doesn't
    // ride the queue forever.
    final deferredOverflow = fkDeferred && attempts >= _fkDeferredRetryCap;
    final shouldPersistAsPermanent = permanent || deferredOverflow;

    if (shouldPersistAsPermanent) {
      // §6.8 orphan auto-move: lift the row out of sync_queue, archive
      // to sync_queue_orphans (with the original id preserved), and
      // delete the queue row so it stops counting against pending
      // metrics. Operator-visible surface for genuine permanent
      // failures.
      final reason =
          deferredOverflow ? 'fk_deferred_cap_reached: $error' : error;
      debugPrint(
        '[SyncDao] orphan ${existing.actionType} attempts=$attempts '
        'reason=$reason',
      );
      await transaction(() async {
        await into(syncQueueOrphans).insert(
          SyncQueueOrphansCompanion.insert(
            originalId: existing.id,
            actionType: existing.actionType,
            payload: existing.payload,
            reason: reason,
          ),
        );
        await (delete(syncQueue)..where((t) => t.id.equals(id))).go();
      });
      return;
    }

    // Transient retry. FK-deferred uses a 10-minute base so the next
    // pull (typical cadence: minutes) lands in between attempts;
    // regular transients keep the original 30-second base.
    final base = fkDeferred ? 600 : 30;
    final delay = Duration(seconds: (1 << (attempts % 10)) * base);
    final next = now.add(delay);

    debugPrint(
      '[SyncDao] retry ${existing.actionType} attempts=$attempts '
      'next=${next.toIso8601String()}',
    );

    await (update(syncQueue)..where((t) => t.id.equals(id))).write(
      SyncQueueCompanion(
        status: const Value('pending'),
        errorMessage: Value(error),
        attempts: Value(attempts),
        nextAttemptAt: Value(next),
      ),
    );
  }

  Stream<int> watchPendingCount() {
    return (selectOnly(syncQueue)
          ..addColumns([syncQueue.id.count()])
          ..where(syncQueue.isSynced.not() & whereBusiness(syncQueue)))
        .watchSingle()
        .map((row) => row.read(syncQueue.id.count()) ?? 0);
  }

  Future<void> resetStuckInProgress() async {
    // Items stuck in 'syncing' for more than 5 minutes are reset to 'pending'
    final fiveMinsAgo = DateTime.now().subtract(const Duration(minutes: 5));
    await (update(syncQueue)..where(
          (t) =>
              t.status.equals('syncing') &
              t.createdAt.isSmallerThanValue(fiveMinsAgo) &
              whereBusiness(t),
        ))
        .write(const SyncQueueCompanion(status: Value('pending')));
  }

  Future<void> clearFailureBackoff() async {
    await (update(syncQueue)
          ..where((t) => t.status.equals('pending') & whereBusiness(t)))
        .write(const SyncQueueCompanion(nextAttemptAt: Value(null)));
  }

  Future<List<SyncQueueData>> getFailedItems({int limit = 50}) {
    return (select(syncQueue)
          ..where((t) => t.status.equals('failed') & whereBusiness(t))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(limit))
        .get();
  }

  Stream<List<SyncQueueData>> watchFailedItems({int limit = 100}) {
    return (select(syncQueue)
          ..where((t) => t.status.equals('failed') & whereBusiness(t))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(limit))
        .watch();
  }

  /// Every row in transient-retry / never-pushed state, oldest first. The
  /// `markFailed` state machine keeps every transiently-failed row at
  /// `status='pending'` with a future `nextAttemptAt` — `'failed'` itself
  /// is unused by the current code paths. Without this surface, a row
  /// that has retried for hours looks identical to one enqueued a second
  /// ago, and the only signal is the bare "Pending in queue: N" counter.
  Stream<List<SyncQueueData>> watchPendingItems({int limit = 100}) {
    return (select(syncQueue)
          ..where((t) =>
              t.status.equals('pending') &
              t.isSynced.not() &
              whereBusiness(t))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)])
          ..limit(limit))
        .watch();
  }

  Stream<int> watchFailedCount() {
    return (selectOnly(syncQueue)
          ..addColumns([syncQueue.id.count()])
          ..where(syncQueue.status.equals('failed') & whereBusiness(syncQueue)))
        .watchSingle()
        .map((row) => row.read(syncQueue.id.count()) ?? 0);
  }

  Future<void> clearFailureBackoffById(String id) async {
    await (update(syncQueue)..where((t) => t.id.equals(id))).write(
      const SyncQueueCompanion(
        nextAttemptAt: Value(null),
        status: Value('pending'),
      ),
    );
  }

  Future<void> discardQueueItem(String id) async {
    await (delete(syncQueue)..where((t) => t.id.equals(id))).go();
  }

  Future<void> purgeOldDoneItems() async {
    final sevenDaysAgo = DateTime.now().subtract(const Duration(days: 7));
    await (delete(syncQueue)..where(
          (t) =>
              t.isSynced.equals(true) &
              t.createdAt.isSmallerThanValue(sevenDaysAgo),
        ))
        .go();
  }

  Future<void> enqueue(String actionType, String payload) async {
    await into(syncQueue).insert(
      SyncQueueCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: requireBusinessId(),
        actionType: actionType,
        payload: payload,
        // Stamp auth.uid() at enqueue time so dispatch can reject the row
        // after an account switch. Null when the SDK has no session yet
        // (bootstrap) — dispatch treats null as "trust the current user".
        authUserId: Value(db.currentAuthUserId),
      ),
    );
  }

  /// Looks up an existing pending sync_queue row for `(actionType, rowId)`
  /// using the partial unique index `idx_sync_queue_dedup_pending`. Returns
  /// the row id of the match, or null. Domain envelopes (action_type
  /// 'domain:%') are exempt from coalescing — each is an independent
  /// atomic call — so callers must skip this lookup for them.
  Future<String?> _findPendingDuplicateId(
    String actionType,
    String rowId,
  ) async {
    final result = await customSelect(
      "SELECT id FROM sync_queue "
      "WHERE action_type = ?1 AND status = 'pending' "
      "  AND json_extract(payload, '\$.id') = ?2 "
      "LIMIT 1",
      variables: [
        Variable.withString(actionType),
        Variable.withString(rowId),
      ],
      readsFrom: {syncQueue},
    ).getSingleOrNull();
    return result?.read<String>('id');
  }

  /// Finds a pending domain envelope by extracting an arbitrary JSON path
  /// from the payload. Used by the checkout flow to locate the freshly
  /// enqueued `domain:pos_record_sale` row matching a specific orderId
  /// (the order id lives at `$.p_order.id`, not at the top-level `id`,
  /// so the dedup lookup above doesn't match).
  Future<SyncQueueData?> findPendingDomainItem(
    String actionType, {
    required String payloadIdPath,
    required String idValue,
  }) async {
    final bid = db.businessIdResolver.call();
    if (bid == null) return null;
    final result = await customSelect(
      "SELECT id FROM sync_queue "
      "WHERE action_type = ?1 AND status = 'pending' "
      "  AND business_id = ?2 "
      "  AND json_extract(payload, ?3) = ?4 "
      "LIMIT 1",
      variables: [
        Variable.withString(actionType),
        Variable.withString(bid),
        Variable.withString(payloadIdPath),
        Variable.withString(idValue),
      ],
      readsFrom: {syncQueue},
    ).getSingleOrNull();
    if (result == null) return null;
    return getQueueItem(result.read<String>('id'));
  }

  Future<SyncQueueData?> getQueueItem(String id) {
    return (select(syncQueue)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// Looks up a row in `sync_queue_orphans` by its ORIGINAL queue id —
  /// what callers stored before §6.8's auto-archive moved permanent
  /// failures out of `sync_queue`. Used by `flushSale` to surface a
  /// terminal failure to the foreground checkout flow even though
  /// `getQueueItem` would now return null.
  Future<SyncQueueOrphanData?> findOrphanByOriginalId(String originalId) {
    return (select(syncQueueOrphans)
          ..where((t) => t.originalId.equals(originalId)))
        .getSingleOrNull();
  }

  // ── Orphan surfacing & recovery ────────────────────────────────────────────
  // §6.8 auto-moves permanent failures (P0001, FK-deferred cap) out of
  // sync_queue into sync_queue_orphans and deletes from the queue. The result
  // is invisible to the failed-items list and to watchPendingCount, so the
  // user sees a "Push/RLS gap" in the row-count audit with no corresponding
  // row to inspect or retry. The methods below give the Sync Issues screen a
  // way to list, retry, and discard those rows.

  Stream<List<SyncQueueOrphanData>> watchOrphans({int limit = 200}) {
    return (select(syncQueueOrphans)
          ..orderBy([(t) => OrderingTerm.desc(t.movedAt)])
          ..limit(limit))
        .watch();
  }

  Stream<int> watchOrphanCount() {
    return (selectOnly(syncQueueOrphans)
          ..addColumns([syncQueueOrphans.id.count()]))
        .watchSingle()
        .map((row) => row.read(syncQueueOrphans.id.count()) ?? 0);
  }

  /// Re-enqueues an orphan into sync_queue with cleared backoff and removes
  /// it from the orphans table. The original action_type and payload are
  /// preserved verbatim. Caller must ensure the underlying cause has been
  /// addressed — a blind retry of a phantom-conflict on an append-only
  /// ledger will just orphan it again.
  Future<void> retryOrphan(String orphanId) async {
    await transaction(() async {
      final orphan = await (select(syncQueueOrphans)
            ..where((t) => t.id.equals(orphanId)))
          .getSingleOrNull();
      if (orphan == null) return;

      // sync_queue_orphans has no business_id column; recover it from the
      // payload. For table upserts the JSON has `business_id`; for domain
      // envelopes it sits at `p_business_id`. Fall back to the session
      // resolver only if neither is present (legacy orphans).
      String? bid;
      try {
        final decoded = jsonDecode(orphan.payload) as Map<String, dynamic>;
        bid = decoded['business_id'] as String? ??
            decoded['p_business_id'] as String?;
      } catch (_) {
        // undecodable payload — fall through to resolver
      }
      bid ??= db.businessIdResolver.call();
      if (bid == null) {
        throw StateError(
          'cannot retry orphan ${orphan.id}: no business_id in payload and '
          'no current session',
        );
      }

      await into(syncQueue).insert(
        SyncQueueCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: bid,
          actionType: orphan.actionType,
          payload: orphan.payload,
          // Retry re-tags to whoever is signed in now. The orphans table
          // does not carry an auth_user_id (orphans pre-date L5), and the
          // user pressing Retry on the Sync Issues screen is explicitly
          // taking ownership of the push.
          authUserId: Value(db.currentAuthUserId),
        ),
      );
      await (delete(syncQueueOrphans)..where((t) => t.id.equals(orphanId))).go();
    });
  }

  Future<void> discardOrphan(String orphanId) async {
    await (delete(syncQueueOrphans)..where((t) => t.id.equals(orphanId))).go();
  }

  Future<void> enqueueUpsert(String tableName, Insertable row) async {
    final payloadMap = serializeInsertable(row);
    // Resolve the queue row's businessId. Prefer the payload's value — it
    // covers the bootstrap case where the very first business/user is being
    // created during onboarding and the session resolver isn't bound yet
    // (the row being enqueued already carries its own tenant). Fall back to
    // the session resolver for normal post-login writes. If neither yields
    // a value there's no tenant context at all; refuse to enqueue rather
    // than insert a poison row that push would later reject.
    final resolvedBid = (payloadMap['business_id'] as String?) ??
        db.businessIdResolver.call();
    if (resolvedBid == null) {
      throw StateError(
        'enqueueUpsert($tableName): no business_id in payload and no '
        'authenticated session — refusing to enqueue without tenant context.',
      );
    }
    final bid = resolvedBid;
    payloadMap['business_id'] ??= bid;

    final actionType = '$tableName:upsert';
    final payloadJson = jsonEncode(payloadMap);
    final rowId = payloadMap['id'];

    // Without an id we can't coalesce safely — fall back to plain insert.
    if (rowId is! String) {
      await enqueue(actionType, payloadJson);
      return;
    }

    // Coalesce: a burst of writes to the same row only needs the *latest*
    // payload. Earlier pending entries are stale and must not produce
    // separate outbox rows. The partial unique index guarantees at most
    // one pending row per (action_type, payload.id); the transaction here
    // makes the SELECT-then-INSERT atomic against concurrent enqueues from
    // the same isolate (Drift serializes writes on a single connection).
    await transaction(() async {
      final existingId = await _findPendingDuplicateId(actionType, rowId);
      if (existingId != null) {
        // Refresh the auth tag too: a coalesced row carries the new
        // payload's intent, so it should be tagged with whoever is
        // signed in now. If user A enqueued an upsert, logged out, and
        // user B then edits the same row, the coalesced row pushes
        // under user B (the JWT that will sign the request anyway).
        await (update(syncQueue)..where((t) => t.id.equals(existingId)))
            .write(SyncQueueCompanion(
          payload: Value(payloadJson),
          createdAt: Value(DateTime.now()),
          attempts: const Value(0),
          nextAttemptAt: const Value(null),
          errorMessage: const Value(null),
          authUserId: Value(db.currentAuthUserId),
        ));
      } else {
        await into(syncQueue).insert(
          SyncQueueCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: bid,
            actionType: actionType,
            payload: payloadJson,
            authUserId: Value(db.currentAuthUserId),
          ),
        );
      }
    });
  }

  /// Append-only ledger tables — the cloud's `forbid_delete` trigger
  /// raises P0001 on DELETE for any of these, and the corresponding row
  /// would be permanently stuck in `failed` status. Voids must go
  /// through the dedicated DAO methods that append a compensating row.
  static const _ledgerTables = {
    'wallet_transactions',
    'stock_transactions',
    'payment_transactions',
    'activity_logs',
    'crate_ledger',
  };

  Future<void> enqueueDelete(String tableName, String rowId) async {
    if (_ledgerTables.contains(tableName)) {
      throw StateError(
        'enqueueDelete is forbidden for append-only ledger table '
        '"$tableName". Append a compensating/void row through the '
        'corresponding DAO instead (e.g. WalletTransactionsDao.voidTransaction).',
      );
    }
    final payloadMap = {
      'id': rowId,
      'is_deleted': true,
      'last_updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    // Mirror enqueueUpsert's resolution: payload first, resolver second,
    // throw if neither. Delete is always for an existing row, so the
    // resolver should normally have a session — but the same defensive
    // ordering keeps the two methods symmetric and supports future
    // bootstrap-time deletes if any arise.
    final resolvedBid = db.businessIdResolver.call();
    if (resolvedBid == null) {
      throw StateError(
        'enqueueDelete($tableName): no authenticated session — refusing '
        'to enqueue without tenant context.',
      );
    }
    final bid = resolvedBid;
    payloadMap['business_id'] = bid;
    final upsertActionType = '$tableName:upsert';
    final deleteActionType = '$tableName:delete';
    final payloadJson = jsonEncode(payloadMap);

    // A delete supersedes any pending upsert for the same row — pushing the
    // upsert first would race against the delete and leave the cloud row
    // in an inconsistent state. Mark any pending upsert as completed (so it
    // doesn't push), then coalesce against an existing pending delete.
    await transaction(() async {
      final pendingUpsertId =
          await _findPendingDuplicateId(upsertActionType, rowId);
      if (pendingUpsertId != null) {
        await (update(syncQueue)..where((t) => t.id.equals(pendingUpsertId)))
            .write(const SyncQueueCompanion(
          isSynced: Value(true),
          status: Value('completed'),
          nextAttemptAt: Value(null),
        ));
      }

      final existingDeleteId =
          await _findPendingDuplicateId(deleteActionType, rowId);
      if (existingDeleteId != null) {
        // Coalesced delete retags to current user — same rationale as
        // the upsert coalesce branch above.
        await (update(syncQueue)..where((t) => t.id.equals(existingDeleteId)))
            .write(SyncQueueCompanion(
          payload: Value(payloadJson),
          createdAt: Value(DateTime.now()),
          attempts: const Value(0),
          nextAttemptAt: const Value(null),
          errorMessage: const Value(null),
          authUserId: Value(db.currentAuthUserId),
        ));
      } else {
        await into(syncQueue).insert(
          SyncQueueCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: bid,
            actionType: deleteActionType,
            payload: payloadJson,
            authUserId: Value(db.currentAuthUserId),
          ),
        );
      }
    });
  }

  /// Deletes pending queue items that have already been attempted at least
  /// once (i.e. items the engine has tried to push and failed on). Untried
  /// items (`attempts == 0`) are preserved so a fresh enqueue racing with
  /// the purge isn't lost. Returns the number of rows deleted.
  ///
  /// Used as a one-shot remediation when a serialization bug bakes a bad
  /// payload into the queue — fixing the bug doesn't repair existing rows
  /// because the payload is frozen at enqueue time.
  Future<int> purgeAttemptedPending() async {
    return (delete(syncQueue)
          ..where((t) =>
              t.status.equals('pending') & t.attempts.isBiggerThanValue(0)))
        .go();
  }
}

@DriftAccessor(tables: [ActivityLogs])
class ActivityLogDao extends DatabaseAccessor<AppDatabase>
    with _$ActivityLogDaoMixin, BusinessScopedDao<AppDatabase> {
  ActivityLogDao(super.db);

  Future<void> log({
    required String action,
    required String description,
    String? staffId,
    String? storeId,
    String? orderId,
    String? productId,
    String? customerId,
    String? expenseId,
    String? deliveryId,
    String? walletTxnId,
  }) async {
    final id = UuidV7.generate();
    final row = ActivityLogsCompanion.insert(
      id: Value(id),
      businessId: requireBusinessId(),
      userId: Value(staffId),
      action: action,
      description: description,
      orderId: Value(orderId),
      productId: Value(productId),
      customerId: Value(customerId),
      expenseId: Value(expenseId),
      deliveryId: Value(deliveryId),
      walletTxnId: Value(walletTxnId),
      storeId: Value(storeId),
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(activityLogs).insert(row);
    await db.syncDao.enqueueUpsert('activity_logs', row);
  }

  Stream<List<ActivityLogData>> watchRecent({int limit = 100}) {
    return (select(activityLogs)
          ..where((t) => whereBusiness(t) & t.voidedAt.isNull())
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ])
          ..limit(limit))
        .watch();
  }

  Future<List<ActivityLogData>> getForOrder(String orderId) {
    return (select(activityLogs)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.orderId.equals(orderId) &
                t.voidedAt.isNull(),
          )
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ]))
        .get();
  }

  Future<List<ActivityLogData>> getForProduct(String productId) {
    return (select(activityLogs)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.productId.equals(productId) &
                t.voidedAt.isNull(),
          )
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ]))
        .get();
  }

  Future<List<ActivityLogData>> getForCustomer(String customerId) {
    return (select(activityLogs)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.customerId.equals(customerId) &
                t.voidedAt.isNull(),
          )
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ]))
        .get();
  }

  Future<List<ActivityLogData>> getForExpense(String expenseId) {
    return (select(activityLogs)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.expenseId.equals(expenseId) &
                t.voidedAt.isNull(),
          )
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ]))
        .get();
  }

  Future<List<ActivityLogData>> getForDelivery(String deliveryId) {
    return (select(activityLogs)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.deliveryId.equals(deliveryId) &
                t.voidedAt.isNull(),
          )
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ]))
        .get();
  }

  Future<List<ActivityLogData>> getForWalletTxn(String walletTxnId) {
    return (select(activityLogs)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.walletTxnId.equals(walletTxnId) &
                t.voidedAt.isNull(),
          )
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ]))
        .get();
  }

  Future<List<ActivityLogData>> getStockCountLogs() {
    return (select(activityLogs)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.action.equals('stock_count') &
                t.voidedAt.isNull(),
          )
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ]))
        .get();
  }
}

@DriftAccessor(tables: [Users, Stores])
class StoresDao extends DatabaseAccessor<AppDatabase>
    with _$StoresDaoMixin, BusinessScopedDao<AppDatabase> {
  StoresDao(super.db);

  /// Active (non-deleted) stores for the current business, ordered by name.
  /// Drives store pickers and the Stores screen.
  Stream<List<StoreData>> watchActiveStores() {
    return (select(stores)
          ..where((t) => whereBusiness(t) & t.isDeleted.not())
          ..orderBy([(t) => OrderingTerm(expression: t.name)]))
        .watch();
  }

  /// One-shot business-scoped variant of [watchActiveStores]. Use this for
  /// store pickers that read once (initState / load) so a device holding more
  /// than one business's data can't surface — and FK-reference — another
  /// business's store.
  Future<List<StoreData>> getActiveStores() {
    return (select(stores)
          ..where((t) => whereBusiness(t) & t.isDeleted.not())
          ..orderBy([(t) => OrderingTerm(expression: t.name)]))
        .get();
  }

  Stream<StoreData?> watchStore(String id) {
    return (select(
      stores,
    )..where((t) => t.id.equals(id) & whereBusiness(t))).watchSingleOrNull();
  }

  Future<StoreData?> getStore(String id) {
    return (select(
      stores,
    )..where((t) => t.id.equals(id) & whereBusiness(t))).getSingleOrNull();
  }

  Future<UserData?> getUserById(String id) {
    // deliberately not businessId-scoped
    return (select(users)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  Future<UserData?> getUserByEmail(String email, {String? preferredBusinessId}) async {
    // Deliberately NOT businessId-scoped — login happens before a session
    // exists. Users has UNIQUE(business_id, email), so a single email can hold
    // one local row PER business (multi-business account / staff re-invite).
    // Tolerate >1 row instead of crashing (getSingleOrNull throws on multi-row,
    // which would kill the sign-in / upsertLocalUserFromProfile rebuild): prefer
    // the row for the active/cloud business, else the most-recently-updated.
    final rows =
        await (select(users)..where((t) => t.email.equals(email))).get();
    if (rows.isEmpty) return null;
    if (rows.length == 1) return rows.first;
    if (preferredBusinessId != null) {
      for (final r in rows) {
        if (r.businessId == preferredBusinessId) return r;
      }
    }
    rows.sort((a, b) => b.lastUpdatedAt.compareTo(a.lastUpdatedAt));
    return rows.first;
  }
}

@DriftAccessor(tables: [Notifications])
class NotificationsDao extends DatabaseAccessor<AppDatabase>
    with _$NotificationsDaoMixin, BusinessScopedDao<AppDatabase> {
  NotificationsDao(super.db);

  /// Recipient-scope filter: a row is visible to the current user when
  /// `recipient_user_id` is NULL (broadcast) OR equals the current user's
  /// id. If no user is resolved (logged out), only broadcasts surface —
  /// safer default than leaking targeted rows.
  Expression<bool> _whereForCurrentUser($NotificationsTable t) {
    final uid = currentUserId;
    if (uid == null) return t.recipientUserId.isNull();
    return t.recipientUserId.isNull() | t.recipientUserId.equals(uid);
  }

  Future<void> create(
    String type,
    String message, {
    String? linkedRecordId,
    String? recipientUserId,
  }) async {
    final id = UuidV7.generate();
    final row = NotificationsCompanion.insert(
      id: Value(id),
      businessId: requireBusinessId(),
      type: type,
      message: message,
      linkedRecordId: Value(linkedRecordId),
      recipientUserId: Value(recipientUserId),
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(notifications).insert(row);
    await db.syncDao.enqueueUpsert('notifications', row);
  }

  Stream<List<NotificationData>> watchAll() {
    return (select(notifications)
          ..where((t) => whereBusiness(t) & _whereForCurrentUser(t))
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  Stream<int> watchUnreadCount() {
    final count = notifications.id.count();
    return (selectOnly(notifications)
          ..addColumns([count])
          ..where(
            whereBusiness(notifications) &
                _whereForCurrentUser(notifications) &
                notifications.isRead.equals(false),
          ))
        .watchSingle()
        .map((row) => row.read(count) ?? 0);
  }

  Future<void> markRead(String id) async {
    final now = DateTime.now();
    final comp = NotificationsCompanion(
      id: Value(id),
      isRead: const Value(true),
      lastUpdatedAt: Value(now),
    );
    // Recipient guard prevents marking-read on another user's targeted row
    // (e.g. a staff dismissing a notification scoped to the CEO).
    await (update(notifications)..where(
          (t) => t.id.equals(id) & whereBusiness(t) & _whereForCurrentUser(t),
        ))
        .write(comp);
    // Full-row enqueue: a partial notifications upsert omits NOT NULL type/message.
    final row = await (select(notifications)
          ..where((t) => t.id.equals(id) & whereBusiness(t)))
        .getSingleOrNull();
    if (row != null) {
      await db.syncDao.enqueueUpsert('notifications', row.toCompanion(true));
    }
  }

  Future<void> markAllRead() async {
    final now = DateTime.now();
    final unread = await (select(notifications)..where(
          (t) =>
              whereBusiness(t) &
              _whereForCurrentUser(t) &
              t.isRead.equals(false),
        ))
        .get();
    if (unread.isEmpty) return;

    await (update(notifications)..where(
          (t) => whereBusiness(t) & _whereForCurrentUser(t),
        ))
        .write(
          NotificationsCompanion(
            isRead: const Value(true),
            lastUpdatedAt: Value(now),
          ),
        );

    for (final notif in unread) {
      // Full row (with the read flag applied) so the cloud upsert's INSERT has
      // the NOT NULL type/message columns; a partial upsert would 23502.
      await db.syncDao.enqueueUpsert(
        'notifications',
        notif.toCompanion(true).copyWith(
              isRead: const Value(true),
              lastUpdatedAt: Value(now),
            ),
      );
    }
  }

  Future<void> deleteSingle(String id) async {
    await (delete(notifications)..where(
          (t) => t.id.equals(id) & whereBusiness(t) & _whereForCurrentUser(t),
        ))
        .go();
    await db.syncDao.enqueueDelete('notifications', id);
  }

  Future<void> clearAll() async {
    final allNotifs = await (select(notifications)..where(
          (t) => whereBusiness(t) & _whereForCurrentUser(t),
        ))
        .get();
    await (delete(notifications)..where(
          (t) => whereBusiness(t) & _whereForCurrentUser(t),
        ))
        .go();
    for (final n in allNotifs) {
      await db.syncDao.enqueueDelete('notifications', n.id);
    }
  }
}

@DriftAccessor(
  tables: [StockTransactions, Products, Users, Stores, Inventory],
)
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

  // ── Filtered queries with joined product/user/store names ──────────

  JoinedSelectStatement<HasResultSet, dynamic> _buildFilteredQuery({
    String? storeId,
    DateTime? startDate,
    DateTime? endDate,
    String? movementType,
  }) {
    final query = select(stockTransactions).join([
      innerJoin(products, products.id.equalsExp(stockTransactions.productId)),
      innerJoin(users, users.id.equalsExp(stockTransactions.performedBy)),
      leftOuterJoin(
        stores,
        stores.id.equalsExp(stockTransactions.locationId),
      ),
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
    query.orderBy([OrderingTerm.desc(stockTransactions.createdAt)]);
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
    final invRows =
        await (select(inventory)..where(
              (i) => whereBusiness(i) & i.storeId.equals(storeId),
            ))
            .get();
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
  // Transfer flows have no UI callers today; methods will land alongside the
  // transfer screens. Keeping the shell preserves the AppDatabase accessor
  // registration so adding methods later doesn't require schema regen.
}

@DriftAccessor(tables: [PendingCrateReturns])
class PendingCrateReturnsDao extends DatabaseAccessor<AppDatabase>
    with _$PendingCrateReturnsDaoMixin, BusinessScopedDao<AppDatabase> {
  PendingCrateReturnsDao(super.db);

  Future<String> createPendingReturn({
    required String? orderId,
    required String customerId,
    required String submittedBy,
    required String crateSizeGroupId,
    required int quantity,
  }) async {
    final id = UuidV7.generate();
    final row = PendingCrateReturnsCompanion.insert(
      id: Value(id),
      businessId: requireBusinessId(),
      orderId: Value(orderId),
      customerId: customerId,
      crateSizeGroupId: crateSizeGroupId,
      quantity: quantity,
      submittedBy: submittedBy,
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(pendingCrateReturns).insert(row);
    await db.syncDao.enqueueUpsert('pending_crate_returns', row);
    return id;
  }

  Future<PendingCrateReturnData?> getById(String id) {
    return (select(pendingCrateReturns)
          ..where((t) => t.id.equals(id) & whereBusiness(t))
          ..limit(1))
        .getSingleOrNull();
  }

  Future<void> updateStatus(String id, String newStatus) async {
    final now = DateTime.now();
    final comp = PendingCrateReturnsCompanion(
      id: Value(id),
      status: Value(newStatus),
      lastUpdatedAt: Value(now),
    );
    await (update(
      pendingCrateReturns,
    )..where((t) => t.id.equals(id) & whereBusiness(t))).write(comp);
    // Full-row enqueue: a partial pending_crate_returns upsert omits NOT NULL
    // customer_id / crate_size_group_id / quantity / submitted_by.
    final row = await (select(pendingCrateReturns)
          ..where((t) => t.id.equals(id) & whereBusiness(t)))
        .getSingleOrNull();
    if (row != null) {
      await db.syncDao
          .enqueueUpsert('pending_crate_returns', row.toCompanion(true));
    }
  }
}

extension CustomerDataExtension on CustomerData {
  String get addressText => address ?? 'N/A';
}

@DriftAccessor(tables: [Sessions])
class SessionsDao extends DatabaseAccessor<AppDatabase>
    with _$SessionsDaoMixin, BusinessScopedDao<AppDatabase> {
  SessionsDao(super.db);

  Future<String> createSession({
    required String userId,
    required Duration ttl,
    String? userAgent,
    String? ipAddress,
    String? deviceId,
  }) async {
    final businessId = requireBusinessId();
    final id = UuidV7.generate();
    final row = SessionsCompanion.insert(
      id: Value(id),
      businessId: businessId,
      userId: userId,
      expiresAt: DateTime.now().add(ttl),
      userAgent: Value(userAgent),
      ipAddress: Value(ipAddress),
      deviceId: Value(deviceId),
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(sessions).insert(row);
    await db.syncDao.enqueueUpsert('sessions', row);
    return id;
  }

  Future<void> revokeSession(String sessionId) async {
    final now = DateTime.now();
    final comp = SessionsCompanion(
      id: Value(sessionId),
      revokedAt: Value(now),
      lastUpdatedAt: Value(now),
    );
    await (update(
      sessions,
    )..where((t) => t.id.equals(sessionId) & whereBusiness(t))).write(comp);
    // Full-row enqueue: a partial sessions upsert omits NOT NULL user_id/expires_at.
    final row = await (select(sessions)
          ..where((t) => t.id.equals(sessionId) & whereBusiness(t)))
        .getSingleOrNull();
    if (row != null) {
      await db.syncDao.enqueueUpsert('sessions', row.toCompanion(true));
    }
  }

  Future<void> revokeAllSessionsForUser(String userId) async {
    final now = DateTime.now();
    final active =
        await (select(sessions)..where(
              (t) =>
                  t.userId.equals(userId) &
                  whereBusiness(t) &
                  t.revokedAt.isNull() &
                  t.expiresAt.isBiggerThanValue(now),
            ))
            .get();
    if (active.isEmpty) return;

    await (update(sessions)..where(
          (t) =>
              t.userId.equals(userId) &
              whereBusiness(t) &
              t.revokedAt.isNull() &
              t.expiresAt.isBiggerThanValue(now),
        ))
        .write(
          SessionsCompanion(revokedAt: Value(now), lastUpdatedAt: Value(now)),
        );

    for (final s in active) {
      await db.syncDao.enqueueUpsert(
        'sessions',
        s.toCompanion(true).copyWith(
              revokedAt: Value(now),
              lastUpdatedAt: Value(now),
            ),
      );
    }
  }

  Future<SessionData?> findActiveSession(String sessionId) async {
    final now = DateTime.now();
    return (select(sessions)
          ..where(
            (t) =>
                t.id.equals(sessionId) &
                whereBusiness(t) &
                t.revokedAt.isNull() &
                t.expiresAt.isBiggerThanValue(now),
          )
          ..limit(1))
        .getSingleOrNull();
  }
}

@DriftAccessor(tables: [CustomerWallets])
class CustomerWalletsDao extends DatabaseAccessor<AppDatabase>
    with _$CustomerWalletsDaoMixin, BusinessScopedDao<AppDatabase> {
  CustomerWalletsDao(super.db);

  Future<CustomerWalletData?> getByCustomerId(String customerId) {
    return (select(customerWallets)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.customerId.equals(customerId) &
                t.isDeleted.not(),
          )
          ..limit(1))
        .getSingleOrNull();
  }

  Future<void> updateWalletLimit(String customerId, int limitKobo) async {
    final now = DateTime.now();
    final comp = CustomersCompanion(
      id: Value(customerId),
      walletLimitKobo: Value(limitKobo),
      lastUpdatedAt: Value(now),
    );
    await (update(
      attachedDatabase.customers,
    )..where((t) => t.id.equals(customerId) & whereBusiness(t))).write(comp);
    // Full-row enqueue: a partial customers upsert omits the NOT NULL name.
    final row = await (attachedDatabase.select(attachedDatabase.customers)
          ..where((t) => t.id.equals(customerId) & whereBusiness(t)))
        .getSingleOrNull();
    if (row != null) {
      await db.syncDao.enqueueUpsert('customers', row.toCompanion(true));
    }
  }
}

@DriftAccessor(
  tables: [WalletTransactions, CustomerWallets, PaymentTransactions, Orders],
)
class WalletTransactionsDao extends DatabaseAccessor<AppDatabase>
    with _$WalletTransactionsDaoMixin, BusinessScopedDao<AppDatabase> {
  WalletTransactionsDao(super.db);

  /// Computes the current wallet balance by summing all signed amounts.
  /// Per PR 4d "Recommended void approach", we don't filter by voidedAt IS NULL
  /// because a compensating entry (opposite sign) will have been appended.
  Future<int> getBalanceKobo(String customerId) async {
    final sumExpr = walletTransactions.signedAmountKobo.sum();
    final query = selectOnly(walletTransactions)
      ..addColumns([sumExpr])
      ..where(
        whereBusiness(walletTransactions) &
            walletTransactions.customerId.equals(customerId),
      );
    final row = await query.getSingleOrNull();
    return row?.read(sumExpr) ?? 0;
  }

  Stream<int> watchBalanceKobo(String customerId) {
    final sumExpr = walletTransactions.signedAmountKobo.sum();
    final query = selectOnly(walletTransactions)
      ..addColumns([sumExpr])
      ..where(
        whereBusiness(walletTransactions) &
            walletTransactions.customerId.equals(customerId),
      );
    return query.watchSingleOrNull().map((row) => row?.read(sumExpr) ?? 0);
  }

  Stream<Map<String, int>> watchAllBalancesKobo() {
    final sumExpr = walletTransactions.signedAmountKobo.sum();
    final query = selectOnly(walletTransactions)
      ..addColumns([walletTransactions.customerId, sumExpr])
      ..where(whereBusiness(walletTransactions))
      ..groupBy([walletTransactions.customerId]);
    return query.watch().map((rows) {
      final out = <String, int>{};
      for (final r in rows) {
        final cid = r.read(walletTransactions.customerId);
        final sum = r.read(sumExpr);
        if (cid != null) out[cid] = sum ?? 0;
      }
      return out;
    });
  }

  Stream<List<WalletTransactionData>> watchHistory(String customerId) {
    return (select(walletTransactions)
          ..where((t) => whereBusiness(t) & t.customerId.equals(customerId))
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  /// Voids a transaction by marking the original as voided AND appending
  /// a compensating entry with the opposite sign.
  Future<void> voidTransaction({
    required String transactionId,
    required String voidedBy,
    required String reason,
  }) async {
    final flagValue =
        await db.systemConfigDao.get('feature.domain_rpcs_v2.void_wallet_txn');
    final useDomainRpc = flagValue == 'true' || flagValue == '"true"';

    await transaction(() async {
      final original =
          await (select(walletTransactions)
                ..where((t) => t.id.equals(transactionId))
                ..limit(1))
              .getSingleOrNull();

      if (original == null) return;
      if (original.voidedAt != null) return; // Already voided

      // 1. Mark original as voided
      final now = DateTime.now();
      await (update(
        walletTransactions,
      )..where((t) => t.id.equals(transactionId))).write(
        WalletTransactionsCompanion(
          voidedAt: Value(now),
          voidedBy: Value(voidedBy),
          voidReason: Value(reason),
          lastUpdatedAt: Value(now),
        ),
      );

      // 2. Append compensating entry
      final compId = UuidV7.generate();
      final compComp = WalletTransactionsCompanion.insert(
        id: Value(compId),
        businessId: requireBusinessId(),
        walletId: original.walletId,
        customerId: original.customerId,
        type: original.type == 'credit' ? 'debit' : 'credit',
        amountKobo: original.amountKobo,
        signedAmountKobo: -original.signedAmountKobo,
        referenceType: 'void',
        orderId: Value(original.orderId), // Link to same order if applicable
        performedBy: Value(voidedBy),
        createdAt: Value(now),
        lastUpdatedAt: Value(now),
      );
      await into(walletTransactions).insert(compComp);

      if (useDomainRpc) {
        final payload = <String, dynamic>{
          'p_business_id': requireBusinessId(),
          'p_actor_id': voidedBy,
          'p_original_id': transactionId,
          'p_compensating_id': compId,
          'p_void_reason': reason,
        };
        await db.syncDao
            .enqueue('domain:pos_void_wallet_txn', jsonEncode(payload));
      } else {
        final updatedOrig = await (select(walletTransactions)
              ..where((t) => t.id.equals(transactionId))
              ..limit(1))
            .getSingle();
        await db.syncDao.enqueueUpsert('wallet_transactions', updatedOrig);
        await db.syncDao.enqueueUpsert('wallet_transactions', compComp);
      }
    });
  }
}

@DriftAccessor(tables: [CrateSizeGroups])
class CrateSizeGroupsDao extends DatabaseAccessor<AppDatabase>
    with _$CrateSizeGroupsDaoMixin, BusinessScopedDao<AppDatabase> {
  CrateSizeGroupsDao(super.db);

  Stream<List<CrateSizeGroupData>> watchAll() {
    return (select(crateSizeGroups)
          ..where((t) => whereBusiness(t) & t.isDeleted.not())
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .watch();
  }

  Future<List<CrateSizeGroupData>> getAll() {
    return (select(crateSizeGroups)
          ..where((t) => whereBusiness(t) & t.isDeleted.not())
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .get();
  }
}

@DriftAccessor(tables: [CustomerCrateBalances, CrateSizeGroups])
class CustomerCrateBalancesDao extends DatabaseAccessor<AppDatabase>
    with _$CustomerCrateBalancesDaoMixin, BusinessScopedDao<AppDatabase> {
  CustomerCrateBalancesDao(super.db);

  Stream<List<CustomerCrateBalanceWithGroup>> watchByCustomer(
    String customerId,
  ) {
    final query = select(customerCrateBalances).join([
      innerJoin(
        crateSizeGroups,
        crateSizeGroups.id.equalsExp(customerCrateBalances.crateSizeGroupId),
      ),
    ]);
    query.where(
      whereBusiness(customerCrateBalances) &
          customerCrateBalances.customerId.equals(customerId),
    );

    return query.watch().map((rows) {
      return rows.map((row) {
        return CustomerCrateBalanceWithGroup(
          balance: row.readTable(customerCrateBalances),
          group: row.readTable(crateSizeGroups),
        );
      }).toList();
    });
  }
}

class CustomerCrateBalanceWithGroup {
  final CustomerCrateBalance balance;
  final CrateSizeGroupData group;
  CustomerCrateBalanceWithGroup({required this.balance, required this.group});
}

// ── Funds Register DAOs (master plan §23) ────────────────────────────────────

@DriftAccessor(tables: [FundsAccounts])
class FundsAccountsDao extends DatabaseAccessor<AppDatabase>
    with _$FundsAccountsDaoMixin, BusinessScopedDao<AppDatabase> {
  FundsAccountsDao(super.db);

  /// Active (non-deleted) accounts for [storeId] — Cash Till first (account
  /// type sorts cash_till < pos_machine), then by name.
  Stream<List<FundsAccountData>> watchActiveAccountsForStore(String storeId) {
    return (select(fundsAccounts)
          ..where((t) =>
              whereBusiness(t) & t.storeId.equals(storeId) & t.isDeleted.not())
          ..orderBy([
            (t) => OrderingTerm(expression: t.accountType),
            (t) => OrderingTerm(expression: t.name),
          ]))
        .watch();
  }

  /// One-shot business-scoped variant for the checkout account picker (reads
  /// once so a multi-business device can't surface another business's account).
  Future<List<FundsAccountData>> getActiveAccountsForStore(String storeId) {
    return (select(fundsAccounts)
          ..where((t) =>
              whereBusiness(t) & t.storeId.equals(storeId) & t.isDeleted.not())
          ..orderBy([
            (t) => OrderingTerm(expression: t.accountType),
            (t) => OrderingTerm(expression: t.name),
          ]))
        .get();
  }

  /// Idempotently ensures a Cash Till exists for [storeId] and returns it.
  Future<FundsAccountData> ensureCashTill(String storeId) async {
    final existing = await (select(fundsAccounts)
          ..where((t) =>
              whereBusiness(t) &
              t.storeId.equals(storeId) &
              t.accountType.equals('cash_till') &
              t.isDeleted.not())
          ..limit(1))
        .getSingleOrNull();
    if (existing != null) return existing;
    final id = await createAccount(
      storeId: storeId,
      accountType: 'cash_till',
      name: 'Cash Till',
    );
    return (select(fundsAccounts)..where((t) => t.id.equals(id))).getSingle();
  }

  /// Creates an account (cash_till | pos_machine | bank) + enqueues the upsert.
  ///
  /// UNIQUE(store_id, account_type, name) ignores is_deleted, so re-adding a
  /// name that was soft-deleted earlier would violate it and crash. Treat that
  /// as "bring the account back": reactivate the existing row instead. An
  /// *active* duplicate is a genuine user error and throws a friendly message
  /// for the caller to surface.
  Future<String> createAccount({
    required String storeId,
    required String accountType,
    required String name,
    String? accountNumber,
  }) async {
    final existing = await (select(fundsAccounts)
          ..where((t) =>
              whereBusiness(t) &
              t.storeId.equals(storeId) &
              t.accountType.equals(accountType) &
              t.name.equals(name))
          ..limit(1))
        .getSingleOrNull();
    if (existing != null) {
      if (!existing.isDeleted) {
        throw StateError('An account named "$name" already exists');
      }
      await (update(fundsAccounts)
            ..where((t) => t.id.equals(existing.id) & whereBusiness(t)))
          .write(FundsAccountsCompanion(
        isDeleted: const Value(false),
        accountNumber: Value(accountNumber),
        lastUpdatedAt: Value(DateTime.now()),
      ));
      final reactivated = await (select(fundsAccounts)
            ..where((t) => t.id.equals(existing.id) & whereBusiness(t)))
          .getSingle();
      await db.syncDao
          .enqueueUpsert('funds_accounts', reactivated.toCompanion(true));
      return existing.id;
    }
    final id = UuidV7.generate();
    final row = FundsAccountsCompanion.insert(
      id: Value(id),
      businessId: requireBusinessId(),
      storeId: storeId,
      accountType: accountType,
      name: name,
      accountNumber: Value(accountNumber),
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(fundsAccounts).insert(row);
    await db.syncDao.enqueueUpsert('funds_accounts', row);
    return id;
  }

  /// Soft-deletes an account — §5 / hard rule #9: enqueueUpsert, never
  /// enqueueDelete. Partial companion carries id + business_id so the cloud's
  /// upsert flips is_deleted on the existing row (same shape as products).
  Future<void> softDeleteAccount(String id) async {
    final comp = FundsAccountsCompanion(
      id: Value(id),
      businessId: Value(requireBusinessId()),
      isDeleted: const Value(true),
      lastUpdatedAt: Value(DateTime.now()),
    );
    await (update(fundsAccounts)
          ..where((t) => t.id.equals(id) & whereBusiness(t)))
        .write(comp);
    // Full-row enqueue: a partial funds_accounts upsert omits NOT NULL
    // store_id / account_type / name.
    final row = await (select(fundsAccounts)
          ..where((t) => t.id.equals(id) & whereBusiness(t)))
        .getSingleOrNull();
    if (row != null) {
      await db.syncDao.enqueueUpsert('funds_accounts', row.toCompanion(true));
    }
  }
}

@DriftAccessor(tables: [FundDays, FundsAccounts, FundTransactions])
class FundDaysDao extends DatabaseAccessor<AppDatabase>
    with _$FundDaysDaoMixin, BusinessScopedDao<AppDatabase> {
  FundDaysDao(super.db);

  Future<FundDayData?> getDay(String storeId, String businessDate) {
    return (select(fundDays)
          ..where((t) =>
              whereBusiness(t) &
              t.storeId.equals(storeId) &
              t.businessDate.equals(businessDate))
          ..limit(1))
        .getSingleOrNull();
  }

  /// THE POS gate (hard rule #10): true iff an open day exists for the store.
  Stream<bool> watchIsDayOpen(String storeId, String businessDate) {
    return (select(fundDays)
          ..where((t) =>
              whereBusiness(t) &
              t.storeId.equals(storeId) &
              t.businessDate.equals(businessDate) &
              t.status.equals('open')))
        .watch()
        .map((rows) => rows.isNotEmpty);
  }

  /// Opens the day for [storeId] (§23.4): inserts the day header + an 'opening'
  /// credit per active account (even 0, so every account has a day-zero marker)
  /// in one transaction. Throws if the day is already open (also guarded by the
  /// UNIQUE(store_id, business_date) constraint).
  Future<void> openDay({
    required String storeId,
    required String businessDate,
    required Map<String, int> perAccountOpeningKobo,
    required String performedBy,
  }) async {
    await transaction(() async {
      final existing = await getDay(storeId, businessDate);
      if (existing != null) {
        throw StateError('Day already opened for this store');
      }
      final now = DateTime.now();
      final dayRow = FundDaysCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: requireBusinessId(),
        storeId: storeId,
        businessDate: businessDate,
        status: const Value('open'),
        openedBy: Value(performedBy),
        openedAt: Value(now.toUtc()),
        lastUpdatedAt: Value(now),
      );
      await into(fundDays).insert(dayRow);
      await db.syncDao.enqueueUpsert('fund_days', dayRow);

      final accounts = await (select(fundsAccounts)
            ..where((t) =>
                whereBusiness(t) &
                t.storeId.equals(storeId) &
                t.isDeleted.not()))
          .get();
      for (final acct in accounts) {
        final opening = perAccountOpeningKobo[acct.id] ?? 0;
        final txn = FundTransactionsCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: requireBusinessId(),
          fundsAccountId: acct.id,
          storeId: storeId,
          businessDate: businessDate,
          type: 'credit',
          amountKobo: opening,
          signedAmountKobo: opening,
          referenceType: 'opening',
          performedBy: Value(performedBy),
          createdAt: Value(now),
          lastUpdatedAt: Value(now),
        );
        await into(fundTransactions).insert(txn);
        await db.syncDao.enqueueUpsert('fund_transactions', txn);
      }

      await db.activityLogDao.log(
        action: 'funds.open_day',
        // No raw UUID in user-facing text (hard rule #4); the store is already
        // carried in the structured storeId field below.
        description: 'Opened the day',
        staffId: performedBy,
        storeId: storeId,
      );
    });
  }
}

@DriftAccessor(tables: [FundTransactions])
class FundTransactionsDao extends DatabaseAccessor<AppDatabase>
    with _$FundTransactionsDaoMixin, BusinessScopedDao<AppDatabase> {
  FundTransactionsDao(super.db);

  /// Appends a 'sale' credit for the cash/card/transfer that landed in
  /// [fundsAccountId]. MUST be called inside an existing transaction (e.g.
  /// OrdersDao.createOrder) — it does not open its own.
  Future<void> creditSale({
    required String fundsAccountId,
    required String storeId,
    required String businessDate,
    required int amountKobo,
    required String orderId,
    String? paymentId,
    String? performedBy,
  }) async {
    final now = DateTime.now();
    final txn = FundTransactionsCompanion.insert(
      id: Value(UuidV7.generate()),
      businessId: requireBusinessId(),
      fundsAccountId: fundsAccountId,
      storeId: storeId,
      businessDate: businessDate,
      type: 'credit',
      amountKobo: amountKobo,
      signedAmountKobo: amountKobo,
      referenceType: 'sale',
      orderId: Value(orderId),
      paymentId: Value(paymentId),
      performedBy: Value(performedBy),
      createdAt: Value(now),
      lastUpdatedAt: Value(now),
    );
    await into(fundTransactions).insert(txn);
    await db.syncDao.enqueueUpsert('fund_transactions', txn);
  }

  /// Appends a 'topup' credit for the cash/transfer a customer handed over to
  /// top up their wallet — the money physically lands in [fundsAccountId], so
  /// the Funds Register must reflect it (§18 / coding rule 5). MUST be called
  /// inside an existing transaction (WalletService.topup) — it does not open
  /// its own. Mirrors [creditSale] but keys on the payment, not an order.
  Future<void> creditTopup({
    required String fundsAccountId,
    required String storeId,
    required String businessDate,
    required int amountKobo,
    required String paymentId,
    String? performedBy,
  }) async {
    final now = DateTime.now();
    final txn = FundTransactionsCompanion.insert(
      id: Value(UuidV7.generate()),
      businessId: requireBusinessId(),
      fundsAccountId: fundsAccountId,
      storeId: storeId,
      businessDate: businessDate,
      type: 'credit',
      amountKobo: amountKobo,
      signedAmountKobo: amountKobo,
      referenceType: 'topup',
      paymentId: Value(paymentId),
      performedBy: Value(performedBy),
      createdAt: Value(now),
      lastUpdatedAt: Value(now),
    );
    await into(fundTransactions).insert(txn);
    await db.syncDao.enqueueUpsert('fund_transactions', txn);
  }

  /// Expected balance for an account on a day = SUM(signed_amount_kobo) of
  /// non-voided rows (void appends a compensating entry, so no IS NULL filter).
  Future<int> getBalanceFor(String fundsAccountId, String businessDate) async {
    final sumExpr = fundTransactions.signedAmountKobo.sum();
    final query = selectOnly(fundTransactions)
      ..addColumns([sumExpr])
      ..where(
        whereBusiness(fundTransactions) &
            fundTransactions.fundsAccountId.equals(fundsAccountId) &
            fundTransactions.businessDate.equals(businessDate),
      );
    final row = await query.getSingleOrNull();
    return row?.read(sumExpr) ?? 0;
  }

  /// Live per-account expected balances for a store on [businessDate].
  Stream<Map<String, int>> watchStoreBalancesForDay(
    String storeId,
    String businessDate,
  ) {
    final sumExpr = fundTransactions.signedAmountKobo.sum();
    final query = selectOnly(fundTransactions)
      ..addColumns([fundTransactions.fundsAccountId, sumExpr])
      ..where(
        whereBusiness(fundTransactions) &
            fundTransactions.storeId.equals(storeId) &
            fundTransactions.businessDate.equals(businessDate),
      )
      ..groupBy([fundTransactions.fundsAccountId]);
    return query.watch().map((rows) {
      final out = <String, int>{};
      for (final r in rows) {
        final aid = r.read(fundTransactions.fundsAccountId);
        if (aid != null) out[aid] = r.read(sumExpr) ?? 0;
      }
      return out;
    });
  }
}

@DriftAccessor(tables: [ManufacturerCrateBalances, CrateSizeGroups])
class ManufacturerCrateBalancesDao extends DatabaseAccessor<AppDatabase>
    with _$ManufacturerCrateBalancesDaoMixin, BusinessScopedDao<AppDatabase> {
  ManufacturerCrateBalancesDao(super.db);

  Stream<List<ManufacturerCrateBalanceWithGroup>> watchByManufacturer(
    String manufacturerId,
  ) {
    final query = select(manufacturerCrateBalances).join([
      innerJoin(
        crateSizeGroups,
        crateSizeGroups.id.equalsExp(manufacturerCrateBalances.crateSizeGroupId),
      ),
    ]);
    query.where(
      whereBusiness(manufacturerCrateBalances) &
          manufacturerCrateBalances.manufacturerId.equals(manufacturerId),
    );

    return query.watch().map((rows) {
      return rows.map((row) {
        return ManufacturerCrateBalanceWithGroup(
          balance: row.readTable(manufacturerCrateBalances),
          group: row.readTable(crateSizeGroups),
        );
      }).toList();
    });
  }
}

class ManufacturerCrateBalanceWithGroup {
  final ManufacturerCrateBalance balance;
  final CrateSizeGroupData group;
  ManufacturerCrateBalanceWithGroup({
    required this.balance,
    required this.group,
  });
}

@DriftAccessor(
  tables: [CrateLedger, CustomerCrateBalances, ManufacturerCrateBalances],
)
class CrateLedgerDao extends DatabaseAccessor<AppDatabase>
    with _$CrateLedgerDaoMixin, BusinessScopedDao<AppDatabase> {
  CrateLedgerDao(super.db);

  Future<void> recordCrateReturnByManufacturer({
    required String manufacturerId,
    required String crateSizeGroupId,
    required int quantity,
    required String performedBy,
  }) async {
    final delta = -quantity; // returning empties reduces our balance

    final flagValue = await db.systemConfigDao
        .get('feature.domain_rpcs_v2.record_crate_return');
    final useDomainRpc = flagValue == 'true' || flagValue == '"true"';

    await transaction(() async {
      // 1. Append crate_ledger entry
      final ledgerId = UuidV7.generate();
      final ledgerComp = CrateLedgerCompanion.insert(
        id: Value(ledgerId),
        businessId: requireBusinessId(),
        manufacturerId: Value(manufacturerId),
        crateSizeGroupId: crateSizeGroupId,
        quantityDelta: delta,
        movementType: 'returned',
        performedBy: Value(performedBy),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await into(crateLedger).insert(ledgerComp);

      // 2. Update manufacturer_crate_balances cache (always — UI reads this)
      await customStatement(
        'INSERT INTO manufacturer_crate_balances (id, business_id, manufacturer_id, crate_size_group_id, balance) '
        'VALUES (?, ?, ?, ?, ?) '
        'ON CONFLICT(business_id, manufacturer_id, crate_size_group_id) DO UPDATE SET '
        'balance = balance + excluded.balance, last_updated_at = CURRENT_TIMESTAMP',
        [
          UuidV7.generate(),
          requireBusinessId(),
          manufacturerId,
          crateSizeGroupId,
          delta,
        ],
      );

      if (useDomainRpc) {
        final payload = <String, dynamic>{
          'p_business_id': requireBusinessId(),
          'p_actor_id': performedBy,
          'p_ledger_id': ledgerId,
          'p_owner_kind': 'manufacturer',
          'p_owner_id': manufacturerId,
          'p_crate_size_group_id': crateSizeGroupId,
          'p_quantity_delta': delta,
          'p_movement_type': 'returned',
        };
        await db.syncDao
            .enqueue('domain:pos_record_crate_return', jsonEncode(payload));
      } else {
        await db.syncDao.enqueueUpsert('crate_ledger', ledgerComp);
        final updatedBalance =
            await (select(manufacturerCrateBalances)
                  ..where(
                    (t) =>
                        whereBusiness(t) &
                        t.manufacturerId.equals(manufacturerId) &
                        t.crateSizeGroupId.equals(crateSizeGroupId),
                  )
                  ..limit(1))
                .getSingle();
        await db.syncDao.enqueueUpsert(
          'manufacturer_crate_balances',
          updatedBalance,
        );
      }
    });
  }

  Future<void> recordCrateReturnByCustomer({
    required String customerId,
    required String crateSizeGroupId,
    required int quantity,
    required String performedBy,
    String? orderId,
  }) async {
    final delta = -quantity; // customer returning reduces balance

    final flagValue = await db.systemConfigDao
        .get('feature.domain_rpcs_v2.record_crate_return');
    final useDomainRpc = flagValue == 'true' || flagValue == '"true"';

    await transaction(() async {
      final ledgerId = UuidV7.generate();
      final ledgerComp = CrateLedgerCompanion.insert(
        id: Value(ledgerId),
        businessId: requireBusinessId(),
        customerId: Value(customerId),
        manufacturerId: const Value.absent(),
        crateSizeGroupId: crateSizeGroupId,
        quantityDelta: delta,
        movementType: 'returned',
        referenceOrderId: Value(orderId),
        performedBy: Value(performedBy),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await into(crateLedger).insert(ledgerComp);

      await customStatement(
        'INSERT INTO customer_crate_balances (id, business_id, customer_id, crate_size_group_id, balance) '
        'VALUES (?, ?, ?, ?, ?) '
        'ON CONFLICT(business_id, customer_id, crate_size_group_id) DO UPDATE SET '
        'balance = balance + excluded.balance, last_updated_at = CURRENT_TIMESTAMP',
        [
          UuidV7.generate(),
          requireBusinessId(),
          customerId,
          crateSizeGroupId,
          delta,
        ],
      );

      if (useDomainRpc) {
        final payload = <String, dynamic>{
          'p_business_id': requireBusinessId(),
          'p_actor_id': performedBy,
          'p_ledger_id': ledgerId,
          'p_owner_kind': 'customer',
          'p_owner_id': customerId,
          'p_crate_size_group_id': crateSizeGroupId,
          'p_quantity_delta': delta,
          'p_movement_type': 'returned',
          if (orderId != null) 'p_reference_order_id': orderId,
        };
        await db.syncDao
            .enqueue('domain:pos_record_crate_return', jsonEncode(payload));
      } else {
        await db.syncDao.enqueueUpsert('crate_ledger', ledgerComp);
        final updatedBalance =
            await (select(customerCrateBalances)
                  ..where(
                    (t) =>
                        whereBusiness(t) &
                        t.customerId.equals(customerId) &
                        t.crateSizeGroupId.equals(crateSizeGroupId),
                  )
                  ..limit(1))
                .getSingle();
        await db.syncDao
            .enqueueUpsert('customer_crate_balances', updatedBalance);
      }
    });
  }

  /// Verification logic to ensure cache tables match ledger sums.
  /// To be scheduled nightly or run on-demand.
  Future<void> verifyCrateReconciliation() async {
    // 1. Reconcile Customers
    final customerLedgerSums =
        await (selectOnly(crateLedger)
              ..addColumns([
                crateLedger.customerId,
                crateLedger.crateSizeGroupId,
                crateLedger.quantityDelta.sum(),
              ])
              ..where(
                whereBusiness(crateLedger) & crateLedger.customerId.isNotNull(),
              )
              ..groupBy([crateLedger.customerId, crateLedger.crateSizeGroupId]))
            .get();

    for (final row in customerLedgerSums) {
      final custId = row.read(crateLedger.customerId)!;
      final cgId = row.read(crateLedger.crateSizeGroupId)!;
      final sum = row.read(crateLedger.quantityDelta.sum()) ?? 0;

      final cache =
          await (select(customerCrateBalances)..where(
                (t) =>
                    whereBusiness(t) &
                    t.customerId.equals(custId) &
                    t.crateSizeGroupId.equals(cgId),
              ))
              .getSingleOrNull();

      if (cache == null || cache.balance != sum.toInt()) {
        // Log mismatch or trigger auto-fix (logging for now)
        // ignore: avoid_print
        print(
          'CRATE MISMATCH [Customer]: $custId, Group: $cgId, Ledger: $sum, Cache: ${cache?.balance}',
        );
      }
    }

    // 2. Reconcile Manufacturers
    final manufacturerLedgerSums =
        await (selectOnly(crateLedger)
              ..addColumns([
                crateLedger.manufacturerId,
                crateLedger.crateSizeGroupId,
                crateLedger.quantityDelta.sum(),
              ])
              ..where(
                whereBusiness(crateLedger) &
                    crateLedger.manufacturerId.isNotNull(),
              )
              ..groupBy([crateLedger.manufacturerId, crateLedger.crateSizeGroupId]))
            .get();

    for (final row in manufacturerLedgerSums) {
      final mfrId = row.read(crateLedger.manufacturerId)!;
      final cgId = row.read(crateLedger.crateSizeGroupId)!;
      final sum = row.read(crateLedger.quantityDelta.sum()) ?? 0;

      final cache =
          await (select(manufacturerCrateBalances)..where(
                (t) =>
                    whereBusiness(t) &
                    t.manufacturerId.equals(mfrId) &
                    t.crateSizeGroupId.equals(cgId),
              ))
              .getSingleOrNull();

      if (cache == null || cache.balance != sum.toInt()) {
        // ignore: avoid_print
        print(
          'CRATE MISMATCH [Manufacturer]: $mfrId, Group: $cgId, Ledger: $sum, Cache: ${cache?.balance}',
        );
      }
    }
  }
}

@DriftAccessor(tables: [Settings])
class SettingsDao extends DatabaseAccessor<AppDatabase>
    with _$SettingsDaoMixin, BusinessScopedDao<AppDatabase> {
  SettingsDao(super.db);

  Future<String?> get(String key) async {
    final row =
        await (select(settings)
              ..where((t) => whereBusiness(t) & t.key.equals(key))
              ..limit(1))
            .getSingleOrNull();
    return row?.value;
  }

  Future<void> set(String key, String value) async {
    // customInsert (not customStatement) so Drift marks `settings` as updated
    // and re-fires any open watch() streams — without `updates:`, raw
    // statements are invisible to stream watchers, so reactive readers (e.g.
    // the business accent colour via businessDesignSystemProvider) never see
    // the new value until they re-subscribe.
    await customInsert(
      'INSERT INTO settings (id, business_id, "key", value) VALUES (?, ?, ?, ?) '
      'ON CONFLICT(business_id, "key") DO UPDATE SET value = excluded.value, last_updated_at = (strftime(\'%s\', \'now\'))',
      variables: [
        Variable.withString(UuidV7.generate()),
        Variable.withString(requireBusinessId()),
        Variable.withString(key),
        Variable.withString(value),
      ],
      updates: {settings},
    );
    final row =
        await (select(settings)
              ..where((t) => whereBusiness(t) & t.key.equals(key))
              ..limit(1))
            .getSingle();
    await db.syncDao.enqueueUpsert('settings', row);
  }

  Stream<String?> watch(String key) {
    return (select(settings)
          ..where((t) => whereBusiness(t) & t.key.equals(key))
          ..limit(1))
        .watchSingleOrNull()
        .map((row) => row?.value);
  }

  /// Helper for timezone-aware logic (PR 4c/4f)
  Future<String> getTimezone() async {
    return (await get('business_timezone')) ?? 'UTC';
  }

  Stream<String> watchTimezone() {
    return watch('business_timezone').map((v) => v ?? 'UTC');
  }
}

@DriftAccessor(tables: [Businesses])
class BusinessesDao extends DatabaseAccessor<AppDatabase>
    with _$BusinessesDaoMixin, BusinessScopedDao<AppDatabase> {
  BusinessesDao(super.db);

  /// Edits the current business's name and/or type (CEO Settings > Business
  /// Info, §10.1). Currency is a synced `settings` key (`default_currency`),
  /// not a column here — set it via [SettingsDao.set].
  ///
  /// `businesses` is cloud-synced via its special push/pull/realtime path
  /// (it is intentionally absent from `_syncedTenantTables`), so the write
  /// still routes through `enqueueUpsert`. Because that absence also means
  /// no `bump_businesses_last_updated_at` trigger exists, `lastUpdatedAt`
  /// is stamped explicitly here (same as onboarding's local mirror).
  Future<void> updateInfo({String? name, String? type}) async {
    final id = requireBusinessId();
    await (update(businesses)..where((t) => t.id.equals(id))).write(
      BusinessesCompanion(
        name: name == null ? const Value.absent() : Value(name),
        type: type == null ? const Value.absent() : Value(type),
        lastUpdatedAt: Value(DateTime.now()),
      ),
    );
    final row =
        await (select(businesses)..where((t) => t.id.equals(id))).getSingle();
    await db.syncDao.enqueueUpsert('businesses', row);
  }
}

@DriftAccessor(tables: [SystemConfig])
class SystemConfigDao extends DatabaseAccessor<AppDatabase>
    with _$SystemConfigDaoMixin {
  SystemConfigDao(super.db);

  Future<String?> get(String key) async {
    final row =
        await (select(systemConfig)
              ..where((t) => t.key.equals(key))
              ..limit(1))
            .getSingleOrNull();
    return row?.value;
  }

  Future<void> set(String key, String? value) async {
    await customStatement(
      'INSERT INTO system_config ("key", value) VALUES (?, ?) '
      'ON CONFLICT("key") DO UPDATE SET value = excluded.value, last_updated_at = (strftime(\'%s\', \'now\'))',
      [key, value],
    );
  }
}

// ---------------------------------------------------------------------------
// Master plan §2.4 — roles, permissions, membership (schema v13)
// ---------------------------------------------------------------------------

/// Read-only access to the global `permissions` table. Rows are seeded
/// by migration on both the client and the cloud; nothing writes to
/// this table at runtime, so no enqueue path.
@DriftAccessor(tables: [Permissions])
class PermissionsDao extends DatabaseAccessor<AppDatabase>
    with _$PermissionsDaoMixin {
  PermissionsDao(super.db);

  Future<List<PermissionData>> getAll() {
    return (select(permissions)
          ..orderBy([
            (t) => OrderingTerm.asc(t.category),
            (t) => OrderingTerm.asc(t.key),
          ]))
        .get();
  }

  Stream<List<PermissionData>> watchAll() {
    return (select(permissions)
          ..orderBy([
            (t) => OrderingTerm.asc(t.category),
            (t) => OrderingTerm.asc(t.key),
          ]))
        .watch();
  }

  Future<PermissionData?> getByKey(String key) {
    return (select(permissions)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
  }
}

@DriftAccessor(tables: [Roles])
class RolesDao extends DatabaseAccessor<AppDatabase>
    with _$RolesDaoMixin, BusinessScopedDao<AppDatabase> {
  RolesDao(super.db);

  /// All non-deleted roles for the current business, ordered for
  /// display: system defaults first (CEO → Manager → Cashier →
  /// Stock keeper), then any Phase 2 custom roles.
  Stream<List<RoleData>> watchAll() {
    return (select(roles)
          ..where((t) => whereBusiness(t) & t.isDeleted.not())
          ..orderBy([
            (t) => OrderingTerm.desc(t.isSystemDefault),
            (t) => OrderingTerm.asc(t.name),
          ]))
        .watch();
  }

  Future<List<RoleData>> getAll() {
    return (select(roles)
          ..where((t) => whereBusiness(t) & t.isDeleted.not())
          ..orderBy([
            (t) => OrderingTerm.desc(t.isSystemDefault),
            (t) => OrderingTerm.asc(t.name),
          ]))
        .get();
  }

  /// All non-deleted roles across every business on this device, NOT scoped
  /// to the current session. Role ids are globally unique, so the role-badge
  /// resolver (see `userRoleProvider`) can look up a role by id even before
  /// login binds a business — the Who Is Working / shared-PIN picker shows
  /// each candidate's role before `setCurrentUser` runs.
  Stream<List<RoleData>> watchAllUnscoped() {
    return (select(roles)..where((t) => t.isDeleted.not())).watch();
  }

  /// Lookup by slug — the stable machine identifier (`ceo`, `manager`,
  /// `cashier`, `stock_keeper`). Code that branches on role identity
  /// uses this, not `name`.
  Future<RoleData?> getBySlug(String slug) {
    return (select(roles)
          ..where((t) => whereBusiness(t) & t.slug.equals(slug))
          ..limit(1))
        .getSingleOrNull();
  }

  /// Insert a role. Used by tests and (future) Phase 2 custom-role UI.
  /// The four system defaults are seeded server-side by
  /// `complete_onboarding` and arrive locally via sync pull.
  Future<void> insertRole(RolesCompanion row) async {
    await into(roles).insert(row);
    await db.syncDao.enqueueUpsert('roles', row);
  }
}

@DriftAccessor(tables: [RolePermissions])
class RolePermissionsDao extends DatabaseAccessor<AppDatabase>
    with _$RolePermissionsDaoMixin, BusinessScopedDao<AppDatabase> {
  RolePermissionsDao(super.db);

  Stream<List<RolePermissionData>> watchForRole(String roleId) {
    return (select(rolePermissions)
          ..where((t) => whereBusiness(t) & t.roleId.equals(roleId))
          ..orderBy([(t) => OrderingTerm.asc(t.permissionKey)]))
        .watch();
  }

  Future<List<RolePermissionData>> getForRole(String roleId) {
    return (select(rolePermissions)
          ..where((t) => whereBusiness(t) & t.roleId.equals(roleId))
          ..orderBy([(t) => OrderingTerm.asc(t.permissionKey)]))
        .get();
  }

  /// Count of granted permissions for a role. Used by the verification
  /// test and by CEO Settings to show "N of M permissions granted".
  Future<int> countForRole(String roleId) async {
    final row =
        await (selectOnly(rolePermissions)
              ..addColumns([rolePermissions.id.count()])
              ..where(
                  whereBusiness(rolePermissions) &
                      rolePermissions.roleId.equals(roleId)))
            .getSingle();
    return row.read(rolePermissions.id.count()) ?? 0;
  }

  /// Grant a permission to a role. UNIQUE (role_id, permission_key)
  /// guards against duplicates.
  Future<void> grant(String roleId, String permissionKey) async {
    final row = RolePermissionsCompanion.insert(
      id: Value(UuidV7.generate()),
      businessId: requireBusinessId(),
      roleId: roleId,
      permissionKey: permissionKey,
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(rolePermissions).insert(row);
    await db.syncDao.enqueueUpsert('role_permissions', row);
  }

  /// Revoke a permission. Deletes the row and enqueues the
  /// tombstone — `role_permissions` is not an append-only ledger, so
  /// hard-delete via `enqueueDelete` is the right path here.
  Future<void> revoke(String roleId, String permissionKey) async {
    final existing = await (select(rolePermissions)
          ..where((t) =>
              whereBusiness(t) &
              t.roleId.equals(roleId) &
              t.permissionKey.equals(permissionKey))
          ..limit(1))
        .getSingleOrNull();
    if (existing == null) return;
    await (delete(rolePermissions)..where((t) => t.id.equals(existing.id)))
        .go();
    await db.syncDao.enqueueDelete('role_permissions', existing.id);
  }
}

@DriftAccessor(tables: [RoleSettings])
class RoleSettingsDao extends DatabaseAccessor<AppDatabase>
    with _$RoleSettingsDaoMixin, BusinessScopedDao<AppDatabase> {
  RoleSettingsDao(super.db);

  Stream<List<RoleSettingData>> watchForRole(String roleId) {
    return (select(roleSettings)
          ..where((t) => whereBusiness(t) & t.roleId.equals(roleId))
          ..orderBy([(t) => OrderingTerm.asc(t.settingKey)]))
        .watch();
  }

  Future<List<RoleSettingData>> getForRole(String roleId) {
    return (select(roleSettings)
          ..where((t) => whereBusiness(t) & t.roleId.equals(roleId))
          ..orderBy([(t) => OrderingTerm.asc(t.settingKey)]))
        .get();
  }

  Future<String?> getValue(String roleId, String settingKey) async {
    final row = await (select(roleSettings)
          ..where((t) =>
              whereBusiness(t) &
              t.roleId.equals(roleId) &
              t.settingKey.equals(settingKey))
          ..limit(1))
        .getSingleOrNull();
    return row?.settingValue;
  }

  /// Set a setting value. Upserts on (role_id, setting_key).
  Future<void> set(String roleId, String settingKey, String? value) async {
    final existing = await (select(roleSettings)
          ..where((t) =>
              whereBusiness(t) &
              t.roleId.equals(roleId) &
              t.settingKey.equals(settingKey))
          ..limit(1))
        .getSingleOrNull();
    if (existing != null) {
      final comp = RoleSettingsCompanion(
        id: Value(existing.id),
        settingValue: Value(value),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await (update(roleSettings)..where((t) => t.id.equals(existing.id)))
          .write(comp);
      // Refresh full row for enqueue (payload carries businessId etc.)
      final refreshed = await (select(roleSettings)
            ..where((t) => t.id.equals(existing.id)))
          .getSingle();
      await db.syncDao.enqueueUpsert('role_settings', refreshed);
    } else {
      final comp = RoleSettingsCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: requireBusinessId(),
        roleId: roleId,
        settingKey: settingKey,
        settingValue: Value(value),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await into(roleSettings).insert(comp);
      await db.syncDao.enqueueUpsert('role_settings', comp);
    }
  }
}

/// One active staff member for the Who Is Working picker (master plan §8):
/// the user row plus their resolved role (null if the role row hasn't synced
/// locally yet).
class WhoIsWorkingEntry {
  final UserData user;
  final RoleData? role;
  const WhoIsWorkingEntry({required this.user, this.role});
}

@DriftAccessor(tables: [UserBusinesses, Users, Roles])
class UserBusinessesDao extends DatabaseAccessor<AppDatabase>
    with _$UserBusinessesDaoMixin, BusinessScopedDao<AppDatabase> {
  UserBusinessesDao(super.db);

  /// All active memberships for the current business. Drives the
  /// Staff Management list and the Who Is Working picker.
  Stream<List<UserBusinessData>> watchForCurrentBusiness() {
    return (select(userBusinesses)
          ..where((t) => whereBusiness(t))
          ..orderBy([(t) => OrderingTerm.asc(t.status)]))
        .watch();
  }

  /// Active staff (with their user + role rows) for [businessId], joined in
  /// one query — drives the Who Is Working picker (master plan §8).
  ///
  /// Deliberately NOT business-scoped via [whereBusiness]/[requireBusinessId]:
  /// the picker renders BEFORE sign-in, so the session resolver has no current
  /// business yet (`currentBusinessId == null`). It filters by the explicit
  /// [businessId] argument instead. Suspended staff are excluded (§8.3).
  Stream<List<WhoIsWorkingEntry>> watchActiveStaffForBusiness(
    String businessId,
  ) {
    final query = select(userBusinesses).join([
      innerJoin(users, users.id.equalsExp(userBusinesses.userId)),
      leftOuterJoin(roles, roles.id.equalsExp(userBusinesses.roleId)),
    ])
      ..where(
        userBusinesses.businessId.equals(businessId) &
            userBusinesses.status.equals('active'),
      )
      ..orderBy([OrderingTerm.asc(users.name)]);
    return query.watch().map(
          (rows) => rows
              .map((row) => WhoIsWorkingEntry(
                    user: row.readTable(users),
                    role: row.readTableOrNull(roles),
                  ))
              .toList(),
        );
  }

  /// All memberships for a specific user — Phase 1 always returns
  /// at most one row, but the query supports the Phase 2 multi-
  /// business model without a schema change.
  Future<List<UserBusinessData>> getForUser(String userId) {
    return (select(userBusinesses)..where((t) => t.userId.equals(userId)))
        .get();
  }

  /// Reactive memberships for a specific user, NOT scoped to the current
  /// session. Filters by user id only so the role-badge resolver works
  /// before login binds a business (the shared-PIN picker). Drives
  /// `userRoleProvider`.
  Stream<List<UserBusinessData>> watchForUser(String userId) {
    return (select(userBusinesses)..where((t) => t.userId.equals(userId)))
        .watch();
  }

  Future<UserBusinessData?> getForUserInBusiness(
    String userId,
    String businessId,
  ) {
    return (select(userBusinesses)
          ..where((t) =>
              t.userId.equals(userId) & t.businessId.equals(businessId))
          ..limit(1))
        .getSingleOrNull();
  }

  Future<void> insertMembership(UserBusinessesCompanion row) async {
    await into(userBusinesses).insert(row);
    await db.syncDao.enqueueUpsert('user_businesses', row);
  }

  /// Suspend or reactivate a membership. [status] is `'active'` or
  /// `'suspended'` (matches the CHECK constraint). Enqueues the updated
  /// row for sync.
  Future<void> setStatus(String membershipId, String status) async {
    await (update(userBusinesses)..where((t) => t.id.equals(membershipId)))
        .write(
      UserBusinessesCompanion(
        status: Value(status),
        lastUpdatedAt: Value(DateTime.now()),
      ),
    );
    // Re-read the full row so the enqueue payload carries businessId etc.
    final refreshed = await (select(userBusinesses)
          ..where((t) => t.id.equals(membershipId)))
        .getSingle();
    await db.syncDao.enqueueUpsert('user_businesses', refreshed);
  }

  /// Change the role on a membership. Enqueues the updated row for sync.
  Future<void> setRole(String membershipId, String roleId) async {
    await (update(userBusinesses)..where((t) => t.id.equals(membershipId)))
        .write(
      UserBusinessesCompanion(
        roleId: Value(roleId),
        lastUpdatedAt: Value(DateTime.now()),
      ),
    );
    // Re-read the full row so the enqueue payload carries businessId etc.
    final refreshed = await (select(userBusinesses)
          ..where((t) => t.id.equals(membershipId)))
        .getSingle();
    await db.syncDao.enqueueUpsert('user_businesses', refreshed);
  }

  /// Stamp the login time on a user's membership. Enqueues the updated row
  /// for sync. No-op if the user has no membership in [businessId].
  Future<void> touchLastLogin(String userId, String businessId) async {
    final now = DateTime.now();
    await (update(userBusinesses)
          ..where((t) =>
              t.userId.equals(userId) & t.businessId.equals(businessId)))
        .write(
      UserBusinessesCompanion(
        lastLoginAt: Value(now),
        lastUpdatedAt: Value(now),
      ),
    );
    // Re-read the full row so the enqueue payload carries businessId etc.
    final refreshed = await getForUserInBusiness(userId, businessId);
    if (refreshed != null) {
      await db.syncDao.enqueueUpsert('user_businesses', refreshed);
    }
  }
}

@DriftAccessor(tables: [InviteCodes])
class InviteCodesDao extends DatabaseAccessor<AppDatabase>
    with _$InviteCodesDaoMixin, BusinessScopedDao<AppDatabase> {
  InviteCodesDao(super.db);

  /// Active invite codes (not yet used, not revoked, not soft-
  /// deleted, not expired). Drives the Invites tab.
  Stream<List<InviteCodeData>> watchActive() {
    final now = DateTime.now();
    return (select(inviteCodes)
          ..where((t) =>
              whereBusiness(t) &
              t.isDeleted.not() &
              t.usedAt.isNull() &
              t.revokedAt.isNull() &
              t.expiresAt.isBiggerThanValue(now))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .watch();
  }

  Future<InviteCodeData?> getByCode(String code) {
    return (select(inviteCodes)
          ..where((t) => t.code.equals(code))
          ..limit(1))
        .getSingleOrNull();
  }

  Future<void> insertInvite(InviteCodesCompanion row) async {
    await into(inviteCodes).insert(row);
    await db.syncDao.enqueueUpsert('invite_codes', row);
  }

  /// Revoke an invite code (soft — stays in sync). Sets `revokedAt` so the
  /// code drops out of `watchActive` and can no longer be redeemed. The
  /// row stays in `invite_codes`; enqueue the full row so the cloud sees
  /// the revoke (CLAUDE.md hard rule #9 / §5 soft-delete via enqueueUpsert).
  Future<void> revoke(String id) async {
    final now = DateTime.now();
    await (update(inviteCodes)..where((t) => t.id.equals(id))).write(
      InviteCodesCompanion(
        revokedAt: Value(now),
        lastUpdatedAt: Value(now),
      ),
    );
    // Re-read the full row so the enqueue payload carries businessId etc.
    final refreshed =
        await (select(inviteCodes)..where((t) => t.id.equals(id))).getSingle();
    await db.syncDao.enqueueUpsert('invite_codes', refreshed);
  }
}

@DriftAccessor(tables: [UserStores])
class UserStoresDao extends DatabaseAccessor<AppDatabase>
    with _$UserStoresDaoMixin, BusinessScopedDao<AppDatabase> {
  UserStoresDao(super.db);

  Stream<List<UserStoreData>> watchForUser(String userId) {
    return (select(userStores)..where((t) => t.userId.equals(userId))).watch();
  }

  Future<List<UserStoreData>> getForUser(String userId) {
    return (select(userStores)..where((t) => t.userId.equals(userId))).get();
  }

  /// Assign a user to a store. UNIQUE (user_id, store_id) guards
  /// against duplicates.
  Future<void> assign(UserStoresCompanion row) async {
    await into(userStores).insert(row);
    await db.syncDao.enqueueUpsert('user_stores', row);
  }
}
