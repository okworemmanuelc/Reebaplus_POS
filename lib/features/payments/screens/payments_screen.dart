import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/features/payments/widgets/supplier_form_sheet.dart';
import 'package:reebaplus_pos/shared/widgets/notification_bell.dart';
import 'package:reebaplus_pos/features/payments/screens/supplier_transactions_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/supplier_detail_screen.dart';

/// §21 Supplier Accounts — the suppliers list with live ledger balances, an
/// "Add Supplier" FAB, and a link into the all-suppliers Transaction history.
class PaymentsScreen extends ConsumerWidget {
  const PaymentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(currencySymbolProvider);
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final subtext =
        Theme.of(context).textTheme.bodySmall?.color ??
        Theme.of(context).iconTheme.color!;

    // §21 access: Supplier Accounts is gated by `suppliers.manage`. Fail CLOSED:
    // `perms` is empty while grants load → spinner, not a flash of no-access.
    final perms = ref.watch(currentUserPermissionsProvider);
    final canManage = perms.contains('suppliers.manage');

    return Scaffold(
      backgroundColor: bg,
      drawer: const AppDrawer(activeRoute: 'supplier_accounts'),
      appBar: _buildAppBar(context, ref),
      body: !canManage
          ? Center(
              child: perms.isEmpty
                  ? const CircularProgressIndicator()
                  : Text(
                      'You don’t have access to Supplier Accounts.',
                      style: TextStyle(
                        color: subtext,
                        fontSize: context.getRFontSize(14),
                      ),
                    ),
            )
          : _buildSuppliersBody(context, ref),
      floatingActionButton: canManage
          ? AppFAB(
              heroTag: 'suppliers_fab',
              onPressed: () => SupplierFormSheet.show(context),
              icon: FontAwesomeIcons.plus.data,
              label: 'Add Supplier',
            )
          : null,
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, WidgetRef ref) {
    final surface = Theme.of(context).colorScheme.surface;
    final text = Theme.of(context).colorScheme.onSurface;
    return AppBar(
      backgroundColor: surface,
      elevation: 0,
      iconTheme: IconThemeData(color: text),
      leading: Builder(
        builder: (ctx) => InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => Scaffold.of(ctx).openDrawer(),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 2.5,
                  width: context.getRSize(22),
                  decoration: BoxDecoration(
                    color: text,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Container(
                  height: 2.5,
                  width: context.getRSize(16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Container(
                  height: 2.5,
                  width: context.getRSize(22),
                  decoration: BoxDecoration(
                    color: text,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        const NotificationBell(),
        SizedBox(width: context.getRSize(8)),
      ],
      title: Row(
        children: [
          Container(
            padding: EdgeInsets.all(context.getRSize(8)),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.7),
                  Theme.of(context).colorScheme.primary,
                ],
              ),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(
              FontAwesomeIcons.moneyBillWave.data,
              color: Colors.white,
              size: context.getRSize(16),
            ),
          ),
          SizedBox(width: context.getRSize(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    'Supplier Accounts',
                    style: TextStyle(
                      fontSize: context.getRFontSize(18),
                      fontWeight: FontWeight.w800,
                      color: text,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
                Text(
                  ref.watch(activeStoreLabelProvider),
                  style: TextStyle(
                    fontSize: context.getRFontSize(11),
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuppliersBody(BuildContext context, WidgetRef ref) {
    final subtext =
        Theme.of(context).textTheme.bodySmall?.color ??
        Theme.of(context).iconTheme.color!;
    final suppliers =
        ref.watch(allSuppliersProvider).valueOrNull ?? const <SupplierData>[];
    final balances =
        ref.watch(supplierBalancesKoboProvider).valueOrNull ??
        const <String, int>{};
    // §21.11 — balances shown are scoped to the active store.
    final scopeLabel = ref.watch(activeStoreLabelProvider);

    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            context.getRSize(16),
            context.getRSize(12),
            context.getRSize(16),
            context.getRSize(4),
          ),
          child: _TransactionHistoryLink(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const SupplierTransactionsScreen(),
              ),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            context.getRSize(20),
            context.getRSize(8),
            context.getRSize(20),
            context.getRSize(2),
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Balances for: $scopeLabel',
              style: TextStyle(
                color: subtext,
                fontSize: context.getRFontSize(12),
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        Expanded(
          child: AppRefreshWrapper(
            child: suppliers.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      SizedBox(height: context.getRSize(120)),
                      Center(
                        child: Text(
                          'No suppliers added yet',
                          style: TextStyle(color: subtext),
                        ),
                      ),
                    ],
                  )
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(
                    context.getRSize(16),
                    context.getRSize(8),
                    context.getRSize(16),
                    context.getRSize(120) + context.deviceBottomPadding,
                  ),
                  itemCount: suppliers.length,
                  itemBuilder: (_, i) {
                    final s = suppliers[i];
                    final bal = balances[s.id] ?? 0;
                    return _SupplierRow(
                      supplier: s,
                      balanceKobo: bal,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              SupplierDetailScreen(supplierId: s.id),
                        ),
                      ),
                    );
                  },
                ),
          ),
        ),
      ],
    );
  }
}

class _TransactionHistoryLink extends StatelessWidget {
  final VoidCallback onTap;

  const _TransactionHistoryLink({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).colorScheme.onSurface;
    final subtext =
        Theme.of(context).textTheme.bodySmall?.color ??
        Theme.of(context).iconTheme.color!;
    final primary = Theme.of(context).colorScheme.primary;
    final border = Theme.of(context).dividerColor;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(context.getRSize(14)),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: border),
        ),
        child: Row(
          children: [
            Container(
              width: context.getRSize(40),
              height: context.getRSize(40),
              decoration: BoxDecoration(
                color: primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                FontAwesomeIcons.receipt.data,
                color: primary,
                size: context.getRSize(16),
              ),
            ),
            SizedBox(width: context.getRSize(14)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Transaction history',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: context.getRFontSize(15),
                      color: text,
                    ),
                  ),
                  SizedBox(height: context.getRSize(2)),
                  Text(
                    'All invoices & payments across suppliers',
                    style: TextStyle(
                      color: subtext,
                      fontSize: context.getRFontSize(12),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: subtext,
              size: context.getRSize(20),
            ),
          ],
        ),
      ),
    );
  }
}

