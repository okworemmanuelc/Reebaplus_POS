import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';

import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_bar_header.dart';
import 'package:reebaplus_pos/shared/widgets/notification_bell.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/shared/widgets/user_tips_modal.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/features/dashboard/screens/sales_detail_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/reports_hub_screen.dart';
import 'package:reebaplus_pos/features/customers/screens/customers_screen.dart';
import 'package:reebaplus_pos/features/expenses/screens/expenses_screen.dart';
import 'package:reebaplus_pos/features/orders/screens/orders_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/slide_route.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  String _selectedPeriod = 'Day';
  final List<String> _periods = ['Day', 'Week', 'Month', 'Year', 'To Date'];

  // Warehouse filter (null = All)
  String? _selectedWarehouseId;
  List<WarehouseData> _warehouses = [];
  StreamSubscription? _warehousesSub;

  // True when the logged-in user is a manager locked to one warehouse
  bool _warehouseLocked = false;
  String _lockedWarehouseName = '';

  // Pro-tips hero visibility
  bool _showProTips = false;

  // DB-backed data
  List<OrderWithItems> _allOrdersWithItems = [];
  List<ExpenseWithCategory> _allExpenses = [];
  List<Customer> _customers = [];
  double _totalStockValue = 0;
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
    // Track login count to hide pro tips after first visit
    SharedPreferences.getInstance().then((prefs) {
      final count = (prefs.getInt('dashboard_visit_count') ?? 0) + 1;
      prefs.setInt('dashboard_visit_count', count);
      if (mounted) setState(() => _showProTips = count <= 1);
    });

    // Lock managers (tier 5) and below to their own warehouse; only CEO (tier 6)
    // sees cross-warehouse data.
    final currentUser = ref.read(authProvider).currentUser;
    final userTier = currentUser?.roleTier ?? 6;
    if (userTier < 5 && currentUser?.warehouseId != null) {
      if (mounted) {
        setState(() {
          _warehouseLocked = true;
          _selectedWarehouseId = currentUser!.warehouseId;
        });
      }
    }

    // Warehouses for the filter dropdown
    final db = ref.read(databaseProvider);
    _warehousesSub = db.select(db.warehouses).watch().listen((wh) {
      if (mounted) {
        setState(() {
          _warehouses = wh;
          if (_warehouseLocked && _selectedWarehouseId != null) {
            _lockedWarehouseName =
                wh
                    .where((w) => w.id == _selectedWarehouseId)
                    .map((w) => w.name)
                    .firstOrNull ??
                '';
          }
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

    _subscribeExpenses(_selectedWarehouseId);

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

    _subscribeInventory(_selectedWarehouseId);

    // Load staff list once (for staff sales breakdown)
    final staff = await db.select(db.users).get();
    if (mounted) setState(() => _staffList = staff);
  }

  /// Re-subscribable inventory stream — call on warehouse change.
  void _subscribeInventory(String? warehouseId) {
    _inventorySub?.cancel();
    if (mounted) setState(() => _inventoryLoading = true);
    final db = ref.read(databaseProvider);
    final stream = warehouseId != null
        ? db.inventoryDao.watchProductsByWarehouse(warehouseId)
        : db.inventoryDao.watchAllProductDatasWithStock();
    _inventorySub = stream.listen((items) {
      if (mounted) {
        setState(() {
          _totalStockValue = items.fold<double>(
            0,
            (sum, item) =>
                sum + (item.totalStock * item.product.sellingPriceKobo / 100.0),
          );
          _inventoryLoading = false;
        });
      }
    });
  }

  /// Re-subscribable expenses stream — call on warehouse change.
  void _subscribeExpenses(String? warehouseId) {
    _expensesSub?.cancel();
    if (mounted) setState(() => _expensesLoading = true);
    final db = ref.read(databaseProvider);
    _expensesSub = db.expensesDao.watchAll(warehouseId: warehouseId).listen((expenses) {
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
    _warehousesSub?.cancel();
    _ordersSub?.cancel();
    _expensesSub?.cancel();
    _customersSub?.cancel();
    _inventorySub?.cancel();
    super.dispose();
  }

  bool _isDateInPeriod(DateTime date, String period) {
    final now = DateTime.now();
    final diff = now.difference(date);
    switch (period) {
      case 'Day':
        return diff.inDays == 0 && now.day == date.day;
      case 'Week':
        return diff.inDays <= 7;
      case 'Month':
        return diff.inDays <= 30;
      case 'Year':
        return diff.inDays <= 365;
      case 'To Date':
        return true;
      default:
        return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Filter by selected period and warehouse
    final filteredOrdersWithItems = _allOrdersWithItems
        .where(
          (o) =>
              _isDateInPeriod(o.order.createdAt, _selectedPeriod) &&
              o.order.status == 'completed' &&
              (_selectedWarehouseId == null ||
                  o.order.warehouseId == _selectedWarehouseId),
        )
        .toList();

    // Warehouse filtering is handled at the SQL level by _subscribeExpenses;
    // here we only need the period filter.
    final filteredExpenses = _allExpenses
        .where((e) => _isDateInPeriod(e.expense.createdAt, _selectedPeriod))
        .toList();


    // Filter customers by warehouse for credit/debt metrics
    final filteredCustomers = _selectedWarehouseId == null
        ? _customers
        : _customers
              .where((c) => c.warehouseId == _selectedWarehouseId)
              .toList();

    // Metrics
    final totalSales = filteredOrdersWithItems.fold<double>(
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
              (_selectedWarehouseId == null ||
                  o.order.warehouseId == _selectedWarehouseId),
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
          title: const AppBarHeader(
            icon: FontAwesomeIcons.chartLine,
            title: 'Reebaplus POS',
            subtitle: 'Business Overview',
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
              if (_showProTips) ...[
                _buildQuickStartHero(),
                SizedBox(height: context.spacingL),
              ],
              _buildPeriodHeader(),
              SizedBox(height: context.spacingM),
              _buildMetricsList(
                sales: totalSales,
                pending: pendingOrdersCount,
                profit: netProfit,
                credit: totalCredit,
                debt: totalDebt,
                expenses: totalExpenses,
                filteredOrders: filteredOrdersWithItems,
                staffSalesList: staffSalesList,
              ),
              SizedBox(height: context.spacingL),
            ],
          ),
        ),
    );
  }

  Widget _buildQuickStartHero() {
    return Container(
      padding: EdgeInsets.all(context.spacingL),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Theme.of(context).colorScheme.primary,
            Theme.of(context).colorScheme.secondary,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(context.radiusL),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
            blurRadius: 15,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  FontAwesomeIcons.rocket,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 16),
              const Expanded(
                child: Text(
                  'Welcome to Reebaplus POS!',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            'Get started with our pro tips and master your beverage business in minutes.',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              height: 1.4,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 20),
          AppButton(
            text: 'View Pro Tips',
            variant: AppButtonVariant.secondary,
            isFullWidth: false,
            onPressed: () => UserTipsModal.show(context),
          ),
        ],
      ),
    );
  }

  Widget _buildPeriodHeader() {
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
            _buildReportButton(),
          ],
        ),
        SizedBox(height: context.getRSize(12)),
        Row(
          children: [
            if (_warehouseLocked) ...[
              Flexible(child: _buildLockedWarehouseChip()),
              SizedBox(width: context.getRSize(8)),
            ] else if (_warehouses.isNotEmpty) ...[
              Flexible(child: _buildWarehouseDropdown()),
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

  Widget _buildLockedWarehouseChip() {
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
            Icons.warehouse_outlined,
            size: context.getRSize(14),
            color: Theme.of(context).colorScheme.primary,
          ),
          SizedBox(width: context.getRSize(6)),
          Flexible(
            child: Text(
              _lockedWarehouseName.isEmpty
                  ? 'My Warehouse'
                  : _lockedWarehouseName,
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

  Widget _buildWarehouseDropdown() {
    return SizedBox(
      width: context.getRSize(160),
      child: AppDropdown<String?>(
        value: _selectedWarehouseId,
        items: [
          const DropdownMenuItem<String?>(
            value: null,
            child: Text('All Warehouses'),
          ),
          ..._warehouses.map(
            (wh) => DropdownMenuItem<String?>(
                value: wh.id, child: Text(wh.name)),
          ),
        ],
        onChanged: (v) {
          setState(() => _selectedWarehouseId = v);
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
        onChanged: (v) => setState(() => _selectedPeriod = v ?? 'Day'),
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
  }) {
    final userTier = ref.read(authProvider).currentUser?.roleTier ?? 2;
    final canDrill = userTier >= 4;

    return Column(
      children: [
        _ordersLoading
            ? const SizedBox.shrink()
            : _robustMetricCard(
                label: 'Total Sales',
                value: formatCurrency(sales),
                subtitle: 'Generated from $_selectedPeriod transactions',
                icon: FontAwesomeIcons.nairaSign,
                color: Theme.of(context).colorScheme.primary,
                trend: sales > 0 ? 'Active' : 'No sales',
                isNeutral: true,
                onTap: canDrill
                    ? () => _openSalesDetail(filteredOrders, 'sales')
                    : null,
              ),
        if (userTier >= 5) ...[
          SizedBox(height: context.spacingM),
          _ordersLoading || _expensesLoading
              ? const SizedBox.shrink()
              : _robustMetricCard(
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
                ),
        ],
        SizedBox(height: context.spacingM),
        _ordersLoading
            ? const SizedBox.shrink()
            : _robustMetricCard(
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
              ),
        SizedBox(height: context.spacingM),
        _expensesLoading
            ? const SizedBox.shrink()
            : _robustMetricCard(
                label: 'Total Expenses',
                value: formatCurrency(expenses),
                subtitle: 'Including operations & staff',
                icon: FontAwesomeIcons.fileInvoiceDollar,
                color: Theme.of(context).colorScheme.error,
                trend: expenses > 0 ? 'Recorded' : 'None',
                isPositive: false,
                inverted: true,
                onTap: () {
                  String initialPeriod = 'All Time';
                  switch (_selectedPeriod) {
                    case 'Day':
                      initialPeriod = 'Today';
                      break;
                    case 'Week':
                      initialPeriod = 'This Week';
                      break;
                    case 'Month':
                      initialPeriod = 'This Month';
                      break;
                    case 'Year':
                      initialPeriod = 'This Year';
                      break;
                    case 'To Date':
                      initialPeriod = 'All Time';
                      break;
                  }
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          ExpensesScreen(initialPeriod: initialPeriod),
                    ),
                  );
                },
              ),
        SizedBox(height: context.spacingM),
        _inventoryLoading
            ? const SizedBox.shrink()
            : _robustMetricCard(
                label: 'Stock Value',
                value: formatCurrency(_totalStockValue),
                subtitle: 'Estimated inventory worth',
                icon: FontAwesomeIcons.boxesStacked,
                color: Theme.of(context).colorScheme.primary,
                trend: 'Live',
                isNeutral: true,
                onTap: () => ref.read(navigationProvider).setIndex(2),
              ),
        SizedBox(height: context.spacingM),
        _customersLoading
            ? const SizedBox.shrink()
            : _robustMetricCard(
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
              ),
        if (userTier >= 4)
          _buildStaffSalesSection(staffSalesList),
      ],
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
