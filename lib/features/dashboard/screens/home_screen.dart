import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';

import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_bar_header.dart';
import 'package:reebaplus_pos/shared/widgets/notification_bell.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/features/dashboard/screens/sales_detail_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/reports_hub_screen.dart';
import 'package:reebaplus_pos/features/customers/screens/customers_screen.dart';
import 'package:reebaplus_pos/features/expenses/screens/expenses_screen.dart';
import 'package:reebaplus_pos/features/orders/screens/orders_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/slide_route.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  String _selectedPeriod = kDatePeriodLabels.first; // Last 24 hours (§30.6/§30.11)
  final List<String> _periods = kDatePeriodLabels;

  // Store filter (null = All)
  String? _selectedStoreId;
  List<StoreData> _stores = [];
  StreamSubscription? _storesSub;

  // Total SKUs card expand state (§11.5 — Cashier/Stock keeper).
  bool _skusExpanded = false;

  // DB-backed data
  List<OrderWithItems> _allOrdersWithItems = [];
  List<ExpenseWithCategory> _allExpenses = [];
  List<Customer> _customers = [];
  double _totalStockValue = 0;
  List<ProductDataWithStock> _inventoryItems = [];
  List<UserData> _staffList = [];

  bool _ordersLoading = true;
  bool _expensesLoading = true;
  bool _customersLoading = true;
  bool _inventoryLoading = true;

  StreamSubscription? _ordersSub;
  StreamSubscription? _expensesSub;
  StreamSubscription? _customersSub;
  StreamSubscription? _inventorySub;
  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _border => Theme.of(context).dividerColor;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => _initializeData());
  }

  Future<void> _initializeData() async {
    // Stores for the filter dropdown
    final db = ref.read(databaseProvider);
    _storesSub = db.storesDao.watchActiveStores().listen((wh) {
      if (mounted) {
        setState(() {
          _stores = wh;
        });
      }
    });

    _ordersSub = ref.read(orderServiceProvider).watchAllOrdersWithItems().listen((orders) async {
      if (mounted) {
        setState(() {
          _allOrdersWithItems = orders;
          _ordersLoading = false;
        });
      }
    });

    _subscribeExpenses(_selectedStoreId);

    _customersSub = db.customersDao.watchAllCustomers().listen((
      customers,
    ) async {
      if (mounted) {
        setState(() {
          _customers = customers.map((d) => Customer.fromDb(d)).toList();
          _customersLoading = false;
        });
      }
    });

    _subscribeInventory(_selectedStoreId);

    // Load staff list once (for staff sales breakdown)
    final staff = await db.select(db.users).get();
    if (mounted) setState(() => _staffList = staff);
  }

  /// Re-subscribable inventory stream — call on store change.
  void _subscribeInventory(String? storeId) {
    _inventorySub?.cancel();
    if (mounted) setState(() => _inventoryLoading = true);
    final db = ref.read(databaseProvider);
    final stream = storeId != null
        ? db.inventoryDao.watchProductsByStore(storeId)
        : db.inventoryDao.watchAllProductDatasWithStock();
    _inventorySub = stream.listen((items) {
      if (mounted) {
        setState(() {
          _inventoryItems = items;
          _totalStockValue = items.fold<double>(
            0,
            (sum, item) =>
                sum + (item.totalStock * item.product.retailerPriceKobo / 100.0),
          );
          _inventoryLoading = false;
        });
      }
    });
  }

  /// Re-subscribable expenses stream — call on store change.
  void _subscribeExpenses(String? storeId) {
    _expensesSub?.cancel();
    if (mounted) setState(() => _expensesLoading = true);
    final db = ref.read(databaseProvider);
    _expensesSub = db.expensesDao.watchAll(storeId: storeId).listen((expenses) {
      if (mounted) {
        setState(() {
          _allExpenses = expenses;
          _expensesLoading = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _storesSub?.cancel();
    _ordersSub?.cancel();
    _expensesSub?.cancel();
    _customersSub?.cancel();
    _inventorySub?.cancel();
    super.dispose();
  }

  bool _isDateInPeriod(DateTime date, String period) =>
      datePeriodFromLabel(period).includes(date);

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider); // rebuild money displays when currency changes
    // ── Role resolution & §11.4 card visibility ─────────────────────────────
    final role = ref.watch(currentUserRoleProvider);
    final slug = role?.slug;
    final userId = ref.watch(authProvider).currentUser?.id;

    final isCeo = slug == 'ceo';
    final isManager = slug == 'manager';
    final isCashier = slug == 'cashier';
    final isStockKeeper = slug == 'stock_keeper';

    final showTotalSales = isCeo || isManager || isCashier;
    final showNetProfit = isCeo;
    final showPending = slug != null; // all four roles
    final showExpenses = isCeo || isManager;
    final showStockValue = isCeo || isManager;
    final showTotalSkus = isCashier || isStockKeeper;
    final showWallet = isCeo || isManager || isCashier;
    final showStaffSales = isCeo || isManager;

    final subtitle = isCashier
        ? "Today's Sales"
        : isStockKeeper
            ? 'Stock Overview'
            : 'Business Overview';

    // ── Store filter lock (§11.2) ────────────────────────────────────────────
    // CEO is always free. Manager is free only when the CEO toggle is on.
    // Cashier/Stock keeper are always locked to their assigned store(s).
    final canViewAllStores =
        isCeo || (isManager && ref.watch(managerCanViewAllStoresProvider));
    final assignedStoreIds = (userId == null
            ? const <UserStoreData>[]
            : (ref.watch(myUserStoresProvider(userId)).valueOrNull ??
                const <UserStoreData>[]))
        .map((s) => s.storeId)
        .toSet();
    final storeLocked = slug != null && !canViewAllStores;
    final lockedStores =
        _stores.where((s) => assignedStoreIds.contains(s.id)).toList();

    // Pin a locked user's filter to an allowed store, re-subscribing once.
    // Single store → that one; multiple → first allowed if the current
    // selection isn't one of theirs (e.g. the default "All").
    if (storeLocked && lockedStores.isNotEmpty &&
        !lockedStores.any((s) => s.id == _selectedStoreId)) {
      final id = lockedStores.first.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _selectedStoreId == id) return;
        setState(() => _selectedStoreId = id);
        _subscribeInventory(id);
        _subscribeExpenses(id);
      });
    }

    // Filter by selected period and store
    final filteredOrdersWithItems = _allOrdersWithItems
        .where(
          (o) =>
              _isDateInPeriod(o.order.createdAt, _selectedPeriod) &&
              o.order.status == 'completed' &&
              (_selectedStoreId == null ||
                  o.order.storeId == _selectedStoreId),
        )
        .toList();

    // Store filtering is handled at the SQL level by _subscribeExpenses;
    // here we only need the period filter. Total Expenses counts APPROVED
    // expenses only (§20.1) — pending/rejected aren't actual spend yet.
    final filteredExpenses = _allExpenses
        .where((e) =>
            e.expense.status == 'approved' &&
            _isDateInPeriod(e.expense.expenseDate, _selectedPeriod))
        .toList();


    // Filter customers by store for credit/debt metrics
    final filteredCustomers = _selectedStoreId == null
        ? _customers
        : _customers
              .where((c) => c.storeId == _selectedStoreId)
              .toList();

    // Metrics. Cashier sees own sales only (§11.4); other roles see the
    // store/period-scoped total.
    final salesOrders = isCashier
        ? filteredOrdersWithItems
            .where((o) => o.order.staffId == userId)
            .toList()
        : filteredOrdersWithItems;
    final totalSales = salesOrders.fold<double>(
      0,
      (sum, o) => sum + o.order.totalAmountKobo / 100.0,
    );
    final totalExpenses = filteredExpenses.fold<double>(
      0,
      (sum, e) => sum + e.expense.amountKobo / 100.0,
    );


    // Profit — only for items that had a buying price at the time of sale.
    // Uses the snapshotted buyingPriceKobo on the order item, not the current product price.
    final hasBuyingPrices = filteredOrdersWithItems.any(
      (o) => o.items.any((i) => i.item.buyingPriceKobo > 0),
    );
    double? netProfit;
    if (hasBuyingPrices) {
      double pricedRevenue = 0;
      double cogs = 0;
      for (final o in filteredOrdersWithItems) {
        for (final i in o.items) {
          if (i.item.buyingPriceKobo > 0) {
            pricedRevenue += i.item.quantity * i.item.unitPriceKobo / 100.0;
            cogs += i.item.quantity * i.item.buyingPriceKobo / 100.0;
          }
        }
      }
      netProfit = pricedRevenue - cogs - totalExpenses;
    }

    final pendingOrdersCount = _allOrdersWithItems
        .where(
          (o) =>
              o.order.status == 'pending' &&
              (_selectedStoreId == null ||
                  o.order.storeId == _selectedStoreId),
        )
        .length;

    final balances =
        ref.watch(walletBalancesKoboProvider).valueOrNull ?? const <int, int>{};
    final totalCredit = filteredCustomers.fold<double>(0, (sum, c) {
      final b = balances[c.id] ?? 0;
      return sum + (b > 0 ? b / 100.0 : 0);
    });
    final totalDebt = filteredCustomers.fold<double>(0, (sum, c) {
      final b = balances[c.id] ?? 0;
      return sum + (b < 0 ? b.abs() / 100.0 : 0);
    });

    // Per-staff sales breakdown (from already-filtered orders)
    final staffSalesMap = <String, double>{};
    for (final o in filteredOrdersWithItems) {
      final sid = o.order.staffId;
      if (sid != null) {
        staffSalesMap[sid] =
            (staffSalesMap[sid] ?? 0) + o.order.totalAmountKobo / 100.0;
      }
    }
    final staffSalesList = staffSalesMap.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return SharedScaffold(
        activeRoute: 'dashboard',
        backgroundColor: _bg,
        appBar: AppBar(
          backgroundColor: _surface,
          elevation: 0,
          leading: const MenuButton(),
          title: AppBarHeader(
            icon: FontAwesomeIcons.chartLine,
            title: 'Reebaplus POS',
            subtitle: subtitle,
          ),
          actions: [
            const NotificationBell(),
            SizedBox(width: context.getRSize(8)),
          ],
        ),
        body: AppRefreshWrapper(
          child: ListView(
            padding: EdgeInsets.all(context.spacingM).copyWith(
              bottom: context.spacingM + context.bottomInset,
            ),
            children: [
              _buildPeriodHeader(
                storeLocked: storeLocked,
                lockedStores: lockedStores,
                showReports: isCeo || isManager,
              ),
              SizedBox(height: context.spacingM),
              _buildMetricsList(
                sales: totalSales,
                pending: pendingOrdersCount,
                profit: netProfit,
                credit: totalCredit,
                debt: totalDebt,
                expenses: totalExpenses,
                filteredOrders: salesOrders,
                staffSalesList: staffSalesList,
                showTotalSales: showTotalSales,
                showNetProfit: showNetProfit,
                showPending: showPending,
                showExpenses: showExpenses,
                showStockValue: showStockValue,
                showTotalSkus: showTotalSkus,
                showWallet: showWallet,
                showStaffSales: showStaffSales,
              ),
              SizedBox(height: context.spacingL),
            ],
          ),
        ),
    );
  }

  Widget _buildPeriodHeader({
    required bool storeLocked,
    required List<StoreData> lockedStores,
    required bool showReports,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Performance Overview',
                  style: context.bodyLarge.copyWith(
                    fontWeight: FontWeight.bold,
                    color: _text,
                  ),
                ),
                SizedBox(height: context.getRSize(2)),
                Text(
                  'Analytics for the selected period',
                  style: TextStyle(
                    fontSize: context.getRFontSize(12),
                    color: _subtext,
                  ),
                ),
              ],
            ),
            if (showReports) _buildReportButton(),
          ],
        ),
        SizedBox(height: context.getRSize(12)),
        Row(
          children: [
            // Locked to a single store → fixed chip. Locked but assigned to
            // several → dropdown limited to those stores (no "All"). Free →
            // full picker with "All Stores".
            if (storeLocked && lockedStores.length > 1) ...[
              Flexible(
                child: _buildStoreDropdown(
                  stores: lockedStores,
                  includeAll: false,
                ),
              ),
              SizedBox(width: context.getRSize(8)),
            ] else if (storeLocked) ...[
              Flexible(
                child: _buildLockedStoreChip(
                  lockedStores.isEmpty ? '' : lockedStores.first.name,
                ),
              ),
              SizedBox(width: context.getRSize(8)),
            ] else if (_stores.isNotEmpty) ...[
              Flexible(child: _buildStoreDropdown()),
              SizedBox(width: context.getRSize(8)),
            ],
            Flexible(child: _buildPeriodDropdown()),
          ],
        ),
      ],
    );
  }

  Widget _buildReportButton() {
    return Material(
      color: context.primaryColor.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const ReportsHubScreen()),
          );
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                FontAwesomeIcons.fileContract,
                size: 14,
                color: context.primaryColor,
              ),
              const SizedBox(width: 8),
              Text(
                'Reports',
                style: TextStyle(
                  color: context.primaryColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                ),
                child: const Text(
                  '3',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 8,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLockedStoreChip(String name) {
    return Container(
      height: 48,
      padding: EdgeInsets.symmetric(horizontal: context.getRSize(12)),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.store_outlined,
            size: context.getRSize(14),
            color: Theme.of(context).colorScheme.primary,
          ),
          SizedBox(width: context.getRSize(6)),
          Flexible(
            child: Text(
              name.isEmpty ? 'My Store' : name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.getRFontSize(13),
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          SizedBox(width: context.getRSize(4)),
          Icon(Icons.lock_outline, size: context.getRSize(12), color: _subtext),
        ],
      ),
    );
  }

  Widget _buildStoreDropdown({List<StoreData>? stores, bool includeAll = true}) {
    final list = stores ?? _stores;
    return SizedBox(
      width: context.getRSize(160),
      child: AppDropdown<String?>(
        value: _selectedStoreId,
        items: [
          if (includeAll)
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('All Stores'),
            ),
          ...list.map(
            (wh) => DropdownMenuItem<String?>(
                value: wh.id, child: Text(wh.name)),
          ),
        ],
        onChanged: (v) {
          setState(() => _selectedStoreId = v);
          _subscribeInventory(v);
          _subscribeExpenses(v);
        },
      ),
    );
  }

  Widget _buildPeriodDropdown() {
    return SizedBox(
      width: context.getRSize(140),
      child: AppDropdown<String>(
        value: _selectedPeriod,
        items: _periods
            .map((p) => DropdownMenuItem(value: p, child: Text(p)))
            .toList(),
        onChanged: (v) =>
            setState(() => _selectedPeriod = v ?? kDatePeriodLabels.first),
      ),
    );
  }

  void _openSalesDetail(List<OrderWithItems> orders, String mode) {
    Navigator.of(context).push(
      slideDownRoute(
        SalesDetailScreen(
          orders: orders,
          mode: mode,
          period: _selectedPeriod,
        ),
      ),
    );
  }

  Widget _buildMetricsList({
    required double sales,
    required int pending,
    required double? profit,
    required double credit,
    required double debt,
    required double expenses,
    required List<OrderWithItems> filteredOrders,
    required List<MapEntry<String, double>> staffSalesList,
    required bool showTotalSales,
    required bool showNetProfit,
    required bool showPending,
    required bool showExpenses,
    required bool showStockValue,
    required bool showTotalSkus,
    required bool showWallet,
    required bool showStaffSales,
  }) {
    // Cards are gated by role (§11.4). Build a list so hidden/loading cards
    // leave no gap; a single spacer is inserted between visible cards.
    final cards = <Widget>[];
    void add(Widget card) {
      if (cards.isNotEmpty) cards.add(SizedBox(height: context.spacingM));
      cards.add(card);
    }

    if (showTotalSales && !_ordersLoading) {
      add(_robustMetricCard(
        label: 'Total Sales',
        value: formatCurrency(sales),
        subtitle: 'Generated from $_selectedPeriod transactions',
        icon: FontAwesomeIcons.nairaSign,
        color: Theme.of(context).colorScheme.primary,
        trend: sales > 0 ? 'Active' : 'No sales',
        isNeutral: true,
        onTap: () => _openSalesDetail(filteredOrders, 'sales'),
      ));
    }
    if (showNetProfit && !(_ordersLoading || _expensesLoading)) {
      add(_robustMetricCard(
        label: 'Net Profit',
        value: profit != null ? formatCurrency(profit) : '—',
        subtitle: profit != null
            ? 'Revenue minus cost of goods & expenses'
            : 'Add buying prices to products to see profit',
        icon: FontAwesomeIcons.chartLine,
        color: profit != null
            ? (profit >= 0 ? success : danger)
            : Theme.of(context).colorScheme.primary,
        trend: profit != null
            ? (profit >= 0 ? 'Positive' : 'Negative')
            : 'N/A',
        isPositive: profit == null || profit >= 0,
        onTap: profit != null
            ? () => _openSalesDetail(filteredOrders, 'profit')
            : null,
      ));
    }
    if (showPending && !_ordersLoading) {
      add(_robustMetricCard(
        label: 'Pending Orders',
        value: pending.toString(),
        subtitle: 'Orders awaiting fulfillment',
        icon: FontAwesomeIcons.clock,
        color: AppColors.warning,
        trend: pending > 0 ? 'Attention' : 'Clear',
        isNeutral: true,
        onTap: () {
          Navigator.of(context).push(
            slideLeftRoute(const OrdersScreen(initialIndex: 0)),
          );
        },
      ));
    }
    if (showExpenses && !_expensesLoading) {
      add(_robustMetricCard(
        label: 'Total Expenses',
        value: formatCurrency(expenses),
        subtitle: 'Including operations & staff',
        icon: FontAwesomeIcons.fileInvoiceDollar,
        color: Theme.of(context).colorScheme.error,
        trend: expenses > 0 ? 'Recorded' : 'None',
        isPositive: false,
        inverted: true,
        onTap: () {
          // Home and Expenses share the canonical chip set (§30.11), so the
          // selected period passes straight through.
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ExpensesScreen(initialPeriod: _selectedPeriod),
            ),
          );
        },
      ));
    }
    if (showStockValue && !_inventoryLoading) {
      add(_robustMetricCard(
        label: 'Stock Value',
        value: formatCurrency(_totalStockValue),
        subtitle: 'Estimated inventory worth',
        icon: FontAwesomeIcons.boxesStacked,
        color: Theme.of(context).colorScheme.primary,
        trend: 'Live',
        isNeutral: true,
        onTap: () => ref.read(navigationProvider).setIndex(2),
      ));
    }
    if (showTotalSkus && !_inventoryLoading) {
      add(_buildTotalSkusCard());
    }
    if (showWallet && !_customersLoading) {
      add(_robustMetricCard(
        label: 'Customer Wallet',
        value: 'Cr: ${formatCurrency(credit)}',
        subtitle: 'Debt: ${formatCurrency(debt)}',
        icon: FontAwesomeIcons.wallet,
        color: Theme.of(context).colorScheme.primary,
        trend: debt > 0 ? 'Pending Recov.' : 'Healthy',
        isPositive: debt == 0,
        onTap: () {
          Navigator.of(context).push(
            slideLeftRoute(const CustomersScreen()),
          );
        },
      ));
    }

    return Column(
      children: [
        ...cards,
        if (showStaffSales) _buildStaffSalesSection(staffSalesList),
      ],
    );
  }

  /// §11.5 — Total SKUs, expandable, grouped by manufacturer. Cashier/Stock
  /// keeper only. Closed shows the SKU count; expanded lists per-manufacturer
  /// counts.
  Widget _buildTotalSkusCard() {
    final totalSkus = _inventoryItems.length;
    final manufacturers = ref.watch(allManufacturersProvider).valueOrNull ??
        const <ManufacturerData>[];
    final names = {for (final m in manufacturers) m.id: m.name};

    final counts = <String, int>{};
    for (final item in _inventoryItems) {
      final mid = item.product.manufacturerId;
      final label =
          mid == null ? 'Unspecified' : (names[mid] ?? 'Unspecified');
      counts[label] = (counts[label] ?? 0) + 1;
    }
    final grouped = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final color = Theme.of(context).colorScheme.primary;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(context.radiusL),
        border: Border.all(color: _border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(context.radiusL),
            child: InkWell(
              borderRadius: BorderRadius.circular(context.radiusL),
              onTap: () => setState(() => _skusExpanded = !_skusExpanded),
              child: Padding(
                padding: EdgeInsets.all(context.spacingM),
                child: Row(
                  children: [
                    Container(
                      width: context.getRSize(56),
                      height: context.getRSize(56),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            color.withValues(alpha: 0.1),
                            color.withValues(alpha: 0.05),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(FontAwesomeIcons.boxesStacked,
                          color: color, size: context.getRSize(24)),
                    ),
                    SizedBox(width: context.spacingM),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Total SKUs',
                            style: TextStyle(
                              fontSize: context.getRFontSize(13),
                              color: _subtext,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(height: context.getRSize(2)),
                          Text(
                            '$totalSkus',
                            style: TextStyle(
                              fontSize: context.getRFontSize(22),
                              fontWeight: FontWeight.w900,
                              color: _text,
                            ),
                          ),
                          SizedBox(height: context.getRSize(2)),
                          Text(
                            'Tap to see breakdown by manufacturer',
                            style: TextStyle(
                              fontSize: context.getRFontSize(12),
                              color: _subtext.withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      _skusExpanded
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      color: _subtext,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_skusExpanded) ...[
            Divider(height: 1, color: _border),
            if (grouped.isEmpty)
              Padding(
                padding: EdgeInsets.all(context.spacingM),
                child: Text(
                  'No products yet',
                  style: TextStyle(
                      color: _subtext, fontSize: context.getRFontSize(13)),
                ),
              )
            else
              for (int i = 0; i < grouped.length; i++) ...[
                if (i > 0) Divider(height: 1, color: _border),
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.spacingM,
                    vertical: context.getRSize(10),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          grouped[i].key,
                          style: TextStyle(
                            fontSize: context.getRFontSize(14),
                            fontWeight: FontWeight.w600,
                            color: _text,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '${grouped[i].value}',
                        style: TextStyle(
                          fontSize: context.getRFontSize(14),
                          fontWeight: FontWeight.w800,
                          color: _text,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
          ],
        ],
      ),
    );
  }

  Widget _buildStaffSalesSection(List<MapEntry<String, double>> staffSalesList) {
    if (_ordersLoading) {
      return const SizedBox.shrink();
    }

    final nameMap = {for (final u in _staffList) u.id: u};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: context.spacingL),
        Text(
          'Staff Sales',
          style: context.bodyLarge.copyWith(
            fontWeight: FontWeight.bold,
            color: _text,
          ),
        ),
        SizedBox(height: context.spacingS),
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.circular(context.radiusL),
            border: Border.all(color: _border),
          ),
          child: staffSalesList.isEmpty
              ? Padding(
                  padding: EdgeInsets.all(context.spacingM),
                  child: Text(
                    'No staff sales recorded for this period',
                    style: TextStyle(
                      color: _subtext,
                      fontSize: context.getRFontSize(13),
                    ),
                  ),
                )
              : Column(
                  children: [
                    for (int i = 0; i < staffSalesList.length; i++) ...[
                      if (i > 0) Divider(height: 1, color: _border),
                      _buildStaffRow(staffSalesList[i], nameMap),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildStaffRow(
    MapEntry<String, double> entry,
    Map<String, UserData> nameMap,
  ) {
    final user = nameMap[entry.key];
    final name = user?.name ?? 'Unknown Staff';
    final colorHex = user?.avatarColor ?? '#3B82F6';
    final color = Color(int.parse(colorHex.replaceFirst('#', '0xFF')));

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.spacingM,
        vertical: context.getRSize(10),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: context.getRSize(18),
            backgroundColor: color.withValues(alpha: 0.15),
            child: Text(
              name[0].toUpperCase(),
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontSize: context.getRFontSize(14),
              ),
            ),
          ),
          SizedBox(width: context.spacingM),
          Expanded(
            child: Text(
              name,
              style: TextStyle(
                fontSize: context.getRFontSize(14),
                fontWeight: FontWeight.w600,
                color: _text,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            formatCurrency(entry.value),
            style: TextStyle(
              fontSize: context.getRFontSize(14),
              fontWeight: FontWeight.w800,
              color: _text,
            ),
          ),
        ],
      ),
    );
  }

  Widget _robustMetricCard({
    required String label,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
    required String trend,
    bool isPositive = true,
    bool isNeutral = false,
    bool inverted = false,
    VoidCallback? onTap,
  }) {
    final trendColor = isNeutral ? _subtext : (isPositive ? success : danger);
    final trendIcon = isNeutral
        ? FontAwesomeIcons.circleExclamation
        : (isPositive ? FontAwesomeIcons.arrowUp : FontAwesomeIcons.arrowDown);

    final card = Container(
      width: double.infinity,
      padding: EdgeInsets.all(context.spacingM),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(context.radiusL),
        border: Border.all(
          color: onTap != null ? color.withValues(alpha: 0.4) : _border,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: context.getRSize(56),
            height: context.getRSize(56),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  color.withValues(alpha: 0.1),
                  color.withValues(alpha: 0.05),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: color, size: context.getRSize(24)),
          ),
          SizedBox(width: context.spacingM),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: context.getRFontSize(13),
                    color: _subtext,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: context.getRSize(2)),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: context.getRFontSize(22),
                    fontWeight: FontWeight.w900,
                    color: _text,
                  ),
                ),
                SizedBox(height: context.getRSize(2)),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: context.getRFontSize(12),
                    color: _subtext.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: context.getRSize(10),
              vertical: context.getRSize(6),
            ),
            decoration: BoxDecoration(
              color: trendColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(trendIcon, color: trendColor, size: context.getRSize(10)),
                SizedBox(width: context.getRSize(4)),
                Text(
                  trend,
                  style: TextStyle(
                    color: trendColor,
                    fontSize: context.getRFontSize(11),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return card;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(context.radiusL),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(context.radiusL),
        child: card,
      ),
    );
  }
}
