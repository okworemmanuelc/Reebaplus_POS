import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/crates/crate_deposit_ledger_types.dart';
import 'package:reebaplus_pos/core/crates/crate_money_arrangement.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_parts.dart';
import 'package:reebaplus_pos/features/inventory/widgets/supplier_parts.dart';
import 'package:reebaplus_pos/features/payments/widgets/record_supplier_activity.dart';
import 'package:reebaplus_pos/features/payments/widgets/supplier_form_sheet.dart';
import 'package:reebaplus_pos/features/payments/widgets/supplier_ledger_entry_tile.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
import 'package:reebaplus_pos/shared/widgets/tabbed_sliver_scaffold.dart';

/// Key prefix on every ledger row, followed by the entry id. The test seam for
/// "at least one complete ledger row is laid out and hit-testable" (PRD #239).
const String kSupplierLedgerRowKeyPrefix = 'supplier-ledger-row-';

/// Scroll-position identities: each surface keeps its place across tab
/// switches. The Ledger key is shared by both shapes of the screen — the
/// tabbed Ledger tab and the single scroll view a business without crate
/// tracking gets — so one finder addresses the ledger either way.
const String kSupplierLedgerStorageKey = 'supplier-detail-ledger';
const String kSupplierCratesStorageKey = 'supplier-detail-crates';

/// §21.3 / §21.10 — Supplier Details on real ledger data. Balance =
/// SUM(payments) − SUM(invoices); negative (red) = we owe the supplier.
class SupplierDetailScreen extends ConsumerStatefulWidget {
  final String supplierId;

  /// The period the ledger opens on. Always the §30.6 default in the app; a
  /// test passes an unbounded period so a golden never depends on today's date.
  @visibleForTesting
  final String initialTimeFilter;

  const SupplierDetailScreen({
    super.key,
    required this.supplierId,
    this.initialTimeFilter = 'This Month',
  });

  @override
  ConsumerState<SupplierDetailScreen> createState() =>
      _SupplierDetailScreenState();
}

