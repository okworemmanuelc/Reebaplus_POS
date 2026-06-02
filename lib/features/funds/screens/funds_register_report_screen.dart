import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';

/// Funds Register Report (§25.2) — the daily open/close-per-account audit, with
/// mismatches flagged. Surfaces the Close Day reconciliation snapshots
/// (`fund_day_closings`) across the selected period: each account's expected
/// balance vs the actual counted/withdrawn, and the variance. Read-only.
///
/// Role visibility (§25.3) is enforced upstream — only CEO/Manager reach the
/// Business Reports hub, and the Funds Register Report is visible to both.
class FundsRegisterReportScreen extends ConsumerStatefulWidget {
  const FundsRegisterReportScreen({super.key, required this.initialPeriod});

  /// The hub's global period, used as this screen's starting filter (§25.5).
  /// The screen can override it locally (§25.6).
  final String initialPeriod;

  @override
  ConsumerState<FundsRegisterReportScreen> createState() =>
      _FundsRegisterReportScreenState();
}

class _FundsRegisterReportScreenState
    extends ConsumerState<FundsRegisterReportScreen> {
  late String _period = widget.initialPeriod;

  String _accountLabel(FundsAccountData? a, String fallbackType) {
    if (a == null) return _typeLabel(fallbackType);
    if (a.accountType == 'cash_till') return 'Cash Till';
    return a.name;
  }

  String _typeLabel(String type) {
    switch (type) {
      case 'cash_till':
        return 'Cash Till';
      case 'pos_machine':
        return 'POS machine';
      case 'bank':
        return 'Bank';
      default:
        return type;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final closings =
        ref.watch(allFundDayClosingsProvider).valueOrNull ?? const [];
    final accounts =
        ref.watch(allFundsAccountsProvider).valueOrNull ?? const [];
    final stores = ref.watch(allStoresProvider).valueOrNull ?? const [];

    final accountById = {for (final a in accounts) a.id: a};
    final storeNameById = {for (final s in stores) s.id: s.name};

    // Filter to the selected period on the close's business date (§25.5).
    final filtered = closings
        .where((c) => datePeriodFromLabel(_period).includes(
              DateTime.tryParse(c.businessDate) ?? DateTime(1970),
            ))
        .toList();

    // Headline figures (§25.6).
    final dayKeys = <String>{
      for (final c in filtered) '${c.storeId}|${c.businessDate}',
    };
    final mismatchCount = filtered.where((c) => c.varianceKobo != 0).length;
    final netVarianceKobo =
        filtered.fold<int>(0, (sum, c) => sum + c.varianceKobo);

    // Group by business date (newest first — list is already date-desc), then
    // by store, preserving order.
    final byDate = <String, Map<String, List<FundDayClosingData>>>{};
    for (final c in filtered) {
      final byStore = byDate.putIfAbsent(c.businessDate, () => {});
      byStore.putIfAbsent(c.storeId, () => []).add(c);
    }

    return SharedScaffold(
      activeRoute: 'dashboard',
      appBar: AppBar(
        title: Text(
          'Funds Register',
          style: context.h3.copyWith(fontWeight: FontWeight.bold),
        ),
        elevation: 0,
        backgroundColor: context.backgroundColor,
        leading: BackButton(color: context.primaryColor),
        actions: [
          SizedBox(
            width: 110,
            child: AppDropdown<String>(
              value: _period,
              items: kDatePeriodLabels
                  .map((p) => DropdownMenuItem(
                      value: p,
                      child:
                          Text(p, style: const TextStyle(fontSize: 12))))
                  .toList(),
              onChanged: (v) => setState(
                  () => _period = v ?? kDatePeriodLabels.first),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: filtered.isEmpty
          ? _emptyState(theme)
          : ListView(
              padding: EdgeInsets.all(context.spacingM).copyWith(
                bottom: context.spacingM + context.deviceBottomInset,
              ),
              children: [
                _headline(
                  theme,
                  daysClosed: dayKeys.length,
                  mismatches: mismatchCount,
                  netVarianceKobo: netVarianceKobo,
                ),
                SizedBox(height: context.spacingM),
                for (final dateEntry in byDate.entries)
                  for (final storeEntry in dateEntry.value.entries)
                    _dayCard(
                      theme,
                      businessDate: dateEntry.key,
                      storeName: storeNameById[storeEntry.key] ?? 'Store',
                      showStore: stores.length > 1,
                      rows: storeEntry.value,
                      accountById: accountById,
                    ),
              ],
            ),
    );
  }

  Widget _emptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(FontAwesomeIcons.vault,
              size: 40, color: theme.hintColor.withValues(alpha: 0.5)),
          SizedBox(height: context.spacingM),
          Text('No data for this period.',
              style: context.bodyMedium.copyWith(color: theme.hintColor)),
        ],
      ),
    );
  }

  Widget _headline(
    ThemeData theme, {
    required int daysClosed,
    required int mismatches,
    required int netVarianceKobo,
  }) {
    return Row(
      children: [
        _statTile(theme, 'Days closed', '$daysClosed',
            color: context.primaryColor),
        SizedBox(width: context.spacingS),
        _statTile(theme, 'Mismatches', '$mismatches',
            color: mismatches > 0 ? theme.colorScheme.error : Colors.green),
        SizedBox(width: context.spacingS),
        _statTile(
          theme,
          'Net variance',
          formatCurrency(netVarianceKobo / 100.0),
          color:
              netVarianceKobo != 0 ? theme.colorScheme.error : Colors.green,
        ),
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
                    fontWeight: FontWeight.bold, color: color, fontSize: 16)),
            const SizedBox(height: 2),
            Text(label,
                style: context.bodySmall.copyWith(color: theme.hintColor)),
          ],
        ),
      ),
    );
  }

  Widget _dayCard(
    ThemeData theme, {
    required String businessDate,
    required String storeName,
    required bool showStore,
    required List<FundDayClosingData> rows,
    required Map<String, FundsAccountData> accountById,
  }) {
    final anyMismatch = rows.any((c) => c.varianceKobo != 0);
    return Container(
      margin: EdgeInsets.only(bottom: context.spacingM),
      padding: EdgeInsets.all(context.spacingM),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(context.radiusL),
        border: Border.all(
          color: anyMismatch
              ? theme.colorScheme.error.withValues(alpha: 0.3)
              : theme.dividerColor.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(FontAwesomeIcons.calendarDay,
                  size: 13, color: context.primaryColor),
              const SizedBox(width: 8),
              Text(businessDate,
                  style: context.bodyMedium
                      .copyWith(fontWeight: FontWeight.bold)),
              const Spacer(),
              if (anyMismatch)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.error.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('Mismatch',
                      style: context.bodySmall.copyWith(
                          color: theme.colorScheme.error,
                          fontWeight: FontWeight.w700)),
                ),
            ],
          ),
          if (showStore)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(storeName,
                  style:
                      context.bodySmall.copyWith(color: theme.hintColor)),
            ),
          SizedBox(height: context.spacingS),
          for (final c in rows)
            _accountRow(theme, c, accountById[c.fundsAccountId]),
        ],
      ),
    );
  }

  Widget _accountRow(
      ThemeData theme, FundDayClosingData c, FundsAccountData? account) {
    final danger = c.varianceKobo != 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_accountLabel(account, c.accountType),
              style:
                  context.bodyMedium.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          _moneyLine(theme, 'Expected', c.expectedKobo),
          _moneyLine(theme, 'Counted', c.countedKobo),
          _moneyLine(theme, 'Variance', c.varianceKobo, danger: danger),
        ],
      ),
    );
  }

  Widget _moneyLine(ThemeData theme, String label, int kobo,
      {bool danger = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: context.bodySmall.copyWith(color: theme.hintColor)),
          Text(formatCurrency(kobo / 100.0),
              style: context.bodySmall.copyWith(
                fontWeight: danger ? FontWeight.bold : FontWeight.w500,
                color: danger ? theme.colorScheme.error : null,
              )),
        ],
      ),
    );
  }
}
