part of 'daos.dart';

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

  /// #158 — the Crates-tab read. Balance is DERIVED from the append-only
  /// `crate_ledger` (the wallet model), not the demoted `customer_crate_balances`
  /// cache; forwards to the Crate Pool seam so the SUM logic lives in one place.
  Stream<List<CrateBalanceEntry>> watchCrateBalancesWithGroups(
    String customerId,
  ) {
    return attachedDatabase.cratePoolDao.watchCustomerCrateDebt(customerId);
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

extension CustomerDataExtension on CustomerData {
  String get addressText => address ?? 'N/A';
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
