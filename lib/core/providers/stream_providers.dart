/// Shared Drift stream providers.
///
/// Multiple screens that watch the same data share a single stream
/// automatically — Riverpod deduplicates by provider identity.
library;

import 'dart:async';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/data/currencies.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/settings/vat_settings.dart';
import 'package:reebaplus_pos/core/theme/theme_notifier.dart';
import 'package:reebaplus_pos/core/utils/business_time.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/shared/models/activity_log.dart';
import 'package:reebaplus_pos/shared/utils/role_display.dart';
import 'package:reebaplus_pos/features/subscription/subscription_access.dart';

// ── Orders ──────────────────────────────────────────────────────────────────
final allOrdersProvider = businessScopedStream<List<OrderWithItems>>(
  (ref, db, businessId) =>
      ref.watch(orderServiceProvider).watchAllOrdersWithItems(),
  whenAbsent: const [],
);

final pendingOrdersProvider =
    businessScopedStreamFamily<List<OrderWithItems>, String?>(
  (ref, db, businessId, storeId) =>
      ref.watch(orderServiceProvider).watchPendingOrdersWithItems(storeId: storeId),
  whenAbsent: const [],
);

class OrdersPageState {
  final List<OrderWithItems> orders;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;

  const OrdersPageState({
    required this.orders,
    required this.isLoading,
    required this.isLoadingMore,
    required this.hasMore,
  });

  OrdersPageState copyWith({
    List<OrderWithItems>? orders,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
  }) {
    return OrdersPageState(
      orders: orders ?? this.orders,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
    );
  }
}

class PaginatedOrdersNotifier extends StateNotifier<OrdersPageState> {
  final Ref _ref;
  final ({String status, String? storeId, String dateLabel, String search}) _arg;

  StreamSubscription<List<OrderWithItems>>? _headSubscription;
  List<OrderWithItems> _headOrders = const [];
  List<OrderWithItems> _tailOrders = const [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;

  PaginatedOrdersNotifier(this._ref, this._arg)
      : super(const OrdersPageState(
          orders: [],
          isLoading: true,
          isLoadingMore: false,
          hasMore: true,
        )) {
    _init();
  }

  void _init() {
    final (from, to) = dateRangeForLabel(_arg.dateLabel);

    final headStream = _ref.read(orderServiceProvider).watchOrdersPage(
          status: _arg.status,
          storeId: _arg.storeId,
          from: from,
          to: to,
          search: _arg.search,
          limit: 30,
        );

    _headSubscription?.cancel();
    _headSubscription = headStream.listen(
      (head) {
        _headOrders = head;
        _isLoading = false;
        if (head.length < 30) {
          _hasMore = false;
        } else {
          if (_tailOrders.isEmpty) {
            _hasMore = true;
          }
        }
        _emitState();
      },
      onError: (err, stack) {
        _isLoading = false;
        _emitState();
        debugPrint('Error in head stream: $err');
      },
    );

    _ref.onDispose(() {
      _headSubscription?.cancel();
    });
  }

  void _emitState() {
    final headIds = _headOrders.map((o) => o.order.id).toSet();
    // Note: In this live-head/static-tail design, if an order is created between 
    // the head's last row and the tail cursor after the tail is loaded, it will 
    // only appear after a manual pull-to-refresh (deduping by id prevents duplication).
    final filteredTail = _tailOrders.where((o) => !headIds.contains(o.order.id)).toList();

    state = OrdersPageState(
      orders: [..._headOrders, ...filteredTail],
      isLoading: _isLoading,
      isLoadingMore: _isLoadingMore,
      hasMore: _hasMore,
    );
  }

  Future<void> loadMore() async {
    if (_isLoadingMore || !_hasMore) return;

    _isLoadingMore = true;
    _emitState();

    try {
      final lastOrder = _tailOrders.isNotEmpty
          ? _tailOrders.last
          : (_headOrders.isNotEmpty ? _headOrders.last : null);
      if (lastOrder == null) {
        _hasMore = false;
        _isLoadingMore = false;
        _emitState();
        return;
      }

      final cursor = (createdAt: lastOrder.order.createdAt, id: lastOrder.order.id);
      final (from, to) = dateRangeForLabel(_arg.dateLabel);

      final nextPage = await _ref.read(orderServiceProvider).getOrdersPage(
            status: _arg.status,
            storeId: _arg.storeId,
            from: from,
            to: to,
            search: _arg.search,
            cursor: cursor,
            limit: 30,
          );

      if (nextPage.length < 30) {
        _hasMore = false;
      } else {
        _hasMore = true;
      }

      final existingIds = {
        ..._headOrders.map((o) => o.order.id),
        ..._tailOrders.map((o) => o.order.id)
      };
      final newUniqueItems = nextPage.where((o) => !existingIds.contains(o.order.id)).toList();

      _tailOrders = [..._tailOrders, ...newUniqueItems];
    } catch (err) {
      debugPrint('Error loading more orders: $err');
    } finally {
      _isLoadingMore = false;
      _emitState();
    }
  }

  @override
  void dispose() {
    _headSubscription?.cancel();
    super.dispose();
  }
}

final paginatedOrdersProvider = StateNotifierProvider.autoDispose.family<
    PaginatedOrdersNotifier,
    OrdersPageState,
    ({String status, String? storeId, String dateLabel, String search})
>((ref, arg) {
  return PaginatedOrdersNotifier(ref, arg);
});

final ordersStatsProvider = businessScopedStreamAutoDisposeFamily<
    OrdersStats,
    ({String status, String? storeId, String dateLabel, String search})
>(
  (ref, db, businessId, arg) {
    final (from, to) = dateRangeForLabel(arg.dateLabel);
    return ref.watch(orderServiceProvider).watchOrdersStats(
          status: arg.status,
          storeId: arg.storeId,
          from: from,
          to: to,
          search: arg.search,
        );
  },
  whenAbsent: OrdersStats.empty(),
);

// ── Activity Logs ───────────────────────────────────────────────────────────
class ActivityLogsPageState {
  final List<ActivityLog> logs;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;

  const ActivityLogsPageState({
    required this.logs,
    required this.isLoading,
    required this.isLoadingMore,
    required this.hasMore,
  });

  ActivityLogsPageState copyWith({
    List<ActivityLog>? logs,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
  }) {
    return ActivityLogsPageState(
      logs: logs ?? this.logs,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
    );
  }
}

class PaginatedActivityLogsNotifier extends StateNotifier<ActivityLogsPageState> {
  final Ref _ref;
  final String? _storeId;

  StreamSubscription<List<ActivityLogData>>? _headSubscription;
  List<ActivityLogData> _headLogsData = const [];
  List<ActivityLogData> _tailLogsData = const [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;

  PaginatedActivityLogsNotifier(this._ref, this._storeId)
      : super(const ActivityLogsPageState(
          logs: [],
          isLoading: true,
          isLoadingMore: false,
          hasMore: true,
        )) {
    _init();
  }

  void _init() {
    final headStream = _ref.read(databaseProvider).activityLogDao.watchActivityLogsPage(
          storeId: _storeId,
          limit: 30,
        );

    _headSubscription?.cancel();
    _headSubscription = headStream.listen(
      (head) {
        _headLogsData = head;
        _isLoading = false;
        if (head.length < 30) {
          _hasMore = false;
        } else {
          if (_tailLogsData.isEmpty) {
            _hasMore = true;
          }
        }
        _emitState();
      },
      onError: (err, stack) {
        _isLoading = false;
        _emitState();
        debugPrint('Error in activity log head stream: $err');
      },
    );

    _ref.onDispose(() {
      _headSubscription?.cancel();
    });
  }

  void _emitState() {
    final headIds = _headLogsData.map((l) => l.id).toSet();
    final filteredTail = _tailLogsData.where((l) => !headIds.contains(l.id)).toList();
    final combinedData = [..._headLogsData, ...filteredTail];
    final mappedLogs = combinedData.map((data) => ActivityLog.fromDb(data)).toList();

    state = ActivityLogsPageState(
      logs: mappedLogs,
      isLoading: _isLoading,
      isLoadingMore: _isLoadingMore,
      hasMore: _hasMore,
    );
  }

  Future<void> loadMore() async {
    if (_isLoadingMore || !_hasMore) return;

    _isLoadingMore = true;
    _emitState();

    try {
      final lastLog = _tailLogsData.isNotEmpty
          ? _tailLogsData.last
          : (_headLogsData.isNotEmpty ? _headLogsData.last : null);
      if (lastLog == null) {
        _hasMore = false;
        _isLoadingMore = false;
        _emitState();
        return;
      }

      final cursor = (createdAt: lastLog.createdAt, id: lastLog.id);

      final nextPage = await _ref.read(databaseProvider).activityLogDao.getActivityLogsPage(
            storeId: _storeId,
            cursor: cursor,
            limit: 30,
          );

      if (nextPage.length < 30) {
        _hasMore = false;
      } else {
        _hasMore = true;
      }

      final existingIds = {
        ..._headLogsData.map((l) => l.id),
        ..._tailLogsData.map((l) => l.id)
      };
      final newUniqueItems = nextPage.where((l) => !existingIds.contains(l.id)).toList();

      _tailLogsData = [..._tailLogsData, ...newUniqueItems];
    } catch (err) {
      debugPrint('Error loading more activity logs: $err');
    } finally {
      _isLoadingMore = false;
      _emitState();
    }
  }

  @override
  void dispose() {
    _headSubscription?.cancel();
    super.dispose();
  }
}

final paginatedActivityLogsProvider = StateNotifierProvider.autoDispose
    .family<PaginatedActivityLogsNotifier, ActivityLogsPageState, String?>((ref, storeId) {
  return PaginatedActivityLogsNotifier(ref, storeId);
});

// ── Stock History / Inventory History ───────────────────────────────────────
class StockHistoryPageState {
  final List<StockTransactionWithDetails> transactions;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;

