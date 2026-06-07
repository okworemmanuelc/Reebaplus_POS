import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/csv_export.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';

/// Customer Ledger report (§25.2) — wallet balances, top debtors and top credit
/// balances across all registered customers. The wallet balance is the live
/// `SUM(signed_amount_kobo)` of each customer's ledger: **negative means the
/// customer owes** (a debtor), **positive means they hold credit**. Walk-ins are
/// excluded — they never route through a wallet (rule #14).
///
/// Balances are point-in-time (the running total of an append-only ledger), so
/// this report shows the *current* position and carries no rolling period filter
/// (§30.11 windows describe a span, not an as-of date). Role visibility (§25.3)
/// is enforced upstream — only CEO/Manager reach the Reports hub.
class CustomerLedgerScreen extends ConsumerStatefulWidget {
  const CustomerLedgerScreen({super.key});

  @override
  ConsumerState<CustomerLedgerScreen> createState() =>
      _CustomerLedgerScreenState();
}

class _CustomerLedgerScreenState extends ConsumerState<CustomerLedgerScreen> {
  _LedgerData _compute(List<Customer> customers, Map<String, int> balances) {
    final entries = <_LedgerEntry>[];
    for (final c in customers) {
      if (c.isWalkIn) continue;
      final balanceKobo = balances[c.id] ?? 0;
      if (balanceKobo == 0) continue;
      entries.add(_LedgerEntry(
        name: c.name,
        phone: c.phone,
        balanceKobo: balanceKobo,
      ));
    }
    final debtors = entries.where((e) => e.balanceKobo < 0).toList()
      ..sort((a, b) => a.balanceKobo.compareTo(b.balanceKobo));
    final creditors = entries.where((e) => e.balanceKobo > 0).toList()
      ..sort((a, b) => b.balanceKobo.compareTo(a.balanceKobo));
    return _LedgerData(
      debtors: debtors,
      creditors: creditors,
      totalOwedKobo: debtors.fold<int>(0, (s, e) => s - e.balanceKobo),
      totalCreditKobo: creditors.fold<int>(0, (s, e) => s + e.balanceKobo),
    );
  }

  Future<void> _exportCsv(_LedgerData data) async {
    final rows = <List<String>>[
      for (final e in [...data.debtors, ...data.creditors])
        [
          e.name,
          e.phone ?? '',
          (e.balanceKobo / 100.0).toStringAsFixed(2),
          e.balanceKobo < 0 ? 'Owes' : 'Credit',
        ],
    ];
    try {
      await shareCsv(
        csv: buildCsv(['Customer', 'Phone', 'Balance', 'Status'], rows),
        fileName: 'customer_ledger',
        subject: 'Customer Ledger',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not export: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider); // rebuild money displays when currency changes
    final theme = Theme.of(context);
    final customers = ref.watch(customerServiceProvider).value;
    final balances =
        ref.watch(walletBalancesKoboProvider).valueOrNull ?? const {};
    final data = _compute(customers, balances);
    final hasData = data.debtors.isNotEmpty || data.creditors.isNotEmpty;

    return SharedScaffold(
      activeRoute: 'dashboard',
      appBar: AppBar(
        title: Text(
          'Customer Ledger',
          style: context.h3.copyWith(fontWeight: FontWeight.bold),
        ),
        elevation: 0,
        backgroundColor: context.backgroundColor,
        leading: BackButton(color: context.primaryColor),
        actions: [
          IconButton(
            tooltip: 'Export CSV',
            icon: Icon(FontAwesomeIcons.fileCsv,
                size: 18, color: context.primaryColor),
            onPressed: hasData ? () => _exportCsv(data) : null,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: !hasData
          ? _emptyState(theme)
          : ListView(
              padding: EdgeInsets.all(context.spacingM).copyWith(
                bottom: context.spacingM + context.deviceBottomPadding,
              ),
              children: [
                _headline(theme, data),
                if (data.debtors.isNotEmpty) ...[
                  SizedBox(height: context.spacingM),
                  _section(theme, 'Top debtors', data.debtors, owed: true),
                ],
                if (data.creditors.isNotEmpty) ...[
                  SizedBox(height: context.spacingM),
                  _section(theme, 'In credit', data.creditors, owed: false),
                ],
              ],
            ),
    );
  }

  Widget _emptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(FontAwesomeIcons.wallet,
              size: 40, color: theme.hintColor.withValues(alpha: 0.5)),
          SizedBox(height: context.spacingM),
          Text('No customer balances yet.',
              style: context.bodyMedium.copyWith(color: theme.hintColor)),
        ],
      ),
    );
  }

  Widget _headline(ThemeData theme, _LedgerData data) {
    return Row(
      children: [
        _statTile(theme, 'Owed to you',
            formatCurrency(data.totalOwedKobo / 100.0),
            color: theme.colorScheme.error),
        SizedBox(width: context.spacingS),
        _statTile(theme, 'Customer credit',
            formatCurrency(data.totalCreditKobo / 100.0),
            color: const Color(0xFF22C55E)),
        SizedBox(width: context.spacingS),
        _statTile(theme, 'Debtors', '${data.debtors.length}',
            color: context.primaryColor),
      ],
    );
  }

  Widget _statTile(ThemeData theme, String label, String value,
      {required Color color}) {
    return Expanded(
      child: Container(
        padding: EdgeInsets.all(context.spacingM),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(context.radiusL),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value,
                style: context.bodyMedium.copyWith(
                    fontWeight: FontWeight.bold, color: color, fontSize: 15)),
            const SizedBox(height: 2),
            Text(label,
                style: context.bodySmall.copyWith(color: theme.hintColor)),
          ],
        ),
      ),
    );
  }

  Widget _section(ThemeData theme, String title, List<_LedgerEntry> entries,
      {required bool owed}) {
    return Container(
      padding: EdgeInsets.all(context.spacingM),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(context.radiusL),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: context.bodyMedium.copyWith(fontWeight: FontWeight.bold)),
          SizedBox(height: context.spacingS),
          for (var i = 0; i < entries.length; i++) ...[
            if (i > 0)
              Divider(
                  height: context.spacingM,
                  color: theme.dividerColor.withValues(alpha: 0.2)),
            _entryRow(theme, entries[i], owed: owed),
          ],
        ],
      ),
    );
  }

  Widget _entryRow(ThemeData theme, _LedgerEntry e, {required bool owed}) {
    final color = owed ? theme.colorScheme.error : const Color(0xFF22C55E);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(e.name,
                  style:
                      context.bodyMedium.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              if (e.phone != null && e.phone!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(e.phone!,
                    style: context.bodySmall.copyWith(color: theme.hintColor)),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(formatCurrency(e.balanceKobo.abs() / 100.0),
            style: context.bodyMedium
                .copyWith(fontWeight: FontWeight.w700, color: color)),
      ],
    );
  }
}

class _LedgerData {
  _LedgerData({
    required this.debtors,
    required this.creditors,
    required this.totalOwedKobo,
    required this.totalCreditKobo,
  });

  final List<_LedgerEntry> debtors;
  final List<_LedgerEntry> creditors;
  final int totalOwedKobo;
  final int totalCreditKobo;
}

class _LedgerEntry {
  _LedgerEntry({
    required this.name,
    required this.phone,
    required this.balanceKobo,
  });

  final String name;
  final String? phone;
  final int balanceKobo;
}
