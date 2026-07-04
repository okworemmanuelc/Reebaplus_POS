import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/shared/models/order.dart' as domain;
import 'package:reebaplus_pos/shared/services/orders/crate_return_input.dart';
import 'package:reebaplus_pos/shared/services/orders/order_commands.dart';
import 'package:reebaplus_pos/shared/services/orders/order_queries.dart';
import 'package:reebaplus_pos/shared/services/orders/sale_flusher.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';

/// The Order module's single front door (ADR 0004). One deep module over
/// everything order-shaped, split *internally* into two surfaces the outside
/// world never sees separately:
///
/// * [OrderCommands] — the lifecycle writes (Checkout / Confirm / Cancel) and
///   their invariants, cloud push via the [SaleFlusher] seam;
/// * [OrderQueries] — read projections (live streams, paging, stats).
///
/// The facade preserves the historical `OrderService` API so its call sites and
/// `orderServiceProvider` are untouched; it sits on top of `OrdersDao`, which
/// remains the persistence seam.
class OrderService {
  final OrderCommands _commands;
  final OrderQueries _queries;

  OrderService(
    AppDatabase db, [
    SupabaseSyncService? syncService,
    SecureStorageService? secureStorage,
  ]) : _commands = OrderCommands(
         db,
         syncService != null
             ? SyncSaleFlusher(syncService)
             : const NoopSaleFlusher(),
         secureStorage,
       ),
       _queries = OrderQueries(db);

  // ── Commands (Checkout / Confirm / Cancel) ─────────────────────────────────

  /// **Checkout** — build an order from a UI cart and persist it atomically.
  /// Returns the human-readable order number (e.g. `ORD-000042`).
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
    int walletBalanceKobo = 0,
    Map<String, int> crateDepositPaidByManufacturer = const {},
  }) {
    return _commands.checkout(
      customerId: customerId,
      cart: cart,
      totalAmountKobo: totalAmountKobo,
      amountPaidKobo: amountPaidKobo,
      paymentType: paymentType,
      staffId: staffId,
      storeId: storeId,
      crateDepositPaidKobo: crateDepositPaidKobo,
      discountKobo: discountKobo,
      paymentSubType: paymentSubType,
      walletBalanceKobo: walletBalanceKobo,
      crateDepositPaidByManufacturer: crateDepositPaidByManufacturer,
    );
  }

  /// **Confirm** — settle counted-back empties (if any), then flip
  /// `pending`→`completed`. [crateReturns] is empty for a non-crate order.
  Future<void> markAsCompleted(
    String orderId,
    String staffId, {
    String? customerId,
    String? storeId,
    List<CrateReturnLine> crateReturns = const [],
    bool refundAsCash = false,
  }) {
    return _commands.confirm(
      orderId,
      staffId,
      customerId: customerId,
      storeId: storeId,
      crateReturns: crateReturns,
      refundAsCash: refundAsCash,
    );
  }

  /// **Cancel** / refund (§19.7): reverses stock, payments, credit-balance legs.
  Future<void> markAsCancelled(String orderId, String reason, String staffId) {
    return _commands.cancel(orderId, reason, staffId);
  }

  Future<void> assignRider(String orderId, String riderName) {
    return _commands.assignRider(orderId, riderName);
  }

  // ── Queries ────────────────────────────────────────────────────────────────

  Stream<List<domain.Order>> watchPendingOrders() =>
      _queries.watchPendingOrders();

  Stream<List<domain.Order>> watchAllOrders() => _queries.watchAllOrders();

  Stream<List<domain.Order>> watchCompletedOrders() =>
      _queries.watchCompletedOrders();

  Stream<List<OrderWithItems>> watchAllOrdersWithItems() =>
      _queries.watchAllOrdersWithItems();

  Stream<List<OrderWithItems>> watchPendingOrdersWithItems({String? storeId}) =>
      _queries.watchPendingOrdersWithItems(storeId: storeId);

  Stream<List<OrderData>> watchOrdersByCustomer(String customerId) =>
      _queries.watchOrdersByCustomer(customerId);

  Future<ProductSalesSummary> getSalesSummaryForProduct(String productId) =>
      _queries.getSalesSummaryForProduct(productId);

  Future<List<OrderWithItems>> getOrdersPage({
    required String status,
    String? storeId,
    DateTime? from,
    DateTime? to,
    String? search,
    ({DateTime createdAt, String id})? cursor,
    int limit = 30,
  }) {
    return _queries.getOrdersPage(
      status: status,
      storeId: storeId,
      from: from,
      to: to,
      search: search,
      cursor: cursor,
      limit: limit,
    );
  }

  Stream<List<OrderWithItems>> watchOrdersPage({
    required String status,
    String? storeId,
    DateTime? from,
    DateTime? to,
    String? search,
    int limit = 30,
  }) {
    return _queries.watchOrdersPage(
      status: status,
      storeId: storeId,
      from: from,
      to: to,
      search: search,
      limit: limit,
    );
  }

  Stream<OrdersStats> watchOrdersStats({
    required String status,
    String? storeId,
    DateTime? from,
    DateTime? to,
    String? search,
  }) {
    return _queries.watchOrdersStats(
      status: status,
      storeId: storeId,
      from: from,
      to: to,
      search: search,
    );
  }

  Future<List<CartStaleItem>> checkCartStaleness(List<CartLineSnapshot> lines) =>
      _queries.checkCartStaleness(lines);

  static domain.Order fromDb(OrderData data) => OrderQueries.fromDb(data);
}