class _SupplierRow extends StatelessWidget {
  final SupplierData supplier;
  final int balanceKobo;
  final VoidCallback onTap;

  const _SupplierRow({
    required this.supplier,
    required this.balanceKobo,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).colorScheme.onSurface;
    final subtext =
        Theme.of(context).textTheme.bodySmall?.color ??
        Theme.of(context).iconTheme.color!;
    final border = Theme.of(context).dividerColor;

    final contact = [
      if ((supplier.phone ?? '').isNotEmpty) supplier.phone!,
      if ((supplier.address ?? '').isNotEmpty) supplier.address!,
    ].join(' • ');

    final owed = balanceKobo < 0;
    final balColor = owed ? danger : (balanceKobo > 0 ? success : subtext);
    final balLabel = owed
        ? 'Owed ${formatCurrency(balanceKobo.abs() / 100)}'
        : (balanceKobo > 0
              ? 'Credit ${formatCurrency(balanceKobo / 100)}'
              : 'Settled');

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(bottom: context.getRSize(12)),
        padding: EdgeInsets.all(context.getRSize(16)),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: border),
        ),
        child: Row(
          children: [
            Container(
              width: context.getRSize(48),
              height: context.getRSize(48),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                FontAwesomeIcons.buildingColumns.data,
                color: Theme.of(context).colorScheme.primary,
                size: context.getRSize(20),
              ),
            ),
            SizedBox(width: context.getRSize(16)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    supplier.name,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: context.getRFontSize(16),
                      color: text,
                    ),
                  ),
                  if (contact.isNotEmpty) ...[
                    SizedBox(height: context.getRSize(4)),
                    Text(
                      contact,
                      style: TextStyle(
                        color: subtext,
                        fontSize: context.getRFontSize(13),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  SizedBox(height: context.getRSize(4)),
                  Text(
                    balLabel,
                    style: TextStyle(
                      color: balColor,
                      fontSize: context.getRFontSize(13),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: subtext,
              size: context.getRSize(20),
            ),
          ],
        ),
      ),
    );
  }
}
