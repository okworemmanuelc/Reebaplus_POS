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
  Future<OnlineOrderAnswerOutcome> accept({
    required String onlineOrderId,
    CustomerLinkChoice? link,
  }) {
    return transaction(() async {
      final order = await _openOrder(onlineOrderId);
      if (order == null) return OnlineOrderAnswerOutcome.alreadyAnswered;

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
