import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/data/business_types.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';
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
  bool _isScrolled = false;

  List<String> get _periodOptions =>
      datePeriodLabelsForRole(managerUp: isManagerOrAbove(ref));

  String get _effectivePeriod =>
      _periodOptions.contains(_timeFilter) ? _timeFilter : _periodOptions.last;

  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider);
    final canManage = ref
        .watch(currentUserPermissionsProvider)
        .contains('suppliers.manage');
    final isCeo = ref.watch(currentUserRoleProvider)?.slug == 'ceo';
    final supplierAsync = ref.watch(supplierByIdProvider(widget.supplierId));
    final supplier = supplierAsync.valueOrNull;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _bg,
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.05),
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
          ],
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: _isScrolled
              ? _surface.withValues(alpha: 0.8)
              : Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: Icon(Icons.arrow_back_ios_new, color: _text, size: 20),
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
            // Edit is CEO only (§21.7).
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
          ],
        ),
        body: NotificationListener<ScrollUpdateNotification>(
          onNotification: (notif) {
            if (notif.metrics.pixels > 10 && !_isScrolled) {
              setState(() => _isScrolled = true);
            } else if (notif.metrics.pixels <= 10 && _isScrolled) {
              setState(() => _isScrolled = false);
            }
            return false;
          },
          child: !canManage
              ? Center(
                  child: Text(
                    'You don’t have access to Supplier Accounts.',
                    style: TextStyle(color: _subtext),
                  ),
                )
              : supplier == null
              ? (supplierAsync.isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : Center(
                        child: Text(
                          'Supplier not found',
                          style: TextStyle(color: _subtext),
                        ),
                      ))
              : _buildBody(context, supplier),
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
    );
  }

  Widget _buildBody(BuildContext context, SupplierData supplier) {
    final balanceAsync = ref.watch(supplierBalanceProvider(widget.supplierId));
    final historyAsync = ref.watch(
      supplierLedgerHistoryProvider(widget.supplierId),
    );
    final balanceKobo = balanceAsync.valueOrNull ?? 0;
    final history =
        historyAsync.valueOrNull ?? const <SupplierLedgerEntryData>[];

    // §21.11 — active-store scope. On "All Stores" the rows can span stores, so
    // show which store recorded each one.
    final scopeLabel = ref.watch(activeStoreLabelProvider);
    final isAllStores = ref.watch(lockedStoreProvider).value == null;
    final stores =
        ref.watch(allStoresProvider).valueOrNull ?? const <StoreData>[];
    final storeNameById = {for (final s in stores) s.id: s.name};

    final window = datePeriodFromLabel(_effectivePeriod);
    final filtered = history
        .where((e) => window.includes(e.activityDate))
        .toList();

    return ListView(
      // Extra bottom space so the Record Activity FAB doesn't cover the last row.
      padding: EdgeInsets.all(
        context.getRSize(20),
      ).copyWith(bottom: context.getRSize(96) + context.deviceBottomPadding),
      children: [
        _buildHeader(context, supplier),
        SizedBox(height: context.getRSize(24)),
        _buildBalanceCard(context, balanceKobo, scopeLabel),
        // §3.13 — Available Empty Crates section (Bar / Beverage distributor
        // only). Display-only in Phase 1; real-data wiring is deferred.
        if (isCrateBusiness(ref.watch(currentBusinessProvider)?.type)) ...[
          SizedBox(height: context.getRSize(24)),
          _buildEmptyCratesSection(context),
        ],
        SizedBox(height: context.getRSize(24)),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Activity',
              style: TextStyle(
                fontSize: context.getRFontSize(16),
                fontWeight: FontWeight.w800,
                color: _text,
              ),
            ),
            AppDropdown<String>(
              value: _effectivePeriod,
              width: context.getRSize(140),
              items: _periodOptions.map((val) {
                return DropdownMenuItem<String>(value: val, child: Text(val));
              }).toList(),
              onChanged: (val) {
                if (val != null) setState(() => _timeFilter = val);
              },
            ),
          ],
        ),
        SizedBox(height: context.getRSize(16)),
        _buildHistory(
          context,
          filtered,
          supplier: supplier,
          storeNameById: isAllStores ? storeNameById : null,
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context, SupplierData s) {
    final lines = <String>[
      if ((s.phone ?? '').isNotEmpty) s.phone!,
      if ((s.email ?? '').isNotEmpty) s.email!,
      if ((s.address ?? '').isNotEmpty) s.address!,
    ];
    final bank = [
      if ((s.bankName ?? '').isNotEmpty) s.bankName!,
      if ((s.bankAccountNumber ?? '').isNotEmpty) s.bankAccountNumber!,
      if ((s.bankAccountName ?? '').isNotEmpty) s.bankAccountName!,
    ].join(' • ');

    return Column(
      children: [
        Container(
          width: context.getRSize(80),
          height: context.getRSize(80),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(
            FontAwesomeIcons.buildingColumns.data,
            color: Theme.of(context).colorScheme.primary,
            size: context.getRSize(32),
          ),
        ),
        SizedBox(height: context.getRSize(16)),
        Text(
          s.name,
          style: TextStyle(
            fontSize: context.getRFontSize(22),
            fontWeight: FontWeight.w800,
            color: _text,
          ),
          textAlign: TextAlign.center,
        ),
        if (lines.isNotEmpty) ...[
          SizedBox(height: context.getRSize(8)),
          Text(
            lines.join(' • '),
            style: TextStyle(
              fontSize: context.getRFontSize(14),
              color: _subtext,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
          ),
        ],
        if (bank.isNotEmpty) ...[
          SizedBox(height: context.getRSize(4)),
          Text(
            bank,
            style: TextStyle(
              fontSize: context.getRFontSize(13),
              color: _subtext,
            ),
            textAlign: TextAlign.center,
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
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }

  Widget _buildBalanceCard(
    BuildContext context,
    int balanceKobo,
    String scopeLabel,
  ) {
    // Negative balance = we owe the supplier (red). Positive = credit (green).
    final owed = balanceKobo < 0;
    final color = owed ? danger : (balanceKobo > 0 ? success : _text);
    final label = owed
        ? 'Amount owed to supplier'
        : (balanceKobo > 0 ? 'Credit balance' : 'Settled');

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: EdgeInsets.all(context.getRSize(20)),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.05),
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: context.getRFontSize(14),
                    color: _subtext,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: context.getRSize(8)),
                Text(
                  formatCurrency(balanceKobo.abs() / 100),
                  style: TextStyle(
                    fontSize: context.getRFontSize(28),
                    color: color,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: context.getRSize(4)),
                // §21.11 — which store this balance is scoped to.
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
        ),
      ),
    );
  }

  /// §3.13 — display-only "Available Empty Crates" card for crate businesses.
  /// Real per-supplier crate-stock wiring is deferred to a later phase; this is
  /// a placeholder so the section is present as specified.
  Widget _buildEmptyCratesSection(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: EdgeInsets.all(context.getRSize(16)),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.05),
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      FontAwesomeIcons.boxesStacked.data,
                      size: context.getRSize(16),
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    SizedBox(width: context.getRSize(10)),
                    Text(
                      'Available Empty Crates',
                      style: TextStyle(
                        fontSize: context.getRFontSize(15),
                        fontWeight: FontWeight.w800,
                        color: _text,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: context.getRSize(10)),
                Text(
                  'Empty-crate tracking per supplier is coming soon. This section is a '
                  'preview — crate balances are not yet recorded against suppliers.',
                  style: TextStyle(
                    fontSize: context.getRFontSize(12),
                    color: _subtext,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHistory(
    BuildContext context,
    List<SupplierLedgerEntryData> entries, {
    required SupplierData supplier,
    Map<String, String>? storeNameById,
  }) {
    if (entries.isEmpty) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(context.getRSize(20)),
          child: Text(
            'No activity in this period',
            style: TextStyle(color: _subtext),
          ),
        ),
      );
    }
    // §21.7 — only a CEO can void an entry. The reversal compensating row itself
    // (and already-voided originals) is not voidable.
    final isCeo = ref.watch(currentUserRoleProvider)?.slug == 'ceo';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final e in entries)
          SupplierLedgerEntryTile(
            entry: e,
            onTap: isCeo ? () => _showEntryActions(supplier, e) : null,
            storeName: storeNameById == null
                ? null
                : (storeNameById[e.storeId] ??
                      (e.storeId == null ? 'Unassigned' : null)),
          ),
      ],
    );
  }

  /// §21.7 — CEO taps a ledger row → an action sheet offering Void / reversal.
  /// A `void` compensating row and an already-voided original are not voidable.
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
    // Write-boundary re-check — void is CEO only (§21.7).
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
