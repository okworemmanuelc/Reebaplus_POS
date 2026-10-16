import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/crates/manufacturer_crate_position.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/inventory/widgets/buy_crates_sheet.dart';
import 'package:reebaplus_pos/features/inventory/widgets/count_manufacturer_empties_sheet.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_parts.dart';
import 'package:reebaplus_pos/features/inventory/widgets/manufacturer_settings_tab.dart';
import 'package:reebaplus_pos/features/inventory/widgets/record_damaged_crates_sheet.dart';
import 'package:reebaplus_pos/features/inventory/widgets/supplier_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/crate_shortage_write_off_sheet.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
import 'package:reebaplus_pos/shared/widgets/reverse_crate_write_off_sheet.dart';
import 'package:reebaplus_pos/shared/widgets/tabbed_sliver_scaffold.dart';

/// Read-only Manufacturer screen (#291, PRD #284 §5).
///
/// Opens by tapping any brand card on Inventory → Crates.
/// Built on [TabbedSliverScaffold] so the brand summary header scrolls away
/// cleanly and the [TabBar] pins under it across up to four tabs (Settings is
/// omitted for a role that can edit nothing on it, #295):
///   1. Crates — the six canonical statuses
///   2. Products — brand products with crate value
///   3. History — chronological crate ledger movements
class ManufacturerScreen extends ConsumerStatefulWidget {
  final ManufacturerData manufacturer;

  const ManufacturerScreen({super.key, required this.manufacturer});

  @override
  ConsumerState<ManufacturerScreen> createState() => _ManufacturerScreenState();
}

