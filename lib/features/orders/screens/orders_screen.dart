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

  // Date filters
  String _completedFilter = 'All Time';
  String _cancelledFilter = 'All Time';

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

  /// Resolves a warehouseId to its branch name.
  Future<String?> _resolveBranchName(String? warehouseId) async {
    if (warehouseId == null) return null;
    final db = ref.read(databaseProvider);
    final warehouses = await db.select(db.warehouses).get();
    return warehouses
        .where((w) => w.id == warehouseId)
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
                  if (_completedFilter == 'All Time') return true;
                  final t = o.order.completedAt ?? o.order.createdAt;
                  final diff = now.difference(t);
                  if (_completedFilter == 'Day') {
                    return diff.inDays == 0 && now.day == t.day;
                  }
                  if (_completedFilter == 'Week') return diff.inDays <= 7;
                  if (_completedFilter == 'Month') return diff.inDays <= 30;
                  if (_completedFilter == 'Year') return diff.inDays <= 365;
                  return true;
                }).toList(),
              );

              final separatedCancelled = allOrdersWithItems
                  .where((o) => o.order.status == 'cancelled')
                  .toList();
              final cancelled = _applySearch(
                separatedCancelled.where((o) {
                  if (_cancelledFilter == 'All Time') return true;
                  final t = o.order.cancelledAt ?? o.order.createdAt;
                  final diff = now.difference(t);
                  if (_cancelledFilter == 'Day') {
                    return diff.inDays == 0 && now.day == t.day;
                  }
                  if (_cancelledFilter == 'Week') return diff.inDays <= 7;
                  if (_cancelledFilter == 'Month') return diff.inDays <= 30;
                  if (_cancelledFilter == 'Year') return diff.inDays <= 365;
                  return true;
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

  Widget _buildSearchBar(BuildContext context) {
    return Container(
      color: surfaceCol,
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(10),
        context.getRSize(16),
        context.getRSize(10),
      ),
      child: TextField(
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
      ),
    );
  }

  // ─────────────────────────── TABS ───────────────────────────────────────

  Widget _buildPendingTab(BuildContext context, List<OrderWithItems> list) {
    // Compute summary stats
    final totalValue = list.fold<int>(
      0,
      (sum, o) => sum + o.order.netAmountKobo,
    );
    final totalOutstanding = list.fold<int>(
      0,
      (sum, o) =>
          sum +
          (o.order.netAmountKobo - o.order.amountPaidKobo).clamp(0, 999999999),
    );
    final unassigned =
        list.where((o) => o.order.riderName == 'Pick-up Order').length;

    final stats = [
      _StatItem(
        label: 'Pending',
        value: '${list.length}',
        color: Theme.of(context).colorScheme.primary,
      ),
      _StatItem(
        label: 'Total Value',
        value: formatCurrency(totalValue / 100.0),
        color: Theme.of(context).colorScheme.primary,
      ),
      _StatItem(
        label: 'Outstanding',
        value: formatCurrency(totalOutstanding / 100.0),
        color: danger,
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
            child: _buildSearchBar(context),
          ),
        ),
        ..._buildOrderSlivers(context, list, status: 'pending'),
      ],
    );
  }

  Widget _buildCompletedTab(BuildContext context, List<OrderWithItems> list) {
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
    ];

    final searchBarHeight = context.getRSize(64.0);
    final filterChipHeight = context.getRSize(56.0);
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
        SliverPersistentHeader(
          pinned: true,
          delegate: _PinnedHeaderDelegate(
            height: filterChipHeight,
            child: _buildFilterChips(
              context,
              selected: _completedFilter,
              onSelect: (f) => setState(() => _completedFilter = f),
            ),
          ),
        ),
        ..._buildOrderSlivers(context, list, status: 'completed'),
      ],
    );
  }

  Widget _buildCancelledTab(BuildContext context, List<OrderWithItems> list) {
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
    final filterChipHeight = context.getRSize(56.0);
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
        SliverPersistentHeader(
          pinned: true,
          delegate: _PinnedHeaderDelegate(
            height: filterChipHeight,
            child: _buildFilterChips(
              context,
              selected: _cancelledFilter,
              onSelect: (f) => setState(() => _cancelledFilter = f),
            ),
          ),
        ),
        ..._buildOrderSlivers(context, list, status: 'cancelled'),
      ],
    );
  }

  // ─────────────────────────── FILTER CHIPS ───────────────────────────────

  Widget _buildFilterChips(
    BuildContext context, {
    required String selected,
    required ValueChanged<String> onSelect,
  }) {
    final filters = ['Day', 'Week', 'Month', 'Year', 'To Date', 'All Time'];
    return Container(
      color: surfaceCol,
      padding: EdgeInsets.symmetric(vertical: context.getRSize(8)),
      height: context.getRSize(56),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: context.getRSize(16)),
        itemCount: filters.length,
        separatorBuilder: (context, index) =>
            SizedBox(width: context.getRSize(8)),
        itemBuilder: (context, index) {
          final f = filters[index];
          final isSelected = f == selected;
          return FilterChip(
            label: Text(
              f,
              style: TextStyle(
                fontSize: context.getRFontSize(12),
                color: isSelected ? Colors.white : textCol,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
            selected: isSelected,
            onSelected: (_) => onSelect(f),
            selectedColor: Theme.of(context).colorScheme.primary,
            backgroundColor: _bg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(
                color: isSelected ? Colors.transparent : borderCol,
              ),
            ),
            showCheckmark: false,
          );
        },
      ),
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
                onCancel:
                    status == 'pending' ? () => _cancelOrder(item.order) : null,
                onAssignRider: status == 'pending'
                    ? (orderId) => _showRiderSelection(context, orderId)
                    : null,
                onRefund: status == 'cancelled'
                    ? () => _showRefundChoice(context, item.order)
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

  void _cancelOrder(OrderData order) {
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: surfaceCol,
          title: Text(
            'Cancel Order',
            style: TextStyle(color: textCol, fontWeight: FontWeight.bold),
          ),
          content: Text(
            'Are you sure you want to cancel order #${order.id}?',
            style: TextStyle(color: subtextCol),
          ),
          actions: [
            AppButton(
              text: 'Back',
              variant: AppButtonVariant.ghost,
              size: AppButtonSize.small,
              onPressed: () => Navigator.pop(ctx),
            ),
            AppButton(
              text: 'Cancel Order',
              variant: AppButtonVariant.danger,
              size: AppButtonSize.small,
              onPressed: () {
                Navigator.pop(ctx);
                ref
                    .read(orderServiceProvider)
                    .markAsCancelled(order.id, 'Cancelled by staff', '');
              },
            ),
          ],
        );
      },
    );
  }

  void _showRefundChoice(BuildContext context, OrderData order) {
    final isPartial = order.amountPaidKobo < order.netAmountKobo;

    if (isPartial) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: surfaceCol,
          title: Text(
            'Refund Payment',
            style: TextStyle(color: textCol, fontWeight: FontWeight.bold),
          ),
          content: Text(
            'Partial payment was made (${formatCurrency(order.amountPaidKobo / 100.0)} of ${formatCurrency(order.netAmountKobo / 100.0)}). '
            'The refund will be credited to ${order.orderNumber}\'s wallet.',
            style: TextStyle(color: subtextCol),
          ),
          actions: [
            AppButton(
              text: 'Cancel',
              variant: AppButtonVariant.ghost,
              size: AppButtonSize.small,
              onPressed: () => Navigator.pop(ctx),
            ),
            AppButton(
              text: 'Confirm Refund',
              size: AppButtonSize.small,
              onPressed: () {
                Navigator.pop(ctx);
                _processRefund(order, toWallet: true);
              },
            ),
          ],
        ),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Container(
          decoration: BoxDecoration(
            color: surfaceCol,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: EdgeInsets.all(context.getRSize(16)),
                child: Text(
                  'Refund Method',
                  style: TextStyle(
                    fontSize: context.getRFontSize(18),
                    fontWeight: FontWeight.bold,
                    color: textCol,
                  ),
                ),
              ),
              Text(
                'Select how you want to refund ${formatCurrency(order.amountPaidKobo / 100.0)}',
                style: TextStyle(color: subtextCol, fontSize: 13),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: Icon(
                  FontAwesomeIcons.wallet,
                  color: success,
                  size: context.getRSize(18),
                ),
                title: Text(
                  'Refund to Wallet',
                  style: TextStyle(color: textCol),
                ),
                subtitle: Text(
                  'Add balance to customer\'s wallet',
                  style: TextStyle(color: subtextCol, fontSize: 12),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _processRefund(order, toWallet: true);
                },
              ),
              ListTile(
                leading: Icon(
                  FontAwesomeIcons.moneyBillWave,
                  color: Theme.of(context).colorScheme.primary,
                  size: context.getRSize(18),
                ),
                title: Text('Refund to Cash', style: TextStyle(color: textCol)),
                subtitle: Text(
                  'Record as cash payout',
                  style: TextStyle(color: subtextCol, fontSize: 12),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _processRefund(order, toWallet: false);
                },
              ),
              SizedBox(height: context.getRSize(20)),
            ],
          ),
        ),
      ),
    );
  }

  void _processRefund(OrderData order, {required bool toWallet}) {
    AppNotification.showSuccess(
      context,
      'Refund of ${formatCurrency(order.amountPaidKobo / 100.0)} processed to ${toWallet ? 'Wallet' : 'Cash'}.',
    );
  }

  void _showRiderSelection(BuildContext context, String orderId) {
    // Staff/riders are no longer tracked. Mark the order as pick-up by default.
    ref.read(orderServiceProvider).assignRider(orderId, 'Pick-up Order');
  }

  void _viewReceipt(BuildContext context, OrderWithItems richOrder) async {
    DateTime? reshareDate;
    DateTime? reprintDate;

    final branchName = await _resolveBranchName(richOrder.order.warehouseId);

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
                        ),
                      ),
                    ),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: EdgeInsets.all(context.getRSize(16)),
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
                          if (currentOrder.status == 'cancelled')
                            Expanded(
                              child: AppButton(
                                text: 'Refund',
                                icon: FontAwesomeIcons.rotateLeft,
                                variant: AppButtonVariant.danger,
                                onPressed:
                                    (currentOrder.paymentType == 'Credit')
                                    ? null
                                    : () {
                                        Navigator.pop(modalCtx);
                                        _showRefundChoice(
                                          context,
                                          currentOrder,
                                        );
                                      },
                              ),
                            ),
                          if (currentOrder.status == 'cancelled')
                            SizedBox(width: context.getRSize(12)),
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
          branchName ?? await _resolveBranchName(order.warehouseId);

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
      );

      if (!context.mounted) return;

      final isConnected = await printer.isConnected;
      if (isConnected) {
        final success = await printer.printBytesDirectly(bytes);
        if (success) {
          if (!context.mounted) return;
          AppNotification.showSuccess(context, 'Print successful');
          _logReprint(order.id.toString());
          return;
        }
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
  final VoidCallback? onCancel;
  final Function(String)? onAssignRider;
  final VoidCallback? onRefund;
  final VoidCallback onViewReceipt;

  const _OrderCard({
    required this.orderWithItems,
    required this.status,
    this.onMarkAsDelivered,
    this.onCancel,
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

    // Accent color for the left border stripe
    final Color accentColor;
    if (status == 'pending') {
      accentColor = primary;
    } else if (status == 'completed') {
      accentColor = success;
    } else {
      accentColor = danger;
    }

    // Financial values
    final outstanding = order.netAmountKobo - order.amountPaidKobo;
    final isWalletPayment = order.paymentType == 'Wallet Payment';
    final hasOutstanding = outstanding > 0 && !isWalletPayment;
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
                                      Text(
                                        formatCurrency(item.totalKobo / 100.0),
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
                              Divider(height: 1, color: borderCol),
                              SizedBox(height: context.getRSize(10)),

                              // ── Totals row ─────────────────────────────
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

                              // ── Discount row ───────────────────────────
                              if (hasDiscount) ...[
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

                              // ── Outstanding badge ──────────────────────
                              if (hasOutstanding) ...[
                                SizedBox(height: context.getRSize(6)),
                                Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: context.getRSize(10),
                                    vertical: context.getRSize(5),
                                  ),
                                  decoration: BoxDecoration(
                                    color: danger.withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: danger.withValues(alpha: 0.2),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        FontAwesomeIcons.clockRotateLeft,
                                        size: context.getRSize(11),
                                        color: danger,
                                      ),
                                      SizedBox(width: context.getRSize(6)),
                                      Text(
                                        'Owes: ${formatCurrency(outstanding / 100.0)}',
                                        style: TextStyle(
                                          color: danger,
                                          fontWeight: FontWeight.w600,
                                          fontSize: context.getRFontSize(12),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],

                              // ── Cancellation reason ────────────────────
                              if (status == 'cancelled' &&
                                  order.cancellationReason != null &&
                                  order.cancellationReason!.isNotEmpty) ...[
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
                                if (onCancel != null)
                                  Expanded(
                                    child: AppButton(
                                      text: 'Cancel',
                                      icon: FontAwesomeIcons.ban,
                                      variant: AppButtonVariant.ghost,
                                      size: AppButtonSize.xsmall,
                                      onPressed: onCancel,
                                    ),
                                  ),
                                SizedBox(width: context.getRSize(12)),
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

                        // ── Refund button (cancelled) ──────────────────────
                        if (status == 'cancelled' && onRefund != null)
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
                            child: AppButton(
                              text: 'Initiate Refund',
                              icon: FontAwesomeIcons.rotateLeft,
                              variant: AppButtonVariant.danger,
                              size: AppButtonSize.xsmall,
                              onPressed: onRefund,
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
