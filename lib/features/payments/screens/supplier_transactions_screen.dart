import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/payments/widgets/payments_parts.dart';
import 'package:reebaplus_pos/features/payments/widgets/supplier_ledger_entry_tile.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// §21.10 — every ledger entry across all suppliers (invoices, payments, voids),
/// newest first, filtered by a period dropdown. Read-only history view.
class SupplierTransactionsScreen extends ConsumerStatefulWidget {
  const SupplierTransactionsScreen({super.key});

  @override
  ConsumerState<SupplierTransactionsScreen> createState() =>
      _SupplierTransactionsScreenState();
}

class _SupplierTransactionsScreenState
    extends ConsumerState<SupplierTransactionsScreen> {
  String _periodFilter = 'This Month'; // §30.6/§30.11 default
  DateTimeRange? _customRange;

  List<String> get _periodOptions => datePeriodLabelsForRole(
    managerUp: Gates.seeExtendedDateRanges.allows(ref),
  );

  String get _effectivePeriod {
    final isCustom = _periodFilter.startsWith('Custom:');
    final dropdownValue = isCustom ? 'Custom' : _periodFilter;
    if (_periodOptions.contains(dropdownValue)) {
      return _periodFilter;
    }
    return _periodOptions.first;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider);
    // §21 access — gated by suppliers.manage. Fail closed while grants load.
    final canManage = Gates.manageSuppliers.allows(ref);
    final isReady = ref.watch(gateContextProvider).isReady;

    final lockedStoreId = ref.watch(lockedStoreProvider).value;
    final providerKey = (storeId: lockedStoreId, period: _effectivePeriod);

    final pageState = ref.watch(paginatedSupplierHistoryProvider(providerKey));
    final statsAsync = ref.watch(supplierHistoryStatsProvider(providerKey));
    final stats = statsAsync.valueOrNull ?? SupplierLedgerStats.empty();

    final suppliers =
        ref.watch(allSuppliersProvider).valueOrNull ?? const <SupplierData>[];
    final nameById = {for (final s in suppliers) s.id: s.name};

    // §21.11 — when viewing "All Stores" (no store locked), show which store
    // recorded each entry. With a concrete store locked, every row is that store.
    final isAllStores = lockedStoreId == null;
    final scopeLabel = ref.watch(activeStoreLabelProvider);
    final stores =
        ref.watch(allStoresProvider).valueOrNull ?? const <StoreData>[];
    final storeNameById = {for (final s in stores) s.id: s.name};

    final entries = pageState.entries;
    final isLoading = pageState.isLoading;
    final isLoadingMore = pageState.isLoadingMore;
    final hasMore = pageState.hasMore;

    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;

    void loadMore() => Future.microtask(
      () => ref
          .read(paginatedSupplierHistoryProvider(providerKey).notifier)
          .loadMore(),
    );

    Widget controls(double gutter) => Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        context.getRSize(12),
        gutter,
        context.getRSize(4),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              '${stats.count} transaction'
              '${stats.count == 1 ? '' : 's'} • $scopeLabel',
              style: context.semiBoldStyle(13).copyWith(color: subtext),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(width: context.getRSize(8)),
          AppDropdown<String>(
            value: _effectivePeriod.startsWith('Custom:')
                ? 'Custom'
                : _effectivePeriod,
            width: context.getRSize(140),
            items: _periodOptions.map((val) {
              return DropdownMenuItem<String>(
                value: val,
                child: Text(
                  val,
                  style: context
                      .mediumStyle(14)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
              );
            }).toList(),
            onChanged: (val) async {
              if (val == 'Custom') {
                final range = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(2020),
                  lastDate: DateTime.now().add(const Duration(days: 365)),
                  initialDateRange: _customRange,
                  builder: (context, child) =>
                      Theme(data: Theme.of(context), child: child!),
                );
                if (range != null) {
                  setState(() {
                    _customRange = range;
                    _periodFilter =
                        'Custom:${range.start.toIso8601String()}:${range.end.toIso8601String()}';
                  });
                }
              } else if (val != null) {
                setState(() {
                  _periodFilter = val;
                  _customRange = null;
                });
              }
            },
          ),
        ],
      ),
    );

    Widget totals(double gutter) => Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        context.getRSize(8),
        gutter,
        context.getRSize(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: PaymentsFigureCard(
              key: PaymentsKeys.totalIn,
              label: 'Total In',
              value: formatCurrency(stats.totalIn / 100.0),
              color: f.green,
            ),
          ),
          SizedBox(width: context.getRSize(10)),
          Expanded(
            child: PaymentsFigureCard(
              key: PaymentsKeys.totalOut,
              label: 'Total Out',
              value: formatCurrency(stats.totalOut / 100.0),
              color: f.danger,
            ),
          ),
        ],
      ),
    );

    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: PaymentsTopBar(
          key: PaymentsKeys.transactionsTopBar,
          height: paymentsTopBarHeight(context),
          header: ScreenHeader(
            icon: AppIcons.receipt,
            title: 'Transaction History',
            subtitle: scopeLabel,
            leading: PaymentsBackButton(
              onPressed: () => Navigator.pop(context),
            ),
          ),
        ),
        body: SafeArea(
          top: false,
          bottom: false,
          child: !canManage
              ? Center(
                  child: !isReady
                      ? const CircularProgressIndicator()
                      : Padding(
                          padding: EdgeInsets.all(context.getRSize(16)),
                          child: Text(
                            'You don’t have access to Supplier Accounts.',
                            textAlign: TextAlign.center,
                            style: context
                                .regularStyle(14)
                                .copyWith(color: subtext),
                          ),
                        ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final gutter = paymentsGutter(
                      context,
                      constraints.maxWidth,
                    );
                    return Column(
                      children: [
                        controls(gutter),
                        totals(gutter),
                        Expanded(
                          child: isLoading
                              ? const Center(child: CircularProgressIndicator())
                              : entries.isEmpty
                              ? const Center(
                                  child: PaymentsEmptyMessage(
                                    key: PaymentsKeys.transactionsEmpty,
                                    icon: AppIcons.receipt,
                                    message: 'No transactions in this period',
                                  ),
                                )
                              : ListView.builder(
                                  key: PaymentsKeys.transactionsList,
                                  padding: EdgeInsets.fromLTRB(
                                    gutter,
                                    context.getRSize(8),
                                    gutter,
                                    context.getRSize(24) +
                                        context.deviceBottomPadding,
                                  ),
                                  itemCount: entries.length + (hasMore ? 1 : 0),
                                  itemBuilder: (_, i) {
                                    if (i >= entries.length) {
                                      if (!isLoadingMore) loadMore();
                                      return Padding(
                                        padding: EdgeInsets.symmetric(
                                          vertical: context.getRSize(16),
                                        ),
                                        child: const Center(
                                          child: CircularProgressIndicator(),
                                        ),
                                      );
                                    }
                                    if (i >= entries.length - 5 &&
                                        hasMore &&
                                        !isLoadingMore) {
                                      loadMore();
                                    }
                                    final e = entries[i];
                                    return SupplierLedgerEntryTile(
                                      key: PaymentsKeys.ledgerRow(e.id),
                                      entry: e,
                                      supplierName:
                                          nameById[e.supplierId] ??
                                          'Unknown supplier',
                                      storeName: isAllStores
                                          ? (storeNameById[e.storeId] ??
                                                (e.storeId == null
                                                    ? 'Unassigned'
                                                    : null))
                                          : null,
                                    );
                                  },
                                ),
                        ),
                      ],
                    );
                  },
                ),
        ),
      ),
    );
  }
}
