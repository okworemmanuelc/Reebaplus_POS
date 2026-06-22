import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_card.dart';

/// §25.2 — Supplier Accounts Report. One row per supplier showing the current
/// outstanding balance, total paid, and total received (invoice totals), scoped
/// to the active store via the §12.1 picker. Gross paid/received exclude voided
/// entries; the balance nets the void's compensating row.
class SupplierAccountsReportScreen extends ConsumerStatefulWidget {
  const SupplierAccountsReportScreen({super.key});

  @override
  ConsumerState<SupplierAccountsReportScreen> createState() =>
      _SupplierAccountsReportScreenState();
}

class _SupplierAccountsReportScreenState extends ConsumerState<SupplierAccountsReportScreen> {
  bool _isScrolled = false;

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider);
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final surface = Theme.of(context).colorScheme.surface;
    final text = Theme.of(context).colorScheme.onSurface;
    final subtext =
        Theme.of(context).textTheme.bodySmall?.color ??
        Theme.of(context).iconTheme.color!;

    final entries =
        ref.watch(supplierAllHistoryProvider).valueOrNull ??
        const <SupplierLedgerEntryData>[];
    final suppliers =
        ref.watch(allSuppliersProvider).valueOrNull ?? const <SupplierData>[];
    final scopeLabel = ref.watch(activeStoreLabelProvider);

    final rows = _aggregate(suppliers, entries);

    return ColoredBox(
      color: bg,
      child: Container(
        decoration: AppDecorations.glassyBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: _isScrolled
              ? surface.withValues(alpha: 0.8)
              : Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: Icon(Icons.arrow_back_ios_new, color: text, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
          title: Text(
            'Supplier Accounts Report',
            style: TextStyle(
              color: text,
              fontSize: context.getRFontSize(18),
              fontWeight: FontWeight.w800,
            ),
          ),
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
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  context.getRSize(20),
                  context.getRSize(12),
                  context.getRSize(20),
                  context.getRSize(4),
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Balances for: $scopeLabel',
                    style: TextStyle(
                      color: subtext,
                      fontSize: context.getRFontSize(12),
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              Expanded(
                child: rows.isEmpty
                    ? Center(
                        child: Text(
                          'No suppliers added yet',
                          style: TextStyle(color: subtext),
                        ),
                      )
                    : ListView.builder(
                        padding: EdgeInsets.fromLTRB(
                          context.getRSize(16),
                          context.getRSize(8),
                          context.getRSize(16),
                          context.getRSize(24) + context.deviceBottomPadding,
                        ),
                        itemCount: rows.length,
                        itemBuilder: (_, i) => _SupplierReportRow(
                          row: rows[i],
                          text: text,
                          subtext: subtext,
                          border: Theme.of(context).dividerColor,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    ),
    );
  }

  /// Folds the store-scoped ledger into a per-supplier summary. Gross totals
  /// skip voided originals and `void` rows; balance sums every signed row.
  List<_SupplierReportData> _aggregate(
    List<SupplierData> suppliers,
    List<SupplierLedgerEntryData> entries,
  ) {
    final balance = <String, int>{};
    final paid = <String, int>{};
    final received = <String, int>{};
    final nameById = {for (final s in suppliers) s.id: s.name};

    for (final e in entries) {
      balance[e.supplierId] = (balance[e.supplierId] ?? 0) + e.signedAmountKobo;
      if (e.voidedAt != null || e.referenceType == 'void') continue;
      if (e.referenceType == 'invoice') {
        received[e.supplierId] = (received[e.supplierId] ?? 0) + e.amountKobo;
      } else if (e.referenceType.startsWith('payment_')) {
        paid[e.supplierId] = (paid[e.supplierId] ?? 0) + e.amountKobo;
      }
    }

    // One row per active supplier, plus any former (soft-deleted) supplier that
    // still has ledger history under the active scope (§17.5).
    final ids = <String>{...nameById.keys, ...balance.keys};
    final out = ids
        .map(
          (id) => _SupplierReportData(
            supplierId: id,
            name: nameById[id] ?? 'Former supplier',
            balanceKobo: balance[id] ?? 0,
            paidKobo: paid[id] ?? 0,
            receivedKobo: received[id] ?? 0,
          ),
        )
        .toList();
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }
}

class _SupplierReportData {
  final String supplierId;
  final String name;
  final int balanceKobo;
  final int paidKobo;
  final int receivedKobo;

  const _SupplierReportData({
    required this.supplierId,
    required this.name,
    required this.balanceKobo,
    required this.paidKobo,
    required this.receivedKobo,
  });
}

class _SupplierReportRow extends StatelessWidget {
  final _SupplierReportData row;
  final Color text;
  final Color subtext;
  final Color border;

  const _SupplierReportRow({
    required this.row,
    required this.text,
    required this.subtext,
    required this.border,
  });

  @override
  Widget build(BuildContext context) {
    final owed = row.balanceKobo < 0;
    final balColor = owed ? danger : (row.balanceKobo > 0 ? success : subtext);
    final balLabel = owed
        ? 'Owed ${formatCurrency(row.balanceKobo.abs() / 100)}'
        : (row.balanceKobo > 0
              ? 'Credit ${formatCurrency(row.balanceKobo / 100)}'
              : 'Settled');

    return GlassyCard(
      margin: EdgeInsets.only(bottom: context.getRSize(12)),
      padding: EdgeInsets.all(context.getRSize(16)),
      backgroundColor: Theme.of(context).colorScheme.surface.withValues(alpha: 0.4),
      border: Border.all(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.05),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  row.name,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: context.getRFontSize(16),
                    color: text,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(width: context.getRSize(8)),
              Text(
                balLabel,
                style: TextStyle(
                  color: balColor,
                  fontSize: context.getRFontSize(13),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          SizedBox(height: context.getRSize(12)),
          Row(
            children: [
              Expanded(
                child: _stat(
                  context,
                  'Total received',
                  formatCurrency(row.receivedKobo / 100),
                  danger,
                ),
              ),
              Expanded(
                child: _stat(
                  context,
                  'Total paid',
                  formatCurrency(row.paidKobo / 100),
                  success,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(
    BuildContext context,
    String label,
    String value,
    Color valueColor,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(color: subtext, fontSize: context.getRFontSize(11)),
        ),
        SizedBox(height: context.getRSize(2)),
        Text(
          value,
          style: TextStyle(
            color: valueColor,
            fontSize: context.getRFontSize(14),
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}
