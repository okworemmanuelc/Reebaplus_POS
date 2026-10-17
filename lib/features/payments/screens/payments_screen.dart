import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
import 'package:reebaplus_pos/features/payments/widgets/payments_parts.dart';
import 'package:reebaplus_pos/features/payments/widgets/supplier_form_sheet.dart';
import 'package:reebaplus_pos/features/payments/screens/supplier_transactions_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/supplier_detail_screen.dart';

/// §21 Supplier Accounts — the suppliers list with live ledger balances, an
/// "Add Supplier" FAB, and a link into the all-suppliers Transaction history.
/// Restyled in #411 (PRD #346 Wave 2 B): solid top bar with the shared
/// `ScreenHeader`, flat cards, content capped at 720 and centred.
class PaymentsScreen extends ConsumerWidget {
  const PaymentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(currencySymbolProvider);
    final subtext =
        Theme.of(context).textTheme.bodySmall?.color ??
        Theme.of(context).iconTheme.color!;

    // §21 access: Supplier Accounts is gated by `suppliers.manage`. Fail CLOSED:
    // `perms` is empty while grants load → spinner, not a flash of no-access.
    final perms = ref.watch(currentUserPermissionsProvider);
    final canManage = perms.contains('suppliers.manage');

    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        // One line: test/tour/drawer_presence_ban_test.dart reads it line by line.
        drawer: context.isRailLayout ? null : const AppDrawer(activeRoute: 'supplier_accounts'),
        appBar: PaymentsTopBar(
          key: PaymentsKeys.topBar,
          height: paymentsTopBarHeight(context),
          header: ScreenHeader(
            icon: AppIcons.payments,
            title: 'Supplier Accounts',
            subtitle: ref.watch(activeStoreLabelProvider),
            leading: context.isRailLayout
                ? null
                : const SizedBox.square(
                    dimension: kMinInteractiveDimension,
                    child: MenuButton(),
                  ),
            actions: const [PaymentsLiveBell()],
          ),
        ),
        body: DrawerHost(
          // Side insets (a cutout, a sideways nav bar) are cleared here; under
          // MainLayout they are already removed, so this is a no-op there.
          child: SafeArea(
            top: false,
            bottom: false,
            child: !canManage
                ? Center(
                    child: perms.isEmpty
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
                : _buildSuppliersBody(context, ref),
          ),
        ),
        floatingActionButton: canManage
            ? AppFAB(
                heroTag: 'suppliers_fab',
                onPressed: () => SupplierFormSheet.show(context),
                icon: AppIcons.add,
                label: 'Add Supplier',
              )
            : null,
      ),
    );
  }

  Widget _buildSuppliersBody(BuildContext context, WidgetRef ref) {
    final suppliers =
        ref.watch(allSuppliersProvider).valueOrNull ?? const <SupplierData>[];
    final balances =
        ref.watch(supplierBalancesKoboProvider).valueOrNull ??
        const <String, int>{};
    // §21.11 — balances shown are scoped to the active store.
    final scopeLabel = ref.watch(activeStoreLabelProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        final gutter = paymentsGutter(context, constraints.maxWidth);
        final header = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsRow(
              key: PaymentsKeys.historyLink,
              icon: AppIcons.receipt,
              tone: IconTileTone.info,
              title: 'Transaction history',
              subtitle: 'All invoices & payments across suppliers',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const SupplierTransactionsScreen(),
                ),
              ),
            ),
            SizedBox(height: context.getRSize(16)),
            SectionHeader(
              title: 'Suppliers',
              subtitle: 'Balances for: $scopeLabel',
            ),
            SizedBox(height: context.getRSize(10)),
          ],
        );
        final bottom = context.getRSize(100) + context.deviceBottomPadding;
        return AppRefreshWrapper(
          child: suppliers.isEmpty
              ? ListView(
                  key: PaymentsKeys.list,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(
                    gutter,
                    context.getRSize(16),
                    gutter,
                    bottom,
                  ),
                  children: [
                    header,
                    SizedBox(height: context.getRSize(48)),
                    const Center(
                      child: PaymentsEmptyMessage(
                        key: PaymentsKeys.empty,
                        message: 'No suppliers added yet',
                      ),
                    ),
                  ],
                )
              : ListView.builder(
                  key: PaymentsKeys.list,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(
                    gutter,
                    context.getRSize(16),
                    gutter,
                    bottom,
                  ),
                  itemCount: suppliers.length + 1,
                  itemBuilder: (_, i) {
                    if (i == 0) return header;
                    final s = suppliers[i - 1];
                    final bal = balances[s.id] ?? 0;
                    return Padding(
                      padding: EdgeInsets.only(bottom: context.getRSize(12)),
                      child: _supplierRow(context, s, bal),
                    );
                  },
                ),
        );
      },
    );
  }

  Widget _supplierRow(BuildContext context, SupplierData supplier, int bal) {
    final contact = [
      if ((supplier.phone ?? '').isNotEmpty) supplier.phone!,
      if ((supplier.address ?? '').isNotEmpty) supplier.address!,
    ].join(' • ');
    final owed = bal < 0;
    final balLabel = owed
        ? 'Owed ${formatCurrency(bal.abs() / 100)}'
        : (bal > 0 ? 'Credit ${formatCurrency(bal / 100)}' : 'Settled');
    return PaymentsSupplierRow(
      key: PaymentsKeys.supplierRow(supplier.id),
      name: supplier.name,
      contact: contact,
      balanceLabel: balLabel,
      tone: owed
          ? PaymentsBalanceTone.owed
          : (bal > 0
                ? PaymentsBalanceTone.credit
                : PaymentsBalanceTone.settled),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SupplierDetailScreen(supplierId: supplier.id),
        ),
      ),
    );
  }
}
