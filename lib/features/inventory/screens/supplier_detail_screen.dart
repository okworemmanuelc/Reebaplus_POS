import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:reebaplus_pos/features/payments/widgets/record_supplier_activity.dart';
import 'package:reebaplus_pos/features/payments/widgets/supplier_form_sheet.dart';
import 'package:reebaplus_pos/features/payments/widgets/supplier_ledger_entry_tile.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_card.dart';
import 'package:reebaplus_pos/shared/widgets/optimized_backdrop_filter.dart';

/// §21.3 / §21.10 — Supplier Details on real ledger data. Balance =
/// SUM(payments) − SUM(invoices); negative (red) = we owe the supplier.
class SupplierDetailScreen extends ConsumerStatefulWidget {
  final String supplierId;

  const SupplierDetailScreen({super.key, required this.supplierId});

  @override
  ConsumerState<SupplierDetailScreen> createState() =>
      _SupplierDetailScreenState();
}

class _SupplierDetailScreenState extends ConsumerState<SupplierDetailScreen> {
  String _timeFilter = 'This Month'; // §30.6/§30.11 default
  DateTimeRange? _customRange;
  bool _isScrolled = false;

  List<String> get _periodOptions =>
      datePeriodLabelsForRole(managerUp: isManagerOrAbove(ref));

  String get _effectivePeriod {
    final isCustom = _timeFilter.startsWith('Custom:');
    final dropdownValue = isCustom ? 'Custom' : _timeFilter;
    return _periodOptions.contains(dropdownValue) ? dropdownValue : _periodOptions.first;
  }

  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _surface => Theme.of(context).colorScheme.surface;
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
    final canManage = ref
        .watch(currentUserPermissionsProvider)
        .contains('suppliers.manage');
    final isCeo = ref.watch(currentUserRoleProvider)?.slug == 'ceo';
    final supplierAsync = ref.watch(supplierByIdProvider(widget.supplierId));
    final supplier = supplierAsync.valueOrNull;

    final showCrates = businessTracksCrates(ref.watch(currentBusinessProvider));

