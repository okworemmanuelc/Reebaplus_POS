import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/app_bar_header.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/features/stores/screens/request_stock_screen.dart';
import 'package:reebaplus_pos/features/stores/widgets/store_transfer_hub.dart';

class StoreDetailsScreen extends ConsumerStatefulWidget {
  final StoreData store;

  const StoreDetailsScreen({super.key, required this.store});

  @override
  ConsumerState<StoreDetailsScreen> createState() => _StoreDetailsScreenState();
}

class _StoreDetailsScreenState extends ConsumerState<StoreDetailsScreen> {
  StoreData? _liveStore;
  List<ProductDataWithStock> _inventory = [];
  List<CustomerData> _customers = [];

  StreamSubscription<StoreData?>? _storeSub;
  StreamSubscription<List<ProductDataWithStock>>? _inventorySub;
  StreamSubscription<List<CustomerData>>? _customersSub;

  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _border => Theme.of(context).dividerColor;

  StoreData get _store => _liveStore ?? widget.store;

  @override
  void initState() {
    super.initState();
    final id = widget.store.id;
    final db = ref.read(databaseProvider);

    _storeSub = db.storesDao.watchStore(id).listen((w) {
      if (mounted && w != null) setState(() => _liveStore = w);
    });
    _inventorySub = db.inventoryDao
        .watchProductDatasWithStockByStore(id)
        .listen((list) {
          if (mounted) setState(() => _inventory = list);
        });
    _customersSub = db.customersDao.watchCustomersByStore(id).listen((list) {
      if (mounted) setState(() => _customers = list);
    });
  }

  @override
  void dispose() {
    _storeSub?.cancel();
    _inventorySub?.cancel();
    _customersSub?.cancel();
    super.dispose();
  }

  void _openRequestScreen({String? fixedDestStoreId, String? fixedSourceStoreId}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RequestStockScreen(
          fixedDestStoreId: fixedDestStoreId,
          fixedSourceStoreId: fixedSourceStoreId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Full access = CEO / all-stores Manager, or a user assigned to THIS store.
    // Otherwise the viewer gets a read-only, request-only restricted view.
    final canViewAll = ref.watch(canViewAllStoresProvider);
    final userId = ref.watch(authProvider).currentUser?.id;
    final assignedIds =
        (userId == null
                ? null
                : ref.watch(myUserStoresProvider(userId)).valueOrNull)
            ?.map((s) => s.storeId)
            .toSet() ??
            const <String>{};
    final hasFullAccess = canViewAll || assignedIds.contains(widget.store.id);
    final canRequest = hasPermission(ref, 'stores.request_transfer');

    final totalStock = _inventory.fold<int>(0, (sum, p) => sum + p.totalStock);
    final totalValue = _inventory.fold<double>(
      0.0,
      (sum, p) => sum + (p.totalStock * (p.product.retailerPriceKobo / 100.0)),
    );
    final activeProducts = _inventory.where((p) => p.totalStock > 0).length;
    final lowStock = _inventory
        .where(
          (p) =>
              p.totalStock > 0 && p.totalStock <= p.product.lowStockThreshold,
        )
        .length;
    final customersCount = _customers.length;

    return SharedScaffold(
      activeRoute: 'store',
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, color: _text, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: AppBarHeader(
          icon: FontAwesomeIcons.store.data,
          title: _store.name,
          subtitle: _store.location ?? 'Main Storage',
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth > 600;
          if (!hasFullAccess) {
            return _buildRestrictedView(canRequest);
          }
          return ListView(
            padding: EdgeInsets.all(rSize(context, 16)).copyWith(
              bottom: rSize(context, 16) + context.deviceBottomPadding,
            ),
            children: [
              _buildMetricOverview(totalStock, totalValue),
              SizedBox(height: rSize(context, 20)),
              _buildStatsGrid(isWide, activeProducts, lowStock, customersCount),
              SizedBox(height: rSize(context, 24)),
              _buildInventoryList(),
              SizedBox(height: rSize(context, 16)),
              if (canRequest) ...[
                AppButton(
                  text: 'Request Stock',
                  icon: FontAwesomeIcons.handHoldingDollar.data,
                  variant: AppButtonVariant.secondary,
                  isFullWidth: true,
                  onPressed: () =>
                      _openRequestScreen(fixedDestStoreId: widget.store.id),
                ),
                SizedBox(height: rSize(context, 16)),
              ],
              _buildQuickActions(isWide),
              SizedBox(height: rSize(context, 24)),
              StoreTransferHub(storeId: widget.store.id),
              SizedBox(height: rSize(context, 100)),
            ],
          );
        },
      ),
    );
  }

