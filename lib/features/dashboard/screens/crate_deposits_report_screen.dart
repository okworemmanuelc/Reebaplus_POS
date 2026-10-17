import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/database/daos.dart' show CrateDepositSummary;
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/features/dashboard/widgets/report_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
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

    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: SharedScaffold(
        activeRoute: 'dashboard',
        backgroundColor: Colors.transparent,
        appBar: ReportTopBar(
          key: ReportKeys.topBar,
          height: reportTopBarHeight(context),
          header: ScreenHeader(
            leading: const ReportBackButton(),
            icon: AppIcons.beerMug,
            title: 'Crate Deposits',
            subtitle: ref.watch(activeStoreLabelProvider),
            actions: [
              if (summary != null)
                ReportBarAction(
                  key: ReportKeys.export,
                  icon: AppIcons.export,
                  tooltip: 'Export CSV',
                  onPressed: () => _exportCsv(context, summary, held, nameOf),
                ),
            ],
          ),
        ),
        body: summaryAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Could not load: $e')),
          data: (s) => LayoutBuilder(
            builder: (context, constraints) {
              final gutter = reportGutter(context, constraints.maxWidth);
              return ListView(
                padding: EdgeInsets.fromLTRB(
                  gutter,
                  context.getRSize(16),
                  gutter,
                  context.getRSize(16) + context.deviceBottomPadding,
                ),
                children: [
                  _heldCard(context, s),
                  SizedBox(height: context.getRSize(12)),
                  _breakdownCard(context, s),
                  SizedBox(height: context.getRSize(16)),
                  const ReportGroupLabel('By customer'),
                  SizedBox(height: context.getRSize(10)),
                  if (held.isEmpty)
                    _emptyHint(context)
                  else
                    ...held.map(
                      (e) => _customerTile(context, nameOf(e.key), e.value),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  // Big "held now" headline.
  Widget _heldCard(BuildContext context, CrateDepositSummary s) {
    return ReportHeadlineCard(
      icon: AppIcons.beerMug,
      tone: IconTileTone.warning,
      label: 'Deposits held now',
      figure: formatCurrency(s.heldKobo / 100.0),
      figureColor: Theme.of(context).colorScheme.primary,
      note: 'Returnable crate deposits recorded for customers.',
    );
  }

  // Taken − Refunded − Kept = Held, with the identity spelled out.
  Widget _breakdownCard(BuildContext context, CrateDepositSummary s) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return ReportCard(
      child: Column(
        children: [
          _row(context, 'Deposits taken', s.takenKobo, null),
          _row(context, 'Refunded', s.refundedKobo, f.warning, prefix: '− '),
          _row(context, 'Kept (income)', s.keptKobo, f.green, prefix: '− '),
          const ReportDivider(),
          _row(
            context,
            'Held now',
            s.heldKobo,
            t.colorScheme.primary,
            bold: true,
          ),
          SizedBox(height: context.getRSize(6)),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Held = Taken − Refunded − Kept',
              style: context
                  .regularStyle(12)
                  .copyWith(color: muted, fontStyle: FontStyle.italic),
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
    return ReportValueRow(
      label: label,
      value: '$prefix${formatCurrency(kobo / 100.0)}',
      valueColor: color,
      bold: bold,
    );
  }

  Widget _customerTile(BuildContext context, String name, int kobo) {
    final t = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: context.getRSize(8)),
      child: ReportCard(
        padding: EdgeInsets.all(context.getRSize(14)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 32),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                flex: 3,
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context
                      .boldStyle(14)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
              ),
              SizedBox(width: context.getRSize(12)),
              Flexible(
                flex: 2,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    formatCurrency(kobo / 100.0),
                    maxLines: 1,
                    style: context
                        .extraBoldStyle(14)
                        .copyWith(color: t.colorScheme.primary),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyHint(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return ReportCard(
      padding: EdgeInsets.all(context.getRSize(20)),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          children: [
            const IconTile(
              icon: AppIcons.box,
              tone: IconTileTone.neutral,
              size: 48,
            ),
            SizedBox(height: context.getRSize(10)),
            Text(
              'No deposits are being held right now.',
              textAlign: TextAlign.center,
              style: context.mediumStyle(13).copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}
