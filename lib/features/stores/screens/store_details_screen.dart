import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/features/stores/screens/request_stock_screen.dart';
import 'package:reebaplus_pos/features/stores/widgets/store_transfer_hub.dart';
import 'package:reebaplus_pos/features/stores/widgets/stores_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
import 'package:reebaplus_pos/core/utils/product_unit.dart';

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

  void _openRequestScreen({
    String? fixedDestStoreId,
    String? fixedSourceStoreId,
  }) {
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
    final canRequest = Gates.requestStoreTransfer.allows(ref);

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

    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: SharedScaffold(
        activeRoute: 'store',
        backgroundColor: Colors.transparent,
        appBar: StoresTopBar(
          key: StoresKeys.detailsTopBar,
          height: storesTopBarHeight(context),
          header: ScreenHeader(
            leading: StoresBackButton(onPressed: () => Navigator.pop(context)),
            icon: AppIcons.store,
            title: _store.name,
            subtitle: _store.location ?? 'Main Storage',
          ),
        ),
        body: CustomScrollView(
          key: hasFullAccess ? StoresKeys.detailsBody : StoresKeys.restricted,
          slivers: [
            storesSliver(
              SliverToBoxAdapter(
                child: hasFullAccess
                    ? _buildFullView(
                        canRequest: canRequest,
                        totalStock: totalStock,
                        totalValue: totalValue,
                        activeProducts: activeProducts,
                        lowStock: lowStock,
                        customersCount: customersCount,
                      )
                    : _buildRestrictedView(canRequest),
              ),
              cap: kStoreDetailsMaxContentWidth,
              top: context.getRSize(16),
              bottom: context.getRSize(24) + context.deviceBottomPadding,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFullView({
    required bool canRequest,
    required int totalStock,
    required double totalValue,
    required int activeProducts,
    required int lowStock,
    required int customersCount,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeaderCards(
          totalStock,
          totalValue,
          activeProducts,
          lowStock,
          customersCount,
        ),
        SizedBox(height: context.getRSize(20)),
        _buildInventoryList(),
        SizedBox(height: context.getRSize(16)),
        if (canRequest) ...[
          AppButton(
            key: StoresKeys.requestStock,
            text: 'Request Stock',
            icon: AppIcons.settlement,
            variant: AppButtonVariant.secondary,
            isFullWidth: true,
            onPressed: () =>
                _openRequestScreen(fixedDestStoreId: widget.store.id),
          ),
          SizedBox(height: context.getRSize(16)),
        ],
        _buildQuickActions(),
        SizedBox(height: context.getRSize(24)),
        KeyedSubtree(
          key: StoresKeys.transferHub,
          child: StoreTransferHub(storeId: widget.store.id),
        ),
      ],
    );
  }

  // ── Restricted view (viewer not assigned to this store) ─────────────────────
  // Read-only browse of the store's stock + a single "Request Stock" action.
  // No metrics, no management, no transfer hub.
  Widget _buildRestrictedView(bool canRequest) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const StoresNotice(
          text:
              "You can browse this store's stock and request items. Full "
              "management is available only for stores you're assigned to.",
        ),
        SizedBox(height: context.getRSize(20)),
        _buildInventoryList(),
        SizedBox(height: context.getRSize(16)),
        if (canRequest)
          AppButton(
            key: StoresKeys.requestStock,
            text: 'Request Stock from this store',
            icon: AppIcons.settlement,
            isFullWidth: true,
            onPressed: () =>
                _openRequestScreen(fixedSourceStoreId: widget.store.id),
          ),
      ],
    );
  }

  /// Store Value + the three figure tiles: stacked, or side by side once the
  /// measured content column is at least [kStoreDetailsSideBySideWidth]
  /// (never a viewport predicate - PRD #239).
  Widget _buildHeaderCards(
    int totalStock,
    double totalValue,
    int activeProducts,
    int lowStock,
    int customersCount,
  ) {
    return LayoutBuilder(
      builder: (context, c) {
        final gap = context.getRSize(12);
        final sideBySide = c.maxWidth >= kStoreDetailsSideBySideWidth;
        final value = StatCard(
          key: StoresKeys.storeValue,
          icon: AppIcons.inventory,
          tone: IconTileTone.info,
          title: 'Store Value',
          value: formatCurrency(totalValue),
          subtitle: 'Total Units',
          pillLabel: totalStock.toString(),
          pillTone: TagPillTone.info,
        );
        Widget tiles(double width) {
          final cols = width >= context.getRSize(480) ? 3 : 2;
          final tileWidth = (width - gap * (cols - 1)) / cols;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              SizedBox(
                width: tileWidth,
                child: StoreStatTile(
                  icon: AppIcons.inventory,
                  tone: IconTileTone.green,
                  label: 'Products',
                  value: activeProducts.toString(),
                ),
              ),
              SizedBox(
                width: tileWidth,
                child: StoreStatTile(
                  icon: AppIcons.warning,
                  tone: IconTileTone.danger,
                  label: 'Low Stock',
                  value: lowStock.toString(),
                ),
              ),
              SizedBox(
                width: tileWidth,
                child: StoreStatTile(
                  key: StoresKeys.customersTile,
                  icon: AppIcons.customers,
                  tone: IconTileTone.info,
                  label: 'Customers',
                  value: customersCount.toString(),
                  onTap: () {
                    // §12.1: focus the app-wide active store on this store,
                    // then open the Customers tab (which now follows the
                    // nav-drawer picker).
                    final nav = ref.read(navigationProvider);
                    nav.setLockedStore(widget.store.id);
                    Navigator.of(context).pop();
                    nav.setIndex(4);
                  },
                ),
              ),
            ],
          );
        }

        if (!sideBySide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              value,
              SizedBox(height: gap),
              tiles(c.maxWidth),
            ],
          );
        }
        final rightWidth = (c.maxWidth - gap) * 3 / 5;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 2, child: value),
            SizedBox(width: gap),
            SizedBox(width: rightWidth, child: tiles(rightWidth)),
          ],
        );
      },
    );
  }

  // ── Inventory List ──────────────────────────────────────────────────────────
  Widget _buildInventoryList() {
    final t = Theme.of(context);
    final crates = businessTracksCrates(ref.watch(currentBusinessProvider));
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final stocked = _inventory.where((p) => p.totalStock > 0).toList()
      ..sort((a, b) => b.totalStock.compareTo(a.totalStock));

    return DecoratedBox(
      key: StoresKeys.inventoryCard,
      decoration: AppDecorations.card(context),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusXL),
        // ListTile paints on the nearest Material; a transparent one keeps
        // the card's own fill visible.
        child: Material(
          type: MaterialType.transparency,
          child: StoresExpansionTile(
            initiallyExpanded: true,
            tilePadding: EdgeInsets.symmetric(horizontal: context.getRSize(16)),
            leading: const IconTile(
              icon: AppIcons.inventory,
              tone: IconTileTone.green,
              size: 40,
            ),
            title: Text(
              'Inventory',
              style: context
                  .boldStyle(15)
                  .copyWith(color: t.colorScheme.onSurface),
            ),
            subtitle: Text(
              '${stocked.length} product${stocked.length == 1 ? '' : 's'} in stock',
              style: context.regularStyle(12).copyWith(color: muted),
            ),
            children: stocked.isEmpty
                ? [
                    Padding(
                      padding: EdgeInsets.all(context.getRSize(20)),
                      child: Text(
                        'No stock in this store yet.',
                        style: context.regularStyle(13).copyWith(color: muted),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ]
                : stocked.map((item) {
                    final isLow =
                        item.totalStock <= item.product.lowStockThreshold;
                    return Container(
                      decoration: BoxDecoration(
                        border: Border(top: BorderSide(color: t.dividerColor)),
                      ),
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: context.getRSize(16),
                          vertical: context.getRSize(12),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.product.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: context
                                        .boldStyle(14)
                                        .copyWith(
                                          color: t.colorScheme.onSurface,
                                        ),
                                  ),
                                  if ((item.product.unit ?? '').isNotEmpty)
                                    Text(
                                      unitLabel(item.product.unit, crates: crates)!,
                                      style: context
                                          .regularStyle(12)
                                          .copyWith(color: muted),
                                    ),
                                ],
                              ),
                            ),
                            SizedBox(width: context.getRSize(8)),
                            TagPill(
                              label: '${item.totalStock} units',
                              tone: isLow
                                  ? TagPillTone.danger
                                  : TagPillTone.green,
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
          ),
        ),
      ),
    );
  }

  // ── Quick Actions ───────────────────────────────────────────────────────────
  Widget _buildQuickActions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Quick Actions'),
        SizedBox(height: context.getRSize(12)),
        KeyedSubtree(
          key: StoresKeys.viewInventory,
          child: SettingsRow(
            icon: AppIcons.inventory,
            tone: IconTileTone.info,
            title: 'View Inventory',
            subtitle: 'Check and manage stock',
            onTap: () {
              // §12.1: focus the app-wide active store on this store, then
              // open the Inventory tab (which now follows the nav-drawer
              // picker).
              final nav = ref.read(navigationProvider);
              nav.setLockedStore(widget.store.id);
              nav.setIndex(2);
            },
          ),
        ),
      ],
    );
  }
}
