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
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/shared/models/order_status.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/features/dashboard/widgets/get_started_card.dart';
import 'package:reebaplus_pos/features/dashboard/screens/sales_detail_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/reports_hub_screen.dart';
import 'package:reebaplus_pos/features/dashboard/reports_attention.dart';
import 'package:reebaplus_pos/features/customers/screens/customers_screen.dart';
import 'package:reebaplus_pos/features/expenses/screens/expenses_screen.dart';
import 'package:reebaplus_pos/features/orders/screens/orders_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/slide_route.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_card.dart';
import 'package:reebaplus_pos/features/sync/controllers/first_load_overlay_controller.dart';
import 'package:reebaplus_pos/shared/widgets/skeletons/first_load_skeletons.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  String _selectedPeriod = kDatePeriodLabels.first; // Today (§30.6/§30.11)
  DateTimeRange? _customRange;

  // Store filter (null = All). Follows the §12.1 nav-drawer store picker via
  // `lockedStoreProvider`; no per-screen store dropdown.
  String? _selectedStoreId;

  // Scroll reactivity state
  bool _isScrolled = false;

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
    final db = ref.read(databaseProvider);

    _ordersSub = ref
        .read(orderServiceProvider)
        .watchAllOrdersWithItems()
        .listen((orders) async {
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

    // Load staff list once (for staff sales breakdown). Business-scoped — the
    // device can hold more than one business's users, so a bare select(users)
    // would leak other businesses' staff (business-scoping invariant).
    final staff = await db.storesDao.getUsersForCurrentBusiness();
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
                sum +
                (item.totalStock * item.product.retailerPriceKobo / 100.0),
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
    _ordersSub?.cancel();
    _expensesSub?.cancel();
    _customersSub?.cancel();
    _inventorySub?.cancel();
    super.dispose();
  }

  bool _isDateInPeriod(DateTime date, String period) =>
      isDateInPeriod(date, period);

  @override
  Widget build(BuildContext context) {
    ref.watch(
      currencySymbolProvider,
    ); // rebuild money displays when currency changes
    final bizName = ref.watch(currentBusinessNameProvider);

    // First load: show the dashboard skeleton (brief §4.4) while the store is
    // empty and data is still streaming in, so a stock keeper landing here sees
    // placeholder cards rather than a blank dashboard. The drawer stays
    // reachable via the menu button. Resolves to real content as data arrives.
    if (ref.watch(firstLoadSkeletonActiveProvider)) {
      return Container(
        decoration: AppDecorations.glassyBackground(context),
        child: SharedScaffold(
          activeRoute: 'dashboard',
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            leading: context.isDesktop ? null : const MenuButton(),
            title: Text(bizName.isNotEmpty ? bizName : 'Reebaplus POS'),
          ),
          body: const SafeArea(child: HomeSkeleton()),
        ),
      );
    }

    // ── Role resolution & §11.4 card visibility ─────────────────────────────
    final role = ref.watch(currentUserRoleProvider);
    final slug = role?.slug;
    final userId = ref.watch(authProvider).currentUser?.id;

    final isCeo = slug == 'ceo';
    final isManager = slug == 'manager';
    final isCashier = slug == 'cashier';
    final isStockKeeper = slug == 'stock_keeper';

    // §11.4 card visibility also respects the report permissions (hard rule
    // #6): these cards open the full Sales / Expenses breakdowns, so a
    // Manager/Cashier whose report key is revoked must not see the card. CEO is
    // always-on. Each tile's composite tier+key rule is lifted verbatim into a
    // named gate (Gates.*, issue #18); `.allows(ref)` is the reactive render
    // check, so a mid-session revocation hides the tile live.
    final showTotalSales = Gates.seeSalesMetric.allows(ref);
    final showNetProfit = Gates.seeProfitMetric.allows(ref);
    final showPending = slug != null; // all four roles
    final showExpenses = Gates.seeExpensesMetric.allows(ref);
    final showStockValue = Gates.seeStockValueMetric.allows(ref);
    final showTotalSkus = isCashier || isStockKeeper;
    final showCreditBalance = Gates.seeCreditBalanceMetric.allows(ref);
    final showStaffSales = Gates.seeStaffSales.allows(ref);

    // ── Store filter (§12.1) ─────────────────────────────────────────────────
    // The store filter follows the nav-drawer store picker (null = "All
    // Stores"). Confinement is enforced upstream — the picker only offers the
    // user's selectable stores, and MainLayout pins confined users to a real
    // store. Re-subscribe the per-store streams when the active store changes.
    final desiredStoreId = ref.watch(lockedStoreProvider).value;
    if (_selectedStoreId != desiredStoreId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _selectedStoreId == desiredStoreId) return;
        setState(() => _selectedStoreId = desiredStoreId);
        _subscribeInventory(desiredStoreId);
        _subscribeExpenses(desiredStoreId);
      });
    }

    // Filter by selected period and store
    final filteredOrdersWithItems = _allOrdersWithItems
        .where(
          (o) =>
              _isDateInPeriod(o.order.createdAt, _selectedPeriod) &&
              // Revenue is recognized at checkout ('pending'), not at the
              // ceremonial Confirm ('completed'). Count any non-reversed sale.
              orderCountsAsSale(o.order.status) &&
              (_selectedStoreId == null || o.order.storeId == _selectedStoreId),
        )
        .toList();

    // Store filtering is handled at the SQL level by _subscribeExpenses;
    // here we only need the period filter. Total Expenses counts APPROVED
    // expenses only (§20.1) — pending/rejected aren't actual spend yet.
    final filteredExpenses = _allExpenses
        .where(
          (e) =>
              e.expense.status == 'approved' &&
              _isDateInPeriod(e.expense.expenseDate, _selectedPeriod),
        )
        .toList();

    // Debt/credit is intentionally NOT store-scoped: a customer has a single
    // business-wide wallet (one balance, not one per store), and they can buy
    // across multiple stores. Scoping by the customer's assigned home store
    // double-counted a cross-store customer's full balance under their home
    // store and hid it entirely under the others. Sales/inventory/expenses
    // stay store-scoped above; the wallet total is always business-wide.

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
              (_selectedStoreId == null || o.order.storeId == _selectedStoreId),
        )
        .length;

    final balances =
        ref.watch(creditBalancesKoboProvider).valueOrNull ?? const <int, int>{};
    final totalCredit = _customers.fold<double>(0, (sum, c) {
      final b = balances[c.id] ?? 0;
      return sum + (b > 0 ? b / 100.0 : 0);
    });
    final totalDebt = _customers.fold<double>(0, (sum, c) {
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

    final theme = Theme.of(context);

    return Container(
      decoration: AppDecorations.glassyBackground(context),
      child: SharedScaffold(
        activeRoute: 'dashboard',
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: _isScrolled ? theme.colorScheme.surface.withValues(alpha: 0.8) : Colors.transparent,
          elevation: 0,
          leading: context.isDesktop ? null : const MenuButton(),
          title: AppBarHeader(
            icon: FontAwesomeIcons.chartLine.data,
            title: bizName.isNotEmpty ? bizName : 'Reebaplus POS',
            subtitle: ref.watch(activeStoreLabelProvider),
          ),
          actions: [
            const NotificationBell(),
            SizedBox(width: context.getRSize(8)),
          ],
        ),
        body: NotificationListener<ScrollUpdateNotification>(
          onNotification: (notif) {
            if (notif.metrics.pixels > 10 && !_isScrolled) {
              setState(() => _isScrolled = true);
            } else if (notif.metrics.pixels <= 10 && _isScrolled) {
              setState(() => _isScrolled = false);
            }
            return false;
          },
          child: AppRefreshWrapper(
            child: ListView(
              padding: EdgeInsets.all(
                context.spacingM,
              ).copyWith(
                top: context.getRSize(24),
                bottom: context.spacingM + context.bottomInset,
              ),
              children: [
                // Get-started checklist (Home tab only, CEO only — issue #31).
                // Self-hides for every other case, so it costs zero height when
                // not applicable.
                const GetStartedCard(),
                _buildPeriodHeader(showReports: isCeo || isManager),
                SizedBox(height: context.getRSize(24)),
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
              showCreditBalance: showCreditBalance,
              showStaffSales: showStaffSales,
            ),
            SizedBox(height: context.spacingL),
          ],
        ),
      ),
        ),
      ),
    );
  }

  Widget _buildPeriodHeader({required bool showReports}) {
    if (context.isPhone) {
      return Column(
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
          SizedBox(height: context.getRSize(16)),
          Row(
            children: [
              _buildPeriodDropdown(),
              if (showReports) ...[
                SizedBox(width: context.getRSize(12)),
                Expanded(child: _buildReportButton()),
              ],
            ],
          ),
        ],
      );
    } else {
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
          // §12.1: the store is chosen in the nav-drawer picker; Home just shows
          // the period filter here now.
          Row(children: [Flexible(child: _buildPeriodDropdown())]),
        ],
      );
    }
  }

  Widget _buildReportButton() {
    // Attention dot (issue #119): a single dot — no number — lights when this
    // viewer has pending approvals OR an un-reviewed daily stock count. The
    // button itself is already CEO/Manager-gated (showReports); the dot clears
    // when they open Daily Reconciliation. The in-hub Approvals card keeps its
    // own numeric badge.
    final showDot = ref.watch(reportsAttentionDotProvider);
    return Material(
      color: context.primaryColor.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(context.radiusM),
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const ReportsHubScreen()),
          );
        },
        borderRadius: BorderRadius.circular(context.radiusM),
        child: Container(
          height: context.getRSize(48),
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(horizontal: context.getRSize(16)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                FontAwesomeIcons.fileContract.data,
                size: context.getRSize(16),
                color: context.primaryColor,
              ),
              SizedBox(width: context.getRSize(8)),
              Text(
                'Reports',
                style: TextStyle(
                  color: context.primaryColor,
                  fontWeight: FontWeight.bold,
                  fontSize: context.getRFontSize(14),
                ),
              ),
              if (showDot) ...[
                SizedBox(width: context.getRSize(6)),
                Container(
                  width: context.getRSize(8),
                  height: context.getRSize(8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.error,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPeriodDropdown() {
    final options =
        datePeriodLabelsForRole(managerUp: Gates.seeExtendedDateRanges.allows(ref));
    final isCustom = _selectedPeriod.startsWith('Custom:');
    final dropdownValue = isCustom ? 'Custom' : _selectedPeriod;
    final selected = options.contains(dropdownValue) ? dropdownValue : options.first;

    return SizedBox(
      width: context.getRSize(140),
      child: AppDropdown<String>(
        value: selected,
        items: options
            .map((p) => DropdownMenuItem(value: p, child: Text(p)))
            .toList(),
        onChanged: (v) async {
          if (v == 'Custom') {
            final range = await showDateRangePicker(
              context: context,
              firstDate: DateTime(2020),
              lastDate: DateTime.now().add(const Duration(days: 365)),
              initialDateRange: _customRange,
              builder: (context, child) => Theme(
                data: Theme.of(context),
                child: child!,
              ),
            );
            if (range != null) {
              setState(() {
                _customRange = range;
                _selectedPeriod = 'Custom:${range.start.toIso8601String()}:${range.end.toIso8601String()}';
              });
            }
          } else if (v != null) {
            setState(() {
              _selectedPeriod = v;
              _customRange = null;
            });
          }
        },
      ),
    );
  }

  void _openSalesDetail(List<OrderWithItems> orders, String mode) {
    Navigator.of(context).push(
      slideDownRoute(
        SalesDetailScreen(
          orders: orders,
          mode: mode,
          period: formatPeriodLabel(_selectedPeriod),
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
    required bool showCreditBalance,
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
      add(
        _robustMetricCard(
          label: 'Total Sales',
          value: formatCurrency(sales),
          subtitle: 'Generated from ${formatPeriodLabel(_selectedPeriod)} transactions',
          icon: FontAwesomeIcons.nairaSign.data,
          color: Theme.of(context).colorScheme.primary,
          trend: sales > 0 ? 'Active' : 'No sales',
          isNeutral: true,
          onTap: () => _openSalesDetail(filteredOrders, 'sales'),
        ),
      );
    }
    if (showNetProfit && !(_ordersLoading || _expensesLoading)) {
      add(
        _robustMetricCard(
          label: 'Net Profit',
          value: profit != null ? formatCurrency(profit) : '—',
          subtitle: profit != null
              ? 'Revenue minus cost of goods & expenses'
              : 'Add buying prices to '
                    '${ref.watch(industryLexiconProvider).itemPluralLower} to '
                    'see profit',
          icon: FontAwesomeIcons.chartLine.data,
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
      );
    }
    if (showPending && !_ordersLoading) {
      add(
        _robustMetricCard(
          label: 'Pending Orders',
          value: pending.toString(),
          subtitle: 'Orders awaiting fulfillment',
          icon: FontAwesomeIcons.clock.data,
          color: AppColors.warning,
          trend: pending > 0 ? 'Attention' : 'Clear',
          isNeutral: true,
          onTap: () {
            Navigator.of(
              context,
            ).push(slideLeftRoute(const OrdersScreen(initialIndex: 0)));
          },
        ),
      );
    }
    if (showExpenses && !_expensesLoading) {
      add(
        _robustMetricCard(
          label: 'Total Expenses',
          value: formatCurrency(expenses),
          subtitle: 'Including operations & staff',
          icon: FontAwesomeIcons.fileInvoiceDollar.data,
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
        ),
      );
    }
    if (showStockValue && !_inventoryLoading) {
      add(
        _robustMetricCard(
          label: 'Stock Value',
          value: formatCurrency(_totalStockValue),
          subtitle: 'Estimated inventory worth',
          icon: FontAwesomeIcons.boxesStacked.data,
          color: Theme.of(context).colorScheme.primary,
          trend: 'Live',
          isNeutral: true,
          onTap: () => ref.read(navigationProvider).setIndex(2),
        ),
      );
    }
    if (showTotalSkus && !_inventoryLoading) {
      add(_buildTotalSkusCard());
    }
    if (showCreditBalance && !_customersLoading) {
      add(_buildCreditsBalanceCard(credit, debt));
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
    final manufacturers =
        ref.watch(allManufacturersProvider).valueOrNull ??
        const <ManufacturerData>[];
    final names = {for (final m in manufacturers) m.id: m.name};

    final counts = <String, int>{};
    for (final item in _inventoryItems) {
      final mid = item.product.manufacturerId;
      final label = mid == null ? 'Unspecified' : (names[mid] ?? 'Unspecified');
      counts[label] = (counts[label] ?? 0) + 1;
    }
    final grouped = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final color = Theme.of(context).colorScheme.primary;
    return GlassyCard(
      radius: context.radiusL,
      padding: EdgeInsets.zero,
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
                      child: Icon(
                        FontAwesomeIcons.boxesStacked.data,
                        color: color,
                        size: context.getRSize(24),
                      ),
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
            Divider(height: 1, color: _border.withValues(alpha: 0.05)),
            if (grouped.isEmpty)
              Padding(
                padding: EdgeInsets.all(context.spacingM),
                child: Text(
                  'No ${ref.watch(industryLexiconProvider).itemPluralLower} yet',
                  style: TextStyle(
                    color: _subtext,
                    fontSize: context.getRFontSize(13),
                  ),
                ),
              )
            else
              for (int i = 0; i < grouped.length; i++) ...[
                if (i > 0) Divider(height: 1, color: _border.withValues(alpha: 0.05)),
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

  Widget _buildStaffSalesSection(
    List<MapEntry<String, double>> staffSalesList,
  ) {
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
        GlassyCard(
          radius: context.radiusL,
          padding: EdgeInsets.zero,
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
                      if (i > 0) Divider(height: 1, color: _border.withValues(alpha: 0.05)),
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
        ? FontAwesomeIcons.circleExclamation.data
        : (isPositive
              ? FontAwesomeIcons.arrowUp.data
              : FontAwesomeIcons.arrowDown.data);

    final innerContent = Padding(
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

    return GlassyCard(
      radius: context.radiusL,
      padding: EdgeInsets.zero,
      child: onTap != null
          ? InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(context.radiusL),
              child: innerContent,
            )
          : innerContent,
    );
  }

  Widget _buildCreditsBalanceCard(double credit, double debt) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;

    final innerContent = Padding(
      padding: EdgeInsets.all(context.spacingM),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: context.getRSize(40),
                height: context.getRSize(40),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      color.withValues(alpha: 0.1),
                      color.withValues(alpha: 0.05),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(FontAwesomeIcons.wallet.data, color: color, size: context.getRSize(18)),
              ),
              SizedBox(width: context.spacingM),
              Text(
                'Customer Credits Balance',
                style: TextStyle(
                  fontSize: context.getRFontSize(14),
                  color: _text,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              Icon(Icons.chevron_right, color: _subtext, size: 20),
            ],
          ),
          SizedBox(height: context.spacingM),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: EdgeInsets.all(context.spacingS),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Credit',
                        style: TextStyle(
                          fontSize: context.getRFontSize(12),
                          color: _subtext,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        formatCurrency(credit),
                        style: TextStyle(
                          fontSize: context.getRFontSize(16),
                          fontWeight: FontWeight.bold,
                          color: _text,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(width: context.spacingM),
              Expanded(
                child: Container(
                  padding: EdgeInsets.all(context.spacingS),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.error.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Debt',
                        style: TextStyle(
                          fontSize: context.getRFontSize(12),
                          color: _subtext,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        formatCurrency(debt),
                        style: TextStyle(
                          fontSize: context.getRFontSize(16),
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    return GlassyCard(
      radius: context.radiusL,
      padding: EdgeInsets.zero,
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(slideLeftRoute(const CustomersScreen()));
        },
        borderRadius: BorderRadius.circular(context.radiusL),
        child: innerContent,
      ),
    );
  }
}
