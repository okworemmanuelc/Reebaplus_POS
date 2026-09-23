import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/crates/manufacturer_crate_position.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/tabbed_sliver_scaffold.dart';

/// Read-only Manufacturer screen (#291, PRD #284 §5).
///
/// Opens by tapping any brand card on Inventory → Crates.
/// Built on [TabbedSliverScaffold] so the brand summary header scrolls away
/// cleanly and the [TabBar] pins under it across three tabs:
///   1. Crates — the six canonical statuses
///   2. Products — brand products with crate value
///   3. History — chronological crate ledger movements
class ManufacturerScreen extends ConsumerStatefulWidget {
  final ManufacturerData manufacturer;

  const ManufacturerScreen({
    super.key,
    required this.manufacturer,
  });

  @override
  ConsumerState<ManufacturerScreen> createState() => _ManufacturerScreenState();
}

class _ManufacturerScreenState extends ConsumerState<ManufacturerScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  double get _tabBarBottomMargin => context.getRSize(8);
  static const double _tabBarBorderWidth = 1;
  double get _tabBarChromeExtent => _tabBarBottomMargin + 2 * _tabBarBorderWidth;

  @override
  Widget build(BuildContext context) {
    return Guarded.screen(
      gate: Gates.viewInventory,
      builder: (context) => _build(context),
      denied: Scaffold(
        appBar: AppBar(
          title: Text(widget.manufacturer.name),
        ),
        body: const Center(
          child: Text('You do not have permission to view inventory.'),
        ),
      ),
    );
  }

  Widget _build(BuildContext context) {
    final currentBusiness = ref.watch(currentBusinessProvider);
    final tracksCrates = businessTracksCrates(currentBusiness);

    if (!tracksCrates) {
      return Scaffold(
        key: const ValueKey(kManufacturerScreenKey),
        appBar: AppBar(
          title: Text(widget.manufacturer.name),
        ),
        body: const Center(
          child: Text('Crate management is only available for businesses that track crates.'),
        ),
      );
    }

    final mfrList = ref.watch(allManufacturersProvider).valueOrNull;
    final mfr = mfrList?.where((m) => m.id == widget.manufacturer.id).firstOrNull ??
        widget.manufacturer;

    final positionAsync = ref.watch(manufacturerCratePositionProvider(mfr.id));
    final position = positionAsync.valueOrNull ??
        ManufacturerCratePosition.zero(mfr.id, crateValueKobo: mfr.depositAmountKobo);

    final attributionAsync = ref.watch(customerDepositAttributionProvider);
    final attribution = attributionAsync.valueOrNull ??
        const CustomerDepositAttribution.zero();

    final products = ref.watch(manufacturerProductsProvider(mfr.id)).valueOrNull ??
        const <ProductDataWithStock>[];

    final movements = ref.watch(manufacturerCrateMovementsProvider(mfr.id)).valueOrNull ??
        const <CrateMovementHistoryEntry>[];

    final canSeeCustomerDepositMoney = Gates.crateDepositsReport.allows(ref);

    final theme = Theme.of(context);

    return Scaffold(
      key: const ValueKey(kManufacturerScreenKey),
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        bottom: false,
        child: TabbedSliverScaffold(
          controller: _tabController,
          tabBarExtent: context.getRSize(60),
          tabBarChromeExtent: _tabBarChromeExtent,
          headerSlivers: [
            SliverToBoxAdapter(
              child: _buildHeader(context, theme, mfr, position),
            ),
          ],
          tabBar: Container(
            color: Colors.transparent,
            padding: EdgeInsets.symmetric(horizontal: context.getRSize(16)),
            child: _buildTabBar(theme),
          ),
          tabViews: [
            TabSliverView(
              storageKey: kManufacturerCratesStorageKey,
              slivers: _cratesTabSlivers(
                context,
                theme,
                position,
                canSeeCustomerDepositMoney,
                attribution,
              ),
            ),
            TabSliverView(
              storageKey: kManufacturerProductsStorageKey,
              slivers: _productsTabSlivers(context, theme, products, mfr),
            ),
            TabSliverView(
              storageKey: kManufacturerHistoryStorageKey,
              slivers: _historyTabSlivers(context, theme, movements),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabBar(ThemeData theme) {
    return Container(
      margin: EdgeInsets.only(bottom: _tabBarBottomMargin),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.1),
          width: _tabBarBorderWidth,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: TabBar(
          controller: _tabController,
          indicatorSize: TabBarIndicatorSize.tab,
          indicatorPadding: EdgeInsets.all(context.getRSize(4)),
          indicator: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.3),
            ),
          ),
          labelColor: theme.colorScheme.primary,
          unselectedLabelColor: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          labelStyle: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: context.getRFontSize(13),
          ),
          unselectedLabelStyle: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: context.getRFontSize(13),
          ),
          dividerColor: Colors.transparent,
          tabs: const [
            Tab(text: 'Crates'),
            Tab(text: 'Products'),
            Tab(text: 'History'),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    ThemeData theme,
    ManufacturerData mfr,
    ManufacturerCratePosition pos,
  ) {
    final crateValueNaira = mfr.depositAmountKobo / 100;
    final totalCrateValueNaira = pos.totalCrateValueKobo / 100;
    final hasShort = pos.short.count > 0;

    return Container(
      margin: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(12),
        context.getRSize(16),
        context.getRSize(12),
      ),
      padding: EdgeInsets.all(context.getRSize(16)),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.15),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => Navigator.of(context).pop(),
              ),
              SizedBox(width: context.getRSize(12)),
              Container(
                width: context.getRSize(40),
                height: context.getRSize(40),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  FontAwesomeIcons.industry.data,
                  color: theme.colorScheme.secondary,
                  size: context.getRSize(16),
                ),
              ),
              SizedBox(width: context.getRSize(12)),
              Expanded(
                child: Text(
                  mfr.name,
                  style: TextStyle(
                    fontSize: context.getRFontSize(18),
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          SizedBox(height: context.getRSize(12)),
          Text(
            'Crate value: ${formatCurrency(crateValueNaira)}',
            style: TextStyle(
              fontSize: context.getRFontSize(13),
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          SizedBox(height: context.getRSize(4)),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${pos.totalCrates} crates • ${formatCurrency(totalCrateValueNaira)} total value',
                ),
                if (hasShort)
                  TextSpan(
                    text: ' • ${pos.short.count} short',
                    style: const TextStyle(
                      color: AppColors.warning,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
            style: TextStyle(
              fontSize: context.getRFontSize(12),
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _cratesTabSlivers(
    BuildContext context,
    ThemeData theme,
    ManufacturerCratePosition pos,
    bool canSeeCustomerDepositMoney,
    CustomerDepositAttribution attribution,
  ) {
    return [
      SliverToBoxAdapter(
        child: SizedBox(height: context.getRSize(8)),
      ),
      SliverToBoxAdapter(
        child: _buildStatusCard(
          context: context,
          theme: theme,
          keySuffix: 'in_warehouse',
          title: 'In warehouse',
          countText: '${pos.inWarehouse.count} crates',
          moneyText: formatCurrency(pos.inWarehouse.moneyKobo / 100),
          icon: FontAwesomeIcons.warehouse.data,
          iconColor: theme.colorScheme.primary,
        ),
      ),
      SliverToBoxAdapter(
        child: _buildStatusCard(
          context: context,
          theme: theme,
          keySuffix: 'full_in_stock',
          title: 'Full crates in stock',
          countText: '${pos.fullCratesInStock.count} crates',
          moneyText: formatCurrency(pos.fullCratesInStock.moneyKobo / 100),
          icon: FontAwesomeIcons.boxesStacked.data,
          iconColor: AppColors.success,
        ),
      ),
      SliverToBoxAdapter(
        child: _buildStatusCard(
          context: context,
          theme: theme,
          keySuffix: 'with_customers_deposit',
          title: 'With customers on deposit',
          countText: '${pos.withCustomersOnDeposit.count} crates',
          moneyText: canSeeCustomerDepositMoney
              ? formatCurrency(pos.withCustomersOnDeposit.moneyKobo / 100)
              : null,
          icon: FontAwesomeIcons.handHoldingDollar.data,
          iconColor: Colors.teal,
        ),
      ),
      SliverToBoxAdapter(
        child: _buildStatusCard(
          context: context,
          theme: theme,
          keySuffix: 'with_customers_no_deposit',
          title: 'With customers no deposit',
          countText: '${pos.withCustomersNoDeposit.count} crates',
          moneyText: formatCurrency(pos.withCustomersNoDeposit.moneyKobo / 100),
          icon: FontAwesomeIcons.users.data,
          iconColor: Colors.deepPurple,
        ),
      ),
      SliverToBoxAdapter(
        child: _buildStatusCard(
          context: context,
          theme: theme,
          keySuffix: 'short',
          title: 'Short',
          countText: '${pos.short.count} crates',
          moneyText: null,
          icon: FontAwesomeIcons.triangleExclamation.data,
          iconColor: AppColors.warning,
          countColor: pos.short.count > 0 ? AppColors.warning : null,
        ),
      ),
      SliverToBoxAdapter(
        child: _buildStatusCard(
          context: context,
          theme: theme,
          keySuffix: 'damaged',
          title: 'Damaged',
          countText: '${pos.damaged.count} crates',
          moneyText: formatCurrency(pos.damaged.moneyKobo / 100),
          icon: FontAwesomeIcons.heartCrack.data,
          iconColor: theme.colorScheme.error,
          countColor: pos.damaged.count > 0 ? theme.colorScheme.error : null,
        ),
      ),
      if (canSeeCustomerDepositMoney && attribution.unattributedKobo > 0)
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              context.getRSize(16),
              context.getRSize(12),
              context.getRSize(16),
              context.getRSize(16),
            ),
            child: Container(
              key: const ValueKey(kManufacturerAttributionNoteKey),
              padding: EdgeInsets.all(context.getRSize(12)),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.15),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: context.getRSize(16),
                    color: theme.colorScheme.primary,
                  ),
                  SizedBox(width: context.getRSize(8)),
                  Expanded(
                    child: Text(
                      '${formatCurrency(attribution.unattributedKobo / 100)} customer deposit held across brands is not attributed to a specific manufacturer.',
                      style: TextStyle(
                        fontSize: context.getRFontSize(11),
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      SliverToBoxAdapter(
        child: SizedBox(height: context.getRSize(16)),
      ),
    ];
  }

  Widget _buildStatusCard({
    required BuildContext context,
    required ThemeData theme,
    required String keySuffix,
    required String title,
    required String countText,
    String? moneyText,
    required IconData icon,
    required Color iconColor,
    Color? countColor,
  }) {
    return Container(
      key: ValueKey(kManufacturerStatusKeyPrefix + keySuffix),
      margin: EdgeInsets.symmetric(
        horizontal: context.getRSize(16),
        vertical: context.getRSize(5),
      ),
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.12),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: context.getRSize(40),
            height: context.getRSize(40),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: context.getRSize(16)),
          ),
          SizedBox(width: context.getRSize(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: context.getRFontSize(14),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (moneyText != null) ...[
                  SizedBox(height: context.getRSize(2)),
                  Text(
                    moneyText,
                    style: TextStyle(
                      fontSize: context.getRFontSize(12),
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(width: context.getRSize(8)),
          Text(
            countText,
            style: TextStyle(
              fontSize: context.getRFontSize(15),
              fontWeight: FontWeight.w800,
              color: countColor ?? theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _productsTabSlivers(
    BuildContext context,
    ThemeData theme,
    List<ProductDataWithStock> products,
    ManufacturerData mfr,
  ) {
    if (products.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(context.getRSize(32)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    FontAwesomeIcons.wineBottle.data,
                    size: context.getRSize(40),
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
                  ),
                  SizedBox(height: context.getRSize(12)),
                  Text(
                    'No products found for this manufacturer',
                    style: TextStyle(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      fontSize: context.getRFontSize(13),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ];
    }

    final crateValueText = 'Crate: ${formatCurrency(mfr.depositAmountKobo / 100)}';

    return [
      SliverToBoxAdapter(
        child: SizedBox(height: context.getRSize(8)),
      ),
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final product = products[index].product;
            return Container(
              key: ValueKey('$kManufacturerProductKeyPrefix${product.id}'),
              margin: EdgeInsets.symmetric(
                horizontal: context.getRSize(16),
                vertical: context.getRSize(5),
              ),
              padding: EdgeInsets.all(context.getRSize(14)),
              decoration: BoxDecoration(
                color: theme.cardColor,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: theme.dividerColor.withValues(alpha: 0.12),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: context.getRSize(36),
                    height: context.getRSize(36),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      FontAwesomeIcons.wineBottle.data,
                      color: theme.colorScheme.primary,
                      size: context.getRSize(14),
                    ),
                  ),
                  SizedBox(width: context.getRSize(12)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          product.name,
                          style: TextStyle(
                            fontSize: context.getRFontSize(14),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (product.size?.isNotEmpty == true || product.subtitle?.isNotEmpty == true) ...[
                          SizedBox(height: context.getRSize(2)),
                          Text(
                            product.size?.isNotEmpty == true
                                ? product.size!
                                : product.subtitle!,
                            style: TextStyle(
                              fontSize: context.getRFontSize(11),
                              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  SizedBox(width: context.getRSize(8)),
                  Text(
                    crateValueText,
                    style: TextStyle(
                      fontSize: context.getRFontSize(12),
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
            );
          },
          childCount: products.length,
        ),
      ),
      SliverToBoxAdapter(
        child: SizedBox(height: context.getRSize(16)),
      ),
    ];
  }

  List<Widget> _historyTabSlivers(
    BuildContext context,
    ThemeData theme,
    List<CrateMovementHistoryEntry> movements,
  ) {
    if (movements.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(context.getRSize(32)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    FontAwesomeIcons.clockRotateLeft.data,
                    size: context.getRSize(40),
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
                  ),
                  SizedBox(height: context.getRSize(12)),
                  Text(
                    'No crate movements recorded yet',
                    style: TextStyle(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      fontSize: context.getRFontSize(13),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ];
    }

    final dateFormat = DateFormat('MMM d, y • HH:mm');

    return [
      SliverToBoxAdapter(
        child: SizedBox(height: context.getRSize(8)),
      ),
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final entry = movements[index];
            final delta = entry.quantityDelta;
            final isPositive = delta > 0;
            final deltaText = isPositive ? '+$delta crates' : '$delta crates';
            final deltaColor = isPositive ? AppColors.success : theme.colorScheme.error;

            final details = [
              dateFormat.format(entry.createdAt),
              if (entry.performedByName?.isNotEmpty == true) 'by ${entry.performedByName}',
              if (entry.storeName?.isNotEmpty == true) entry.storeName!,
            ].join(' • ');

            return Container(
              key: ValueKey('$kManufacturerHistoryRowKeyPrefix${entry.id}'),
              margin: EdgeInsets.symmetric(
                horizontal: context.getRSize(16),
                vertical: context.getRSize(5),
              ),
              padding: EdgeInsets.all(context.getRSize(14)),
              decoration: BoxDecoration(
                color: theme.cardColor,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: theme.dividerColor.withValues(alpha: 0.12),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: context.getRSize(36),
                    height: context.getRSize(36),
                    decoration: BoxDecoration(
                      color: (isPositive ? AppColors.success : theme.colorScheme.error)
                          .withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      isPositive
                          ? FontAwesomeIcons.arrowDown.data
                          : FontAwesomeIcons.arrowUp.data,
                      color: isPositive ? AppColors.success : theme.colorScheme.error,
                      size: context.getRSize(14),
                    ),
                  ),
                  SizedBox(width: context.getRSize(12)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.movementLabel,
                          style: TextStyle(
                            fontSize: context.getRFontSize(14),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: context.getRSize(2)),
                        Text(
                          details,
                          style: TextStyle(
                            fontSize: context.getRFontSize(11),
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: context.getRSize(8)),
                  Text(
                    deltaText,
                    style: TextStyle(
                      fontSize: context.getRFontSize(13),
                      fontWeight: FontWeight.w800,
                      color: deltaColor,
                    ),
                  ),
                ],
              ),
            );
          },
          childCount: movements.length,
        ),
      ),
      SliverToBoxAdapter(
        child: SizedBox(height: context.getRSize(16)),
      ),
    ];
  }
}
