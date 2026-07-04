part of 'daos.dart';

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

  // ── Paginated Transaction History (§21.10) ────────────────────────────────

  /// Page of ledger entries across all suppliers, newest first, with
  /// mixed-direction 3-column keyset cursor:
  ///   ORDER BY created_at DESC, signed_amount_kobo ASC, id DESC.
  /// The [cursor] skips past the row at that position. [startDate] filters by
  /// activity_date >= startDate (Trap 3 — uses activityDate, not createdAt).
  Future<List<SupplierLedgerEntryData>> getSupplierHistoryPage({
    String? storeId,
    DateTime? startDate,
    ({DateTime createdAt, int signedAmountKobo, String id})? cursor,
    int limit = 30,
  }) async {
    final query = select(supplierLedgerEntries)
      ..where((t) => _scope(storeId));
    if (startDate != null) {
      query.where((t) => t.activityDate.isBiggerOrEqualValue(startDate));
    }
    if (cursor != null) {
      final c = cursor;
      query.where(
        (t) =>
            t.createdAt.isSmallerThanValue(c.createdAt) |
            (t.createdAt.equals(c.createdAt) &
                t.signedAmountKobo.isBiggerThanValue(c.signedAmountKobo)) |
            (t.createdAt.equals(c.createdAt) &
                t.signedAmountKobo.equals(c.signedAmountKobo) &
                t.id.isSmallerThanValue(c.id)),
      );
    }
    query
      ..orderBy([
        (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
        (t) =>
            OrderingTerm(expression: t.signedAmountKobo, mode: OrderingMode.asc),
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
      ])
      ..limit(limit);
    return query.get();
  }

  /// Live head (no cursor) for [getSupplierHistoryPage] — drives the watch
  /// subscription in [PaginatedSupplierHistoryNotifier].
  Stream<List<SupplierLedgerEntryData>> watchSupplierHistoryPage({
    String? storeId,
    DateTime? startDate,
    int limit = 30,
  }) {
    final query = select(supplierLedgerEntries)
      ..where((t) => _scope(storeId));
    if (startDate != null) {
      query.where((t) => t.activityDate.isBiggerOrEqualValue(startDate));
    }
    query
      ..orderBy([
        (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
        (t) =>
            OrderingTerm(expression: t.signedAmountKobo, mode: OrderingMode.asc),
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
      ])
      ..limit(limit);
    return query.watch();
  }

  /// Aggregate stats over the full windowed set (no cursor/limit).
  /// count = ALL windowed rows (voided + void included).
  /// totalIn / totalOut exclude voided originals AND void compensating rows;
  /// NULL-safe referenceType check prevents SQL three-valued-logic drop.
  Stream<SupplierLedgerStats> watchSupplierHistoryStats({
    String? storeId,
    DateTime? startDate,
  }) {
    final query = selectOnly(supplierLedgerEntries);
    query.where(_scope(storeId));
    if (startDate != null) {
      query.where(
        supplierLedgerEntries.activityDate.isBiggerOrEqualValue(startDate),
      );
    }

    const totalInCol = CustomExpression<int>(
      'SUM(CASE WHEN supplier_ledger_entries.voided_at IS NULL'
      ' AND (supplier_ledger_entries.reference_type IS NULL'
      ' OR supplier_ledger_entries.reference_type <> \'void\')'
      ' AND supplier_ledger_entries.signed_amount_kobo >= 0'
      ' THEN supplier_ledger_entries.signed_amount_kobo ELSE 0 END)',
    );
    const totalOutCol = CustomExpression<int>(
      'SUM(CASE WHEN supplier_ledger_entries.voided_at IS NULL'
      ' AND (supplier_ledger_entries.reference_type IS NULL'
      ' OR supplier_ledger_entries.reference_type <> \'void\')'
      ' AND supplier_ledger_entries.signed_amount_kobo < 0'
      ' THEN -supplier_ledger_entries.signed_amount_kobo ELSE 0 END)',
    );
    final countCol = supplierLedgerEntries.id.count();

    query.addColumns([totalInCol, totalOutCol, countCol]);

    return query.watchSingle().map((row) {
      return SupplierLedgerStats(
        count: row.read(countCol) ?? 0,
        totalIn: row.read(totalInCol) ?? 0,
        totalOut: row.read(totalOutCol) ?? 0,
      );
    });
  }
}

class SupplierLedgerStats {
  final int count;
  final int totalIn;
  final int totalOut;

  const SupplierLedgerStats({
    required this.count,
    required this.totalIn,
    required this.totalOut,
  });

  factory SupplierLedgerStats.empty() => const SupplierLedgerStats(
    count: 0,
    totalIn: 0,
    totalOut: 0,
  );
}

/// §3.13 — one per-(supplier, manufacturer) crate balance, joined with the
/// manufacturer name for display. Supplier-side mirror of
/// [CustomerCrateBalanceWithManufacturer]. A positive [balance] = WE owe the
/// supplier that many empties; negative = the supplier owes us (a crate credit).
class SupplierCrateBalanceWithManufacturer {
  final String manufacturerId;
  final String manufacturerName;
  final int balance;
  final int depositRateKobo;
  SupplierCrateBalanceWithManufacturer({
    required this.manufacturerId,
    required this.manufacturerName,
    required this.balance,
    required this.depositRateKobo,
  });
}

/// §3.13 — append-only ledger of empty-crate movements between the store and a
/// supplier. The supplier-side mirror of [CrateLedgerDao]'s customer methods.
/// `received` (+) = full crates arrived from the supplier (we now owe N
/// empties); `returned` (−) = empties handed back to the supplier. Both append
/// one [SupplierCrateLedger] row, upsert the [SupplierCrateBalances] cache, and
/// enqueue both for cloud push (no domain RPC — same shape as the customer
/// flag-off path). There is no UPDATE/DELETE on the ledger (append-only).

@DriftAccessor(tables: [SupplierCrateLedger, SupplierCrateBalances])
class SupplierCrateLedgerDao extends DatabaseAccessor<AppDatabase>
    with _$SupplierCrateLedgerDaoMixin, BusinessScopedDao<AppDatabase> {
  SupplierCrateLedgerDao(super.db);

  /// Record full crates RECEIVED from a supplier (we now owe N empties).
  /// [depositPaidKobo] is the refundable deposit money paid on this receipt
  /// (>= 0); pass 0 when no deposit changed hands.
  Future<void> recordCrateReceiptFromSupplier({
    required String supplierId,
    required String manufacturerId,
    required int quantity,
    required String performedBy,
    String? storeId,
    int depositPaidKobo = 0,
    String? note,
  }) async {
    if (quantity <= 0) return;
    await _appendMovement(
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

  /// Record empties RETURNED to a supplier (reduces what we owe them).
  /// [depositRefundedKobo] is the deposit money refunded back to us on this
  /// return (>= 0), recorded so the net deposit held by the supplier nets out.
  Future<void> recordCrateReturnToSupplier({
    required String supplierId,
    required String manufacturerId,
    required int quantity,
    required String performedBy,
    String? storeId,
    int depositRefundedKobo = 0,
    String? note,
  }) async {
    if (quantity <= 0) return;
    await _appendMovement(
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

  Future<void> _appendMovement({
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

      // customInsert (not customStatement) so the watching streams refresh on
      // commit — a raw customStatement write is invisible to Drift's tracker.
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

  /// Full ledger history for one supplier, newest first.
  Stream<List<SupplierCrateLedgerEntryData>> watchHistory(String supplierId) {
    return (select(supplierCrateLedger)
          ..where((t) => whereBusiness(t) & t.supplierId.equals(supplierId))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .watch();
  }

  /// Net refundable deposit still held BY the supplier (kobo) = deposits paid on
  /// receipts − deposits refunded on returns. Never negative in practice.
  Stream<int> watchDepositHeldKobo(String supplierId) {
    final received = supplierCrateLedger.depositPaidKobo;
    final query = selectOnly(supplierCrateLedger)
      ..addColumns([supplierCrateLedger.movementType, received.sum()])
      ..where(
        whereBusiness(supplierCrateLedger) &
            supplierCrateLedger.supplierId.equals(supplierId),
      )
      ..groupBy([supplierCrateLedger.movementType]);
    return query.watch().map((rows) {
      var net = 0;
      for (final r in rows) {
        final type = r.read(supplierCrateLedger.movementType);
        final sum = r.read(received.sum()) ?? 0;
        if (type == 'returned') {
          net -= sum;
        } else {
          net += sum;
        }
      }
      return net;
    });
  }

  /// Cumulative crates RECEIVED from / RETURNED (sent back) to this supplier —
  /// the running totals, NOT the net balance. Both are non-negative. Driven off
  /// `quantity_delta` (+ on `received`, − on `returned`) grouped by movement
  /// type; `adjusted` corrections are excluded from these gross counts.
  Stream<({int received, int returned})> watchMovementTotals(
    String supplierId,
  ) {
    final qtySum = supplierCrateLedger.quantityDelta.sum();
    final query = selectOnly(supplierCrateLedger)
      ..addColumns([supplierCrateLedger.movementType, qtySum])
      ..where(
        whereBusiness(supplierCrateLedger) &
            supplierCrateLedger.supplierId.equals(supplierId),
      )
      ..groupBy([supplierCrateLedger.movementType]);
    return query.watch().map((rows) {
      var received = 0;
      var returned = 0;
      for (final r in rows) {
        final type = r.read(supplierCrateLedger.movementType);
        final sum = r.read(qtySum) ?? 0;
        if (type == 'received') {
          received += sum;
        } else if (type == 'returned') {
          returned += -sum; // delta is negative for returns
        }
      }
      return (received: received, returned: returned);
    });
  }
}

/// §3.13 — per-(supplier, manufacturer) crate-balance cache reader. Supplier-side
/// mirror of [CustomerCrateBalancesDao]. Joins the manufacturer for display and
/// its current deposit rate so the UI can value the outstanding crates.

@DriftAccessor(tables: [SupplierCrateBalances, Manufacturers])
class SupplierCrateBalancesDao extends DatabaseAccessor<AppDatabase>
    with _$SupplierCrateBalancesDaoMixin, BusinessScopedDao<AppDatabase> {
  SupplierCrateBalancesDao(super.db);

  /// Live per-manufacturer balances for one supplier. Clear (0) rows are
  /// included so a fully-settled brand can still show "Clear".
  Stream<List<SupplierCrateBalanceWithManufacturer>> watchBySupplier(
    String supplierId,
  ) {
    final query = select(supplierCrateBalances).join([
      innerJoin(
        manufacturers,
        manufacturers.id.equalsExp(supplierCrateBalances.manufacturerId),
      ),
    ]);
    query.where(
      whereBusiness(supplierCrateBalances) &
          supplierCrateBalances.supplierId.equals(supplierId),
    );
    return query.watch().map((rows) {
      return rows.map((row) {
        final bal = row.readTable(supplierCrateBalances);
        final mfr = row.readTable(manufacturers);
        return SupplierCrateBalanceWithManufacturer(
          manufacturerId: bal.manufacturerId,
          manufacturerName: mfr.name,
          balance: bal.balance,
          depositRateKobo: mfr.depositAmountKobo,
        );
      }).toList();
    });
  }

  /// Net crates we owe this supplier across all manufacturers (positive = owed).
  Stream<int> watchTotalOwed(String supplierId) {
    final sumExpr = supplierCrateBalances.balance.sum();
    final query = selectOnly(supplierCrateBalances)
      ..addColumns([sumExpr])
      ..where(
        whereBusiness(supplierCrateBalances) &
            supplierCrateBalances.supplierId.equals(supplierId),
      );
    return query.watchSingleOrNull().map((row) => row?.read(sumExpr) ?? 0);
  }
}
