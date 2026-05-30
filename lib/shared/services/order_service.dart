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
    if (amountPaidKobo > 0 && (fundsAccountId == null || fundsAccountId.isEmpty)) {
      throw ArgumentError(
        'A paid sale must credit a Funds Register account (fundsAccountId)',
      );
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
      status: 'completed',
      staffId: Value(staffId),
      storeId: Value(storeId),
      crateDepositPaidKobo: Value(crateDepositPaidKobo),
      completedAt: Value(DateTime.now().toUtc()),
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

    return orderNumber;
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
          final productId = item['id'] as String?;
          if (productId == null || productId.isEmpty) {
            throw ArgumentError(
              'Cart contains an item without a product id (Quick Sale '
              'items cannot be saved as orders).',
            );
          }

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
            productId: productId,
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

  Future<void> markAsCancelled(String orderId, String reason, String staffId) {
    return _ordersDao.markCancelled(orderId, reason, staffId);
  }

  Future<void> assignRider(String orderId, String riderName) {
    return _ordersDao.assignRider(orderId, riderName);
  }
}