class _SupplierDetailScreenState extends ConsumerState<SupplierDetailScreen>
    with SingleTickerProviderStateMixin {
  late String _timeFilter; // §30.6/§30.11 default: 'This Month'
  DateTimeRange? _customRange;

  /// Ledger + Empty Crates. Only read when the business tracks crates; the
  /// other shape has no tabs at all.
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _timeFilter = widget.initialTimeFilter;
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  List<String> get _periodOptions => datePeriodLabelsForRole(
    managerUp: Gates.seeExtendedDateRanges.allows(ref),
  );

  String get _effectivePeriod {
    final isCustom = _timeFilter.startsWith('Custom:');
    final dropdownValue = isCustom ? 'Custom' : _timeFilter;
    return _periodOptions.contains(dropdownValue)
        ? dropdownValue
        : _periodOptions.first;
  }

  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;

  // Helpers for initials
  String _initials(String name) {
    final parts = name.trim().split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider);
    final theme = Theme.of(context);
    final f = theme.extension<AppFixedColors>() ?? AppFixedColors.light;
    final canManage = Gates.manageSuppliers.allows(ref);
    final isCeo = ref.watch(currentUserRoleProvider)?.slug == 'ceo';
    final supplierAsync = ref.watch(supplierByIdProvider(widget.supplierId));
    final supplier = supplierAsync.valueOrNull;

    final showCrates = businessTracksCrates(ref.watch(currentBusinessProvider));

    Widget content;
    if (!canManage) {
      content = Center(
        child: Text(
          'You don’t have access to Supplier Accounts.',
          style: context.regularStyle(14).copyWith(color: _subtext),
        ),
      );
    } else if (supplier == null) {
      content = supplierAsync.isLoading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: Text(
                'Supplier not found',
                style: context.regularStyle(14).copyWith(color: _subtext),
              ),
            );
    } else {
      content = _buildBody(context, theme, supplier, showCrates);
    }

    return ColoredBox(
      color: _bg,
      child: Container(
        decoration: AppDecorations.pageBackground(context),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          // Solid Surface bar with a hairline, as every redesigned screen
          // (#392); it no longer tints on scroll.
          appBar: InventoryTopBar(
            icon: AppIcons.supplier,
            title: 'Supplier Details',
            subtitle: supplier?.name,
            height: inventoryTopBarHeight(context),
            leading: IconButton(
              tooltip: 'Back',
              constraints: const BoxConstraints(
                minWidth: kMinInteractiveDimension,
                minHeight: kMinInteractiveDimension,
              ),
              icon: const Icon(AppIcons.arrowBack),
              onPressed: () => Navigator.pop(context),
            ),
            actions: [
              if (isCeo && supplier != null)
                InventoryBarAction(
                  icon: AppIcons.edit,
                  tooltip: 'Edit supplier',
                  onPressed: () =>
                      SupplierFormSheet.show(context, existing: supplier),
                ),
              if (isCeo && supplier != null)
                IconButton(
                  tooltip: 'Delete supplier',
                  constraints: const BoxConstraints(
                    minWidth: kMinInteractiveDimension,
                    minHeight: kMinInteractiveDimension,
                  ),
                  icon: AppIcon(
                    AppIcons.delete,
                    size: context.getRSize(20),
                    color: f.danger,
                  ),
                  onPressed: () => _confirmDelete(supplier),
                ),
            ],
          ),
          // A detail screen: the body caps at a fixed 960 and centres.
          body: SafeArea(
            top: false,
            bottom: false,
            child: InventoryDetailColumn(child: content),
          ),
          floatingActionButton: (canManage && supplier != null)
              ? AppFAB(
                  heroTag: 'supplier_record_fab',
                  onPressed: () => showSupplierActivityChooser(
                    context,
                    supplierId: supplier.id,
                    supplierName: supplier.name,
                  ),
                  icon: AppIcons.add,
                  label: 'Record Activity',
                )
              : null,
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    ThemeData theme,
    SupplierData supplier,
    bool showCrates,
  ) {
    final balanceAsync = ref.watch(supplierBalanceProvider(widget.supplierId));
    final historyAsync = ref.watch(
      supplierLedgerHistoryProvider(widget.supplierId),
    );
    final balanceKobo = balanceAsync.valueOrNull ?? 0;
    final history =
        historyAsync.valueOrNull ?? const <SupplierLedgerEntryData>[];

    final scopeLabel = ref.watch(activeStoreLabelProvider);
    final isAllStores = ref.watch(lockedStoreProvider).value == null;
    final stores =
        ref.watch(allStoresProvider).valueOrNull ?? const <StoreData>[];
    final storeNameById = {for (final s in stores) s.id: s.name};

    final filtered = history
        .where((e) => isDateInPeriod(e.activityDate, _timeFilter))
        .toList();

    // The profile card and the balance card sit side by side when the
    // measured width is at least 900, stacked below (#392).
    final headerSlivers = [
      SliverToBoxAdapter(
        child: InventoryDetailHeaderCards(
          builders: [
            (_) => _buildHeader(context, theme, supplier),
            (_) => _buildBalanceCard(context, theme, balanceKobo, scopeLabel),
          ],
        ),
      ),
    ];
    final ledgerSlivers = _ledgerSlivers(
      context,
      theme,
      filtered,
      supplier,
      isAllStores ? storeNameById : null,
    );

    // No tabs to pin, so one scroll view carries the whole screen. Same
    // storage key as the tabbed shape's Ledger tab.
    if (!showCrates) {
      return CustomScrollView(
        key: const PageStorageKey<String>(kSupplierLedgerStorageKey),
        slivers: [
          ...headerSlivers,
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                context.getRSize(16),
                context.getRSize(8),
                context.getRSize(16),
                context.getRSize(4),
              ),
              child: const SectionHeader(title: 'Activity Ledger'),
            ),
          ),
          ...ledgerSlivers,
        ],
      );
    }

    return TabbedSliverScaffold(
      controller: _tabController,
      // The hairline under the tab bar is reserved on top of the 48dp floor,
      // so every tab keeps its full tap target.
      tabBarExtent: kMinInteractiveDimension,
      tabBarChromeExtent: 1,
      headerSlivers: headerSlivers,
      tabBar: InventoryDetailTabBar(
        controller: _tabController,
        labels: const ['Ledger', 'Empty Crates'],
      ),
      tabViews: [
        TabSliverView(
          storageKey: kSupplierLedgerStorageKey,
          slivers: ledgerSlivers,
        ),
        TabSliverView(
          storageKey: kSupplierCratesStorageKey,
          slivers: _cratesTabSlivers(context, theme),
        ),
      ],
    );
  }

  /// The supplier's profile card (#392): initials tile, name and the contact,
  /// address, bank and notes lines (each only when there is something to say).
  Widget _buildHeader(BuildContext context, ThemeData theme, SupplierData s) {
    final f = theme.extension<AppFixedColors>() ?? AppFixedColors.light;
    return Container(
      padding: EdgeInsets.all(context.getRSize(16)),
      decoration: AppDecorations.card(context),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: context.getRSize(56),
            height: context.getRSize(56),
            decoration: BoxDecoration(
              color: f.infoTint,
              borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
            ),
            alignment: Alignment.center,
            child: Text(
              _initials(s.name),
              style: context.extraBoldStyle(20).copyWith(color: f.info),
            ),
          ),
          SizedBox(width: context.getRSize(14)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  s.name,
                  style: context.extraBoldStyle(18).copyWith(color: _text),
                ),
                if ((s.phone ?? '').isNotEmpty ||
                    (s.address ?? '').isNotEmpty) ...[
                  SizedBox(height: context.getRSize(8)),
                  _InfoRow(
                    icon: AppIcons.phone,
                    text: [
                      if ((s.phone ?? '').isNotEmpty) s.phone!,
                      if ((s.email ?? '').isNotEmpty) s.email!,
                    ].join(' • '),
                    theme: theme,
                  ),
                ],
                if ((s.address ?? '').isNotEmpty && s.address != 'N/A') ...[
                  SizedBox(height: context.getRSize(4)),
                  _InfoRow(
                    icon: AppIcons.location,
                    text: s.address!,
                    theme: theme,
                  ),
                ],
                if ((s.bankName ?? '').isNotEmpty ||
                    (s.bankAccountNumber ?? '').isNotEmpty) ...[
                  SizedBox(height: context.getRSize(4)),
                  _InfoRow(
                    icon: AppIcons.bank,
                    text: [
                      if ((s.bankName ?? '').isNotEmpty) s.bankName!,
                      if ((s.bankAccountNumber ?? '').isNotEmpty)
                        s.bankAccountNumber!,
                      if ((s.bankAccountName ?? '').isNotEmpty)
                        s.bankAccountName!,
                    ].join(' • '),
                    theme: theme,
                  ),
                ],
                if ((s.notes ?? '').isNotEmpty) ...[
                  SizedBox(height: context.getRSize(6)),
                  Text(
                    s.notes!,
                    style: context
                        .regularStyle(12)
                        .copyWith(color: _subtext, fontStyle: FontStyle.italic),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The balance card (#392): the label, the figure (red when we owe, green
  /// when paid in advance), the scope and the period selector. Same maths as
  /// before: Balance = SUM(payments) - SUM(invoices).
  Widget _buildBalanceCard(
    BuildContext context,
    ThemeData theme,
    int balanceKobo,
    String scopeLabel,
  ) {
    final f = theme.extension<AppFixedColors>() ?? AppFixedColors.light;
    final owed = balanceKobo < 0;
    final color = owed ? f.danger : (balanceKobo > 0 ? f.green : _text);
    // Positive = we paid the supplier in advance (a prepayment), not credit we
    // hold on their behalf; negative = a debt we owe for unpaid goods.
    final label = owed
        ? 'Amount owed to supplier'
        : (balanceKobo > 0 ? 'Paid in advance' : 'Settled');

    return Container(
      padding: EdgeInsets.all(context.getRSize(16)),
      decoration: AppDecorations.card(context),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    IconTile(
                      icon: AppIcons.creditBalance,
                      tone: owed
                          ? IconTileTone.danger
                          : (balanceKobo > 0
                                ? IconTileTone.green
                                : IconTileTone.neutral),
                      size: 32,
                    ),
                    SizedBox(width: context.getRSize(8)),
                    // Wraps rather than pushing past the card edge: next to
                    // the period selector a 320dp phone leaves this label
                    // ~135dp, short of "Amount owed to supplier".
                    Flexible(
                      child: Text(
                        label,
                        style: context
                            .semiBoldStyle(12)
                            .copyWith(color: _subtext),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: context.getRSize(8)),
                Text(
                  formatCurrency(balanceKobo.abs() / 100),
                  style: context.extraBoldStyle(26).copyWith(color: color),
                ),
                SizedBox(height: context.getRSize(2)),
                Text(
                  scopeLabel,
                  style: context.semiBoldStyle(12).copyWith(color: _subtext),
                ),
              ],
            ),
          ),
          SizedBox(width: context.getRSize(8)),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'Period:',
                style: context.semiBoldStyle(11).copyWith(color: _subtext),
              ),
              SizedBox(height: context.getRSize(4)),
              SizedBox(
                width: 120,
                child: AppDropdown<String>(
                  value: _effectivePeriod,
                  isExpanded: false,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: context.getRSize(8),
                    vertical: context.getRSize(6),
                  ),
                  items: _periodOptions
                      .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                      .toList(),
                  onChanged: (v) async {
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
                          _timeFilter =
                              'Custom:${range.start.toIso8601String()}:${range.end.toIso8601String()}';
                        });
                      }
                    } else if (v != null) {
                      setState(() {
                        _timeFilter = v;
                        _customRange = null;
                      });
                    }
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLedgerSummaryRow(
    ThemeData theme,
    List<SupplierLedgerEntryData> filteredHistory,
  ) {
    final f = theme.extension<AppFixedColors>() ?? AppFixedColors.light;
    int totalInKobo = 0, totalOutKobo = 0;
    for (final entry in filteredHistory) {
      if (entry.voidedAt != null) continue;
      if (entry.referenceType == 'void') continue;

      if (entry.signedAmountKobo >= 0) {
        totalInKobo += entry.signedAmountKobo;
      } else {
        totalOutKobo += entry.signedAmountKobo.abs();
      }
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(4),
        context.getRSize(16),
        0,
      ),
      child: Row(
        children: [
          Expanded(
            child: SupplierTotalTile(
              icon: AppIcons.arrowDown,
              tone: IconTileTone.green,
              label: 'Total In',
              value: formatCurrency(totalInKobo / 100.0),
              valueColor: f.green,
            ),
          ),
          SizedBox(width: context.getRSize(10)),
          Expanded(
            child: SupplierTotalTile(
              icon: AppIcons.arrowUp,
              tone: IconTileTone.danger,
              label: 'Total Out',
              value: formatCurrency(totalOutKobo / 100.0),
              valueColor: f.danger,
            ),
          ),
        ],
      ),
    );
  }

  /// The ledger as slivers: the Total In / Total Out strip scrolls with the
  /// rows rather than sitting as a fixed band above them (PRD #239).
  List<Widget> _ledgerSlivers(
    BuildContext context,
    ThemeData theme,
    List<SupplierLedgerEntryData> entries,
    SupplierData supplier,
    Map<String, String>? storeNameById,
  ) {
    final summaryRow = SliverToBoxAdapter(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildLedgerSummaryRow(theme, entries),
          SizedBox(height: context.getRSize(4)),
        ],
      ),
    );

    if (entries.isEmpty) {
      return [
        summaryRow,
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(context.getRSize(16)),
            child: const InventoryEmptyCard(
              icon: AppIcons.bill,
              title: 'No activity in this period',
            ),
          ),
        ),
      ];
    }

    final isCeo = ref.watch(currentUserRoleProvider)?.slug == 'ceo';
    return [
      summaryRow,
      SliverPadding(
        padding: EdgeInsets.fromLTRB(
          context.getRSize(16),
          context.getRSize(8),
          context.getRSize(16),
          context.getRSize(96) + context.deviceBottomPadding,
        ),
        sliver: SliverList.builder(
          itemCount: entries.length,
          itemBuilder: (ctx, i) {
            final e = entries[i];
            return SupplierLedgerEntryTile(
              key: ValueKey('$kSupplierLedgerRowKeyPrefix${e.id}'),
              entry: e,
              onTap: isCeo ? () => _showEntryActions(supplier, e) : null,
              storeName: storeNameById == null
                  ? null
                  : (storeNameById[e.storeId] ??
                        (e.storeId == null ? 'Unassigned' : null)),
            );
          },
        ),
      ),
    ];
  }

  /// §3.13 — real per-supplier empty-crate tracking. Mirrors the customer
  /// Crates tab: a positive per-manufacturer balance = WE owe the supplier that
  /// many empties (for the full crates they delivered); negative = a crate
  /// credit. The deposit we paid for crates we keep is surfaced as the
  /// refundable "deposit held by supplier" figure.
  List<Widget> _cratesTabSlivers(BuildContext context, ThemeData theme) {
    final supplierAsync = ref.watch(supplierByIdProvider(widget.supplierId));
    final supplier = supplierAsync.valueOrNull;
    final canManage = Gates.manageSuppliers.allows(ref);
    final balances =
        ref
            .watch(supplierCrateBalancesProvider(widget.supplierId))
            .valueOrNull ??
        const <SupplierCrateBalanceWithManufacturer>[];
    final totalOwed = balances.fold<int>(0, (sum, b) => sum + b.balance);
    // Refundable deposit value = the per-manufacturer deposit rate applied to the
    // crates we still owe (positive balances). Always consistent with the crate
    // balance — returning crates lowers it automatically (§3.13 / the deposit the
    // store pays the supplier for empty crates).
    final depositValueKobo = balances.fold<int>(
      0,
      (sum, b) => sum + (b.balance > 0 ? b.balance * b.depositRateKobo : 0),
    );
    final active = balances.where((b) => b.balance != 0).toList();
    final totals =
        ref
            .watch(supplierCrateMovementTotalsProvider(widget.supplierId))
            .valueOrNull ??
        (received: 0, returned: 0);

    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(
          context.getRSize(16),
          context.getRSize(8),
          context.getRSize(16),
          context.getRSize(96) + context.deviceBottomPadding,
        ),
        sliver: SliverList.list(
          children: [
            if (canManage && supplier != null) ...[
              _buildCrateActionCard(theme, supplier),
              SizedBox(height: context.getRSize(12)),
              // #214 — the standing-float door. Only a brand on `standing_float`
              // has money that moves on nothing but a real top-up or payout, so
              // this card simply is not there for a business without one, which is
              // every business until an owner switches a brand over.
              if (_floatBrands().isNotEmpty) ...[
                _buildFloatActionCard(theme, supplier),
                SizedBox(height: context.getRSize(12)),
              ],
            ],
            _buildCrateSummaryCard(theme, totalOwed, depositValueKobo),
            SizedBox(height: context.getRSize(12)),
            _buildCrateMovementStats(theme, totals.received, totals.returned),
            SizedBox(height: context.getRSize(16)),
            // #212 (PRD #203, ADR 0023 rules 1 + 2) — what this supplier is
            // actually holding of the owner's money, per brand. Renders nothing at
            // all for a business whose brands are all on the default `none`
            // arrangement, which is every business until an owner switches one on.
            ..._buildPlacedDepositSection(context, theme),
            const SectionHeader(title: 'By manufacturer'),
            SizedBox(height: context.getRSize(8)),
            if (active.isEmpty)
              const InventoryEmptyCard(
                icon: AppIcons.box,
                title: 'No crate activity recorded with this supplier',
              )
            else
              ...active.map((b) => _buildSupplierCrateRow(theme, b)),
          ],
        ),
      ),
    ];
  }

  /// **Money this supplier is holding for us** (#212, ADR 0023 rule 1) — the
  /// Placed Deposit, per brand, plus anything still waiting on a manager and
  /// the brand-level crate shortfall behind it.
  ///
  /// Every figure comes from `computeCrateDepositPosition`, the one pure seam,
  /// so this section and the #215 business-wide card cannot disagree.
  ///
  /// It is deliberately SEPARATE from the "Deposit value (refundable)" tile
  /// above, which is the NOTIONAL figure — crates owed × today's rate. ADR 0023
  /// finding #3 is that those two numbers have never met; showing both, side by
  /// side and labelled, is the honest fix. Making one silently overwrite the
  /// other would only hide the disagreement.
  ///
  /// Empty for a brand on `none`: the position is all zeros there by
  /// construction, so an all-`none` business sees this whole section vanish and
  /// the screen reads exactly as it did before PRD #203.
  List<Widget> _buildPlacedDepositSection(
    BuildContext context,
    ThemeData theme,
  ) {
    final f = theme.extension<AppFixedColors>() ?? AppFixedColors.light;
    final positions =
        ref
            .watch(supplierCrateDepositPositionsProvider(widget.supplierId))
            .valueOrNull ??
        const <SupplierCrateDepositPosition>[];
    final live = positions
        .where(
          (p) =>
              p.position.movesMoney &&
              (p.position.placedDepositKobo != 0 || p.position.hasPending),
        )
        .toList();
    if (live.isEmpty) return const [];

    final totalPlaced = live.fold<int>(
      0,
      (s, p) => s + p.position.placedDepositKobo,
    );
    final totalPending = live.fold<int>(
      0,
      (s, p) => s + p.position.pendingDepositKobo,
    );

    return [
      const SectionHeader(
        title: 'Your money with this supplier',
        subtitle:
            'Deposits you have actually paid for their crates. It is still '
            'yours — you get it back when the empties go home.',
      ),
      SizedBox(height: context.getRSize(12)),
      Container(
        padding: EdgeInsets.all(context.getRSize(16)),
        decoration: AppDecorations.card(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Held by this supplier',
                    style: context.semiBoldStyle(12).copyWith(color: _subtext),
                  ),
                ),
                Text(
                  formatCurrency(totalPlaced / 100),
                  style: context.extraBoldStyle(18).copyWith(color: _text),
                ),
              ],
            ),
            if (totalPending != 0) ...[
              SizedBox(height: context.getRSize(6)),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Awaiting confirmation',
                      style: context
                          .semiBoldStyle(12)
                          .copyWith(color: _subtext),
                    ),
                  ),
                  Text(
                    formatCurrency(totalPending / 100),
                    style: context.boldStyle(14).copyWith(color: f.warning),
                  ),
                ],
              ),
            ],
            SizedBox(height: context.getRSize(10)),
            Divider(height: 1, color: theme.dividerColor),
            SizedBox(height: context.getRSize(10)),
            ...live.map(
              (p) => Padding(
                padding: EdgeInsets.symmetric(vertical: context.getRSize(4)),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            p.manufacturerName,
                            style: context
                                .semiBoldStyle(13)
                                .copyWith(color: _text),
                          ),
                          // Deliberately NOT a shortfall line. A shortfall is
                          // brand-level across every supplier (ADR 0023 rule
                          // 4); printing it on a per-supplier card would show
                          // the same missing crates twice and imply this depot
                          // is the one who lost them. #215 carries it, once,
                          // business-wide. What belongs here is how much of
                          // this supplier's crate debt carries no money.
                          if (p.position.unbackedCrates > 0)
                            Text(
                              '${p.position.unbackedCrates} crate'
                              '${p.position.unbackedCrates == 1 ? '' : 's'} '
                              'with no deposit paid',
                              style: context
                                  .regularStyle(12)
                                  .copyWith(color: _subtext),
                            ),
                        ],
                      ),
                    ),
                    Text(
                      formatCurrency(p.position.placedDepositKobo / 100),
                      style: context.boldStyle(13).copyWith(color: _text),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      SizedBox(height: context.getRSize(16)),
    ];
  }

  // The "+" action card pinned at the top of the Crates tab (§3.13).
  Widget _buildCrateActionCard(ThemeData theme, SupplierData supplier) {
    return SettingsRow(
      icon: AppIcons.inventory,
      tone: IconTileTone.info,
      title: 'Record crate activity',
      subtitle: 'Crates received from / returned to this supplier',
      onTap: () => _showRecordCrateSheet(supplier),
    );
  }

  /// Every brand on the `standing_float` arrangement (#214). Empty for every
  /// business until an owner deliberately switches one over, which is what
  /// keeps this whole surface invisible on a live tenant.
  List<ManufacturerData> _floatBrands() {
    final all =
        ref.watch(allManufacturersProvider).valueOrNull ??
        const <ManufacturerData>[];
    return all
        .where(
          (m) =>
              crateMoneyArrangementOf(m.crateMoneyArrangement) ==
              CrateMoneyArrangement.standingFloat,
        )
        .toList();
  }

  /// **The only door a standing float's money has** (#214, ADR 0023 rules 1
  /// and 4). Deliveries, hand-backs and missing crates all leave it alone; a
  /// top-up and a payout are the two times real cash changes hands, and this
  /// is where they are recorded.
  Widget _buildFloatActionCard(ThemeData theme, SupplierData supplier) {
    return SettingsRow(
      icon: AppIcons.transfer,
      tone: IconTileTone.green,
      title: 'Crate float money',
      subtitle:
          'Top up what this supplier holds, or record money they paid back',
      onTap: () => _showFloatMoneySheet(supplier),
    );
  }

  /// Record a standing-float top-up or payout (#214).
  ///
  /// Whoever may confirm crate money (`Gates.confirmCrateDeposit`) records it
  /// on the spot — the money already moved, and a person who may decide a
  /// deposit may record one they just paid. Anyone else raises it for that
  /// role, which is why the store question appears only for them: the approval
  /// queue routes BY store and `store_id` is NOT NULL on it, while the float
  /// ledger itself is business-level and needs no store at all.
  Future<void> _showFloatMoneySheet(SupplierData supplier) async {
    final staffId = ref.read(authProvider).currentUser?.id;
    if (staffId == null || staffId.isEmpty) {
      AppNotification.showError(context, 'No active session.');
      return;
    }
    final brands = _floatBrands();
    if (brands.isEmpty) return;

    final canPostDirectly = Gates.confirmCrateDeposit.allowsNow(ref);
    final lockedStoreId = ref.read(lockedStoreProvider).value;
    final stores = ref.read(selectableStoresProvider);
    String? chosenStoreId =
        lockedStoreId ?? (stores.length == 1 ? stores.single.id : null);

    var isTopUp = true;
    String? selectedId = brands.length == 1 ? brands.single.id : null;
    final amountCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final needsStorePick = !canPostDirectly && lockedStoreId == null;
          // The theme supplies the sheet's Surface and shape (#392). One
          // scrolling column, so the keyboard or a short window never
          // overflows it; it lifts above the keyboard as it always has.
          return SingleChildScrollView(
            padding: EdgeInsets.only(
              left: ctx.getRSize(20),
              right: ctx.getRSize(20),
              top: ctx.getRSize(12),
              bottom:
                  MediaQuery.of(ctx).viewInsets.bottom +
                  ctx.deviceBottomPadding +
                  ctx.getRSize(16),
            ),
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  InventorySheetHeader(
                    title: 'Crate Float Money',
                    subtitle: supplier.name,
                  ),
                  SizedBox(height: ctx.getRSize(12)),
                  Text(
                    'Only record money that actually changed hands. Crates '
                    'coming and going do not move this.',
                    style: ctx.regularStyle(12).copyWith(color: _subtext),
                  ),
                  SizedBox(height: ctx.getRSize(16)),
                  Row(
                    children: [
                      Expanded(
                        child: _crateMovementChip(
                          ctx,
                          label: 'Top up',
                          selected: isTopUp,
                          onTap: () => setSheet(() => isTopUp = true),
                        ),
                      ),
                      SizedBox(width: ctx.getRSize(10)),
                      Expanded(
                        child: _crateMovementChip(
                          ctx,
                          label: 'They paid back',
                          selected: !isTopUp,
                          onTap: () => setSheet(() => isTopUp = false),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: ctx.getRSize(16)),
                  AppDropdown<String>(
                    value: selectedId,
                    labelText: 'Brand',
                    hintText: 'Select a brand',
                    items: brands
                        .map(
                          (m) => DropdownMenuItem(
                            value: m.id,
                            child: Text(m.name),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setSheet(() => selectedId = v),
                    validator: (v) =>
                        (v == null || v.isEmpty) ? 'Select a brand' : null,
                  ),
                  if (needsStorePick) ...[
                    SizedBox(height: ctx.getRSize(16)),
                    AppDropdown<String>(
                      value: chosenStoreId,
                      labelText: 'Store',
                      hintText: 'Who should confirm this?',
                      items: stores
                          .map(
                            (s) => DropdownMenuItem(
                              value: s.id,
                              child: Text(s.name),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setSheet(() => chosenStoreId = v),
                      validator: (v) => (v == null || v.isEmpty)
                          ? 'Choose the store this belongs to'
                          : null,
                    ),
                  ],
                  SizedBox(height: ctx.getRSize(16)),
                  AppInput(
                    controller: amountCtrl,
                    labelText: isTopUp
                        ? 'Amount you paid the supplier'
                        : 'Amount the supplier paid back',
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [CurrencyInputFormatter()],
                    validator: (v) => _typedKobo(v ?? '') > 0
                        ? null
                        : 'Enter the amount that changed hands',
                  ),
                  SizedBox(height: ctx.getRSize(16)),
                  AppInput(controller: noteCtrl, labelText: 'Note (optional)'),
                  SizedBox(height: ctx.getRSize(24)),
                  AppButton(
                    text: canPostDirectly
                        ? (isTopUp ? 'Record Top-up' : 'Record Payout')
                        : 'Send for Confirmation',
                    onPressed: () => _submitFloatMovement(
                      ctx,
                      supplier: supplier,
                      manufacturerId: selectedId,
                      brands: brands,
                      amountText: amountCtrl.text,
                      noteText: noteCtrl.text,
                      isTopUp: isTopUp,
                      canPostDirectly: canPostDirectly,
                      staffId: staffId,
                      storeId: chosenStoreId,
                      formKey: formKey,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    amountCtrl.dispose();
    noteCtrl.dispose();
  }

  Future<void> _submitFloatMovement(
    BuildContext sheetCtx, {
    required SupplierData supplier,
    required String? manufacturerId,
    required List<ManufacturerData> brands,
    required String amountText,
    required String noteText,
    required bool isTopUp,
    required bool canPostDirectly,
    required String staffId,
    required String? storeId,
    required GlobalKey<FormState> formKey,
  }) async {
    if (!(formKey.currentState?.validate() ?? false)) return;
    final mfrId = manufacturerId!;
    final amountKobo = _typedKobo(amountText);
    final brandName = brands.firstWhere((m) => m.id == mfrId).name;
    final note = noteText.trim().isEmpty ? null : noteText.trim();
    final messenger = ScaffoldMessenger.of(context);

    // Write-boundary re-check (§10.2.1): honour a revoked override, and re-read
    // the money gate rather than trusting the flag the sheet opened with.
    if (!Gates.manageSuppliers.allowsNow(ref)) {
      Navigator.pop(sheetCtx);
      showGateDenied(context, Gates.manageSuppliers);
      return;
    }
    final postDirectly =
        canPostDirectly && Gates.confirmCrateDeposit.allowsNow(ref);
    Navigator.pop(sheetCtx);
    try {
      final dao = ref.read(databaseProvider).cratePoolDao;
      if (postDirectly) {
        await dao.recordCrateFloatMovement(
          supplierId: supplier.id,
          manufacturerId: mfrId,
          amountKobo: amountKobo,
          isTopUp: isTopUp,
          performedBy: staffId,
          // Deliberately null unless a store is locked: a float belongs to the
          // business, not to one store (ADR 0023's consequence note that crate
          // money is a company obligation).
          storeId: storeId,
          note: note,
        );
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              isTopUp
                  ? 'Top-up recorded — ${supplier.name} now holds '
                        '${formatCurrency(amountKobo / 100)} more of yours'
                  : 'Payout recorded — ${formatCurrency(amountKobo / 100)} is '
                        'back from ${supplier.name}',
            ),
          ),
        );
        return;
      }
      await dao.raiseCrateDepositRequest(
        supplierId: supplier.id,
        manufacturerId: mfrId,
        storeId: storeId!,
        crateCount: 0,
        requestedBy: staffId,
        kind: isTopUp
            ? kCrateDepositMovementFloatTopup
            : kCrateDepositMovementFloatPayout,
        requestedAmountKobo: amountKobo,
        note: note,
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '$brandName float ${isTopUp ? 'top-up' : 'payout'} of '
            '${formatCurrency(amountKobo / 100)} is waiting for a manager',
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        AppNotification.showError(
          context,
          'Could not record the float money. Please try again.',
        );
      }
    }
  }

  // Headline summary: net crates owed + refundable deposit held by the supplier.
  Widget _buildCrateSummaryCard(
    ThemeData theme,
    int totalOwed,
    int depositHeldKobo,
  ) {
    final f = theme.extension<AppFixedColors>() ?? AppFixedColors.light;
    final isOwe = totalOwed > 0;
    final isCredit = totalOwed < 0;
    final color = isOwe
        ? theme.colorScheme.primary
        : isCredit
        ? f.green
        : _subtext;
    final headline = isOwe
        ? 'You owe ${totalOwed.abs()} crate${totalOwed.abs() == 1 ? '' : 's'}'
        : isCredit
        ? '${totalOwed.abs()} crate${totalOwed.abs() == 1 ? '' : 's'} credit'
        : 'All crates settled';
    return Container(
      padding: EdgeInsets.all(context.getRSize(16)),
      decoration: AppDecorations.card(context),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Net crate balance',
                  style: context.semiBoldStyle(12).copyWith(color: _subtext),
                ),
                SizedBox(height: context.getRSize(4)),
                Text(
                  headline,
                  style: context.extraBoldStyle(18).copyWith(color: color),
                ),
              ],
            ),
          ),
          Container(
            width: 1,
            height: context.getRSize(40),
            color: theme.dividerColor,
          ),
          SizedBox(width: context.getRSize(16)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Deposit value (refundable)',
                  style: context.semiBoldStyle(12).copyWith(color: _subtext),
                ),
                SizedBox(height: context.getRSize(4)),
                Text(
                  formatCurrency(depositHeldKobo / 100),
                  style: context.extraBoldStyle(18).copyWith(color: _text),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Cumulative crates received from / sent back to this supplier (running
  // totals, not the net balance). "Returned" is the count sent back to date.
  Widget _buildCrateMovementStats(ThemeData theme, int received, int returned) {
    return Row(
      children: [
        Expanded(
          child: InventoryFigureCard(
            icon: AppIcons.receiving,
            tone: IconTileTone.info,
            value: '$received',
            label: 'Crates received',
          ),
        ),
        SizedBox(width: context.getRSize(12)),
        Expanded(
          child: InventoryFigureCard(
            icon: AppIcons.refresh,
            tone: IconTileTone.green,
            value: '$returned',
            label: 'Crates returned',
          ),
        ),
      ],
    );
  }

  // One per-manufacturer balance row (owed / credit), with the crate count.
  Widget _buildSupplierCrateRow(
    ThemeData theme,
    SupplierCrateBalanceWithManufacturer entry,
  ) {
    final bal = entry.balance;
    final isOwe = bal > 0;
    final label = isOwe ? '${bal.abs()} owed' : '${bal.abs()} credit';
    return Padding(
      padding: EdgeInsets.only(bottom: context.getRSize(10)),
      child: Container(
        constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
        padding: EdgeInsets.all(context.getRSize(14)),
        decoration: AppDecorations.card(context),
        child: Row(
          children: [
            IconTile(
              icon: AppIcons.box,
              tone: isOwe ? IconTileTone.info : IconTileTone.green,
              size: 40,
            ),
            SizedBox(width: context.getRSize(12)),
            Expanded(
              child: Text(
                entry.manufacturerName,
                style: context.boldStyle(15).copyWith(color: _text),
              ),
            ),
            TagPill(
              label: label,
              tone: isOwe ? TagPillTone.info : TagPillTone.green,
            ),
          ],
        ),
      ),
    );
  }

  /// §3.13 — record crates received from / returned to a supplier. Pick the
  /// movement, the manufacturer, the count, and the (optional) deposit, then
  /// write through [SupplierCrateService]. Gated on `suppliers.manage`.
  Future<void> _showRecordCrateSheet(SupplierData supplier) async {
    final staffId = ref.read(authProvider).currentUser?.id;
    if (staffId == null || staffId.isEmpty) {
      AppNotification.showError(context, 'No active session.');
      return;
    }
    final manufacturers = await ref
        .read(databaseProvider)
        .inventoryDao
        .getAllManufacturers();
    if (!mounted) return;
    if (manufacturers.isEmpty) {
      AppNotification.showError(context, 'Add a manufacturer first.');
      return;
    }

    var isReturn = false; // false = received, true = returned
    String? selectedId;
    final qtyCtrl = TextEditingController();
    final depositCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final lockedStoreId = ref.read(lockedStoreProvider).value;
    // #213: a crate-MONEY brand needs a store, because the approval queue
    // scopes approvers by store and `store_id` is NOT NULL. Under "All Stores"
    // #212 had nowhere to route the money and fell back to the legacy column;
    // asking which store the trip belongs to is what lets the money leg exist
    // at all. A `none` brand never sees this and behaves exactly as before.
    final stores = ref.read(selectableStoresProvider);
    String? chosenStoreId =
        lockedStoreId ?? (stores.length == 1 ? stores.single.id : null);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          // The selected brand's Crate Money Arrangement decides the whole shape
          // of this sheet (#211/#213). `per_delivery` means the deposit is real
          // money on a real ledger: it is never hand-typed into the legacy crate
          // column, and the refund a supplier hands back waits for a manager.
          final selectedMfr = selectedId == null
              ? null
              : manufacturers.where((m) => m.id == selectedId).firstOrNull;
          final isMoneyBrand =
              selectedMfr != null &&
              crateMoneyArrangementOf(selectedMfr.crateMoneyArrangement) ==
                  CrateMoneyArrangement.perDelivery;
          final needsStorePick = isMoneyBrand && lockedStoreId == null;
          // The theme supplies the sheet's Surface and shape (#392). One
          // scrolling column; it lifts above the keyboard as it always has.
          return SingleChildScrollView(
            padding: EdgeInsets.only(
              left: ctx.getRSize(20),
              right: ctx.getRSize(20),
              top: ctx.getRSize(12),
              bottom:
                  MediaQuery.of(ctx).viewInsets.bottom +
                  ctx.deviceBottomPadding +
                  ctx.getRSize(16),
            ),
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  InventorySheetHeader(
                    title: 'Empty Crates',
                    subtitle: supplier.name,
                  ),
                  SizedBox(height: ctx.getRSize(20)),
                  // Movement toggle.
                  Row(
                    children: [
                      Expanded(
                        child: _crateMovementChip(
                          ctx,
                          label: 'Received',
                          selected: !isReturn,
                          onTap: () => setSheet(() => isReturn = false),
                        ),
                      ),
                      SizedBox(width: ctx.getRSize(10)),
                      Expanded(
                        child: _crateMovementChip(
                          ctx,
                          label: 'Returned',
                          selected: isReturn,
                          onTap: () => setSheet(() => isReturn = true),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: ctx.getRSize(16)),
                  AppDropdown<String>(
                    value: selectedId,
                    labelText: 'Manufacturer',
                    hintText: 'Select a manufacturer',
                    items: manufacturers
                        .map(
                          (m) => DropdownMenuItem(
                            value: m.id,
                            child: Text(m.name),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setSheet(() => selectedId = v),
                    validator: (v) => (v == null || v.isEmpty)
                        ? 'Select a manufacturer'
                        : null,
                  ),
                  if (needsStorePick) ...[
                    SizedBox(height: ctx.getRSize(16)),
                    AppDropdown<String>(
                      value: chosenStoreId,
                      labelText: 'Store',
                      hintText: 'Which store was this?',
                      items: stores
                          .map(
                            (s) => DropdownMenuItem(
                              value: s.id,
                              child: Text(s.name),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setSheet(() => chosenStoreId = v),
                      validator: (v) => (v == null || v.isEmpty)
                          ? 'Choose the store this belongs to'
                          : null,
                    ),
                  ],
                  SizedBox(height: ctx.getRSize(16)),
                  AppInput(
                    controller: qtyCtrl,
                    labelText: isReturn
                        ? 'Crates returned to supplier'
                        : 'Crates received from supplier',
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    validator: (v) {
                      final n = int.tryParse((v ?? '').trim()) ?? 0;
                      if (n > 0) return null;
                      // A settlement can carry no crates at all — the day a
                      // supplier simply pays back a balance. It then needs the
                      // amount, because there is nothing to derive one from.
                      if (isMoneyBrand &&
                          isReturn &&
                          _typedKobo(depositCtrl.text) > 0) {
                        return null;
                      }
                      return 'Enter a crate count';
                    },
                  ),
                  SizedBox(height: ctx.getRSize(16)),
                  if (isMoneyBrand && !isReturn)
                    // The deposit on a receipt is NOT hand-typed for this brand
                    // — it is the manufacturer's rate, and a manager confirms
                    // it. Showing a money box here would invite a figure the
                    // write path deliberately ignores.
                    Text(
                      'A manager will confirm the deposit for these crates at '
                      "${selectedMfr.name}'s rate. You are only recording the "
                      'crates.',
                      style: ctx.regularStyle(12).copyWith(color: _subtext),
                    )
                  else ...[
                    AppInput(
                      controller: depositCtrl,
                      labelText: !isReturn
                          ? 'Deposit paid to supplier (optional)'
                          : isMoneyBrand
                          ? 'Refund actually received (optional)'
                          : 'Deposit refunded to you (optional)',
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [CurrencyInputFormatter()],
                    ),
                    if (isMoneyBrand && isReturn) ...[
                      SizedBox(height: ctx.getRSize(6)),
                      Text(
                        'Type what the supplier actually handed back. Leave it '
                        'blank and a manager records the real figure. Anything '
                        'short of the deposit stays yours, still held.',
                        style: ctx.regularStyle(12).copyWith(color: _subtext),
                      ),
                    ],
                  ],
                  SizedBox(height: ctx.getRSize(24)),
                  AppButton(
                    text: isReturn
                        ? (isMoneyBrand ? 'Record Settlement' : 'Record Return')
                        : 'Record Receipt',
                    onPressed: () => _submitCrateMovement(
                      ctx,
                      supplier: supplier,
                      manufacturerId: selectedId,
                      manufacturers: manufacturers,
                      qtyText: qtyCtrl.text,
                      depositText: depositCtrl.text,
                      isReturn: isReturn,
                      isMoneyBrand: isMoneyBrand,
                      staffId: staffId,
                      storeId: isMoneyBrand ? chosenStoreId : lockedStoreId,
                      formKey: formKey,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    qtyCtrl.dispose();
    depositCtrl.dispose();
  }

  /// A two-way toggle chip in the crate sheets (#392): a 48dp stadium, primary
  /// tint when chosen, hairline otherwise.
  Widget _crateMovementChip(
    BuildContext ctx, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final primary = Theme.of(ctx).colorScheme.primary;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusM);
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Container(
          constraints: const BoxConstraints(
            minHeight: kMinInteractiveDimension,
          ),
          padding: EdgeInsets.symmetric(vertical: ctx.getRSize(12)),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? primary.withValues(alpha: 0.12)
                : Theme.of(ctx).cardColor,
            borderRadius: radius,
            border: Border.all(
              color: selected ? primary : Theme.of(ctx).dividerColor,
              width: selected ? 2 : 1,
            ),
          ),
          child: Text(
            label,
            style: ctx
                .boldStyle(14)
                .copyWith(color: selected ? primary : _subtext),
          ),
        ),
      ),
    );
  }

  /// Naira typed into a money box, in kobo. 0 when it cannot be read as money.
  int _typedKobo(String text) {
    final raw = text.replaceAll(',', '').trim();
    if (raw.isEmpty) return 0;
    final naira = double.tryParse(raw);
    if (naira == null || naira <= 0) return 0;
    return (naira * 100).round();
  }

  Future<void> _submitCrateMovement(
    BuildContext sheetCtx, {
    required SupplierData supplier,
    required String? manufacturerId,
    required List<ManufacturerData> manufacturers,
    required String qtyText,
    required String depositText,
    required bool isReturn,
    required bool isMoneyBrand,
    required String staffId,
    required String? storeId,
    required GlobalKey<FormState> formKey,
  }) async {
    if (!(formKey.currentState?.validate() ?? false)) return;
    final mfrId = manufacturerId!;
    final qty = int.tryParse(qtyText.trim()) ?? 0;
    final depositKobo = _typedKobo(depositText);
    final mfrName = manufacturers.firstWhere((m) => m.id == mfrId).name;
    final messenger = ScaffoldMessenger.of(context);

    // Write-boundary re-check (§10.2.1): honour a revoked override.
    if (!Gates.manageSuppliers.allowsNow(ref)) {
      Navigator.pop(sheetCtx);
      showGateDenied(context, Gates.manageSuppliers);
      return;
    }
    Navigator.pop(sheetCtx);
    try {
      final service = ref.read(supplierCrateServiceProvider);
      if (isReturn && isMoneyBrand && storeId != null) {
        // #213 — the standalone settlement. No delivery is invented: this
        // writes the empties leg (when there are empties) and parks the refund
        // for a money-permitted role, who records what was actually handed
        // back. A short refund leaves the remainder held, not gone.
        await service.recordSettlement(
          supplierId: supplier.id,
          supplierName: supplier.name,
          manufacturerId: mfrId,
          manufacturerName: mfrName,
          crateCount: qty,
          staffId: staffId,
          storeId: storeId,
          refundAmountKobo: depositKobo > 0 ? depositKobo : null,
        );
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              qty == 0
                  ? 'Settlement recorded — the refund is waiting for a manager'
                  : '$qty $mfrName crate${qty == 1 ? '' : 's'} returned to '
                        '${supplier.name} — the refund is waiting for a manager',
            ),
          ),
        );
        return;
      }
      if (isReturn) {
        await service.recordReturn(
          supplierId: supplier.id,
          supplierName: supplier.name,
          manufacturerId: mfrId,
          manufacturerName: mfrName,
          quantity: qty,
          staffId: staffId,
          storeId: storeId,
          depositRefundedKobo: depositKobo,
        );
      } else {
        await service.recordReceipt(
          supplierId: supplier.id,
          supplierName: supplier.name,
          manufacturerId: mfrId,
          manufacturerName: mfrName,
          quantity: qty,
          staffId: staffId,
          storeId: storeId,
          depositPaidKobo: depositKobo,
        );
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            isReturn
                ? '$qty $mfrName crate${qty == 1 ? '' : 's'} returned to ${supplier.name}'
                : '$qty $mfrName crate${qty == 1 ? '' : 's'} received from ${supplier.name}',
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        AppNotification.showError(
          context,
          'Could not record crate activity. Please try again.',
        );
      }
    }
  }

  // --- Actions ---

  void _showEntryActions(SupplierData supplier, SupplierLedgerEntryData entry) {
    final isVoidable = entry.referenceType != 'void' && entry.voidedAt == null;
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (ctx) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          ctx.getRSize(20),
          ctx.getRSize(12),
          ctx.getRSize(20),
          ctx.getRSize(16) + ctx.deviceBottomPadding,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InventorySheetHeader(
              title: 'Entry options',
              subtitle:
                  '${formatCurrency(entry.amountKobo / 100)} • '
                  '${DateFormat('MMM d, y').format(entry.activityDate)}',
            ),
            SizedBox(height: ctx.getRSize(20)),
            if (isVoidable)
              AppButton(
                text: 'Void / reverse this entry',
                variant: AppButtonVariant.danger,
                onPressed: () {
                  Navigator.pop(ctx);
                  _confirmVoid(supplier, entry);
                },
              )
            else
              Text(
                entry.referenceType == 'void'
                    ? 'This is a reversal entry and cannot be voided.'
                    : 'This entry has already been voided.',
                style: ctx.regularStyle(13).copyWith(color: _subtext),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmVoid(
    SupplierData supplier,
    SupplierLedgerEntryData entry,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        // Scrolls rather than overflows at large text or on a sideways phone.
        scrollable: true,
        title: Text(
          'Void this entry?',
          style: ctx.screenTitleStyle.copyWith(color: _text),
        ),
        content: Text(
          'A compensating reversal of ${formatCurrency(entry.amountKobo / 100)} '
          'will be appended to ${supplier.name}’s ledger. The original entry '
          'is kept for the record. This cannot be undone.',
          style: ctx.regularStyle(14).copyWith(color: _subtext),
        ),
        actions: [
          AppButton(
            text: 'Cancel',
            variant: AppButtonVariant.ghost,
            isFullWidth: false,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          AppButton(
            text: 'Void',
            variant: AppButtonVariant.danger,
            isFullWidth: false,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    if (ref.read(currentUserRoleProvider)?.slug != 'ceo') return;
    final voidedBy = ref.read(authProvider).currentUser?.id;
    if (voidedBy == null) return;
    try {
      await ref
          .read(supplierAccountServiceProvider)
          .voidEntry(
            entryId: entry.id,
            supplierId: supplier.id,
            voidedBy: voidedBy,
            reason: 'Voided by CEO',
          );
      if (mounted) {
        AppNotification.showSuccess(context, 'Entry voided');
      }
    } catch (_) {
      if (mounted) {
        AppNotification.showError(
          context,
          'Could not void the entry. Please try again.',
        );
      }
    }
  }

  Future<void> _confirmDelete(SupplierData supplier) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        // Scrolls rather than overflows at large text or on a sideways phone.
        scrollable: true,
        title: Text(
          'Delete supplier?',
          style: ctx.screenTitleStyle.copyWith(color: _text),
        ),
        content: Text(
          'Remove ${supplier.name}? Their ledger history is kept, but they will '
          'no longer appear in the suppliers list.',
          style: ctx.regularStyle(14).copyWith(color: _subtext),
        ),
        actions: [
          AppButton(
            text: 'Cancel',
            variant: AppButtonVariant.ghost,
            isFullWidth: false,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          AppButton(
            text: 'Delete',
            isFullWidth: false,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    if (!mounted) return;
    if (!Gates.manageSuppliers.allowsNow(ref)) {
      showGateDenied(context, Gates.manageSuppliers);
      return;
    }
    final db = ref.read(databaseProvider);
    try {
      await db.catalogDao.softDeleteSupplier(supplier.id);
      await db.activityLogDao.logActivity(
        action: 'supplier.delete',
        description: 'Deleted supplier ${supplier.name}',
        staffId: ref.read(authProvider).currentUser?.id,
        entityType: 'supplier',
        entityId: supplier.id,
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (!mounted) return;
      AppNotification.showError(
        context,
        'Could not delete supplier. Please try again.',
      );
    }
  }
}

// ── Shared Helpers for Screen ───────────────────────────────────────────────

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final ThemeData theme;

  const _InfoRow({required this.icon, required this.text, required this.theme});

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    final muted =
        theme.textTheme.bodySmall?.color ?? theme.colorScheme.onSurface;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(top: context.getRSize(2)),
          child: AppIcon(icon, size: context.getRSize(14), color: muted),
        ),
        SizedBox(width: context.getRSize(8)),
        Expanded(
          child: Text(
            text,
            style: context.mediumStyle(13).copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}
