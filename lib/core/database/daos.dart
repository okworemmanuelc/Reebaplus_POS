import 'dart:convert';
import 'dart:math' as math;
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:rxdart/rxdart.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:reebaplus_pos/core/data/business_types.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/business_scoped_dao.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/database/sync_helpers.dart';
import 'package:reebaplus_pos/core/utils/order_number.dart';

part 'daos.g.dart';

/// Sentinel for "argument was not provided" on optional setter parameters,
/// distinct from "argument was provided as null". Used by methods that
/// accept partial-update payloads (e.g. `CatalogDao.updateProductDetails`)
/// to map missing args to `Value.absent()` and explicit-null args to
/// `Value(null)` — the latter clears the column, the former leaves it
/// untouched.
const Object _unset = Object();

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

  Future<void> updateManufacturerStock(
    String id,
    int newStock, {
    String? storeId,
  }) async {
    final now = DateTime.now();

    if (storeId != null) {
      // Per-store path (§16.8.1): set this store's balance and bump the
      // business total by the delta so manufacturers.empty_crate_stock stays
      // equal to the sum of all store balances.
      final currentBalance = await db.storeCrateBalancesDao.getBalance(
        storeId: storeId,
        manufacturerId: id,
      );
      final delta = newStock - currentBalance;

      await db.storeCrateBalancesDao.setBalance(
        storeId: storeId,
        manufacturerId: id,
        newBalance: newStock,
      );

      // Bump business total by the same delta.
      final mfr = await (select(
        manufacturers,
      )..where((t) => t.id.equals(id) & whereBusiness(t))).getSingle();
      final comp = ManufacturersCompanion(
        id: Value(id),
        emptyCrateStock: Value(mfr.emptyCrateStock + delta),
        lastUpdatedAt: Value(now),
      );
      await (update(
        manufacturers,
      )..where((t) => t.id.equals(id) & whereBusiness(t))).write(comp);
    } else {
      // Legacy path (no store dimension): absolute set on business total.
      final comp = ManufacturersCompanion(
        id: Value(id),
        emptyCrateStock: Value(newStock),
        lastUpdatedAt: Value(now),
      );
      await (update(
        manufacturers,
      )..where((t) => t.id.equals(id) & whereBusiness(t))).write(comp);
    }
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
  /// returnable crates held against a manufacturer.
  Future<void> addEmptyCrates(
    String manufacturerId,
    int quantity, {
    String? storeId,
  }) async {
    if (quantity == 0) return;
    await customUpdate(
      'UPDATE manufacturers SET empty_crate_stock = empty_crate_stock + ?, '
      'last_updated_at = CAST(strftime(\'%s\', CURRENT_TIMESTAMP) AS INTEGER) '
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

    // Per-store tracking (§16.8.1): if a store is provided, stamp the balance
    // and write a store-scoped crate_ledger row.
    if (storeId != null) {
      await db.storeCrateBalancesDao.applyDelta(
        storeId: storeId,
        manufacturerId: manufacturerId,
        delta: quantity,
      );
      final ledgerComp = CrateLedgerCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: requireBusinessId(),
        manufacturerId: Value(manufacturerId),
        storeId: Value(storeId),
        quantityDelta: quantity,
        movementType: 'adjusted',
        lastUpdatedAt: Value(DateTime.now()),
      );
      await into(crateLedger).insert(ledgerComp);
      await db.syncDao.enqueueUpsert('crate_ledger', ledgerComp);
    }
  }

  /// Stream the per-manufacturer count of full bottles in stock, derived
  /// from inventory rows joined with products on `manufacturer_id`.
  ///
  /// When [storeId] is non-null the count is confined to that store's inventory
  /// (§16.8.1 Phase 2 — the Empty Crates tab shows per-store figures when a
  /// store is active). When null it sums every store (business-wide / "All
  /// Stores").
  Stream<Map<String, int>> watchFullCratesByManufacturer({String? storeId}) {
    var predicate =
        whereBusiness(inventory) &
        whereBusiness(products) &
        products.manufacturerId.isNotNull() &
        products.isDeleted.not();
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
      if (customerId != null && isCrateBusiness(crateBiz?.type)) {
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
          if (walletDebitKobo > 0) 'p_wallet_amount_kobo': walletDebitKobo,
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

      // §14.3 full wallet ledger (rule #4): every registered sale runs through
      // the wallet. Post TWO legs — a debit for the order total (goods leave)
      // and a credit for the amount paid at checkout (money in) — so the net
      // (paid − total) is the customer's position: 0 when fully paid, negative
      // when they owe. This includes fully-paid cash sales (debit total +
      // credit total, net 0), so the wallet history is complete. The credit leg
      // records the money against the customer's wallet. It reuses the existing
      // top-up reference types (by method, mirroring WalletService) so no CHECK
      // widening is needed. Walk-ins (customerId == null) never touch the wallet
      // (rule #14).
      //
      // v1 path. The v2 RPC (pos_record_sale_v2) still mints only the debit via
      // p_wallet_amount_kobo — it MUST also mint this credit leg before
      // record_sale v2 is enabled, or cloud wallets will miss payments (R2).
      if (customerId != null) {
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

@DriftAccessor(
  tables: [
    Customers,
    CustomerCrateBalances,
    CustomerWallets,
    WalletTransactions,
    Manufacturers,
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
            manufacturers,
            manufacturers.id.equalsExp(customerCrateBalances.manufacturerId),
          ),
        ])..where(
          whereBusiness(customerCrateBalances) &
              customerCrateBalances.customerId.equals(customerId),
        );
    return query.watch().map(
      (rows) => rows
          .map(
            (r) => CrateBalanceEntry(
              manufacturerId: r.readTable(customerCrateBalances).manufacturerId,
              manufacturerName: r.readTable(manufacturers).name,
              balance: r.readTable(customerCrateBalances).balance,
            ),
          )
          .toList(),
    );
  }

  Future<String> addCustomer(CustomersCompanion customer) async {
    final customerId = UuidV7.generate();
    final walletId = UuidV7.generate();

    final flagValue = await db.systemConfigDao.get(
      'feature.domain_rpcs_v2.create_customer',
    );
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
          if (custComp.storeId.present) 'p_store_id': custComp.storeId.value,
        };
        await db.syncDao.enqueue(
          'domain:pos_create_customer',
          jsonEncode(payload),
        );
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
    await (update(
      customers,
    )..where((t) => t.id.equals(customerId) & whereBusiness(t))).write(
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

  /// §18 — edit an existing customer's editable details (the same fields the
  /// Add Customer sheet captures). Writes locally then enqueues the FULL row
  /// (via [_enqueueFullCustomer]) so the cloud gets a complete upsert — a
  /// partial customers upsert omits the NOT NULL name → 23502 and would never
  /// sync. Same enqueue pattern as [softDeleteCustomer].
  Future<void> updateCustomerDetails({
    required String customerId,
    required String name,
    String? phone,
    String? address,
    String? googleMapsLocation,
    required String priceTier,
    String? storeId,
  }) async {
    await (update(
      customers,
    )..where((t) => t.id.equals(customerId) & whereBusiness(t))).write(
      CustomersCompanion(
        name: Value(name),
        phone: Value(phone),
        address: Value(address),
        googleMapsLocation: Value(googleMapsLocation),
        priceTier: Value(priceTier),
        storeId: Value(storeId),
        lastUpdatedAt: Value(DateTime.now()),
      ),
    );
    await _enqueueFullCustomer(customerId);
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

  /// §13.4 — crate deposit held for the customer (separate from the spendable
  /// balance above). Shown as its own line on the wallet screen.
  Stream<int> watchWalletDepositsHeldKobo(String customerId) {
    return attachedDatabase.walletTransactionsDao.watchDepositsHeldKobo(
      customerId,
    );
  }

  Future<int> getWalletDepositsHeldKobo(String customerId) {
    return attachedDatabase.walletTransactionsDao.getDepositsHeldKobo(
      customerId,
    );
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

  /// Records an expense (§20). [status] is computed by the caller from the
  /// recorder's role + approval limit: 'approved' for a CEO or a Manager within
  /// their limit; 'pending' for a Manager over limit. The payment method is
  /// recorded for reporting; an expense no longer posts to any account balance
  /// (Funds Register removed, §23).
  Future<void> addExpense({
    required String categoryName,
    required int amountKobo,
    required String description,
    String? paymentMethod,
    String? reference,
    String? storeId,
    required String recordedBy,
    DateTime? expenseDate,
    String? receiptPath,
    String status = 'approved',
  }) async {
    final flagValue = await db.systemConfigDao.get(
      'feature.domain_rpcs_v2.record_expense',
    );
    final useDomainRpc = flagValue == 'true' || flagValue == '"true"';

    // Match v1's existing behavior: a payment_transactions row is always
    // recorded (defaulting to 'other' when the caller didn't specify a
    // method). Keeps analytics/reporting parity across the flag flip.
    final effectivePaymentMethod = paymentMethod ?? 'other';
    final pickedDate = expenseDate ?? DateTime.now();

    await transaction(() async {
      final categoryId = await resolveCategoryId(categoryName);
      final expenseId = UuidV7.generate();
      final activityLogId = UuidV7.generate();
      final paymentId = UuidV7.generate();
      final now = DateTime.now();
      final approved = status == 'approved';

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
        status: Value(status),
        expenseDate: Value(pickedDate),
        receiptPath: Value(receiptPath),
        approvedBy: approved ? Value(recordedBy) : const Value.absent(),
        approvedAt: approved ? Value(now) : const Value.absent(),
        lastUpdatedAt: Value(now),
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
        entityType: const Value('expense'),
        entityId: Value(expenseId),
        storeId: Value(storeId),
        lastUpdatedAt: Value(now),
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
        lastUpdatedAt: Value(now),
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
          'p_status': status,
          'p_expense_date': pickedDate.toIso8601String(),
          if (reference != null) 'p_reference': reference,
          if (storeId != null) 'p_store_id': storeId,
          if (receiptPath != null) 'p_receipt_path': receiptPath,
        };
        await db.syncDao.enqueue(
          'domain:pos_record_expense',
          jsonEncode(payload),
        );
      } else {
        await db.syncDao.enqueueUpsert('expenses', expComp);
        await db.syncDao.enqueueUpsert('activity_logs', activityComp);
        await db.syncDao.enqueueUpsert('payment_transactions', payComp);
      }

      // 4. §20.4 / §26.4 — a Manager's over-limit expense lands Pending; alert
      // the CEO(s) so the approval surfaces on their notification bell (the
      // §20.1 "pending approval" badge). Fired inside the txn so it rolls back
      // with the insert.
      if (!approved) {
        final ceoIds = await db.userBusinessesDao.getUserIdsForRoleSlugs([
          'ceo',
        ]);
        for (final uid in ceoIds) {
          await db.notificationsDao.fireNotification(
            type: 'expense.pending_approval',
            message: 'Expense awaiting your approval: $description',
            severity: 'warning',
            linkedRecordId: expenseId,
            recipientUserId: uid,
          );
        }
      }
    });
  }

  /// Count of expenses awaiting CEO approval (§20.1 bell badge / pending
  /// section). Business-scoped, non-deleted.
  Stream<int> watchPendingCount() {
    final query = selectOnly(expenses)
      ..addColumns([expenses.id.count()])
      ..where(
        whereBusiness(expenses) &
            expenses.isDeleted.not() &
            expenses.status.equals('pending'),
      );
    return query.watchSingleOrNull().map(
      (row) => row?.read(expenses.id.count()) ?? 0,
    );
  }

  /// CEO approves a pending expense (§20.4). Sets status + approver and notifies
  /// the recorder. (An approved expense no longer posts to any account balance —
  /// Funds Register removed, §23.)
  Future<void> approveExpense({
    required String expenseId,
    required String approverId,
  }) async {
    // The status read+guard MUST live inside the transaction. Drift serializes
    // transactions on one connection, so a concurrent/double-tap approve sees
    // the already-committed 'approved' status and no-ops. The conditional UPDATE
    // (status == 'pending') + affected-row check is the belt-and-suspenders.
    String? recordedBy;
    String? description;
    var didApprove = false;

    await transaction(() async {
      final exp =
          await (select(expenses)
                ..where((t) => t.id.equals(expenseId) & whereBusiness(t)))
              .getSingleOrNull();
      if (exp == null || exp.status != 'pending') return;
      final now = DateTime.now();
      final affected =
          await (update(expenses)..where(
                (t) =>
                    t.id.equals(expenseId) &
                    whereBusiness(t) &
                    t.status.equals('pending'),
              ))
              .write(
                ExpensesCompanion(
                  status: const Value('approved'),
                  approvedBy: Value(approverId),
                  approvedAt: Value(now),
                  lastUpdatedAt: Value(now),
                ),
              );
      if (affected == 0) return; // lost the race — already approved
      didApprove = true;
      recordedBy = exp.recordedBy;
      description = exp.description;

      final row = await (select(
        expenses,
      )..where((t) => t.id.equals(expenseId) & whereBusiness(t))).getSingle();
      await db.syncDao.enqueueUpsert('expenses', row.toCompanion(true));

      await db.activityLogDao.log(
        action: 'expense_approved',
        description: 'Approved expense: ${exp.description}',
        staffId: approverId,
        storeId: exp.storeId,
        expenseId: expenseId,
      );
    });

    if (didApprove && recordedBy != null) {
      await db.notificationsDao.fireNotification(
        type: 'expense.approved',
        message: 'Your expense "$description" was approved.',
        severity: 'info',
        linkedRecordId: expenseId,
        recipientUserId: recordedBy,
      );
    }
  }

  /// CEO rejects a pending expense with a reason (§20.4). No funds movement.
  /// Notifies the recorder.
  Future<void> rejectExpense({
    required String expenseId,
    required String approverId,
    required String reason,
  }) async {
    // In-transaction guard (same reasoning as approveExpense) so a double-tap
    // reject doesn't re-fire / re-notify.
    String? recordedBy;
    String? description;
    var didReject = false;

    await transaction(() async {
      final exp =
          await (select(expenses)
                ..where((t) => t.id.equals(expenseId) & whereBusiness(t)))
              .getSingleOrNull();
      if (exp == null || exp.status != 'pending') return;
      final now = DateTime.now();
      final affected =
          await (update(expenses)..where(
                (t) =>
                    t.id.equals(expenseId) &
                    whereBusiness(t) &
                    t.status.equals('pending'),
              ))
              .write(
                ExpensesCompanion(
                  status: const Value('rejected'),
                  rejectionReason: Value(reason),
                  approvedBy: Value(approverId),
                  approvedAt: Value(now),
                  lastUpdatedAt: Value(now),
                ),
              );
      if (affected == 0) return;
      didReject = true;
      recordedBy = exp.recordedBy;
      description = exp.description;

      final row = await (select(
        expenses,
      )..where((t) => t.id.equals(expenseId) & whereBusiness(t))).getSingle();
      await db.syncDao.enqueueUpsert('expenses', row.toCompanion(true));

      await db.activityLogDao.log(
        action: 'expense_rejected',
        description: 'Rejected expense: ${exp.description} — $reason',
        staffId: approverId,
        storeId: exp.storeId,
        expenseId: expenseId,
      );
    });

    if (didReject && recordedBy != null) {
      await db.notificationsDao.fireNotification(
        type: 'expense.rejected',
        message: 'Your expense "$description" was rejected: $reason',
        severity: 'warning',
        linkedRecordId: expenseId,
        recipientUserId: recordedBy,
      );
    }
  }

  /// Edits the descriptive fields of an expense (§20.3 Edit). Amount and payment
  /// method are immutable after creation — a wrong amount is corrected by
  /// soft-delete + re-create. The 24h / role gate is enforced by the caller.
  Future<void> updateExpense({
    required String expenseId,
    required String performedBy,
    required String categoryName,
    required String description,
    String? reference,
    DateTime? expenseDate,
    String? receiptPath,
  }) async {
    final categoryId = await resolveCategoryId(categoryName);
    final now = DateTime.now();
    await (update(
      expenses,
    )..where((t) => t.id.equals(expenseId) & whereBusiness(t))).write(
      ExpensesCompanion(
        categoryId: Value(categoryId),
        description: Value(description),
        reference: Value(reference),
        expenseDate: expenseDate != null
            ? Value(expenseDate)
            : const Value.absent(),
        receiptPath: Value(receiptPath),
        lastUpdatedAt: Value(now),
      ),
    );
    final row = await (select(
      expenses,
    )..where((t) => t.id.equals(expenseId) & whereBusiness(t))).getSingle();
    await db.syncDao.enqueueUpsert('expenses', row.toCompanion(true));

    await db.activityLogDao.log(
      action: 'expense_updated',
      description: 'Edited expense: ${row.description}',
      staffId: performedBy,
      storeId: row.storeId,
      expenseId: expenseId,
    );
  }

  /// Soft-deletes an expense (§20.3, CEO only, hard rule #9 — enqueueUpsert, not
  /// delete). The 24h / role gate is enforced by the caller. (Funds Register was
  /// removed, §23, so a delete no longer reverses any account balance.)
  Future<void> softDeleteExpense({
    required String expenseId,
    required String performedBy,
  }) async {
    // Read + delete-guard live inside the transaction (Drift serializes txns),
    // and the UPDATE is conditional on is_deleted = false, so a double-tap
    // delete is idempotent.
    String? description;
    String? storeIdForLog;
    var didDelete = false;

    await transaction(() async {
      final exp =
          await (select(expenses)
                ..where((t) => t.id.equals(expenseId) & whereBusiness(t)))
              .getSingleOrNull();
      if (exp == null || exp.isDeleted) return;
      final now = DateTime.now();
      final affected =
          await (update(expenses)..where(
                (t) =>
                    t.id.equals(expenseId) &
                    whereBusiness(t) &
                    t.isDeleted.equals(false),
              ))
              .write(
                ExpensesCompanion(
                  isDeleted: const Value(true),
                  lastUpdatedAt: Value(now),
                ),
              );
      if (affected == 0) return; // lost the race — already deleted
      didDelete = true;
      description = exp.description;
      storeIdForLog = exp.storeId;

      final row = await (select(
        expenses,
      )..where((t) => t.id.equals(expenseId) & whereBusiness(t))).getSingle();
      await db.syncDao.enqueueUpsert('expenses', row.toCompanion(true));
    });

    if (didDelete) {
      await db.activityLogDao.log(
        action: 'expense_deleted',
        description: 'Deleted expense: $description',
        staffId: performedBy,
        storeId: storeIdForLog,
        expenseId: expenseId,
      );
    }
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

/// §20.1/§20.3 monthly budget goal. One live row per (business, store-or-null):
/// a null store_id row is the business-wide goal; a store_id row is that store's
/// goal. Routed through enqueueUpsert per the §5 sync contract.
@DriftAccessor(tables: [ExpenseBudgets])
class ExpenseBudgetsDao extends DatabaseAccessor<AppDatabase>
    with _$ExpenseBudgetsDaoMixin, BusinessScopedDao<AppDatabase> {
  ExpenseBudgetsDao(super.db);

  /// All live budgets for the business (the business-wide row has null
  /// store_id). The provider layer resolves the goal for a given store scope.
  Stream<List<ExpenseBudgetData>> watchAll() {
    return (select(
      expenseBudgets,
    )..where((t) => whereBusiness(t) & t.isDeleted.not())).watch();
  }

  /// Sets the monthly goal for (business, [storeId]-or-null). storeId null sets
  /// the business-wide goal. Updates the existing live row for the scope, else
  /// inserts a fresh one — one live row per scope (the partial unique indexes
  /// guard against races). enqueueUpsert syncs it (§5).
  Future<void> setBudget({String? storeId, required int amountKobo}) async {
    final existing =
        await (select(expenseBudgets)
              ..where((t) {
                final base = whereBusiness(t) & t.isDeleted.not();
                return storeId == null
                    ? base & t.storeId.isNull()
                    : base & t.storeId.equals(storeId);
              })
              ..limit(1))
            .getSingleOrNull();
    final now = DateTime.now();
    if (existing != null) {
      await (update(
        expenseBudgets,
      )..where((t) => t.id.equals(existing.id) & whereBusiness(t))).write(
        ExpenseBudgetsCompanion(
          amountKobo: Value(amountKobo),
          lastUpdatedAt: Value(now),
        ),
      );
      final row = await (select(
        expenseBudgets,
      )..where((t) => t.id.equals(existing.id) & whereBusiness(t))).getSingle();
      await db.syncDao.enqueueUpsert('expense_budgets', row.toCompanion(true));
    } else {
      final comp = ExpenseBudgetsCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: requireBusinessId(),
        storeId: Value(storeId),
        amountKobo: amountKobo,
        lastUpdatedAt: Value(now),
      );
      await into(expenseBudgets).insert(comp);
      await db.syncDao.enqueueUpsert('expense_budgets', comp);
    }
  }
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
      final reason = deferredOverflow
          ? 'fk_deferred_cap_reached: $error'
          : error;
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
            // Carry the queue row's auto-retry count forward (§6.8.1) so the
            // automatic-recovery cap holds across re-orphan cycles instead of
            // resetting to 0 every time a recovered row fails again.
            autoRetryCount: Value(existing.autoRetryCount),
          ),
        );
        await (delete(syncQueue)..where((t) => t.id.equals(id))).go();
      });
      return;
    }

    // Transient retry. FK-deferred uses a 10-minute base so the next
    // pull (typical cadence: minutes) lands in between attempts;
    // regular transients keep the original 30-second base. The delay is
    // capped at a ceiling (§6.8: 5 min normal / 15 min FK-deferred) so a row
    // that has failed many times can't drift hours into the future — the
    // 1<<(attempts%10) growth otherwise reaches ~4 h before wrapping, leaving
    // a row stuck long after a continuously-online device's transient cause
    // (cloud blip, lagging parent) has cleared.
    final base = fkDeferred ? 600 : 30;
    final ceilingSeconds = fkDeferred ? 900 : 300;
    final rawSeconds = (1 << (attempts % 10)) * base;
    final delay = Duration(seconds: math.min(rawSeconds, ceilingSeconds));
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
          ..where(
            (t) =>
                t.status.equals('pending') &
                t.isSynced.not() &
                whereBusiness(t),
          )
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
      variables: [Variable.withString(actionType), Variable.withString(rowId)],
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
    return (select(syncQueue)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Looks up a row in `sync_queue_orphans` by its ORIGINAL queue id —
  /// what callers stored before §6.8's auto-archive moved permanent
  /// failures out of `sync_queue`. Used by `flushSale` to surface a
  /// terminal failure to the foreground checkout flow even though
  /// `getQueueItem` would now return null.
  Future<SyncQueueOrphanData?> findOrphanByOriginalId(String originalId) {
    return (select(
      syncQueueOrphans,
    )..where((t) => t.originalId.equals(originalId))).getSingleOrNull();
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
  /// ledger will just orphan it again. Manual retry (the Sync Issues screen
  /// button) resets the auto-retry counter to 0: the operator is explicitly
  /// taking ownership, so it should get the full automatic-recovery budget
  /// again if it re-orphans.
  Future<void> retryOrphan(String orphanId) async {
    await transaction(() async {
      final orphan = await (select(
        syncQueueOrphans,
      )..where((t) => t.id.equals(orphanId))).getSingleOrNull();
      if (orphan == null) return;
      await _reenqueueOrphan(orphan, newAutoRetryCount: 0);
    });
  }

  /// Reason-prefix allowlist for [autoRecoverDueOrphans] (§6.8.1). Only causes
  /// that are now known to be self-healing are auto-retried — re-pushing the
  /// row, not editing it, lets the existing push-side heals run again:
  ///   - `fk_deferred_cap_reached…` — the parent row was missing when the cap
  ///     was hit; it may have since arrived via a pull, so the child can now
  ///     insert.
  ///   - `…created_at is immutable…` (P0001) — the push boundary now scrubs
  ///     `created_at` for ledger voids (`_ledgerCreatedAtScrubTables`, S134),
  ///     so a re-push no longer trips the immutable-column trigger.
  /// Everything else (duplicate order number 23505, RLS / insufficient
  /// privilege, invalid_parameter_value) stays manual-only — a blind retry
  /// would just re-orphan and churn the cloud.
  static bool _isAutoRecoverableReason(String reason) {
    return reason.startsWith('fk_deferred_cap_reached') ||
        reason.contains('created_at is immutable');
  }

  /// Per-orphan auto-recovery cap. After this many automatic re-enqueues a
  /// still-failing orphan is parked for manual review so it can't loop on the
  /// sweep forever. Survives re-orphaning via [SyncQueue.autoRetryCount].
  static const autoRecoverCap = 3;

  /// Automatic orphan recovery sweep (§6.8.1). Re-enqueues every orphan whose
  /// cause is on the self-healing allowlist and whose auto-retry budget is not
  /// yet spent. Returns the number re-enqueued so the caller can decide whether
  /// to kick a push. Driven by the periodic drain tick and connectivity
  /// recovery — never blind-retries terminal failures.
  Future<int> autoRecoverDueOrphans({int limit = 50}) async {
    final candidates =
        await (select(syncQueueOrphans)
              ..where((t) => t.autoRetryCount.isSmallerThanValue(autoRecoverCap))
              ..orderBy([(t) => OrderingTerm.asc(t.movedAt)])
              ..limit(limit))
            .get();
    var recovered = 0;
    for (final orphan in candidates) {
      if (!_isAutoRecoverableReason(orphan.reason)) continue;
      try {
        await transaction(() async {
          await _reenqueueOrphan(
            orphan,
            newAutoRetryCount: orphan.autoRetryCount + 1,
          );
        });
        recovered++;
      } catch (e) {
        // A single undecodable/sessionless orphan must not abort the sweep —
        // skip it (it stays for manual review) and continue.
        debugPrint('[SyncDao] auto-recover skipped orphan ${orphan.id}: $e');
      }
    }
    return recovered;
  }

  /// Shared re-enqueue core for [retryOrphan] and [autoRecoverDueOrphans].
  /// MUST be called inside a transaction. Recovers the businessId from the
  /// payload (table upserts carry `business_id`; domain envelopes carry
  /// `p_business_id`), inserts a fresh sync_queue row, and deletes the orphan.
  Future<void> _reenqueueOrphan(
    SyncQueueOrphanData orphan, {
    required int newAutoRetryCount,
  }) async {
    // sync_queue_orphans has no business_id column; recover it from the
    // payload. Fall back to the session resolver only if neither key is
    // present (legacy orphans).
    String? bid;
    try {
      final decoded = jsonDecode(orphan.payload) as Map<String, dynamic>;
      bid =
          decoded['business_id'] as String? ??
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
        // Re-tags to whoever is signed in now. The orphans table does not
        // carry an auth_user_id; the re-push takes ownership under the
        // current session.
        authUserId: Value(db.currentAuthUserId),
        autoRetryCount: Value(newAutoRetryCount),
      ),
    );
    await (delete(
      syncQueueOrphans,
    )..where((t) => t.id.equals(orphan.id))).go();
  }

  Future<void> discardOrphan(String orphanId) async {
    await (delete(syncQueueOrphans)..where((t) => t.id.equals(orphanId))).go();
  }

  Future<void> enqueueUpsert(String tableName, Insertable row) async {
    // Sync safeguard (CLAUDE.md §5): fail fast on an unknown/typo'd table.
    // The pusher dispatches `<table>:upsert` to `_supabase.from(table)` with
    // no whitelist, so a bad name would silently stick as a failed queue row.
    if (!kEnqueueableTables.contains(tableName)) {
      throw StateError(
        'enqueueUpsert("$tableName"): not a registered synced/cache/businesses '
        'table. Add it to _syncedTenantTables (or kSyncCacheTables) or fix the '
        'table name — CLAUDE.md §5.',
      );
    }
    final payloadMap = serializeInsertable(row);
    // Resolve the queue row's businessId. Prefer the payload's value — it
    // covers the bootstrap case where the very first business/user is being
    // created during onboarding and the session resolver isn't bound yet
    // (the row being enqueued already carries its own tenant). Fall back to
    // the session resolver for normal post-login writes. If neither yields
    // a value there's no tenant context at all; refuse to enqueue rather
    // than insert a poison row that push would later reject.
    final resolvedBid =
        (payloadMap['business_id'] as String?) ?? db.businessIdResolver.call();
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
        await (update(syncQueue)..where((t) => t.id.equals(existingId))).write(
          SyncQueueCompanion(
            payload: Value(payloadJson),
            createdAt: Value(DateTime.now()),
            attempts: const Value(0),
            nextAttemptAt: const Value(null),
            errorMessage: const Value(null),
            authUserId: Value(db.currentAuthUserId),
          ),
        );
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
    // Sync safeguard (CLAUDE.md §5): delete targets are always synced tables
    // (never caches, which the cloud rebuilds from domain responses). Reject
    // an unknown/typo'd name before it sticks as a failed queue row.
    if (!kSyncedTenantTables.contains(tableName)) {
      throw StateError(
        'enqueueDelete("$tableName"): not a registered synced table — '
        'fix the table name or add it to _syncedTenantTables (CLAUDE.md §5).',
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
      final pendingUpsertId = await _findPendingDuplicateId(
        upsertActionType,
        rowId,
      );
      if (pendingUpsertId != null) {
        await (update(
          syncQueue,
        )..where((t) => t.id.equals(pendingUpsertId))).write(
          const SyncQueueCompanion(
            isSynced: Value(true),
            status: Value('completed'),
            nextAttemptAt: Value(null),
          ),
        );
      }

      final existingDeleteId = await _findPendingDuplicateId(
        deleteActionType,
        rowId,
      );
      if (existingDeleteId != null) {
        // Coalesced delete retags to current user — same rationale as
        // the upsert coalesce branch above.
        await (update(
          syncQueue,
        )..where((t) => t.id.equals(existingDeleteId))).write(
          SyncQueueCompanion(
            payload: Value(payloadJson),
            createdAt: Value(DateTime.now()),
            attempts: const Value(0),
            nextAttemptAt: const Value(null),
            errorMessage: const Value(null),
            authUserId: Value(db.currentAuthUserId),
          ),
        );
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
    return (delete(syncQueue)..where(
          (t) => t.status.equals('pending') & t.attempts.isBiggerThanValue(0),
        ))
        .go();
  }
}

@DriftAccessor(tables: [ErrorLogs])
class ErrorLogDao extends DatabaseAccessor<AppDatabase>
    with _$ErrorLogDaoMixin, BusinessScopedDao<AppDatabase> {
  ErrorLogDao(super.db);

  static const int _maxMessage = 500;
  static const int _maxStack = 4000;

  /// Records a caught/uncaught error to the append-only `error_logs` table
  /// (master plan §33 — Reliability and Crash Handling). This is the crash
  /// safety net, so it is fully defensive: it must NEVER throw — any failure
  /// to record is swallowed (the net can't become the thing that breaks).
  ///
  /// Routes through [SyncDao.enqueueUpsert] ONLY when a business is bound. A
  /// pre-login crash has no tenant to scope to, so that row is kept local-only
  /// — it can't be RLS-scoped cloud-side (§33.3). The enqueue call below keeps
  /// the Layer C raw-write scanner green for this method.
  Future<void> logError({
    required String errorType,
    required String message,
    String? stackTrace,
    String? context,
    String? role,
    bool isFatal = false,
    String? appVersion,
    String? platform,
    String? businessId,
    String? userId,
  }) async {
    try {
      // Prefer an explicitly-supplied tenant/user over the live resolver.
      // Session-teardown diagnostics (the `auth.session_lost` /
      // `auth.session_expired_gate` breadcrumbs) fire at the moment the JWT is
      // gone — and on the kick path AFTER `AuthService.value` is nulled — so the
      // resolver returns null there, which would silently keep the row
      // local-only (no enqueue → never release-visible, the exact failure these
      // breadcrumbs exist to avoid). Passing the in-hand local user's tenant
      // keeps the row scoped and durably queued; it flushes on the next
      // authenticated push (e.g. the OTP re-auth the gate itself performs).
      // Nullable still — null before a business is bound (pre-login crash).
      final bid = businessId ?? currentBusinessId;
      final row = ErrorLogsCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: Value(bid),
        userId: Value(userId ?? currentUserId),
        role: Value(role),
        context: Value(context),
        errorType: errorType,
        message: _truncate(message, _maxMessage),
        stackTrace: Value(
          stackTrace == null ? null : _truncate(stackTrace, _maxStack),
        ),
        isFatal: Value(isFatal),
        appVersion: Value(appVersion),
        platform: Value(platform),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await into(errorLogs).insert(row);
      // sync-exempt: pre-login crashes (bid == null) have no tenant to scope to,
      // so they stay local-only; only tenant-scoped rows are pushed (§33.3).
      if (bid != null) {
        await db.syncDao.enqueueUpsert('error_logs', row);
      }
    } catch (_) {
      // The crash safety net must never itself crash. Swallow deliberately.
    }
  }

  static String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';
}

@DriftAccessor(tables: [ActivityLogs])
class ActivityLogDao extends DatabaseAccessor<AppDatabase>
    with _$ActivityLogDaoMixin, BusinessScopedDao<AppDatabase> {
  ActivityLogDao(super.db);

  /// Canonical activity-log write (Ring 0 #2, §24.4). Stores a generic
  /// (entityType, entityId) reference plus optional before/after JSON snapshots
  /// for the detail view. Routes through enqueueUpsert (synced append-only
  /// ledger). New features should call this directly.
  Future<void> logActivity({
    required String action,
    required String description,
    String? staffId,
    String? storeId,
    String? entityType,
    String? entityId,
    Map<String, dynamic>? before,
    Map<String, dynamic>? after,
  }) async {
    final row = ActivityLogsCompanion.insert(
      id: Value(UuidV7.generate()),
      businessId: requireBusinessId(),
      userId: Value(staffId),
      action: action,
      description: description,
      entityType: Value(entityType),
      entityId: Value(entityId),
      beforeJson: Value(before == null ? null : jsonEncode(before)),
      afterJson: Value(after == null ? null : jsonEncode(after)),
      storeId: Value(storeId),
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(activityLogs).insert(row);
    await db.syncDao.enqueueUpsert('activity_logs', row);
  }

  /// Back-compat convenience over [logActivity]: the legacy per-entity params
  /// fold onto the generic (entityType, entityId) pair (the old "<=1 set" CHECK
  /// guaranteed at most one was set). Existing callers and [ActivityLogService]
  /// keep working unchanged; new code should prefer [logActivity] so it can
  /// carry before/after snapshots.
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
    String? entityType;
    String? entityId;
    if (orderId != null) {
      entityType = 'order';
      entityId = orderId;
    } else if (productId != null) {
      entityType = 'product';
      entityId = productId;
    } else if (customerId != null) {
      entityType = 'customer';
      entityId = customerId;
    } else if (expenseId != null) {
      entityType = 'expense';
      entityId = expenseId;
    } else if (deliveryId != null) {
      entityType = 'delivery';
      entityId = deliveryId;
    } else if (walletTxnId != null) {
      entityType = 'wallet_transaction';
      entityId = walletTxnId;
    }
    await logActivity(
      action: action,
      description: description,
      staffId: staffId,
      storeId: storeId,
      entityType: entityType,
      entityId: entityId,
    );
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
                t.entityType.equals('order') &
                t.entityId.equals(orderId) &
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
                t.entityType.equals('product') &
                t.entityId.equals(productId) &
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
                t.entityType.equals('customer') &
                t.entityId.equals(customerId) &
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
                t.entityType.equals('expense') &
                t.entityId.equals(expenseId) &
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
                t.entityType.equals('delivery') &
                t.entityId.equals(deliveryId) &
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
                t.entityType.equals('wallet_transaction') &
                t.entityId.equals(walletTxnId) &
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

  /// Edit an existing store's name / address (§10.1 Stores). Business-scoped
  /// (a device can hold more than one business's stores) and routed through
  /// the sync queue so the change reaches the cloud + other devices. `stores`
  /// is a synced tenant table, so this is the only correct write path.
  /// An empty [location] clears the stored address (nullable column).
  Future<void> updateStore({
    required String id,
    String? name,
    String? location,
  }) async {
    await (update(
      stores,
    )..where((t) => t.id.equals(id) & whereBusiness(t))).write(
      StoresCompanion(
        name: name == null ? const Value.absent() : Value(name),
        location: location == null
            ? const Value.absent()
            : Value(location.isEmpty ? null : location),
        lastUpdatedAt: Value(DateTime.now()),
      ),
    );
    final row = await (select(
      stores,
    )..where((t) => t.id.equals(id))).getSingle();
    await db.syncDao.enqueueUpsert('stores', row);
  }

  /// Edit a user's own display name / avatar colour (profile, §10.1-adjacent).
  /// Routed through the sync queue so the change reaches the cloud + other
  /// devices (name is in the `users` push whitelist). Not business-scoped —
  /// the caller passes their own user id.
  Future<void> updateUserProfile({
    required String id,
    String? name,
    String? avatarColor,
  }) async {
    await (update(users)..where((t) => t.id.equals(id))).write(
      UsersCompanion(
        name: name == null ? const Value.absent() : Value(name),
        avatarColor: avatarColor == null
            ? const Value.absent()
            : Value(avatarColor),
        lastUpdatedAt: Value(DateTime.now()),
      ),
    );
    final row = await (select(
      users,
    )..where((t) => t.id.equals(id))).getSingle();
    await db.syncDao.enqueueUpsert('users', row);
  }

  Future<UserData?> getUserById(String id) {
    // deliberately not businessId-scoped
    return (select(users)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  Future<UserData?> getUserByEmail(
    String email, {
    String? preferredBusinessId,
  }) async {
    // Deliberately NOT businessId-scoped — login happens before a session
    // exists. Users has UNIQUE(business_id, email), so a single email can hold
    // one local row PER business (multi-business account / staff re-invite).
    // Tolerate >1 row instead of crashing (getSingleOrNull throws on multi-row,
    // which would kill the sign-in / upsertLocalUserFromProfile rebuild): prefer
    // the row for the active/cloud business, else the most-recently-updated.
    final rows = await (select(
      users,
    )..where((t) => t.email.equals(email))).get();
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

  /// Users belonging to the CURRENT business — business-scoped read for the
  /// Home staff-sales name lookup. The device can hold more than one business's
  /// users, so this must never be a bare `select(users)` (business-scoping
  /// invariant — CLAUDE.md). Runs post-login, so the session resolver is bound.
  Future<List<UserData>> getUsersForCurrentBusiness() {
    return (select(users)..where((t) => whereBusiness(t))).get();
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

  /// Canonical notification write (Ring 0 #2, §26.2/§26.4). Sets [severity]
  /// (info/warning/alert) for the card colour; [recipientUserId] null =
  /// broadcast to every member. Routes through enqueueUpsert (synced). New
  /// features fire their §26.4 events through this helper.
  Future<void> fireNotification({
    required String type,
    required String message,
    String severity = 'info',
    String? linkedRecordId,
    String? recipientUserId,
  }) async {
    final row = NotificationsCompanion.insert(
      id: Value(UuidV7.generate()),
      businessId: requireBusinessId(),
      type: type,
      message: message,
      severity: Value(severity),
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
    final row = await (select(
      notifications,
    )..where((t) => t.id.equals(id) & whereBusiness(t))).getSingleOrNull();
    if (row != null) {
      await db.syncDao.enqueueUpsert('notifications', row.toCompanion(true));
    }
  }

  Future<void> markAllRead() async {
    final now = DateTime.now();
    final unread =
        await (select(notifications)..where(
              (t) =>
                  whereBusiness(t) &
                  _whereForCurrentUser(t) &
                  t.isRead.equals(false),
            ))
            .get();
    if (unread.isEmpty) return;

    await (update(
      notifications,
    )..where((t) => whereBusiness(t) & _whereForCurrentUser(t))).write(
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
        notif
            .toCompanion(true)
            .copyWith(isRead: const Value(true), lastUpdatedAt: Value(now)),
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
    final allNotifs = await (select(
      notifications,
    )..where((t) => whereBusiness(t) & _whereForCurrentUser(t))).get();
    await (delete(
      notifications,
    )..where((t) => whereBusiness(t) & _whereForCurrentUser(t))).go();
    for (final n in allNotifs) {
      await db.syncDao.enqueueDelete('notifications', n.id);
    }
  }
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
  ///
  /// Local: writes two store-stamped crate_ledger rows and updates
  /// store_crate_balances for immediate UI feedback. Cloud: a single atomic
  /// `domain:pos_transfer_crates` envelope (idempotent via ledger IDs).
  /// store_crate_balances is NOT separately enqueued — the domain RPC is the
  /// sole cloud writer (prevents double-count).
  Future<void> transferCrates({
    required String transferId,
    required String fromStoreId,
    required String toStoreId,
    required String manufacturerId,
    required int quantity,
    required String performedBy,
  }) async {
    final bizId = requireBusinessId();
    final outLedgerId = UuidV7.generate();
    final inLedgerId = UuidV7.generate();
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    await transaction(() async {
      // 1. Local crate_ledger rows (append-only; store-stamped §v44).
      await customStatement(
        'INSERT INTO crate_ledger '
        '  (id, business_id, manufacturer_id, store_id, '
        '   quantity_delta, movement_type, performed_by, created_at, last_updated_at) '
        'VALUES (?,?,?,?,?,?,?,?,?)',
        [
          outLedgerId,
          bizId,
          manufacturerId,
          fromStoreId,
          -quantity,
          'transferred_out',
          performedBy,
          nowSec,
          nowSec,
        ],
      );
      await customStatement(
        'INSERT INTO crate_ledger '
        '  (id, business_id, manufacturer_id, store_id, '
        '   quantity_delta, movement_type, performed_by, created_at, last_updated_at) '
        'VALUES (?,?,?,?,?,?,?,?,?)',
        [
          inLedgerId,
          bizId,
          manufacturerId,
          toStoreId,
          quantity,
          'transferred_in',
          performedBy,
          nowSec,
          nowSec,
        ],
      );

      // 2. Local store_crate_balances — immediate UI feedback only.
      //    NOT enqueued directly; the domain RPC is the sole cloud writer.
      await customStatement(
        'INSERT INTO store_crate_balances '
        '  (id, business_id, store_id, manufacturer_id, balance, last_updated_at) '
        'VALUES (?,?,?,?,?,?) '
        'ON CONFLICT(business_id, store_id, manufacturer_id) DO UPDATE SET '
        '  balance = balance + excluded.balance, '
        '  last_updated_at = excluded.last_updated_at',
        [
          UuidV7.generate(),
          bizId,
          fromStoreId,
          manufacturerId,
          -quantity,
          nowSec,
        ],
      );
      await customStatement(
        'INSERT INTO store_crate_balances '
        '  (id, business_id, store_id, manufacturer_id, balance, last_updated_at) '
        'VALUES (?,?,?,?,?,?) '
        'ON CONFLICT(business_id, store_id, manufacturer_id) DO UPDATE SET '
        '  balance = balance + excluded.balance, '
        '  last_updated_at = excluded.last_updated_at',
        [UuidV7.generate(), bizId, toStoreId, manufacturerId, quantity, nowSec],
      );

      // 3. Enqueue the domain RPC (handles cloud crate_ledger + store_crate_balances atomically).
      final payload = <String, dynamic>{
        'p_business_id': bizId,
        'p_actor_id': performedBy,
        'p_transfer_id': transferId,
        'p_from_store_id': fromStoreId,
        'p_to_store_id': toStoreId,
        'p_manufacturer_id': manufacturerId,
        'p_quantity': quantity,
        'p_out_ledger_id': outLedgerId,
        'p_in_ledger_id': inLedgerId,
      };
      await db.syncDao.enqueue(
        'domain:pos_transfer_crates',
        jsonEncode(payload),
      );
    });
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

@DriftAccessor(tables: [PendingCrateReturns])
class PendingCrateReturnsDao extends DatabaseAccessor<AppDatabase>
    with _$PendingCrateReturnsDaoMixin, BusinessScopedDao<AppDatabase> {
  PendingCrateReturnsDao(super.db);

  Future<String> createPendingReturn({
    required String? orderId,
    required String customerId,
    required String submittedBy,
    required String manufacturerId,
    required int quantity,
  }) async {
    final id = UuidV7.generate();
    final row = PendingCrateReturnsCompanion.insert(
      id: Value(id),
      businessId: requireBusinessId(),
      orderId: Value(orderId),
      customerId: customerId,
      manufacturerId: manufacturerId,
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
    final row = await (select(
      pendingCrateReturns,
    )..where((t) => t.id.equals(id) & whereBusiness(t))).getSingleOrNull();
    if (row != null) {
      await db.syncDao.enqueueUpsert(
        'pending_crate_returns',
        row.toCompanion(true),
      );
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
    final now = DateTime.now();

    // Reuse the existing active session for this device+user instead of minting
    // a fresh row on every re-auth (biometric unlock, PIN re-entry, Switch
    // User, app resume). Each `sessions` row is an idempotent, low-value
    // single-active-session record that must still sync; on a device that
    // re-auths while offline, minting a new id each time produces a *separate*
    // outbox row per login (different payload.id → enqueueUpsert can't coalesce
    // them), so they pile up in Sync Issues and burn retries for sessions that
    // no longer matter. Reusing the id collapses every re-auth push into the
    // one coalesced pending row for this device+user, and bumping the expiry
    // gives the session a sliding TTL window across active days.
    //
    // A revoked (kicked / logged-out) or expired session is NOT reused — a real
    // re-login after a kick legitimately starts a new session. Without a
    // deviceId we can't identify the device, so fall back to minting.
    if (deviceId != null) {
      final existing =
          await (select(sessions)
                ..where(
                  (t) =>
                      t.userId.equals(userId) &
                      t.deviceId.equals(deviceId) &
                      whereBusiness(t) &
                      t.revokedAt.isNull() &
                      t.expiresAt.isBiggerThanValue(now),
                )
                ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
                ..limit(1))
              .getSingleOrNull();
      if (existing != null) {
        await (update(sessions)..where((t) => t.id.equals(existing.id))).write(
          SessionsCompanion(
            expiresAt: Value(now.add(ttl)),
            lastUpdatedAt: Value(now),
          ),
        );
        // Full-row re-enqueue (same id) so the refreshed expiry reaches the
        // cloud. enqueueUpsert coalesces by (action_type, payload.id), so this
        // collapses into any still-pending push for this row rather than adding
        // another. Mirrors revokeSession's update-then-full-row-enqueue.
        final refreshed =
            await (select(sessions)
                  ..where((t) => t.id.equals(existing.id)))
                .getSingleOrNull();
        if (refreshed != null) {
          await db.syncDao.enqueueUpsert(
            'sessions',
            refreshed.toCompanion(true),
          );
        }
        return existing.id;
      }
    }

    final id = UuidV7.generate();
    // createdAt is set explicitly (not left to the column's SQL default) so the
    // enqueued companion carries it into the cloud push. Otherwise the pushed
    // payload omits created_at and the cloud's NOT NULL constraint rejects the
    // upsert (23502). Same explicit-value rule as the id in synced writes.
    final row = SessionsCompanion.insert(
      id: Value(id),
      businessId: businessId,
      userId: userId,
      expiresAt: now.add(ttl),
      userAgent: Value(userAgent),
      ipAddress: Value(ipAddress),
      deviceId: Value(deviceId),
      createdAt: Value(now),
      lastUpdatedAt: Value(now),
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
    final row =
        await (select(sessions)
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
        s
            .toCompanion(true)
            .copyWith(revokedAt: Value(now), lastUpdatedAt: Value(now)),
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
    final row =
        await (attachedDatabase.select(attachedDatabase.customers)
              ..where((t) => t.id.equals(customerId) & whereBusiness(t)))
            .getSingleOrNull();
    if (row != null) {
      await db.syncDao.enqueueUpsert('customers', row.toCompanion(true));
    }
  }
}

/// §13.4 Ring 7 — business-wide crate-deposit balancing figures (all kobo).
/// Invariant: `heldKobo == takenKobo - refundedKobo - keptKobo`.
class CrateDepositSummary {
  final int takenKobo; // total deposits ever collected
  final int refundedKobo; // total refunded back to customers
  final int keptKobo; // total forfeited (income)
  final int heldKobo; // deposits still being held now

  const CrateDepositSummary({
    required this.takenKobo,
    required this.refundedKobo,
    required this.keptKobo,
    required this.heldKobo,
  });
}

@DriftAccessor(
  tables: [WalletTransactions, CustomerWallets, PaymentTransactions, Orders],
)
class WalletTransactionsDao extends DatabaseAccessor<AppDatabase>
    with _$WalletTransactionsDaoMixin, BusinessScopedDao<AppDatabase> {
  WalletTransactionsDao(super.db);

  /// Computes the current SPENDABLE wallet balance by summing signed amounts,
  /// EXCLUDING the crate-deposit family (§13.4 decision 13: a refundable deposit
  /// is money held for the customer — never their spendable credit nor their
  /// debt). Use [getDepositsHeldKobo] for the held-deposit figure.
  /// Per PR 4d "Recommended void approach", we don't filter by voidedAt IS NULL
  /// because a compensating entry (opposite sign) will have been appended.
  Future<int> getBalanceKobo(String customerId) async {
    final sumExpr = walletTransactions.signedAmountKobo.sum();
    final query = selectOnly(walletTransactions)
      ..addColumns([sumExpr])
      ..where(
        whereBusiness(walletTransactions) &
            walletTransactions.customerId.equals(customerId) &
            walletTransactions.referenceType.isNotIn(
              kCrateDepositReferenceTypes,
            ),
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
            walletTransactions.customerId.equals(customerId) &
            walletTransactions.referenceType.isNotIn(
              kCrateDepositReferenceTypes,
            ),
      );
    return query.watchSingleOrNull().map((row) => row?.read(sumExpr) ?? 0);
  }

  Stream<Map<String, int>> watchAllBalancesKobo() {
    final sumExpr = walletTransactions.signedAmountKobo.sum();
    final query = selectOnly(walletTransactions)
      ..addColumns([walletTransactions.customerId, sumExpr])
      ..where(
        whereBusiness(walletTransactions) &
            walletTransactions.referenceType.isNotIn(
              kCrateDepositReferenceTypes,
            ),
      )
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

  /// §13.4 decision 15 — the crate deposit "held" for a customer: SUM(signed)
  /// over the crate-deposit family ([kCrateDepositReferenceTypes]). A
  /// `crate_deposit` credit, minus its later `crate_deposit_refunded` /
  /// `crate_deposit_forfeited` debit, nets to 0 once the deposit is resolved —
  /// so this is exactly `taken − refunds − kept`. Shown beside the spendable
  /// balance on the wallet screen (decision 14).
  Future<int> getDepositsHeldKobo(String customerId) async {
    final sumExpr = walletTransactions.signedAmountKobo.sum();
    final query = selectOnly(walletTransactions)
      ..addColumns([sumExpr])
      ..where(
        whereBusiness(walletTransactions) &
            walletTransactions.customerId.equals(customerId) &
            walletTransactions.referenceType.isIn(kCrateDepositReferenceTypes),
      );
    final row = await query.getSingleOrNull();
    return row?.read(sumExpr) ?? 0;
  }

  Stream<int> watchDepositsHeldKobo(String customerId) {
    final sumExpr = walletTransactions.signedAmountKobo.sum();
    final query = selectOnly(walletTransactions)
      ..addColumns([sumExpr])
      ..where(
        whereBusiness(walletTransactions) &
            walletTransactions.customerId.equals(customerId) &
            walletTransactions.referenceType.isIn(kCrateDepositReferenceTypes),
      );
    return query.watchSingleOrNull().map((row) => row?.read(sumExpr) ?? 0);
  }

  /// §13.4 Ring 7 — business-wide crate-deposit balancing figures (kobo), summed
  /// over the whole `wallet_transactions` deposit family:
  ///   taken    = every `crate_deposit` credit collected,
  ///   refunded = every `crate_deposit_refunded` given back (positive abs),
  ///   kept     = every `crate_deposit_forfeited` income (positive abs),
  ///   held     = taken − refunded − kept = deposits still being held.
  /// By construction `held` equals the per-customer held figures summed, because
  /// each refund/forfeit appends an offsetting deposit-family debit.
  Stream<CrateDepositSummary> watchCrateDepositSummary() {
    final sumExpr = walletTransactions.signedAmountKobo.sum();
    final query = selectOnly(walletTransactions)
      ..addColumns([walletTransactions.referenceType, sumExpr])
      ..where(
        whereBusiness(walletTransactions) &
            walletTransactions.referenceType.isIn(kCrateDepositReferenceTypes),
      )
      ..groupBy([walletTransactions.referenceType]);
    return query.watch().map((rows) {
      int taken = 0, refundedSigned = 0, keptSigned = 0;
      for (final r in rows) {
        final ref = r.read(walletTransactions.referenceType);
        final v = r.read(sumExpr) ?? 0;
        if (ref == 'crate_deposit') {
          taken = v;
        } else if (ref == 'crate_deposit_refunded') {
          refundedSigned = v; // negative (debits)
        } else if (ref == 'crate_deposit_forfeited') {
          keptSigned = v; // negative (debits)
        }
      }
      return CrateDepositSummary(
        takenKobo: taken,
        refundedKobo: -refundedSigned,
        keptKobo: -keptSigned,
        heldKobo: taken + refundedSigned + keptSigned,
      );
    });
  }

  /// §13.4 Ring 7 — per-customer held deposit (kobo), customers with a non-zero
  /// held balance only. Drives the report's customer breakdown.
  Stream<Map<String, int>> watchDepositsHeldByCustomer() {
    final sumExpr = walletTransactions.signedAmountKobo.sum();
    final query = selectOnly(walletTransactions)
      ..addColumns([walletTransactions.customerId, sumExpr])
      ..where(
        whereBusiness(walletTransactions) &
            walletTransactions.referenceType.isIn(kCrateDepositReferenceTypes),
      )
      ..groupBy([walletTransactions.customerId]);
    return query.watch().map((rows) {
      final map = <String, int>{};
      for (final r in rows) {
        final cid = r.read(walletTransactions.customerId);
        final v = r.read(sumExpr) ?? 0;
        if (cid != null && v != 0) map[cid] = v;
      }
      return map;
    });
  }

  Stream<List<WalletTransactionData>> watchHistory(String customerId) {
    return (select(walletTransactions)
          ..where((t) => whereBusiness(t) & t.customerId.equals(customerId))
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
            // §13.4 — a crate-return settlement posts its `crate_refund` credit
            // (the spendable "money back" the customer sees on the receipt) and
            // its paired `crate_deposit_refunded`/`_forfeited` bookkeeping debits
            // in the SAME second. Float crate_refund to the top of its group so
            // the headline credit reads first. An INT CASE expr (0 before 1
            // under ASC), not a bare boolean — the boolean form was unreliable
            // in ORDER BY (see the signed-amount note below).
            (t) => OrderingTerm(
              expression: const CustomExpression<int>(
                "CASE WHEN reference_type = 'crate_refund' THEN 0 ELSE 1 END",
              ),
              mode: OrderingMode.asc,
            ),
            // §14.3 (bug #3) — newest activity first. A sale's two legs share
            // the same second (created_at is second-resolution + createOrder
            // stamps both legs the same instant), so this tiebreak decides their
            // order. signed_amount_kobo ASC puts the order DEBIT (negative,
            // "money out" — the LAST step of the sale) ABOVE the payment CREDIT
            // (positive, "money in"). A real numeric column → deterministic
            // across SQLite backends, unlike a boolean-expr tiebreak (a no-op in
            // ORDER BY → fell back to rowid order, which differed in-memory vs
            // the on-device file DB) or the random-tailed UuidV7 id.
            (t) => OrderingTerm(
              expression: t.signedAmountKobo,
              mode: OrderingMode.asc,
            ),
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
    final flagValue = await db.systemConfigDao.get(
      'feature.domain_rpcs_v2.void_wallet_txn',
    );
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
        await db.syncDao.enqueue(
          'domain:pos_void_wallet_txn',
          jsonEncode(payload),
        );
      } else {
        final updatedOrig =
            await (select(walletTransactions)
                  ..where((t) => t.id.equals(transactionId))
                  ..limit(1))
                .getSingle();
        await db.syncDao.enqueueUpsert('wallet_transactions', updatedOrig);
        await db.syncDao.enqueueUpsert('wallet_transactions', compComp);
      }
    });
  }
}

/// §21.10 — append-only supplier ledger. Mirrors [WalletTransactionsDao] but
/// inverted (invoice = debit, payment = credit) and with no crate-deposit split:
/// the balance is a plain SUM(signed_amount_kobo). Negative = we owe the supplier.
@DriftAccessor(tables: [SupplierLedgerEntries, Suppliers])
class SupplierLedgerDao extends DatabaseAccessor<AppDatabase>
    with _$SupplierLedgerDaoMixin, BusinessScopedDao<AppDatabase> {
  SupplierLedgerDao(super.db);

  /// §21.11 — when [storeId] is non-null, scope to that store's entries; null =
  /// business-wide ("All Stores" aggregate).
  Expression<bool> _scope(String? storeId) {
    final base = whereBusiness(supplierLedgerEntries);
    return storeId == null
        ? base
        : base & supplierLedgerEntries.storeId.equals(storeId);
  }

  /// Current balance (kobo). SUM(signed): payments (credit, +) minus invoices
  /// (debit, −). Negative = we owe the supplier. Like the wallet, we don't filter
  /// voidedAt — a void appends an opposite-sign compensating entry. [storeId]
  /// scopes to one store (§21.11); null = business-wide.
  Future<int> getBalanceKobo(String supplierId, {String? storeId}) async {
    final sumExpr = supplierLedgerEntries.signedAmountKobo.sum();
    final query = selectOnly(supplierLedgerEntries)
      ..addColumns([sumExpr])
      ..where(
        _scope(storeId) & supplierLedgerEntries.supplierId.equals(supplierId),
      );
    final row = await query.getSingleOrNull();
    return row?.read(sumExpr) ?? 0;
  }

  Stream<int> watchBalanceKobo(String supplierId, {String? storeId}) {
    final sumExpr = supplierLedgerEntries.signedAmountKobo.sum();
    final query = selectOnly(supplierLedgerEntries)
      ..addColumns([sumExpr])
      ..where(
        _scope(storeId) & supplierLedgerEntries.supplierId.equals(supplierId),
      );
    return query.watchSingleOrNull().map((row) => row?.read(sumExpr) ?? 0);
  }

  /// supplierId → balance (kobo), for the Suppliers list. Drives the live
  /// red/negative balance chip per supplier. [storeId] scopes per store (§21.11).
  Stream<Map<String, int>> watchAllBalancesKobo({String? storeId}) {
    final sumExpr = supplierLedgerEntries.signedAmountKobo.sum();
    final query = selectOnly(supplierLedgerEntries)
      ..addColumns([supplierLedgerEntries.supplierId, sumExpr])
      ..where(_scope(storeId))
      ..groupBy([supplierLedgerEntries.supplierId]);
    return query.watch().map((rows) {
      final out = <String, int>{};
      for (final r in rows) {
        final sid = r.read(supplierLedgerEntries.supplierId);
        final sum = r.read(sumExpr);
        if (sid != null) out[sid] = sum ?? 0;
      }
      return out;
    });
  }

  /// Ledger history for one supplier, newest first. Same deterministic tiebreak
  /// as the wallet: createdAt DESC, then signedAmountKobo ASC (invoice debit
  /// above payment credit when posted the same second). [storeId] scopes per
  /// store (§21.11); null = business-wide.
  Stream<List<SupplierLedgerEntryData>> watchHistory(
    String supplierId, {
    String? storeId,
  }) {
    return (select(supplierLedgerEntries)
          ..where((t) => _scope(storeId) & t.supplierId.equals(supplierId))
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

  /// Every ledger entry across all suppliers, newest first — drives the
  /// "Transaction history" screen. Same deterministic tiebreak as watchHistory.
  /// [storeId] scopes per store (§21.11); null = business-wide.
  Stream<List<SupplierLedgerEntryData>> watchAllHistory({String? storeId}) {
    return (select(supplierLedgerEntries)
          ..where((t) => _scope(storeId))
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

  /// Voids an entry by marking the original voided AND appending an opposite-sign
  /// `void` compensating entry (append-only — §21.7, CEO only at the UI). Plain
  /// enqueue path (no domain RPC in Phase 1).
  /// Returns true when a void was actually applied; false when the entry was
  /// missing or already voided (Section 10.11 — double-void is a no-op).
  Future<bool> voidEntry({
    required String entryId,
    required String voidedBy,
    required String reason,
  }) async {
    return transaction(() async {
      final original =
          await (select(supplierLedgerEntries)
                ..where((t) => t.id.equals(entryId))
                ..limit(1))
              .getSingleOrNull();
      if (original == null) return false;
      if (original.voidedAt != null) return false; // Already voided

      final now = DateTime.now();
      await (update(
        supplierLedgerEntries,
      )..where((t) => t.id.equals(entryId))).write(
        SupplierLedgerEntriesCompanion(
          voidedAt: Value(now),
          voidedBy: Value(voidedBy),
          voidReason: Value(reason),
          lastUpdatedAt: Value(now),
        ),
      );

      final compId = UuidV7.generate();
      final compComp = SupplierLedgerEntriesCompanion.insert(
        id: Value(compId),
        businessId: requireBusinessId(),
        supplierId: original.supplierId,
        // §21.11 — net the same store the original was recorded against.
        storeId: Value(original.storeId),
        type: original.type == 'credit' ? 'debit' : 'credit',
        amountKobo: original.amountKobo,
        signedAmountKobo: -original.signedAmountKobo,
        referenceType: 'void',
        activityDate: now,
        performedBy: Value(voidedBy),
        referenceNote: Value(reason),
        createdAt: Value(now),
        lastUpdatedAt: Value(now),
      );
      await into(supplierLedgerEntries).insert(compComp);

      final updatedOrig =
          await (select(supplierLedgerEntries)
                ..where((t) => t.id.equals(entryId))
                ..limit(1))
              .getSingle();
      await db.syncDao.enqueueUpsert('supplier_ledger_entries', updatedOrig);
      await db.syncDao.enqueueUpsert('supplier_ledger_entries', compComp);
      return true;
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

@DriftAccessor(tables: [CustomerCrateBalances, Manufacturers])
class CustomerCrateBalancesDao extends DatabaseAccessor<AppDatabase>
    with _$CustomerCrateBalancesDaoMixin, BusinessScopedDao<AppDatabase> {
  CustomerCrateBalancesDao(super.db);

  Stream<List<CustomerCrateBalanceWithManufacturer>> watchByCustomer(
    String customerId,
  ) {
    final query = select(customerCrateBalances).join([
      innerJoin(
        manufacturers,
        manufacturers.id.equalsExp(customerCrateBalances.manufacturerId),
      ),
    ]);
    query.where(
      whereBusiness(customerCrateBalances) &
          customerCrateBalances.customerId.equals(customerId),
    );

    return query.watch().map((rows) {
      return rows.map((row) {
        return CustomerCrateBalanceWithManufacturer(
          balance: row.readTable(customerCrateBalances),
          manufacturer: row.readTable(manufacturers),
        );
      }).toList();
    });
  }
}

class CustomerCrateBalanceWithManufacturer {
  final CustomerCrateBalance balance;
  final ManufacturerData manufacturer;
  CustomerCrateBalanceWithManufacturer({
    required this.balance,
    required this.manufacturer,
  });
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

@DriftAccessor(tables: [ManufacturerCrateBalances])
class ManufacturerCrateBalancesDao extends DatabaseAccessor<AppDatabase>
    with _$ManufacturerCrateBalancesDaoMixin, BusinessScopedDao<AppDatabase> {
  ManufacturerCrateBalancesDao(super.db);

  /// v29: one balance per manufacturer (the crate-size dimension was dropped).
  Stream<List<ManufacturerCrateBalance>> watchByManufacturer(
    String manufacturerId,
  ) {
    return (select(manufacturerCrateBalances)..where(
          (t) => whereBusiness(t) & t.manufacturerId.equals(manufacturerId),
        ))
        .watch();
  }
}

@DriftAccessor(tables: [StoreCrateBalances])
class StoreCrateBalancesDao extends DatabaseAccessor<AppDatabase>
    with _$StoreCrateBalancesDaoMixin, BusinessScopedDao<AppDatabase> {
  StoreCrateBalancesDao(super.db);

  /// Current balance for one (store, manufacturer) pair. Returns 0 if absent.
  Future<int> getBalance({
    required String storeId,
    required String manufacturerId,
  }) async {
    final row =
        await (select(storeCrateBalances)..where(
              (t) =>
                  whereBusiness(t) &
                  t.storeId.equals(storeId) &
                  t.manufacturerId.equals(manufacturerId),
            ))
            .getSingleOrNull();
    return row?.balance ?? 0;
  }

  /// Per-store crate balance for a manufacturer (§16.8.1).
  Stream<List<StoreCrateBalanceData>> watchForStore(String storeId) {
    return (select(
      storeCrateBalances,
    )..where((t) => whereBusiness(t) & t.storeId.equals(storeId))).watch();
  }

  /// UPSERT a store's crate balance for [manufacturerId] by [delta].
  ///
  /// Positive delta = crates arriving; negative = crates leaving.
  /// The caller is responsible for ensuring source balance doesn't go negative.
  Future<void> applyDelta({
    required String storeId,
    required String manufacturerId,
    required int delta,
  }) async {
    await customInsert(
      'INSERT INTO store_crate_balances '
      '  (id, business_id, store_id, manufacturer_id, balance) '
      'VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(business_id, store_id, manufacturer_id) DO UPDATE SET '
      '  balance = balance + excluded.balance, '
      "  last_updated_at = CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)",
      variables: [
        Variable(UuidV7.generate()),
        Variable(requireBusinessId()),
        Variable(storeId),
        Variable(manufacturerId),
        Variable(delta),
      ],
      updates: {storeCrateBalances},
    );
    // Enqueue the updated cache row for cloud push.
    final row =
        await (select(storeCrateBalances)..where(
              (t) =>
                  whereBusiness(t) &
                  t.storeId.equals(storeId) &
                  t.manufacturerId.equals(manufacturerId),
            ))
            .getSingleOrNull();
    if (row != null) {
      await db.syncDao.enqueueUpsert(
        'store_crate_balances',
        row.toCompanion(true),
      );
    }
  }

  /// Absolute set — used by the per-store management dialog.
  Future<void> setBalance({
    required String storeId,
    required String manufacturerId,
    required int newBalance,
  }) async {
    await customInsert(
      'INSERT INTO store_crate_balances '
      '  (id, business_id, store_id, manufacturer_id, balance) '
      'VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(business_id, store_id, manufacturer_id) DO UPDATE SET '
      '  balance = excluded.balance, '
      "  last_updated_at = CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)",
      variables: [
        Variable(UuidV7.generate()),
        Variable(requireBusinessId()),
        Variable(storeId),
        Variable(manufacturerId),
        Variable(newBalance),
      ],
      updates: {storeCrateBalances},
    );
    final row =
        await (select(storeCrateBalances)..where(
              (t) =>
                  whereBusiness(t) &
                  t.storeId.equals(storeId) &
                  t.manufacturerId.equals(manufacturerId),
            ))
            .getSingleOrNull();
    if (row != null) {
      await db.syncDao.enqueueUpsert(
        'store_crate_balances',
        row.toCompanion(true),
      );
    }
  }
}

@DriftAccessor(
  tables: [CrateLedger, CustomerCrateBalances, ManufacturerCrateBalances],
)
class CrateLedgerDao extends DatabaseAccessor<AppDatabase>
    with _$CrateLedgerDaoMixin, BusinessScopedDao<AppDatabase> {
  CrateLedgerDao(super.db);

  Future<void> recordCrateReturnByManufacturer({
    required String manufacturerId,
    required int quantity,
    required String performedBy,
    String? storeId,
  }) async {
    final delta = -quantity; // returning empties reduces our balance

    final flagValue = await db.systemConfigDao.get(
      'feature.domain_rpcs_v2.record_crate_return',
    );
    final useDomainRpc = flagValue == 'true' || flagValue == '"true"';

    await transaction(() async {
      // 1. Append crate_ledger entry. v29: keyed by manufacturer (owner =
      // manufacturer here, so customer_id is null); crate_size_group_id null.
      // v44 (§16.8.1): stamp store_id for per-store tracking.
      final ledgerId = UuidV7.generate();
      final ledgerComp = CrateLedgerCompanion.insert(
        id: Value(ledgerId),
        businessId: requireBusinessId(),
        manufacturerId: Value(manufacturerId),
        storeId: Value(storeId),
        quantityDelta: delta,
        movementType: 'returned',
        performedBy: Value(performedBy),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await into(crateLedger).insert(ledgerComp);

      // 2. Update manufacturer_crate_balances cache (always — UI reads this).
      // customInsert (not customStatement) so Drift invalidates the watching
      // streams on commit — a raw customStatement write is invisible to the
      // stream tracker, which left the Crates tab stale after a return.
      await customInsert(
        'INSERT INTO manufacturer_crate_balances (id, business_id, manufacturer_id, balance) '
        'VALUES (?, ?, ?, ?) '
        'ON CONFLICT(business_id, manufacturer_id) DO UPDATE SET '
        'balance = balance + excluded.balance, '
        'last_updated_at = CAST(strftime(\'%s\', CURRENT_TIMESTAMP) AS INTEGER)',
        variables: [
          Variable(UuidV7.generate()),
          Variable(requireBusinessId()),
          Variable(manufacturerId),
          Variable(delta),
        ],
        updates: {manufacturerCrateBalances},
      );

      // 2b. Update per-store cache if a storeId is provided (§16.8.1).
      if (storeId != null) {
        await db.storeCrateBalancesDao.applyDelta(
          storeId: storeId,
          manufacturerId: manufacturerId,
          delta: delta,
        );
      }

      if (useDomainRpc) {
        final payload = <String, dynamic>{
          'p_business_id': requireBusinessId(),
          'p_actor_id': performedBy,
          'p_ledger_id': ledgerId,
          'p_owner_kind': 'manufacturer',
          'p_owner_id': manufacturerId,
          'p_manufacturer_id': manufacturerId,
          'p_quantity_delta': delta,
          'p_movement_type': 'returned',
        };
        await db.syncDao.enqueue(
          'domain:pos_record_crate_return',
          jsonEncode(payload),
        );
      } else {
        await db.syncDao.enqueueUpsert('crate_ledger', ledgerComp);
        final updatedBalance =
            await (select(manufacturerCrateBalances)
                  ..where(
                    (t) =>
                        whereBusiness(t) &
                        t.manufacturerId.equals(manufacturerId),
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
    required String manufacturerId,
    required int quantity,
    required String performedBy,
    String? orderId,
  }) async {
    final delta = -quantity; // customer returning reduces balance

    final flagValue = await db.systemConfigDao.get(
      'feature.domain_rpcs_v2.record_crate_return',
    );
    final useDomainRpc = flagValue == 'true' || flagValue == '"true"';

    await transaction(() async {
      // v29: a customer crate row sets BOTH customer_id (owner) AND
      // manufacturer_id (whose crates), keyed by manufacturer. crate_size_group
      // is null (vestigial).
      final ledgerId = UuidV7.generate();
      final ledgerComp = CrateLedgerCompanion.insert(
        id: Value(ledgerId),
        businessId: requireBusinessId(),
        customerId: Value(customerId),
        manufacturerId: Value(manufacturerId),
        quantityDelta: delta,
        movementType: 'returned',
        referenceOrderId: Value(orderId),
        performedBy: Value(performedBy),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await into(crateLedger).insert(ledgerComp);

      // customInsert (not customStatement) so the watching streams refresh.
      await customInsert(
        'INSERT INTO customer_crate_balances (id, business_id, customer_id, manufacturer_id, balance) '
        'VALUES (?, ?, ?, ?, ?) '
        'ON CONFLICT(business_id, customer_id, manufacturer_id) DO UPDATE SET '
        'balance = balance + excluded.balance, '
        'last_updated_at = CAST(strftime(\'%s\', CURRENT_TIMESTAMP) AS INTEGER)',
        variables: [
          Variable(UuidV7.generate()),
          Variable(requireBusinessId()),
          Variable(customerId),
          Variable(manufacturerId),
          Variable(delta),
        ],
        updates: {customerCrateBalances},
      );

      if (useDomainRpc) {
        final payload = <String, dynamic>{
          'p_business_id': requireBusinessId(),
          'p_actor_id': performedBy,
          'p_ledger_id': ledgerId,
          'p_owner_kind': 'customer',
          'p_owner_id': customerId,
          'p_manufacturer_id': manufacturerId,
          'p_quantity_delta': delta,
          'p_movement_type': 'returned',
          if (orderId != null) 'p_reference_order_id': orderId,
        };
        await db.syncDao.enqueue(
          'domain:pos_record_crate_return',
          jsonEncode(payload),
        );
      } else {
        await db.syncDao.enqueueUpsert('crate_ledger', ledgerComp);
        final updatedBalance =
            await (select(customerCrateBalances)
                  ..where(
                    (t) =>
                        whereBusiness(t) &
                        t.customerId.equals(customerId) &
                        t.manufacturerId.equals(manufacturerId),
                  )
                  ..limit(1))
                .getSingle();
        await db.syncDao.enqueueUpsert(
          'customer_crate_balances',
          updatedBalance,
        );
      }
    });
  }

  /// §13.4 — record crates ISSUED to a customer at sale time. This is the
  /// dispatch half of crate tracking that was missing and caused the "returned
  /// everything but still shows owing" bug: the balance only ever DECREMENTED
  /// on return, so `returned == taken` could never net to zero. Appends a
  /// `+quantity` 'issued' ledger row and increments customer_crate_balances; the
  /// existing 'returned' path then nets it back toward zero.
  ///
  /// No own transaction — the caller (OrdersDao.createOrder) is already inside
  /// one. No domain RPC envelope: there is no pos_record_crate_issue, so
  /// crate_ledger + the balance cache ride the per-table upsert path (same shape
  /// as [recordCrateReturnByCustomer]'s flag-off branch). Works on both sale
  /// sync paths because these rows are client-authored (pos_record_sale_v2 does
  /// not mint them).
  Future<void> recordCrateIssueByCustomer({
    required String customerId,
    required String manufacturerId,
    required int quantity,
    required String performedBy,
    String? orderId,
  }) async {
    if (quantity <= 0) return;
    final delta = quantity; // dispatch increases what the customer owes

    final ledgerId = UuidV7.generate();
    final ledgerComp = CrateLedgerCompanion.insert(
      id: Value(ledgerId),
      businessId: requireBusinessId(),
      customerId: Value(customerId),
      manufacturerId: Value(manufacturerId),
      quantityDelta: delta,
      movementType: 'issued',
      referenceOrderId: Value(orderId),
      performedBy: Value(performedBy),
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(crateLedger).insert(ledgerComp);

    // customInsert (not customStatement) so the watching streams refresh.
    await customInsert(
      'INSERT INTO customer_crate_balances (id, business_id, customer_id, manufacturer_id, balance) '
      'VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(business_id, customer_id, manufacturer_id) DO UPDATE SET '
      'balance = balance + excluded.balance, '
      'last_updated_at = CAST(strftime(\'%s\', CURRENT_TIMESTAMP) AS INTEGER)',
      variables: [
        Variable(UuidV7.generate()),
        Variable(requireBusinessId()),
        Variable(customerId),
        Variable(manufacturerId),
        Variable(delta),
      ],
      updates: {customerCrateBalances},
    );

    await db.syncDao.enqueueUpsert('crate_ledger', ledgerComp);
    final updatedBalance =
        await (select(customerCrateBalances)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    t.customerId.equals(customerId) &
                    t.manufacturerId.equals(manufacturerId),
              )
              ..limit(1))
            .getSingle();
    await db.syncDao.enqueueUpsert('customer_crate_balances', updatedBalance);
  }

  /// Verification logic to ensure cache tables match ledger sums.
  /// To be scheduled nightly or run on-demand.
  Future<void> verifyCrateReconciliation() async {
    // v29: crate balances are keyed by manufacturer. A customer crate row sets
    // BOTH customer_id and manufacturer_id; a business/manufacturer-stock row
    // sets only manufacturer_id (customer_id null).
    //
    // 1. Reconcile Customers — rows with a customer owner, by (customer,
    // manufacturer).
    final customerLedgerSums =
        await (selectOnly(crateLedger)
              ..addColumns([
                crateLedger.customerId,
                crateLedger.manufacturerId,
                crateLedger.quantityDelta.sum(),
              ])
              ..where(
                whereBusiness(crateLedger) & crateLedger.customerId.isNotNull(),
              )
              ..groupBy([crateLedger.customerId, crateLedger.manufacturerId]))
            .get();

    for (final row in customerLedgerSums) {
      final custId = row.read(crateLedger.customerId)!;
      final mfrId = row.read(crateLedger.manufacturerId);
      final sum = row.read(crateLedger.quantityDelta.sum()) ?? 0;
      if (mfrId == null) continue; // legacy pre-v29 row without a manufacturer

      final cache =
          await (select(customerCrateBalances)..where(
                (t) =>
                    whereBusiness(t) &
                    t.customerId.equals(custId) &
                    t.manufacturerId.equals(mfrId),
              ))
              .getSingleOrNull();

      if (cache == null || cache.balance != sum.toInt()) {
        // Log mismatch or trigger auto-fix (logging for now)
        // ignore: avoid_print
        print(
          'CRATE MISMATCH [Customer]: $custId, Manufacturer: $mfrId, Ledger: $sum, Cache: ${cache?.balance}',
        );
      }
    }

    // 2. Reconcile Manufacturers — business-side stock rows only (no customer
    // owner), by manufacturer.
    final manufacturerLedgerSums =
        await (selectOnly(crateLedger)
              ..addColumns([
                crateLedger.manufacturerId,
                crateLedger.quantityDelta.sum(),
              ])
              ..where(
                whereBusiness(crateLedger) &
                    crateLedger.manufacturerId.isNotNull() &
                    crateLedger.customerId.isNull(),
              )
              ..groupBy([crateLedger.manufacturerId]))
            .get();

    for (final row in manufacturerLedgerSums) {
      final mfrId = row.read(crateLedger.manufacturerId)!;
      final sum = row.read(crateLedger.quantityDelta.sum()) ?? 0;

      final cache =
          await (select(manufacturerCrateBalances)..where(
                (t) => whereBusiness(t) & t.manufacturerId.equals(mfrId),
              ))
              .getSingleOrNull();

      if (cache == null || cache.balance != sum.toInt()) {
        // ignore: avoid_print
        print(
          'CRATE MISMATCH [Manufacturer]: $mfrId, Ledger: $sum, Cache: ${cache?.balance}',
        );
      }
    }

    // 3. Reconcile per-store balances (§16.8.1) — store-stamped business-side
    // ledger rows (store_id NOT NULL, customer_id NULL) vs store_crate_balances.
    final storeLedgerSums = await customSelect(
      'SELECT store_id, manufacturer_id, SUM(quantity_delta) AS ledger_sum '
      'FROM crate_ledger '
      'WHERE business_id = ? '
      '  AND store_id IS NOT NULL '
      '  AND customer_id IS NULL '
      'GROUP BY store_id, manufacturer_id',
      variables: [Variable(requireBusinessId())],
    ).get();

    for (final row in storeLedgerSums) {
      final sid = row.read<String>('store_id');
      final mfrId = row.read<String>('manufacturer_id');
      final sum = row.read<int>('ledger_sum');
      final cacheBalance = await db.storeCrateBalancesDao.getBalance(
        storeId: sid,
        manufacturerId: mfrId,
      );
      if (cacheBalance != sum) {
        // ignore: avoid_print
        print(
          'CRATE MISMATCH [Store]: store=$sid, mfr=$mfrId, Ledger: $sum, Cache: $cacheBalance',
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
  Future<void> updateInfo({String? name, String? type, String? phone}) async {
    final id = requireBusinessId();
    await (update(businesses)..where((t) => t.id.equals(id))).write(
      BusinessesCompanion(
        name: name == null ? const Value.absent() : Value(name),
        type: type == null ? const Value.absent() : Value(type),
        // Empty string clears the stored phone (nullable column).
        phone: phone == null
            ? const Value.absent()
            : Value(phone.isEmpty ? null : phone),
        lastUpdatedAt: Value(DateTime.now()),
      ),
    );
    final row = await (select(
      businesses,
    )..where((t) => t.id.equals(id))).getSingle();
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
    return (select(permissions)..orderBy([
          (t) => OrderingTerm.asc(t.category),
          (t) => OrderingTerm.asc(t.key),
        ]))
        .get();
  }

  Stream<List<PermissionData>> watchAll() {
    return (select(permissions)..orderBy([
          (t) => OrderingTerm.asc(t.category),
          (t) => OrderingTerm.asc(t.key),
        ]))
        .watch();
  }

  Future<PermissionData?> getByKey(String key) {
    return (select(
      permissions,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
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
                    rolePermissions.roleId.equals(roleId),
              ))
            .getSingle();
    return row.read(rolePermissions.id.count()) ?? 0;
  }

  /// Grant a permission to a role. Idempotent on the logical identity
  /// (role_id, permission_key): if the pair is already granted, this is a
  /// no-op. A blind `insert` with a fresh UUID would trip
  /// UNIQUE(role_id, permission_key) (SqliteException 2067) whenever a row for
  /// the pair already exists — e.g. a stale toggle, or a row that arrived from
  /// the cloud since the UI last built.
  Future<void> grant(String roleId, String permissionKey) async {
    final existing =
        await (select(rolePermissions)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    t.roleId.equals(roleId) &
                    t.permissionKey.equals(permissionKey),
              )
              ..limit(1))
            .getSingleOrNull();
    if (existing != null) return; // already granted — nothing to do
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
    final existing =
        await (select(rolePermissions)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    t.roleId.equals(roleId) &
                    t.permissionKey.equals(permissionKey),
              )
              ..limit(1))
            .getSingleOrNull();
    if (existing == null) return;
    await (delete(
      rolePermissions,
    )..where((t) => t.id.equals(existing.id))).go();
    await db.syncDao.enqueueDelete('role_permissions', existing.id);
  }
}

@DriftAccessor(tables: [UserPermissionOverrides])
class UserPermissionOverridesDao extends DatabaseAccessor<AppDatabase>
    with _$UserPermissionOverridesDaoMixin, BusinessScopedDao<AppDatabase> {
  UserPermissionOverridesDao(super.db);

  Stream<List<UserPermissionOverrideData>> watchForUser(String userId) {
    return (select(userPermissionOverrides)
          ..where((t) => whereBusiness(t) & t.userId.equals(userId))
          ..orderBy([(t) => OrderingTerm.asc(t.permissionKey)]))
        .watch();
  }

  Future<List<UserPermissionOverrideData>> getForUser(String userId) {
    return (select(userPermissionOverrides)
          ..where((t) => whereBusiness(t) & t.userId.equals(userId))
          ..orderBy([(t) => OrderingTerm.asc(t.permissionKey)]))
        .get();
  }

  /// Set or clear a staff member's override for [permissionKey] (§10.2.1).
  /// [value] true = force-grant, false = force-revoke, null = clear the
  /// override (inherit the role default). Idempotent on the logical identity
  /// (business_id, user_id, permission_key): a value that already matches is a
  /// no-op, so we never trip UNIQUE on a stale toggle or a row that arrived
  /// from the cloud since the UI last built.
  Future<void> setOverride(
    String userId,
    String permissionKey,
    bool? value,
  ) async {
    final existing =
        await (select(userPermissionOverrides)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    t.userId.equals(userId) &
                    t.permissionKey.equals(permissionKey),
              )
              ..limit(1))
            .getSingleOrNull();

    if (value == null) {
      // Inherit — remove the override row and tombstone it cloud-side.
      // `user_permission_overrides` is not an append-only ledger, so
      // hard-delete via `enqueueDelete` is the right path here.
      if (existing == null) return;
      await (delete(
        userPermissionOverrides,
      )..where((t) => t.id.equals(existing.id))).go();
      await db.syncDao.enqueueDelete('user_permission_overrides', existing.id);
      return;
    }

    if (existing != null) {
      if (existing.isGranted == value) return; // already at this value
      final row = UserPermissionOverridesCompanion(
        id: Value(existing.id),
        businessId: Value(existing.businessId),
        userId: Value(existing.userId),
        permissionKey: Value(existing.permissionKey),
        isGranted: Value(value),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await (update(
        userPermissionOverrides,
      )..where((t) => t.id.equals(existing.id))).write(row);
      await db.syncDao.enqueueUpsert('user_permission_overrides', row);
      return;
    }

    final row = UserPermissionOverridesCompanion.insert(
      id: Value(UuidV7.generate()),
      businessId: requireBusinessId(),
      userId: userId,
      permissionKey: permissionKey,
      isGranted: value,
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(userPermissionOverrides).insert(row);
    await db.syncDao.enqueueUpsert('user_permission_overrides', row);
  }

  /// Restore defaults — clear EVERY override for [userId] so all permissions
  /// revert to the role default. Each row is hard-deleted and tombstoned
  /// (`enqueueDelete`) so other devices drop it too (same path as a single
  /// inherit/clear in [setOverride]). Returns the number of overrides cleared.
  Future<int> clearAllForUser(String userId) async {
    final rows = await getForUser(userId);
    for (final r in rows) {
      await (delete(
        userPermissionOverrides,
      )..where((t) => t.id.equals(r.id))).go();
      await db.syncDao.enqueueDelete('user_permission_overrides', r.id);
    }
    return rows.length;
  }
}

@DriftAccessor(tables: [StoreRolePermissions])
class StoreRolePermissionsDao extends DatabaseAccessor<AppDatabase>
    with _$StoreRolePermissionsDaoMixin, BusinessScopedDao<AppDatabase> {
  StoreRolePermissionsDao(super.db);

  Stream<List<StoreRolePermissionData>> watchFor(
    String storeId,
    String roleId,
  ) {
    return (select(storeRolePermissions)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.storeId.equals(storeId) &
                t.roleId.equals(roleId),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.permissionKey)]))
        .watch();
  }

  Future<List<StoreRolePermissionData>> getFor(String storeId, String roleId) {
    return (select(storeRolePermissions)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.storeId.equals(storeId) &
                t.roleId.equals(roleId),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.permissionKey)]))
        .get();
  }

  /// Set or clear a store's override of [permissionKey] for [roleId] (§10.2.1
  /// Store scope). [value] true = force-grant, false = force-revoke, null =
  /// clear the override (inherit the role's business default). Idempotent on the
  /// logical identity (store_id, role_id, permission_key): a value that already
  /// matches is a no-op, so we never trip UNIQUE on a stale toggle or a row that
  /// arrived from the cloud since the UI last built. Same shape as
  /// [UserPermissionOverridesDao.setOverride].
  Future<void> setOverride(
    String storeId,
    String roleId,
    String permissionKey,
    bool? value,
  ) async {
    final existing =
        await (select(storeRolePermissions)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    t.storeId.equals(storeId) &
                    t.roleId.equals(roleId) &
                    t.permissionKey.equals(permissionKey),
              )
              ..limit(1))
            .getSingleOrNull();

    if (value == null) {
      // Inherit — remove the override row and tombstone it cloud-side.
      // `store_role_permissions` is not an append-only ledger, so hard-delete
      // via `enqueueDelete` is the right path here.
      if (existing == null) return;
      await (delete(
        storeRolePermissions,
      )..where((t) => t.id.equals(existing.id))).go();
      await db.syncDao.enqueueDelete('store_role_permissions', existing.id);
      return;
    }

    if (existing != null) {
      if (existing.isGranted == value) return; // already at this value
      final row = StoreRolePermissionsCompanion(
        id: Value(existing.id),
        businessId: Value(existing.businessId),
        storeId: Value(existing.storeId),
        roleId: Value(existing.roleId),
        permissionKey: Value(existing.permissionKey),
        isGranted: Value(value),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await (update(
        storeRolePermissions,
      )..where((t) => t.id.equals(existing.id))).write(row);
      await db.syncDao.enqueueUpsert('store_role_permissions', row);
      return;
    }

    final row = StoreRolePermissionsCompanion.insert(
      id: Value(UuidV7.generate()),
      businessId: requireBusinessId(),
      storeId: storeId,
      roleId: roleId,
      permissionKey: permissionKey,
      isGranted: value,
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(storeRolePermissions).insert(row);
    await db.syncDao.enqueueUpsert('store_role_permissions', row);
  }

  /// Restore store defaults — clear EVERY override for [storeId] + [roleId] so
  /// that store's permissions revert to the role's business defaults. Each row
  /// is hard-deleted and tombstoned (`enqueueDelete`) so other devices drop it
  /// too. Returns the number of overrides cleared.
  Future<int> clearAllForStoreRole(String storeId, String roleId) async {
    final rows = await getFor(storeId, roleId);
    for (final r in rows) {
      await (delete(
        storeRolePermissions,
      )..where((t) => t.id.equals(r.id))).go();
      await db.syncDao.enqueueDelete('store_role_permissions', r.id);
    }
    return rows.length;
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
    final row =
        await (select(roleSettings)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    t.roleId.equals(roleId) &
                    t.settingKey.equals(settingKey),
              )
              ..limit(1))
            .getSingleOrNull();
    return row?.settingValue;
  }

  /// Set a setting value. Upserts on (role_id, setting_key).
  Future<void> set(String roleId, String settingKey, String? value) async {
    final existing =
        await (select(roleSettings)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    t.roleId.equals(roleId) &
                    t.settingKey.equals(settingKey),
              )
              ..limit(1))
            .getSingleOrNull();
    if (existing != null) {
      final comp = RoleSettingsCompanion(
        id: Value(existing.id),
        settingValue: Value(value),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await (update(
        roleSettings,
      )..where((t) => t.id.equals(existing.id))).write(comp);
      // Refresh full row for enqueue (payload carries businessId etc.)
      final refreshed = await (select(
        roleSettings,
      )..where((t) => t.id.equals(existing.id))).getSingle();
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

  /// The user id of this business's CEO (the single owner, CLAUDE.md), or null
  /// if none is resolved locally. Used to route §26.4 CEO-only notifications.
  Future<String?> getCeoUserId() async {
    final ceoRole = await db.rolesDao.getBySlug('ceo');
    if (ceoRole == null) return null;
    final row =
        await (select(userBusinesses)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    t.roleId.equals(ceoRole.id) &
                    t.status.equals('active'),
              )
              ..limit(1))
            .getSingleOrNull();
    return row?.userId;
  }

  /// Active user ids whose role slug is in [slugs] for the current business.
  /// Routes §26.4 notifications to a role audience (e.g. Close Day's "day
  /// closed" fires to CEO + Manager). Empty if none resolve locally.
  Future<List<String>> getUserIdsForRoleSlugs(List<String> slugs) async {
    if (slugs.isEmpty) return const [];
    final query =
        select(userBusinesses).join([
          innerJoin(roles, roles.id.equalsExp(userBusinesses.roleId)),
        ])..where(
          whereBusiness(userBusinesses) &
              userBusinesses.status.equals('active') &
              roles.slug.isIn(slugs),
        );
    final rows = await query.get();
    return rows.map((r) => r.readTable(userBusinesses).userId).toList();
  }

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
    final query =
        select(userBusinesses).join([
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
          .map(
            (row) => WhoIsWorkingEntry(
              user: row.readTable(users),
              role: row.readTableOrNull(roles),
            ),
          )
          .toList(),
    );
  }

  /// One-shot count of active staff for [businessId]. Drives cold-start
  /// routing (master plan §7.2): >1 → Who Is Working picker so the signer is
  /// chosen explicitly; ≤1 → that user's personalized PIN screen. Not
  /// session-scoped (runs before sign-in), same as [watchActiveStaffForBusiness].
  Future<int> countActiveStaffForBusiness(String businessId) async {
    final countExp = userBusinesses.id.count();
    final row =
        await (selectOnly(userBusinesses)
              ..addColumns([countExp])
              ..where(
                userBusinesses.businessId.equals(businessId) &
                    userBusinesses.status.equals('active'),
              ))
            .getSingle();
    return row.read(countExp) ?? 0;
  }

  /// All memberships for a specific user — Phase 1 always returns
  /// at most one row, but the query supports the Phase 2 multi-
  /// business model without a schema change.
  Future<List<UserBusinessData>> getForUser(String userId) {
    return (select(
      userBusinesses,
    )..where((t) => t.userId.equals(userId))).get();
  }

  /// Reactive memberships for a specific user, NOT scoped to the current
  /// session. Filters by user id only so the role-badge resolver works
  /// before login binds a business (the shared-PIN picker). Drives
  /// `userRoleProvider`.
  Stream<List<UserBusinessData>> watchForUser(String userId) {
    return (select(
      userBusinesses,
    )..where((t) => t.userId.equals(userId))).watch();
  }

  Future<UserBusinessData?> getForUserInBusiness(
    String userId,
    String businessId,
  ) {
    return (select(userBusinesses)
          ..where(
            (t) => t.userId.equals(userId) & t.businessId.equals(businessId),
          )
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
    await (update(
      userBusinesses,
    )..where((t) => t.id.equals(membershipId))).write(
      UserBusinessesCompanion(
        status: Value(status),
        lastUpdatedAt: Value(DateTime.now()),
      ),
    );
    // Re-read the full row so the enqueue payload carries businessId etc.
    final refreshed = await (select(
      userBusinesses,
    )..where((t) => t.id.equals(membershipId))).getSingle();
    await db.syncDao.enqueueUpsert('user_businesses', refreshed);
  }

  /// Change the role on a membership. Enqueues the updated row for sync.
  Future<void> setRole(String membershipId, String roleId) async {
    await (update(
      userBusinesses,
    )..where((t) => t.id.equals(membershipId))).write(
      UserBusinessesCompanion(
        roleId: Value(roleId),
        lastUpdatedAt: Value(DateTime.now()),
      ),
    );
    // Re-read the full row so the enqueue payload carries businessId etc.
    final refreshed = await (select(
      userBusinesses,
    )..where((t) => t.id.equals(membershipId))).getSingle();
    await db.syncDao.enqueueUpsert('user_businesses', refreshed);
  }

  /// Stamp the login time on a user's membership. Enqueues the updated row
  /// for sync. No-op if the user has no membership in [businessId].
  Future<void> touchLastLogin(String userId, String businessId) async {
    final now = DateTime.now();
    await (update(userBusinesses)..where(
          (t) => t.userId.equals(userId) & t.businessId.equals(businessId),
        ))
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
          ..where(
            (t) =>
                whereBusiness(t) &
                t.isDeleted.not() &
                t.usedAt.isNull() &
                t.revokedAt.isNull() &
                t.expiresAt.isBiggerThanValue(now),
          )
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
      InviteCodesCompanion(revokedAt: Value(now), lastUpdatedAt: Value(now)),
    );
    // Re-read the full row so the enqueue payload carries businessId etc.
    final refreshed = await (select(
      inviteCodes,
    )..where((t) => t.id.equals(id))).getSingle();
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

  /// User ids assigned to [storeId] in the current business. Routes the §26.4
  /// stock-keeper adjustment notification to the *affected store's* leadership
  /// (intersected with the Manager audience by the caller). Business-scoped so
  /// it never leaks across businesses held on the same device.
  Future<List<String>> getUserIdsForStore(String storeId) async {
    final rows = await (select(
      userStores,
    )..where((t) => whereBusiness(t) & t.storeId.equals(storeId))).get();
    return rows.map((r) => r.userId).toList();
  }

  /// Assign [userId] to [storeId] in the current business (§9.5 CEO staff
  /// store-assignment editor). Idempotent — if the pair already exists it's a
  /// no-op (also dodges the UNIQUE (user_id, store_id) constraint). Explicit
  /// `id` so the cloud echo can't mint a different one and collide on the
  /// natural key (SqliteException 2067). Synced via enqueueUpsert.
  Future<void> assign(String userId, String storeId) async {
    final existing =
        await (select(userStores)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    t.userId.equals(userId) &
                    t.storeId.equals(storeId),
              )
              ..limit(1))
            .getSingleOrNull();
    if (existing != null) return; // already assigned — nothing to do
    final row = UserStoresCompanion.insert(
      id: Value(UuidV7.generate()),
      businessId: requireBusinessId(),
      userId: userId,
      storeId: storeId,
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(userStores).insert(row);
    await db.syncDao.enqueueUpsert('user_stores', row);
  }

  /// Remove [userId]'s assignment to [storeId] (§9.5). Deletes the row and
  /// enqueues the tombstone — `user_stores` is a junction table, not an
  /// append-only ledger, so hard-delete via `enqueueDelete` is the right path
  /// here (same pattern as RolePermissionsDao.revoke).
  Future<void> unassign(String userId, String storeId) async {
    final existing =
        await (select(userStores)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    t.userId.equals(userId) &
                    t.storeId.equals(storeId),
              )
              ..limit(1))
            .getSingleOrNull();
    if (existing == null) return;
    await (delete(userStores)..where((t) => t.id.equals(existing.id))).go();
    await db.syncDao.enqueueDelete('user_stores', existing.id);
  }
}
