import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/csv_export.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';
import 'package:reebaplus_pos/features/dashboard/reports_attention.dart';
import 'package:reebaplus_pos/features/dashboard/screens/daily_reconciliation_detail_screen.dart';
import 'package:reebaplus_pos/features/dashboard/widgets/changed_since_review_badge.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/features/dashboard/widgets/report_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
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

  @override
  void initState() {
    super.initState();
    // Opening the Daily Reconciliation report marks its daily stock counts
    // reviewed for this viewer, clearing the Home Reports attention dot's
    // stock-count reason (issue #119). Per-user, device-local; deferred past
    // first build so it never mutates a provider mid-build.
    Future.microtask(
      () => ref.read(reconReviewMarkerProvider.notifier).markOpenedNow(),
    );
  }

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

    // #192 — the reviewed days whose figures have moved since. Before this the
    // only way to learn a reviewed day had changed was to already be inside it,
    // so a day that moved after review stayed silent unless someone happened to
    // re-open it.
    //
    // Watched ONLY while day buckets are on screen: a week/month/year bucket
    // holds no day close, so the sweep (a pass over every report row set) would
    // be paid for an answer nothing could render. Riverpod re-resolves the
    // dependency set on every build, so switching the period picker back to Day
    // simply picks it up — the same conditional-watch shape the detail screen
    // uses for its day-close basis.
    final showsDayBuckets =
        _customRange != null || _grouping == ReconGrouping.day;
    final changedDays = showsDayBuckets
        ? ref.watch(changedReviewedDaysProvider)
        : const <String>{};

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
            icon: AppIcons.auditCheck,
            title: 'Daily Reconciliation',
            subtitle: scopeLabel,
            actions: [
              ReportBarAction(
                key: ReportKeys.export,
                icon: AppIcons.fileCsv,
                tooltip: 'Export CSV',
                onPressed: buckets.isEmpty
                    ? null
                    : () => _exportCsv(buckets, scopeLabel),
              ),
            ],
          ),
        ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final gutter = reportGutter(context, constraints.maxWidth);
            final onSurface = theme.colorScheme.onSurface;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    gutter,
                    context.getRSize(12),
                    gutter,
                    context.getRSize(4),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppDropdown<Object>(
                        key: ReportKeys.period,
                        labelText: 'Period',
                        value: currentValue,
                        items: [
                          ...groupings.map(
                            (g) => DropdownMenuItem<Object>(
                              value: g,
                              child: Text(
                                g.label,
                                style: context
                                    .mediumStyle(14)
                                    .copyWith(color: onSurface),
                              ),
                            ),
                          ),
                          DropdownMenuItem<Object>(
                            value: 'custom',
                            child: Text(
                              'Custom range',
                              style: context
                                  .mediumStyle(14)
                                  .copyWith(color: onSurface),
                            ),
                          ),
                        ],
                        onChanged: (v) => _handlePeriodChange(v, theme),
                      ),
                      if (_customRange != null) ...[
                        SizedBox(height: context.getRSize(8)),
                        ReportChip(
                          '${DateFormat('MMM d, yyyy').format(_customRange!.start)} – ${DateFormat('MMM d, yyyy').format(_customRange!.end)}',
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: buckets.isEmpty
                      ? const ReportEmpty(
                          icon: AppIcons.auditCheck,
                          message: 'No data for this period.',
                        )
                      : ListView.separated(
                          padding: EdgeInsets.fromLTRB(
                            gutter,
                            context.getRSize(8),
                            gutter,
                            context.getRSize(16) + context.deviceBottomPadding,
                          ),
                          itemCount: buckets.length,
                          separatorBuilder: (_, __) =>
                              SizedBox(height: context.getRSize(12)),
                          itemBuilder: (_, i) => _bucketCard(
                            theme,
                            buckets[i],
                            changedDays: changedDays,
                          ),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _bucketCard(
    ThemeData theme,
    ReconBucket b, {
    required Set<String> changedDays,
  }) {
    final mismatch = b.hasShortage;
    // #192 — this day was reviewed and has moved since. Neutral WARNING
    // treatment (not the error red a stock mismatch gets): history mutating
    // after a review is a "look again", not a fault.
    final movedSinceReview =
        b.grouping == ReconGrouping.day &&
        changedDays.contains(reconDayKey(b.start));
    final f = theme.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted =
        theme.textTheme.bodySmall?.color ?? theme.colorScheme.onSurface;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    return DecoratedBox(
      decoration: AppDecorations.card(
        context,
      ).copyWith(border: mismatch ? Border.all(color: f.dangerOutline) : null),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
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
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: kMinInteractiveDimension,
            ),
            child: Padding(
              padding: EdgeInsets.all(context.getRSize(14)),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          b.label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context
                              .boldStyle(16)
                              .copyWith(color: theme.colorScheme.onSurface),
                        ),
                        SizedBox(height: context.getRSize(4)),
                        Text(
                          '${fmtNumber(b.itemsSold)} items sold',
                          style: context
                              .regularStyle(13)
                              .copyWith(color: muted),
                        ),
                        if (movedSinceReview || mismatch) ...[
                          SizedBox(height: context.getRSize(8)),
                          Wrap(
                            spacing: context.getRSize(8),
                            runSpacing: context.getRSize(6),
                            children: [
                              if (movedSinceReview)
                                const ChangedSinceReviewBadge(
                                  label: 'Changed since review',
                                ),
                              if (mismatch)
                                const StatusPill(
                                  label: 'Mismatch',
                                  tone: TagPillTone.danger,
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  SizedBox(width: context.getRSize(8)),
                  AppIcon(
                    AppIcons.chevronRight,
                    color: muted,
                    size: context.getRSize(22),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
