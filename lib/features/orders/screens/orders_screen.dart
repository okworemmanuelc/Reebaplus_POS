import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:screenshot/screenshot.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import 'package:reebaplus_pos/core/theme/colors.dart';

import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/core/utils/store_address.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/receipt_widget.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/features/deliveries/data/models/delivery_receipt.dart'
    as model;
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_card.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_bar_header.dart';
import 'package:reebaplus_pos/shared/widgets/notification_bell.dart';

import 'package:reebaplus_pos/features/pos/services/receipt_builder.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/orders/widgets/crate_return_modal.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/customers/screens/customer_detail_screen.dart';
import 'package:reebaplus_pos/shared/widgets/slide_route.dart';
import 'package:reebaplus_pos/shared/widgets/printer_picker.dart';

class OrdersScreen extends ConsumerStatefulWidget {
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
      final initialRange = tab == 'completed' ? _completedCustomRange : _cancelledCustomRange;
      final range = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2020),
        lastDate: DateTime.now().add(const Duration(days: 365)),
        initialDateRange: initialRange,
        builder: (context, child) => Theme(
          data: Theme.of(context),
          child: child!,
        ),
      );
      if (range != null) {
        setState(() {
          final rangeStr = 'Custom:${range.start.toIso8601String()}:${range.end.toIso8601String()}';
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
  Color get borderCol => Theme.of(context).colorScheme.primary.withValues(alpha: 0.05);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialIndex,
    );
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
    return SharedScaffold(
      activeRoute: 'orders',
      backgroundColor: _bg,
      appBar: _buildAppBar(context),
      body: Builder(
        builder: (context) {
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
            child: NestedScrollView(
              headerSliverBuilder: (context, innerBoxIsScrolled) => [
                SliverToBoxAdapter(child: _buildTabBar(context)),
              ],
              body: TabBarView(
                controller: _tabController,
                children: [
                  _buildPendingTab(context, activeStoreId),
                  _buildCompletedTab(context, activeStoreId),
                  _buildCancelledTab(context, activeStoreId),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ─────────────────────────── APP BAR ────────────────────────────────────

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      backgroundColor: surfaceCol,
      elevation: 0,
      iconTheme: IconThemeData(color: textCol),
      leading: const MenuButton(),
      title: AppBarHeader(
        icon: FontAwesomeIcons.receipt.data,
        title: 'Orders',
        subtitle: ref.watch(activeStoreLabelProvider),
      ),
      centerTitle: true,
      actions: const [NotificationBell(), SizedBox(width: 8)],
    );
  }

  Widget _buildTabBar(BuildContext context) {
    return Material(
      color: surfaceCol,
      child: TabBar(
        controller: _tabController,
        dividerColor: Colors.transparent,
        labelColor: Theme.of(context).colorScheme.primary,
        unselectedLabelColor: subtextCol,
        indicatorColor: Theme.of(context).colorScheme.primary,
        indicatorWeight: 3,
        labelStyle: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: context.getRFontSize(14),
        ),
        tabs: [
          Tab(
            icon: Icon(FontAwesomeIcons.boxOpen.data, size: 16),
            text: 'Pending',
          ),
          Tab(
            icon: Icon(FontAwesomeIcons.clipboardCheck.data, size: 16),
            text: 'Completed',
          ),
          Tab(
            icon: Icon(FontAwesomeIcons.ban.data, size: 16),
            text: 'Cancelled',
          ),
        ],
      ),
    );
  }

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
    return Container(
      color: surfaceCol,
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(10),
        context.getRSize(16),
        context.getRSize(10),
      ),
      child: Row(
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
    );
  }

  Widget _buildSearchField(BuildContext context) {
    return TextField(
      controller: _searchController,
      onChanged: _onSearchChanged,
      style: TextStyle(color: textCol, fontSize: context.getRFontSize(14)),
      decoration: InputDecoration(
        hintText: 'Search by customer or order #',
        hintStyle: TextStyle(
          color: subtextCol,
          fontSize: context.getRFontSize(13),
        ),
        prefixIcon: Icon(
          FontAwesomeIcons.magnifyingGlass.data,
          size: context.getRSize(15),
          color: subtextCol,
        ),
        suffixIcon: _searchQuery.isNotEmpty
            ? GestureDetector(
                onTap: () {
                  _searchController.clear();
                  setState(() => _searchQuery = '');
                },
                child: Icon(
                  FontAwesomeIcons.xmark.data,
                  size: context.getRSize(14),
                  color: subtextCol,
                ),
              )
            : null,
        filled: true,
        fillColor: _bg,
        contentPadding: EdgeInsets.symmetric(
          horizontal: context.getRSize(16),
          vertical: context.getRSize(10),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: borderCol),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: borderCol),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: Theme.of(context).colorScheme.primary,
            width: 1.5,
          ),
        ),
      ),
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
    final selectedVal = options.contains(dropdownValue) ? dropdownValue : options.first;

    return SizedBox(
      width: context.getRSize(140),
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
          FontAwesomeIcons.calendarDay.data,
          size: context.getRSize(13),
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

  Widget _buildPendingTab(BuildContext context, String? activeStoreId) {
    final pendingAsync = ref.watch(pendingOrdersProvider(activeStoreId));

    return pendingAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (allPending) {
        final list = _applySearch(allPending);
        final managerUp = isManagerOrAbove(ref);

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
          if (managerUp)
            _StatItem(
              label: 'Total Value',
              value: formatCurrency(totalValue / 100.0),
              color: Theme.of(context).colorScheme.primary,
            ),
          _StatItem(label: 'Pick-up', value: '$unassigned', color: subtextCol),
        ];

        final searchBarHeight = context.getRSize(64.0);
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _SummaryStrip(stats: stats)),
            SliverPersistentHeader(
              pinned: true,
              delegate: _PinnedHeaderDelegate(
                height: searchBarHeight,
                child: _buildSearchBar(context),
              ),
            ),
            ..._buildOrderSlivers(context, list, status: 'pending'),
          ],
        );
      },
    );
  }

  Widget _buildCompletedTab(BuildContext context, String? activeStoreId) {
    final managerUp = isManagerOrAbove(ref);
    final key = (
      status: 'completed',
      storeId: activeStoreId,
      dateLabel: _completedFilter,
      search: _searchQuery,
    );

    final statsAsync = ref.watch(ordersStatsProvider(key));
    final stateAsync = ref.watch(paginatedOrdersProvider(key));

    return statsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (stats) {
        final statItems = [
          _StatItem(label: 'Completed', value: '${stats.count}', color: success),
          if (managerUp) ...[
            _StatItem(
              label: 'Revenue',
              value: formatCurrency(stats.totalAmountKobo / 100.0),
              color: Theme.of(context).colorScheme.primary,
            ),
            _StatItem(
              label: 'Collected',
              value: formatCurrency(stats.amountPaidKobo / 100.0),
              color: success,
            ),
            _StatItem(
              label: 'Crate Deposits',
              value: formatCurrency(stats.crateDepositPaidKobo / 100.0),
              color: subtextCol,
            ),
          ],
        ];

        if (stateAsync.isLoading) {
          return const Center(child: CircularProgressIndicator());
        }

        final searchBarHeight = context.getRSize(64.0);
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _SummaryStrip(stats: statItems)),
            SliverPersistentHeader(
              pinned: true,
              delegate: _PinnedHeaderDelegate(
                height: searchBarHeight,
                child: _buildSearchBar(
                  context,
                  selectedFilter: _completedFilter,
                  onSelectFilter: (f) => _changeFilter('completed', f),
                  filterOptions: _periodOptions(managerUp),
                ),
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
          ],
        );
      },
    );
  }

  Widget _buildCancelledTab(BuildContext context, String? activeStoreId) {
    final managerUp = isManagerOrAbove(ref);
    final key = (
      status: 'cancelled',
      storeId: activeStoreId,
      dateLabel: _cancelledFilter,
      search: _searchQuery,
    );

    final statsAsync = ref.watch(ordersStatsProvider(key));
    final stateAsync = ref.watch(paginatedOrdersProvider(key));

    return statsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (stats) {
        final statItems = [
          _StatItem(label: 'Cancelled', value: '${stats.count}', color: danger),
          if (managerUp)
            _StatItem(
              label: 'Value Forfeited',
              value: formatCurrency(stats.totalAmountKobo / 100.0),
              color: danger,
            ),
          _StatItem(
            label: 'Refunds Issued',
            value: '${stats.refundedCount}',
            color: blueMain,
          ),
        ];

        if (stateAsync.isLoading) {
          return const Center(child: CircularProgressIndicator());
        }

        final searchBarHeight = context.getRSize(64.0);
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _SummaryStrip(stats: statItems)),
            SliverPersistentHeader(
              pinned: true,
              delegate: _PinnedHeaderDelegate(
                height: searchBarHeight,
                child: _buildSearchBar(
                  context,
                  selectedFilter: _cancelledFilter,
                  onSelectFilter: (f) => _changeFilter('cancelled', f),
                  filterOptions: _periodOptions(managerUp),
                ),
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
          ],
        );
      },
    );
  }

  List<Widget> _buildPaginatedOrderSlivers(
    BuildContext context,
    List<OrderWithItems> list, {
    required String status,
    required bool isLoadingMore,
    required bool hasMore,
    required ({String status, String? storeId, String dateLabel, String search}) key,
  }) {
    if (list.isEmpty) {
      IconData icon;
      String text;
      if (status == 'completed') {
        icon = FontAwesomeIcons.clipboardCheck.data;
        text = _searchQuery.isNotEmpty
            ? 'No completed orders match "$_searchQuery"'
            : 'No completed orders';
      } else {
        icon = FontAwesomeIcons.ban.data;
        text = _searchQuery.isNotEmpty
            ? 'No cancelled orders match "$_searchQuery"'
            : 'No cancelled orders';
      }

      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: context.getRSize(48), color: borderCol),
                SizedBox(height: context.getRSize(16)),
                Text(
                  text,
                  style: TextStyle(
                    color: subtextCol,
                    fontSize: context.getRFontSize(16),
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ];
    }

    final canRefund = hasPermission(ref, 'sales.cancel');

    // We add 1 to the child count if we are loading more to render the spinner.
    final childCount = list.length + (isLoadingMore ? 1 : 0);

    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(
          context.getRSize(16),
          context.getRSize(16),
          context.getRSize(16),
          context.getRSize(100) + context.bottomInset,
        ),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            // Trigger load more near the bottom
            if (hasMore && !isLoadingMore && index >= list.length - 5) {
              Future.microtask(() {
                if (mounted) {
                  ref.read(paginatedOrdersProvider(key).notifier).loadMore();
                }
              });
            }

            if (index == list.length) {
              return Padding(
                padding: EdgeInsets.symmetric(vertical: context.getRSize(16)),
                child: const Center(
                  child: CircularProgressIndicator(),
                ),
              );
            }

            final item = list[index];
            return _OrderCard(
              orderWithItems: item,
              status: status,
              onMarkAsDelivered: status == 'pending'
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
        icon = FontAwesomeIcons.boxOpen.data;
        text = _searchQuery.isNotEmpty
            ? 'No pending orders match "$_searchQuery"'
            : 'No pending orders';
      } else if (status == 'completed') {
        icon = FontAwesomeIcons.clipboardCheck.data;
        text = _searchQuery.isNotEmpty
            ? 'No completed orders match "$_searchQuery"'
            : 'No completed orders';
      } else {
        icon = FontAwesomeIcons.ban.data;
        text = _searchQuery.isNotEmpty
            ? 'No cancelled orders match "$_searchQuery"'
            : 'No cancelled orders';
      }

      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: context.getRSize(48), color: borderCol),
                SizedBox(height: context.getRSize(16)),
                Text(
                  text,
                  style: TextStyle(
                    color: subtextCol,
                    fontSize: context.getRFontSize(16),
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ];
    }

    // §19.7: the Pending-tab Refund is gated to CEO + Manager (sales.cancel).
    final canRefund = hasPermission(ref, 'sales.cancel');

    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(
          context.getRSize(16),
          context.getRSize(16),
          context.getRSize(16),
          context.getRSize(100) + context.bottomInset,
        ),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            final item = list[index];
            return _OrderCard(
              orderWithItems: item,
              status: status,
              onMarkAsDelivered: status == 'pending'
                  ? () => _markAsDelivered(item)
                  : null,
              // §19.7: Refund replaces the old Cancel button on the Pending
              // tab and is hidden unless the user may cancel a sale. It
              // reverses the sale (stock, payment, both wallet legs) and moves
              // the order to Cancelled. The Completed and Cancelled tabs have
              // no Refund button (§19.8).
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
      ),
    ];
  }

  // ─────────────────────── ACTION HANDLERS (unchanged) ────────────────────

  void _markAsDelivered(OrderWithItems orderWithItems) {
    _executeMarkDelivered(orderWithItems);
  }

  void _executeMarkDelivered(OrderWithItems orderWithItems) async {
    final order = orderWithItems.order;

    if (mounted) {
      final confirmed = await CrateReturnModal.show(
        context,
        orderWithItems,
        ref: ref,
      );
      if (!confirmed) return;
    }

    if (!mounted) return;

    try {
      await ref
          .read(orderServiceProvider)
          .markAsCompleted(
            order.id,
            ref.read(authProvider).currentUser?.id ?? '',
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
              backgroundColor: surfaceCol,
              title: Text(
                'Refund ${order.orderNumber}',
                style: TextStyle(color: textCol, fontWeight: FontWeight.bold),
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
                    style: TextStyle(color: subtextCol, fontSize: 13),
                  ),
                  SizedBox(height: context.getRSize(16)),
                  TextField(
                    controller: reasonController,
                    autofocus: true,
                    minLines: 1,
                    maxLines: 3,
                    style: TextStyle(color: textCol),
                    onChanged: (_) => setDialogState(() {}),
                    decoration: InputDecoration(
                      labelText: 'Reason (required)',
                      labelStyle: TextStyle(color: subtextCol),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: borderCol),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(
                          color: Theme.of(ctx).colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                AppButton(
                  text: 'Back',
                  variant: AppButtonVariant.ghost,
                  size: AppButtonSize.small,
                  onPressed: () => Navigator.pop(ctx),
                ),
                AppButton(
                  text: 'Issue Refund',
                  icon: FontAwesomeIcons.rotateLeft.data,
                  variant: AppButtonVariant.danger,
                  size: AppButtonSize.small,
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
    final staffId = ref.read(authProvider).currentUser?.id ?? '';
    try {
      await ref
          .read(orderServiceProvider)
          .markAsCancelled(order.id, reason, staffId);
      if (mounted) {
        AppNotification.showSuccess(
          context,
          'Refund issued for ${order.orderNumber}.',
        );
      }
    } catch (e) {
      if (mounted) {
        AppNotification.showError(context, 'Could not issue refund: $e');
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
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              height: MediaQuery.of(context).size.height * 0.85,
              decoration: BoxDecoration(
                color: surfaceCol,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(20),
                ),
              ),
              child: Column(
                children: [
                  Container(
                    margin: EdgeInsets.symmetric(
                      vertical: context.getRSize(12),
                    ),
                    width: context.getRSize(40),
                    height: context.getRSize(5),
                    decoration: BoxDecoration(
                      color: borderCol,
                      borderRadius: BorderRadius.circular(10),
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
                        child: ReceiptWidget(
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
                                  'manufacturerId': ri.product?.manufacturerId,
                                },
                              )
                              .toList(),
                          subtotal: currentOrder.totalAmountKobo / 100.0,
                          crateDeposit: 0,
                          total: currentOrder.netAmountKobo / 100.0,
                          manufacturerNames: manufacturerNames,
                          paymentMethod: currentOrder.paymentType,
                          customerName:
                              richOrder.customer?.name ?? 'Walk-in Customer',
                          customerAddress:
                              richOrder.customer?.addressText ?? 'N/A',
                          cashReceived:
                              currentOrder.paymentType == 'Wallet Payment'
                              ? currentOrder.netAmountKobo / 100.0
                              : currentOrder.amountPaidKobo / 100.0,
                          reprintDate: reprintDate,
                          reshareDate: reshareDate,
                          riderName: currentOrder.riderName,
                          deliveryRef: null,
                          orderStatus: currentOrder.status,
                          refundAmount: currentOrder.amountPaidKobo / 100.0,
                          storeAddress: storeAddress,
                          businessName: ref.read(currentBusinessNameProvider),
                          logoPath: ref
                              .read(currentBusinessLogoPathProvider)
                              .valueOrNull,
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
                            icon: FontAwesomeIcons.print.data,
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
                            icon: FontAwesomeIcons.shareNodes.data,
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

    final deliveryReceipt = ref
        .read(deliveryReceiptServiceProvider)
        .getByOrderId(order.id.toString());

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

      final bytes = await ThermalReceiptService.buildReceipt(
        orderId: order.orderNumber,
        cart: receiptMapping,
        subtotal: order.totalAmountKobo / 100.0,
        crateDeposit: 0,
        total: order.netAmountKobo / 100.0,
        paymentMethod: order.paymentType,
        customerName: richOrder.customer?.name ?? 'Walk-in Customer',
        customerAddress: richOrder.customer?.addressText ?? 'N/A',
        cashReceived: order.paymentType == 'Wallet Payment'
            ? order.netAmountKobo / 100.0
            : order.amountPaidKobo / 100.0,
        walletBalance: walletBalance,
        reprintDate: DateTime.now(),
        riderName: order.riderName,
        deliveryRef: deliveryReceipt?.referenceNumber,
        orderStatus: order.status,
        refundAmount: order.amountPaidKobo / 100.0,
        storeAddress: finalStoreAddress,
        businessName: ref.read(currentBusinessNameProvider),
        manufacturerNames: manufacturerNames,
      );

      if (!context.mounted) return;

      // Auto-print: reuse the live connection, otherwise auto-connect to the
      // last-used / paired printer — printBytes() handles both. Only when that
      // fails do we fall through to the picker below.
      final printed = await printer.printBytes(bytes);
      if (!context.mounted) return;
      if (printed) {
        AppNotification.showSuccess(context, 'Print successful');
        _logReprint(order.id.toString());
        return;
      }

      if (context.mounted) {
        final selectedDevice = await showModalBottomSheet<BluetoothInfo>(
          context: context,
          isScrollControlled: true,
          backgroundColor: surfaceCol,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.5,
          ),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
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
            await printer.saveLastConnectedMac(selectedDevice.macAdress);
            final printOk = await printer.printBytesDirectly(bytes);
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

class _SummaryStrip extends StatelessWidget {
  final List<_StatItem> stats;
  const _SummaryStrip({required this.stats});

  @override
  Widget build(BuildContext context) {
    final surfaceCol = Theme.of(context).colorScheme.surface;
    final borderCol = Theme.of(context).dividerColor;
    final subtextCol =
        Theme.of(context).textTheme.bodySmall?.color ??
        Theme.of(context).iconTheme.color!;

    return Container(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(12),
        context.getRSize(16),
        context.getRSize(12),
      ),
      decoration: BoxDecoration(
        color: surfaceCol,
        border: Border(bottom: BorderSide(color: borderCol)),
      ),
      child: Row(
        children: stats.map((stat) {
          final isLast = stat == stats.last;
          return Expanded(
            child: Container(
              margin: isLast
                  ? EdgeInsets.zero
                  : EdgeInsets.only(right: context.getRSize(1)),
              padding: EdgeInsets.symmetric(
                vertical: context.getRSize(8),
                horizontal: context.getRSize(4),
              ),
              decoration: isLast
                  ? null
                  : BoxDecoration(
                      border: Border(right: BorderSide(color: borderCol)),
                    ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    stat.value,
                    style: TextStyle(
                      color:
                          stat.color ?? Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.bold,
                      fontSize: context.getRFontSize(13),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: context.getRSize(2)),
                  Text(
                    stat.label,
                    style: TextStyle(
                      color: subtextCol,
                      fontSize: context.getRFontSize(10),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ═══════════════════════════ ORDER CARD ═════════════════════════════════════

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

  // Returns a color for the payment type badge
  Color _paymentColor(String paymentType, Color primaryColor) {
    final lower = paymentType.toLowerCase();
    // Mixed cash + wallet (e.g. 'Cash / Transfer / Wallet') is a partial
    // payment — cash now, the shortfall booked to the wallet as debt. Match it
    // before the plain 'wallet' check, which would otherwise claim it.
    if (lower.contains('wallet') && lower.contains('cash')) return primaryColor;
    if (lower.contains('wallet')) return blueMain;
    if (lower.contains('partial')) return primaryColor;
    if (lower.contains('credit')) return danger;
    return success; // Full Cash / Card
  }

  // Returns a short label for the payment type badge
  String _paymentLabel(String paymentType) {
    final lower = paymentType.toLowerCase();
    // Mixed cash + wallet (e.g. 'Cash / Transfer / Wallet') → Partial. Checked
    // before plain 'wallet' so the combined label isn't badged as a pure wallet
    // payment.
    if (lower.contains('wallet') && lower.contains('cash')) return 'Partial';
    if (lower.contains('wallet')) return 'Credit Payment';
    if (lower.contains('partial')) return 'Partial';
    if (lower.contains('credit')) return 'Credit';
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
    final textCol = Theme.of(context).colorScheme.onSurface;
    final subtextCol =
        Theme.of(context).textTheme.bodySmall?.color ??
        Theme.of(context).iconTheme.color!;
    final borderCol = Theme.of(context).dividerColor;
    final surfaceCol = Theme.of(context).colorScheme.surface;
    final primary = Theme.of(context).colorScheme.primary;

    final order = orderWithItems.order;
    final customer = orderWithItems.customer;
    final items = orderWithItems.items;

    // §19.3: roles below Manager see items + quantities only — no monetary
    // values (line prices, total, paid, discount, wallet-debt) anywhere on the
    // card. The printed receipt (onViewReceipt) is unchanged.
    final canSeeMoney = isManagerOrAbove(ref);
    // The footer block (divider + money rows) is replaced by just the
    // cancellation reason when money is hidden — so a low role still sees why a
    // cancelled order was cancelled, with no money.
    final showCancelReason =
        status == 'cancelled' &&
        order.cancellationReason != null &&
        order.cancellationReason!.isNotEmpty;

    // Accent color for the left border stripe
    final Color accentColor;
    if (status == 'pending') {
      accentColor = primary;
    } else if (status == 'completed') {
      accentColor = success;
    } else {
      accentColor = danger;
    }

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

    return GlassyCard(
      margin: EdgeInsets.only(bottom: context.getRSize(16)),
      padding: EdgeInsets.zero,
      radius: 16.0,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onViewReceipt,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Left accent stripe
                Container(
                  width: 4, 
                  decoration: BoxDecoration(
                    color: accentColor,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(16),
                      bottomLeft: Radius.circular(16),
                    ),
                  ),
                ),

                // Card content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                        // ── Header: Customer + badges ──────────────────────
                        Padding(
                          padding: EdgeInsets.all(context.getRSize(14)),
                          child: Row(
                            children: [
                              // Customer profile (avatar + name/address). For a
                              // named customer this taps through to their detail
                              // screen; a null onTap (walk-in) lets the tap fall
                              // through to the card's onViewReceipt.
                              Expanded(
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(10),
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
                                  child: Row(
                                    children: [
                                      // Avatar
                                      Container(
                                        padding: EdgeInsets.all(
                                          context.getRSize(9),
                                        ),
                                        decoration: BoxDecoration(
                                          color: primary.withValues(alpha: 0.1),
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                        child: Icon(
                                          FontAwesomeIcons.user.data,
                                          size: context.getRSize(15),
                                          color: primary,
                                        ),
                                      ),
                                      SizedBox(width: context.getRSize(10)),

                                      // Name + address
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              customer?.name ??
                                                  'Walk-in Customer',
                                              style: TextStyle(
                                                color: textCol,
                                                fontWeight: FontWeight.bold,
                                                fontSize: context.getRFontSize(
                                                  14,
                                                ),
                                              ),
                                            ),
                                            if (customer?.addressText != null &&
                                                customer!.addressText != 'N/A')
                                              Text(
                                                customer.addressText,
                                                style: TextStyle(
                                                  color: subtextCol,
                                                  fontSize: context.getRFontSize(
                                                    12,
                                                  ),
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              SizedBox(width: context.getRSize(8)),

                              // Right side: rider (pending) or status badge (others)
                              if (status == 'pending')
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    IconButton(
                                      icon: Icon(
                                        FontAwesomeIcons.motorcycle.data,
                                        size: context.getRSize(18),
                                        color: primary,
                                      ),
                                      onPressed: () =>
                                          onAssignRider?.call(order.id),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                    SizedBox(height: context.getRSize(2)),
                                    Text(
                                      order.riderName,
                                      style: TextStyle(
                                        fontSize: context.getRFontSize(9),
                                        color: subtextCol,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                )
                              else
                                _StatusBadge(status: order.status),
                            ],
                          ),
                        ),

                        Divider(height: 1, color: borderCol),

                        // ── Order ID, date/time, and payment badge ─────────
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            context.getRSize(14),
                            context.getRSize(10),
                            context.getRSize(14),
                            0,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Order #${order.orderNumber}',
                                      style: TextStyle(
                                        color: subtextCol,
                                        fontWeight: FontWeight.w600,
                                        fontSize: context.getRFontSize(12),
                                      ),
                                    ),
                                    Text(
                                      '$dateStr · $timeStr',
                                      style: TextStyle(
                                        color: subtextCol,
                                        fontSize: context.getRFontSize(11),
                                      ),
                                    ),
                                    // §19.4: who created the order — shown on
                                    // every tab, for every role.
                                    Row(
                                      children: [
                                        Icon(
                                          FontAwesomeIcons.user.data,
                                          size: context.getRSize(9),
                                          color: subtextCol,
                                        ),
                                        SizedBox(width: context.getRSize(4)),
                                        Flexible(
                                          child: Text(
                                            'By $creatorName',
                                            style: TextStyle(
                                              color: subtextCol,
                                              fontSize: context.getRFontSize(
                                                11,
                                              ),
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              // Payment type badge
                              _PaymentBadge(
                                label: _paymentLabel(order.paymentType),
                                color: _paymentColor(
                                  order.paymentType,
                                  primary,
                                ),
                              ),
                            ],
                          ),
                        ),

                        // ── Items list ─────────────────────────────────────
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            context.getRSize(14),
                            context.getRSize(10),
                            context.getRSize(14),
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
                                        width: context.getRSize(4),
                                        height: context.getRSize(4),
                                        margin: EdgeInsets.only(
                                          right: context.getRSize(8),
                                          top: context.getRSize(1),
                                        ),
                                        decoration: BoxDecoration(
                                          color: subtextCol.withValues(
                                            alpha: 0.5,
                                          ),
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      Expanded(
                                        child: Text(
                                          '${item.quantity}× ${richItem.displayName}',
                                          style: TextStyle(
                                            color: textCol,
                                            fontSize: context.getRFontSize(13),
                                          ),
                                        ),
                                      ),
                                      if (canSeeMoney)
                                        Text(
                                          formatCurrency(
                                            item.totalKobo / 100.0,
                                          ),
                                          style: TextStyle(
                                            color: textCol,
                                            fontWeight: FontWeight.w600,
                                            fontSize: context.getRFontSize(13),
                                          ),
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
                                      left: context.getRSize(12),
                                      top: context.getRSize(2),
                                    ),
                                    child: Text(
                                      '+$extraCount more item${extraCount > 1 ? 's' : ''}',
                                      style: TextStyle(
                                        color: subtextCol,
                                        fontSize: context.getRFontSize(12),
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
                            context.getRSize(14),
                            context.getRSize(10),
                            context.getRSize(14),
                            context.getRSize(14),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (canSeeMoney || showCancelReason) ...[
                                Divider(height: 1, color: borderCol),
                                SizedBox(height: context.getRSize(10)),
                              ],

                              // ── Totals row (money — hidden below Manager) ──
                              if (canSeeMoney)
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Text(
                                              'Total  ',
                                              style: TextStyle(
                                                color: subtextCol,
                                                fontSize: context.getRFontSize(
                                                  12,
                                                ),
                                              ),
                                            ),
                                            Text(
                                              formatCurrency(
                                                order.netAmountKobo / 100.0,
                                              ),
                                              style: TextStyle(
                                                color: primary,
                                                fontWeight: FontWeight.bold,
                                                fontSize: context.getRFontSize(
                                                  15,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        SizedBox(height: context.getRSize(2)),
                                        Text(
                                          'Paid: ${formatCurrency(order.amountPaidKobo / 100.0)}',
                                          style: TextStyle(
                                            color: subtextCol,
                                            fontSize: context.getRFontSize(12),
                                          ),
                                        ),
                                      ],
                                    ),
                                    // Debt badge (named customers, negative balance)
                                    if (showCreditDebt)
                                      _CreditDebtBadge(
                                        balanceKobo: creditBalanceKobo,
                                      ),
                                  ],
                                ),

                              // ── Discount row (money — hidden below Manager) ─
                              if (canSeeMoney && hasDiscount) ...[
                                SizedBox(height: context.getRSize(6)),
                                Row(
                                  children: [
                                    Icon(
                                      FontAwesomeIcons.tag.data,
                                      size: context.getRSize(11),
                                      color: success,
                                    ),
                                    SizedBox(width: context.getRSize(5)),
                                    Text(
                                      'Discount: -${formatCurrency(order.discountKobo / 100.0)}',
                                      style: TextStyle(
                                        color: success,
                                        fontSize: context.getRFontSize(12),
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ],

                              // §19.2: no per-order "Owes" badge — settled at
                              // checkout; customer debt shows via the wallet
                              // badge above (rule #4), only when balance < 0.

                              // ── Cancellation reason ────────────────────
                              if (showCancelReason) ...[
                                if (canSeeMoney)
                                  SizedBox(height: context.getRSize(6)),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(
                                      FontAwesomeIcons.circleInfo.data,
                                      size: context.getRSize(11),
                                      color: subtextCol,
                                    ),
                                    SizedBox(width: context.getRSize(5)),
                                    Expanded(
                                      child: Text(
                                        order.cancellationReason!,
                                        style: TextStyle(
                                          color: subtextCol,
                                          fontSize: context.getRFontSize(12),
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

                        // ── Footer actions (pending only) ──────────────────
                        if (status == 'pending')
                          Container(
                            padding: EdgeInsets.fromLTRB(
                              context.getRSize(14),
                              context.getRSize(12),
                              context.getRSize(14),
                              context.getRSize(14),
                            ),
                            decoration: BoxDecoration(
                              color: surfaceCol,
                              border: Border(top: BorderSide(color: borderCol)),
                            ),
                            child: Row(
                              children: [
                                // §19.7: Refund (CEO + Manager only — null hides
                                // it). Replaces the former Cancel button.
                                if (onRefund != null) ...[
                                  Expanded(
                                    child: AppButton(
                                      text: 'Refund',
                                      icon: FontAwesomeIcons.rotateLeft.data,
                                      variant: AppButtonVariant.danger,
                                      size: AppButtonSize.xsmall,
                                      onPressed: onRefund,
                                    ),
                                  ),
                                  SizedBox(width: context.getRSize(12)),
                                ],
                                if (onMarkAsDelivered != null)
                                  Expanded(
                                    child: AppButton(
                                      text: 'Confirm',
                                      icon: FontAwesomeIcons.truckFast.data,
                                      size: AppButtonSize.xsmall,
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
      );
    }
}

// ═══════════════════════════ HELPER WIDGETS ══════════════════════════════════

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final Color color;
    final IconData icon;
    final String label;

    switch (status) {
      case 'completed':
        color = success;
        icon = FontAwesomeIcons.check.data;
        label = 'DONE';
        break;
      case 'refunded':
        color = blueMain;
        icon = FontAwesomeIcons.rotateLeft.data;
        label = 'REFUNDED';
        break;
      default:
        color = danger;
        icon = FontAwesomeIcons.ban.data;
        label = 'CANCELLED';
    }

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(8),
        vertical: context.getRSize(5),
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.1)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: context.getRSize(10), color: color),
          SizedBox(width: context.getRSize(5)),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: context.getRFontSize(10),
            ),
          ),
        ],
      ),
    );
  }
}

class _PaymentBadge extends StatelessWidget {
  final String label;
  final Color color;
  const _PaymentBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(8),
        vertical: context.getRSize(4),
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.1)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: context.getRFontSize(10),
        ),
      ),
    );
  }
}

// ═══════════════════════ PINNED HEADER DELEGATE ══════════════════════════════

class _PinnedHeaderDelegate extends SliverPersistentHeaderDelegate {
  final double height;
  final Widget child;

  _PinnedHeaderDelegate({required this.height, required this.child});

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => SizedBox(height: height, child: child);

  @override
  bool shouldRebuild(_PinnedHeaderDelegate oldDelegate) => true;
}

class _CreditDebtBadge extends StatelessWidget {
  final int balanceKobo;
  const _CreditDebtBadge({required this.balanceKobo});

  @override
  Widget build(BuildContext context) {
    // balanceKobo is negative — show the debt amount positively
    final debtAmount = balanceKobo.abs();
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(8),
        vertical: context.getRSize(5),
      ),
      decoration: BoxDecoration(
        color: danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: danger.withValues(alpha: 0.1)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            FontAwesomeIcons.wallet.data,
            size: context.getRSize(10),
            color: danger,
          ),
          SizedBox(width: context.getRSize(4)),
          Text(
            'Debt: ${formatCurrency(debtAmount / 100.0)}',
            style: TextStyle(
              color: danger,
              fontWeight: FontWeight.bold,
              fontSize: context.getRFontSize(10),
            ),
          ),
        ],
      ),
    );
  }
}
