import 'dart:convert';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:flutter/foundation.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/shared/models/order.dart' as domain;

class OrderService {
  final AppDatabase _db;
  final SupabaseSyncService? _syncService;
  late final OrdersDao _ordersDao = _db.ordersDao;

  OrderService(this._db, [this._syncService]);

  /// Build an order from a UI cart and persist it atomically.
  ///
  /// Returns the human-readable order number (e.g. `ORD-000042`) — the
  /// checkout/receipt code displays this to the user.
  Future<String> addOrder({
    required String? customerId,
    required List<Map<String, dynamic>> cart,
    required int totalAmountKobo,
    required int amountPaidKobo,
    required String paymentType,
    String? staffId,
    String? storeId,
    int crateDepositPaidKobo = 0,
    int discountKobo = 0,
    String paymentSubType = 'cash',
    String? fundsAccountId,
    String? businessDate,
  }) async {
    if (staffId == null || staffId.isEmpty) {
      throw ArgumentError('staffId is required');
    }
    if (storeId == null || storeId.isEmpty) {
      throw ArgumentError('storeId is required');
    }
    if (cart.isEmpty) {
      throw ArgumentError('cart is empty');
    }
    // Hard rule #5: any money that actually arrives (cash / card / transfer)
    // must land in a Funds Register account. Wallet and credit sales pay 0 now
    // and route through the wallet, so they don't need one.
    if (amountPaidKobo > 0) {
      if (fundsAccountId == null || fundsAccountId.isEmpty) {
        throw ArgumentError(
          'A paid sale must credit a Funds Register account (fundsAccountId)',
        );
      }
      // The Funds credit in OrdersDao.createOrder only fires when BOTH the
      // account and the businessDate are present. If businessDate were null
      // (e.g. todaysBusinessDateProvider not yet resolved) the payment row
      // would still be written but the money would never land in any account.
      // Fail loudly here instead of silently dropping the ledger entry.
      if (businessDate == null || businessDate.isEmpty) {
        throw ArgumentError(
          'A paid sale must carry a businessDate to bucket the Funds credit',
        );
      }
    }

    final orderId = UuidV7.generate();
    final orderNumber = await _ordersDao.generateOrderNumber();

    final dbPaymentType = _resolvePaymentType(
      paymentSubType: paymentSubType,
      amountPaidKobo: amountPaidKobo,
      totalAmountKobo: totalAmountKobo,
    );
    final walletDebitKobo = _resolveWalletDebit(
      dbPaymentType: dbPaymentType,
      amountPaidKobo: amountPaidKobo,
      totalAmountKobo: totalAmountKobo,
    );
    if (walletDebitKobo > 0 && (customerId == null || customerId.isEmpty)) {
      throw ArgumentError(
        'Wallet/credit/partial payments require a customerId',
      );
    }

    final items = _buildOrderItems(
      cart: cart,
      orderId: orderId,
      storeId: storeId,
    );

    final orderCompanion = OrdersCompanion.insert(
      id: Value(orderId),
      businessId: _ordersDao.requireBusinessId(),
      orderNumber: orderNumber,
      customerId: Value(customerId),
      totalAmountKobo: totalAmountKobo,
      // [totalAmountKobo] is the payable the customer owes, already net of
      // per-line discounts (the cart subtracts them before checkout). The
      // server's pos_record_sale_v2 RPC recomputes the gross from p_items and
      // derives net = gross − discount + crate_deposit, so we forward
      // [discountKobo] as the order's discount but must NOT re-subtract it from
      // the local net here — that would double-count. The server's response
      // overwrites these mirror values on success (_applyDomainResponse).
      discountKobo: Value(discountKobo),
      netAmountKobo: totalAmountKobo,
      amountPaidKobo: Value(amountPaidKobo),
      paymentType: dbPaymentType,
      // §19.5 lifecycle: a completed checkout lands the order in Pending
      // (already settled — received, or charged through the wallet, §14.3).
      // Confirm (OrdersDao.markCompleted) flips it to 'completed' and stamps
      // completedAt — for crate businesses that's after the Empty-Crates modal.
      // Revenue is recognized here at checkout, not at Confirm; the Funds credit
      // and wallet legs are already booked regardless of status. The v2 RPC
      // forwards this status via p_status, so both sync paths agree.
      status: 'pending',
      staffId: Value(staffId),
      storeId: Value(storeId),
      crateDepositPaidKobo: Value(crateDepositPaidKobo),
    );

    await _ordersDao.createOrder(
      order: orderCompanion,
      items: items,
      customerId: customerId,
      amountPaidKobo: amountPaidKobo,
      totalAmountKobo: totalAmountKobo,
      staffId: staffId,
      storeId: storeId,
      walletDebitKobo: walletDebitKobo,
      paymentMethod: _resolvePaymentMethod(paymentSubType),
      fundsAccountId: fundsAccountId,
      businessDate: businessDate,
    );

    // Surface server-side errors (insufficient_stock from a concurrent
    // device, FK / unique violations) BEFORE the receipt prints. flushSale
    // is a no-op when offline, when the queue row is absent (already
    // drained by background push), or when the sale was enqueued under
    // the legacy multi-row path. On permanent failure we compensate
    // locally — cancel the order, refund the inventory cache — so the
    // device's view stays consistent with the cloud's "this sale never
    // happened".
    if (_syncService != null && _syncService.isOnline.value) {
      try {
        await _syncService.flushSale(orderId);
      } on SaleSyncException catch (e) {
        debugPrint('[OrderService] Sale rejected by server: $e');
        await _compensateRejectedSale(orderId, items);
        rethrow;
      } catch (e) {
        // Transient error — the queue row stays pending and the
        // background drain will retry. Don't block the receipt.
        debugPrint('[OrderService] flushSale transient: $e');
      }
    }

    // §12.3 / §26.4: a Quick Sale is an off-inventory line. Once the sale is
    // accepted (a server-rejected sale rethrows above and never reaches here),
    // record it in the activity log and alert CEO + Manager for audit.
    final quickLines = cart.where((c) {
      final id = c['id'] as String?;
      return id == null || id.isEmpty;
    }).toList(growable: false);
    if (quickLines.isNotEmpty) {
      await _auditQuickSale(
        orderId: orderId,
        orderNumber: orderNumber,
        staffId: staffId,
        storeId: storeId,
        quickLines: quickLines,
      );
    }

    return orderNumber;
  }

