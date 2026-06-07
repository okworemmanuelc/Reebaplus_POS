import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/payments/widgets/supplier_ledger_entry_tile.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';

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

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider);
    // §21 access — gated by suppliers.manage. Fail closed while grants load.
    final perms = ref.watch(currentUserPermissionsProvider);
    final canManage = perms.contains('suppliers.manage');

    final entries =
        ref.watch(supplierAllHistoryProvider).valueOrNull ??
            const <SupplierLedgerEntryData>[];
    final suppliers =
        ref.watch(allSuppliersProvider).valueOrNull ?? const <SupplierData>[];
    final nameById = {for (final s in suppliers) s.id: s.name};

    // §21.11 — when viewing "All Stores" (no store locked), show which store
    // recorded each entry. With a concrete store locked, every row is that store.
    final isAllStores = ref.watch(lockedStoreProvider).value == null;
    final scopeLabel = ref.watch(activeStoreLabelProvider);
    final stores =
        ref.watch(allStoresProvider).valueOrNull ?? const <StoreData>[];
    final storeNameById = {for (final s in stores) s.id: s.name};

    final window = datePeriodFromLabel(_effectivePeriod);
    final filtered =
        entries.where((e) => window.includes(e.activityDate)).toList();

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _surface,
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
      body: !canManage
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
                          '${filtered.length} transaction'
                          '${filtered.length == 1 ? '' : 's'} • $scopeLabel',
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
                              value: val, child: Text(val));
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
                Expanded(
                  child: filtered.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                FontAwesomeIcons.receipt,
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
                            context.getRSize(24) + context.deviceBottomPadding,
                          ),
                          itemCount: filtered.length,
                          itemBuilder: (_, i) {
                            final e = filtered[i];
                            return SupplierLedgerEntryTile(
                              entry: e,
                              supplierName:
                                  nameById[e.supplierId] ?? 'Unknown supplier',
                              storeName: isAllStores
                                  ? (storeNameById[e.storeId] ??
                                      (e.storeId == null ? 'Unassigned' : null))
                                  : null,
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