    Widget content;
    if (!canManage) {
      content = Center(
        child: Text(
          'You don’t have access to Supplier Accounts.',
          style: TextStyle(color: _subtext),
        ),
      );
    } else if (supplier == null) {
      content = supplierAsync.isLoading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: Text('Supplier not found', style: TextStyle(color: _subtext)),
            );
    } else {
      content = _buildBody(context, theme, supplier, showCrates);
    }

    // DefaultTabController if showCrates is true
    Widget bodyContent = content;
    if (showCrates && canManage && supplier != null) {
      bodyContent = DefaultTabController(
        length: 2,
        child: content,
      );
    }

    return ColoredBox(
      color: _bg,
      child: Container(
        decoration: AppDecorations.glassyBackground(context),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: _isScrolled
                ? _surface.withValues(alpha: 0.8)
                : Colors.transparent,
            elevation: 0,
            leading: IconButton(
              icon: Icon(Icons.arrow_back_ios_new, color: _text, size: context.getRSize(20)),
              onPressed: () => Navigator.pop(context),
            ),
            title: Text(
              'Supplier Details',
              style: TextStyle(
                color: _text,
                fontSize: context.getRFontSize(18),
                fontWeight: FontWeight.w800,
              ),
            ),
            actions: [
              if (isCeo && supplier != null)
                IconButton(
                  icon: Icon(
                    FontAwesomeIcons.penToSquare.data,
                    color: _text,
                    size: context.getRSize(16),
                  ),
                  tooltip: 'Edit supplier',
                  onPressed: () =>
                      SupplierFormSheet.show(context, existing: supplier),
                ),
              if (isCeo && supplier != null)
                IconButton(
                  icon: Icon(
                    FontAwesomeIcons.trashCan.data,
                    color: danger,
                    size: context.getRSize(16),
                  ),
                  tooltip: 'Delete supplier',
                  onPressed: () => _confirmDelete(supplier),
                ),
              SizedBox(width: context.getRSize(8)),
            ],
          ),
          body: NotificationListener<ScrollUpdateNotification>(
            onNotification: (notif) {
              if (notif.metrics.axis == Axis.vertical) {
                final scrolled = notif.metrics.pixels > 10;
                if (scrolled != _isScrolled) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() => _isScrolled = scrolled);
                  });
                }
              }
              return false;
            },
            child: bodyContent,
          ),
          floatingActionButton: (canManage && supplier != null)
              ? AppFAB(
                  heroTag: 'supplier_record_fab',
                  onPressed: () => showSupplierActivityChooser(
                    context,
                    supplierId: supplier.id,
                    supplierName: supplier.name,
                  ),
                  icon: FontAwesomeIcons.plus.data,
                  label: 'Record Activity',
                )
              : null,
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, ThemeData theme, SupplierData supplier, bool showCrates) {
    final balanceAsync = ref.watch(supplierBalanceProvider(widget.supplierId));
    final historyAsync = ref.watch(
      supplierLedgerHistoryProvider(widget.supplierId),
    );
    final balanceKobo = balanceAsync.valueOrNull ?? 0;
    final history = historyAsync.valueOrNull ?? const <SupplierLedgerEntryData>[];

    final scopeLabel = ref.watch(activeStoreLabelProvider);
    final isAllStores = ref.watch(lockedStoreProvider).value == null;
    final stores = ref.watch(allStoresProvider).valueOrNull ?? const <StoreData>[];
    final storeNameById = {for (final s in stores) s.id: s.name};

    final filtered = history
        .where((e) => isDateInPeriod(e.activityDate, _timeFilter))
        .toList();

    return NestedScrollView(
      headerSliverBuilder: (context, innerBoxIsScrolled) {
        return [
          SliverToBoxAdapter(child: _buildHeader(context, theme, supplier)),
          SliverToBoxAdapter(child: _buildBalanceCard(context, theme, balanceKobo, scopeLabel)),
          if (showCrates)
            SliverPersistentHeader(
              pinned: true,
              delegate: _SliverTabBarDelegate(
                extent: context.getRSize(60),
                child: Container(
                  color: Colors.transparent,
                  padding: EdgeInsets.symmetric(horizontal: context.getRSize(20)),
                  child: _buildTabBar(theme),
                ),
              ),
            )
          else
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  context.getRSize(20),
                  context.getRSize(16),
                  context.getRSize(20),
                  context.getRSize(8),
                ),
                child: Text(
                  'Activity Ledger',
                  style: TextStyle(
                    fontSize: context.getRFontSize(16),
                    fontWeight: FontWeight.w800,
                    color: _text,
                  ),
                ),
              ),
            ),
        ];
      },
      body: showCrates
          ? TabBarView(
              children: [
                _buildHistoryTab(context, theme, filtered, supplier, isAllStores ? storeNameById : null),
                _buildCratesTab(context, theme),
              ],
            )
          : _buildHistoryTab(context, theme, filtered, supplier, isAllStores ? storeNameById : null),
    );
  }

  Widget _buildTabBar(ThemeData theme) {
    return Container(
      margin: EdgeInsets.only(bottom: context.getRSize(8)),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.1)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: OptimizedBackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          fallbackBuilder: (context, child) => child,
          child: TabBar(
            indicatorSize: TabBarIndicatorSize.tab,
            indicatorPadding: EdgeInsets.all(context.getRSize(4)),
            indicator: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.3)),
            ),
            labelColor: theme.colorScheme.primary,
            unselectedLabelColor: _text.withAlpha(150),
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
              Tab(text: 'Ledger'),
              Tab(text: 'Empty Crates'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ThemeData theme, SupplierData s) {
    return _GlassyCard(
      margin: EdgeInsets.fromLTRB(
        context.getRSize(20),
        context.getRSize(24),
        context.getRSize(20),
        context.getRSize(16),
      ),
      padding: EdgeInsets.all(context.getRSize(16)),
      radius: 20,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: context.getRSize(60),
            height: context.getRSize(60),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                _initials(s.name),
                style: TextStyle(
                  fontSize: context.getRFontSize(22),
                  fontWeight: FontWeight.w900,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ),
          SizedBox(width: context.getRSize(16)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  s.name,
                  style: TextStyle(
                    fontSize: context.getRFontSize(18),
                    fontWeight: FontWeight.w800,
                    color: _text,
                  ),
                ),
                if ((s.phone ?? '').isNotEmpty || (s.address ?? '').isNotEmpty) ...[
                  SizedBox(height: context.getRSize(8)),
                  _InfoRow(
                    icon: FontAwesomeIcons.phone.data,
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
                    icon: FontAwesomeIcons.locationDot.data,
                    text: s.address!,
                    theme: theme,
                  ),
                ],
                if ((s.bankName ?? '').isNotEmpty || (s.bankAccountNumber ?? '').isNotEmpty) ...[
                  SizedBox(height: context.getRSize(4)),
                  _InfoRow(
                    icon: FontAwesomeIcons.buildingColumns.data,
                    text: [
                      if ((s.bankName ?? '').isNotEmpty) s.bankName!,
                      if ((s.bankAccountNumber ?? '').isNotEmpty) s.bankAccountNumber!,
                      if ((s.bankAccountName ?? '').isNotEmpty) s.bankAccountName!,
                    ].join(' • '),
                    theme: theme,
                  ),
                ],
                if ((s.notes ?? '').isNotEmpty) ...[
                  SizedBox(height: context.getRSize(6)),
                  Text(
                    s.notes!,
                    style: TextStyle(
                      fontSize: context.getRFontSize(12),
                      color: _subtext,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBalanceCard(BuildContext context, ThemeData theme, int balanceKobo, String scopeLabel) {
    final owed = balanceKobo < 0;
    final color = owed ? danger : (balanceKobo > 0 ? success : _text);
    final label = owed
        ? 'Amount owed to supplier'
        : (balanceKobo > 0 ? 'Credit balance' : 'Settled');

    return _GlassyCard(
      margin: EdgeInsets.symmetric(horizontal: context.getRSize(20)).copyWith(
        bottom: context.getRSize(16),
      ),
      padding: EdgeInsets.all(context.getRSize(18)),
      radius: 20,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          FontAwesomeIcons.wallet.data,
                          size: context.getRSize(14),
                          color: theme.colorScheme.primary,
                        ),
                        SizedBox(width: context.getRSize(8)),
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: context.getRFontSize(12),
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface.withAlpha(128),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: context.getRSize(6)),
                    Text(
                      formatCurrency(balanceKobo.abs() / 100),
                      style: TextStyle(
                        fontSize: context.getRFontSize(28),
                        fontWeight: FontWeight.w900,
                        color: color,
                        letterSpacing: -1,
                      ),
                    ),
                    SizedBox(height: context.getRSize(4)),
                    Text(
                      scopeLabel,
                      style: TextStyle(
                        fontSize: context.getRFontSize(12),
                        color: _subtext,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'Period:',
                    style: TextStyle(
                      fontSize: context.getRFontSize(10),
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface.withAlpha(128),
                    ),
                  ),
                  SizedBox(height: context.getRSize(4)),
                  SizedBox(
                    width: 120,
                    child: AppDropdown<String>(
                      value: _effectivePeriod,
                      isExpanded: false,
                      contentPadding: EdgeInsets.symmetric(horizontal: context.getRSize(8), vertical: context.getRSize(6)),
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
                            builder: (context, child) => Theme(
                              data: Theme.of(context),
                              child: child!,
                            ),
                          );
                          if (range != null) {
                            setState(() {
                              _customRange = range;
                              _timeFilter = 'Custom:${range.start.toIso8601String()}:${range.end.toIso8601String()}';
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
        ],
      ),
    );
  }

  Widget _buildSummaryTile(
    ThemeData theme,
    String label,
    double amount,
    Color color,
  ) {
    return _GlassyCard(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(14),
        vertical: context.getRSize(10),
      ),
      radius: 12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: context.getRFontSize(11),
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface.withAlpha(128),
            ),
          ),
          SizedBox(height: context.getRSize(4)),
          Text(
            formatCurrency(amount),
            style: TextStyle(
              fontSize: context.getRFontSize(15),
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLedgerSummaryRow(ThemeData theme, List<SupplierLedgerEntryData> filteredHistory) {
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
        context.getRSize(20),
        context.getRSize(12),
        context.getRSize(20),
        0,
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildSummaryTile(
              theme,
              'Total In',
              totalInKobo / 100.0,
              success,
            ),
          ),
          SizedBox(width: context.getRSize(10)),
          Expanded(
            child: _buildSummaryTile(
              theme,
              'Total Out',
              totalOutKobo / 100.0,
              danger,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryTab(
    BuildContext context,
    ThemeData theme,
    List<SupplierLedgerEntryData> entries,
    SupplierData supplier,
    Map<String, String>? storeNameById,
  ) {
    final summaryRow = Column(
      children: [
        _buildLedgerSummaryRow(theme, entries),
        SizedBox(height: context.getRSize(4)),
      ],
    );

    if (entries.isEmpty) {
      return Column(
        children: [
          summaryRow,
          Expanded(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(context.getRSize(40)),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      FontAwesomeIcons.fileInvoiceDollar.data,
                      size: context.getRSize(48),
                      color: theme.colorScheme.onSurface.withAlpha(40),
                    ),
                    SizedBox(height: context.getRSize(16)),
                    Text(
                      'No activity in this period',
                      style: TextStyle(
                        color: theme.colorScheme.onSurface.withAlpha(128),
                        fontSize: context.getRFontSize(14),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }
    
    final isCeo = ref.watch(currentUserRoleProvider)?.slug == 'ceo';
    return Column(
      children: [
        summaryRow,
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.fromLTRB(
              context.getRSize(20),
              context.getRSize(8),
              context.getRSize(20),
              context.getRSize(96) + context.deviceBottomPadding,
            ),
            itemCount: entries.length,
            itemBuilder: (ctx, i) {
              final e = entries[i];
              return SupplierLedgerEntryTile(
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
      ],
    );
  }

  /// §3.13 — real per-supplier empty-crate tracking. Mirrors the customer
  /// Crates tab: a positive per-manufacturer balance = WE owe the supplier that
  /// many empties (for the full crates they delivered); negative = a crate
  /// credit. The deposit we paid for crates we keep is surfaced as the
  /// refundable "deposit held by supplier" figure.
  Widget _buildCratesTab(BuildContext context, ThemeData theme) {
    final supplierAsync = ref.watch(supplierByIdProvider(widget.supplierId));
    final supplier = supplierAsync.valueOrNull;
    final canManage =
        ref.watch(currentUserPermissionsProvider).contains('suppliers.manage');
    final balances =
        ref.watch(supplierCrateBalancesProvider(widget.supplierId)).valueOrNull ??
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
        ref.watch(supplierCrateMovementTotalsProvider(widget.supplierId)).valueOrNull ??
        (received: 0, returned: 0);

    return ListView(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(20),
        context.getRSize(16),
        context.getRSize(20),
        context.getRSize(96) + context.deviceBottomPadding,
      ),
      children: [
        if (canManage && supplier != null) ...[
          _buildCrateActionCard(theme, supplier),
          SizedBox(height: context.getRSize(16)),
        ],
        _buildCrateSummaryCard(theme, totalOwed, depositValueKobo),
        SizedBox(height: context.getRSize(12)),
        _buildCrateMovementStats(theme, totals.received, totals.returned),
        SizedBox(height: context.getRSize(16)),
        Text(
          'By manufacturer',
          style: TextStyle(
            fontSize: context.getRFontSize(14),
            fontWeight: FontWeight.w800,
            color: _text,
          ),
        ),
        SizedBox(height: context.getRSize(12)),
        if (active.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: context.getRSize(20)),
            child: Text(
              'No crate activity recorded with this supplier',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.getRFontSize(13),
                color: _subtext,
              ),
            ),
          )
        else
          ...active.map((b) => _buildSupplierCrateRow(theme, b)),
      ],
    );
  }

  // The "+" action card pinned at the top of the Crates tab (§3.13).
  Widget _buildCrateActionCard(ThemeData theme, SupplierData supplier) {
    return InkWell(
      onTap: () => _showRecordCrateSheet(supplier),
      borderRadius: BorderRadius.circular(16),
      child: _GlassyCard(
        padding: EdgeInsets.all(context.getRSize(14)),
        child: Row(
          children: [
            Container(
              width: context.getRSize(40),
              height: context.getRSize(40),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                FontAwesomeIcons.boxesStacked.data,
                color: theme.colorScheme.primary,
                size: context.getRSize(16),
              ),
            ),
            SizedBox(width: context.getRSize(12)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Record crate activity',
                    style: TextStyle(
                      fontSize: context.getRFontSize(14),
                      fontWeight: FontWeight.w700,
                      color: _text,
                    ),
                  ),
                  SizedBox(height: context.getRSize(2)),
                  Text(
                    'Crates received from / returned to this supplier',
                    style: TextStyle(
                      fontSize: context.getRFontSize(12),
                      color: _subtext,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              FontAwesomeIcons.chevronRight.data,
              size: context.getRSize(13),
              color: _subtext,
            ),
          ],
        ),
      ),
    );
  }

  // Headline summary: net crates owed + refundable deposit held by the supplier.
  Widget _buildCrateSummaryCard(
    ThemeData theme,
    int totalOwed,
    int depositHeldKobo,
  ) {
    final isOwe = totalOwed > 0;
    final isCredit = totalOwed < 0;
    final color = isOwe
        ? theme.colorScheme.primary
        : isCredit
        ? success
        : _subtext;
    final headline = isOwe
        ? 'You owe ${totalOwed.abs()} crate${totalOwed.abs() == 1 ? '' : 's'}'
        : isCredit
        ? '${totalOwed.abs()} crate${totalOwed.abs() == 1 ? '' : 's'} credit'
        : 'All crates settled';
    return _GlassyCard(
      padding: EdgeInsets.all(context.getRSize(18)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Net crate balance',
                  style: TextStyle(
                    fontSize: context.getRFontSize(12),
                    color: _subtext,
                  ),
                ),
                SizedBox(height: context.getRSize(4)),
                Text(
                  headline,
                  style: TextStyle(
                    fontSize: context.getRFontSize(18),
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
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
                  style: TextStyle(
                    fontSize: context.getRFontSize(12),
                    color: _subtext,
                  ),
                ),
                SizedBox(height: context.getRSize(4)),
                Text(
                  formatCurrency(depositHeldKobo / 100),
                  style: TextStyle(
                    fontSize: context.getRFontSize(18),
                    fontWeight: FontWeight.w800,
                    color: _text,
                  ),
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
  Widget _buildCrateMovementStats(
    ThemeData theme,
    int received,
    int returned,
  ) {
    return Row(
      children: [
        Expanded(
          child: _crateStatTile(
            theme,
            icon: FontAwesomeIcons.truckRampBox.data,
            label: 'Crates received',
            value: '$received',
            color: theme.colorScheme.primary,
          ),
        ),
        SizedBox(width: context.getRSize(12)),
        Expanded(
          child: _crateStatTile(
            theme,
            icon: FontAwesomeIcons.rotateLeft.data,
            label: 'Crates returned',
            value: '$returned',
            color: success,
          ),
        ),
      ],
    );
  }

  Widget _crateStatTile(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return _GlassyCard(
      padding: EdgeInsets.all(context.getRSize(14)),
      child: Row(
        children: [
          Container(
            width: context.getRSize(34),
            height: context.getRSize(34),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: context.getRSize(14)),
          ),
          SizedBox(width: context.getRSize(10)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontSize: context.getRFontSize(18),
                    fontWeight: FontWeight.w800,
                    color: _text,
                  ),
                ),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: context.getRFontSize(11),
                    color: _subtext,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // One per-manufacturer balance row (owed / credit), with the crate count.
  Widget _buildSupplierCrateRow(
    ThemeData theme,
    SupplierCrateBalanceWithManufacturer entry,
  ) {
    final bal = entry.balance;
    final isOwe = bal > 0;
    final color = isOwe ? theme.colorScheme.primary : success;
    final label = isOwe
        ? '${bal.abs()} owed'
        : '${bal.abs()} credit';
    return Padding(
      padding: EdgeInsets.only(bottom: context.getRSize(10)),
      child: _GlassyCard(
        padding: EdgeInsets.all(context.getRSize(14)),
        child: Row(
          children: [
            Container(
              width: context.getRSize(38),
              height: context.getRSize(38),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                FontAwesomeIcons.boxOpen.data,
                color: color,
                size: context.getRSize(15),
              ),
            ),
            SizedBox(width: context.getRSize(12)),
            Expanded(
              child: Text(
                entry.manufacturerName,
                style: TextStyle(
                  fontSize: context.getRFontSize(14),
                  fontWeight: FontWeight.w600,
                  color: _text,
                ),
              ),
            ),
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: context.getRSize(10),
                vertical: context.getRSize(4),
              ),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: context.getRFontSize(12),
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
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
    final manufacturers =
        await ref.read(databaseProvider).inventoryDao.getAllManufacturers();
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
    final storeId = ref.read(lockedStoreProvider).value;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(
            left: ctx.getRSize(20),
            right: ctx.getRSize(20),
            top: ctx.getRSize(16),
            bottom: MediaQuery.of(ctx).viewInsets.bottom + ctx.deviceBottomPadding + ctx.getRSize(16),
          ),
          child: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: ctx.getRSize(40),
                      height: ctx.getRSize(4),
                      decoration: BoxDecoration(
                        color: Theme.of(ctx).dividerColor,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  SizedBox(height: ctx.getRSize(20)),
                  Text(
                    'Empty Crates',
                    style: TextStyle(
                      fontSize: ctx.getRFontSize(18),
                      fontWeight: FontWeight.w800,
                      color: _text,
                    ),
                  ),
                  SizedBox(height: ctx.getRSize(4)),
                  Text(
                    supplier.name,
                    style: TextStyle(
                      fontSize: ctx.getRFontSize(13),
                      color: Theme.of(ctx).colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
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
                    validator: (v) =>
                        (v == null || v.isEmpty) ? 'Select a manufacturer' : null,
                  ),
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
                      if (n <= 0) return 'Enter a crate count';
                      return null;
                    },
                  ),
                  SizedBox(height: ctx.getRSize(16)),
                  AppInput(
                    controller: depositCtrl,
                    labelText: isReturn
                        ? 'Deposit refunded to you (optional)'
                        : 'Deposit paid to supplier (optional)',
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [CurrencyInputFormatter()],
                  ),
                  SizedBox(height: ctx.getRSize(24)),
                  AppButton(
                    text: isReturn ? 'Record Return' : 'Record Receipt',
                    onPressed: () => _submitCrateMovement(
                      ctx,
                      supplier: supplier,
                      manufacturerId: selectedId,
                      manufacturers: manufacturers,
                      qtyText: qtyCtrl.text,
                      depositText: depositCtrl.text,
                      isReturn: isReturn,
                      staffId: staffId,
                      storeId: storeId,
                      formKey: formKey,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    qtyCtrl.dispose();
    depositCtrl.dispose();
  }

  Widget _crateMovementChip(
    BuildContext ctx, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final primary = Theme.of(ctx).colorScheme.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: EdgeInsets.symmetric(vertical: ctx.getRSize(12)),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? primary.withValues(alpha: 0.12)
              : Theme.of(ctx).cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? primary : Theme.of(ctx).dividerColor,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: ctx.getRFontSize(14),
            fontWeight: FontWeight.w700,
            color: selected ? primary : _subtext,
          ),
        ),
      ),
    );
  }

  Future<void> _submitCrateMovement(
    BuildContext sheetCtx, {
    required SupplierData supplier,
    required String? manufacturerId,
    required List<ManufacturerData> manufacturers,
    required String qtyText,
    required String depositText,
    required bool isReturn,
    required String staffId,
    required String? storeId,
    required GlobalKey<FormState> formKey,
  }) async {
    if (!(formKey.currentState?.validate() ?? false)) return;
    final mfrId = manufacturerId!;
    final qty = int.parse(qtyText.trim());
    final depositKobo =
        (((double.tryParse(depositText.replaceAll(',', '').trim()) ?? 0)) * 100)
            .round();
    final mfrName = manufacturers.firstWhere((m) => m.id == mfrId).name;
    final messenger = ScaffoldMessenger.of(context);

    // Write-boundary re-check (§10.2.1): honour a revoked override.
    if (!ref
        .read(currentUserPermissionsProvider)
        .contains('suppliers.manage')) {
      Navigator.pop(sheetCtx);
      AppNotification.showError(
        context,
        'You don’t have permission to do that.',
      );
      return;
    }
    Navigator.pop(sheetCtx);
    try {
      final service = ref.read(supplierCrateServiceProvider);
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
    final isVoidable =
        entry.referenceType != 'void' && entry.voidedAt == null;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            ctx.getRSize(20),
            ctx.getRSize(16),
            ctx.getRSize(20),
            ctx.getRSize(16) + ctx.deviceBottomPadding,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Entry options',
                style: TextStyle(
                  color: _text,
                  fontWeight: FontWeight.w800,
                  fontSize: ctx.getRFontSize(16),
                ),
              ),
              SizedBox(height: ctx.getRSize(4)),
              Text(
                '${formatCurrency(entry.amountKobo / 100)} • '
                '${DateFormat('MMM d, y').format(entry.activityDate)}',
                style: TextStyle(color: _subtext, fontSize: ctx.getRFontSize(13)),
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
                  style: TextStyle(
                    color: _subtext,
                    fontSize: ctx.getRFontSize(13),
                  ),
                ),
            ],
          ),
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
        backgroundColor: _surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: Text(
          'Void this entry?',
          style: TextStyle(color: _text, fontWeight: FontWeight.bold),
        ),
        content: Text(
          'A compensating reversal of ${formatCurrency(entry.amountKobo / 100)} '
          'will be appended to ${supplier.name}’s ledger. The original entry '
          'is kept for the record. This cannot be undone.',
          style: TextStyle(color: _subtext),
        ),
        actions: [
          AppButton(
            text: 'Cancel',
            variant: AppButtonVariant.ghost,
            size: AppButtonSize.small,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          AppButton(
            text: 'Void',
            variant: AppButtonVariant.danger,
            size: AppButtonSize.small,
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
        backgroundColor: _surface,
        title: Text(
          'Delete supplier?',
          style: TextStyle(color: _text, fontWeight: FontWeight.bold),
        ),
        content: Text(
          'Remove ${supplier.name}? Their ledger history is kept, but they will '
          'no longer appear in the suppliers list.',
          style: TextStyle(color: _subtext),
        ),
        actions: [
          AppButton(
            text: 'Cancel',
            variant: AppButtonVariant.ghost,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          AppButton(
            text: 'Delete',
            size: AppButtonSize.small,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    if (!ref
        .read(currentUserPermissionsProvider)
        .contains('suppliers.manage')) {
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

  const _InfoRow({
    required this.icon,
    required this.text,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(top: context.getRSize(2)),
          child: Icon(
            icon,
            size: context.getRSize(11),
            color: theme.colorScheme.onSurface.withAlpha(128),
          ),
        ),
        SizedBox(width: context.getRSize(8)),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: context.getRFontSize(13),
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurface.withAlpha(178),
            ),
          ),
        ),
      ],
    );
  }
}

class _GlassyCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double radius;

  const _GlassyCard({
    required this.child,
    this.padding,
    this.margin,
    this.radius = 16.0,
  });

  @override
  Widget build(BuildContext context) {
    return GlassyCard(
      padding: padding,
      margin: margin,
      radius: radius,
      child: child,
    );
  }
}

class _SliverTabBarDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  final double extent;
  _SliverTabBarDelegate({required this.child, this.extent = 60});

  @override
  double get minExtent => extent;
  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    // Pin the child to exactly [extent]. Under a NestedScrollView a pinned
    // header reports paintExtent from the child's *actual* rendered height but
    // layoutExtent from the declared maxExtent; if the (loosely-constrained)
    // child renders even fractionally shorter than [extent], paintExtent drops
    // below layoutExtent and the framework asserts "layoutExtent exceeds
    // paintExtent". Forcing the height keeps childExtent == maxExtent.
    return SizedBox(height: extent, child: child);
  }

  @override
  bool shouldRebuild(_SliverTabBarDelegate oldDelegate) {
    return oldDelegate.extent != extent;
  }
}
