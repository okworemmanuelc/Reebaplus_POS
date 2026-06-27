import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/database/daos.dart' show CrateDepositSummary;
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/csv_export.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';

/// §13.4 Ring 7 — the Crate Deposits balancing report. Crate deposits are
/// refundable money the business HOLDS for customers (never income until the
/// crates are forfeited). This report proves the books balance:
///
///   Held = Taken − Refunded − Kept
///
/// where Taken is every deposit collected, Refunded is what was given back,
/// Kept is what was forfeited (income), and Held is what's still owed back to
/// customers right now. All four come from the one credit ledger (the
/// `crate_deposit` / `crate_deposit_refunded` / `crate_deposit_forfeited`
/// family) — there is no separate deposit money store. Role visibility (§25.3)
/// is enforced upstream: only CEO/Manager reach the Reports hub.
class CrateDepositsReportScreen extends ConsumerWidget {
  const CrateDepositsReportScreen({super.key});

  Future<void> _exportCsv(
    BuildContext context,
    CrateDepositSummary s,
    List<MapEntry<String, int>> held,
    String Function(String) nameOf,
  ) async {
    final rows = <List<String>>[
      ['Deposits taken', (s.takenKobo / 100.0).toStringAsFixed(2)],
      ['Refunded', (s.refundedKobo / 100.0).toStringAsFixed(2)],
      ['Kept (income)', (s.keptKobo / 100.0).toStringAsFixed(2)],
      ['Held now', (s.heldKobo / 100.0).toStringAsFixed(2)],
      [],
      ['Customer', 'Deposit held'],
      for (final e in held)
        [nameOf(e.key), (e.value / 100.0).toStringAsFixed(2)],
    ];
    try {
      await shareCsv(
        csv: buildCsv(const ['Item', 'Amount'], rows),
        fileName: 'crate_deposits',
        subject: 'Crate Deposits',
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not export: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(
      currencySymbolProvider,
    ); // rebuild money displays on currency change
    final summaryAsync = ref.watch(crateDepositSummaryProvider);
    final heldByCustomer =
        ref.watch(depositsHeldByCustomerProvider).valueOrNull ?? const {};
    final customers = ref.watch(customerServiceProvider).value;
    String nameOf(String id) {
      for (final c in customers) {
        if (c.id == id) return c.name;
      }
      return 'Customer';
    }

    final summary = summaryAsync.valueOrNull;

    // Customers currently holding a deposit, largest first.
    final held = heldByCustomer.entries.where((e) => e.value != 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return SharedScaffold(
      activeRoute: 'dashboard',
      appBar: AppBar(
        title: Text(
          'Crate Deposits',
          style: context.h3.copyWith(fontWeight: FontWeight.bold),
        ),
        elevation: 0,
        backgroundColor: context.backgroundColor,
        leading: BackButton(color: context.primaryColor),
        actions: [
          if (summary != null)
            IconButton(
              tooltip: 'Export CSV',
              icon: Icon(
                FontAwesomeIcons.fileExport.data,
                size: 18,
                color: context.primaryColor,
              ),
              onPressed: () => _exportCsv(context, summary, held, nameOf),
            ),
        ],
      ),
      body: summaryAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load: $e')),
        data: (s) => ListView(
          padding: EdgeInsets.all(
            context.spacingM,
          ).copyWith(bottom: context.spacingM + context.deviceBottomPadding),
          children: [
            _heldCard(context, s),
            SizedBox(height: context.spacingM),
            _breakdownCard(context, s),
            SizedBox(height: context.spacingM),
            Text(
              'By customer',
              style: context.bodyMedium.copyWith(fontWeight: FontWeight.bold),
            ),
            SizedBox(height: context.spacingS),
            if (held.isEmpty)
              _emptyHint(context)
            else
              ...held.map(
                (e) => _customerTile(context, nameOf(e.key), e.value),
              ),
          ],
        ),
      ),
    );
  }

  // Big "held now" headline.
  Widget _heldCard(BuildContext context, CrateDepositSummary s) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(context.spacingL),
      decoration: BoxDecoration(
        color: context.primaryColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(context.radiusL),
        border: Border.all(color: context.primaryColor.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                FontAwesomeIcons.beerMugEmpty.data,
                size: 16,
                color: context.primaryColor,
              ),
              const SizedBox(width: 8),
              Text(
                'Deposits held now',
                style: context.bodySmall.copyWith(
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).hintColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            formatCurrency(s.heldKobo / 100.0),
            style: context.h2.copyWith(
              fontWeight: FontWeight.w900,
              color: context.primaryColor,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Returnable crate deposits recorded for customers.',
            style: context.bodySmall.copyWith(
              color: Theme.of(context).hintColor,
            ),
          ),
        ],
      ),
    );
  }

  // Taken − Refunded − Kept = Held, with the identity spelled out.
  Widget _breakdownCard(BuildContext context, CrateDepositSummary s) {
    return Container(
      padding: EdgeInsets.all(context.spacingM),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(context.radiusL),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(
        children: [
          _row(context, 'Deposits taken', s.takenKobo, null),
          _row(
            context,
            'Refunded',
            s.refundedKobo,
            Colors.orange,
            prefix: '− ',
          ),
          _row(
            context,
            'Kept (income)',
            s.keptKobo,
            Colors.green,
            prefix: '− ',
          ),
          Divider(
            height: context.spacingL,
            color: Theme.of(context).dividerColor,
          ),
          _row(
            context,
            'Held now',
            s.heldKobo,
            context.primaryColor,
            bold: true,
          ),
          const SizedBox(height: 6),
          Text(
            'Held = Taken − Refunded − Kept',
            style: context.bodySmall.copyWith(
              color: Theme.of(context).hintColor,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    String label,
    int kobo,
    Color? color, {
    bool bold = false,
    String prefix = '',
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: context.bodyMedium.copyWith(
              fontWeight: bold ? FontWeight.bold : FontWeight.w500,
            ),
          ),
          Text(
            '$prefix${formatCurrency(kobo / 100.0)}',
            style: context.bodyMedium.copyWith(
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _customerTile(BuildContext context, String name, int kobo) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.symmetric(
        horizontal: context.spacingM,
        vertical: context.spacingS + 2,
      ),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(context.radiusM),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.bodyMedium.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          Text(
            formatCurrency(kobo / 100.0),
            style: context.bodyMedium.copyWith(
              fontWeight: FontWeight.w800,
              color: context.primaryColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyHint(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(context.spacingL),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(context.radiusL),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(
        children: [
          Icon(
            FontAwesomeIcons.boxOpen.data,
            size: 28,
            color: Theme.of(context).hintColor,
          ),
          const SizedBox(height: 10),
          Text(
            'No deposits are being held right now.',
            style: context.bodySmall.copyWith(
              color: Theme.of(context).hintColor,
            ),
          ),
        ],
      ),
    );
  }
}