  /// §12.3 / §26.4: audit a Quick Sale — write an activity-log entry and fire a
  /// CEO + Manager notification (Quick Sales bypass inventory, so they are
  /// tracked for oversight). Best-effort: a failure here must not fail the sale,
  /// which is already recorded.
  Future<void> _auditQuickSale({
    required String orderId,
    required String orderNumber,
    required String staffId,
    required String storeId,
    required List<Map<String, dynamic>> quickLines,
  }) async {
    try {
      final summary = quickLines.map((c) {
        final name = (c['name'] as String?)?.trim();
        final qty = (c['qty'] as num?)?.toString() ?? '1';
        return '$qty× ${name == null || name.isEmpty ? 'Quick Sale' : name}';
      }).join(', ');

      await _db.activityLogDao.log(
        action: 'quick_sale',
        description: 'Quick Sale on $orderNumber: $summary',
        staffId: staffId,
        storeId: storeId,
        orderId: orderId,
      );

      final recipients = await _db.userBusinessesDao
          .getUserIdsForRoleSlugs(['ceo', 'manager']);
      for (final uid in (recipients.isEmpty ? [staffId] : recipients)) {
        await _db.notificationsDao.fireNotification(
          type: 'quick_sale_used',
          message: 'Quick Sale on $orderNumber: $summary',
          severity: 'warning',
          linkedRecordId: orderId,
          recipientUserId: uid,
        );
      }
    } catch (e) {
      debugPrint('[OrderService] quick-sale audit failed (non-fatal): $e');
    }
  }

  /// Reverses the local writes performed by `OrdersDao.createOrder` when
  /// the server's `pos_record_sale` RPC permanently rejected the sale
  /// (e.g. insufficient_stock from a concurrent device). The cloud never
  /// saw any of this — the RPC rolled back its own transaction — so the
  /// compensation is purely local: we don't enqueue it. The original
  /// `domain:pos_record_sale` queue row was already marked failed by
  /// SyncService.
  Future<void> _compensateRejectedSale(
    String orderId,
    List<OrderItemsCompanion> items,
  ) async {
    // sync-exempt: §5 #3 — local-only reversal of writes the cloud's RPC
    // already rolled back (insufficient_stock etc.); nothing to push.
    await _db.transaction(() async {
      // 1. Mark order cancelled.
      await (_db.update(_db.orders)
            ..where((t) => t.id.equals(orderId)))
          .write(OrdersCompanion(
        status: const Value('cancelled'),
        cancellationReason: const Value('rejected_by_server'),
        cancelledAt: Value(DateTime.now().toUtc()),
        lastUpdatedAt: Value(DateTime.now()),
      ));

      // 2. Refund inventory cache. Each item's optimistic deduction is
      // undone by adding the quantity back. The corresponding
      // stock_transactions ledger rows are append-only — we leave them
      // in place; they're orphaned but harmless because the cloud's
      // ledger never received them either.
      for (final item in items) {
        final qty = item.quantity.value;
        final productId = item.productId.value;
        // Quick-sale line (§26.4): never deducted inventory → nothing to refund.
        if (productId == null) continue;
        final whId = item.storeId.value;
        await _db.customUpdate(
          'UPDATE inventory SET quantity = quantity + ?, last_updated_at = ? '
          'WHERE business_id = ? AND product_id = ? AND store_id = ?',
          variables: [
            Variable<int>(qty),
            Variable<DateTime>(DateTime.now()),
            Variable<String>(_ordersDao.requireBusinessId()),
            Variable<String>(productId),
            Variable<String>(whId),
          ],
          updates: {_db.inventory},
        );
      }
    });
  }

