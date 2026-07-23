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

/// The **Crate Pool seam** (#156 / ADR 0020) — the single module every empty-
/// crate movement routes through. It is the *sole* writer of the crate tables
/// (`crate_ledger`, `supplier_crate_ledger`, and the four `*_crate_balances`
/// caches) and of the `manufacturers.empty_crate_stock` scalar; every other DAO
/// or service that used to write those tables now delegates here (a
/// `crate_seam_ban_test` fails the build if a crate write appears anywhere
/// else). Each operation is a domain verb (issue-to-customer, return-from-
/// customer, receive/return-supplier, record-damage, transfer-between-stores,
/// reverse-order-issuance, record-manual-count-correction, add-empties-to-pool)
/// that appends a correctly-signed, store-stamped, append-only ledger row in one
/// transaction and enqueues it to the Outbox.
///
/// This slice (#157) is behavior-preserving: the balance caches are still
/// written exactly as before. Later slices (#158–#163) derive the balances from
/// `SUM(quantity_delta)` and demote the caches. The working name in the PRD is
/// `CratePoolDao`; it absorbs the former `CrateLedgerDao`.
@DriftAccessor(
  tables: [
    CrateLedger,
    CustomerCrateBalances,
    ManufacturerCrateBalances,
    StoreCrateBalances,
    SupplierCrateLedger,
    SupplierCrateBalances,
    Manufacturers,
  ],
)
class CratePoolDao extends DatabaseAccessor<AppDatabase>
    with _$CratePoolDaoMixin, BusinessScopedDao<AppDatabase> {
  CratePoolDao(super.db);

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
        // #158: only the append-only ledger row syncs; the
        // `customer_crate_balances` cache is a local-only projection and is not
        // enqueued (the balance is derived — see [watchCustomerCrateDebt]).
        await db.syncDao.enqueueUpsert('crate_ledger', ledgerComp);
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
    // #158: the `customer_crate_balances` cache is a LOCAL-ONLY projection — it
    // is NOT enqueued. Only the append-only ledger row above crosses the wire;
    // the balance is DERIVED from it (see [watchCustomerCrateDebt]). Pushing the
    // absolute cache value is exactly the last-write-wins clobber this slice
    // removes.
  }

  /// #158 — a customer's crate debt per manufacturer, DERIVED from the append-
  /// only ledger the way the wallet balance derives from `wallet_transactions`
  /// ([WalletTransactionsDao.watchAllBalancesKobo]): the balance is
  /// `SUM(quantity_delta)` over the customer's `crate_ledger` rows grouped by
  /// manufacturer — never the stored `customer_crate_balances` total. Positive =
  /// the customer owes us empties; negative = a credit; zero = clear (a fully-
  /// returned brand nets to 0, not a phantom debt). Because the underlying
  /// `crate_ledger` insert is a Drift builder write the stream tracker observes,
  /// this re-emits live on every new movement. One row per manufacturer the
  /// customer has ever moved a crate for (inner-joined for the display name).
  Stream<List<CrateBalanceEntry>> watchCustomerCrateDebt(String customerId) {
    final sumExpr = crateLedger.quantityDelta.sum();
    final query = selectOnly(crateLedger).join([
      innerJoin(
        manufacturers,
        manufacturers.id.equalsExp(crateLedger.manufacturerId),
      ),
    ])
      ..addColumns([crateLedger.manufacturerId, manufacturers.name, sumExpr])
      ..where(
        whereBusiness(crateLedger) &
            crateLedger.customerId.equals(customerId) &
            crateLedger.manufacturerId.isNotNull(),
      )
      ..groupBy([crateLedger.manufacturerId, manufacturers.name]);
    return query.watch().map(
      (rows) => rows
          .map(
            (r) => CrateBalanceEntry(
              manufacturerId: r.read(crateLedger.manufacturerId)!,
              manufacturerName: r.read(manufacturers.name)!,
              balance: r.read(sumExpr) ?? 0,
            ),
          )
          .toList(),
    );
  }

  /// The crate legs of an APPROVED pending crate return (the approval-queue
  /// flow). Same customer-return movement as [recordCrateReturnByCustomer] but
  /// stamped with [returnId] (`referenceReturnId`). Runs inside the approval
  /// service's transaction, which also flips `pending_crate_returns` → approved.
  /// On the flagged path the caller dispatches the `pos_approve_crate_return`
  /// envelope (which settles the ledger + pending row server-side), so this only
  /// enqueues the per-table rows on the flag-off path.
  Future<void> recordApprovedCustomerReturn({
    required String customerId,
    required String manufacturerId,
    required String returnId,
    required String ledgerId,
    required int quantity,
    required String approvedBy,
    required bool useDomainRpc,
  }) async {
    final delta = -quantity; // returning reduces what the customer owes
    final ledgerComp = CrateLedgerCompanion.insert(
      id: Value(ledgerId),
      businessId: requireBusinessId(),
      customerId: Value(customerId),
      manufacturerId: Value(manufacturerId),
      quantityDelta: delta,
      movementType: 'returned',
      referenceReturnId: Value(returnId),
      performedBy: Value(approvedBy),
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(crateLedger).insert(ledgerComp);

    await customInsert(
      'INSERT INTO customer_crate_balances (id, business_id, customer_id, manufacturer_id, balance) '
      'VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(business_id, customer_id, manufacturer_id) DO UPDATE SET '
      'balance = balance + excluded.balance, '
      "last_updated_at = CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)",
      variables: [
        Variable(UuidV7.generate()),
        Variable(requireBusinessId()),
        Variable(customerId),
        Variable(manufacturerId),
        Variable(delta),
      ],
      updates: {customerCrateBalances},
    );

    if (!useDomainRpc) {
      // #158: customer crate debt is derived from the ledger; the cache is a
      // local-only projection and is not enqueued.
      await db.syncDao.enqueueUpsert('crate_ledger', ledgerComp);
    }
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

  // ───────────────────────────────────────────────────────────────────────
  // Physical business pool (manufacturers.empty_crate_stock scalar + per-store)
  // Moved here from InventoryDao (#157) so the pool has one writer.
  // ───────────────────────────────────────────────────────────────────────

  /// Credit the physical empty-crate pool for [manufacturerId] by [quantity]
  /// (receive-delivery / customer-return physical crates). Bumps the business
  /// scalar and, when a store is active, the per-store cache. #157: now ALWAYS
  /// appends a store-stamped `adjusted` crate_ledger row — including the
  /// store-less case, which previously skipped the ledger entirely.
  Future<void> addEmptiesToPool(
    String manufacturerId,
    int quantity, {
    String? storeId,
  }) async {
    if (quantity == 0) return;
    await transaction(() async {
      await customUpdate(
        'UPDATE manufacturers SET empty_crate_stock = empty_crate_stock + ?, '
        "last_updated_at = CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER) "
        'WHERE id = ? AND business_id = ?',
        variables: [
          Variable(quantity),
          Variable(manufacturerId),
          Variable(requireBusinessId()),
        ],
        updates: {manufacturers},
      );
      await _enqueueFullManufacturer(manufacturerId);
      if (storeId != null) {
        await db.storeCrateBalancesDao.applyDelta(
          storeId: storeId,
          manufacturerId: manufacturerId,
          delta: quantity,
        );
      }
      await _appendPoolLedgerRow(
        manufacturerId: manufacturerId,
        storeId: storeId,
        quantityDelta: quantity,
        movementType: 'adjusted',
      );
    });
  }

  /// Debit the physical pool because STORED empties were damaged/lost (§17.2).
  /// The scalar is clamped at zero. #157: appends a `damaged` crate_ledger row
  /// even when no store is locked.
  Future<void> recordDamage(
    String manufacturerId,
    int quantity, {
    String? storeId,
  }) async {
    if (quantity <= 0) return;
    await transaction(() async {
      await customUpdate(
        'UPDATE manufacturers SET empty_crate_stock = MAX(0, empty_crate_stock - ?), '
        "last_updated_at = CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER) "
        'WHERE id = ? AND business_id = ?',
        variables: [
          Variable(quantity),
          Variable(manufacturerId),
          Variable(requireBusinessId()),
        ],
        updates: {manufacturers},
      );
      await _enqueueFullManufacturer(manufacturerId);
      if (storeId != null) {
        await db.storeCrateBalancesDao.applyDelta(
          storeId: storeId,
          manufacturerId: manufacturerId,
          delta: -quantity,
        );
      }
      await _appendPoolLedgerRow(
        manufacturerId: manufacturerId,
        storeId: storeId,
        quantityDelta: -quantity,
        movementType: 'damaged',
      );
    });
  }

  /// Manually set a manufacturer's empty-crate count (management dialog). #157:
  /// a manual "set to N" is recorded as a reconciling **delta** row (N − current)
  /// so the correction has a traceable history instead of an off-ledger
  /// overwrite. With a store active, the per-store cache is set absolutely and
  /// the business total bumped by the same delta; the legacy (no-store) path
  /// sets the business scalar absolutely.
  Future<void> recordManualCountCorrection(
    String manufacturerId,
    int newStock, {
    String? storeId,
  }) async {
    await transaction(() async {
      final now = DateTime.now();
      if (storeId != null) {
        final currentBalance = await db.storeCrateBalancesDao.getBalance(
          storeId: storeId,
          manufacturerId: manufacturerId,
        );
        final delta = newStock - currentBalance;
        await db.storeCrateBalancesDao.setBalance(
          storeId: storeId,
          manufacturerId: manufacturerId,
          newBalance: newStock,
        );
        await customUpdate(
          'UPDATE manufacturers SET empty_crate_stock = empty_crate_stock + ?, '
          "last_updated_at = CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER) "
          'WHERE id = ? AND business_id = ?',
          variables: [
            Variable(delta),
            Variable(manufacturerId),
            Variable(requireBusinessId()),
          ],
          updates: {manufacturers},
        );
        await _enqueueFullManufacturer(manufacturerId);
        if (delta != 0) {
          await _appendPoolLedgerRow(
            manufacturerId: manufacturerId,
            storeId: storeId,
            quantityDelta: delta,
            movementType: 'adjusted',
          );
        }
      } else {
        final mfr = await (select(
          manufacturers,
        )..where((t) => t.id.equals(manufacturerId) & whereBusiness(t))).getSingle();
        final delta = newStock - mfr.emptyCrateStock;
        await (update(manufacturers)
              ..where((t) => t.id.equals(manufacturerId) & whereBusiness(t)))
            .write(
          ManufacturersCompanion(
            id: Value(manufacturerId),
            emptyCrateStock: Value(newStock),
            lastUpdatedAt: Value(now),
          ),
        );
        await _enqueueFullManufacturer(manufacturerId);
        if (delta != 0) {
          await _appendPoolLedgerRow(
            manufacturerId: manufacturerId,
            storeId: null,
            quantityDelta: delta,
            movementType: 'adjusted',
          );
        }
      }
    });
  }

  /// Move [quantity] empties of [manufacturerId] between two stores (§16.9),
  /// executed at dispatch. Writes two store-stamped crate_ledger legs and
  /// updates store_crate_balances locally; the cloud side is the single atomic
  /// `domain:pos_transfer_crates` envelope (store_crate_balances is NOT
  /// separately enqueued — the RPC is the sole cloud writer, preventing a
  /// double-count). Moved verbatim from StockTransferDao (#157).
  Future<void> transferBetweenStores({
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
  }

  // ───────────────────────────────────────────────────────────────────────
  // Supplier crate movements (supplier_crate_ledger + supplier_crate_balances)
  // Moved here from SupplierCrateLedgerDao (#157) so the seam owns every write.
  // ───────────────────────────────────────────────────────────────────────

  /// Full crates RECEIVED from a supplier (we now owe N empties), with an
  /// optional refundable [depositPaidKobo] paid on the receipt.
  Future<void> recordReceiveFromSupplier({
    required String supplierId,
    required String manufacturerId,
    required int quantity,
    required String performedBy,
    String? storeId,
    int depositPaidKobo = 0,
    String? note,
  }) async {
    if (quantity <= 0) return;
    await _appendSupplierMovement(
      supplierId: supplierId,
      manufacturerId: manufacturerId,
      quantityDelta: quantity,
      movementType: 'received',
      performedBy: performedBy,
      storeId: storeId,
      depositPaidKobo: depositPaidKobo < 0 ? 0 : depositPaidKobo,
      note: note,
    );
  }

  /// Empties RETURNED to a supplier (reduces what we owe), with an optional
  /// [depositRefundedKobo] refunded back to us on the return.
  Future<void> recordReturnToSupplier({
    required String supplierId,
    required String manufacturerId,
    required int quantity,
    required String performedBy,
    String? storeId,
    int depositRefundedKobo = 0,
    String? note,
  }) async {
    if (quantity <= 0) return;
    await _appendSupplierMovement(
      supplierId: supplierId,
      manufacturerId: manufacturerId,
      quantityDelta: -quantity,
      movementType: 'returned',
      performedBy: performedBy,
      storeId: storeId,
      depositPaidKobo: depositRefundedKobo < 0 ? 0 : depositRefundedKobo,
      note: note,
    );
  }

  Future<void> _appendSupplierMovement({
    required String supplierId,
    required String manufacturerId,
    required int quantityDelta,
    required String movementType,
    required String performedBy,
    required int depositPaidKobo,
    String? storeId,
    String? note,
  }) async {
    await transaction(() async {
      final ledgerComp = SupplierCrateLedgerCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: requireBusinessId(),
        supplierId: supplierId,
        manufacturerId: manufacturerId,
        storeId: Value(storeId),
        quantityDelta: quantityDelta,
        movementType: movementType,
        depositPaidKobo: Value(depositPaidKobo),
        note: Value(note),
        performedBy: Value(performedBy),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await into(supplierCrateLedger).insert(ledgerComp);

      await customInsert(
        'INSERT INTO supplier_crate_balances '
        '  (id, business_id, supplier_id, manufacturer_id, balance) '
        'VALUES (?, ?, ?, ?, ?) '
        'ON CONFLICT(business_id, supplier_id, manufacturer_id) DO UPDATE SET '
        '  balance = balance + excluded.balance, '
        "  last_updated_at = CAST(strftime('%s', CURRENT_TIMESTAMP) AS INTEGER)",
        variables: [
          Variable(UuidV7.generate()),
          Variable(requireBusinessId()),
          Variable(supplierId),
          Variable(manufacturerId),
          Variable(quantityDelta),
        ],
        updates: {supplierCrateBalances},
      );

      await db.syncDao.enqueueUpsert('supplier_crate_ledger', ledgerComp);
      final updatedBalance =
          await (select(supplierCrateBalances)
                ..where(
                  (t) =>
                      whereBusiness(t) &
                      t.supplierId.equals(supplierId) &
                      t.manufacturerId.equals(manufacturerId),
                )
                ..limit(1))
              .getSingle();
      await db.syncDao.enqueueUpsert(
        'supplier_crate_balances',
        updatedBalance,
      );
    });
  }

  // ── Shared helpers ─────────────────────────────────────────────────────

  /// Append an append-only, store-stamped business-pool ledger row and enqueue
  /// it. Used by the physical-pool verbs above.
  Future<void> _appendPoolLedgerRow({
    required String manufacturerId,
    String? storeId,
    required int quantityDelta,
    required String movementType,
    String? performedBy,
  }) async {
    final ledgerComp = CrateLedgerCompanion.insert(
      id: Value(UuidV7.generate()),
      businessId: requireBusinessId(),
      manufacturerId: Value(manufacturerId),
      storeId: Value(storeId),
      quantityDelta: quantityDelta,
      movementType: movementType,
      performedBy: Value(performedBy),
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(crateLedger).insert(ledgerComp);
    await db.syncDao.enqueueUpsert('crate_ledger', ledgerComp);
  }

  Future<void> _enqueueFullManufacturer(String id) async {
    final row = await (select(
      manufacturers,
    )..where((t) => t.id.equals(id) & whereBusiness(t))).getSingleOrNull();
    if (row != null) {
      await db.syncDao.enqueueUpsert('manufacturers', row.toCompanion(true));
    }
  }
}