  const StockHistoryPageState({
    required this.transactions,
    required this.isLoading,
    required this.isLoadingMore,
    required this.hasMore,
  });

  StockHistoryPageState copyWith({
    List<StockTransactionWithDetails>? transactions,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
  }) {
    return StockHistoryPageState(
      transactions: transactions ?? this.transactions,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
    );
  }
}

class PaginatedStockHistoryNotifier extends StateNotifier<StockHistoryPageState> {
  final Ref _ref;
  final ({String? storeId, String period}) _arg;

  StreamSubscription<List<StockTransactionWithDetails>>? _headSubscription;
  List<StockTransactionWithDetails> _headTransactions = const [];
  List<StockTransactionWithDetails> _tailTransactions = const [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  String _businessTz = 'UTC';

  PaginatedStockHistoryNotifier(this._ref, this._arg)
      : super(const StockHistoryPageState(
          transactions: [],
          isLoading: true,
          isLoadingMore: false,
          hasMore: true,
        )) {
    _init();
  }

  Future<void> _init() async {
    final db = _ref.read(databaseProvider);
    final businessId = db.currentBusinessId;
    if (businessId != null) {
      _businessTz = await getBusinessTimezone(db, businessId);
    }
    _startWatch();
  }

  (DateTime?, DateTime?) _getDateRange() {
    final now = DateTime.now();
    switch (_arg.period) {
      case 'Today':
        return (localDayStartUtc(now, _businessTz), null);
      case '7 Days':
        return (now.subtract(const Duration(days: 7)), null);
      case '30 Days':
        return (now.subtract(const Duration(days: 30)), null);
      case 'All':
      default:
        return (null, null);
    }
  }

  void _startWatch() {
    final dates = _getDateRange();
    final headStream = _ref.read(databaseProvider).stockLedgerDao.watchTransactionsPage(
          storeId: _arg.storeId,
          startDate: dates.$1,
          endDate: dates.$2,
          limit: 30,
        );

    _headSubscription?.cancel();
    _headSubscription = headStream.listen(
      (head) {
        _headTransactions = head;
        _isLoading = false;
        if (head.length < 30) {
          _hasMore = false;
        } else {
          if (_tailTransactions.isEmpty) {
            _hasMore = true;
          }
        }
        _emitState();
      },
      onError: (err, stack) {
        _isLoading = false;
        _emitState();
        debugPrint('Error in stock history head stream: $err');
      },
    );

    _ref.onDispose(() {
      _headSubscription?.cancel();
    });
  }

  void _emitState() {
    final headIds = _headTransactions.map((t) => t.transactionId).toSet();
    final filteredTail = _tailTransactions.where((t) => !headIds.contains(t.transactionId)).toList();

    state = StockHistoryPageState(
      transactions: [..._headTransactions, ...filteredTail],
      isLoading: _isLoading,
      isLoadingMore: _isLoadingMore,
      hasMore: _hasMore,
    );
  }

  Future<void> loadMore() async {
    if (_isLoadingMore || !_hasMore) return;

    _isLoadingMore = true;
    _emitState();

    try {
      final lastTx = _tailTransactions.isNotEmpty
          ? _tailTransactions.last
          : (_headTransactions.isNotEmpty ? _headTransactions.last : null);
      if (lastTx == null) {
        _hasMore = false;
        _isLoadingMore = false;
        _emitState();
        return;
      }

      final cursor = (createdAt: lastTx.createdAt, id: lastTx.transactionId);
      final dates = _getDateRange();

      final nextPage = await _ref.read(databaseProvider).stockLedgerDao.getTransactionsPage(
            storeId: _arg.storeId,
            startDate: dates.$1,
            endDate: dates.$2,
            cursor: cursor,
            limit: 30,
          );

      if (nextPage.length < 30) {
        _hasMore = false;
      } else {
        _hasMore = true;
      }

      final existingIds = {
        ..._headTransactions.map((t) => t.transactionId),
        ..._tailTransactions.map((t) => t.transactionId)
      };
      final newUniqueItems = nextPage.where((t) => !existingIds.contains(t.transactionId)).toList();

      _tailTransactions = [..._tailTransactions, ...newUniqueItems];
    } catch (err) {
      debugPrint('Error loading more stock history: $err');
    } finally {
      _isLoadingMore = false;
      _emitState();
    }
  }

  @override
  void dispose() {
    _headSubscription?.cancel();
    super.dispose();
  }
}

final paginatedStockHistoryProvider = StateNotifierProvider.autoDispose.family<
    PaginatedStockHistoryNotifier,
    StockHistoryPageState,
    ({String? storeId, String period})
>((ref, arg) {
  return PaginatedStockHistoryNotifier(ref, arg);
});

final stockHistoryStatsProvider = businessScopedStreamAutoDisposeFamily<
    StockHistoryStats,
    ({String? storeId, String period})
>(
  (ref, db, businessId, arg) async* {
    final tz = await getBusinessTimezone(db, businessId);

    final now = DateTime.now();
    DateTime? startDate;
    DateTime? endDate;
    switch (arg.period) {
      case 'Today':
        startDate = localDayStartUtc(now, tz);
        break;
      case '7 Days':
        startDate = now.subtract(const Duration(days: 7));
        break;
      case '30 Days':
        startDate = now.subtract(const Duration(days: 30));
        break;
      case 'All':
      default:
        break;
    }

    yield* db.stockLedgerDao.watchTransactionsStats(
      storeId: arg.storeId,
      startDate: startDate,
      endDate: endDate,
    );
  },
  whenAbsent: StockHistoryStats.empty(),
);

// ── Supplier Transaction History Pagination ──────────────────────────────────

class SupplierHistoryPageState {
  final List<SupplierLedgerEntryData> entries;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;

  const SupplierHistoryPageState({
    required this.entries,
    required this.isLoading,
    required this.isLoadingMore,
    required this.hasMore,
  });

