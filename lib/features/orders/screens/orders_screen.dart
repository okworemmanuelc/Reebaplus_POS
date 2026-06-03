import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
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
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/receipt_widget.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/features/deliveries/data/models/delivery_receipt.dart' as model;
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_bar_header.dart';
import 'package:reebaplus_pos/shared/widgets/notification_bell.dart';

import 'package:reebaplus_pos/features/pos/services/receipt_builder.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/orders/widgets/crate_return_modal.dart';
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
  Color get borderCol => Theme.of(context).dividerColor;

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

  /// Resolves a storeId to its branch name.
  Future<String?> _resolveBranchName(String? storeId) async {
    if (storeId == null) return null;
    final db = ref.read(databaseProvider);
    final stores = await db.storesDao.getActiveStores();
    return stores
        .where((w) => w.id == storeId)
        .map((w) => w.name)
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
    ref.watch(currencySymbolProvider); // rebuild money displays when currency changes
    return SharedScaffold(
      activeRoute: 'orders',
      backgroundColor: _bg,
      appBar: _buildAppBar(context),
      body: Builder(
        builder: (context) {
          final ordersAsync = ref.watch(allOrdersProvider);

          return ordersAsync.when(
            loading: () =>
                const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Error: $e')),
            data: (allOrdersWithItems) {
              final now = DateTime.now();

              final pending = _applySearch(
                allOrdersWithItems
                    .where((o) => o.order.status == 'pending')
                    .toList(),
              );

              final separatedCompleted = allOrdersWithItems
                  .where((o) => o.order.status == 'completed')
                  .toList();
              final completed = _applySearch(
                separatedCompleted.where((o) {
                  final t = o.order.completedAt ?? o.order.createdAt;
                  return datePeriodFromLabel(_completedFilter)
                      .includes(t, now: now);
                }).toList(),
              );

              final separatedCancelled = allOrdersWithItems
                  .where((o) => o.order.status == 'cancelled')
                  .toList();
              final cancelled = _applySearch(
                separatedCancelled.where((o) {
                  final t = o.order.cancelledAt ?? o.order.createdAt;
                  return datePeriodFromLabel(_cancelledFilter)
                      .includes(t, now: now);
                }).toList(),
              );

              return AppRefreshWrapper(
                child: NestedScrollView(
                  headerSliverBuilder: (context, innerBoxIsScrolled) => [
                    SliverToBoxAdapter(child: _buildTabBar(context)),
                  ],
                  body: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildPendingTab(context, pending),
                      _buildCompletedTab(context, completed),
                      _buildCancelledTab(context, cancelled),
                    ],
                  ),
                ),
              );
            },
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
      title: const AppBarHeader(
        icon: FontAwesomeIcons.receipt,
        title: 'Orders',
        subtitle: 'Sales History',
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
        labelColor: Theme.of(context).colorScheme.primary,
        unselectedLabelColor: subtextCol,
        indicatorColor: Theme.of(context).colorScheme.primary,
        indicatorWeight: 3,
        labelStyle: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: context.getRFontSize(14),
        ),
        tabs: const [
          Tab(icon: Icon(FontAwesomeIcons.boxOpen, size: 16), text: 'Pending'),
          Tab(
            icon: Icon(FontAwesomeIcons.clipboardCheck, size: 16),
            text: 'Completed',
          ),
          Tab(icon: Icon(FontAwesomeIcons.ban, size: 16), text: 'Cancelled'),
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
    final showFilter = selectedFilter != null &&
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
        style: TextStyle(
          color: textCol,
          fontSize: context.getRFontSize(14),
        ),
        decoration: InputDecoration(
          hintText: 'Search by customer or order #',
          hintStyle: TextStyle(
            color: subtextCol,
            fontSize: context.getRFontSize(13),
          ),
          prefixIcon: Icon(
            FontAwesomeIcons.magnifyingGlass,
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
                    FontAwesomeIcons.xmark,
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
    return PopupMenuButton<String>(
      onSelected: onSelect,
      color: surfaceCol,
      elevation: 3,
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: borderCol),
      ),
      itemBuilder: (ctx) => [
        for (final o in options)
          PopupMenuItem<String>(
            value: o,
            child: Row(
              children: [
                Icon(
                  FontAwesomeIcons.check,
                  size: context.getRSize(11),
                  color: o == selected
                      ? Theme.of(context).colorScheme.primary
                      : Colors.transparent,
                ),
                SizedBox(width: context.getRSize(8)),
                Text(
                  o,
                  style: TextStyle(
                    color: textCol,
                    fontSize: context.getRFontSize(13),
                    fontWeight:
                        o == selected ? FontWeight.w700 : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
      ],
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.getRSize(14),
          vertical: context.getRSize(12),
        ),
        decoration: BoxDecoration(
          color: _bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderCol),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              FontAwesomeIcons.calendarDay,
              size: context.getRSize(13),
              color: subtextCol,
            ),
            SizedBox(width: context.getRSize(8)),
            Text(
              selected,
              style: TextStyle(
                color: textCol,
                fontSize: context.getRFontSize(13),
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(width: context.getRSize(6)),
            Icon(
              FontAwesomeIcons.chevronDown,
              size: context.getRSize(10),
              color: subtextCol,
            ),
          ],
        ),
      ),
    );
  }

  /// Period options. Roles below Manager are capped at a Month maximum (§19.1);
  /// `managerUp` (Manager-or-above) is exactly that gate.
  List<String> _periodOptions(bool managerUp) {
    // §30.11 canonical chip set. Lower roles get the three shortest windows.
    return managerUp ? kDatePeriodLabels : kDatePeriodLabels.sublist(0, 3);
  }

  // ─────────────────────────── TABS ───────────────────────────────────────

  Widget _buildPendingTab(BuildContext context, List<OrderWithItems> list) {
    // §19.3: roles below Manager don't see monetary values in Orders.
    final managerUp = isManagerOrAbove(ref);

    // Compute summary stats
    final totalValue = list.fold<int>(
      0,
      (sum, o) => sum + o.order.netAmountKobo,
    );
    final unassigned =
        list.where((o) => o.order.riderName == 'Pick-up Order').length;

    // §19.2: no "Outstanding" card — a pending order is already settled at
    // checkout (received or charged to the wallet, §14.3), so it never owes.
    // Any debt lives on the customer's wallet (rule #4) and shows per card via
    // the wallet-debt badge when the balance is below zero.
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
      _StatItem(
        label: 'Pick-up',
        value: '$unassigned',
        color: subtextCol,
      ),
    ];

    final searchBarHeight = context.getRSize(64.0);
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _SummaryStrip(stats: stats)),
        SliverPersistentHeader(
          pinned: true,
          delegate: _PinnedHeaderDelegate(
            height: searchBarHeight,
            // Pending has no period filter — search field only.
            child: _buildSearchBar(context),
          ),
        ),
        ..._buildOrderSlivers(context, list, status: 'pending'),
      ],
    );
  }

  Widget _buildCompletedTab(BuildContext context, List<OrderWithItems> list) {
    final managerUp = isManagerOrAbove(ref);

    final totalRevenue = list.fold<int>(
      0,
      (sum, o) => sum + o.order.netAmountKobo,
    );
    final totalCollected = list.fold<int>(
      0,
      (sum, o) => sum + o.order.amountPaidKobo,
    );
    final crateDeposits = list.fold<int>(
      0,
      (sum, o) => sum + o.order.crateDepositPaidKobo,
    );

    final stats = [
      _StatItem(
        label: 'Completed',
        value: '${list.length}',
        color: success,
      ),
      if (managerUp) ...[
        _StatItem(
          label: 'Revenue',
          value: formatCurrency(totalRevenue / 100.0),
          color: Theme.of(context).colorScheme.primary,
        ),
        _StatItem(
          label: 'Collected',
          value: formatCurrency(totalCollected / 100.0),
          color: success,
        ),
        _StatItem(
          label: 'Crate Deposits',
          value: formatCurrency(crateDeposits / 100.0),
          color: subtextCol,
        ),
      ],
    ];

    final searchBarHeight = context.getRSize(64.0);
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _SummaryStrip(stats: stats)),
        SliverPersistentHeader(
          pinned: true,
          delegate: _PinnedHeaderDelegate(
            height: searchBarHeight,
            child: _buildSearchBar(
              context,
              selectedFilter: _completedFilter,
              onSelectFilter: (f) => setState(() => _completedFilter = f),
              filterOptions: _periodOptions(managerUp),
            ),
          ),
        ),
        ..._buildOrderSlivers(context, list, status: 'completed'),
      ],
    );
  }

  Widget _buildCancelledTab(BuildContext context, List<OrderWithItems> list) {
    final managerUp = isManagerOrAbove(ref);

    final valueForfeited = list.fold<int>(
      0,
      (sum, o) => sum + o.order.netAmountKobo,
    );
    final refundsIssued =
        list.where((o) => o.order.status == 'refunded').length;

    final stats = [
      _StatItem(
        label: 'Cancelled',
        value: '${list.length}',
        color: danger,
      ),
      if (managerUp)
        _StatItem(
          label: 'Value Forfeited',
          value: formatCurrency(valueForfeited / 100.0),
          color: danger,
        ),
      _StatItem(
        label: 'Refunds Issued',
        value: '$refundsIssued',
        color: blueMain,
      ),
    ];

    final searchBarHeight = context.getRSize(64.0);
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _SummaryStrip(stats: stats)),
        SliverPersistentHeader(
          pinned: true,
          delegate: _PinnedHeaderDelegate(
            height: searchBarHeight,
            child: _buildSearchBar(
              context,
              selectedFilter: _cancelledFilter,
              onSelectFilter: (f) => setState(() => _cancelledFilter = f),
              filterOptions: _periodOptions(managerUp),
            ),
          ),
        ),
        ..._buildOrderSlivers(context, list, status: 'cancelled'),
      ],
    );
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
        icon = FontAwesomeIcons.boxOpen;
        text = _searchQuery.isNotEmpty
            ? 'No pending orders match "$_searchQuery"'
            : 'No pending orders';
      } else if (status == 'completed') {
        icon = FontAwesomeIcons.clipboardCheck;
        text = _searchQuery.isNotEmpty
            ? 'No completed orders match "$_searchQuery"'
            : 'No completed orders';
      } else {
        icon = FontAwesomeIcons.ban;
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
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final item = list[index];
              return _OrderCard(
                orderWithItems: item,
                status: status,
                onMarkAsDelivered: status == 'pending'
                    ? () => _markAsDelivered(item)
                    : null,
                // §19.7: Refund replaces the old Cancel button on the Pending
                // tab and is hidden unless the user may cancel a sale. It
                // reverses the sale (stock, payment, both wallet legs, Funds
                // debit dated to today) and moves the order to Cancelled. The
                // Completed and Cancelled tabs have no Refund button (§19.8).
                onRefund: (status == 'pending' && canRefund)
                    ? () => _refundPendingOrder(item.order)
                    : null,
                onAssignRider: status == 'pending'
                    ? (orderId) => _showRiderSelection(context, orderId)
                    : null,
                onViewReceipt: () => _viewReceipt(context, item),
              );
            },
            childCount: list.length,
          ),
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

    await ref
        .read(orderServiceProvider)
        .markAsCompleted(order.id, ref.read(authProvider).currentUser?.id ?? '');

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
  }

  /// §19.7: Refund a Pending order (Manager/CEO — gated at the call site via
  /// sales.cancel). A refund moves cash out of the till, so it first requires
  /// an **open funds day** for the order's store (§23.8) — gated here, before
  /// the reason is asked, the same way the POS gate blocks sales. The reversal
  /// runs in OrdersDao.markCancelled and is dated to **today** (the refund day,
  /// §23.5): stock restored, payment voided, **both wallet legs reversed** (the
  /// wallet returns to its pre-sale balance, §14.3), and the Funds account
  /// debited today. The order moves to the Cancelled tab.
  void _refundPendingOrder(OrderData order) async {
    final today = await ref.read(todaysBusinessDateProvider.future);
    final storeId = order.storeId;
    final day = storeId == null
        ? null
        : await ref.read(databaseProvider).fundDaysDao.getDay(storeId, today);
    if (!mounted) return;
    if (day == null || day.status != 'open') {
      AppNotification.showError(
        context,
        'Open the day before issuing a refund.',
      );
      return;
    }

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
                    'is restored. The customer\'s wallet returns to its pre-sale '
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
                  icon: FontAwesomeIcons.rotateLeft,
                  variant: AppButtonVariant.danger,
                  size: AppButtonSize.small,
                  onPressed: reason.isEmpty
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          _executeRefund(order, reason, today);
                        },
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _executeRefund(
    OrderData order,
    String reason,
    String businessDate,
  ) async {
    final staffId = ref.read(authProvider).currentUser?.id ?? '';
    await ref.read(orderServiceProvider).markAsCancelled(
          order.id,
          reason,
          staffId,
          businessDate: businessDate,
        );
    if (mounted) {
      AppNotification.showSuccess(
        context,
        'Refund issued for ${order.orderNumber}.',
      );
    }
  }

  void _showRiderSelection(BuildContext context, String orderId) {
    // Staff/riders are no longer tracked. Mark the order as pick-up by default.
    ref.read(orderServiceProvider).assignRider(orderId, 'Pick-up Order');
  }

  void _viewReceipt(BuildContext context, OrderWithItems richOrder) async {
    DateTime? reshareDate;
    DateTime? reprintDate;

    final branchName = await _resolveBranchName(richOrder.order.storeId);

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
                                  'name': ri.product.name,
                                  'size': ri.product.size,
                                  'qty': ri.item.quantity,
                                  'price': ri.item.unitPriceKobo / 100.0,
                                },
                              )
                              .toList(),
                          subtotal: currentOrder.totalAmountKobo / 100.0,
                          crateDeposit: 0,
                          total: currentOrder.netAmountKobo / 100.0,
                          paymentMethod: currentOrder.paymentType,
                          customerName:
                              richOrder.customer?.name ?? 'Walk-in Customer',
                          customerAddress:
                              richOrder.customer?.addressText ?? 'N/A',
                          cashReceived: currentOrder.paymentType == 'Wallet Payment'
                              ? currentOrder.netAmountKobo / 100.0
                              : currentOrder.amountPaidKobo / 100.0,
                          reprintDate: reprintDate,
                          reshareDate: reshareDate,
                          riderName: currentOrder.riderName,
                          deliveryRef: null,
                          orderStatus: currentOrder.status,
                          refundAmount: currentOrder.amountPaidKobo / 100.0,
                          branchName: branchName,
                          businessName: ref.read(currentBusinessNameProvider),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.all(context.getRSize(16)).add(
                      EdgeInsets.only(bottom: context.deviceBottomInset),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: AppButton(
                            text: 'Print',
                            icon: FontAwesomeIcons.print,
                            onPressed: () {
                              setModalState(() {
                                reprintDate = DateTime.now();
                                reshareDate = null;
                              });
                              _printReceipt(
                                context,
                                richOrder,
                                branchName: branchName,
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
                            icon: FontAwesomeIcons.shareNodes,
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
    String? branchName,
  }) async {
    final order = richOrder.order;

    final receiptMapping = richOrder.items
        .map(
          (ri) => {
            'name': ri.product.name,
            'size': ri.product.size,
            'qty': ri.item.quantity,
            'price': ri.item.unitPriceKobo / 100.0,
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

      final finalBranchName =
          branchName ?? await _resolveBranchName(order.storeId);

      final walletBalance = richOrder.customer == null
          ? null
          : (await ref
                  .read(databaseProvider)
                  .customersDao
                  .getWalletBalanceKobo(richOrder.customer!.id)) /
              100.0;

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
        branchName: finalBranchName,
        businessName: ref.read(currentBusinessNameProvider),
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
                      border: Border(
                        right: BorderSide(color: borderCol),
                      ),
                    ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    stat.value,
                    style: TextStyle(
                      color: stat.color ??
                          Theme.of(context).colorScheme.onSurface,
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
    if (lower.contains('wallet')) return blueMain;
    if (lower.contains('partial')) return primaryColor;
    if (lower.contains('credit')) return danger;
    return success; // Full Cash / Card
  }

  // Returns a short label for the payment type badge
  String _paymentLabel(String paymentType) {
    final lower = paymentType.toLowerCase();
    if (lower.contains('wallet')) return 'Wallet';
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
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
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
    final cardCol = Theme.of(context).cardColor;
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
    final showCancelReason = status == 'cancelled' &&
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
    // at checkout — received, or charged through the wallet (§14.3) — so the
    // order never carries a balance. Customer debt lives on the wallet (rule #4)
    // and shows via the wallet-debt badge below, only when the balance is < 0.
    final hasDiscount = order.discountKobo > 0;

    // Wallet badge — only for named customers with a negative balance (debt).
    // Balance comes from the live ledger via walletBalancesKoboProvider.
    final balances =
        ref.watch(walletBalancesKoboProvider).valueOrNull ?? const <int, int>{};
    final walletBalanceKobo = customer == null ? 0 : (balances[customer.id] ?? 0);
    final showWalletDebt = customer != null && walletBalanceKobo < 0;

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

    return Container(
      margin: EdgeInsets.only(bottom: context.getRSize(16)),
      decoration: BoxDecoration(
        color: cardCol,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderCol),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onViewReceipt,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(15),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Left accent stripe
                  Container(width: 4, color: accentColor),

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
                              // Avatar
                              Container(
                                padding: EdgeInsets.all(context.getRSize(9)),
                                decoration: BoxDecoration(
                                  color: primary.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  FontAwesomeIcons.user,
                                  size: context.getRSize(15),
                                  color: primary,
                                ),
                              ),
                              SizedBox(width: context.getRSize(10)),

                              // Name + address
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      customer?.name ?? 'Walk-in Customer',
                                      style: TextStyle(
                                        color: textCol,
                                        fontWeight: FontWeight.bold,
                                        fontSize: context.getRFontSize(14),
                                      ),
                                    ),
                                    if (customer?.addressText != null &&
                                        customer!.addressText != 'N/A')
                                      Text(
                                        customer.addressText,
                                        style: TextStyle(
                                          color: subtextCol,
                                          fontSize: context.getRFontSize(12),
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                  ],
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
                                        FontAwesomeIcons.motorcycle,
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
                                      'Order #${order.id}',
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
                                  ],
                                ),
                              ),
                              // Payment type badge
                              _PaymentBadge(
                                label: _paymentLabel(order.paymentType),
                                color: _paymentColor(order.paymentType, primary),
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
                                final product = richItem.product;
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
                                          '${item.quantity}× ${product.name}',
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
                                                fontSize:
                                                    context.getRFontSize(12),
                                              ),
                                            ),
                                            Text(
                                              formatCurrency(
                                                order.netAmountKobo / 100.0,
                                              ),
                                              style: TextStyle(
                                                color: primary,
                                                fontWeight: FontWeight.bold,
                                                fontSize:
                                                    context.getRFontSize(15),
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
                                    if (showWalletDebt)
                                      _WalletDebtBadge(
                                        balanceKobo: walletBalanceKobo,
                                      ),
                                  ],
                                ),

                              // ── Discount row (money — hidden below Manager) ─
                              if (canSeeMoney && hasDiscount) ...[
                                SizedBox(height: context.getRSize(6)),
                                Row(
                                  children: [
                                    Icon(
                                      FontAwesomeIcons.tag,
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
                                      FontAwesomeIcons.circleInfo,
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
                              border: Border(
                                top: BorderSide(color: borderCol),
                              ),
                            ),
                            child: Row(
                              children: [
                                // §19.7: Refund (CEO + Manager only — null hides
                                // it). Replaces the former Cancel button.
                                if (onRefund != null) ...[
                                  Expanded(
                                    child: AppButton(
                                      text: 'Refund',
                                      icon: FontAwesomeIcons.rotateLeft,
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
                                      icon: FontAwesomeIcons.truckFast,
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
        icon = FontAwesomeIcons.check;
        label = 'DONE';
        break;
      case 'refunded':
        color = blueMain;
        icon = FontAwesomeIcons.rotateLeft;
        label = 'REFUNDED';
        break;
      default:
        color = danger;
        icon = FontAwesomeIcons.ban;
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
        border: Border.all(color: color.withValues(alpha: 0.2)),
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
        border: Border.all(color: color.withValues(alpha: 0.25)),
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

class _WalletDebtBadge extends StatelessWidget {
  final int balanceKobo;
  const _WalletDebtBadge({required this.balanceKobo});

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
        border: Border.all(color: danger.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            FontAwesomeIcons.wallet,
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
