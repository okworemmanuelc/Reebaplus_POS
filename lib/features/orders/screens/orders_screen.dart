import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/features/orders/widgets/online_orders_tab.dart';
import 'package:reebaplus_pos/features/orders/widgets/online_order_parts.dart';
import 'package:reebaplus_pos/features/orders/widgets/orders_parts.dart';
import 'package:reebaplus_pos/features/orders/widgets/mark_paid_dialog.dart';
import 'package:reebaplus_pos/core/providers/online_order_providers.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/tag_pill.dart';
import 'package:screenshot/screenshot.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/core/utils/store_address.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/shared/models/receipt_totals.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/first_run_empty_state.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/receipt_widget.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/tabbed_sliver_scaffold.dart';
import 'package:reebaplus_pos/features/deliveries/data/models/delivery_receipt.dart'
    as model;
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/notification_bell.dart';

import 'package:reebaplus_pos/features/pos/services/receipt_builder.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/orders/widgets/crate_return_modal.dart';
import 'package:reebaplus_pos/features/orders/widgets/return_sale_dialog.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/customers/screens/customer_detail_screen.dart';
import 'package:reebaplus_pos/shared/widgets/slide_route.dart';
import 'package:reebaplus_pos/shared/widgets/printer_picker.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';
import 'package:reebaplus_pos/shared/widgets/receipt_paper_size_prompt.dart';

/// Test seam for finding order rows laid out on [OrdersScreen].
const String kOrderRowKeyPrefix = 'order-card-';

/// Stable key for one order card on [OrdersScreen].
Key orderRowKey(String orderId) => ValueKey('$kOrderRowKeyPrefix$orderId');

class OrdersScreen extends ConsumerStatefulWidget {
  /// The tab to open on, counted over the VISIBLE tabs: Pending · Online ·
  /// Completed · Cancelled with `online_orders.view` (#427), else Pending ·
  /// Completed · Cancelled.
  final int initialIndex;
  const OrdersScreen({super.key, this.initialIndex = 0});

  @override
  ConsumerState<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends ConsumerState<OrdersScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final ScreenshotController _screenshotCtrl = ScreenshotController();

  // Date filters (§19.1/§30.11: default Last 24 hours).
  String _completedFilter = kDatePeriodLabels.first;
  String _cancelledFilter = kDatePeriodLabels.first;
  DateTimeRange? _completedCustomRange;
  DateTimeRange? _cancelledCustomRange;

