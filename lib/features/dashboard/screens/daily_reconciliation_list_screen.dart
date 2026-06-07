import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/business_time.dart';
import 'package:reebaplus_pos/core/utils/csv_export.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/dashboard/screens/daily_reconciliation_detail_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/slide_route.dart';

/// Daily Reconciliation Report (§25.2 / §25.9) — the drill-down list. The global
/// rolling window (§30.11) selects the span; this lists one tappable card per
/// **calendar day** inside it that has a saved stock count. Each card headlines
/// items sold and flags a mismatch when the day had a stock shortage. Tapping
/// opens that day's full reconciliation. Role-gated upstream (CEO/Manager only,
/// §25.3). (The Close Day cash-audit half was removed with Funds Register, §23.)
class DailyReconciliationListScreen extends ConsumerStatefulWidget {
  const DailyReconciliationListScreen({super.key, required this.initialPeriod});

  final String initialPeriod;

  @override
  ConsumerState<DailyReconciliationListScreen> createState() =>
      _DailyReconciliationListScreenState();
}

class _DailyReconciliationListScreenState
    extends ConsumerState<DailyReconciliationListScreen> {
  late String _period = widget.initialPeriod;

  String _prettyDate(String date) {
    final d = DateTime.tryParse(date);
    return d == null ? date : DateFormat('EEE, d MMM yyyy').format(d);
  }

  List<_Day> _buildDays(String? tz) {
    final stockCounts = ref.watch(allStockCountsProvider).valueOrNull ?? const [];
    final orders = ref.watch(allOrdersProvider).valueOrNull ?? const [];

    final byDay = <String, _Day>{};
    _Day dayOf(String date) =>
        byDay.putIfAbsent(date, () => _Day(date: date));

    // Collapse re-saved counts to the latest session per (date, store) so a
    // shortage corrected in a later count of the same day stops flagging.
    final sortedCounts = [...stockCounts]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final seenCount = <String>{};
    for (final c in sortedCounts) {
      if (!seenCount.add('${c.businessDate}|${c.storeId}')) continue;
      final d = dayOf(c.businessDate);
      if (c.shortageUnits > 0) d.stockShortage = true;
    }
    // Items sold per reconciled day (bucketed by the business timezone). Only
    // attribute to days that already have a card (a close and/or count).
    if (tz != null) {
      for (final o in orders) {
        if (o.order.status != 'completed') continue;
        final d = byDay[businessDateString(o.order.createdAt, tz)];
        if (d == null) continue;
        for (final i in o.items) {
          d.itemsSold += i.item.quantity;
        }
      }
    }

    final period = datePeriodFromLabel(_period);
    final days = byDay.values.where((d) {
      final start = DateTime.tryParse(d.date);
      if (start == null) return false;
      // A day overlaps the rolling window iff it ends within it.
      return period.includes(start.add(const Duration(days: 1)));
    }).toList()
      ..sort((a, b) => b.date.compareTo(a.date)); // YYYY-MM-DD sorts chronologically
    return days;
  }

  Future<void> _exportCsv(List<_Day> days) async {
    final rows = <List<String>>[
      for (final d in days)
        [
          d.date,
          '${d.itemsSold}',
          d.hasMismatch ? 'Yes' : 'No',
        ],
    ];
    try {
      await shareCsv(
        csv: buildCsv(
          ['Date', 'Items sold', 'Mismatch'],
          rows,
        ),
        fileName: 'daily_reconciliation_${_period.replaceAll(' ', '_')}',
        subject: 'Daily Reconciliation — $_period',
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
    final tz = ref.watch(businessTimezoneProvider).valueOrNull;
    final days = _buildDays(tz);

    return SharedScaffold(
      activeRoute: 'dashboard',
      appBar: AppBar(
        title: Text('Daily Reconciliation',
            style: context.h3.copyWith(fontWeight: FontWeight.bold)),
        elevation: 0,
        backgroundColor: context.backgroundColor,
        leading: BackButton(color: context.primaryColor),
        actions: [
          IconButton(
            tooltip: 'Export CSV',
            icon: Icon(FontAwesomeIcons.fileCsv,
                size: 18, color: context.primaryColor),
            onPressed: days.isEmpty ? null : () => _exportCsv(days),
          ),
          SizedBox(
            width: 110,
            child: AppDropdown<String>(
              value: _period,
              items: kDatePeriodLabels
                  .map((p) => DropdownMenuItem(
                      value: p,
                      child: Text(p, style: const TextStyle(fontSize: 12))))
                  .toList(),
              onChanged: (v) =>
                  setState(() => _period = v ?? kDatePeriodLabels.first),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: days.isEmpty
          ? _emptyState(theme)
          : ListView.separated(
              padding: EdgeInsets.all(context.spacingM).copyWith(
                bottom: context.spacingM + context.deviceBottomPadding,
              ),
              itemCount: days.length,
              separatorBuilder: (_, __) => SizedBox(height: context.spacingS),
              itemBuilder: (_, i) => _dayCard(theme, days[i]),
            ),
    );
  }

  Widget _emptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(FontAwesomeIcons.clipboardCheck,
              size: 40, color: theme.hintColor.withValues(alpha: 0.5)),
          SizedBox(height: context.spacingM),
          Text('No data for this period.',
              style: context.bodyMedium.copyWith(color: theme.hintColor)),
        ],
      ),
    );
  }

  Widget _dayCard(ThemeData theme, _Day d) {
    final mismatch = d.hasMismatch;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(context.radiusL),
        onTap: () => Navigator.push(
          context,
          slideDownRoute(
            DailyReconciliationDetailScreen(businessDate: d.date),
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
                    Text(_prettyDate(d.date),
                        style: context.bodyMedium
                            .copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(
                      '${fmtNumber(d.itemsSold)} items sold',
                      style:
                          context.bodySmall.copyWith(color: theme.hintColor),
                    ),
                  ],
                ),
              ),
              if (mismatch)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.error.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('Mismatch',
                      style: context.bodySmall.copyWith(
                          color: theme.colorScheme.error,
                          fontWeight: FontWeight.w700)),
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

class _Day {
  _Day({required this.date});
  final String date;
  int itemsSold = 0;
  bool stockShortage = false;

  bool get hasMismatch => stockShortage;
}