  SupplierHistoryPageState copyWith({
    List<SupplierLedgerEntryData>? entries,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
  }) {
    return SupplierHistoryPageState(
      entries: entries ?? this.entries,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
    );
  }
}

class PaginatedSupplierHistoryNotifier
    extends StateNotifier<SupplierHistoryPageState> {
  final Ref _ref;
  final ({String? storeId, String period}) _arg;

  StreamSubscription<List<SupplierLedgerEntryData>>? _headSubscription;
  List<SupplierLedgerEntryData> _headEntries = const [];
  List<SupplierLedgerEntryData> _tailEntries = const [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;

  PaginatedSupplierHistoryNotifier(this._ref, this._arg)
      : super(const SupplierHistoryPageState(
          entries: [],
          isLoading: true,
          isLoadingMore: false,
          hasMore: true,
        )) {
    _startWatch();
  }

  DateTime? _getStartDate() {
    final (start, _) = dateRangeForLabel(_arg.period);
    return start;
  }

  void _startWatch() {
    final startDate = _getStartDate();
    final headStream =
        _ref.read(databaseProvider).supplierLedgerDao.watchSupplierHistoryPage(
              storeId: _arg.storeId,
              startDate: startDate,
              limit: 30,
            );

    _headSubscription?.cancel();
    _headSubscription = headStream.listen(
      (head) {
        _headEntries = head;
        _isLoading = false;
        if (head.length < 30) {
          _hasMore = false;
        } else {
          if (_tailEntries.isEmpty) {
            _hasMore = true;
          }
        }
        _emitState();
      },
      onError: (err, stack) {
        _isLoading = false;
        _emitState();
        debugPrint('Error in supplier history head stream: $err');
      },
    );

    _ref.onDispose(() {
      _headSubscription?.cancel();
    });
  }

  void _emitState() {
    final headIds = _headEntries.map((e) => e.id).toSet();
    final filteredTail =
        _tailEntries.where((e) => !headIds.contains(e.id)).toList();

    state = SupplierHistoryPageState(
      entries: [..._headEntries, ...filteredTail],
      isLoading: _isLoading,
      isLoadingMore: _isLoadingMore,
      hasMore: _hasMore,
    );
  }

  Future<void> loadMore() async {
    if (_isLoadingMore || !_hasMore) return;

    _isLoadingMore = true;
    _emitState();

    try {
      final lastEntry = _tailEntries.isNotEmpty
          ? _tailEntries.last
          : (_headEntries.isNotEmpty ? _headEntries.last : null);
      if (lastEntry == null) {
        _hasMore = false;
        _isLoadingMore = false;
        _emitState();
        return;
      }

      final cursor = (
        createdAt: lastEntry.createdAt,
        signedAmountKobo: lastEntry.signedAmountKobo,
        id: lastEntry.id,
      );
      final startDate = _getStartDate();

      final nextPage = await _ref
          .read(databaseProvider)
          .supplierLedgerDao
          .getSupplierHistoryPage(
            storeId: _arg.storeId,
            startDate: startDate,
            cursor: cursor,
            limit: 30,
          );

      _hasMore = nextPage.length >= 30;

      final existingIds = {
        ..._headEntries.map((e) => e.id),
        ..._tailEntries.map((e) => e.id),
      };
      final newUnique =
          nextPage.where((e) => !existingIds.contains(e.id)).toList();
      _tailEntries = [..._tailEntries, ...newUnique];
    } catch (err) {
      debugPrint('Error loading more supplier history: $err');
    } finally {
      _isLoadingMore = false;
      _emitState();
    }
  }

  @override
  void dispose() {
    _headSubscription?.cancel();
    super.dispose();
  }
}

final paginatedSupplierHistoryProvider = StateNotifierProvider.autoDispose
    .family<PaginatedSupplierHistoryNotifier, SupplierHistoryPageState,
        ({String? storeId, String period})>((ref, arg) {
  return PaginatedSupplierHistoryNotifier(ref, arg);
});

final supplierHistoryStatsProvider = businessScopedStreamAutoDisposeFamily<
    SupplierLedgerStats,
    ({String? storeId, String period})>(
  (ref, db, businessId, arg) {
    final (startDate, _) = dateRangeForLabel(arg.period);
    return db.supplierLedgerDao.watchSupplierHistoryStats(
      storeId: arg.storeId,
      startDate: startDate,
    );
  },
  whenAbsent: SupplierLedgerStats.empty(),
);

// ── Stores ──────────────────────────────────────────────────────────────────
/// Active stores for the bound business — the store picker feed (Receive
/// checkout, Request Stock, POS scope). Guarded by the factory (ADR 0003):
/// `watchActiveStores()` bakes the businessId at build time via
/// `requireBusinessId()`, which threw and stuck the whole session if first-built
/// in the null-businessId window; the factory returns `[]` until a business
/// binds and re-queries the instant it does.
final allStoresProvider = businessScopedStream<List<StoreData>>(
  (ref, db, businessId) => db.storesDao.watchActiveStores(),
  whenAbsent: const [],
);

/// Per-store SKU + quantity counts, keyed by store id. The silent-empty variant
/// of the build-time-poison bug: it read `db.currentBusinessId` synchronously
/// and stuck empty. The factory hands the closure the resolved non-null
/// businessId to bind into the custom SQL directly.
final storeInventoryCountsProvider =
    businessScopedStream<Map<String, ({int skuCount, int totalQuantity})>>(
  (ref, db, businessId) {
    return db.customSelect(
      'SELECT store_id, SUM(quantity) as qty, COUNT(DISTINCT product_id) as sku_count FROM inventory WHERE business_id = ? GROUP BY store_id',
      variables: [Variable(businessId)],
      readsFrom: {db.inventory},
    ).watch().map((rows) {
      final map = <String, ({int skuCount, int totalQuantity})>{};
      for (final row in rows) {
        final storeId = row.readNullable<String>('store_id');
        if (storeId != null) {
          map[storeId] = (
            skuCount: row.readNullable<num>('sku_count')?.toInt() ?? 0,
            totalQuantity: row.readNullable<num>('qty')?.toInt() ?? 0,
          );
        }
      }
      return map;
    });
  },
  whenAbsent: const {},
);

// ── Expenses ───────────────────────────────────────────────────────────────
final allExpensesProvider = businessScopedStream<List<ExpenseWithCategory>>(
  (ref, db, businessId) => db.expensesDao.watchAll(),
  whenAbsent: const [],
);

/// Map of expense category id → name. Resolves the category text for display
/// after the cached `expenses.category` column was removed.
final expenseCategoryNamesProvider = businessScopedStream<Map<String, String>>(
  (ref, db, businessId) => db.expensesDao
      .watchAllCategories()
      .map((cats) => {for (final c in cats) c.id: c.name}),
  whenAbsent: const {},
);

/// Count of expenses awaiting CEO approval (§20.1 — bell badge + the pending
/// section header). Business-scoped.
final pendingExpensesCountProvider = businessScopedStream<int>(
  (ref, db, businessId) => db.expensesDao.watchPendingCount(),
  whenAbsent: 0,
);

/// The store the Expenses screen is scoped to (§20.8): the active-store picker
/// (§12.1) drives it for everyone, exactly like Home / Inventory / POS / Supplier
/// Accounts. An all-stores viewer (CEO / all-stores Manager) follows the locked
/// store — `null` means "All Stores" (the business-wide aggregate). A confined
/// viewer is always pinned to their active store (locked, else their first
/// selectable store) so they never see another store's costs.
final expenseScopeStoreIdProvider = Provider.autoDispose<String?>((ref) {
  final locked = ref.watch(lockedStoreProvider).value;
  if (ref.watch(canViewAllStoresProvider)) return locked; // null = All Stores
  return locked ?? ref.watch(activeWriteStoreProvider).id;
});

/// Expenses visible in the current scope (§20.8): the active store's expenses, or
/// the business-wide aggregate under "All Stores". Replaces the old role-based
/// "CEO: all / Manager: own store" confinement — the scope now follows the
/// §12.1 picker. The budget bar's spend uses the same scope as its goal.
final viewerScopedExpensesProvider = Provider<List<ExpenseWithCategory>>((ref) {
  final all = ref.watch(allExpensesProvider).valueOrNull ?? const [];
  final scopeStoreId = ref.watch(expenseScopeStoreIdProvider);
  if (scopeStoreId == null) return all; // All Stores aggregate
  return all.where((e) => e.expense.storeId == scopeStoreId).toList();
});

/// All live monthly budget goals for the business (§20.1/§20.3). The
/// business-wide goal is the row with a null store_id; per-store goals carry a
/// store_id. Use [resolveMonthlyBudgetKobo] to pick the goal for a view's scope.
final expenseBudgetsProvider = businessScopedStream<List<ExpenseBudgetData>>(
  (ref, db, businessId) => db.expenseBudgetsDao.watchAll(),
  whenAbsent: const [],
);

/// Resolves the monthly budget goal (kobo) for a store scope: the store's own
/// goal if set, else the business-wide goal (null store_id), else null (unset).
int? resolveMonthlyBudgetKobo(
  List<ExpenseBudgetData> budgets,
  String? storeId,
) {
  if (storeId != null) {
    for (final b in budgets) {
      if (b.storeId == storeId) return b.amountKobo;
    }
  }
  for (final b in budgets) {
    if (b.storeId == null) return b.amountKobo;
  }
  return null;
}

// ── Stock adjustment approvals (§16.6.1) ─────────────────────────────────────
/// All still-pending stock-adjustment requests for the business, newest first.
/// Approver-side store scoping is applied by
/// [viewerScopedPendingStockRequestsProvider].
final pendingStockRequestsProvider =
    businessScopedStream<List<StockAdjustmentRequestData>>(
  (ref, db, businessId) => db.stockAdjustmentRequestsDao.watchPending(),
  whenAbsent: const [],
);

/// Pending stock requests the current viewer may approve (§16.6.1): a CEO sees
/// every store; a Manager sees only requests for the store(s) they're assigned
/// to (mirrors the Home/Inventory store lock — confinement is computed locally,
/// never via the dead nav-service flags).
final viewerScopedPendingStockRequestsProvider =
    Provider<List<StockAdjustmentRequestData>>((ref) {
      final all =
          ref.watch(pendingStockRequestsProvider).valueOrNull ?? const [];
      final role = ref.watch(currentUserRoleProvider);
      if (role?.slug == 'ceo') return all;
      final userId = ref.watch(authProvider).currentUser?.id;
      if (userId == null) return const [];
      final assignedStoreIds =
          (ref.watch(myUserStoresProvider(userId)).valueOrNull ??
                  const <UserStoreData>[])
              .map((s) => s.storeId)
              .toSet();
      return all.where((r) => assignedStoreIds.contains(r.storeId)).toList();
    });

// ── Quick Sale approvals (§12.3.1) ───────────────────────────────────────────
/// All still-pending cashier Quick Sale requests for the business, newest first.
/// Approver-side store scoping is applied by
/// [viewerScopedPendingQuickSaleRequestsProvider].
final pendingQuickSaleRequestsProvider =
    businessScopedStream<List<QuickSaleRequestData>>(
  (ref, db, businessId) => db.quickSaleRequestsDao.watchPending(),
  whenAbsent: const [],
);

/// Pending Quick Sale requests the current viewer may approve (§12.3.1): a CEO
/// sees every store; a Manager sees only requests for the store(s) they're
/// assigned to (mirrors [viewerScopedPendingStockRequestsProvider] — confinement
/// is computed locally, never via the dead nav-service flags).
final viewerScopedPendingQuickSaleRequestsProvider =
    Provider<List<QuickSaleRequestData>>((ref) {
      final all =
          ref.watch(pendingQuickSaleRequestsProvider).valueOrNull ?? const [];
      final role = ref.watch(currentUserRoleProvider);
      if (role?.slug == 'ceo') return all;
      final userId = ref.watch(authProvider).currentUser?.id;
      if (userId == null) return const [];
      final assignedStoreIds =
          (ref.watch(myUserStoresProvider(userId)).valueOrNull ??
                  const <UserStoreData>[])
              .map((s) => s.storeId)
              .toSet();
      return all.where((r) => assignedStoreIds.contains(r.storeId)).toList();
    });

// ── Stock Transfers (§16.8.1) ────────────────────────────────────────────────
/// All in_transit transfers for the business — the raw feed from which the
/// viewer-scoped providers derive their lists in memory.
final allInTransitTransfersProvider =
    businessScopedStream<List<StockTransferData>>(
  (ref, db, businessId) => db.stockTransferDao.watchAllInTransit(),
  whenAbsent: const [],
);

/// All `pending` transfer requests for the business — the raw feed the
/// viewer-scoped request providers derive their lists from in memory.
final allPendingTransfersProvider =
    businessScopedStream<List<StockTransferData>>(
  (ref, db, businessId) => db.stockTransferDao.watchAllPending(),
  whenAbsent: const [],
);

/// Pending requests the current viewer's stores must ACCEPT & DISPATCH — i.e.
/// requests where one of the viewer's stores HOLDS the goods (`fromLocationId`).
/// CEO sees every pending request; a store-assigned user sees only requests
/// against their assigned stores. Gated for action by `stores.dispatch_transfer`.
final viewerScopedIncomingRequestsProvider = Provider<List<StockTransferData>>(
  (ref) {
    final all = ref.watch(allPendingTransfersProvider).valueOrNull ?? const [];
    final role = ref.watch(currentUserRoleProvider);
    if (role?.slug == 'ceo') return all;
    final userId = ref.watch(authProvider).currentUser?.id;
    if (userId == null) return const [];
    final assignedStoreIds =
        (ref.watch(myUserStoresProvider(userId)).valueOrNull ??
                const <UserStoreData>[])
            .map((s) => s.storeId)
            .toSet();
    return all
        .where((r) => assignedStoreIds.contains(r.fromLocationId))
        .toList();
  },
);

/// Pending requests the current viewer's stores RAISED — i.e. requests where one
/// of the viewer's stores NEEDS the goods (`toLocationId`). CEO sees all; a
/// store-assigned user sees only their stores' outstanding requests.
final viewerScopedOutgoingRequestsProvider = Provider<List<StockTransferData>>(
  (ref) {
    final all = ref.watch(allPendingTransfersProvider).valueOrNull ?? const [];
    final role = ref.watch(currentUserRoleProvider);
    if (role?.slug == 'ceo') return all;
    final userId = ref.watch(authProvider).currentUser?.id;
    if (userId == null) return const [];
    final assignedStoreIds =
        (ref.watch(myUserStoresProvider(userId)).valueOrNull ??
                const <UserStoreData>[])
            .map((s) => s.storeId)
            .toSet();
    return all.where((r) => assignedStoreIds.contains(r.toLocationId)).toList();
  },
);

// ── Per-store transfer feeds (store-details hub, §16.8.2) ────────────────────
// These are scoped to ONE concrete store, not to the viewer's assignment set —
// the store-details screen already decides whether the viewer may act.

/// `pending` requests THIS store must fulfil (others asking it to send).
final storeIncomingRequestsProvider =
    businessScopedStreamFamily<List<StockTransferData>, String>(
  (ref, db, businessId, storeId) =>
      db.stockTransferDao.watchPendingForHolderStore(storeId),
  whenAbsent: const [],
);

/// `pending` requests THIS store raised that have not been dispatched yet.
final storeOutgoingRequestsProvider =
    businessScopedStreamFamily<List<StockTransferData>, String>(
  (ref, db, businessId, storeId) =>
      db.stockTransferDao.watchPendingFromStore(storeId),
  whenAbsent: const [],
);

/// `in_transit` transfers arriving AT this store (the confirm-receipt queue).
final storeIncomingTransfersProvider =
    businessScopedStreamFamily<List<StockTransferData>, String>(
  (ref, db, businessId, storeId) => db.stockTransferDao.watchIncoming(storeId),
  whenAbsent: const [],
);

/// `in_transit` transfers dispatched FROM this store (awaiting receipt).
final storeOutgoingTransfersProvider =
    businessScopedStreamFamily<List<StockTransferData>, String>(
  (ref, db, businessId, storeId) => db.stockTransferDao.watchOutgoing(storeId),
  whenAbsent: const [],
);

/// In-transit transfers where the current viewer's stores are the DESTINATION
/// (the confirm queue). CEO sees all stores; store users see only their
/// assigned stores (mirrors [viewerScopedPendingStockRequestsProvider]).
final viewerScopedIncomingTransfersProvider = Provider<List<StockTransferData>>(
  (ref) {
    final all =
        ref.watch(allInTransitTransfersProvider).valueOrNull ?? const [];
    final role = ref.watch(currentUserRoleProvider);
    if (role?.slug == 'ceo') return all;
    final userId = ref.watch(authProvider).currentUser?.id;
    if (userId == null) return const [];
    final assignedStoreIds =
        (ref.watch(myUserStoresProvider(userId)).valueOrNull ??
                const <UserStoreData>[])
            .map((s) => s.storeId)
            .toSet();
    return all.where((r) => assignedStoreIds.contains(r.toLocationId)).toList();
  },
);

/// In-transit transfers where the current viewer's stores are the SOURCE
/// (dispatched shipments eligible for cancellation). CEO sees all; store users
/// see only their assigned stores.
final viewerScopedOutgoingTransfersProvider = Provider<List<StockTransferData>>(
  (ref) {
    final all =
        ref.watch(allInTransitTransfersProvider).valueOrNull ?? const [];
    final role = ref.watch(currentUserRoleProvider);
    if (role?.slug == 'ceo') return all;
    final userId = ref.watch(authProvider).currentUser?.id;
    if (userId == null) return const [];
    final assignedStoreIds =
        (ref.watch(myUserStoresProvider(userId)).valueOrNull ??
                const <UserStoreData>[])
            .map((s) => s.storeId)
            .toSet();
    return all
        .where((r) => assignedStoreIds.contains(r.fromLocationId))
        .toList();
  },
);

/// Completed stock transfers (received + cancelled), business-wide, newest
/// first. Used by the history tab on the Incoming Transfers screen.
final stockTransferHistoryProvider =
    businessScopedStream<List<StockTransferData>>(
  (ref, db, businessId) => db.stockTransferDao.watchHistory(),
  whenAbsent: const [],
);

/// Completed stock transfers (received + cancelled) involving a specific store in either direction, newest
/// first. Used by the Transfer History section in the store details hub.
final storeTransferHistoryProvider =
    businessScopedStreamFamily<List<StockTransferData>, String>(
  (ref, db, businessId, storeId) =>
      db.stockTransferDao.watchHistoryForStore(storeId),
  whenAbsent: const [],
);

// ── Products by store ───────────────────────────────────────────────────────
final productsByStoreProvider =
    businessScopedStreamFamily<List<ProductDataWithStock>, String>(
  (ref, db, businessId, storeId) =>
      db.inventoryDao.watchProductDatasWithStockByStore(storeId),
  whenAbsent: const [],
);

/// Products with stock totals for a store scope, where the key may be null to
/// mean "All Stores". Drives the Product Details screen's realtime refresh so a
/// product edit / stock change syncing in from another device updates the open
/// detail view live (§5).
final productsWithStockProvider =
    businessScopedStreamFamily<List<ProductDataWithStock>, String?>(
  (ref, db, businessId, storeId) =>
      db.inventoryDao.watchProductsWithStock(storeId: storeId),
  whenAbsent: const [],
);

// ── Categories ──────────────────────────────────────────────────────────────
final allCategoriesProvider = businessScopedStream<List<CategoryData>>(
  (ref, db, businessId) => db.inventoryDao.watchAllCategories(),
  whenAbsent: const [],
);

// ── Manufacturers ───────────────────────────────────────────────────────────
// Business-scoped via the DAO so a device holding more than one business's
// data can't surface another business's manufacturers.
final allManufacturersProvider = businessScopedStream<List<ManufacturerData>>(
  (ref, db, businessId) => db.inventoryDao.watchAllManufacturers(),
  whenAbsent: const [],
);

// ── Suppliers ────────────────────────────────────────────────────────────────
/// All (non-deleted) suppliers for the current business. Lets screens keep the
/// supplier dropdown live so an add / rename on another device reflects (§5).
final allSuppliersProvider = businessScopedStream<List<SupplierData>>(
  (ref, db, businessId) => db.catalogDao.watchAllSupplierDatas(),
  whenAbsent: const [],
);

// ── Store by id ─────────────────────────────────────────────────────────────
/// Streams a single store row keyed by id. Returns null when the
/// store hasn't loaded yet or has been (soft-)deleted. Used wherever
/// a screen needs to display the *active* store and have it auto-update
/// when the cloud renames or marks it deleted.
// Business-scoped lookup (DAO filters by current business + id).
final storeByIdProvider = businessScopedStreamFamily<StoreData?, String>(
  (ref, db, businessId, storeId) => db.storesDao.watchStore(storeId),
  whenAbsent: null,
);

// ── Roles & permissions (master plan §2.4, schema v13) ─────────────────────

/// All non-deleted roles for the current business, sorted by role tier
/// (CEO → Manager → Cashier → Stock keeper) via [roleRank]. This is the
/// canonical display order for roles across the whole app — any UI that lists
/// roles must come through this provider (or otherwise sort by [roleRank]) so
/// the tier order is consistent everywhere.
final allRolesProvider = businessScopedStream<List<RoleData>>(
  (ref, db, businessId) => db.rolesDao.watchAll().map(
        (roles) => roles.toList()
          ..sort((a, b) => roleRank(a.slug).compareTo(roleRank(b.slug))),
      ),
  whenAbsent: const [],
);

// ── Appearance (business accent colour, §10.1) ──────────────────────────────

/// Settings key for the CEO-chosen business accent (synced). Value is the
/// [DesignSystem] enum name: 'amber' | 'blue' | 'purple' | 'green'.
const kBusinessDesignSystemKey = 'business_design_system';

DesignSystem? _parseDesignSystem(String? v) {
  if (v == null) return null;
  try {
    return DesignSystem.values.byName(v);
  } catch (_) {
    return null;
  }
}

/// The business-wide accent colour, streamed from the synced `settings` row.
/// Null when no session is bound (pre-login, via the factory's `whenAbsent`) or
/// the key is unset/invalid — the app-root bridge then leaves the device's
/// themeController value alone (blue default). The factory owns the null-session
/// guard (`settingsDao.watch` calls `requireBusinessId()`, which throws without
/// a business) and re-subscribes on bind/unbind.
final businessDesignSystemProvider = businessScopedStream<DesignSystem?>(
  (ref, db, businessId) =>
      db.settingsDao.watch(kBusinessDesignSystemKey).map(_parseDesignSystem),
  whenAbsent: null,
);

/// The business-wide currency code (ISO-4217, e.g. 'NGN', 'USD'), streamed
/// from the synced `default_currency` setting (Business Info, §10.1). Falls
/// back to [kDefaultCurrency] pre-login (no bound business) or when unset.
/// The app-root bridge (main.dart) feeds this into [setActiveCurrencyCode] so
/// every money display follows the CEO-chosen currency live, including across
/// devices. Mirrors [businessDesignSystemProvider]'s null-session guard.
final currencyCodeProvider = businessScopedStream<String>(
  (ref, db, businessId) => db.settingsDao
      .watch('default_currency')
      .map((code) => code ?? kDefaultCurrency),
  whenAbsent: kDefaultCurrency,
);

/// The active currency display symbol (e.g. '₦', r'$', 'GH₵'), derived from
/// [currencyCodeProvider]. For widgets that render a symbol directly (input
/// field prefixes, labels) and want to rebuild when the currency changes.
final currencySymbolProvider = Provider<String>((ref) {
  final code = ref.watch(currencyCodeProvider).valueOrNull ?? kDefaultCurrency;
  return currencySymbolForCode(code);
});

/// The business's VAT configuration (opt-in, OFF by default), streamed from the
/// synced `vat_enabled` / `vat_rate_bps` settings keys — same mechanism as
/// [currencyCodeProvider], so a CEO toggling VAT in Settings propagates across
/// devices with no migration. A row is only "enabled" when the flag is `'true'`
/// AND the rate is positive, so an enabled-but-unconfigured business shows no
/// VAT. Consumed by the standardized daily closing (Phase 1 surfaces VAT due on
/// net sales; the checkout/receipt VAT leg is a later slice).
final vatConfigProvider = businessScopedStream<VatConfig>(
  (ref, db, businessId) => db.settingsDao.watch(kVatEnabledKey).asyncMap((
    enabledRaw,
  ) async {
    final enabled = enabledRaw?.trim().toLowerCase() == 'true';
    if (!enabled) return VatConfig.off;
    final rateBps = parseVatRateBps(await db.settingsDao.get(kVatRateBpsKey));
    return VatConfig(enabled: rateBps > 0, rateBps: rateBps);
  }),
  whenAbsent: VatConfig.off,
);

/// Global permissions catalog. Identical on every device and every
/// business — seeded by migration, never written at runtime.
final allPermissionsProvider = StreamProvider<List<PermissionData>>((ref) {
  return ref.watch(databaseProvider).permissionsDao.watchAll();
});

/// Granted permissions for a specific role.
final rolePermissionsProvider =
    businessScopedStreamFamily<List<RolePermissionData>, String>(
  (ref, db, businessId, roleId) => db.rolePermissionsDao.watchForRole(roleId),
  whenAbsent: const [],
);

/// Per-staff permission overrides for a specific user (§10.2.1). A row forces
/// `permissionKey` on (`isGranted` true) or off (false) for that user,
/// overriding their role default; no row = inherit.
final userPermissionOverridesProvider =
    businessScopedStreamFamily<List<UserPermissionOverrideData>, String>(
  (ref, db, businessId, userId) =>
      db.userPermissionOverridesDao.watchForUser(userId),
  whenAbsent: const [],
);

/// Per-store role permission overrides for a specific (store, role) (§10.2.1
/// Store scope). A row forces `permissionKey` on (`isGranted` true) or off
/// (false) for everyone working in that store, overriding the role's business
/// default; no row = inherit. Keyed by a (storeId, roleId) record so the
/// resolver (active store + current role) and the role-page editor (picked
/// store + edited role) can both watch exactly the slice they need.
final storeRolePermissionsProvider =
    businessScopedStreamFamily<
      List<StoreRolePermissionData>,
      ({String storeId, String roleId})
    >(
  (ref, db, businessId, key) =>
      db.storeRolePermissionsDao.watchFor(key.storeId, key.roleId),
  whenAbsent: const [],
);

/// Per-role tunable settings (max discount %, max expense approval kobo).
final roleSettingsProvider =
    businessScopedStreamFamily<List<RoleSettingData>, String>(
  (ref, db, businessId, roleId) => db.roleSettingsDao.watchForRole(roleId),
  whenAbsent: const [],
);

/// All memberships for the current business — drives Staff Management.
final userBusinessesProvider = businessScopedStream<List<UserBusinessData>>(
  (ref, db, businessId) => db.userBusinessesDao.watchForCurrentBusiness(),
  whenAbsent: const [],
);

/// Active staff (user + role) for a given business — drives the Who Is
/// Working picker (master plan §8). Keyed by an explicit businessId because
/// the picker renders before sign-in, when the session has no current
/// business; the session-scoped [userBusinessesProvider] can't be used there.
final activeStaffProvider =
    StreamProvider.family<List<WhoIsWorkingEntry>, String>((ref, businessId) {
      return ref
          .watch(databaseProvider)
          .userBusinessesDao
          .watchActiveStaffForBusiness(businessId);
    });

/// Device-authenticated staff (user + role) for a given business who have setup their PIN.
final deviceStaffProvider =
    StreamProvider.family<List<WhoIsWorkingEntry>, String>((ref, businessId) {
      return ref
          .watch(databaseProvider)
          .userBusinessesDao
          .watchDeviceStaffForBusiness(businessId);
    });

/// Stores the given user is assigned to.
final myUserStoresProvider = StreamProvider.family<List<UserStoreData>, String>(
  (ref, userId) {
    return ref.watch(databaseProvider).userStoresDao.watchForUser(userId);
  },
);

/// All users in the current business, keyed by id — joins to
/// [userBusinessesProvider] so Staff Management can render each
/// membership's name/avatar. Read-only (no synced write); businessId
/// is the current session's via the Drift business resolver.
final usersByBusinessProvider = businessScopedStream<Map<String, UserData>>(
  (ref, db, businessId) =>
      (db.select(db.users)..where((t) => t.businessId.equals(businessId)))
          .watch()
          .map((rows) => {for (final u in rows) u.id: u}),
  whenAbsent: const {},
);

// ── Role badge resolver (master plan §8.2) ──────────────────────────────────

/// Every role on this device, NOT scoped to the current session — role ids
/// are globally unique, so [userRoleProvider] resolves a role by id even
/// before login binds a business.
final _allRolesUnscopedProvider = StreamProvider<List<RoleData>>((ref) {
  return ref.watch(databaseProvider).rolesDao.watchAllUnscoped();
});

/// Memberships for a given user, NOT scoped to the current session.
final _userMembershipsProvider =
    StreamProvider.family<List<UserBusinessData>, String>((ref, userId) {
      return ref.watch(databaseProvider).userBusinessesDao.watchForUser(userId);
    });

/// The [RoleData] for a user, reactive across both membership and role-table
/// changes. Resolves by user id so it works before `setCurrentUser` binds a
/// business (the shared-PIN picker, master plan §8.4). Returns null until the
/// membership + role rows are present locally — on a fresh device they arrive
/// via the post-login background pull, so callers must render a graceful
/// fallback while it's null.
final userRoleProvider = Provider.family<RoleData?, String>((ref, userId) {
  final roles = ref.watch(_allRolesUnscopedProvider).valueOrNull;
  final memberships = ref.watch(_userMembershipsProvider(userId)).valueOrNull;
  if (roles == null || memberships == null || memberships.isEmpty) return null;

  // Once a business is bound, resolve the role for THAT business — never an
  // arbitrary membership. A multi-business email can have >1 membership locally;
  // picking `memberships.first` could surface another business's role under the
  // active one. Before bind (shared-PIN Who's-Working picker, §8.4) fall back to
  // the first membership (Phase-1: one membership per user on the happy path).
  final boundBusinessId = ref.watch(authProvider).currentUser?.businessId;
  UserBusinessData? membership;
  if (boundBusinessId != null) {
    for (final m in memberships) {
      if (m.businessId == boundBusinessId) {
        membership = m;
        break;
      }
    }
  }
  membership ??= memberships.first;
  final roleId = membership.roleId;
  for (final r in roles) {
    if (r.id == roleId) return r;
  }
  return null;
});

/// Active (unused, unrevoked, unexpired) invite codes for the current
/// business — drives the Invites tab in Staff Management.
final activeInviteCodesProvider = businessScopedStream<List<InviteCodeData>>(
  (ref, db, businessId) => db.inviteCodesDao.watchActive(),
  whenAbsent: const [],
);

// ── Current-user role & permission checks (PIVOT_PLAN step 8A) ───────────────

/// The [RoleData] for the currently logged-in user. Resolves the session
/// user's id via [authProvider] and reuses [userRoleProvider]. Returns null
/// while no one is logged in or before the membership + role rows have
/// arrived locally — callers must render a graceful fallback while null.
final currentUserRoleProvider = Provider<RoleData?>((ref) {
  final userId = ref.watch(authProvider).currentUser?.id;
  if (userId == null) return null;
  return ref.watch(userRoleProvider(userId));
});

/// The current user's membership status ('active' | 'suspended') for the bound
/// business, or null when logged out / not yet resolved locally. Reactive: a
/// suspension performed on another device arrives via the `user_businesses`
/// realtime channel, flips the local row, and re-emits here. Drives the live
/// suspend → sign-out guard in main.dart (master plan §9.5 / §8.3): when this
/// turns 'suspended' for an active session, the device drops to the Who's
/// Working picker (which hides suspended staff, so they can't re-select
/// themselves).
final currentUserMembershipStatusProvider = Provider<String?>((ref) {
  final user = ref.watch(authProvider).currentUser;
  if (user == null) return null;
  final memberships = ref.watch(_userMembershipsProvider(user.id)).valueOrNull;
  if (memberships == null || memberships.isEmpty) return null;
  // Resolve the membership for the bound business (a multi-business email can
  // hold >1 membership locally); fall back to the first before bind.
  for (final m in memberships) {
    if (m.businessId == user.businessId) return m.status;
  }
  return memberships.first.status;
});

/// A counter that forces [currentBusinessSubscriptionProvider] to recompute even
/// when no underlying row changed. A trial expires by the device clock with no
/// realtime event, so bump this on app resume (AutoLockWrapper) — and on a
/// low-frequency timer — to re-evaluate the deadline mid-session (§32).
final subscriptionClockTickProvider = StateProvider<int>((ref) => 0);

/// Effective subscription access for the bound business (master plan §32).
///
/// The cloud-authoritative state lives on the local `businesses` mirror; the
/// admin console flips it and the `businesses` realtime channel re-emits via
/// [currentBusinessProvider], so a switch to Inactive locks the running app
/// live (mirrors the suspend live-lock). [SubscriptionAccess.grace] — no
/// business bound, unknown status, or a null trial date — never locks. Drives
/// the gate in main.dart's home() chain.
final currentBusinessSubscriptionProvider = Provider<SubscriptionAccess>((ref) {
  // Recompute when the clock tick advances (a trial crossing its deadline).
  ref.watch(subscriptionClockTickProvider);
  final business = ref.watch(currentBusinessProvider);
  if (business == null) return SubscriptionAccess.grace;
  return computeSubscriptionAccess(
    business.subscriptionStatus,
    business.trialEndsAt,
    DateTime.now(),
  );
});

/// The set of permission keys granted to the current user's role (e.g.
/// `staff.invite`, `sales.make`). Empty until the role + its grants are
/// resolved locally. Feature code never reads this set directly for gating —
/// it cites a named gate (`Gates.x.allows(ref)`); this provider backs the
/// gate-context seam (ADR 0002).
/// Pure permission resolution (§10.2.1), most-specific wins:
/// **User > Store > Business**. Start from the role's business grants, then
/// apply the active store's overrides, then the user's overrides. CEO is all-on
/// and skips both override layers. Each override is `(key, granted)`: granted
/// true = force-grant, false = force-revoke; an absent key inherits the layer
/// below. Extracted as a pure function so the layering order is unit-testable
/// independently of Riverpod. NOTE: flat application only — no dependency-cascade
/// resolution here (that's enforced at write time in the editors, per the
/// project's "no runtime effective-resolution" rule).
Set<String> resolveEffectivePermissions({
  required bool isCeo,
  required Iterable<String> roleGrants,
  required Iterable<({String key, bool granted})> storeOverrides,
  required Iterable<({String key, bool granted})> userOverrides,
}) {
  final effective = roleGrants.toSet();
  if (isCeo) return effective;
  for (final o in storeOverrides) {
    if (o.granted) {
      effective.add(o.key);
    } else {
      effective.remove(o.key);
    }
  }
  for (final o in userOverrides) {
    if (o.granted) {
      effective.add(o.key);
    } else {
      effective.remove(o.key);
    }
  }
  return effective;
}

final currentUserPermissionsProvider = Provider<Set<String>>((ref) {
  final role = ref.watch(currentUserRoleProvider);
  if (role == null) return const <String>{};
  final grants = ref.watch(rolePermissionsProvider(role.id)).valueOrNull;
  if (grants == null) return const <String>{};
  // The CEO is always all-on and is never overridable (§10.2.1) — skip both the
  // store and user layers (and don't even watch their streams for the CEO).
  if (role.slug == 'ceo') return grants.map((g) => g.permissionKey).toSet();

  final userId = ref.watch(authProvider).currentUser?.id;

  // Store layer (§10.2.1 Store scope): the ACTIVE store the user is working at —
  // the selected/locked store (the §12.1 pick-your-store gate), falling back to
  // their sole assigned store. null (e.g. a multi-store user who hasn't picked a
  // store yet) → no store layer, so effective = business ± user.
  String? activeStoreId = ref.watch(lockedStoreProvider).value;
  if (activeStoreId == null && userId != null) {
    final myStores = ref.watch(myUserStoresProvider(userId)).valueOrNull;
    if (myStores != null && myStores.length == 1) {
      activeStoreId = myStores.first.storeId;
    }
  }
  final storeOverrides = <({String key, bool granted})>[];
  if (activeStoreId != null) {
    final rows = ref
        .watch(
          storeRolePermissionsProvider((
            storeId: activeStoreId,
            roleId: role.id,
          )),
        )
        .valueOrNull;
    if (rows != null) {
      for (final o in rows) {
        storeOverrides.add((key: o.permissionKey, granted: o.isGranted));
      }
    }
  }

  // User layer (most-specific) — per-staff overrides win over store + business.
  final userOverrides = <({String key, bool granted})>[];
  if (userId != null) {
    final rows = ref.watch(userPermissionOverridesProvider(userId)).valueOrNull;
    if (rows != null) {
      for (final o in rows) {
        userOverrides.add((key: o.permissionKey, granted: o.isGranted));
      }
    }
  }

  return resolveEffectivePermissions(
    isCeo: false,
    roleGrants: grants.map((g) => g.permissionKey),
    storeOverrides: storeOverrides,
    userOverrides: userOverrides,
  );
});

/// Whether the current user's permission set has finished resolving locally.
/// False while the role row or its grant rows are still arriving (a fresh
/// login or the post-login background pull). [currentUserPermissionsProvider]
/// can't distinguish "still loading" from "definitively denied" — both surface
/// as an empty set — so a **full-screen** permission gate that renders a "no
/// access" message must wait for this before showing it, or it flashes the
/// denial for a frame before the grants land (the CEO-lands-on-POS flash).
/// Inline hide-don't-block gates don't need this: hiding while loading is the
/// safe default and never flashes a denial.
final currentUserPermissionsReadyProvider = Provider<bool>((ref) {
  final userId = ref.watch(authProvider).currentUser?.id;
  if (userId == null) return false; // logged out — nothing to resolve
  final role = ref.watch(currentUserRoleProvider);
  if (role == null) return false; // membership/role row not arrived yet
  // The base grant rows for the role are the signal that gating can be decided;
  // store/user override streams default to no-op when still null.
  return ref.watch(rolePermissionsProvider(role.id)).valueOrNull != null;
});

// Permission gating is expressed exclusively through the named-gate registry
// (ADR 0002, issue #22 flip). The bare single-key permission helper and the
// manager-tier helper (`isManagerOrAbove`) were REMOVED here: feature code
// cites `Gates.x.allows(ref)` / `.allowsNow(ref)` / `.require(ref)`, so both the
// permission-key axis (`Gate.key`) and the role-tier axis (`Gate.tierAtLeast`,
// e.g. §19.3 money-visibility) live only in registry atoms — never inline in a
// screen. The Sync Issues rule (sync.view OR CEO) is `Gates.viewSyncIssues`.

// ── Discount cap (master plan §12.6 / §13.2) ─────────────────────────────────

/// `role_settings` key holding the max discount % a role may apply in the
/// Cart. Stored on each role row by CEO Settings; shared here so the Cart
/// reads the same key the settings screen writes.
const kMaxDiscountPercentKey = 'max_discount_percent';

/// The max discount percentage the currently logged-in user may apply on a
/// cart line (§13.2). Reads the stored `max_discount_percent` on the user's
/// role; falls back to the seed defaults (CEO 100, Manager 10, others 0) when
/// the setting row hasn't been written yet. Returns 0 (no discount) until the
/// role resolves locally — the safe default for an unresolved role.
final currentUserMaxDiscountPercentProvider = Provider<int>((ref) {
  final role = ref.watch(currentUserRoleProvider);
  if (role == null) return 0;
  int seedDefault() {
    switch (role.slug) {
      case 'ceo':
        return 100;
      case 'manager':
        return 10;
      default:
        return 0;
    }
  }

  final settings = ref.watch(roleSettingsProvider(role.id)).valueOrNull;
  if (settings == null) return seedDefault();
  final stored = settings
      .where((s) => s.settingKey == kMaxDiscountPercentKey)
      .map((s) => s.settingValue)
      .firstOrNull;
  return int.tryParse(stored ?? '') ?? seedDefault();
});

// ── Expense approval limit (master plan §10.2 / §20.4) ───────────────────────

/// `role_settings` key holding the max expense amount (kobo) a role may
/// self-approve. Stored on each role row by CEO Settings; shared here so the
/// Expenses flow reads the same key the settings screen writes.
const kMaxExpenseApprovalKoboKey = 'max_expense_approval_kobo';

/// The max expense amount (kobo) the current user may record without CEO
/// approval (§20.4). `null` means unlimited (CEO). A Manager reads the stored
/// limit — seed default 0, so until the CEO raises it every Manager expense
/// escalates to Pending. Any other/unresolved role returns 0.
final currentUserMaxExpenseApprovalKoboProvider = Provider<int?>((ref) {
  final role = ref.watch(currentUserRoleProvider);
  if (role == null) return 0;
  if (role.slug == 'ceo') return null; // unlimited — CEO never escalates
  final settings = ref.watch(roleSettingsProvider(role.id)).valueOrNull;
  if (settings == null) return 0;
  final stored = settings
      .where((s) => s.settingKey == kMaxExpenseApprovalKoboKey)
      .map((s) => s.settingValue)
      .firstOrNull;
  return int.tryParse(stored ?? '') ?? 0;
});

// ── Manager cross-store view toggle (master plan §11.2 / §10.2) ──────────────

/// `role_settings` key for the CEO toggle that unlocks the Home store picker
/// for Managers. Stored on the Manager role row; value is `'true'`/`'false'`.
/// Shared by the settings toggle and the Home screen so both agree on the key.
const kManagerViewAllStoresKey = 'manager_view_all_stores';

/// Whether the currently logged-in Manager may view other stores on Home.
/// True only when the current user's role is Manager AND the CEO has flipped
/// [kManagerViewAllStoresKey] ON. Other roles get false here — their store
/// access is decided by Home directly from the role slug (the CEO always gets
/// the free picker; Cashier/Stock keeper are always locked).
final managerCanViewAllStoresProvider = Provider<bool>((ref) {
  final role = ref.watch(currentUserRoleProvider);
  if (role == null || role.slug != 'manager') return false;
  final settings = ref.watch(roleSettingsProvider(role.id)).valueOrNull;
  if (settings == null) return false;
  for (final s in settings) {
    if (s.settingKey == kManagerViewAllStoresKey) {
      return s.settingValue == 'true';
    }
  }
  return false;
});

/// True when the current user may view/select EVERY active store — a CEO, or a
/// Manager the CEO granted all-stores access (§11.2/§28). Confined roles (and
/// not-yet-resolved sessions) get false. Drives the "All Stores" option and the
/// confined-user default for the §12.1 nav-drawer store picker.
final canViewAllStoresProvider = Provider<bool>((ref) {
  final slug = ref.watch(currentUserRoleProvider)?.slug;
  if (slug == 'ceo') return true;
  return ref.watch(managerCanViewAllStoresProvider);
});

/// Narrows a store list to the ones a user may sell from. `assigned == null`
/// means "no confinement" → all stores. A confined user with no assignment
/// falls back to all stores so nothing dead-ends on "no store" (the §9.5
/// staff-assignment editor normally guarantees at least one).
List<StoreData> selectableStoresFor(
  List<StoreData> stores,
  Set<String>? assigned,
) {
  if (assigned == null) return stores;
  final mine = stores.where((s) => assigned.contains(s.id)).toList();
  return mine.isEmpty ? stores : mine;
}

/// The stores the current user may select as their active store (§12.1): every
/// active store for an all-stores viewer (CEO / all-stores Manager), otherwise
/// only their assigned store(s). The single source the nav-drawer store picker,
/// POS confinement, and the MainLayout confined-user default all read, so they
/// never disagree. Returns all stores while assignments are still loading (don't
/// confine prematurely on a cold start).
final selectableStoresProvider = Provider<List<StoreData>>((ref) {
  final all = ref.watch(allStoresProvider).valueOrNull ?? const <StoreData>[];
  if (ref.watch(canViewAllStoresProvider)) return all;
  final userId = ref.watch(authProvider).currentUser?.id;
  if (userId == null) return all;
  final assigned = ref.watch(myUserStoresProvider(userId)).valueOrNull;
  if (assigned == null) return all;
  return selectableStoresFor(all, assigned.map((s) => s.storeId).toSet());
});

/// Display label for the active-store scope (§21.11 supplier accounts and any
/// other screen that wants to caption the current scope): the locked store's
/// name, or "All Stores" when nothing is locked.
final activeStoreLabelProvider = Provider.autoDispose<String>((ref) {
  final id = ref.watch(lockedStoreProvider).value;
  if (id == null) return 'All Stores';
  final stores =
      ref.watch(allStoresProvider).valueOrNull ?? const <StoreData>[];
  for (final s in stores) {
    if (s.id == id) return s.name;
  }
  return 'Store';
});

/// The store a NEW write (an expense §20.8, a supplier activity §21.11, …) is
/// stamped against: the locked active store, else the user's first selectable
/// store, else their home store. `label` is its display name for a
/// "Recording for: <store>" banner. Unlike [activeStoreLabelProvider] this never
/// returns "All Stores" — a write always lands on one concrete store, the same
/// fallback a POS sale uses (checkout_page.dart).
final activeWriteStoreProvider =
    Provider.autoDispose<({String? id, String label})>((ref) {
      final locked = ref.watch(lockedStoreProvider).value;
      final selectable = ref.watch(selectableStoresProvider);
      final id =
          locked ??
          (selectable.isNotEmpty
              ? selectable.first.id
              : ref.watch(authProvider).currentUser?.storeId);
      if (id == null) return (id: null, label: 'No store');
      for (final s in selectable) {
        if (s.id == id) return (id: id, label: s.name);
      }
      final all =
          ref.watch(allStoresProvider).valueOrNull ?? const <StoreData>[];
      for (final s in all) {
        if (s.id == id) return (id: id, label: s.name);
      }
      return (id: id, label: 'Store');
    });

// ── Business-day & reconciliation helpers ────────────────────────────────────

/// Today's business-day calendar date (`YYYY-MM-DD`) in the business timezone.
/// The single shared definition so day-bucketed reads (sales / expense
/// reconciliation) always agree on "today". Computed from the business
/// timezone, never the raw device clock.
final todaysBusinessDateProvider = FutureProvider<String>((ref) async {
  final db = ref.watch(databaseProvider);
  final bizId = db.currentBusinessId;
  final tz = bizId == null ? 'UTC' : await getBusinessTimezone(db, bizId);
  final now = DateTime.now();
  // An always-on shared till must re-bucket sales when the local day rolls
  // over. A FutureProvider caches its value forever, so without this the till
  // stays stuck on the day it was opened and sales bucket under the old date.
  // Self-invalidate just after the next business-day boundary so watchers
  // recompute "today".
  final timer = Timer(
    untilNextBusinessDay(now, tz) + const Duration(seconds: 2),
    ref.invalidateSelf,
  );
  ref.onDispose(timer.cancel);
  return businessDateString(now, tz);
});

/// The business timezone name (e.g. `Africa/Lagos`), or `UTC` before a business
/// is bound. Lets report screens bucket order / expense timestamps into the
/// business calendar day via [businessDateString] without each re-resolving the
/// timezone. Used by the Daily Reconciliation Report (§25.9).
final businessTimezoneProvider = FutureProvider<String>((ref) async {
  final db = ref.watch(databaseProvider);
  final bizId = db.currentBusinessId;
  return bizId == null ? 'UTC' : await getBusinessTimezone(db, bizId);
});

/// Current empty-crate holdings per manufacturer (`manufacturerId → count`).
/// Crate businesses only (§13/§18.3); used by the Daily Reconciliation Report's
/// empty-crates section. Point-in-time pool balance, not a day-scoped movement.
final emptyCratesByManufacturerProvider = businessScopedStream<Map<String, int>>(
  (ref, db, businessId) => db.inventoryDao.watchEmptyCratesByManufacturer(),
  whenAbsent: const {},
);

/// Every `damaged` empty-crate movement (§17.2 crate-aware damages — the
/// stored-empty fate). Drives the Daily Reconciliation Statement's forfeited
/// crate-deposit roll-up for empties damaged in storage, which write no
/// stock_adjustment. Crate businesses only.
final allCrateDamagesProvider = businessScopedStream<List<CrateLedgerData>>(
  (ref, db, businessId) => db.inventoryDao.watchAllCrateDamages(),
  whenAbsent: const [],
);

/// Per-store empty-crate balances for the currently locked store (§16.8.1 Phase 2).
/// Returns an empty list when no store is locked. Crate businesses only.
final storeCrateBalancesProvider =
    businessScopedStream<List<StoreCrateBalanceData>>(
  (ref, db, businessId) {
    final storeId = ref.watch(lockedStoreProvider).value;
    if (storeId == null) return Stream.value(const []);
    return db.storeCrateBalancesDao.watchForStore(storeId);
  },
  whenAbsent: const [],
);

/// Current empty-crate balance per manufacturer for a given store, mapped as
/// manufacturerId -> balance. Scoped to [storeId] (§16.8.1).
final storeEmptiesByManufacturerProvider =
    businessScopedStreamFamily<Map<String, int>, String>(
  (ref, db, businessId, storeId) => db.storeCrateBalancesDao
      .watchForStore(storeId)
      .map((rows) => {for (final row in rows) row.manufacturerId: row.balance}),
  whenAbsent: const {},
);

/// Full bottles in stock per manufacturer, scoped to the active store (§16.8.1
/// Phase 2). When a store is locked it counts only that store's inventory; in
/// "All Stores" it sums every store. Keyed by manufacturer id. Drives the
/// "Full" figures on the inventory Empty Crates tab.
final fullCratesByManufacturerProvider = businessScopedStream<Map<String, int>>(
  (ref, db, businessId) {
    final storeId = ref.watch(lockedStoreProvider).value;
    return db.inventoryDao.watchFullCratesByManufacturer(storeId: storeId);
  },
  whenAbsent: const {},
);

// ── Daily Stock Count (master plan §17) ──────────────────────────────────────

/// Every saved Daily Stock Count session in the business, newest day first —
/// drives the Stock Count History sheet and feeds the Daily Reconciliation
/// Report (Ring 3, §25.9). Live so a count saved on another device appears
/// without a manual refresh (§5).
final allStockCountsProvider = businessScopedStream<List<StockCountData>>(
  (ref, db, businessId) => db.stockCountsDao.watchAllForBusiness(),
  whenAbsent: const [],
);

/// Every applied stock adjustment for the business (newest first). Used by the
/// §25.10 Business Statement / Store Reconciliation to value damages
/// (`reason` `damage:<key>`, §17.2): at cost for the CEO P&L, at selling price
/// for the Manager reconciliation.
final allStockAdjustmentsProvider =
    businessScopedStream<List<StockAdjustmentData>>(
  (ref, db, businessId) => db.inventoryDao.watchAllAdjustments(),
  whenAbsent: const [],
);

/// Every supplier-ledger entry across all suppliers (business-wide, newest
/// first). Used by the §25.10 CEO statement of account for goods received
/// (invoice debits) and supplier payments (payment credits). Store scoping is
/// applied in the report from each entry's `storeId` (§21.11).
final allSupplierLedgerEntriesProvider =
    businessScopedStream<List<SupplierLedgerEntryData>>(
  (ref, db, businessId) => db.supplierLedgerDao.watchAllHistory(),
  whenAbsent: const [],
);

/// Every `payment_transactions` row (the unified physical-cash tender ledger)
/// for this business, newest first. Feeds the Daily Reconciliation cash-flow
/// summary (ADR 0014): cash IN (`sale`, `wallet_topup`) and cash OUT (`refund`,
/// `expense`), each filtered on `method == 'cash'`. The table carries no
/// `storeId`, so the cash summary is business-wide (like customer debt).
final allPaymentTransactionsProvider =
    businessScopedStream<List<PaymentTransactionData>>(
  (ref, db, businessId) => db.ordersDao.watchAllPaymentTransactions(),
  whenAbsent: const [],
);

/// Every non-voided `stock_transactions` row (the append-only stock ledger) for
/// this business. Feeds the Daily Reconciliation stock flow-equation card (ADR
/// 0014): opening and expected-closing stock are reconstructed by rewinding
/// these deltas from the current on-hand figure, valued at current cost. Store
/// scope is applied in the report from each row's `locationId`.
final allStockTransactionsProvider =
    businessScopedStream<List<StockTransactionData>>(
  (ref, db, businessId) => db.stockLedgerDao.watchAllTransactions(),
  whenAbsent: const [],
);
