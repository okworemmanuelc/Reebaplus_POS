import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/features/payments/widgets/record_supplier_activity.dart';
import 'package:reebaplus_pos/features/payments/widgets/supplier_form_sheet.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

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

  List<String> get _periodOptions =>
      datePeriodLabelsForRole(managerUp: isManagerOrAbove(ref));

  String get _effectivePeriod => _periodOptions.contains(_timeFilter)
      ? _timeFilter
      : _periodOptions.last;

  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _cardBg => Theme.of(context).cardColor;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _border => Theme.of(context).dividerColor;

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider);
    final canManage =
        ref.watch(currentUserPermissionsProvider).contains('suppliers.manage');
    final isCeo = ref.watch(currentUserRoleProvider)?.slug == 'ceo';
    final supplierAsync = ref.watch(supplierByIdProvider(widget.supplierId));
    final supplier = supplierAsync.valueOrNull;

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _surface,
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
              icon: Icon(FontAwesomeIcons.penToSquare,
                  color: _text, size: context.getRSize(16)),
              tooltip: 'Edit supplier',
              onPressed: () => SupplierFormSheet.show(context, existing: supplier),
            ),
          if (isCeo && supplier != null)
            IconButton(
              icon: Icon(FontAwesomeIcons.trashCan,
                  color: danger, size: context.getRSize(16)),
              tooltip: 'Delete supplier',
              onPressed: () => _confirmDelete(supplier),
            ),
        ],
      ),
      body: !canManage
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
                      child: Text('Supplier not found',
                          style: TextStyle(color: _subtext))))
              : _buildBody(context, supplier),
    );
  }

  Widget _buildBody(BuildContext context, SupplierData supplier) {
    final balanceAsync = ref.watch(supplierBalanceProvider(widget.supplierId));
    final historyAsync =
        ref.watch(supplierLedgerHistoryProvider(widget.supplierId));
    final balanceKobo = balanceAsync.valueOrNull ?? 0;
    final history = historyAsync.valueOrNull ?? const <SupplierLedgerEntryData>[];

    final window = datePeriodFromLabel(_effectivePeriod);
    final filtered =
        history.where((e) => window.includes(e.activityDate)).toList();

    return ListView(
      padding: EdgeInsets.all(context.getRSize(20)).copyWith(
        bottom: context.getRSize(20) + context.deviceBottomPadding,
      ),
      children: [
        _buildHeader(context, supplier),
        SizedBox(height: context.getRSize(24)),
        _buildBalanceCard(context, balanceKobo),
        SizedBox(height: context.getRSize(16)),
        AppButton(
          text: 'Record Activity',
          icon: FontAwesomeIcons.plus,
          onPressed: () => showSupplierActivityChooser(
            context,
            supplierId: supplier.id,
            supplierName: supplier.name,
          ),
        ),
        SizedBox(height: context.getRSize(24)),
        _buildFilterTabs(context),
        SizedBox(height: context.getRSize(16)),
        _buildHistory(context, filtered),
        SizedBox(height: context.getRSize(40)),
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
            FontAwesomeIcons.buildingColumns,
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

  Widget _buildBalanceCard(BuildContext context, int balanceKobo) {
    // Negative balance = we owe the supplier (red). Positive = credit (green).
    final owed = balanceKobo < 0;
    final color = owed ? danger : (balanceKobo > 0 ? success : _text);
    final label = owed
        ? 'Amount owed to supplier'
        : (balanceKobo > 0 ? 'Credit balance' : 'Settled');

    return Container(
      padding: EdgeInsets.all(context.getRSize(20)),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _border),
      ),
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
        ],
      ),
    );
  }

  Widget _buildFilterTabs(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: _periodOptions.map((f) {
          final active = _effectivePeriod == f;
          return Padding(
            padding: EdgeInsets.only(right: context.getRSize(8)),
            child: GestureDetector(
              onTap: () => setState(() => _timeFilter = f),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: EdgeInsets.symmetric(
                  horizontal: context.getRSize(16),
                  vertical: context.getRSize(8),
                ),
                decoration: BoxDecoration(
                  color: active ? blueMain : _cardBg,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: active ? blueMain : _border),
                ),
                child: Text(
                  f,
                  style: TextStyle(
                    fontSize: context.getRFontSize(13),
                    fontWeight: active ? FontWeight.bold : FontWeight.w600,
                    color: active ? Colors.white : _subtext,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildHistory(
      BuildContext context, List<SupplierLedgerEntryData> entries) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Activity',
          style: TextStyle(
            fontSize: context.getRFontSize(16),
            fontWeight: FontWeight.w800,
            color: _text,
          ),
        ),
        SizedBox(height: context.getRSize(16)),
        if (entries.isEmpty)
          Center(
            child: Padding(
              padding: EdgeInsets.all(context.getRSize(20)),
              child: Text(
                'No activity in this period',
                style: TextStyle(color: _subtext),
              ),
            ),
          )
        else
          ...entries.map(_buildEntryCard),
      ],
    );
  }

  Widget _buildEntryCard(SupplierLedgerEntryData e) {
    final isVoided = e.voidedAt != null;
    final credit = e.signedAmountKobo >= 0;
    final color = isVoided ? _subtext : (credit ? success : danger);
    final sign = e.signedAmountKobo < 0 ? '-' : '+';
    final hasReceipt = (e.receiptPath ?? '').isNotEmpty;

    return Opacity(
      opacity: isVoided ? 0.55 : 1,
      child: Container(
        margin: EdgeInsets.only(bottom: context.getRSize(12)),
        padding: EdgeInsets.all(context.getRSize(16)),
        decoration: BoxDecoration(
          color: _cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _border),
        ),
        child: Row(
          children: [
            Container(
              width: context.getRSize(40),
              height: context.getRSize(40),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                _iconFor(e.referenceType),
                color: color,
                size: context.getRSize(16),
              ),
            ),
            SizedBox(width: context.getRSize(14)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          _friendlyRefType(e.referenceType),
                          style: TextStyle(
                            fontSize: context.getRFontSize(15),
                            fontWeight: FontWeight.bold,
                            color: _text,
                            decoration:
                                isVoided ? TextDecoration.lineThrough : null,
                          ),
                        ),
                      ),
                      if (hasReceipt) ...[
                        SizedBox(width: context.getRSize(6)),
                        Icon(FontAwesomeIcons.paperclip,
                            size: context.getRSize(11), color: _subtext),
                      ],
                    ],
                  ),
                  SizedBox(height: context.getRSize(4)),
                  Text(
                    DateFormat('d MMM y').format(e.activityDate) +
                        ((e.referenceNote ?? '').isNotEmpty
                            ? ' • ${e.referenceNote}'
                            : ''),
                    style: TextStyle(
                      fontSize: context.getRFontSize(12),
                      color: _subtext,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            SizedBox(width: context.getRSize(8)),
            Text(
              '$sign${formatCurrency(e.amountKobo / 100)}',
              style: TextStyle(
                fontSize: context.getRFontSize(15),
                fontWeight: FontWeight.w800,
                color: color,
                decoration: isVoided ? TextDecoration.lineThrough : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(String refType) {
    if (refType == 'invoice') return FontAwesomeIcons.fileInvoiceDollar;
    if (refType == 'void') return FontAwesomeIcons.rotateLeft;
    return FontAwesomeIcons.moneyBillTransfer;
  }

  String _friendlyRefType(String refType) {
    switch (refType) {
      case 'invoice':
        return 'Invoice';
      case 'payment_cash':
        return 'Payment (Cash)';
      case 'payment_transfer':
        return 'Payment (Transfer)';
      case 'payment_pos':
        return 'Payment (POS)';
      case 'payment_other':
        return 'Payment (Other)';
      case 'void':
        return 'Void / reversal';
      default:
        return refType;
    }
  }

  Future<void> _confirmDelete(SupplierData supplier) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _surface,
        title: Text('Delete supplier?',
            style: TextStyle(color: _text, fontWeight: FontWeight.bold)),
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
    if (!ref.read(currentUserPermissionsProvider).contains('suppliers.manage')) {
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
          context, 'Could not delete supplier. Please try again.');
    }
  }
}
