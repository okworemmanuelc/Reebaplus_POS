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
    // #159: `store_crate_balances` is a LOCAL-ONLY projection — the per-store
    // empties pool is DERIVED from the append-only `crate_ledger` (see
    // [CratePoolDao.watchEmptiesPoolByManufacturer]), so the absolute cache
    // value is NOT enqueued. Only the store-stamped ledger row (appended by the
    // pool verb / transfer leg) crosses the wire; pushing the absolute cache is
    // exactly the last-write-wins clobber this slice removes.
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
    // #159: local-only projection — not enqueued. The per-store empties pool is
    // derived from the ledger; see [applyDelta] above and
    // [CratePoolDao.watchEmptiesPoolByManufacturer].
  }
}

/// One supplier's crate-deposit position for ONE of their brands (#212) — the
/// [CrateDepositPosition] plus the manufacturer it belongs to, so a screen can
/// render "Star Lager — ₦180,000 with this supplier" without a second query.
class SupplierCrateDepositPosition {
  final String manufacturerId;
  final String manufacturerName;
  final CrateDepositPosition position;

  const SupplierCrateDepositPosition({
    required this.manufacturerId,
    required this.manufacturerName,
    required this.position,
  });
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
    // #212 — the crate-deposit MONEY tables. They live behind the same seam as
    // the counts on purpose (ADR 0020's sole-writer rule extended by ADR 0023
    // rule 1): the count leg and the money leg of one delivery must be able to
    // commit in ONE transaction, which they cannot do from two DAOs.
    SupplierCrateDepositRequests,
    SupplierCrateDeposits,
    PaymentTransactions,
    Manufacturers,
    Suppliers,
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
        // #166 (ADR 0020): the manufacturer_crate_balances cache is a LOCAL-ONLY
        // projection — it is written above so the Crates tab reads a fresh value,
        // but it is NEVER enqueued. Only the append-only crate_ledger row syncs;
        // pushing an absolute "balance is now N" row would reintroduce the
        // last-write-wins clobber the ledger model removes. This was the last
        // crate balance still pushed — after this slice none is.
        await db.syncDao.enqueueUpsert('crate_ledger', ledgerComp);
      }
    });
  }

  /// [ledgerId] lets the CALLER pin the appended row's id (#188). Confirm's
  /// crate-track settlement passes a DETERMINISTIC id derived from
  /// `(order, manufacturer)` so two devices that both settle the order offline
  /// mint the same row and the cloud's primary-key upsert collapses the
  /// duplicate instead of netting the customer's crate debt twice. Every other
  /// caller omits it and keeps a fresh [UuidV7.generate]: two manual returns of
  /// the same brand by the same customer are two REAL events and must not
  /// collapse into one.
  Future<void> recordCrateReturnByCustomer({
    required String customerId,
    required String manufacturerId,
    required int quantity,
    required String performedBy,
    String? orderId,
    String? ledgerId,
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
      final rowId = ledgerId ?? UuidV7.generate();
      final ledgerComp = CrateLedgerCompanion.insert(
        id: Value(rowId),
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
          'p_ledger_id': rowId,
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

  /// #159 — the PHYSICAL empties pool per manufacturer, DERIVED from the append-
  /// only ledger the way [watchCustomerCrateDebt] derives a customer's crate
  /// debt. The pool is `SUM(quantity_delta)` over the business's manufacturer-
  /// owned PHYSICAL-pool `crate_ledger` rows — the store-stamped, customer-less
  /// rows (`store_id IS NOT NULL AND customer_id IS NULL`) — never the demoted
  /// `manufacturers.empty_crate_stock` scalar or the `store_crate_balances`
  /// cache. With [storeId] null the sum spans every store (business-wide "All
  /// Stores"); with a store it confines to that store. Because the SAME store-
  /// stamped set grouped by store gives the per-store figure, the business total
  /// always equals Σ store totals by construction (PRD #156 store-stamp
  /// invariant). Returning empties to a supplier (a `returned` store-stamped,
  /// customer-less row) reduces the total automatically — the old
  /// counter-only-grows asymmetry is gone. Live-refreshing (the `crate_ledger`
  /// insert is a Drift builder write the stream tracker observes). One entry per
  /// manufacturer that has a physical-pool movement (a map miss reads as 0).
  Stream<Map<String, int>> watchEmptiesPoolByManufacturer({String? storeId}) {
    final sumExpr = crateLedger.quantityDelta.sum();
    var predicate =
        whereBusiness(crateLedger) &
        crateLedger.customerId.isNull() &
        crateLedger.storeId.isNotNull() &
        crateLedger.manufacturerId.isNotNull();
    if (storeId != null) {
      predicate = predicate & crateLedger.storeId.equals(storeId);
    }
    final query = selectOnly(crateLedger)
      ..addColumns([crateLedger.manufacturerId, sumExpr])
      ..where(predicate)
      ..groupBy([crateLedger.manufacturerId]);
    return query.watch().map(
      (rows) => {
        for (final r in rows)
          r.read(crateLedger.manufacturerId)!: r.read(sumExpr) ?? 0,
      },
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
  ///     correction, not a phantom customer 'returned') so the ledger-derived
  ///     debt nets back to its pre-sale value; and
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
  }) => _reverseIssuedByCustomer(
        orderId: orderId,
        staffId: staffId,
        enqueue: false,
      );

  /// #162 — reverse the crate rows a CANCELLED sale ISSUED to a customer (the
  /// "reverse-order-issuance" verb, ADR 0020). The ENQUEUED counterpart of
  /// [reverseIssuedByCustomerLocal]: a cancel compensates a sale the cloud
  /// ACCEPTED, so the compensating rows MUST cross the wire for peers to
  /// converge (the rejected-sale reversal is local-only precisely because the
  /// cloud never saw the sale's 'issued' rows). For every 'issued' customer
  /// `crate_ledger` row on [orderId] it appends the inverse `-quantity`
  /// 'adjusted' row (append-only), so the customer's DERIVED crate debt
  /// ([watchCustomerCrateDebt]) nets back to its exact pre-sale value — no
  /// phantom debt for crates the customer never kept. No own transaction: the
  /// caller ([OrdersDao.markCancelled]) is already inside one. A money-track
  /// (deposit) or walk-in sale issues no customer crate balance, so this is a
  /// no-op for it.
  Future<void> reverseIssuedByCustomer({
    required String orderId,
    required String staffId,
  }) => _reverseIssuedByCustomer(
        orderId: orderId,
        staffId: staffId,
        enqueue: true,
      );

  /// Shared body of the reverse-order-issuance verb. [enqueue] distinguishes a
  /// CANCEL (true — the cloud accepted the sale, so the compensating ledger row
  /// syncs) from a REJECTED-sale recovery (false — the cloud never held the
  /// issue, so pushing a compensation would wrongly decrement a balance it never
  /// had, or FK-fail against the rejected order). The `customer_crate_balances`
  /// cache is a local-only projection (#158) and is NEVER enqueued either way.
  Future<void> _reverseIssuedByCustomer({
    required String orderId,
    required String staffId,
    required bool enqueue,
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
      final compRow = CrateLedgerCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: requireBusinessId(),
        customerId: Value(customerId),
        manufacturerId: Value(manufacturerId),
        quantityDelta: -issued.quantityDelta,
        movementType: 'adjusted',
        referenceOrderId: Value(orderId),
        performedBy: Value(staffId),
        lastUpdatedAt: Value(now),
      );
      await into(crateLedger).insert(compRow);

      // Decrement the local-only projection cache back toward its pre-sale
      // value. customUpdate (not customStatement) so Drift invalidates the
      // watching crate streams.
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

      // Only the append-only ledger row crosses the wire, and only on the
      // cancel path — the demoted cache is never pushed (#158).
      if (enqueue) {
        await db.syncDao.enqueueUpsert('crate_ledger', compRow);
      }
    }
  }

  // #159: `verifyCrateReconciliation` (dead, print-only) was DELETED. With every
  // balance now DERIVED from the ledger (`SUM(quantity_delta)`), there is no
  // longer a cache to reconcile the ledger against — the ledger IS the truth
  // (ADR 0020 "retire the dead reconciler").

  // ───────────────────────────────────────────────────────────────────────
  // Physical business pool (manufacturers.empty_crate_stock scalar + per-store)
  // Moved here from InventoryDao (#157) so the pool has one writer.
  // ───────────────────────────────────────────────────────────────────────

  /// Credit the physical empty-crate pool for [manufacturerId] by [quantity]
  /// (receive-delivery / customer-return physical crates). Bumps the business
  /// scalar and, when a store is active, the per-store cache. #157: now ALWAYS
  /// appends a store-stamped `adjusted` crate_ledger row — including the
  /// store-less case, which previously skipped the ledger entirely.
  ///
  /// **[orderId] makes the credit idempotent across devices (#188).** When the
  /// crates come back against a specific ORDER (Confirm's crate returns), the
  /// appended ledger row is stamped with that order AND given a DETERMINISTIC id
  /// derived from `(order, manufacturer, store, movement)`, so two devices that
  /// both settle the order offline mint the SAME row and the cloud's primary-key
  /// upsert collapses the duplicate instead of crediting the pool twice
  /// (`CRATE_TRACKING_AUDIT.md` A3). The pool is DERIVED from these rows (ADR
  /// 0020) — the `empty_crate_stock` scalar and the per-store cache are unpushed
  /// local projections — so collapsing the ledger row IS collapsing the credit.
  /// Omit [orderId] for an order-less credit (a manual return, a delivery): the
  /// row keeps a fresh id, exactly as before, because two such credits are two
  /// real events.
  Future<void> addEmptiesToPool(
    String manufacturerId,
    int quantity, {
    String? storeId,
    String? orderId,
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
        orderId: orderId,
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
  ///
  /// When the manufacturer's Crate Money Arrangement is `per_delivery` (#212),
  /// this ALSO raises a pending deposit money leg for a money-permitted role to
  /// decide — in the same transaction as the count, so a delivery can never
  /// land with its counts recorded and its money forgotten (ADR 0023 finding
  /// #2). The count is committed either way: a stock keeper's say-so is enough
  /// for a crate record and never enough for cash (rule 6).
  ///
  /// The ARRANGEMENT decides this, not the caller. There is no opt-in flag on
  /// purpose: a second receive path that forgot to pass it is exactly how the
  /// money ends up in two disagreeing ledgers.
  ///
  /// A `none` brand raises nothing at all and behaves exactly as it did before
  /// PRD #203. So does `standing_float`, by design — that arrangement moves
  /// money only on a real top-up or payout (#214), never on an ordinary
  /// delivery.
  ///
  /// "The count commits regardless" is a statement about the DECISION, not
  /// about durability: whatever a manager later decides about the cash, the
  /// crates stay recorded. It is deliberately NOT a promise that the count
  /// survives a failure while raising the request — both legs share one
  /// transaction precisely so a half-recorded delivery cannot exist (ADR 0023
  /// finding #2, where a forgotten leg is the whole defect).
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
    await transaction(() async {
      // ONE ledger per brand, never two. `supplier_crate_ledger.deposit_paid_kobo`
      // is the legacy hand-typed deposit column, still the right home for a
      // `none` or `standing_float` brand where PRD #203 raises nothing. But on a
      // `per_delivery` brand the money belongs in `supplier_crate_deposits`, and
      // letting BOTH move would recreate ADR 0023 finding #3 — two numbers that
      // never meet — inside the very slice that exists to fix it. So the legacy
      // column is forced to 0 for that brand and the money goes through the
      // approval queue instead, whichever caller arrived: Receive Stock, or the
      // manual "receive crates" form on the supplier screen.
      final arrangement = await _crateMoneyArrangementOf(manufacturerId);
      final isPerDelivery = arrangement == CrateMoneyArrangement.perDelivery;
      // The one exception, and it is the pre-existing behaviour rather than a
      // new fork: the manual form runs under "All Stores" with no store id, and
      // the approval queue scopes approvers BY store (store_id is NOT NULL).
      // With nowhere to route the money we keep the legacy column rather than
      // silently discarding a figure the user typed.
      final canRaise = storeId != null;
      final legacyDeposit = (isPerDelivery && canRaise)
          ? 0
          : (depositPaidKobo < 0 ? 0 : depositPaidKobo);

      final ledgerId = await _appendSupplierMovement(
        supplierId: supplierId,
        manufacturerId: manufacturerId,
        quantityDelta: quantity,
        movementType: 'received',
        performedBy: performedBy,
        storeId: storeId,
        depositPaidKobo: legacyDeposit,
        note: note,
      );
      if (isPerDelivery && canRaise) {
        await raiseCrateDepositRequest(
          supplierId: supplierId,
          manufacturerId: manufacturerId,
          storeId: storeId,
          crateCount: quantity,
          requestedBy: performedBy,
          supplierCrateLedgerId: ledgerId,
        );
      }
    });
  }

  /// The brand's Crate Money Arrangement, failing closed to
  /// [CrateMoneyArrangement.none] for a manufacturer that cannot be read.
  Future<CrateMoneyArrangement> _crateMoneyArrangementOf(
    String manufacturerId,
  ) async {
    final m = await (select(manufacturers)..where(
          (t) => t.id.equals(manufacturerId) & whereBusiness(t),
        ))
        .getSingleOrNull();
    return crateMoneyArrangementOf(m?.crateMoneyArrangement);
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

  /// Appends one supplier crate-count movement and returns its ledger row id,
  /// so a money leg raised in the same transaction can point back at the exact
  /// delivery it answers (#212).
  Future<String> _appendSupplierMovement({
    required String supplierId,
    required String manufacturerId,
    required int quantityDelta,
    required String movementType,
    required String performedBy,
    required int depositPaidKobo,
    String? storeId,
    String? note,
  }) async {
    final ledgerId = UuidV7.generate();
    await transaction(() async {
      final ledgerComp = SupplierCrateLedgerCompanion.insert(
        id: Value(ledgerId),
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

      // #160: the `supplier_crate_balances` cache is a LOCAL-ONLY projection —
      // still written here so any local reader stays live and a legacy/RPC-
      // authored cloud row restores harmlessly on pull, but it is NOT enqueued.
      // customInsert (not customStatement) so the watching streams refresh.
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

      // #160: only the append-only ledger row crosses the wire; supplier crate
      // debt is DERIVED from it (see [watchSupplierCrateDebt]). Pushing the
      // absolute cache value is exactly the last-write-wins clobber this slice
      // removes — two offline tills' movements both survive a merge instead.
      await db.syncDao.enqueueUpsert('supplier_crate_ledger', ledgerComp);
    });
    return ledgerId;
  }

  /// #160 — a supplier's crate debt per manufacturer, DERIVED from the append-
  /// only `supplier_crate_ledger` the way the wallet balance derives from
  /// `wallet_transactions` ([WalletTransactionsDao.watchAllBalancesKobo]): the
  /// balance is `SUM(quantity_delta)` over the supplier's ledger rows grouped by
  /// manufacturer — never the demoted `supplier_crate_balances` total. Positive =
  /// WE owe the supplier that many empties (for the full crates they delivered);
  /// negative = the supplier owes us (a crate credit); zero = clear (a fully-
  /// settled brand nets to 0, still shown as Clear). Because the underlying
  /// `supplier_crate_ledger` insert is a Drift builder write the stream tracker
  /// observes, this re-emits live on every new movement. One row per manufacturer
  /// the supplier has ever moved a crate for, inner-joined for the display name +
  /// current per-manufacturer deposit rate so the UI can value the crates owed.
  Stream<List<SupplierCrateBalanceWithManufacturer>> watchSupplierCrateDebt(
    String supplierId,
  ) {
    final sumExpr = supplierCrateLedger.quantityDelta.sum();
    final query = selectOnly(supplierCrateLedger).join([
      innerJoin(
        manufacturers,
        manufacturers.id.equalsExp(supplierCrateLedger.manufacturerId),
      ),
    ])
      ..addColumns([
        supplierCrateLedger.manufacturerId,
        manufacturers.name,
        manufacturers.depositAmountKobo,
        sumExpr,
      ])
      ..where(
        whereBusiness(supplierCrateLedger) &
            supplierCrateLedger.supplierId.equals(supplierId),
      )
      ..groupBy([
        supplierCrateLedger.manufacturerId,
        manufacturers.name,
        manufacturers.depositAmountKobo,
      ]);
    return query.watch().map(
      (rows) => rows
          .map(
            (r) => SupplierCrateBalanceWithManufacturer(
              manufacturerId: r.read(supplierCrateLedger.manufacturerId)!,
              manufacturerName: r.read(manufacturers.name)!,
              balance: r.read(sumExpr) ?? 0,
              depositRateKobo: r.read(manufacturers.depositAmountKobo)!,
            ),
          )
          .toList(),
    );
  }

  /// #163 — the business-wide supplier crate DEBT valued in kobo at the current
  /// per-manufacturer deposit rate, DERIVED from the append-only
  /// `supplier_crate_ledger` (never the demoted `supplier_crate_balances`
  /// cache). Sums `quantity_delta` per manufacturer across EVERY supplier, values
  /// each at that manufacturer's `depositAmountKobo`, and totals them — the
  /// business-wide, all-suppliers roll-up of [watchSupplierCrateDebt] (same join
  /// to the current deposit rate). Positive = empties WE still owe suppliers for
  /// the full crates they delivered; a supplier crate credit (negative balance)
  /// nets it down. This is the crate-side liability the net-position figure
  /// subtracts, the analogue of the money-side supplier payable. Re-emits live
  /// on any new supplier crate movement (the ledger insert is an observed write).
  Stream<int> watchSupplierCrateDebtValueKobo() {
    final sumExpr = supplierCrateLedger.quantityDelta.sum();
    final query = selectOnly(supplierCrateLedger).join([
      innerJoin(
        manufacturers,
        manufacturers.id.equalsExp(supplierCrateLedger.manufacturerId),
      ),
    ])
      ..addColumns([manufacturers.depositAmountKobo, sumExpr])
      ..where(whereBusiness(supplierCrateLedger))
      ..groupBy([
        supplierCrateLedger.manufacturerId,
        manufacturers.depositAmountKobo,
      ]);
    return query.watch().map((rows) {
      var total = 0;
      for (final r in rows) {
        final qty = r.read(sumExpr) ?? 0;
        final rate = r.read(manufacturers.depositAmountKobo) ?? 0;
        total += qty * rate;
      }
      return total;
    });
  }

  // ───────────────────────────────────────────────────────────────────────
  // Crate deposit MONEY (#212, PRD #203, ADR 0023 rules 1, 2 and 6)
  //
  // The supplier-side mirror of the customer's held deposit, sign flipped: a
  // Placed Deposit drops cash and raises an ASSET, because the money is still
  // ours and is refundable. It is its own money family — never a `refund`,
  // never an `expense`, never a `void` — for the reason spelled out in
  // `lib/core/crates/crate_deposit_ledger_types.dart`.
  //
  // Two writes, and only two: a REQUEST (no money moves) and a CONFIRMATION
  // (both legs, one transaction). Rejection moves nothing at all and, in
  // particular, never touches the crate counts.
  // ───────────────────────────────────────────────────────────────────────

  /// Raise a pending crate-deposit money leg for a money-permitted role to
  /// decide. Returns the request id, or `null` when nothing was raised.
  ///
  /// Nothing is raised — and this is the release gate for PRD #203, expressed
  /// as the earliest possible return — when:
  ///  * the manufacturer's arrangement is not `per_delivery` (every existing
  ///    brand on every live tenant reads `none`, #211; `standing_float` moves
  ///    money only on real top-ups and payouts, #214);
  ///  * the per-crate rate is 0, so there is no money to ask about;
  ///  * the crate count is 0.
  ///
  /// The rate is SNAPSHOTTED onto the request, so a rate edit next month cannot
  /// restate what a delivery last week asked for.
  Future<String?> raiseCrateDepositRequest({
    required String supplierId,
    required String manufacturerId,
    required String storeId,
    required int crateCount,
    required String requestedBy,
    String kind = kCrateDepositMovementPlacement,
    String? supplierCrateLedgerId,
    String? note,
  }) async {
    if (crateCount <= 0) return null;

    final manufacturer = await (select(
      manufacturers,
    )..where((t) => t.id.equals(manufacturerId) & whereBusiness(t))).getSingleOrNull();
    if (manufacturer == null) return null;

    final arrangement = crateMoneyArrangementOf(
      manufacturer.crateMoneyArrangement,
    );
    if (arrangement != CrateMoneyArrangement.perDelivery) return null;

    final rate = manufacturer.depositAmountKobo;
    if (rate <= 0) return null;

    final supplier = await (select(
      suppliers,
    )..where((t) => t.id.equals(supplierId) & whereBusiness(t))).getSingleOrNull();

    final requestId = UuidV7.generate();
    final now = DateTime.now();
    // Its OWN transaction. This method is public and #214 will call it directly
    // for a float top-up, where the row insert, its outbox entry and the
    // approver fan-out have no outer transaction to ride on — three bare awaits
    // would let a crash leave a request that never reaches another device.
    // Nested inside `recordReceiveFromSupplier` it is a savepoint and composes.
    final row = SupplierCrateDepositRequestsCompanion.insert(
      id: Value(requestId),
      businessId: requireBusinessId(),
      supplierId: supplierId,
      manufacturerId: manufacturerId,
      storeId: storeId,
      kind: kind,
      crateCount: Value(crateCount),
      ratePerCrateKobo: Value(rate),
      requestedAmountKobo: Value(crateCount * rate),
      summary:
          '$crateCount crate${crateCount == 1 ? '' : 's'} of '
          '${manufacturer.name}'
          '${supplier == null ? '' : ' from ${supplier.name}'}',
      supplierCrateLedgerId: Value(supplierCrateLedgerId),
      note: Value(note),
      requestedBy: Value(requestedBy),
      status: const Value(kCrateDepositRequestPending),
      createdAt: Value(now),
      lastUpdatedAt: Value(now),
    );
    await transaction(() async {
      await into(supplierCrateDepositRequests).insert(row);
      await db.syncDao.enqueueUpsert('supplier_crate_deposit_requests', row);

      // Tell the people who can actually decide it — the CEO and the Managers of
    // the store the delivery landed in. Same fan-out as a stock-adjustment
    // request, and the reason is the same: the person who raised it cannot
    // resolve it, so an unnotified queue is an invisible one.
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
          type: 'crate_deposit.requested',
          message:
              'Crate deposit to confirm: ${row.summary.value} — '
              '${formatCurrency(crateCount * rate / 100)}',
          linkedRecordId: requestId,
          recipientUserId: uid,
        );
      }
    });
    return requestId;
  }

  /// Confirm a pending crate-deposit money leg: **both legs, one transaction**
  /// (ADR 0019's both-or-neither rule).
  ///
  ///  1. a `supplier_crate_deposits` row — the Placed Deposit asset, held per
  ///     `(supplier, manufacturer)`;
  ///  2. a `payment_transactions` row of type [kPaymentTypeCrateDepositOut] —
  ///     the cash that really left the drawer, hanging off the deposit row as
  ///     its seventh parent.
  ///
  /// [amountKobo] is what the approver actually agreed to pay, which may be
  /// less than the request asked for (a part payment, a waived deposit) or
  /// more. It defaults to the requested amount. A confirmation of 0 is legal
  /// and meaningful — "we owe them the crates but paid nothing today" — and
  /// writes the request's decision without either money row, because a book
  /// entry appears only when money genuinely moved.
  ///
  /// Returns true when this call was the one that decided the request; false
  /// when it had already been decided (another device won the race).
  Future<bool> confirmCrateDepositRequest({
    required String requestId,
    required String decidedBy,
    int? amountKobo,
    String paymentMethod = 'cash',
    String? note,
  }) async {
    var didConfirm = false;
    await transaction(() async {
      final req =
          await (select(supplierCrateDepositRequests)..where(
                (t) => t.id.equals(requestId) & whereBusiness(t),
              ))
              .getSingleOrNull();
      if (req == null || req.status != kCrateDepositRequestPending) return;

      final settled = (amountKobo ?? req.requestedAmountKobo);
      final amount = settled < 0 ? 0 : settled;
      final now = DateTime.now();

      // Flip the request FIRST, with `status = 'pending'` still in the WHERE.
      // A zero-row update means another device decided it between the read and
      // the write; bail out before any money is written. Same guard shape as
      // `StockAdjustmentRequestsDao.approveRequest`.
      final affected =
          await (update(supplierCrateDepositRequests)..where(
                (t) =>
                    t.id.equals(requestId) &
                    whereBusiness(t) &
                    t.status.equals(kCrateDepositRequestPending),
              ))
              .write(
                SupplierCrateDepositRequestsCompanion(
                  status: const Value(kCrateDepositRequestConfirmed),
                  settledAmountKobo: Value(amount),
                  paymentMethod: Value(paymentMethod),
                  decidedBy: Value(decidedBy),
                  decidedAt: Value(now),
                  decisionNote: Value(note),
                  lastUpdatedAt: Value(now),
                ),
              );
      if (affected == 0) return;
      didConfirm = true;

      if (amount > 0) {
        final outward = crateDepositMovementIsOutward(req.kind);
        final depositId = UuidV7.generate();
        final depositRow = SupplierCrateDepositsCompanion.insert(
          id: Value(depositId),
          businessId: requireBusinessId(),
          supplierId: req.supplierId,
          manufacturerId: req.manufacturerId,
          storeId: Value(req.storeId),
          movementType: req.kind,
          // The asset rises when money goes out to the supplier and falls when
          // it comes back. Same for the crate count it covers.
          //
          // On an ADJUSTED amount the crate count and the snapshot rate stay
          // WHOLE, so `signed_amount_kobo != crate_count * rate_per_crate_kobo`
          // on that row. That is on purpose and it is the honest record: the
          // delivery really was 8 crates at the brand's ₦3,500 rate, and we
          // really paid less than that. Deriving a fake crate count from the
          // part payment would invent a delivery that never happened, and
          // rewriting the rate would lose what the brand actually charges.
          // The consequence to know: `unbackedCrates` counts those crates as
          // backed, because money WAS placed against them — the shortfall in
          // naira shows up in `placedDepositKobo` instead, which is where a
          // part payment belongs.
          signedAmountKobo: outward ? amount : -amount,
          crateCount: Value(outward ? req.crateCount : -req.crateCount),
          ratePerCrateKobo: Value(req.ratePerCrateKobo),
          requestId: Value(requestId),
          supplierCrateLedgerId: Value(req.supplierCrateLedgerId),
          note: Value(note),
          performedBy: Value(decidedBy),
          createdAt: Value(now),
          lastUpdatedAt: Value(now),
        );
        await into(supplierCrateDeposits).insert(depositRow);
        await db.syncDao.enqueueUpsert(
          'supplier_crate_deposits',
          depositRow,
        );

        // The cash leg. `crate_deposit_out`, NEVER `expense` and NEVER
        // `refund`: this money is refundable, so it must not cut profit, and
        // typing held money as a refund is exactly the defect #190/#201 fixed
        // on the customer side. Positive = out of the drawer, negative = back.
        final paymentRow = PaymentTransactionsCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: requireBusinessId(),
          storeId: Value(req.storeId),
          amountKobo: outward ? amount : -amount,
          method: paymentMethod,
          type: kPaymentTypeCrateDepositOut,
          crateDepositId: Value(depositId),
          performedBy: Value(decidedBy),
          createdAt: Value(now),
          lastUpdatedAt: Value(now),
        );
        await into(paymentTransactions).insert(paymentRow);
        await db.syncDao.enqueueUpsert('payment_transactions', paymentRow);
      }

      final updated =
          await (select(supplierCrateDepositRequests)
                ..where((t) => t.id.equals(requestId) & whereBusiness(t)))
              .getSingleOrNull();
      if (updated != null) {
        await db.syncDao.enqueueUpsert(
          'supplier_crate_deposit_requests',
          updated.toCompanion(true),
        );
      }

      await db.activityLogDao.log(
        action: 'crate_deposit_confirmed',
        description:
            'Confirmed crate deposit: ${req.summary} — '
            '${formatCurrency(amount / 100)}'
            '${amount == req.requestedAmountKobo ? '' : ' (adjusted from ${formatCurrency(req.requestedAmountKobo / 100)})'}',
        staffId: decidedBy,
        storeId: req.storeId,
      );

      if (req.requestedBy != null) {
        await db.notificationsDao.fireNotification(
          type: 'crate_deposit.confirmed',
          message: 'Crate deposit confirmed: ${req.summary}',
          linkedRecordId: requestId,
          recipientUserId: req.requestedBy,
        );
      }
    });
    return didConfirm;
  }

  /// Reject a pending crate-deposit money leg.
  ///
  /// **Nothing physical moves.** The crates arrived and the crate ledger says
  /// so; rejecting says only that the business is not paying a deposit for
  /// them. No `supplier_crate_deposits` row, no `payment_transactions` row, no
  /// touch of any crate count or balance.
  ///
  /// Returns true when this call was the one that decided the request.
  Future<bool> rejectCrateDepositRequest({
    required String requestId,
    required String decidedBy,
    String? reason,
  }) async {
    final trimmed = reason?.trim();
    final hasReason = trimmed != null && trimmed.isNotEmpty;
    var didReject = false;
    await transaction(() async {
      final req =
          await (select(supplierCrateDepositRequests)..where(
                (t) => t.id.equals(requestId) & whereBusiness(t),
              ))
              .getSingleOrNull();
      if (req == null || req.status != kCrateDepositRequestPending) return;

      final now = DateTime.now();
      final affected =
          await (update(supplierCrateDepositRequests)..where(
                (t) =>
                    t.id.equals(requestId) &
                    whereBusiness(t) &
                    t.status.equals(kCrateDepositRequestPending),
              ))
              .write(
                SupplierCrateDepositRequestsCompanion(
                  status: const Value(kCrateDepositRequestRejected),
                  decidedBy: Value(decidedBy),
                  decidedAt: Value(now),
                  decisionNote: Value(hasReason ? trimmed : null),
                  lastUpdatedAt: Value(now),
                ),
              );
      if (affected == 0) return;
      didReject = true;

      final updated =
          await (select(supplierCrateDepositRequests)
                ..where((t) => t.id.equals(requestId) & whereBusiness(t)))
              .getSingleOrNull();
      if (updated != null) {
        await db.syncDao.enqueueUpsert(
          'supplier_crate_deposit_requests',
          updated.toCompanion(true),
        );
      }

      await db.activityLogDao.log(
        action: 'crate_deposit_rejected',
        description:
            'Rejected crate deposit: ${req.summary}'
            '${hasReason ? ' — Reason: $trimmed' : ''}'
            ' — the crates on this delivery are unaffected',
        staffId: decidedBy,
        storeId: req.storeId,
      );

      if (req.requestedBy != null) {
        await db.notificationsDao.fireNotification(
          type: 'crate_deposit.rejected',
          message: 'Crate deposit rejected: ${req.summary}',
          severity: 'warning',
          linkedRecordId: requestId,
          recipientUserId: req.requestedBy,
        );
      }
    });
    return didReject;
  }

  /// Every crate-deposit request still awaiting a decision, newest first.
  Stream<List<SupplierCrateDepositRequestData>>
  watchPendingCrateDepositRequests() {
    return (select(supplierCrateDepositRequests)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.status.equals(kCrateDepositRequestPending),
          )
          ..orderBy([
            (t) => OrderingTerm(
              expression: t.createdAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .watch();
  }

  /// One supplier's crate-deposit position, one entry per manufacturer they
  /// have ever moved crate money for.
  ///
  /// Everything is computed by [computeCrateDepositPosition] — this method only
  /// gathers rows. That split is the point of the seam: the arithmetic that
  /// tells an owner a depot is sitting on ₦180,000 of theirs lives in one pure
  /// function that #213-#217 all read through, and it is unit-tested with no
  /// database at all.
  ///
  /// Everything here is **pair-scoped**: the ledger rows, the pending requests
  /// and `cratesOwed` are all one `(supplier, manufacturer)` slice, which is
  /// how ADR 0023 rule 2 keys the money — only the supplier you actually paid
  /// can pay you back.
  ///
  /// **No `emptiesOnHand` is passed, so no shortfall is computed here.** The
  /// empties pool is brand-level and business-wide; subtracting it from ONE
  /// supplier's debt would double-subtract across two suppliers of the same
  /// brand and report both as square while the brand was genuinely short. ADR
  /// 0023 rule 4 puts the shortfall at brand level on purpose — crates are
  /// fungible, and guessing whose went missing invents a fact and then argues
  /// with the supplier's own records. The brand-level card is #215's.
  Stream<List<SupplierCrateDepositPosition>> watchSupplierCrateDepositPositions(
    String supplierId,
  ) {
    final query = select(supplierCrateDeposits).join([
      innerJoin(
        manufacturers,
        manufacturers.id.equalsExp(supplierCrateDeposits.manufacturerId),
      ),
    ])..where(
      whereBusiness(supplierCrateDeposits) &
          supplierCrateDeposits.supplierId.equals(supplierId),
    );

    // Combined with the pending queue rather than derived from the ledger
    // alone: a brand whose FIRST delivery is still awaiting a decision has no
    // ledger row at all, so a ledger-only stream would never fire and the
    // "awaiting confirmation" figure would sit there stale until some unrelated
    // deposit moved. Both halves of ADR 0023 rule 6 have to be live, because
    // the point of the screen is to show the owner money they have not yet
    // agreed to.
    final pendingStream =
        (select(supplierCrateDepositRequests)..where(
              (t) =>
                  whereBusiness(t) &
                  t.supplierId.equals(supplierId) &
                  t.status.equals(kCrateDepositRequestPending),
            ))
            .watch();

    return Rx.combineLatest2<
      List<TypedResult>,
      List<SupplierCrateDepositRequestData>,
      ({List<TypedResult> rows, List<SupplierCrateDepositRequestData> pending})
    >(
      query.watch(),
      pendingStream,
      (rows, pending) => (rows: rows, pending: pending),
    ).asyncMap((input) async {
      final rows = input.rows;
      final movementsBy = <String, List<CrateDepositMovement>>{};
      final manufacturerRows = <String, ManufacturerData>{};
      for (final r in rows) {
        final deposit = r.readTable(supplierCrateDeposits);
        final manufacturer = r.readTable(manufacturers);
        manufacturerRows[manufacturer.id] = manufacturer;
        (movementsBy[manufacturer.id] ??= <CrateDepositMovement>[]).add(
          CrateDepositMovement(
            movementType: deposit.movementType,
            signedAmountKobo: deposit.signedAmountKobo,
            crateCount: deposit.crateCount,
          ),
        );
      }

      final pendingRows = input.pending;
      final pendingBy = <String, List<PendingCrateDeposit>>{};
      for (final p in pendingRows) {
        if (!manufacturerRows.containsKey(p.manufacturerId)) {
          // A brand whose FIRST delivery is still awaiting a decision has no
          // ledger row yet, so the join above never saw it. It still belongs on
          // the supplier's screen — "₦42,000 awaiting your confirmation" is
          // exactly what the owner needs to see.
          final m =
              await (select(manufacturers)..where(
                    (t) => t.id.equals(p.manufacturerId) & whereBusiness(t),
                  ))
                  .getSingleOrNull();
          if (m == null) continue;
          manufacturerRows[p.manufacturerId] = m;
        }
        (pendingBy[p.manufacturerId] ??= <PendingCrateDeposit>[]).add(
          PendingCrateDeposit(
            kind: p.kind,
            requestedAmountKobo: p.requestedAmountKobo,
            crateCount: p.crateCount,
          ),
        );
      }

      final out = <SupplierCrateDepositPosition>[];
      for (final entry in manufacturerRows.entries) {
        final manufacturer = entry.value;
        final cratesOwed = await _supplierCratesOwed(
          supplierId: supplierId,
          manufacturerId: manufacturer.id,
        );
        out.add(
          SupplierCrateDepositPosition(
            manufacturerId: manufacturer.id,
            manufacturerName: manufacturer.name,
            position: computeCrateDepositPosition(
              arrangement: crateMoneyArrangementOf(
                manufacturer.crateMoneyArrangement,
              ),
              ratePerCrateKobo: manufacturer.depositAmountKobo,
              movements: movementsBy[manufacturer.id] ?? const [],
              pending: pendingBy[manufacturer.id] ?? const [],
              cratesOwed: cratesOwed,
              // Deliberately omitted — see the doc above. A shortfall is a
              // brand-level question and this is a pair-level read.
            ),
          ),
        );
      }
      out.sort((a, b) => a.manufacturerName.compareTo(b.manufacturerName));
      return out;
    });
  }

  /// `SUM(quantity_delta)` for one `(supplier, manufacturer)` pair — the
  /// empties we still owe that supplier for their brand's full crates.
  Future<int> _supplierCratesOwed({
    required String supplierId,
    required String manufacturerId,
  }) async {
    final sumExpr = supplierCrateLedger.quantityDelta.sum();
    final row =
        await (selectOnly(supplierCrateLedger)
              ..addColumns([sumExpr])
              ..where(
                whereBusiness(supplierCrateLedger) &
                    supplierCrateLedger.supplierId.equals(supplierId) &
                    supplierCrateLedger.manufacturerId.equals(manufacturerId),
              ))
            .getSingleOrNull();
    return row?.read(sumExpr) ?? 0;
  }

  // ── Shared helpers ─────────────────────────────────────────────────────

  /// Append an append-only, store-stamped business-pool ledger row and enqueue
  /// it. Used by the physical-pool verbs above.
  ///
  /// [orderId] stamps the row's `reference_order_id` AND switches the id to a
  /// DETERMINISTIC one derived from `(order, manufacturer, movement)` — see
  /// [addEmptiesToPool] for why (#188). Without it the id stays a fresh
  /// [UuidV7.generate], which is correct for an order-less pool movement.
  ///
  /// [storeId] is deliberately NOT part of that seed. It is the CONFIRMING
  /// DEVICE's active store, not a fact about the order, so two tills settling
  /// the same order from different active stores would otherwise seed two
  /// different ids and credit the pool twice — the exact partition this closes.
  /// `crate_ledger.store_id` is outside the append-only immutable set, so the
  /// collapsed row's store is a last-write-wins detail (as device-dependent as
  /// it always was) while the business-wide pool total — the figure that must
  /// not double — is right.
  Future<void> _appendPoolLedgerRow({
    required String manufacturerId,
    String? storeId,
    required int quantityDelta,
    required String movementType,
    String? performedBy,
    String? orderId,
  }) async {
    final ledgerComp = CrateLedgerCompanion.insert(
      id: Value(
        orderId == null
            ? UuidV7.generate()
            : UuidV7.deterministic(
                'crate_pool:$orderId:$manufacturerId:$movementType',
              ),
      ),
      businessId: requireBusinessId(),
      manufacturerId: Value(manufacturerId),
      storeId: Value(storeId),
      quantityDelta: quantityDelta,
      movementType: movementType,
      referenceOrderId: Value(orderId),
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
