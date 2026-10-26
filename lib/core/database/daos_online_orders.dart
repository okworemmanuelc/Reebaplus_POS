part of 'daos.dart';

/// Online Orders on the shop's phones (#426 pulls them, #427 answers them).
///
/// An Online Order is a REQUEST: answering it moves no stock, revenue, money or
/// crates (ADR 0031). Every write is a local Drift write plus a full-row outbox
/// upsert; the cloud transition guard (0205/0208) accepts an answer only from
/// `new`. A refusal there (the customer cancelled first) is settled by the sync
/// engine, not orphaned — see `SupabaseSyncService` (#427).
@DriftAccessor(tables: [OnlineOrders, OnlineOrderLines, Customers])
class OnlineOrdersDao extends DatabaseAccessor<AppDatabase>
    with _$OnlineOrdersDaoMixin, BusinessScopedDao<AppDatabase> {
  OnlineOrdersDao(super.db);

  /// Every Online Order of the business, newest first. Store scoping (active
  /// store, the viewer's stores) is applied by the providers.
  Stream<List<OnlineOrderData>> watchAll() {
    return (select(onlineOrders)
          ..where((t) => whereBusiness(t))
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.placedAt, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  Stream<OnlineOrderData?> watchById(String id) {
    return (select(onlineOrders)
          ..where((t) => t.id.equals(id) & whereBusiness(t))
          ..limit(1))
        .watchSingleOrNull();
  }

  /// Whether the order is already in Drift (a push tap, #433, must never wait
  /// on a pull — it opens the detail only when this is true).
  Future<bool> existsById(String id) async {
    final row = await (select(onlineOrders)
          ..where((t) => t.id.equals(id) & whereBusiness(t))
          ..limit(1))
        .getSingleOrNull();
    return row != null;
  }

  /// The order's lines in placement order (name as a stable tiebreak).
  Stream<List<OnlineOrderLineData>> watchLines(String onlineOrderId) {
    return (select(onlineOrderLines)
          ..where(
            (t) => t.onlineOrderId.equals(onlineOrderId) & whereBusiness(t),
          )
          ..orderBy([
            (t) => OrderingTerm(expression: t.createdAt),
            (t) => OrderingTerm(expression: t.productName),
          ]))
        .watch();
  }

  /// The live Customer already linked to [shopperAccountId], if any.
  Future<CustomerData?> findLinkedCustomer(String shopperAccountId) {
    return (select(customers)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.shopperAccountId.equals(shopperAccountId) &
                t.isDeleted.not(),
          )
          ..limit(1))
        .getSingleOrNull();
  }

  /// Suggestions for the first-order "existing customer" choice: phone matches
  /// first, then name matches, never a Customer already linked to a Shopper.
  /// Only suggestions — staff always choose (ADR 0030).
  Future<List<CustomerData>> suggestCustomers({
    required String phone,
    required String name,
    int limit = 5,
  }) async {
    final candidates =
        await (select(customers)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    t.isDeleted.not() &
                    t.shopperAccountId.isNull(),
              )
              ..orderBy([(t) => OrderingTerm(expression: t.name)]))
            .get();
    final wantPhone = _phoneKey(phone);
    final wantName = name.trim().toLowerCase();
    final byPhone = <CustomerData>[];
    final byName = <CustomerData>[];
    for (final c in candidates) {
      final key = _phoneKey(c.phone ?? '');
      if (wantPhone.isNotEmpty && key.isNotEmpty && key == wantPhone) {
        byPhone.add(c);
        continue;
      }
      final have = c.name.trim().toLowerCase();
      if (wantName.isNotEmpty &&
          have.isNotEmpty &&
          (have.contains(wantName) || wantName.contains(have))) {
        byName.add(c);
      }
    }
    return [...byPhone, ...byName].take(limit).toList();
  }

  /// Any not-yet-linked live Customer whose name or phone contains [query],
  /// for the "existing customer" search when no suggestion is right.
  Future<List<CustomerData>> searchLinkableCustomers(
    String query, {
    int limit = 8,
  }) {
    final q = '%${query.trim()}%';
    return (select(customers)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.isDeleted.not() &
                t.shopperAccountId.isNull() &
                (t.name.like(q) | t.phone.like(q)),
          )
          ..orderBy([(t) => OrderingTerm(expression: t.name)])
          ..limit(limit))
        .get();
  }

  /// The last 10 digits: `0803…` and `+234803…` compare equal.
  static String _phoneKey(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    return digits.length <= 10 ? digits : digits.substring(digits.length - 10);
  }

  /// Accept a `new` order. A Shopper already linked to a Customer attaches
  /// automatically; otherwise [link] is required on the first order (else
  /// [OnlineOrderAnswerOutcome.needsCustomerChoice], nothing written).
  ///
  /// [acceptedQtys] (line id -> quantity) lets staff lower a line or remove it
  /// (0) before accepting (#428). A quantity above what was asked, or an unknown
  /// line, throws [ArgumentError]; so does removing every line (that is a
  /// decline). Every line gets `accepted_qty` written: untouched lines get
  /// their requested quantity.
  Future<OnlineOrderAnswerOutcome> accept({
    required String onlineOrderId,
    CustomerLinkChoice? link,
    Map<String, int> acceptedQtys = const {},
  }) {
    return transaction(() async {
      final order = await _openOrder(onlineOrderId);
      if (order == null) return OnlineOrderAnswerOutcome.alreadyAnswered;
      final lines = await (select(onlineOrderLines)
            ..where((t) => t.onlineOrderId.equals(order.id) & whereBusiness(t)))
          .get();
      final decided = _decideAcceptedQtys(lines, acceptedQtys);

      String? customerId = order.customerId;
      final shopper = order.shopperAccountId;
      if (shopper != null) {
        final linked = await findLinkedCustomer(shopper);
        if (linked != null) {
          customerId = linked.id;
        } else {
          switch (link) {
            case null:
              return OnlineOrderAnswerOutcome.needsCustomerChoice;
            case LinkExistingCustomer(customerId: final existingId):
              await _linkExisting(customerId: existingId, shopper: shopper);
              customerId = existingId;
            case CreateRetailerCustomer():
              customerId = await _createRetailer(order, shopper);
          }
        }
      }

      final now = DateTime.now();
      for (final l in lines) {
        await (update(onlineOrderLines)
              ..where((t) => t.id.equals(l.id) & whereBusiness(t)))
            .write(
              OnlineOrderLinesCompanion(
                acceptedQty: Value(decided[l.id]),
                lastUpdatedAt: Value(now),
              ),
            );
        final row = await (select(onlineOrderLines)
              ..where((t) => t.id.equals(l.id) & whereBusiness(t)))
            .getSingle();
        await db.syncDao.enqueueUpsert('online_order_lines', row.toCompanion(true));
      }
      await (update(onlineOrders)
            ..where((t) => t.id.equals(order.id) & whereBusiness(t)))
          .write(
            OnlineOrdersCompanion(
              status: const Value('accepted'),
              customerId: Value(customerId),
              respondedAt: Value(now),
              lastUpdatedAt: Value(now),
            ),
          );
      await _enqueueFullOrder(order.id);
      return OnlineOrderAnswerOutcome.answered;
    });
  }

  /// line id -> quantity to accept; throws on a raise, an unknown line or an
  /// order with nothing left.
  static Map<String, int> _decideAcceptedQtys(
    List<OnlineOrderLineData> lines,
    Map<String, int> wanted,
  ) {
    final ids = lines.map((l) => l.id).toSet();
    for (final id in wanted.keys) {
      if (!ids.contains(id)) {
        throw ArgumentError.value(id, 'acceptedQtys', 'unknown line');
      }
    }
    final out = <String, int>{};
    for (final l in lines) {
      final q = wanted[l.id] ?? l.requestedQty;
      if (q < 0 || q > l.requestedQty) {
        throw ArgumentError.value(
          q,
          'acceptedQtys',
          'must be 0..${l.requestedQty} (never raised)',
        );
      }
      out[l.id] = q;
    }
    if (lines.isNotEmpty && out.values.every((q) => q == 0)) {
      throw ArgumentError('every line removed: decline the order instead');
    }
    return out;
  }

  /// The shop's current retail price (kobo) per product on [onlineOrderId]'s
  /// lines, for the accept screen's price-change flag (#428).
  Stream<Map<String, int>> watchRetailPrices(String onlineOrderId) {
    final q = db.select(db.products).join([
      innerJoin(
        onlineOrderLines,
        onlineOrderLines.productId.equalsExp(db.products.id),
      ),
    ])
      ..where(
        onlineOrderLines.onlineOrderId.equals(onlineOrderId) &
            whereBusiness(onlineOrderLines) &
            whereBusiness(db.products),
      );
    return q.watch().map(
      (rows) => {
        for (final r in rows)
          r.readTable(db.products).id:
              r.readTable(db.products).retailerPriceKobo,
      },
    );
  }

  /// Cancel an ACCEPTED order with the reason the Shopper will see (#428).
  /// Moves nothing: an accepted order never moved stock or money.
  Future<OnlineOrderAnswerOutcome> cancelAccepted({
    required String onlineOrderId,
    required String reason,
  }) {
    final trimmed = reason.trim();
    if (trimmed.isEmpty || trimmed.length > kOnlineOrderReasonMaxLength) {
      throw ArgumentError.value(reason, 'reason', 'must be 1–300 characters');
    }
    return transaction(() async {
      final order = await (select(onlineOrders)
            ..where((t) => t.id.equals(onlineOrderId) & whereBusiness(t))
            ..limit(1))
          .getSingleOrNull();
      if (order == null || order.status != 'accepted') {
        return OnlineOrderAnswerOutcome.alreadyAnswered;
      }
      await (update(onlineOrders)
            ..where((t) => t.id.equals(order.id) & whereBusiness(t)))
          .write(
            OnlineOrdersCompanion(
              status: const Value('cancelled_by_shop'),
              cancelReason: Value(trimmed),
              lastUpdatedAt: Value(DateTime.now()),
            ),
          );
      await _enqueueFullOrder(order.id);
      return OnlineOrderAnswerOutcome.answered;
    });
  }

  /// Decline a `new` order with the reason the Shopper will see.
  Future<OnlineOrderAnswerOutcome> decline({
    required String onlineOrderId,
    required String reason,
  }) {
    final trimmed = reason.trim();
    if (trimmed.isEmpty || trimmed.length > kOnlineOrderReasonMaxLength) {
      throw ArgumentError.value(reason, 'reason', 'must be 1–300 characters');
    }
    return transaction(() async {
      final order = await _openOrder(onlineOrderId);
      if (order == null) return OnlineOrderAnswerOutcome.alreadyAnswered;
      final now = DateTime.now();
      await (update(onlineOrders)
            ..where((t) => t.id.equals(order.id) & whereBusiness(t)))
          .write(
            OnlineOrdersCompanion(
              status: const Value('declined'),
              declineReason: Value(trimmed),
              respondedAt: Value(now),
              lastUpdatedAt: Value(now),
            ),
          );
      await _enqueueFullOrder(order.id);
      return OnlineOrderAnswerOutcome.answered;
    });
  }

  /// What Send to till (#431) loads into the Cart: an ACCEPTED order's lines
  /// with accepted_qty > 0, each with its live product and the stock of the
  /// order's store, plus the linked Customer. Null when the order is not (or no
  /// longer) accepted here. Reads only; nothing is written.
  Future<OnlineOrderTillLoad?> tillLoad(String onlineOrderId) async {
    final order =
        await (select(onlineOrders)
              ..where((t) => t.id.equals(onlineOrderId) & whereBusiness(t))
              ..limit(1))
            .getSingleOrNull();
    if (order == null || order.status != 'accepted') return null;
    final lines = await (select(onlineOrderLines)
          ..where((t) => t.onlineOrderId.equals(order.id) & whereBusiness(t))
          ..orderBy([
            (t) => OrderingTerm(expression: t.createdAt),
            (t) => OrderingTerm(expression: t.productName),
          ]))
        .get();
    final out = <OnlineOrderTillLine>[];
    final missing = <String>[];
    for (final l in lines) {
      if ((l.acceptedQty ?? l.requestedQty) <= 0) continue;
      final product =
          await (db.select(db.products)
                ..where(
                  (p) =>
                      p.id.equals(l.productId) &
                      whereBusiness(p) &
                      p.isDeleted.not(),
                )
                ..limit(1))
              .getSingleOrNull();
      if (product == null) {
        missing.add(l.productName);
        continue;
      }
      final inv =
          await (db.select(db.inventory)
                ..where(
                  (i) =>
                      i.productId.equals(product.id) &
                      i.storeId.equals(order.storeId) &
                      whereBusiness(i),
                )
                ..limit(1))
              .getSingleOrNull();
      out.add(
        OnlineOrderTillLine(line: l, product: product, stock: inv?.quantity ?? 0),
      );
    }
    final customerId = order.customerId;
    final customer = customerId == null
        ? null
        : await (select(customers)
                ..where(
                  (c) =>
                      c.id.equals(customerId) &
                      whereBusiness(c) &
                      c.isDeleted.not(),
                )
                ..limit(1))
              .getSingleOrNull();
    return OnlineOrderTillLoad(
      order: order,
      lines: out,
      customer: customer,
      missing: missing,
    );
  }

  /// Checkout of a Cart tagged with [onlineOrderId] (#431): `accepted` ->
  /// `fulfilled` linked to the new sale [orderId]. Called by
  /// `OrdersDao.createOrder` INSIDE the sale's transaction, so the two commit
  /// together. A no-op (false) when the order is no longer accepted here or
  /// belongs to another store: the sale itself is never blocked.
  ///
  /// [heldByOrderId] holds the outbox row behind the sale's v2 envelope (the
  /// cloud `linked_order_id` FK needs the order first); v1 relies on the push
  /// priority (orders before online_orders).
  Future<bool> markFulfilled({
    required String onlineOrderId,
    required String orderId,
    required String? storeId,
    String? heldByOrderId,
  }) async {
    final order =
        await (select(onlineOrders)
              ..where((t) => t.id.equals(onlineOrderId) & whereBusiness(t))
              ..limit(1))
            .getSingleOrNull();
    if (order == null || order.status != 'accepted') return false;
    if (storeId != null && order.storeId != storeId) return false;
    await (update(onlineOrders)
          ..where((t) => t.id.equals(order.id) & whereBusiness(t)))
        .write(
          OnlineOrdersCompanion(
            status: const Value('fulfilled'),
            linkedOrderId: Value(orderId),
            lastUpdatedAt: Value(DateTime.now()),
          ),
        );
    final row = await (select(
      onlineOrders,
    )..where((t) => t.id.equals(order.id) & whereBusiness(t))).getSingle();
    await db.syncDao.enqueueUpsert(
      'online_orders',
      row.toCompanion(true),
      heldByOrderId: heldByOrderId,
    );
    return true;
  }

  /// The sale [orderId] was rejected by the server and reversed locally: the
  /// Online Order it fulfilled goes back to `accepted` (its held `fulfilled`
  /// push was discarded with the sale). Re-queued so a coalesced, discarded
  /// accept still reaches the cloud.
  Future<void> reopenForRejectedSale(String orderId) async {
    final linked = await (select(onlineOrders)
          ..where(
            (t) =>
                t.linkedOrderId.equals(orderId) &
                t.status.equals('fulfilled') &
                whereBusiness(t),
          ))
        .get();
    for (final o in linked) {
      await (update(onlineOrders)
            ..where((t) => t.id.equals(o.id) & whereBusiness(t)))
          .write(
            OnlineOrdersCompanion(
              status: const Value('accepted'),
              linkedOrderId: const Value(null),
              lastUpdatedAt: Value(DateTime.now()),
            ),
          );
      await _enqueueFullOrder(o.id);
    }
  }

  // ── Pay on delivery (#432) ────────────────────────────────────────────────
  //
  // A Pay on delivery order is a `credit` order an Online Order is linked to.
  // What it has collected is the sum of the live Record Payment credits
  // (`topup_cash` / `topup_transfer` with their `wallet_topup` payment row)
  // that carry its id (Mark as paid). A sale's own paid-now leg has no payment
  // row of its own, so it never counts.
  static const String _payOnDeliverySql =
      'SELECT o.id AS order_id, oo.id AS online_order_id, o.store_id, '
      'o.customer_id, o.status, '
      '(o.net_amount_kobo - o.amount_paid_kobo) AS due_kobo, '
      'COALESCE((SELECT SUM(w.amount_kobo) FROM wallet_transactions w '
      "WHERE w.business_id = o.business_id AND w.order_id = o.id "
      "AND w.type = 'credit' "
      "AND w.reference_type IN ('topup_cash', 'topup_transfer') "
      'AND w.voided_at IS NULL '
      'AND EXISTS (SELECT 1 FROM payment_transactions p '
      "WHERE p.wallet_txn_id = w.id AND p.type = 'wallet_topup')), 0) "
      'AS collected_kobo '
      'FROM online_orders oo '
      'JOIN orders o ON o.id = oo.linked_order_id '
      'AND o.business_id = oo.business_id '
      "WHERE oo.business_id = ? AND o.payment_type = 'credit'";

  PayOnDeliveryOrder _payOnDeliveryFrom(QueryRow r) => PayOnDeliveryOrder(
    orderId: r.read<String>('order_id'),
    onlineOrderId: r.read<String>('online_order_id'),
    storeId: r.readNullable<String>('store_id'),
    customerId: r.readNullable<String>('customer_id'),
    status: r.read<String>('status'),
    dueKobo: r.read<int>('due_kobo'),
    collectedKobo: r.read<int>('collected_kobo'),
  );

  /// Every Pay on delivery order of the business (any status).
  Stream<List<PayOnDeliveryOrder>> watchPayOnDelivery() {
    return customSelect(
      _payOnDeliverySql,
      variables: [Variable<String>(requireBusinessId())],
      readsFrom: {
        onlineOrders,
        db.orders,
        db.walletTransactions,
        db.paymentTransactions,
      },
    ).watch().map((rows) => rows.map(_payOnDeliveryFrom).toList());
  }

  /// The Pay on delivery state of [orderId], or null when it is not one.
  Future<PayOnDeliveryOrder?> payOnDeliveryFor(String orderId) async {
    final rows = await customSelect(
      '$_payOnDeliverySql AND o.id = ? LIMIT 1',
      variables: [
        Variable<String>(requireBusinessId()),
        Variable<String>(orderId),
      ],
      readsFrom: {
        onlineOrders,
        db.orders,
        db.walletTransactions,
        db.paymentTransactions,
      },
    ).get();
    return rows.isEmpty ? null : _payOnDeliveryFrom(rows.first);
  }

  Future<OnlineOrderData?> _openOrder(String id) async {
    final order =
        await (select(onlineOrders)
              ..where((t) => t.id.equals(id) & whereBusiness(t))
              ..limit(1))
            .getSingleOrNull();
    if (order == null || order.status != 'new') return null;
    return order;
  }

  Future<void> _linkExisting({
    required String customerId,
    required String shopper,
  }) async {
    final affected =
        await (update(customers)..where(
              (t) =>
                  t.id.equals(customerId) &
                  whereBusiness(t) &
                  t.isDeleted.not() &
                  t.shopperAccountId.isNull(),
            ))
            .write(
              CustomersCompanion(
                shopperAccountId: Value(shopper),
                lastUpdatedAt: Value(DateTime.now()),
              ),
            );
    if (affected == 0) {
      throw StateError('customer $customerId cannot be linked');
    }
    final row = await (select(
      customers,
    )..where((t) => t.id.equals(customerId) & whereBusiness(t))).getSingle();
    await db.syncDao.enqueueUpsert('customers', row.toCompanion(true));
  }

  /// A new Retailer Customer from the order's own details, already linked.
  Future<String> _createRetailer(OnlineOrderData order, String shopper) {
    final address = [
      order.deliveryStreet,
      order.deliveryLga,
      order.deliveryState,
    ].where((p) => p.trim().isNotEmpty).join(', ');
    return db.customersDao.addCustomer(
      CustomersCompanion.insert(
        businessId: order.businessId,
        name: order.shopperName,
        storeId: Value(order.storeId),
        phone: Value(order.deliveryPhone),
        address: Value(address.isEmpty ? null : address),
        priceTier: const Value('retailer'),
        shopperAccountId: Value(shopper),
      ),
      viaTablePush: true,
    );
  }

  /// Full-row upsert; the registry's push whitelist keeps the cloud-owned
  /// placement snapshots (timestamps, total, note) off the wire.
  Future<void> _enqueueFullOrder(String id) async {
    final row = await (select(
      onlineOrders,
    )..where((t) => t.id.equals(id) & whereBusiness(t))).getSingle();
    await db.syncDao.enqueueUpsert('online_orders', row.toCompanion(true));
  }
}
