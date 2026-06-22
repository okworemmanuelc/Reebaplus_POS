import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/csv_export.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';
import 'package:reebaplus_pos/features/dashboard/screens/daily_reconciliation_detail_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_card.dart';
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
  DateTimeRange? _customRange;
  bool _isScrolled = false;

  Future<void> _exportCsv(List<ReconBucket> buckets, String scope) async {
    final rows = <List<String>>[
      for (final b in buckets)
        [b.label, '${b.itemsSold}', b.hasShortage ? 'Yes' : 'No'],
    ];
    final scopeName = scope.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    final periodName = _customRange != null
        ? 'custom'
        : _grouping.label.toLowerCase();
    
    final subjectScope = _customRange != null
        ? '$scope — ${DateFormat('MMM d').format(_customRange!.start)} to ${DateFormat('MMM d, yyyy').format(_customRange!.end)}'
        : '$scope — by ${_grouping.label}';

    try {
      await shareCsv(
        csv: buildCsv(['Period', 'Items sold', 'Mismatch'], rows),
        fileName: 'reconciliation_${periodName}_$scopeName',
        subject: 'Daily Reconciliation ($subjectScope)',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not export: $e')));
      }
    }
  }

  Future<void> _handlePeriodChange(Object? value, ThemeData theme) async {
    if (value is ReconGrouping) {
      setState(() {
        _grouping = value;
        _customRange = null;
      });
    } else if (value == 'custom') {
      final range = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2020),
        lastDate: DateTime.now().add(const Duration(days: 365)),
        initialDateRange: _customRange,
        builder: (context, child) => Theme(data: theme, child: child!),
      );
      if (range != null) {
        setState(() {
          _customRange = range;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider);
    final theme = Theme.of(context);
    final isCeo = ref.watch(currentUserRoleProvider)?.slug == 'ceo';
    final scopeLabel = ref.watch(activeStoreLabelProvider);
    final primary = theme.colorScheme.primary;

    // §25.9 — a Manager is capped at Month; only the CEO gets Year.
    final groupings = isCeo
        ? ReconGrouping.values
        : [ReconGrouping.day, ReconGrouping.week, ReconGrouping.month];
    if (!groupings.contains(_grouping)) _grouping = ReconGrouping.day;

    final Object currentValue = _customRange != null ? 'custom' : _grouping;
    final List<ReconBucket> buckets;
    
    if (_customRange != null) {
      buckets = buildReconBuckets(
        ref,
        start: _customRange!.start,
        endExclusive: _customRange!.end.add(const Duration(days: 1)),
        grouping: ReconGrouping.day,
      );
    } else {
      buckets = buildReconBuckets(ref, grouping: _grouping);
    }

    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: Container(
        decoration: AppDecorations.glassyBackground(context),
        child: SharedScaffold(
          activeRoute: 'dashboard',
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            elevation: 0,
            backgroundColor: _isScrolled
                ? theme.colorScheme.surface.withValues(alpha: 0.8)
                : Colors.transparent,
            surfaceTintColor: Colors.transparent,
            leading: BackButton(color: primary),
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
                  color: primary,
                ),
                onPressed: buckets.isEmpty
                    ? null
                    : () => _exportCsv(buckets, scopeLabel),
              ),
              SizedBox(width: context.getRSize(8)),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: context.getRSize(16)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(height: context.getRSize(8)),
                      Row(
                        children: [
                          Expanded(
                            child: AppDropdown<Object>(
                              labelText: 'Period',
                              value: currentValue,
                              items: [
                                ...groupings.map(
                                  (g) => DropdownMenuItem<Object>(
                                    value: g,
                                    child: Text(
                                      g.label,
                                      style: theme.textTheme.bodyMedium,
                                    ),
                                  ),
                                ),
                                DropdownMenuItem<Object>(
                                  value: 'custom',
                                  child: Text(
                                    'Custom range',
                                    style: theme.textTheme.bodyMedium,
                                  ),
                                ),
                              ],
                              onChanged: (v) => _handlePeriodChange(v, theme),
                            ),
                          ),
                          SizedBox(width: context.getRSize(16)),
                          const Expanded(child: SizedBox()),
                        ],
                      ),
                      if (_customRange != null) ...[
                        SizedBox(height: context.getRSize(8)),
                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: context.getRSize(12),
                            vertical: context.getRSize(6),
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surface.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(context.radiusL),
                            border: Border.all(
                              color: primary.withValues(alpha: 0.1),
                            ),
                          ),
                          child: Text(
                            '${DateFormat('MMM d, yyyy').format(_customRange!.start)} – ${DateFormat('MMM d, yyyy').format(_customRange!.end)}',
                            style: context.bodySmall.copyWith(
                              fontWeight: FontWeight.w600,
                              color: primary,
                            ),
                          ),
                        ),
                      ],
                      SizedBox(height: context.getRSize(20)),
                    ],
                  ),
                ),
                Expanded(
                  child: buckets.isEmpty
                      ? _emptyState(theme)
                      : ListView.separated(
                          padding: EdgeInsets.fromLTRB(
                            context.getRSize(16),
                            0,
                            context.getRSize(16),
                            context.spacingM + context.deviceBottomPadding,
                          ),
                          itemCount: buckets.length,
                          separatorBuilder: (_, __) => SizedBox(height: context.getRSize(12)),
                          itemBuilder: (_, i) => _bucketCard(theme, buckets[i]),
                        ),
                ),
              ],
            ),
          ),
        ),
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
    return GlassyCard(
      radius: context.radiusL,
      padding: EdgeInsets.zero,
      border: Border.all(
        color: mismatch
            ? theme.colorScheme.error.withValues(alpha: 0.3)
            : theme.colorScheme.primary.withValues(alpha: 0.05),
      ),
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
        child: Padding(
          padding: EdgeInsets.all(context.spacingM),
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
                    SizedBox(height: context.getRSize(4)),
                    Text(
                      '${fmtNumber(b.itemsSold)} items sold',
                      style: context.bodySmall.copyWith(color: theme.hintColor),
                    ),
                  ],
                ),
              ),
              if (mismatch)
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.getRSize(8),
                    vertical: context.getRSize(4),
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
              SizedBox(width: context.getRSize(8)),
              Icon(Icons.chevron_right_rounded, color: theme.hintColor),
            ],
          ),
        ),
      ),
    );
  }
}