  String _resolvePaymentType({
    required String paymentSubType,
    required int amountPaidKobo,
    required int totalAmountKobo,
  }) {
    if (paymentSubType == 'wallet') return 'wallet';
    if (amountPaidKobo <= 0) return 'credit';
    if (amountPaidKobo < totalAmountKobo) return 'mixed';
    return 'cash';
  }

  int _resolveWalletDebit({
    required String dbPaymentType,
    required int amountPaidKobo,
    required int totalAmountKobo,
  }) {
    switch (dbPaymentType) {
      case 'wallet':
      case 'credit':
        return totalAmountKobo;
      case 'mixed':
        return totalAmountKobo - amountPaidKobo;
      default:
        return 0;
    }
  }

  String _resolvePaymentMethod(String paymentSubType) {
    if (paymentSubType == 'wallet') return 'wallet';
    if (paymentSubType == 'transfer') return 'transfer';
    if (paymentSubType == 'card' || paymentSubType == 'pos') {
      return paymentSubType;
    }
    return 'cash';
  }

  List<OrderItemsCompanion> _buildOrderItems({
    required List<Map<String, dynamic>> cart,
    required String orderId,
    required String storeId,
  }) {
    final businessId = _ordersDao.requireBusinessId();
    return cart
        .map((item) {
          // §12.3 Quick Sale: an item not in inventory has no product id. It is
          // recorded as a real order line with productId == null; its name is
          // carried in the priceSnapshot below. Quick-sale lines bypass
          // inventory (§26.4) — OrdersDao.createOrder skips the stock writes.
          final rawId = item['id'] as String?;
          final productId = (rawId == null || rawId.isEmpty) ? null : rawId;

          final qty = (item['qty'] as num).toInt();
          // Prefer the integer kobo snapshot; fall back to the legacy double
          // 'price' (Naira) for carts seeded before line-version tracking.
          final unitPriceKobo =
              (item['unitPriceKobo'] as int?) ??
              ((item['price'] as num).toDouble() * 100).round();
          final buyingPriceKobo = (item['buyingPriceKobo'] as int?) ?? 0;
          final totalKobo = unitPriceKobo * qty;
          final version = item['version'] as int?;

          final snapshot = jsonEncode({
            'name': item['name'],
            'unitPriceKobo': unitPriceKobo,
            if (version != null) 'version': version,
          });

          return OrderItemsCompanion.insert(
            businessId: businessId,
            orderId: orderId,
            productId: Value(productId),
            storeId: storeId,
            quantity: qty,
            unitPriceKobo: unitPriceKobo,
            buyingPriceKobo: Value(buyingPriceKobo),
            totalKobo: totalKobo,
            priceSnapshot: Value(snapshot),
          );
        })
        .toList(growable: false);
  }

  Stream<List<domain.Order>> watchPendingOrders() {
    return _ordersDao.watchPendingOrders().map<List<domain.Order>>(
      (list) => list.map<domain.Order>((d) => OrderService.fromDb(d)).toList(),
    );
  }

  Stream<List<domain.Order>> watchAllOrders() {
    return _ordersDao.watchAllOrders().map<List<domain.Order>>(
      (list) => list.map<domain.Order>((d) => OrderService.fromDb(d)).toList(),
    );
  }

  Stream<List<domain.Order>> watchCompletedOrders() {
    return _ordersDao.watchCompletedOrders().map<List<domain.Order>>(
      (list) => list.map<domain.Order>((d) => OrderService.fromDb(d)).toList(),
    );
  }

  Stream<List<OrderWithItems>> watchAllOrdersWithItems() {
    return _ordersDao.watchAllOrdersWithItems();
  }

  Future<List<CartStaleItem>> checkCartStaleness(List<CartLineSnapshot> lines) {
    return _ordersDao.checkCartStaleness(lines);
  }

  static domain.Order fromDb(OrderData data) {
    return domain.Order(
      id: data.id.toString(),
      customerId: data.customerId?.toString(),
      customerName: 'Customer ${data.customerId}',
      items: [],
      totalAmount: data.totalAmountKobo / 100.0,
      amountPaid: data.amountPaidKobo / 100.0,
      customerWallet: 0.0,
      paymentMethod: data.paymentType,
      createdAt: data.createdAt,
      status: data.status,
    );
  }

  Future<void> markAsCompleted(String orderId, String staffId) {
    return _ordersDao.markCompleted(orderId, staffId);
  }

  /// Refund/cancel an order. [businessDate] is the refund day (the caller's
  /// "today", `YYYY-MM-DD`) — the Funds Register reversal is dated to it so the
  /// cash-out lands on the day it leaves the till (§19.7 / §23.5).
  Future<void> markAsCancelled(
    String orderId,
    String reason,
    String staffId, {
    required String businessDate,
  }) {
    return _ordersDao.markCancelled(
      orderId,
      reason,
      staffId,
      businessDate: businessDate,
    );
  }

  Future<void> assignRider(String orderId, String riderName) {
    return _ordersDao.assignRider(orderId, riderName);
  }
}
