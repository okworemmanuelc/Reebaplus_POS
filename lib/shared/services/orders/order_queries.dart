import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/shared/models/order.dart' as domain;

/// The Order module's **query surface** (ADR 0004): read projections over the
/// order tables — live streams, paged history, stats, cart-staleness. Pure
/// reads, no invariants; it wraps `OrdersDao` reads and never writes. All order
/// reads in the app funnel through here (via the `OrderService` facade), so no
/// screen reaches into `OrdersDao` for an order read.
class OrderQueries {
  final AppDatabase _db;
  late final OrdersDao _ordersDao = _db.ordersDao;

  OrderQueries(this._db);

  Stream<List<domain.Order>> watchPendingOrders() {
    return _ordersDao.watchPendingOrders().map<List<domain.Order>>(
      (list) => list.map<domain.Order>(fromDb).toList(),
    );
  }

  Stream<List<domain.Order>> watchAllOrders() {
    return _ordersDao.watchAllOrders().map<List<domain.Order>>(
      (list) => list.map<domain.Order>(fromDb).toList(),
    );
  }

  Stream<List<domain.Order>> watchCompletedOrders() {
    return _ordersDao.watchCompletedOrders().map<List<domain.Order>>(
      (list) => list.map<domain.Order>(fromDb).toList(),
    );
  }

  Stream<List<OrderWithItems>> watchAllOrdersWithItems() {
    return _ordersDao.watchAllOrdersWithItems();
  }

  Stream<List<OrderWithItems>> watchPendingOrdersWithItems({String? storeId}) {
    return _ordersDao.watchPendingOrdersWithItems(storeId: storeId);
  }

  /// One customer's order history (was a direct `OrdersDao` call from
  /// customer_detail_screen; now routed through the query surface).
  Stream<List<OrderData>> watchOrdersByCustomer(String customerId) {
    return _ordersDao.watchOrdersByCustomer(customerId);
  }

  /// Per-product sales rollup (was a direct `OrdersDao` call from
  /// product_detail_screen; now routed through the query surface).
  Future<ProductSalesSummary> getSalesSummaryForProduct(String productId) {
    return _ordersDao.getSalesSummaryForProduct(productId);
  }

  Future<List<OrderWithItems>> getOrdersPage({
    required String status,
    String? storeId,
    DateTime? from,
    DateTime? to,
    String? search,
    ({DateTime createdAt, String id})? cursor,
    int limit = 30,
  }) {
    return _ordersDao.getOrdersPage(
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
    return _ordersDao.watchOrdersPage(
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
    return _ordersDao.watchOrdersStats(
      status: status,
      storeId: storeId,
      from: from,
      to: to,
      search: search,
    );
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
}