class _ManufacturerScreenState extends ConsumerState<ManufacturerScreen>
    with TickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  /// The Settings tab exists only for a role that can edit something on it, so
  /// the tab count follows the gates (#295).
  void _syncTabCount(int length) {
    if (_tabController.length == length) return;
    final previous = _tabController.index;
    // The old bar is still mounted during this build, so it's disposed once the
    // frame has swapped in the new controller.
    final old = _tabController;
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    _tabController = TabController(
      length: length,
      vsync: this,
      initialIndex: previous < length ? previous : 0,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Guarded.screen(
      gate: Gates.viewInventory,
      builder: (context) => _build(context),
      denied: Scaffold(
        appBar: AppBar(title: Text(widget.manufacturer.name)),
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
        appBar: AppBar(title: Text(widget.manufacturer.name)),
        body: const Center(
          child: Text(
            'Crate management is only available for businesses that track crates.',
          ),
        ),
      );
    }

    final mfrList = ref.watch(allManufacturersProvider).valueOrNull;
    final mfr =
        mfrList?.where((m) => m.id == widget.manufacturer.id).firstOrNull ??
        widget.manufacturer;

    final positionAsync = ref.watch(manufacturerCratePositionProvider(mfr.id));
    final position =
        positionAsync.valueOrNull ??
        ManufacturerCratePosition.zero(
          mfr.id,
          crateValueKobo: mfr.depositAmountKobo,
        );

    final attributionAsync = ref.watch(customerDepositAttributionProvider);
    final attribution =
        attributionAsync.valueOrNull ?? const CustomerDepositAttribution.zero();

    final products =
        ref.watch(manufacturerProductsProvider(mfr.id)).valueOrNull ??
        const <ProductDataWithStock>[];

    final movements =
        ref.watch(manufacturerCrateMovementsProvider(mfr.id)).valueOrNull ??
        const <CrateMovementHistoryEntry>[];

    final canSeeCustomerDepositMoney = Gates.crateDepositsReport.allows(ref);

    final theme = Theme.of(context);
    final showSettings = canEditManufacturerSettings(ref);
    _syncTabCount(showSettings ? 4 : 3);

    return Scaffold(
      key: const ValueKey(kManufacturerScreenKey),
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: InventoryTopBar(
        icon: AppIcons.manufacturer,
        title: mfr.name,
        subtitle: ref.watch(activeStoreLabelProvider),
        height: inventoryTopBarHeight(context),
        leading: IconButton(
          tooltip: 'Back',
          constraints: const BoxConstraints(
            minWidth: kMinInteractiveDimension,
            minHeight: kMinInteractiveDimension,
          ),
          icon: const Icon(AppIcons.arrowBack),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: const [InventoryLiveBell()],
      ),
      body: Container(
        decoration: AppDecorations.pageBackground(context),
        child: SafeArea(
          top: false,
          bottom: false,
          // A detail screen: the body caps at a fixed 960 and centres (#392).
          child: InventoryDetailColumn(
            child: TabbedSliverScaffold(
              controller: _tabController,
              // The hairline under the tab bar is reserved on top of the 48dp
              // floor, so every tab keeps its full target.
              tabBarExtent: kMinInteractiveDimension,
              tabBarChromeExtent: 1,
              headerSlivers: [
                SliverToBoxAdapter(
                  child: _buildHeader(
                    context,
                    theme,
                    mfr,
                    position,
                    canSeeCustomerDepositMoney,
                  ),
                ),
              ],
              tabBar: InventoryDetailTabBar(
                controller: _tabController,
                labels: [
                  'Crates',
                  'Products',
                  'History',
                  if (showSettings) 'Settings',
                ],
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
                    mfr,
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
                if (showSettings)
                  TabSliverView(
                    storageKey: kManufacturerSettingsStorageKey,
                    slivers: [
                      ManufacturerSettingsSlivers(
                        manufacturer: mfr,
                        position: position,
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The two header figures (#392): the crate value and the total crates with
  /// their value. Side by side when the measured width is at least 900,
  /// stacked below. Same figures as before, same deposit-money gate.
  Widget _buildHeader(
    BuildContext context,
    ThemeData theme,
    ManufacturerData mfr,
    ManufacturerCratePosition pos,
    bool canSeeCustomerDepositMoney,
  ) {
    final crateValueNaira = mfr.depositAmountKobo / 100;
    // Without the deposit gate, leave Customer deposit out of the total so it
    // can't be recovered by subtracting the visible status figures.
    final totalCrateValueKobo = canSeeCustomerDepositMoney
        ? pos.totalCrateValueKobo
        : pos.totalCrateValueKobo - pos.withCustomersOnDeposit.moneyKobo;
    final totalCrateValueNaira = totalCrateValueKobo / 100;
    final hasShort = pos.short.count > 0;

    return InventoryDetailHeaderCards(
      builders: [
        (compact) => InventoryDetailStatCard(
          compact: compact,
          icon: AppIcons.manufacturer,
          tone: IconTileTone.info,
          title: 'Crate value',
          value: formatCurrency(crateValueNaira),
          subtitle: 'Per crate',
        ),
        (compact) => InventoryDetailStatCard(
          compact: compact,
          icon: AppIcons.warehouse,
          tone: IconTileTone.green,
          title: 'Total crates',
          value: '${pos.totalCrates} crates',
          subtitle: '${formatCurrency(totalCrateValueNaira)} total value',
          pillLabel: hasShort ? '${pos.short.count} short' : null,
          pillTone: TagPillTone.warning,
        ),
      ],
    );
  }

  List<Widget> _cratesTabSlivers(
    BuildContext context,
    ThemeData theme,
    ManufacturerCratePosition pos,
    bool canSeeCustomerDepositMoney,
    CustomerDepositAttribution attribution,
    ManufacturerData mfr,
  ) {
    final canCount = Gates.countCrates.allows(ref);
    // Buy crates moves money out, so it stays with managers (#294). Hidden,
    // not disabled, for everyone else. Write off and Reverse turn a count into
    // profit, so they share the gate (#296).
    final canBuy = Gates.confirmCrateDeposit.allows(ref);
    final lockedStoreId = ref.watch(lockedStoreProvider).value;
    final shortage = ref.watch(crateShortageRollupProvider(lockedStoreId));
    final reversible =
        shortage.valueOrNull?.brand(mfr.id)?.reversibleCrates ?? 0;
    final f = theme.extension<AppFixedColors>() ?? AppFixedColors.light;
    return [
      if (canCount || canBuy)
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              context.getRSize(16),
              context.getRSize(8),
              context.getRSize(16),
              context.getRSize(4),
            ),
            // Wrap, not Row: two buttons can't fit side by side at 320dp.
            child: Wrap(
              spacing: context.getRSize(8),
              runSpacing: context.getRSize(8),
              children: [
                if (canCount)
                  AppButton(
                    key: const ValueKey(kManufacturerCountButtonKey),
                    text: 'Count',
                    icon: AppIcons.auditCheck,
                    variant: AppButtonVariant.primary,
                    isFullWidth: false,
                    onPressed: () => CountManufacturerEmptiesSheet.show(
                      context,
                      manufacturer: mfr,
                    ),
                  ),
                if (canCount)
                  AppButton(
                    key: const ValueKey(kManufacturerRecordDamagedButtonKey),
                    text: 'Record damaged',
                    icon: AppIcons.warning,
                    variant: AppButtonVariant.outline,
                    isFullWidth: false,
                    onPressed: () => RecordDamagedCratesSheet.show(
                      context,
                      manufacturer: mfr,
                    ),
                  ),
                if (canBuy)
                  AppButton(
                    key: const ValueKey(kBuyCratesButtonKey),
                    text: 'Buy crates',
                    icon: AppIcons.cartAdd,
                    variant: AppButtonVariant.outline,
                    isFullWidth: false,
                    onPressed: () =>
                        BuyCratesSheet.show(context, manufacturer: mfr),
                  ),
              ],
            ),
          ),
        ),
      SliverToBoxAdapter(child: SizedBox(height: context.getRSize(4))),
      SliverToBoxAdapter(
        child: _buildStatusCard(
          context: context,
          theme: theme,
          keySuffix: 'in_warehouse',
          title: 'In warehouse',
          countText: '${pos.inWarehouse.count} crates',
          moneyText: formatCurrency(pos.inWarehouse.moneyKobo / 100),
          icon: AppIcons.warehouse,
          tone: IconTileTone.info,
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
          icon: AppIcons.inventory,
          tone: IconTileTone.green,
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
          icon: AppIcons.settlement,
          tone: IconTileTone.malt,
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
          icon: AppIcons.customers,
          tone: IconTileTone.neutral,
        ),
      ),
      SliverToBoxAdapter(
        child: _buildStatusCard(
          context: context,
          theme: theme,
          keySuffix: 'short',
          title: 'Short',
          countText: '${pos.short.count} crates',
          moneyText: pos.short.count > 0
              ? formatCurrency(pos.short.moneyKobo / 100)
              : null,
          icon: AppIcons.warning,
          tone: IconTileTone.warning,
          countColor: pos.short.count > 0 ? f.warning : null,
          actions: [
            if (canBuy && pos.short.count > 0)
              AppButton(
                key: const ValueKey(kManufacturerWriteOffButtonKey),
                text: 'Write off',
                icon: AppIcons.removeCircle,
                variant: AppButtonVariant.danger,
                isFullWidth: false,
                onPressed: () => CrateShortageWriteOffSheet.show(
                  context,
                  manufacturerId: mfr.id,
                ),
              ),
            if (canBuy && reversible > 0)
              AppButton(
                key: const ValueKey(kManufacturerReverseWriteOffButtonKey),
                text: 'Reverse write-off',
                icon: AppIcons.refresh,
                variant: AppButtonVariant.outline,
                isFullWidth: false,
                onPressed: () => ReverseCrateWriteOffSheet.show(
                  context,
                  manufacturerId: mfr.id,
                ),
              ),
          ],
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
          icon: AppIcons.damaged,
          tone: IconTileTone.danger,
          countColor: pos.damaged.count > 0 ? f.danger : null,
        ),
      ),
      if (canSeeCustomerDepositMoney && attribution.unattributedKobo > 0)
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              context.getRSize(16),
              context.getRSize(12),
              context.getRSize(16),
              context.getRSize(4),
            ),
            child: InventoryNotice(
              key: const ValueKey(kManufacturerAttributionNoteKey),
              icon: AppIcons.infoCircle,
              tone: IconTileTone.info,
              message:
                  '${formatCurrency(attribution.unattributedKobo / 100)} customer deposit held across brands is not attributed to a specific manufacturer.',
            ),
          ),
        ),
      _bottomSpacer(context),
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
    required IconTileTone tone,
    Color? countColor,
    List<Widget> actions = const [],
  }) {
    return InventoryDetailRowCard(
      key: ValueKey(kManufacturerStatusKeyPrefix + keySuffix),
      icon: icon,
      tone: tone,
      title: title,
      subtitle: moneyText,
      trailing: Text(
        countText,
        style: context
            .extraBoldStyle(15)
            .copyWith(color: countColor ?? theme.colorScheme.onSurface),
      ),
      // Wrap, not Row: two buttons can't fit side by side at 320dp.
      footer: actions.isEmpty
          ? null
          : Wrap(
              spacing: context.getRSize(8),
              runSpacing: context.getRSize(8),
              children: actions,
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
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(context.getRSize(16)),
            child: const InventoryEmptyCard(
              icon: AppIcons.wineBottle,
              title: 'No products found for this manufacturer',
            ),
          ),
        ),
      ];
    }

    final crateValueText =
        'Crate: ${formatCurrency(mfr.depositAmountKobo / 100)}';

    return [
      SliverToBoxAdapter(child: SizedBox(height: context.getRSize(8))),
      SliverList(
        delegate: SliverChildBuilderDelegate((context, index) {
          final product = products[index].product;
          final detail = product.size?.isNotEmpty == true
              ? product.size
              : (product.subtitle?.isNotEmpty == true
                    ? product.subtitle
                    : null);
          return InventoryDetailRowCard(
            key: ValueKey('$kManufacturerProductKeyPrefix${product.id}'),
            icon: AppIcons.wineBottle,
            tone: IconTileTone.info,
            title: product.name,
            subtitle: detail,
            trailing: Text(
              crateValueText,
              style: context
                  .semiBoldStyle(12)
                  .copyWith(color: theme.colorScheme.primary),
            ),
          );
        }, childCount: products.length),
      ),
      _bottomSpacer(context),
    ];
  }

  List<Widget> _historyTabSlivers(
    BuildContext context,
    ThemeData theme,
    List<CrateMovementHistoryEntry> movements,
  ) {
    if (movements.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(context.getRSize(16)),
            child: const InventoryEmptyCard(
              icon: AppIcons.history,
              title: 'No crate movements recorded yet',
            ),
          ),
        ),
      ];
    }

    final dateFormat = DateFormat('MMM d, y • HH:mm');
    final f = theme.extension<AppFixedColors>() ?? AppFixedColors.light;

    return [
      SliverToBoxAdapter(child: SizedBox(height: context.getRSize(8))),
      SliverList(
        delegate: SliverChildBuilderDelegate((context, index) {
          final entry = movements[index];
          final delta = entry.quantityDelta;
          final isPositive = delta > 0;
          final deltaText = isPositive ? '+$delta crates' : '$delta crates';
          final deltaColor = isPositive ? f.green : f.danger;

          final details = [
            dateFormat.format(entry.createdAt),
            if (entry.performedByName?.isNotEmpty == true)
              'by ${entry.performedByName}',
            // A movement no store can be resolved for (e.g. an approved
            // return with no order) appears only under All Stores; say so.
            entry.storeName?.isNotEmpty == true ? entry.storeName! : 'No store',
          ].join(' • ');

          return InventoryDetailRowCard(
            key: ValueKey('$kManufacturerHistoryRowKeyPrefix${entry.id}'),
            icon: isPositive ? AppIcons.arrowDown : AppIcons.arrowUp,
            tone: isPositive ? IconTileTone.green : IconTileTone.danger,
            title: entry.movementLabel,
            subtitle: details,
            trailing: Text(
              deltaText,
              style: context.extraBoldStyle(13).copyWith(color: deltaColor),
            ),
          );
        }, childCount: movements.length),
      ),
      _bottomSpacer(context),
    ];
  }

  /// The end of a tab's list: 16 and the device bottom padding, so the last
  /// card clears the system navigation bar (the old spacer was 16 only).
  Widget _bottomSpacer(BuildContext context) => SliverToBoxAdapter(
    child: SizedBox(height: context.getRSize(16) + context.deviceBottomPadding),
  );
}
