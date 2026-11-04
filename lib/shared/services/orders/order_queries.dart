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

  /// #685 - only the orders that can put a report entry on a day in
  /// `[from, to]` (see `OrdersDao.watchAllOrdersWithItems`).
  Stream<List<OrderWithItems>> watchOrdersWithItemsForEntryDays({
    DateTime? from,
    DateTime? to,
  }) {
    return _ordersDao.watchAllOrdersWithItems(
      entryDayFrom: from,
      entryDayTo: to,
    );
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
    Set<String> excludeStoreIds = const {},
    ({DateTime createdAt, String id})? cursor,
    int limit = 30,
  }) {
    return _ordersDao.getOrdersPage(
      status: status,
      storeId: storeId,
      from: from,
      to: to,
      search: search,
      excludeStoreIds: excludeStoreIds,
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
    Set<String> excludeStoreIds = const {},
    int limit = 30,
  }) {
    return _ordersDao.watchOrdersPage(
      status: status,
      storeId: storeId,
      from: from,
      to: to,
      search: search,
      excludeStoreIds: excludeStoreIds,
      limit: limit,
    );
  }

  Stream<OrdersStats> watchOrdersStats({
    required String status,
    String? storeId,
    DateTime? from,
    DateTime? to,
    String? search,
    Set<String> excludeStoreIds = const {},
  }) {
    return _ordersDao.watchOrdersStats(
      status: status,
      storeId: storeId,
      from: from,
      to: to,
      search: search,
      excludeStoreIds: excludeStoreIds,
    );
  }

  Future<List<CartStaleItem>> checkCartStaleness(List<CartLineSnapshot> lines) {
    return _ordersDao.checkCartStaleness(lines);
  }

  /// Whether a Completed sale may be Returned (#551, PRD #337): completed, no
  /// crate history, no crate-tracked bottle line. Business-scoped reads.
  Future<int> refundablePaidKobo(String orderId) =>
      _ordersDao.refundablePaidKobo(orderId);

  Future<bool> isReturnable(String orderId) =>
      _ordersDao.isReturnable(orderId);

  /// #733 — whether the Pending-tab Refund may run (an old order with money
  /// paid on it can't be refunded).
  Future<bool> canRefundPending(String orderId) async =>
      await _ordersDao.pendingRefundRefusal(orderId) == null;

  /// #712 — units still returnable per line ("up to N").
  Future<Map<String, double>> returnableQtyByLine(String orderId) =>
      _ordersDao.returnableQtyByLine(orderId);

  /// #732 — a sale's goods per product, added goods included, for the Return
  /// and Edit sheets.
  Future<List<ReturnableGoods>> returnableGoods(String orderId) =>
      _ordersDao.returnableGoods(orderId);

  /// #712 — what a part return of [qtyByLineId] would do, without writing.
  Future<PartReturnPlan> planPartReturn(
    String orderId,
    Map<String, double> qtyByLineId,
  ) => _ordersDao.planPartReturn(orderId, qtyByLineId);

  /// #713 — what an edit of a completed sale would do, without writing.
  Future<EditSalePlan> planEditSale(
    String orderId,
    Map<String, double> newQtyByLineId,
    List<EditAddedLine> addedLines,
  ) => _ordersDao.planEditSale(orderId, newQtyByLineId, addedLines);

  /// #712 — the part returns of a sale with their minus lines, live.
  Stream<List<SaleAdjustmentLines>> watchAdjustmentsWithLines(String orderId) =>
      _ordersDao.watchAdjustmentsWithLines(orderId);

  /// #711 — empties to hand back and deposit to pay back on a Return.
  Future<ReturnCratePlan> returnPlan(String orderId) =>
      _ordersDao.returnPlan(orderId);

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
