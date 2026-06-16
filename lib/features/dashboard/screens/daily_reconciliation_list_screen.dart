import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/csv_export.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';
import 'package:reebaplus_pos/features/dashboard/screens/daily_reconciliation_detail_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/slide_route.dart';

/// Daily Reconciliation entry list (§25.9). Store-scoped via the §12.1 picker and
/// groupable by Day / Week / Month / Year — one tappable card per bucket that has
/// data, newest first. A **Manager is capped at Month** (no Year). Tapping a
/// bucket opens its reconciliation, which (for non-Day buckets) drills further
/// down to the day leaf. Role-gated upstream (CEO/Manager only, §25.3).
class DailyReconciliationListScreen extends ConsumerStatefulWidget {
  const DailyReconciliationListScreen({super.key});

  @override
  ConsumerState<DailyReconciliationListScreen> createState() =>
      _DailyReconciliationListScreenState();
}

class _DailyReconciliationListScreenState
    extends ConsumerState<DailyReconciliationListScreen> {
  ReconGrouping _grouping = ReconGrouping.day;

  Future<void> _exportCsv(List<ReconBucket> buckets, String scope) async {
    final rows = <List<String>>[
      for (final b in buckets)
        [b.label, '${b.itemsSold}', b.hasShortage ? 'Yes' : 'No'],
    ];
    try {
      await shareCsv(
        csv: buildCsv(['Period', 'Items sold', 'Mismatch'], rows),
        fileName:
            'reconciliation_${_grouping.label.toLowerCase()}_${scope.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')}',
        subject: 'Daily Reconciliation ($scope) — by ${_grouping.label}',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not export: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider);
    final theme = Theme.of(context);
    final isCeo = ref.watch(currentUserRoleProvider)?.slug == 'ceo';
    final scopeLabel = ref.watch(activeStoreLabelProvider);

    // §25.9 — a Manager is capped at Month; only the CEO gets Year.
    final groupings = isCeo
        ? ReconGrouping.values
        : [ReconGrouping.day, ReconGrouping.week, ReconGrouping.month];
    if (!groupings.contains(_grouping)) _grouping = ReconGrouping.day;

    final buckets = buildReconBuckets(ref, grouping: _grouping);

    return SharedScaffold(
      activeRoute: 'dashboard',
      appBar: AppBar(
        elevation: 0,
        backgroundColor: context.backgroundColor,
        leading: BackButton(color: context.primaryColor),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Daily Reconciliation',
              style: context.h3.copyWith(fontWeight: FontWeight.bold),
            ),
            Text(
              scopeLabel,
              style: context.bodySmall.copyWith(color: theme.hintColor),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Export CSV',
            icon: Icon(
              FontAwesomeIcons.fileCsv.data,
              size: 18,
              color: context.primaryColor,
            ),
            onPressed: buckets.isEmpty
                ? null
                : () => _exportCsv(buckets, scopeLabel),
          ),
          SizedBox(
            width: 96,
            child: AppDropdown<ReconGrouping>(
              value: _grouping,
              items: groupings
                  .map(
                    (g) => DropdownMenuItem(
                      value: g,
                      child: Text(
                        g.label,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) =>
                  setState(() => _grouping = v ?? ReconGrouping.day),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: buckets.isEmpty
          ? _emptyState(theme)
          : ListView.separated(
              padding: EdgeInsets.all(context.spacingM).copyWith(
                bottom: context.spacingM + context.deviceBottomPadding,
              ),
              itemCount: buckets.length,
              separatorBuilder: (_, __) => SizedBox(height: context.spacingS),
              itemBuilder: (_, i) => _bucketCard(theme, buckets[i]),
            ),
    );
  }

  Widget _emptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            FontAwesomeIcons.clipboardCheck.data,
            size: 40,
            color: theme.hintColor.withValues(alpha: 0.5),
          ),
          SizedBox(height: context.spacingM),
          Text(
            'No data for this period.',
            style: context.bodyMedium.copyWith(color: theme.hintColor),
          ),
        ],
      ),
    );
  }

  Widget _bucketCard(ThemeData theme, ReconBucket b) {
    final mismatch = b.hasShortage;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(context.radiusL),
        onTap: () => Navigator.push(
          context,
          slideDownRoute(
            DailyReconciliationDetailScreen(
              start: b.start,
              endExclusive: b.endExclusive,
              grouping: b.grouping,
              title: b.label,
            ),
          ),
        ),
        child: Container(
          padding: EdgeInsets.all(context.spacingM),
          decoration: BoxDecoration(
            color: context.surfaceColor,
            borderRadius: BorderRadius.circular(context.radiusL),
            border: Border.all(
              color: mismatch
                  ? theme.colorScheme.error.withValues(alpha: 0.3)
                  : theme.dividerColor.withValues(alpha: 0.2),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      b.label,
                      style: context.bodyMedium.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${fmtNumber(b.itemsSold)} items sold',
                      style: context.bodySmall.copyWith(color: theme.hintColor),
                    ),
                  ],
                ),
              ),
              if (mismatch)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.error.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'Mismatch',
                    style: context.bodySmall.copyWith(
                      color: theme.colorScheme.error,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, color: theme.hintColor),
            ],
          ),
        ),
      ),
    );
  }
}