  Future<void> _changeFilter(String tab, String v) async {
    if (v == 'Custom') {
      final initialRange = tab == 'completed'
          ? _completedCustomRange
          : _cancelledCustomRange;
      final range = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2020),
        lastDate: DateTime.now().add(const Duration(days: 365)),
        initialDateRange: initialRange,
        builder: (context, child) =>
            Theme(data: Theme.of(context), child: child!),
      );
      if (range != null) {
        setState(() {
          final rangeStr =
              'Custom:${range.start.toIso8601String()}:${range.end.toIso8601String()}';
          if (tab == 'completed') {
            _completedCustomRange = range;
            _completedFilter = rangeStr;
          } else {
            _cancelledCustomRange = range;
            _cancelledFilter = rangeStr;
          }
        });
      }
    } else {
      setState(() {
        if (tab == 'completed') {
          _completedFilter = v;
          _completedCustomRange = null;
        } else {
          _cancelledFilter = v;
          _cancelledCustomRange = null;
        }
      });
    }
  }

  // Search
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  Timer? _searchDebounce;

  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get surfaceCol => Theme.of(context).colorScheme.surface;
  Color get textCol => Theme.of(context).colorScheme.onSurface;
  Color get subtextCol =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get borderCol =>
      Theme.of(context).colorScheme.primary.withValues(alpha: 0.05);
  AppFixedColors get _fixed =>
      Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;

  /// Whether the Online tab (#427) is in the tab set — `online_orders.view`.
  late bool _showOnline;

  @override
  void initState() {
    super.initState();
    _showOnline = Gates.viewOnlineOrders.allowsNow(ref);
    _tabController = _newTabController(widget.initialIndex);
  }

  TabController _newTabController(int index) {
    final length = _showOnline ? 4 : 3;
    return TabController(
      length: length,
      vsync: this,
      initialIndex: index.clamp(0, length - 1),
    );
  }

  /// The view permission changed under the open screen: rebuild the tab set,
  /// keeping the same tab selected (Online falls back to Pending).
  void _syncOnlineTab(bool showOnline) {
    if (showOnline == _showOnline) return;
    final old = _tabController;
    final index = old.index;
    final next = showOnline
        ? (index >= 1 ? index + 1 : index)
        : (index == 1 ? 0 : (index > 1 ? index - 1 : index));
    _showOnline = showOnline;
    _tabController = _newTabController(next);
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      setState(() => _searchQuery = value.trim().toLowerCase());
    });
  }

  /// Resolves a storeId to its receipt address (country excluded, §15.1).
  Future<String?> _resolveStoreAddress(String? storeId) async {
    if (storeId == null) return null;
    final db = ref.read(databaseProvider);
    final stores = await db.storesDao.getActiveStores();
    return stores
        .where((w) => w.id == storeId)
        .map((w) => receiptStoreAddress(w.location))
        .firstOrNull;
  }

  List<OrderWithItems> _applySearch(List<OrderWithItems> list) {
    if (_searchQuery.isEmpty) return list;
    return list.where((o) {
      final name = (o.customer?.name ?? 'walk-in').toLowerCase();
      final orderNum = o.order.orderNumber.toLowerCase();
      final orderId = o.order.id.toString();
      return name.contains(_searchQuery) ||
          orderNum.contains(_searchQuery) ||
          orderId.contains(_searchQuery);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(
      currencySymbolProvider,
    ); // rebuild money displays when currency changes
    _syncOnlineTab(Gates.viewOnlineOrders.allows(ref));
    return SharedScaffold(
      activeRoute: 'orders',
      backgroundColor: _bg,
      appBar: _buildAppBar(context),
      body: DecoratedBox(
        decoration: AppDecorations.pageBackground(context),
        child: Builder(
          builder: (context) {
            if (ref.watch(zeroStoresEmptySurfaceProvider)) {
              return const FirstRunEmptyState();
            }
            final activeStoreId = ref.watch(lockedStoreProvider).value;

            return AppRefreshWrapper(
              onRefresh: () {
                final completedKey = (
                  status: 'completed',
                  storeId: activeStoreId,
                  dateLabel: _completedFilter,
                  search: _searchQuery,
                );
                final cancelledKey = (
                  status: 'cancelled',
                  storeId: activeStoreId,
                  dateLabel: _cancelledFilter,
                  search: _searchQuery,
                );
                ref.invalidate(paginatedOrdersProvider(completedKey));
                ref.invalidate(paginatedOrdersProvider(cancelledKey));
                ref.invalidate(ordersStatsProvider(completedKey));
                ref.invalidate(ordersStatsProvider(cancelledKey));
                ref.invalidate(pendingOrdersProvider(activeStoreId));
              },
              child: TabbedSliverScaffold(
                key: ValueKey('orders-tabs-$_showOnline'),
                controller: _tabController,
                tabBarExtent: math.max(
                  kMinInteractiveDimension,
                  context.getRSize(72.0),
                ),
                tabBar: _buildTabBar(context),
                tabViews: [
                  TabSliverView(
                    storageKey: 'orders-pending',
                    slivers: _pendingTabSlivers(context, activeStoreId),
                  ),
                  if (_showOnline)
                    const TabSliverView(
                      storageKey: 'orders-online',
                      slivers: [OnlineOrdersTabSliver()],
                    ),
                  TabSliverView(
                    storageKey: 'orders-completed',
                    slivers: _completedTabSlivers(context, activeStoreId),
                  ),
                  TabSliverView(
                    storageKey: 'orders-cancelled',
                    slivers: _cancelledTabSlivers(context, activeStoreId),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  // ─────────────────────────── APP BAR ────────────────────────────────────

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return OrdersTopBar(
      key: OrdersKeys.topBar,
      height: ordersTopBarHeight(context),
      icon: AppIcons.receipt,
      title: 'Orders',
      subtitle: ref.watch(activeStoreLabelProvider),
      leading: context.isRailLayout ? null : const MenuButton(),
      actions: const [NotificationBell()],
    );
  }

  Widget _buildTabBar(BuildContext context) {
    final t = Theme.of(context);
    final iconSize = context.getRSize(18);
    final newOnline = _showOnline ? ref.watch(newOnlineOrderCountProvider) : 0;
    return Material(
      key: OrdersKeys.tabBar,
      color: surfaceCol,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: t.dividerColor)),
        ),
        child: TabBar(
          controller: _tabController,
          dividerColor: Colors.transparent,
          labelColor: t.colorScheme.primary,
          unselectedLabelColor: subtextCol,
          indicatorColor: t.colorScheme.primary,
          indicatorWeight: 3,
          labelStyle: context.boldStyle(14),
          unselectedLabelStyle: context.semiBoldStyle(14),
          tabs: [
            Tab(
              icon: Icon(AppIcons.box, size: iconSize),
              text: 'Pending',
            ),
            if (_showOnline)
              Tab(
                key: OnlineOrderKeys.tab,
                icon: Badge(
                  key: OnlineOrderKeys.tabBadge,
                  label: Text('$newOnline'),
                  isLabelVisible: newOnline > 0,
                  child: Icon(AppIcons.public, size: iconSize),
                ),
                text: 'Online',
              ),
            Tab(
              icon: Icon(AppIcons.auditCheck, size: iconSize),
              text: 'Completed',
            ),
            Tab(
              icon: Icon(AppIcons.block, size: iconSize),
              text: 'Cancelled',
            ),
          ],
        ),
      ),
    );
  }

  /// Centres [child] at most 720 wide (settings-list width) with a 16 gutter.
  Widget _capped(Widget child) => LayoutBuilder(
    builder: (context, c) => Padding(
      padding: EdgeInsets.symmetric(
        horizontal: ordersCapPadding(c.maxWidth, context.getRSize(16)),
      ),
      child: child,
    ),
  );

  /// The summary strip under the tab bar, capped and spaced like a card list.
  Widget _summary(List<_StatItem> stats) => Padding(
    padding: EdgeInsets.only(top: context.getRSize(16)),
    child: _capped(
      OrdersSummaryStrip(
        stats: [
          for (final s in stats)
            (label: s.label, value: s.value, color: s.color),
        ],
      ),
    ),
  );

  // ─────────────────────────── SEARCH BAR ─────────────────────────────────

  /// The search row. On the Completed / Cancelled tabs a period-filter
  /// **dropdown** sits inline to the right of the search field (§19.1); pass
  /// the filter args to show it. The Pending tab has no period filter, so it
  /// calls this with no filter args and renders the search field alone.
  Widget _buildSearchBar(
    BuildContext context, {
    String? selectedFilter,
    ValueChanged<String>? onSelectFilter,
    List<String>? filterOptions,
  }) {
    final showFilter =
        selectedFilter != null &&
        onSelectFilter != null &&
        filterOptions != null;
    return Padding(
      padding: EdgeInsets.only(top: context.getRSize(12)),
      child: _capped(
        Row(
          children: [
            Expanded(child: _buildSearchField(context)),
            if (showFilter) ...[
              SizedBox(width: context.getRSize(10)),
              _buildFilterDropdown(
                context,
                selected: selectedFilter,
                options: filterOptions,
                onSelect: onSelectFilter,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSearchField(BuildContext context) {
    return AppInput(
      key: OrdersKeys.search,
      controller: _searchController,
      onChanged: _onSearchChanged,
      hintText: 'Search by customer or order #',
      prefixIcon: Icon(
        AppIcons.search,
        size: context.getRSize(18),
        color: subtextCol,
      ),
      suffixIcon: _searchQuery.isNotEmpty
          ? IconButton(
              tooltip: 'Clear search',
              constraints: const BoxConstraints(
                minWidth: kMinInteractiveDimension,
                minHeight: kMinInteractiveDimension,
              ),
              onPressed: () {
                _searchController.clear();
                setState(() => _searchQuery = '');
              },
              icon: Icon(
                AppIcons.close,
                size: context.getRSize(18),
                color: subtextCol,
              ),
            )
          : null,
    );
  }

  /// Period-filter dropdown that sits inline with the search bar (§19.1).
  /// `options` is capped to Day/Week/Month for roles below Manager by the
  /// caller. Styled as a bordered pill to match the search field.
  Widget _buildFilterDropdown(
    BuildContext context, {
    required String selected,
    required List<String> options,
    required ValueChanged<String> onSelect,
  }) {
    final isCustom = selected.startsWith('Custom:');
    final dropdownValue = isCustom ? 'Custom' : selected;
    final selectedVal = options.contains(dropdownValue)
        ? dropdownValue
        : options.first;

    return SizedBox(
      key: OrdersKeys.period,
      width: context.getRSize(150),
      child: AppDropdown<String>(
        value: selectedVal,
        items: options
            .map((p) => DropdownMenuItem(value: p, child: Text(p)))
            .toList(),
        onChanged: (v) {
          if (v != null) onSelect(v);
        },
        contentPadding: EdgeInsets.symmetric(
          horizontal: context.getRSize(12),
          vertical: context.getRSize(10),
        ),
        prefixIcon: Icon(
          AppIcons.calendar,
          size: context.getRSize(16),
          color: subtextCol,
        ),
      ),
    );
  }

  /// Period options. Roles below Manager are capped at a Month maximum (§19.1);
  /// `managerUp` (Manager-or-above) is exactly that gate.
  List<String> _periodOptions(bool managerUp) {
    // §30.11 canonical chip set. Lower roles get Today/This Week/This Month only.
    return datePeriodLabelsForRole(managerUp: managerUp);
  }

  // ─────────────────────────── TABS ───────────────────────────────────────

  List<Widget> _pendingTabSlivers(BuildContext context, String? activeStoreId) {
    final pendingAsync = ref.watch(pendingOrdersProvider(activeStoreId));

    return pendingAsync.when(
      loading: () => const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        ),
      ],
      error: (e, _) => [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: Text('Error: $e')),
        ),
      ],
      data: (allPending) {
        final list = _applySearch(allPending);
        final canSeeMoney = Gates.seeOrderMoney.allows(ref);

        // Compute summary stats
        final totalValue = list.fold<int>(
          0,
          (sum, o) => sum + o.order.netAmountKobo,
        );
        final unassigned = list
            .where((o) => o.order.riderName == 'Pick-up Order')
            .length;

        final stats = [
          _StatItem(
            label: 'Pending',
            value: '${list.length}',
            color: Theme.of(context).colorScheme.primary,
          ),
          if (canSeeMoney)
            _StatItem(
              label: 'Total Value',
              value: formatCurrency(totalValue / 100.0),
              color: Theme.of(context).colorScheme.primary,
            ),
          _StatItem(label: 'Pick-up', value: '$unassigned', color: subtextCol),
        ];

        return [
          SliverToBoxAdapter(child: _summary(stats)),
          SliverToBoxAdapter(child: _buildSearchBar(context)),
          ..._buildOrderSlivers(context, list, status: 'pending'),
        ];
      },
    );
  }

  List<Widget> _completedTabSlivers(
    BuildContext context,
    String? activeStoreId,
  ) {
    final canSeeMoney = Gates.seeOrderMoney.allows(ref);
    final canSeeExtendedRanges = Gates.seeExtendedDateRanges.allows(ref);
    final tracksCrates = businessTracksCrates(
      ref.watch(currentBusinessProvider),
    );
    final key = (
      status: 'completed',
      storeId: activeStoreId,
      dateLabel: _completedFilter,
      search: _searchQuery,
    );

    final statsAsync = ref.watch(ordersStatsProvider(key));
    final stateAsync = ref.watch(paginatedOrdersProvider(key));

    return statsAsync.when(
      loading: () => const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        ),
      ],
      error: (e, _) => [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: Text('Error: $e')),
        ),
      ],
      data: (stats) {
        final statItems = [
          _StatItem(
            label: 'Completed',
            value: '${stats.count}',
            color: _fixed.green,
          ),
          if (canSeeMoney) ...[
            _StatItem(
              label: 'Revenue',
              value: formatCurrency(stats.totalAmountKobo / 100.0),
              color: Theme.of(context).colorScheme.primary,
            ),
            _StatItem(
              label: 'Collected',
              value: formatCurrency(stats.amountPaidKobo / 100.0),
              color: _fixed.green,
            ),
            if (tracksCrates)
              _StatItem(
                label: 'Crate Deposits',
                value: formatCurrency(stats.crateDepositPaidKobo / 100.0),
                color: subtextCol,
              ),
          ],
        ];

        if (stateAsync.isLoading) {
          return const [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            ),
          ];
        }

        return [
          SliverToBoxAdapter(child: _summary(statItems)),
          SliverToBoxAdapter(
            child: _buildSearchBar(
              context,
              selectedFilter: _completedFilter,
              onSelectFilter: (f) => _changeFilter('completed', f),
              filterOptions: _periodOptions(canSeeExtendedRanges),
            ),
          ),
          ..._buildPaginatedOrderSlivers(
            context,
            stateAsync.orders,
            status: 'completed',
            isLoadingMore: stateAsync.isLoadingMore,
            hasMore: stateAsync.hasMore,
            key: key,
          ),
        ];
      },
    );
  }

  List<Widget> _cancelledTabSlivers(
    BuildContext context,
    String? activeStoreId,
  ) {
    final canSeeMoney = Gates.seeOrderMoney.allows(ref);
    final canSeeExtendedRanges = Gates.seeExtendedDateRanges.allows(ref);
    final key = (
      status: 'cancelled',
      storeId: activeStoreId,
      dateLabel: _cancelledFilter,
      search: _searchQuery,
    );

    final statsAsync = ref.watch(ordersStatsProvider(key));
    final stateAsync = ref.watch(paginatedOrdersProvider(key));

    return statsAsync.when(
      loading: () => const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        ),
      ],
      error: (e, _) => [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: Text('Error: $e')),
        ),
      ],
      data: (stats) {
        final statItems = [
          _StatItem(
            label: 'Cancelled',
            value: '${stats.count}',
            color: _fixed.danger,
          ),
          // #196 — "Refunds Issued" now shows the MONEY handed back on these
          // orders (un-voided `payment_transactions.type == 'refund'` rows,
          // the same basis as the Daily Reconciliation), not a count of the
          // retired `refunded` status that nothing writes — which is why it read
          // 0 forever. Because it became a naira figure it moved inside the
          // see-money gate, next to the other money tiles.
          if (canSeeMoney) ...[
            _StatItem(
              label: 'Value Forfeited',
              value: formatCurrency(stats.totalAmountKobo / 100.0),
              color: _fixed.danger,
            ),
            _StatItem(
              label: 'Refunds Issued',
              value: formatCurrency(stats.refundsIssuedKobo / 100.0),
              color: _fixed.info,
            ),
          ],
        ];

        if (stateAsync.isLoading) {
          return const [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            ),
          ];
        }

        return [
          SliverToBoxAdapter(child: _summary(statItems)),
          SliverToBoxAdapter(
            child: _buildSearchBar(
              context,
              selectedFilter: _cancelledFilter,
              onSelectFilter: (f) => _changeFilter('cancelled', f),
              filterOptions: _periodOptions(canSeeExtendedRanges),
            ),
          ),
          ..._buildPaginatedOrderSlivers(
            context,
            stateAsync.orders,
            status: 'cancelled',
            isLoadingMore: stateAsync.isLoadingMore,
            hasMore: stateAsync.hasMore,
            key: key,
          ),
        ];
      },
    );
  }

  List<Widget> _buildPaginatedOrderSlivers(
    BuildContext context,
    List<OrderWithItems> list, {
    required String status,
    required bool isLoadingMore,
    required bool hasMore,
    required ({String status, String? storeId, String dateLabel, String search})
    key,
  }) {
    if (list.isEmpty) {
      IconData icon;
      String text;
      if (status == 'completed') {
        icon = AppIcons.auditCheck;
        text = _searchQuery.isNotEmpty
            ? 'No completed orders match "$_searchQuery"'
            : 'No completed orders';
      } else {
        icon = AppIcons.block;
        text = _searchQuery.isNotEmpty
            ? 'No cancelled orders match "$_searchQuery"'
            : 'No cancelled orders';
      }

      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: OrdersEmptyState(icon: icon, text: text),
          ),
        ),
      ];
    }

    final canRefund = Gates.refundOrder.allows(ref);
    // #171: Confirm is gated Cashier-tier and above (sales.confirm). Hide the
    // Confirm button entirely without it (hide-don't-block, hard rule #7).
    final canConfirm = Gates.confirmOrder.allows(ref);

    // We add 1 to the child count if we are loading more to render the spinner.
    final childCount = list.length + (isLoadingMore ? 1 : 0);

    return [
      SliverLayoutBuilder(
        builder: (context, constraints) {
          final side = ordersCapPadding(
            constraints.crossAxisExtent,
            context.getRSize(16),
          );
          return SliverPadding(
            padding: EdgeInsets.fromLTRB(
              side,
              context.getRSize(16),
              side,
              context.getRSize(100) + context.bottomInset,
            ),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                // Trigger load more near the bottom
                if (hasMore && !isLoadingMore && index >= list.length - 5) {
                  Future.microtask(() {
                    if (mounted) {
                      ref
                          .read(paginatedOrdersProvider(key).notifier)
                          .loadMore();
                    }
                  });
                }

                if (index == list.length) {
                  return Padding(
                    padding: EdgeInsets.symmetric(
                      vertical: context.getRSize(16),
                    ),
                    child: const Center(child: CircularProgressIndicator()),
                  );
                }

                final item = list[index];
                // #551: a Completed card offers Return only when the Order
                // Module says the sale is returnable (it owns the rule).
                if (status == 'completed' && canRefund) {
                  return _ReturnableCard(
                    key: ValueKey('ret-${item.order.id}'),
                    orderWithItems: item,
                    status: status,
                    onViewReceipt: () => _viewReceipt(context, item),
                    onReturn: () => _returnCompletedSale(item),
                  );
                }
                return _OrderCard(
                  orderWithItems: item,
                  status: status,
                  onMarkAsDelivered: (status == 'pending' && canConfirm)
                      ? () => _markAsDelivered(item)
                      : null,
                  onRefund: (status == 'pending' && canRefund)
                      ? () => _refundPendingOrder(item.order)
                      : null,
                  onAssignRider: status == 'pending'
                      ? (orderId) => _showRiderSelection(context, orderId)
                      : null,
                  onViewReceipt: () => _viewReceipt(context, item),
                );
              }, childCount: childCount),
            ),
          );
        },
      ),
    ];
  }

  // ─────────────────────────── ORDER LIST ─────────────────────────────────

  List<Widget> _buildOrderSlivers(
    BuildContext context,
    List<OrderWithItems> list, {
    required String status,
  }) {
    if (list.isEmpty) {
      IconData icon;
      String text;
      if (status == 'pending') {
        icon = AppIcons.box;
        text = _searchQuery.isNotEmpty
            ? 'No pending orders match "$_searchQuery"'
            : 'No pending orders';
      } else if (status == 'completed') {
        icon = AppIcons.auditCheck;
        text = _searchQuery.isNotEmpty
            ? 'No completed orders match "$_searchQuery"'
            : 'No completed orders';
      } else {
        icon = AppIcons.block;
        text = _searchQuery.isNotEmpty
            ? 'No cancelled orders match "$_searchQuery"'
            : 'No cancelled orders';
      }

      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: OrdersEmptyState(icon: icon, text: text),
          ),
        ),
      ];
    }

    // §19.7: the Pending-tab Refund is gated to CEO + Manager (sales.cancel).
    final canRefund = Gates.refundOrder.allows(ref);
    // #171: Confirm is gated Cashier-tier and above (sales.confirm).
    final canConfirm = Gates.confirmOrder.allows(ref);

    return [
      SliverLayoutBuilder(
        builder: (context, constraints) {
          final side = ordersCapPadding(
            constraints.crossAxisExtent,
            context.getRSize(16),
          );
          return SliverPadding(
            padding: EdgeInsets.fromLTRB(
              side,
              context.getRSize(16),
              side,
              context.getRSize(100) + context.bottomInset,
            ),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final item = list[index];
                // #551: a Completed card offers Return only when the Order
                // Module says the sale is returnable (it owns the rule).
                if (status == 'completed' && canRefund) {
                  return _ReturnableCard(
                    key: ValueKey('ret-${item.order.id}'),
                    orderWithItems: item,
                    status: status,
                    onViewReceipt: () => _viewReceipt(context, item),
                    onReturn: () => _returnCompletedSale(item),
                  );
                }
                return _OrderCard(
                  orderWithItems: item,
                  status: status,
                  onMarkAsDelivered: (status == 'pending' && canConfirm)
                      ? () => _markAsDelivered(item)
                      : null,
                  // §19.7: Refund replaces the old Cancel button on the Pending
                  // tab and is hidden unless the user may cancel a sale. It
                  // reverses the sale (stock, payment, both wallet legs) and moves
                  // the order to Cancelled. The Completed and Cancelled tabs have
                  // no Refund button here (§19.8; a crate-free Completed sale offers Return, #551).
                  onRefund: (status == 'pending' && canRefund)
                      ? () => _refundPendingOrder(item.order)
                      : null,
                  onAssignRider: status == 'pending'
                      ? (orderId) => _showRiderSelection(context, orderId)
                      : null,
                  onViewReceipt: () => _viewReceipt(context, item),
                );
              }, childCount: list.length),
            ),
          );
        },
      ),
    ];
  }

  // ─────────────────────── ACTION HANDLERS (unchanged) ────────────────────

  void _markAsDelivered(OrderWithItems orderWithItems) {
    _executeMarkDelivered(orderWithItems);
  }

  void _executeMarkDelivered(OrderWithItems orderWithItems) async {
    final order = orderWithItems.order;

    // ── Write-boundary gate (#171, ADR 0002) ────────────────────────────────
    // Confirm runs the crate-deposit settlement (real money) before the status
    // flip, so re-check the sales.confirm grant here with the throwing form. The
    // Confirm button already hides without it, but a grant revoked mid-session —
    // or a stale back-stack — must not reach the settlement.
    try {
      Gates.confirmOrder.require(ref);
    } on GateDeniedError {
      showGateDenied(context, Gates.confirmOrder);
      return;
    }

    if (!mounted) return;
    // The modal only COLLECTS the counted-back empties now (ADR 0004); the
    // settlement runs inside Confirm (markAsCompleted). null = cashier dismissed.
    final crateResult = await CrateReturnModal.show(
      context,
      orderWithItems,
      ref: ref,
    );
    if (crateResult == null) return;

    if (!mounted) return;

    // #171: paying the deposit refund AS CASH out of the till additionally
    // requires the wallet-withdraw permission on top of sales.confirm. The modal
    // hides the Cash chip without it, but re-check at the write boundary.
    if (crateResult.refundAsCash) {
      try {
        Gates.confirmOrderCashRefund.require(ref);
      } on GateDeniedError {
        showGateDenied(context, Gates.confirmOrderCashRefund);
        return;
      }
    }

    try {
      await ref
          .read(orderServiceProvider)
          .markAsCompleted(
            order.id,
            ref.read(authProvider).currentUser?.id ?? '',
            customerId: order.customerId,
            storeId: order.storeId,
            crateReturns: crateResult.lines,
            refundAsCash: crateResult.refundAsCash,
          );

      final receipt = model.DeliveryReceipt(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        orderId: order.id.toString(),
        referenceNumber: ref
            .read(deliveryReceiptServiceProvider)
            .generateReference(),
        riderName: order.riderName,
        outstandingAmount: (order.netAmountKobo - order.amountPaidKobo) / 100.0,
        paidAmount: order.amountPaidKobo / 100.0,
        createdAt: DateTime.now(),
      );
      ref.read(deliveryReceiptServiceProvider).addReceipt(receipt);

      if (mounted) {
        AppNotification.showSuccess(
          context,
          'Order #${order.id} marked as completed.',
        );
      }
    } catch (e) {
      if (mounted) {
        AppNotification.showError(context, 'Could not complete order: $e');
      }
      return;
    }
  }

  /// §19.7: Refund a Pending order (Manager/CEO — gated at the call site via
  /// sales.cancel). The reversal runs in OrdersDao.markCancelled: stock
  /// restored, payment voided, and **both wallet legs reversed** (the wallet
  /// returns to its pre-sale balance, §14.3). The order moves to the Cancelled
  /// tab.
  void _refundPendingOrder(OrderData order) async {
    final reasonController = TextEditingController();
    final refundLabel = formatCurrency(order.amountPaidKobo / 100.0);

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final reason = reasonController.text.trim();
            return AlertDialog(
              // Scrolls so the text box stays reachable with the keyboard open.
              scrollable: true,
              title: Text(
                'Refund ${order.orderNumber}',
                style: ctx.screenTitleStyle.copyWith(color: textCol),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'A full refund of $refundLabel goes back out and the stock '
                    'is restored. The customer\'s credit balance returns to its pre-sale '
                    'balance, and the cash leaves today\'s till. The order then '
                    'moves to Cancelled.',
                    style: ctx.regularStyle(13).copyWith(color: subtextCol),
                  ),
                  SizedBox(height: context.getRSize(16)),
                  AppInput(
                    key: const Key('orders-refund-reason'),
                    controller: reasonController,
                    autofocus: true,
                    minLines: 1,
                    maxLines: 3,
                    labelText: 'Reason (required)',
                    onChanged: (_) => setDialogState(() {}),
                  ),
                ],
              ),
              actions: [
                AppButton(
                  text: 'Back',
                  variant: AppButtonVariant.ghost,
                  isFullWidth: false,
                  onPressed: () => Navigator.pop(ctx),
                ),
                AppButton(
                  text: 'Issue Refund',
                  icon: AppIcons.refresh,
                  variant: AppButtonVariant.danger,
                  isFullWidth: false,
                  onPressed: reason.isEmpty
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          _executeRefund(order, reason);
                        },
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _executeRefund(OrderData order, String reason) async {
    try {
      Gates.refundOrder.require(ref);
    } on GateDeniedError {
      showGateDenied(context, Gates.refundOrder);
      return;
    }
    final staffId = ref.read(authProvider).currentUser?.id ?? '';
    try {
      await ref
          .read(orderServiceProvider)
          .markAsCancelled(order.id, reason, staffId,
            gateContext: ref.read(gateContextProvider));
      if (mounted) {
        AppNotification.showSuccess(
          context,
          'Refund issued for ${order.orderNumber}.',
        );
      }
    } on GateDeniedError {
      if (mounted) showGateDenied(context, Gates.refundOrder);
    } catch (e) {
      if (mounted) {
        AppNotification.showError(context, 'Could not issue refund: $e');
      }
    }
  }

  /// #551: Return a crate-free Completed sale. The dialog only collects input;
  /// the Order Module's command does every write (and re-checks the Gate and
  /// returnability).
  Future<void> _returnCompletedSale(OrderWithItems item) async {
    final order = item.order;
    final input = await showReturnSaleDialog(
      context,
      orderNumber: order.orderNumber,
      refundLabel: formatCurrency(order.amountPaidKobo / 100.0),
      lines: [
        for (final l in item.items)
          ReturnLineInput(
            lineId: l.item.id,
            name: l.displayName,
            quantity: l.item.quantity,
            canBeDamaged: l.item.productId != null,
          ),
      ],
    );
    if (input == null || !mounted) return;
    try {
      Gates.refundOrder.require(ref);
    } on GateDeniedError {
      showGateDenied(context, Gates.refundOrder);
      return;
    }
    final staffId = ref.read(authProvider).currentUser?.id ?? '';
    try {
      await ref.read(orderServiceProvider).returnCompletedSale(
            orderId: order.id,
            reason: input.reason,
            staffId: staffId,
            gateContext: ref.read(gateContextProvider),
            damageReasonKey: input.damageReasonKey,
            damagedQtyByLine: input.damagedQtyByLine,
          );
      if (mounted) {
        AppNotification.showSuccess(
          context,
          'Sale ${order.orderNumber} returned.',
        );
      }
    } on GateDeniedError {
      if (mounted) showGateDenied(context, Gates.refundOrder);
    } on ReturnRefusedException catch (e) {
      if (mounted) AppNotification.showError(context, e.message);
    } catch (e) {
      if (mounted) {
        AppNotification.showError(context, 'Could not return the sale: $e');
      }
    }
  }

  void _showRiderSelection(BuildContext context, String orderId) async {
    // Staff/riders are no longer tracked. Mark the order as pick-up by default.
    try {
      await ref
          .read(orderServiceProvider)
          .assignRider(orderId, 'Pick-up Order');
    } catch (e) {
      if (context.mounted) {
        AppNotification.showError(
          context,
          'Could not update this order. Please try again.',
        );
      }
    }
  }

  void _viewReceipt(BuildContext context, OrderWithItems richOrder) async {
    DateTime? reshareDate;
    DateTime? reprintDate;

    final storeAddress = await _resolveStoreAddress(richOrder.order.storeId);

    // Fetch manufacturers once before showing the modal
    final db = ref.read(databaseProvider);
    final mfrList = await db.inventoryDao.watchAllManufacturers().first;
    final manufacturerNames = {for (final m in mfrList) m.id: m.name};

    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (modalCtx) {
        final currentOrder = richOrder.order;
        // #200 / US 33 — rebuild the ORIGINAL receipt's money block from the
        // recorded order, so a reprint prints the same Subtotal / Discount /
        // Total the customer first got. `totalKobo` returns
        // `currentOrder.totalAmountKobo` by construction.
        final totals = receiptTotalsFromOrder(
          totalAmountKobo: currentOrder.totalAmountKobo,
          crateDepositPaidKobo: currentOrder.crateDepositPaidKobo,
          discountKobo: currentOrder.discountKobo,
        );
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              key: OrdersKeys.receiptSheet,
              height: context.sheetMaxHeight(0.85),
              decoration: BoxDecoration(
                color: surfaceCol,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(AppSpacing.borderRadiusXL),
                ),
              ),
              child: Column(
                children: [
                  Container(
                    margin: EdgeInsets.symmetric(
                      vertical: context.getRSize(12),
                    ),
                    width: context.getRSize(40),
                    height: context.getRSize(4),
                    decoration: BoxDecoration(
                      color: Theme.of(context).dividerColor,
                      borderRadius: BorderRadius.circular(
                        AppSpacing.borderRadiusS,
                      ),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(
                        context.getRSize(20),
                        context.getRSize(10),
                        context.getRSize(20),
                        context.getRSize(30),
                      ),
                      child: Screenshot(
                        controller: _screenshotCtrl,
                        child: Consumer(
                          builder: (_, receiptRef, _) => ReceiptWidget(
                            orderId: currentOrder.orderNumber,
                            cart: richOrder.items
                                .map(
                                  (ri) => {
                                    'name': ri.displayName,
                                    'size': ri.product?.size,
                                    'qty': ri.item.quantity,
                                    'price': ri.item.unitPriceKobo / 100.0,
                                    'unit': ri.product?.unit,
                                    'trackEmpties': ri.product?.trackEmpties,
                                    'manufacturerId':
                                        ri.product?.manufacturerId,
                                  },
                                )
                                .toList(),
                            // #176 — a reprint must show the SAME goods/deposit
                            // split as the original: goods = grand total − deposit,
                            // the deposit on its own line, grand total = the amount
                            // owed (goods net + deposit). The old form
                            // (subtotal: totalAmount, crateDeposit: 0) inflated the
                            // printed Subtotal by the deposit and hid it entirely.
                            // #200 — and the discount goes back INTO Subtotal with
                            // its own line under it, so a discounted order's
                            // reprint no longer reads a lower Subtotal than the
                            // original (see [receiptTotalsFromOrder]).
                            subtotal: totals.subtotalKobo / 100.0,
                            discount: totals.discountKobo / 100.0,
                            crateDeposit: totals.depositKobo / 100.0,
                            total: totals.totalKobo / 100.0,
                            manufacturerNames: manufacturerNames,
                            // #432 — a Pay on delivery order says so.
                            paymentMethod:
                                receiptRef
                                    .watch(payOnDeliveryByOrderProvider)[
                                        currentOrder.id]
                                    ?.label ??
                                currentOrder.paymentType,
                            customerName:
                                richOrder.customer?.name ?? 'Walk-in Customer',
                            cashReceived:
                                currentOrder.paymentType == 'Wallet Payment'
                                ? currentOrder.netAmountKobo / 100.0
                                : currentOrder.amountPaidKobo / 100.0,
                            reprintDate: reprintDate,
                            reshareDate: reshareDate,
                            orderStatus: currentOrder.status,
                            refundAmount: currentOrder.amountPaidKobo / 100.0,
                            storeAddress: storeAddress,
                            businessName: ref.read(currentBusinessNameProvider),
                            // Watched, so the label follows the business row
                            // even when nothing else keeps it loaded (#487).
                            tracksCrates: businessTracksCrates(
                              receiptRef.watch(currentBusinessProvider),
                            ),
                            logoPath: ref
                                .read(currentBusinessLogoPathProvider)
                                .valueOrNull,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.all(
                      context.getRSize(16),
                    ).add(EdgeInsets.only(bottom: context.deviceBottomPadding)),
                    child: Row(
                      children: [
                        Expanded(
                          child: AppButton(
                            text: 'Print',
                            icon: AppIcons.print,
                            onPressed: () {
                              setModalState(() {
                                reprintDate = DateTime.now();
                                reshareDate = null;
                              });
                              _printReceipt(
                                context,
                                richOrder,
                                storeAddress: storeAddress,
                              );
                            },
                          ),
                        ),
                        SizedBox(width: context.getRSize(12)),
                        // §19.8: the receipt modal is read-only. Refunds happen
                        // only from the Pending tab (§19.7), before an order is
                        // confirmed — there is no Refund button here.
                        Expanded(
                          child: AppButton(
                            text: 'Share',
                            icon: AppIcons.share,
                            variant: AppButtonVariant.secondary,
                            onPressed: () async {
                              setModalState(() {
                                reshareDate = DateTime.now();
                                reprintDate = null;
                              });
                              await Future.delayed(
                                const Duration(milliseconds: 100),
                              );
                              if (context.mounted) {
                                _shareReceipt(
                                  context,
                                  richOrder,
                                  reshareDate: reshareDate,
                                );
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    ).then((_) {
      reshareDate = null;
      reprintDate = null;
    });
  }

  Future<void> _printReceipt(
    BuildContext context,
    OrderWithItems richOrder, {
    String? storeAddress,
  }) async {
    final order = richOrder.order;

    final receiptMapping = richOrder.items
        .map(
          (ri) => {
            'name': ri.displayName,
            'size': ri.product?.size,
            'qty': ri.item.quantity,
            'price': ri.item.unitPriceKobo / 100.0,
            'unit': ri.product?.unit,
            'trackEmpties': ri.product?.trackEmpties,
            'manufacturerId': ri.product?.manufacturerId,
          },
        )
        .toList();

    AppNotification.showInfo(context, 'Preparing receipt...');

    try {
      final printer = ref.read(printerServiceProvider);
      final granted = await printer.requestPermissions();
      if (!granted) {
        if (!context.mounted) return;
        AppNotification.showError(context, 'Bluetooth permissions denied');
        return;
      }

      final finalStoreAddress =
          storeAddress ?? await _resolveStoreAddress(order.storeId);

      final walletBalance = richOrder.customer == null
          ? null
          : (await ref
                    .read(databaseProvider)
                    .customersDao
                    .getWalletBalanceKobo(richOrder.customer!.id)) /
                100.0;

      final db = ref.read(databaseProvider);
      final mfrList = await db.inventoryDao.watchAllManufacturers().first;
      final manufacturerNames = {for (final m in mfrList) m.id: m.name};

      // #176 — real goods/deposit split on the thermal reprint (see the
      // on-screen reprint above): goods = grand total − deposit, deposit on its
      // own line, grand total = goods net + deposit. The old
      // (subtotal: totalAmount, crateDeposit: 0) inflated the printed Subtotal
      // by the deposit and hid it. #200 — plus the discount line, from the same
      // shared derivation the on-screen copy uses.
      final totals = receiptTotalsFromOrder(
        totalAmountKobo: order.totalAmountKobo,
        crateDepositPaidKobo: order.crateDepositPaidKobo,
        discountKobo: order.discountKobo,
      );
      // Built per paper width: the picker fallback below may land on a
      // different printer with a different roll, and rebuilds for it.
      Future<List<int>> buildBytes(ReceiptPaperSize paperSize) =>
          ThermalReceiptService.buildReceipt(
            orderId: order.orderNumber,
            cart: receiptMapping,
            subtotal: totals.subtotalKobo / 100.0,
            discount: totals.discountKobo / 100.0,
            crateDeposit: totals.depositKobo / 100.0,
            total: totals.totalKobo / 100.0,
            // #432 — a Pay on delivery order says so.
            paymentMethod:
                ref.read(payOnDeliveryByOrderProvider)[order.id]?.label ??
                order.paymentType,
            customerName: richOrder.customer?.name ?? 'Walk-in Customer',
            cashReceived: order.paymentType == 'Wallet Payment'
                ? order.netAmountKobo / 100.0
                : order.amountPaidKobo / 100.0,
            walletBalance: walletBalance,
            reprintDate: DateTime.now(),
            orderStatus: order.status,
            refundAmount: order.amountPaidKobo / 100.0,
            storeAddress: finalStoreAddress,
            businessName: ref.read(currentBusinessNameProvider),
            tracksCrates: businessTracksCrates(
              ref.read(currentBusinessProvider),
            ),
            manufacturerNames: manufacturerNames,
            paperSize: paperSize,
          );

      // Auto-print: reuse the live connection, otherwise auto-connect to the
      // last-used / paired printer, asking once for a new printer's paper
      // width. Only when no printer connects do we fall through to the picker.
      if (!context.mounted) return;
      final target = await prepareReceiptPrinter(context, printer);
      if (!context.mounted) return;
      final bytes = await buildBytes(target.paperSize);
      if (!context.mounted) return;
      if (target.connected) {
        final printed = await printer.printBytes(bytes);
        if (!context.mounted) return;
        if (printed) {
          AppNotification.showSuccess(context, 'Print successful');
          _logReprint(order.id.toString());
          return;
        }
      }

      if (context.mounted) {
        final selectedDevice = await showModalBottomSheet<BluetoothInfo>(
          context: context,
          isScrollControlled: true,
          constraints: BoxConstraints(maxHeight: context.sheetMaxHeight(0.5)),
          builder: (pickerCtx) => PrinterPicker(
            onSelected: (device) => Navigator.pop(pickerCtx, device),
          ),
        );

        if (selectedDevice != null && context.mounted) {
          AppNotification.showInfo(
            context,
            'Connecting to ${selectedDevice.name}...',
          );

          final connected = await printer.connect(selectedDevice.macAdress);
          if (!context.mounted) return;

          if (connected) {
            // The picked printer may be new (asks once) or use a different
            // roll than the one the bytes were laid out for.
            final picked = await prepareReceiptPrinter(context, printer);
            if (!context.mounted) return;
            final pickedBytes = picked.paperSize == target.paperSize
                ? bytes
                : await buildBytes(picked.paperSize);
            final printOk = await printer.printBytesDirectly(pickedBytes);
            if (!context.mounted) return;
            if (printOk) {
              AppNotification.showSuccess(context, 'Print successful');
              _logReprint(order.id.toString());
            } else {
              AppNotification.showError(context, 'Print failed after connect');
            }
          } else {
            AppNotification.showError(
              context,
              'Failed to connect to ${selectedDevice.name}',
            );
          }
        }
      }
    } catch (e) {
      if (context.mounted) {
        AppNotification.showError(context, 'Error printing: $e');
      }
    }
  }

  Future<void> _shareReceipt(
    BuildContext context,
    OrderWithItems richOrder, {
    DateTime? reshareDate,
  }) async {
    final order = richOrder.order;

    await Future.delayed(const Duration(milliseconds: 100));

    try {
      final Uint8List? imageBytes = await _screenshotCtrl.capture(
        delay: const Duration(milliseconds: 50),
        pixelRatio: 3.0,
      );

      if (imageBytes == null) {
        if (context.mounted) {
          AppNotification.showError(context, 'Failed to capture receipt');
        }
        return;
      }

      final dir = await getTemporaryDirectory();
      final stamp = reshareDate != null ? 'reshare' : 'reprint';
      final file = File(
        '${dir.path}/reebaplus_pos_${stamp}_${order.id}_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(imageBytes);

      await Share.shareXFiles([
        XFile(file.path),
      ], text: 'Reebaplus POS Receipt Reprint #${order.id}');
      _logReprint(order.id.toString());
    } catch (e) {
      if (context.mounted) {
        AppNotification.showError(context, 'Error sharing: $e');
      }
    }
  }

  Future<void> _logReprint(String orderId) async {
    await ref
        .read(activityLogProvider)
        .logAction(
          'Receipt Reprinted',
          'Receipt for order #$orderId was reprinted',
          orderId: orderId,
        );
  }
}

// ═══════════════════════════ SUMMARY STRIP ══════════════════════════════════

class _StatItem {
  final String label;
  final String value;
  final Color? color;
  const _StatItem({required this.label, required this.value, this.color});
}

// ═══════════════════════════ ORDER CARD ═════════════════════════════════════

/// #551: a Completed card that asks the Order Module whether the sale is
/// returnable before offering Refund (the screen never re-derives the rule).
class _ReturnableCard extends ConsumerStatefulWidget {
  final OrderWithItems orderWithItems;
  final String status;
  final VoidCallback onViewReceipt;
  final VoidCallback onReturn;

  const _ReturnableCard({
    super.key,
    required this.orderWithItems,
    required this.status,
    required this.onViewReceipt,
    required this.onReturn,
  });

  @override
  ConsumerState<_ReturnableCard> createState() => _ReturnableCardState();
}

class _ReturnableCardState extends ConsumerState<_ReturnableCard> {
  late Future<bool> _returnable;

  @override
  void initState() {
    super.initState();
    _returnable = _ask();
  }

  @override
  void didUpdateWidget(_ReturnableCard old) {
    super.didUpdateWidget(old);
    if (old.orderWithItems.order.lastUpdatedAt !=
        widget.orderWithItems.order.lastUpdatedAt) {
      _returnable = _ask();
    }
  }

  Future<bool> _ask() => ref
      .read(orderServiceProvider)
      .isReturnable(widget.orderWithItems.order.id)
      .catchError((_) => false);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _returnable,
      builder: (context, snap) => _OrderCard(
        orderWithItems: widget.orderWithItems,
        status: widget.status,
        onRefund: snap.data == true ? widget.onReturn : null,
        onViewReceipt: widget.onViewReceipt,
      ),
    );
  }
}

class _OrderCard extends ConsumerWidget {
  final OrderWithItems orderWithItems;
  final String status;
  final VoidCallback? onMarkAsDelivered;
  final Function(String)? onAssignRider;
  // §19.7: fires on the Pending tab only (Refund). Null hides the button —
  // either the order isn't pending, or the user lacks sales.cancel.
  final VoidCallback? onRefund;
  final VoidCallback onViewReceipt;

  const _OrderCard({
    required this.orderWithItems,
    required this.status,
    this.onMarkAsDelivered,
    this.onAssignRider,
    this.onRefund,
    required this.onViewReceipt,
  });

  // Part paid now, the rest booked to the customer's credit: checkout's
  // 'Cash / Credit' / 'Transfer / Credit', the legacy 'Cash / Transfer /
  // Wallet', or 'mixed'. Owner (#402): badge these "Partial".
  bool _isPartialPayment(String lower) =>
      lower.contains('partial') ||
      lower.contains('mixed') ||
      (lower.contains('/') &&
          (lower.contains('credit') || lower.contains('wallet')));

  // The payment badge's tone (fixed colours).
  TagPillTone _paymentTone(String paymentType) {
    final lower = paymentType.toLowerCase();
    if (_isPartialPayment(lower)) return TagPillTone.info;
    if (lower.contains('wallet')) return TagPillTone.info;
    if (lower.contains('credit payment')) return TagPillTone.info;
    if (lower.contains('credit')) return TagPillTone.danger;
    return TagPillTone.green; // paid in full: Cash / Transfer / Card
  }

  // Returns a short label for the payment type badge. Owner (#402): a
  // transfer shows "Transfer" and a part payment "Partial" (both used to
  // read "Cash" / "Credit").
  String _paymentLabel(String paymentType) {
    final lower = paymentType.toLowerCase();
    if (_isPartialPayment(lower)) return 'Partial';
    if (lower.contains('wallet') || lower.contains('credit payment')) {
      return 'Credit Payment';
    }
    if (lower.contains('credit')) return 'Credit';
    if (lower.contains('transfer')) return 'Transfer';
    return 'Cash';
  }

  // Formats date as "04 Apr 2026" or "Today"
  String _formatDate(DateTime t) {
    final now = DateTime.now();
    final isToday =
        t.year == now.year && t.month == now.month && t.day == now.day;
    if (isToday) return 'Today';
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${t.day.toString().padLeft(2, '0')} ${months[t.month - 1]} ${t.year}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final textCol = t.colorScheme.onSurface;
    final subtextCol = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    final borderCol = t.dividerColor;
    final primary = t.colorScheme.primary;

    final order = orderWithItems.order;
    final customer = orderWithItems.customer;
    final items = orderWithItems.items;

    // §19.3: roles below Manager see items + quantities only — no monetary
    // values (line prices, total, paid, discount, wallet-debt) anywhere on the
    // card. The printed receipt (onViewReceipt) is unchanged.
    final canSeeMoney = Gates.seeOrderMoney.allows(ref);
    // The footer block (divider + money rows) is replaced by just the
    // cancellation reason when money is hidden — so a low role still sees why a
    // cancelled order was cancelled, with no money.
    final showCancelReason =
        status == 'cancelled' &&
        order.cancellationReason != null &&
        order.cancellationReason!.isNotEmpty;

    // Accent colour for the left stripe (fixed colours, #393).
    final accentColor = orderStatusColor(context, status);

    // Financial values. No per-order "owes" figure (§19.2): the sale is settled
    // at checkout — received, or charged through the credit balance (§14.3) — so the
    // order never carries a balance. Customer debt lives on the credit balance (rule #4)
    // and shows via the credit-debt badge below, only when the balance is < 0.
    final hasDiscount = order.discountKobo > 0;

    // Credit badge — only for named customers with a negative balance (debt).
    // Balance comes from the live ledger via creditBalancesKoboProvider.
    final balances =
        ref.watch(creditBalancesKoboProvider).valueOrNull ?? const <int, int>{};
    final creditBalanceKobo = customer == null
        ? 0
        : (balances[customer.id] ?? 0);
    final showCreditDebt = customer != null && creditBalanceKobo < 0;

    // #432 — a Pay on delivery order (a credit order linked to an Online
    // Order): labelled "Pay on delivery · ₦X to collect" (never "credit"), and
    // Mark as paid shows while money is left to collect — hidden without
    // orders.pay_on_delivery.mark_paid (hide-don't-block, re-checked at save).
    final pod = ref.watch(payOnDeliveryByOrderProvider)[order.id];
    final canMarkPaid =
        pod != null &&
        pod.isLive &&
        !pod.isPaid &&
        Gates.markPayOnDeliveryPaid.allows(ref);

    // §19.4: who created the order (staffId → user name). Not a monetary value,
    // so it shows for every role (the §19.3 money-hiding rule does not apply).
    final users =
        ref.watch(usersByBusinessProvider).valueOrNull ??
        const <String, UserData>{};
    final creatorName = order.staffId == null
        ? 'Unknown'
        : (users[order.staffId!]?.name ?? 'Unknown');

    // Timestamp
    final time = status == 'pending'
        ? order.createdAt
        : (status == 'completed'
              ? (order.completedAt ?? order.createdAt)
              : (order.cancelledAt ?? order.createdAt));
    final dateStr = _formatDate(time);
    final timeStr =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    // Items display — show first 2, then "+N more"
    final displayItems = items.length > 2 ? items.sublist(0, 2) : items;
    final extraCount = items.length - displayItems.length;

    final radius = BorderRadius.circular(AppSpacing.borderRadiusL);

    return Padding(
      key: orderRowKey(order.id),
      padding: EdgeInsets.only(bottom: context.getRSize(12)),
      child: DecoratedBox(
        decoration: AppDecorations.card(
          context,
          radius: AppSpacing.borderRadiusL,
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onViewReceipt,
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Left accent stripe (status colour).
                    Container(width: context.getRSize(4), color: accentColor),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // ── Header: Customer + rider / status ─────────────
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                              context.getRSize(12),
                              context.getRSize(10),
                              context.getRSize(8),
                              context.getRSize(10),
                            ),
                            child: Row(
                              children: [
                                // Customer profile. For a named customer this
                                // taps through to their detail screen; a null
                                // onTap (walk-in) lets the tap fall through to
                                // the card's onViewReceipt.
                                Expanded(
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(
                                      AppSpacing.borderRadiusM,
                                    ),
                                    onTap: customer == null
                                        ? null
                                        : () => Navigator.of(context).push(
                                            slideDownRoute(
                                              CustomerDetailScreen(
                                                customer: Customer.fromDb(
                                                  customer,
                                                ),
                                              ),
                                            ),
                                          ),
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        minHeight: kMinInteractiveDimension,
                                      ),
                                      child: Row(
                                        children: [
                                          IconTile(
                                            icon: AppIcons.user,
                                            tone: customer == null
                                                ? IconTileTone.neutral
                                                : IconTileTone.info,
                                            size: 40,
                                          ),
                                          SizedBox(width: context.getRSize(10)),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                Text(
                                                  customer?.name ??
                                                      'Walk-in Customer',
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: context
                                                      .boldStyle(15)
                                                      .copyWith(color: textCol),
                                                ),
                                                if (customer?.addressText !=
                                                        null &&
                                                    customer!.addressText !=
                                                        'N/A')
                                                  Text(
                                                    customer.addressText,
                                                    style: context
                                                        .regularStyle(12)
                                                        .copyWith(
                                                          color: subtextCol,
                                                        ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                SizedBox(width: context.getRSize(8)),

                                // Right side: rider (pending) or status pill.
                                if (status == 'pending')
                                  Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        key: OrdersKeys.rider,
                                        tooltip: order.riderName,
                                        constraints: const BoxConstraints(
                                          minWidth: kMinInteractiveDimension,
                                          minHeight: kMinInteractiveDimension,
                                        ),
                                        icon: AppIcon(
                                          AppIcons.driver,
                                          size: context.getRSize(20),
                                          color: primary,
                                        ),
                                        onPressed: () =>
                                            onAssignRider?.call(order.id),
                                      ),
                                      Text(
                                        order.riderName,
                                        style: context
                                            .semiBoldStyle(10)
                                            .copyWith(color: subtextCol),
                                      ),
                                    ],
                                  )
                                else
                                  Padding(
                                    padding: EdgeInsets.only(
                                      right: context.getRSize(4),
                                    ),
                                    child: OrderStatusPill(
                                      status: order.status,
                                    ),
                                  ),
                              ],
                            ),
                          ),

                          Divider(height: 1, color: borderCol),

                          // ── Order number, date/time, creator, payment ─────
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                              context.getRSize(12),
                              context.getRSize(10),
                              context.getRSize(12),
                              0,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Order #${order.orderNumber}',
                                        style: context.monoStyle.copyWith(
                                          color: textCol,
                                        ),
                                      ),
                                      SizedBox(height: context.getRSize(2)),
                                      Text(
                                        '$dateStr · $timeStr',
                                        style: context
                                            .regularStyle(12)
                                            .copyWith(color: subtextCol),
                                      ),
                                      // §19.4: who created the order — shown on
                                      // every tab, for every role.
                                      Row(
                                        children: [
                                          AppIcon(
                                            AppIcons.user,
                                            size: context.getRSize(12),
                                            color: subtextCol,
                                          ),
                                          SizedBox(width: context.getRSize(4)),
                                          Flexible(
                                            child: Text(
                                              'By $creatorName',
                                              style: context
                                                  .regularStyle(12)
                                                  .copyWith(color: subtextCol),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                SizedBox(width: context.getRSize(8)),
                                TagPill(
                                  key: pod == null
                                      ? null
                                      : OrdersKeys.payOnDeliveryPill,
                                  // #432 — short pill; the full "Pay on
                                  // delivery · ₦X to collect" line sits with
                                  // the money below.
                                  label: pod == null
                                      ? _paymentLabel(order.paymentType)
                                      : (pod.isPaid ? 'Paid' : 'Pay on delivery'),
                                  tone: pod == null
                                      ? _paymentTone(order.paymentType)
                                      : (pod.isPaid
                                            ? TagPillTone.green
                                            : TagPillTone.info),
                                ),
                              ],
                            ),
                          ),

                          // ── Items list ───────────────────────────────────
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                              context.getRSize(12),
                              context.getRSize(10),
                              context.getRSize(12),
                              0,
                            ),
                            child: Column(
                              children: [
                                ...displayItems.map((richItem) {
                                  final item = richItem.item;
                                  return Padding(
                                    padding: EdgeInsets.only(
                                      bottom: context.getRSize(4),
                                    ),
                                    child: Row(
                                      children: [
                                        Container(
                                          width: context.getRSize(5),
                                          height: context.getRSize(5),
                                          margin: EdgeInsets.only(
                                            right: context.getRSize(8),
                                          ),
                                          decoration: BoxDecoration(
                                            color: subtextCol,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                        Expanded(
                                          child: Text(
                                            '${item.quantity}× ${richItem.displayName}',
                                            style: context
                                                .mediumStyle(13)
                                                .copyWith(color: textCol),
                                          ),
                                        ),
                                        if (canSeeMoney)
                                          Text(
                                            formatCurrency(
                                              item.totalKobo / 100.0,
                                            ),
                                            style: context
                                                .semiBoldStyle(13)
                                                .copyWith(color: textCol),
                                          ),
                                      ],
                                    ),
                                  );
                                }),
                                if (extraCount > 0)
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Padding(
                                      padding: EdgeInsets.only(
                                        left: context.getRSize(13),
                                        top: context.getRSize(2),
                                      ),
                                      child: Text(
                                        '+$extraCount more item${extraCount > 1 ? 's' : ''}',
                                        style: context
                                            .regularStyle(12)
                                            .copyWith(
                                              color: subtextCol,
                                              fontStyle: FontStyle.italic,
                                            ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),

                          Padding(
                            padding: EdgeInsets.fromLTRB(
                              context.getRSize(12),
                              context.getRSize(10),
                              context.getRSize(12),
                              context.getRSize(12),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (canSeeMoney || showCancelReason) ...[
                                  Divider(height: 1, color: borderCol),
                                  SizedBox(height: context.getRSize(10)),
                                ],

                                // ── Totals (money — hidden below Manager) ──
                                if (canSeeMoney)
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Wrap(
                                              crossAxisAlignment:
                                                  WrapCrossAlignment.center,
                                              children: [
                                                Text(
                                                  'Total  ',
                                                  style: context
                                                      .semiBoldStyle(12)
                                                      .copyWith(
                                                        color: subtextCol,
                                                      ),
                                                ),
                                                Text(
                                                  formatCurrency(
                                                    order.netAmountKobo / 100.0,
                                                  ),
                                                  style: context
                                                      .extraBoldStyle(16)
                                                      .copyWith(color: primary),
                                                ),
                                              ],
                                            ),
                                            SizedBox(
                                              height: context.getRSize(2),
                                            ),
                                            Text(
                                              // #432 — never "credit".
                                              pod != null
                                                  ? pod.label
                                                  : 'Paid: ${formatCurrency(order.amountPaidKobo / 100.0)}',
                                              key: pod == null
                                                  ? null
                                                  : OrdersKeys
                                                        .payOnDeliveryLabel,
                                              style: context
                                                  .regularStyle(12)
                                                  .copyWith(color: subtextCol),
                                            ),
                                          ],
                                        ),
                                      ),
                                      // Debt badge (named customers, balance < 0)
                                      if (showCreditDebt)
                                        TagPill(
                                          label:
                                              'Debt: ${formatCurrency(creditBalanceKobo.abs() / 100.0)}',
                                          tone: TagPillTone.danger,
                                          icon: AppIcons.creditBalance,
                                        ),
                                    ],
                                  ),

                                // ── Discount (money — hidden below Manager) ─
                                if (canSeeMoney && hasDiscount) ...[
                                  SizedBox(height: context.getRSize(6)),
                                  Row(
                                    children: [
                                      AppIcon(
                                        AppIcons.tag,
                                        size: context.getRSize(14),
                                        color: f.green,
                                      ),
                                      SizedBox(width: context.getRSize(5)),
                                      Text(
                                        'Discount: -${formatCurrency(order.discountKobo / 100.0)}',
                                        style: context
                                            .semiBoldStyle(12)
                                            .copyWith(color: f.green),
                                      ),
                                    ],
                                  ),
                                ],

                                // §19.2: no per-order "Owes" badge — settled at
                                // checkout; customer debt shows via the wallet
                                // badge above (rule #4), only when balance < 0.

                                // ── Cancellation reason ───────────────────
                                if (showCancelReason) ...[
                                  if (canSeeMoney)
                                    SizedBox(height: context.getRSize(6)),
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      AppIcon(
                                        AppIcons.infoCircle,
                                        size: context.getRSize(14),
                                        color: subtextCol,
                                      ),
                                      SizedBox(width: context.getRSize(5)),
                                      Expanded(
                                        child: Text(
                                          order.cancellationReason!,
                                          style: context
                                              .regularStyle(12)
                                              .copyWith(
                                                color: subtextCol,
                                                fontStyle: FontStyle.italic,
                                              ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),

                          // ── Mark as paid (#432) ───────────────────────────
                          if (canMarkPaid)
                            Container(
                              padding: EdgeInsets.fromLTRB(
                                context.getRSize(12),
                                context.getRSize(10),
                                context.getRSize(12),
                                context.getRSize(
                                  (status == 'pending' ||
                                              status == 'completed') &&
                                          (onRefund != null ||
                                              onMarkAsDelivered != null)
                                      ? 0
                                      : 12,
                                ),
                              ),
                              decoration: BoxDecoration(
                                border: Border(
                                  top: BorderSide(color: borderCol),
                                ),
                              ),
                              child: AppButton(
                                key: MarkPaidKeys.button,
                                text: 'Mark as paid',
                                icon: AppIcons.cash,
                                variant: AppButtonVariant.secondary,
                                height: kMinInteractiveDimension,
                                onPressed: () =>
                                    markPayOnDeliveryPaid(context, ref, pod),
                              ),
                            ),

                          // ── Footer actions (pending; completed = Return) ──
                          if ((status == 'pending' || status == 'completed') &&
                              (onRefund != null || onMarkAsDelivered != null))
                            Container(
                              padding: EdgeInsets.fromLTRB(
                                context.getRSize(12),
                                context.getRSize(10),
                                context.getRSize(12),
                                context.getRSize(12),
                              ),
                              decoration: BoxDecoration(
                                border: Border(
                                  top: BorderSide(color: borderCol),
                                ),
                              ),
                              child: Row(
                                children: [
                                  // §19.7: Refund (CEO + Manager only — null
                                  // hides it). Replaces the former Cancel button.
                                  if (onRefund != null) ...[
                                    Expanded(
                                      child: AppButton(
                                        key: OrdersKeys.refund,
                                        text: 'Refund',
                                        icon: AppIcons.refresh,
                                        variant: AppButtonVariant.danger,
                                        height: kMinInteractiveDimension,
                                        onPressed: onRefund,
                                      ),
                                    ),
                                    SizedBox(width: context.getRSize(12)),
                                  ],
                                  if (onMarkAsDelivered != null)
                                    Expanded(
                                      child: AppButton(
                                        key: OrdersKeys.confirm,
                                        text: 'Confirm',
                                        icon: AppIcons.vanDelivery,
                                        height: kMinInteractiveDimension,
                                        onPressed: onMarkAsDelivered,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
