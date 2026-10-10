import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';

import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_download_state.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/shared/models/order_status.dart';
import 'package:reebaplus_pos/shared/widgets/first_run_empty_state.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/report_revenue.dart';
import 'package:reebaplus_pos/features/dashboard/widgets/get_started_card.dart';
import 'package:reebaplus_pos/features/dashboard/quick_actions.dart';
import 'package:reebaplus_pos/features/dashboard/widgets/home_parts.dart';
import 'package:reebaplus_pos/features/expenses/screens/add_expense_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/stock_count_screen.dart';
import 'package:reebaplus_pos/features/receiving/screens/receive_stock_screen.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/features/dashboard/screens/sales_detail_screen.dart';
import 'package:reebaplus_pos/features/dashboard/screens/reports_hub_screen.dart';
import 'package:reebaplus_pos/features/dashboard/reports_attention.dart';
import 'package:reebaplus_pos/features/customers/screens/customers_screen.dart';
import 'package:reebaplus_pos/features/expenses/screens/expenses_screen.dart';
import 'package:reebaplus_pos/features/orders/screens/orders_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
import 'package:reebaplus_pos/shared/widgets/slide_route.dart';

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

    // Filter by selected period and store. #195 — the store predicate is
    // `reconStoreFilter`, the SAME one the Daily Reconciliation and the Profit
    // report apply, and it is applied PER LINE in the money loops below (the
    // reconciliation's basis) rather than per ORDER. It also carries the #140
    // van exclusion: road revenue is real but carries no cost against it until
    // the trip closes, so an All-Stores figure that counted it would read as
    // 100%-margin sales. Van P&L lands via the closed-trip artifact (van-sales
    // spec §5.4 / §8.1).
    //
    // The list itself keeps a coarse ORDER-level filter — an order survives if
    // any of its lines, or its own store (which carries the discount), is in
    // scope — so the drill-down shows only orders this view can see; the money
    // is then summed per line.
    final inScope = reconStoreFilter(ref);
    final filteredOrdersWithItems = _allOrdersWithItems
        .where(
          (o) =>
              _isDateInPeriod(o.order.createdAt, _selectedPeriod) &&
              // Revenue is recognized at checkout ('pending'), not at the
              // ceremonial Confirm ('completed'). Count any non-reversed sale.
              orderCountsAsSale(o.order.status) &&
              (inScope(o.order.storeId) ||
                  o.items.any((i) => inScope(i.item.storeId))),
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
    // #176 — the single "Total Sales" definition, shared with the Daily
    // Reconciliation and the Profit report (deposit-exclusive item lines minus
    // discounts). `salesOrders` is already period/cashier-filtered, so only the
    // store predicate is passed; it still excludes any cancelled order via
    // `orderCountsAsSale`. Replaces the old Σ`totalAmountKobo` (deposit-IN, so a
    // crate shop's headline was overstated by every deposit taken and disagreed
    // with the other two surfaces).
    final totalSales =
        computeTotalSalesKobo(salesOrders, inScope: inScope) / 100.0;
    final totalExpenses = filteredExpenses.fold<double>(
      0,
      (sum, e) => sum + e.expense.amountKobo / 100.0,
    );

    // Profit — only for items that had a buying price at the time of sale.
    // Uses the snapshotted buyingPriceKobo on the order item, not the current
    // product price. #195 — the same per-LINE store scope as Total Sales, and
    // discounts are netted out of the costed revenue exactly as the
    // reconciliation's `netRevenueKobo` does. Before that, a discount given was
    // reported as profit the business never made.
    //
    // This is the goods margin less expenses, so it is deliberately NOT the
    // reconciliation's `netProfitKobo` (which also nets damages, shortages,
    // write-offs and forfeit income). The Profit & Loss card is the full P&L;
    // this tile is the at-a-glance version, and its subtitle says so.
    //
    // Forfeit income (kept crate deposits) stays OUT for a specific reason, not
    // by omission: wallet rows carry no store, so that figure is business-wide.
    // Adding a business-wide term to a store-scoped tile would re-open exactly
    // the cross-scope contradiction #195 exists to close — under a store lock it
    // would credit one store with the whole business's forfeits. It belongs
    // here only alongside a store-attributed forfeit source.
    final hasBuyingPrices = filteredOrdersWithItems.any(
      (o) => o.items.any(
        (i) => inScope(i.item.storeId) && i.item.buyingPriceKobo > 0,
      ),
    );
    double? netProfit;
    if (hasBuyingPrices) {
      double pricedRevenue = 0;
      double cogs = 0;
      double discounts = 0;
      for (final o in filteredOrdersWithItems) {
        for (final i in o.items) {
          if (!inScope(i.item.storeId)) continue;
          if (i.item.buyingPriceKobo > 0) {
            pricedRevenue += i.item.quantity * i.item.unitPriceKobo / 100.0;
            cogs += i.item.quantity * i.item.buyingPriceKobo / 100.0;
          }
        }
        discounts += orderDiscountKobo(o, inScope: inScope) / 100.0;
      }
      netProfit = pricedRevenue - discounts - cogs - totalExpenses;
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

    // Per-staff sales breakdown (from already-filtered orders). #195 — each
    // order contributes its Total-Sales share ([orderGoodsNetKobo]: in-scope
    // item lines minus the order discount, deposit-EXCLUSIVE), so the league
    // table sums to the Total Sales tile above it. It used to add
    // `totalAmountKobo`, which bundles the refundable crate deposit (contra US
    // 5) — a cashier who took big deposits outranked one who sold more goods.
    final staffSalesMap = <String, double>{};
    for (final o in filteredOrdersWithItems) {
      final sid = o.order.staffId;
      if (sid != null) {
        staffSalesMap[sid] =
            (staffSalesMap[sid] ?? 0) +
            orderGoodsNetKobo(o, inScope: inScope) / 100.0;
      }
    }
    final staffSalesList = staffSalesMap.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final showReports = isCeo || isManager;
    // Sideways phones, tablets and wide screens carry the period + Reports
    // pills in the top bar (`phone-landscape-home-dark.png`); an upright phone
    // keeps them in the period header above the cards.
    final pillsInBar = context.isRailLayout;
    final nameMap = {for (final u in _staffList) u.id: u};
    final quickActions = resolveQuickActions((g) => g.allows(ref));
    final firstLoad =
        _ordersLoading ||
        _expensesLoading ||
        _customersLoading ||
        _inventoryLoading;

    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: SharedScaffold(
        activeRoute: 'dashboard',
        backgroundColor: Colors.transparent,
        appBar: HomeTopBar(
          title: bizName.isNotEmpty ? bizName : 'Reebaplus POS',
          storeLabel: ref.watch(activeStoreLabelProvider),
          height: homeTopBarHeight(context),
          leading: context.isRailLayout
              ? null
              : const SizedBox.square(
                  dimension: kMinInteractiveDimension,
                  child: MenuButton(),
                ),
          periodActions: pillsInBar
              ? [_buildPeriodPill(), if (showReports) _buildReportsPill()]
              : const [],
        ),
        body: ref.watch(zeroStoresEmptySurfaceProvider)
            ? const FirstRunEmptyState()
            : SafeArea(
                // Side insets (a cutout, a sideways nav bar); under MainLayout
                // they are already removed, so this is a no-op there.
                top: false,
                bottom: false,
                child: AppRefreshWrapper(
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(
                      context.getRSize(16),
                      context.getRSize(16),
                      context.getRSize(16),
                      context.spacingM + context.bottomInset,
                    ),
                    children: [
                      // Get-started checklist (Home tab only, CEO only — issue
                      // #31). Self-hides for every other case, so it costs zero
                      // height when not applicable.
                      const GetStartedCard(),
                      _buildPeriodHeader(
                        showReports: showReports,
                        withPills: !pillsInBar,
                      ),
                      // Quick actions (#362): between the period header and the
                      // cards. Held back during the first load, so nobody taps
                      // a tile before Home knows what they may do (#270 US 55),
                      // and omitted (heading too) when no tile is visible.
                      if (!firstLoad && quickActions.tiles.isNotEmpty) ...[
                        SizedBox(height: context.getRSize(16)),
                        HomeQuickActions(
                          tiles: [
                            for (final a in quickActions.tiles)
                              _quickActionTile(a),
                          ],
                        ),
                      ],
                      SizedBox(height: context.getRSize(16)),
                      HomeCardGrid(
                        cardsFor: (cell) => _buildCards(
                          cell: cell,
                          sales: totalSales,
                          pending: pendingOrdersCount,
                          profit: netProfit,
                          credit: totalCredit,
                          debt: totalDebt,
                          expenses: totalExpenses,
                          filteredOrders: salesOrders,
                          inScope: inScope,
                          showTotalSales: showTotalSales,
                          showNetProfit: showNetProfit,
                          showPending: showPending,
                          showExpenses: showExpenses,
                          showStockValue: showStockValue,
                          showTotalSkus: showTotalSkus,
                          showCreditBalance: showCreditBalance,
                        ),
                      ),
                      if (showStaffSales)
                        _buildStaffSalesSection(staffSalesList, nameMap),
                      SizedBox(height: context.spacingL),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  /// "Performance Overview · Analytics for the selected period". On an
  /// upright phone the period + Reports pills sit under it ([withPills]); in
  /// the rail layout they are in the top bar and this is the one-line header.
  Widget _buildPeriodHeader({
    required bool showReports,
    required bool withPills,
  }) {
    return Column(
      key: HomeKeys.periodHeader,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(
          title: 'Performance Overview',
          subtitle: 'Analytics for the selected period',
        ),
        if (withPills) ...[
          SizedBox(height: context.getRSize(12)),
          // §12.1: the store is chosen in the nav-drawer picker; Home just
          // shows the period filter here.
          Row(
            children: [
              Flexible(child: _buildPeriodPill()),
              if (showReports) ...[
                SizedBox(width: context.getRSize(12)),
                Expanded(child: _buildReportsPill()),
              ],
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildReportsPill() {
    // Attention dot (issue #119): a single dot — no number — lights when this
    // viewer has pending approvals OR an un-reviewed daily stock count. The
    // button itself is already CEO/Manager-gated (showReports); the dot clears
    // when they open Daily Reconciliation. The in-hub Approvals card keeps its
    // own numeric badge.
    return HomeReportsPill(
      showDot: ref.watch(reportsAttentionDotProvider),
      onPressed: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => const ReportsHubScreen()),
        );
      },
    );
  }

  Widget _buildPeriodPill() {
    final options = datePeriodLabelsForRole(
      managerUp: Gates.seeExtendedDateRanges.allows(ref),
    );
    final isCustom = _selectedPeriod.startsWith('Custom:');
    final dropdownValue = isCustom ? 'Custom' : _selectedPeriod;
    final selected = options.contains(dropdownValue)
        ? dropdownValue
        : options.first;

    return HomePeriodPill(
      label: selected,
      options: options,
      onSelected: (v) async {
        if (v == 'Custom') {
          final range = await showDateRangePicker(
            context: context,
            firstDate: DateTime(2020),
            lastDate: DateTime.now().add(const Duration(days: 365)),
            initialDateRange: _customRange,
            builder: (context, child) =>
                Theme(data: Theme.of(context), child: child!),
          );
          if (range != null) {
            setState(() {
              _customRange = range;
              _selectedPeriod =
                  'Custom:${range.start.toIso8601String()}:${range.end.toIso8601String()}';
            });
          }
        } else {
          setState(() {
            _selectedPeriod = v;
            _customRange = null;
          });
        }
      },
    );
  }

  /// A quick action's tile: its fixed colour pair, filled icon, label and
  /// destination. Destinations push on the Home tab's navigator with the same
  /// transitions as their existing entry points (Expenses FAB, Inventory FAB,
  /// Inventory's Daily Stock Count button), so Back returns to Home.
  HomeQuickActionTile _quickActionTile(QuickAction action) {
    final f =
        Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;
    return switch (action) {
      // Same icon and red as the Total Expenses card: money going out.
      QuickAction.addExpense => (
        key: HomeKeys.quickAddExpense,
        icon: AppIcons.bill,
        color: f.danger,
        tint: f.dangerTint,
        label: 'Add Expense',
        onTap: () => AddExpenseScreen.show(context),
      ),
      QuickAction.receiveStock => (
        key: HomeKeys.quickReceiveStock,
        icon: AppIcons.receiving,
        color: f.warning,
        tint: f.warningTint,
        label: 'Receive Stock',
        onTap: () => Navigator.of(
          context,
        ).push(slideDownRoute(const ReceiveStockScreen())),
      ),
      // The locked store; under All Stores (null) the count's own store
      // picker applies.
      QuickAction.takeStock => (
        key: HomeKeys.quickTakeStock,
        icon: AppIcons.auditCheck,
        color: f.purple,
        tint: f.purpleTint,
        label: 'Take Stock',
        onTap: () => Navigator.of(context).push(
          slideDownRoute(
            StockCountScreen(
              storeId: ref.read(navigationProvider).lockedStoreId.value,
            ),
          ),
        ),
      ),
    };
  }

  void _openSalesDetail(
    List<OrderWithItems> orders,
    String mode,
    bool Function(String? storeId) inScope,
  ) {
    Navigator.of(context).push(
      slideDownRoute(
        SalesDetailScreen(
          orders: orders,
          mode: mode,
          period: formatPeriodLabel(_selectedPeriod),
          // #195 — the drill-down must sum the SAME lines the tile did, or it
          // contradicts the number the user tapped.
          inScope: inScope,
        ),
      ),
    );
  }

  /// The visible stat cards in the mockup's order (Sales, Profit, Pending,
  /// Expenses, Stock Value, Credits, Total SKUs). Cards are gated by role
  /// (§11.4) and hidden while their data loads, so neither leaves a gap.
  List<Widget> _buildCards({
    required HomeGridCell cell,
    required double sales,
    required int pending,
    required double? profit,
    required double credit,
    required double debt,
    required double expenses,
    required List<OrderWithItems> filteredOrders,
    required bool Function(String? storeId) inScope,
    required bool showTotalSales,
    required bool showNetProfit,
    required bool showPending,
    required bool showExpenses,
    required bool showStockValue,
    required bool showTotalSkus,
    required bool showCreditBalance,
  }) {
    final cards = <Widget>[];
    final density = cell.density;

    if (showTotalSales && !_ordersLoading) {
      cards.add(
        StatCard(
          key: HomeKeys.sales,
          density: density,
          title: 'Total Sales',
          value: formatCurrency(sales),
          subtitle:
              'Generated from ${formatPeriodLabel(_selectedPeriod)} transactions',
          icon: AppIcons.naira,
          tone: IconTileTone.info,
          pillLabel: sales > 0 ? 'Active' : 'No sales',
          pillTone: homeTrendTone(isNeutral: true),
          onTap: () => _openSalesDetail(filteredOrders, 'sales', inScope),
        ),
      );
    }
    if (showNetProfit && !(_ordersLoading || _expensesLoading)) {
      cards.add(
        StatCard(
          key: HomeKeys.profit,
          density: density,
          title: 'Net Profit',
          value: profit != null ? formatCurrency(profit) : '—',
          subtitle: profit != null
              ? 'Revenue minus cost of goods & expenses'
              : 'Add buying prices to '
                    '${ref.watch(industryLexiconProvider).itemPluralLower} to '
                    'see profit',
          icon: AppIcons.analytics,
          // Same colour rule as before: none yet → info, ≥ 0 → green, < 0 →
          // red.
          tone: profit != null
              ? (profit >= 0 ? IconTileTone.green : IconTileTone.danger)
              : IconTileTone.info,
          pillLabel: profit != null
              ? (profit >= 0 ? 'Positive' : 'Negative')
              : 'N/A',
          pillTone: homeTrendTone(isPositive: profit == null || profit >= 0),
          onTap: profit != null
              ? () => _openSalesDetail(filteredOrders, 'profit', inScope)
              : null,
        ),
      );
    }
    if (showPending && !_ordersLoading) {
      cards.add(
        StatCard(
          key: HomeKeys.pending,
          density: density,
          title: 'Pending Orders',
          value: pending.toString(),
          subtitle: 'Orders awaiting fulfillment',
          icon: AppIcons.time,
          tone: IconTileTone.warning,
          pillLabel: pending > 0 ? 'Attention' : 'Clear',
          pillTone: homeTrendTone(isNeutral: true),
          onTap: () {
            Navigator.of(
              context,
            ).push(slideLeftRoute(const OrdersScreen(initialIndex: 0)));
          },
        ),
      );
    }
    if (showExpenses && !_expensesLoading) {
      cards.add(
        StatCard(
          key: HomeKeys.expenses,
          density: density,
          title: 'Total Expenses',
          value: formatCurrency(expenses),
          subtitle: 'Including operations & staff',
          icon: AppIcons.bill,
          tone: IconTileTone.danger,
          pillLabel: expenses > 0 ? 'Recorded' : 'None',
          pillTone: homeTrendTone(isPositive: false),
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
      cards.add(
        StatCard(
          key: HomeKeys.stockValue,
          density: density,
          title: 'Stock Value',
          value: formatCurrency(_totalStockValue),
          subtitle: 'Estimated inventory worth',
          icon: AppIcons.inventory,
          tone: IconTileTone.info,
          pillLabel: 'Live',
          pillTone: homeTrendTone(isNeutral: true),
          onTap: () => ref.read(navigationProvider).setIndex(2),
        ),
      );
    }
    if (showCreditBalance && !_customersLoading) {
      cards.add(
        HomeCreditsCard(
          key: HomeKeys.credits,
          credit: formatCurrency(credit),
          debt: formatCurrency(debt),
          compact: cell.columns > 1,
          dense: density == StatCardDensity.compact,
          onTap: () {
            Navigator.of(context).push(slideLeftRoute(const CustomersScreen()));
          },
        ),
      );
    }
    if (showTotalSkus && !_inventoryLoading) {
      cards.add(_buildTotalSkusCard(density));
    }
    return cards;
  }

  /// §11.5 — Total SKUs, expandable, grouped by manufacturer. Cashier/Stock
  /// keeper only. Closed shows the SKU count; open lists per-manufacturer
  /// counts under the card.
  Widget _buildTotalSkusCard(StatCardDensity density) {
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

    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final card = StatCard(
      density: density,
      title: 'Total SKUs',
      value: '$totalSkus',
      subtitle: 'Tap to see breakdown by manufacturer',
      icon: AppIcons.inventory,
      tone: IconTileTone.neutral,
      onTap: () => setState(() => _skusExpanded = !_skusExpanded),
      trailing: AppIcon(
        _skusExpanded ? AppIcons.keyboardArrowUp : AppIcons.keyboardArrowDown,
        color: muted,
        size: context.getRSize(24),
      ),
    );
    if (!_skusExpanded) return KeyedSubtree(key: HomeKeys.skus, child: card);
    return Column(
      key: HomeKeys.skus,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        card,
        SizedBox(height: context.getRSize(8)),
        HomeSkuBreakdown(
          rows: grouped,
          // Nothing to list while the first download is still running: an
          // empty catalogue says nothing about the business yet (#313).
          emptyText: ref.watch(firstDownloadInProgressProvider)
              ? null
              : 'No ${ref.watch(industryLexiconProvider).itemPluralLower} yet',
        ),
      ],
    );
  }

  Widget _buildStaffSalesSection(
    List<MapEntry<String, double>> staffSalesList,
    Map<String, UserData> nameMap,
  ) {
    if (_ordersLoading) {
      return const SizedBox.shrink();
    }
    // The orders have not downloaded yet, so "no staff sales" would be a guess
    // (#313). The section appears once there are sales or the download is done.
    if (staffSalesList.isEmpty && ref.watch(firstDownloadInProgressProvider)) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: EdgeInsets.only(top: context.spacingL),
      child: HomeStaffSalesSection(
        emptyText: 'No staff sales recorded for this period',
        rows: [
          for (final entry in staffSalesList)
            _staffRow(entry, nameMap[entry.key]),
        ],
      ),
    );
  }

  HomeStaffRow _staffRow(MapEntry<String, double> entry, UserData? user) {
    final colorHex = user?.avatarColor ?? '#3B82F6';
    return (
      name: user?.name ?? 'Unknown Staff',
      color: Color(int.parse(colorHex.replaceFirst('#', '0xFF'))),
      amount: formatCurrency(entry.value),
    );
  }
}

/// The status pill's tone for a stat card's trend, by the same flags the old
/// card used: neutral trends ("Active", "Clear", "Live") are grey with "!",
/// a positive trend green with ↑, anything else red with ↓ ("None").
TagPillTone homeTrendTone({bool isNeutral = false, bool isPositive = true}) {
  if (isNeutral) return TagPillTone.neutral;
  return isPositive ? TagPillTone.green : TagPillTone.danger;
}