  // ── Restricted view (viewer not assigned to this store) ─────────────────────
  // Read-only browse of the store's stock + a single "Request Stock" action.
  // No metrics, no management, no transfer hub.
  Widget _buildRestrictedView(bool canRequest) {
    return ListView(
      padding: EdgeInsets.all(rSize(context, 16)).copyWith(
        bottom: rSize(context, 16) + context.deviceBottomPadding,
      ),
      children: [
        Container(
          padding: EdgeInsets.all(rSize(context, 14)),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _border),
          ),
          child: Row(
            children: [
              Icon(
                FontAwesomeIcons.circleInfo.data,
                size: rSize(context, 16),
                color: Theme.of(context).colorScheme.primary,
              ),
              SizedBox(width: rSize(context, 10)),
              Expanded(
                child: Text(
                  "You can browse this store's stock and request items. Full "
                  "management is available only for stores you're assigned to.",
                  style: TextStyle(
                    color: _subtext,
                    fontSize: rFontSize(context, 12),
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: rSize(context, 20)),
        _buildInventoryList(),
        SizedBox(height: rSize(context, 16)),
        if (canRequest)
          AppButton(
            text: 'Request Stock from this store',
            icon: FontAwesomeIcons.handHoldingDollar.data,
            isFullWidth: true,
            onPressed: () =>
                _openRequestScreen(fixedSourceStoreId: widget.store.id),
          ),
        SizedBox(height: rSize(context, 100)),
      ],
    );
  }

  Widget _buildMetricOverview(int totalStock, double totalValue) {
    return Container(
      padding: EdgeInsets.all(rSize(context, 20)),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Theme.of(context).colorScheme.primary,
            Theme.of(context).colorScheme.secondary,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
            blurRadius: 15,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Store Value',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: rFontSize(context, 14),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                SizedBox(height: rSize(context, 4)),
                Text(
                  formatCurrency(totalValue),
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: rFontSize(context, 28),
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: rSize(context, 16),
              vertical: rSize(context, 8),
            ),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Text(
                  totalStock.toString(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
                Text(
                  'Total Units',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsGrid(
    bool isWide,
    int activeProducts,
    int lowStock,
    int customersCount,
  ) {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: isWide ? 3 : 2,
      mainAxisSpacing: rSize(context, 12),
      crossAxisSpacing: rSize(context, 12),
      childAspectRatio: 1.1,
      children: [
        _buildStatCard(
          'Products',
          activeProducts.toString(),
          FontAwesomeIcons.boxesStacked.data,
          AppColors.success,
        ),
        _buildStatCard(
          'Low Stock',
          lowStock.toString(),
          FontAwesomeIcons.triangleExclamation.data,
          AppColors.danger,
        ),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            // §12.1: focus the app-wide active store on this store, then open
            // the Customers tab (which now follows the nav-drawer picker).
            final nav = ref.read(navigationProvider);
            nav.setLockedStore(widget.store.id);
            Navigator.of(context).pop();
            nav.setIndex(4);
          },
          child: _buildStatCard(
            'Customers',
            customersCount.toString(),
            FontAwesomeIcons.users.data,
            const Color(0xFF06B6D4),
          ),
        ),
      ],
    );
  }

  Widget _buildStatCard(
    String label,
    String value,
    IconData icon,
    Color color,
  ) {
    return Container(
      padding: EdgeInsets.all(rSize(context, 16)),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Container(
            padding: EdgeInsets.all(rSize(context, 8)),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: rSize(context, 16)),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: rFontSize(context, 20),
                  fontWeight: FontWeight.w900,
                  color: _text,
                ),
              ),
              Text(
                label,
                style: TextStyle(
                  fontSize: rFontSize(context, 12),
                  color: _subtext,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Inventory List ──────────────────────────────────────────────────────────
  Widget _buildInventoryList() {
    final stocked = _inventory.where((p) => p.totalStock > 0).toList()
      ..sort((a, b) => b.totalStock.compareTo(a.totalStock));

    return Container(
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: true,
          tilePadding: EdgeInsets.symmetric(
            horizontal: rSize(context, 16),
            vertical: 0,
          ),
          leading: Container(
            padding: EdgeInsets.all(rSize(context, 8)),
            decoration: BoxDecoration(
              color: AppColors.success.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              FontAwesomeIcons.boxesStacked.data,
              color: AppColors.success,
              size: rSize(context, 14),
            ),
          ),
          title: Text(
            'Inventory',
            style: TextStyle(
              fontSize: rFontSize(context, 15),
              fontWeight: FontWeight.bold,
              color: _text,
            ),
          ),
          subtitle: Text(
            '${stocked.length} product${stocked.length == 1 ? '' : 's'} in stock',
            style: TextStyle(fontSize: rFontSize(context, 12), color: _subtext),
          ),
          children: stocked.isEmpty
              ? [
                  Padding(
                    padding: EdgeInsets.all(rSize(context, 20)),
                    child: Text(
                      'No stock in this store yet.',
                      style: TextStyle(
                        color: _subtext,
                        fontSize: rFontSize(context, 13),
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ]
              : stocked.map((item) {
                  final isLow =
                      item.totalStock <= item.product.lowStockThreshold;
                  return Container(
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: _border)),
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: rSize(context, 16),
                        vertical: rSize(context, 12),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.product.name,
                                  style: TextStyle(
                                    fontSize: rFontSize(context, 14),
                                    fontWeight: FontWeight.w600,
                                    color: _text,
                                  ),
                                ),
                                if (item.product.unit.isNotEmpty) ...[
                                  SizedBox(height: rSize(context, 2)),
                                  Text(
                                    item.product.unit,
                                    style: TextStyle(
                                      fontSize: rFontSize(context, 11),
                                      color: _subtext,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: rSize(context, 10),
                              vertical: rSize(context, 4),
                            ),
                            decoration: BoxDecoration(
                              color: isLow
                                  ? Theme.of(
                                      context,
                                    ).colorScheme.error.withValues(alpha: 0.1)
                                  : AppColors.success.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '${item.totalStock} units',
                              style: TextStyle(
                                fontSize: rFontSize(context, 12),
                                fontWeight: FontWeight.bold,
                                color: isLow
                                    ? AppColors.danger
                                    : AppColors.success,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
        ),
      ),
    );
  }

  // ── Quick Actions ───────────────────────────────────────────────────────────
  Widget _buildQuickActions(bool isWide) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Quick Actions',
          style: TextStyle(
            fontSize: rFontSize(context, 16),
            fontWeight: FontWeight.bold,
            color: _text,
          ),
        ),
        SizedBox(height: rSize(context, 12)),
        _actionTile(
          'View Inventory',
          'Check and manage stock',
          FontAwesomeIcons.boxesStacked.data,
          Theme.of(context).colorScheme.primary,
          () {
            // §12.1: focus the app-wide active store on this store, then open
            // the Inventory tab (which now follows the nav-drawer picker).
            final nav = ref.read(navigationProvider);
            nav.setLockedStore(widget.store.id);
            nav.setIndex(2);
          },
        ),
      ],
    );
  }

  Widget _actionTile(
    String title,
    String subtitle,
    IconData icon,
    Color color,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: EdgeInsets.all(rSize(context, 16)),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: EdgeInsets.all(rSize(context, 10)),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: rSize(context, 18)),
            ),
            SizedBox(height: rSize(context, 12)),
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: rFontSize(context, 14),
                color: _text,
              ),
            ),
            SizedBox(height: rSize(context, 2)),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: rFontSize(context, 11),
                color: _subtext,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
