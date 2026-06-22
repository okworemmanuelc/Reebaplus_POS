import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/payments/widgets/supplier_ledger_entry_tile.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_card.dart';

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
  bool _isScrolled = false;

  List<String> get _periodOptions =>
      datePeriodLabelsForRole(managerUp: isManagerOrAbove(ref));

  String get _effectivePeriod => _periodOptions.contains(_periodFilter)
      ? _periodFilter
      : _periodOptions.last;

  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _border => Theme.of(context).dividerColor;

  Widget _buildSummaryTile(
    BuildContext context,
    ThemeData theme,
    String label,
    double amount,
    Color color,
  ) {
    final isDark = theme.brightness == Brightness.dark;
    return GlassyCard(
      radius: 12,
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(14),
        vertical: context.getRSize(10),
      ),
      backgroundColor: isDark
          ? theme.colorScheme.surface.withValues(alpha: 0.25)
          : theme.colorScheme.surface.withValues(alpha: 0.5),
      border: Border.all(
        color: theme.colorScheme.primary.withValues(alpha: isDark ? 0.1 : 0.05),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: context.getRFontSize(11),
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface.withAlpha(128),
            ),
          ),
          SizedBox(height: context.getRSize(4)),
          Text(
            formatCurrency(amount),
            style: TextStyle(
              fontSize: context.getRFontSize(15),
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLedgerSummaryRow(
    ThemeData theme,
    SupplierLedgerStats stats,
  ) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(8),
        context.getRSize(16),
        context.getRSize(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildSummaryTile(
              context,
              theme,
              'Total In',
              stats.totalIn / 100.0,
              success,
            ),
          ),
          SizedBox(width: context.getRSize(10)),
          Expanded(
            child: _buildSummaryTile(
              context,
              theme,
              'Total Out',
              stats.totalOut / 100.0,
              danger,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider);
    // §21 access — gated by suppliers.manage. Fail closed while grants load.
    final perms = ref.watch(currentUserPermissionsProvider);
    final canManage = perms.contains('suppliers.manage');

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

    return ColoredBox(
      color: _bg,
      child: Container(
        decoration: AppDecorations.glassyBackground(context),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: _isScrolled
                ? _surface.withValues(alpha: 0.8)
                : Colors.transparent,
            elevation: 0,
            leading: IconButton(
              icon: Icon(Icons.arrow_back_ios_new, color: _text, size: 20),
              onPressed: () => Navigator.pop(context),
            ),
            title: Text(
              'Transaction History',
              style: TextStyle(
                color: _text,
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
            child: !canManage
                ? Center(
                    child: perms.isEmpty
                        ? const CircularProgressIndicator()
                        : Text(
                            'You don’t have access to Supplier Accounts.',
                            style: TextStyle(color: _subtext),
                          ),
                  )
                : Column(
                    children: [
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          context.getRSize(16),
                          context.getRSize(12),
                          context.getRSize(16),
                          context.getRSize(4),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                '${stats.count} transaction'
                                '${stats.count == 1 ? '' : 's'} • $scopeLabel',
                                style: TextStyle(
                                  color: _subtext,
                                  fontSize: context.getRFontSize(13),
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            SizedBox(width: context.getRSize(8)),
                            AppDropdown<String>(
                              value: _effectivePeriod,
                              width: context.getRSize(140),
                              items: _periodOptions.map((val) {
                                return DropdownMenuItem<String>(
                                  value: val,
                                  child: Text(val),
                                );
                              }).toList(),
                              onChanged: (val) {
                                if (val != null) {
                                  setState(() => _periodFilter = val);
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                      _buildLedgerSummaryRow(Theme.of(context), stats),
                      Expanded(
                        child: isLoading
                            ? const Center(child: CircularProgressIndicator())
                            : entries.isEmpty
                                ? Center(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          FontAwesomeIcons.receipt.data,
                                          size: context.getRSize(48),
                                          color: _border,
                                        ),
                                        SizedBox(height: context.getRSize(16)),
                                        Text(
                                          'No transactions in this period',
                                          style: TextStyle(
                                            color: _subtext,
                                            fontSize: context.getRFontSize(15),
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                : ListView.builder(
                                    padding: EdgeInsets.fromLTRB(
                                      context.getRSize(16),
                                      context.getRSize(8),
                                      context.getRSize(16),
                                      context.getRSize(24) +
                                          context.deviceBottomPadding,
                                    ),
                                    itemCount: entries.length + (hasMore ? 1 : 0),
                                    itemBuilder: (_, i) {
                                      if (i >= entries.length) {
                                        if (!isLoadingMore) {
                                          Future.microtask(
                                            () => ref
                                                .read(
                                                  paginatedSupplierHistoryProvider(
                                                    providerKey,
                                                  ).notifier,
                                                )
                                                .loadMore(),
                                          );
                                        }
                                        return Padding(
                                          padding: EdgeInsets.symmetric(
                                            vertical: context.getRSize(16),
                                          ),
                                          child: const Center(
                                            child: CircularProgressIndicator(),
                                          ),
                                        );
                                      }
                                      if (i >= entries.length - 5 && hasMore && !isLoadingMore) {
                                        Future.microtask(
                                          () => ref
                                              .read(
                                                paginatedSupplierHistoryProvider(
                                                  providerKey,
                                                ).notifier,
                                              )
                                              .loadMore(),
                                        );
                                      }
                                      final e = entries[i];
                                      return SupplierLedgerEntryTile(
                                        entry: e,
                                        supplierName: nameById[e.supplierId] ??
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
                  ),
          ),
        ),
      ),
    );
  }
}
