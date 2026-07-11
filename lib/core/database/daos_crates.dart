part of 'daos.dart';

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

  Future<void> recordCrateReceiveFromManufacturer({
    required String manufacturerId,
    required int quantity,
    required String performedBy,
    String? storeId,
  }) async {
    final delta = quantity; // receiving full crates increases our owed balance

    final flagValue = await db.systemConfigDao.get(
      'feature.domain_rpcs_v2.record_crate_return',
    );
    final useDomainRpc = flagValue == 'true' || flagValue == '"true"';

    await transaction(() async {
      final ledgerId = UuidV7.generate();
      final ledgerComp = CrateLedgerCompanion.insert(
        id: Value(ledgerId),
        businessId: requireBusinessId(),
        manufacturerId: Value(manufacturerId),
        storeId: Value(storeId),
        quantityDelta: delta,
        movementType: 'received',
        performedBy: Value(performedBy),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await into(crateLedger).insert(ledgerComp);

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
          'p_movement_type': 'received',
        };
        await db.syncDao.enqueue(
          'domain:pos_record_crate_return',
          jsonEncode(payload),
        );
      } else {
        await db.syncDao.enqueueUpsert('crate_ledger', ledgerComp);
      }
    });
  }

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

  /// Oversell recovery — LOCAL reversal of the crates a REJECTED sale "issued".
  /// A rejected v2 sale never happened: its `+quantity` 'issued' crate_ledger
  /// rows and the `customer_crate_balances` increment were HELD then discarded
  /// (they never reached the cloud). Unlike inventory — which the cloud's
  /// authoritative `inventory_after` re-converges on the next pull —
  /// `customer_crate_balances` is an LWW cache that WON'T self-heal: its
  /// post-sale value carries the newest timestamp and would win. So undo both
  /// here, append-only and LOCAL-ONLY:
  ///   • append a compensating `-quantity` 'adjusted' ledger row (a system
  ///     correction, not a phantom customer 'returned') so the ledger↔cache
  ///     sums stay consistent for [verifyCrateReconciliation]; and
  ///   • decrement the cache back to its pre-sale value.
  /// NOTHING is enqueued — the cloud never saw the issue, so a compensation
  /// pushed there would wrongly decrement a balance it never held (or FK-fail
  /// against the rejected order). No own transaction: the caller
  /// ([OrdersDao.reverseRejectedSaleLocal]) is already inside one, and its
  /// already-cancelled guard makes this idempotent. Only no-deposit
  /// ("crate-track") brands ever accrue a customer crate balance, so most
  /// rejected sales are a no-op here.
  Future<void> reverseIssuedByCustomerLocal({
    required String orderId,
    required String staffId,
  }) async {
    final issuedRows =
        await (select(crateLedger)..where(
              (l) =>
                  whereBusiness(l) &
                  l.referenceOrderId.equals(orderId) &
                  l.movementType.equals('issued') &
                  l.customerId.isNotNull() &
                  l.manufacturerId.isNotNull(),
            ))
            .get();
    final now = DateTime.now();
    for (final issued in issuedRows) {
      final customerId = issued.customerId!;
      final manufacturerId = issued.manufacturerId!;

      // Compensating ledger row — the exact inverse of the 'issued' delta.
      await into(crateLedger).insert(
        CrateLedgerCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: requireBusinessId(),
          customerId: Value(customerId),
          manufacturerId: Value(manufacturerId),
          quantityDelta: -issued.quantityDelta,
          movementType: 'adjusted',
          referenceOrderId: Value(orderId),
          performedBy: Value(staffId),
          lastUpdatedAt: Value(now),
        ),
      );

      // Decrement the LWW cache back toward its pre-sale value. customUpdate
      // (not customStatement) so Drift invalidates the watching crate streams.
      await customUpdate(
        'UPDATE customer_crate_balances SET balance = balance - ?, '
        "last_updated_at = CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER) "
        'WHERE business_id = ? AND customer_id = ? AND manufacturer_id = ?',
        variables: [
          Variable<int>(issued.quantityDelta),
          Variable<String>(requireBusinessId()),
          Variable<String>(customerId),
          Variable<String>(manufacturerId),
        ],
        updates: {customerCrateBalances},
      );
      // Intentionally NOT enqueued — local-only reversal of a rejected sale.
    }
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
