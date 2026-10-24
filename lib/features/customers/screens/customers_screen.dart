import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';

import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/settings_screen.dart'
    show kSettingsMaxContentWidth;
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer.dart';
import 'package:reebaplus_pos/shared/widgets/first_run_empty_state.dart';
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/customers/widgets/add_customer_sheet.dart';
import 'package:reebaplus_pos/features/customers/widgets/customer_parts.dart';
import 'package:reebaplus_pos/features/customers/screens/customer_detail_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/slide_route.dart';

/// The Customers list (§18; restyled in #395, PRD #346 Wave 2 A): a solid top
/// bar with the shared `ScreenHeader`, then one flat card per registered
/// customer, capped at [kSettingsMaxContentWidth] and centred on wide screens.
class CustomersScreen extends ConsumerStatefulWidget {
  const CustomersScreen({super.key});

  @override
  ConsumerState<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends ConsumerState<CustomersScreen> {
  bool _isFirstLoad = true;

  @override
  void initState() {
    super.initState();
    // §12.1: the store filter follows the nav-drawer store picker (read live in
    // build via lockedStoreProvider). The customers stream loads via its
    // provider; flip the first-load gate once mounted so the list can render.
    Future.microtask(() {
      if (mounted) setState(() => _isFirstLoad = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(
      currencySymbolProvider,
    ); // rebuild money displays when currency changes
    // §12.1: the store filter comes from the nav-drawer store picker
    // (null = "All Stores"); no per-screen store dropdown.
    final storeFilter = ref.watch(lockedStoreProvider).value;

    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: CustomerTopBar(
          key: CustomersKeys.topBar,
          height: customerTopBarHeight(context),
          header: ScreenHeader(
            icon: AppIcons.customers,
            title: 'Customers',
            subtitle: ref.watch(activeStoreLabelProvider),
            leading: context.isRailLayout
                ? null
                : const SizedBox.square(
                    dimension: kMinInteractiveDimension,
                    child: MenuButton(),
                  ),
            actions: const [CustomerLiveBell()],
          ),
        ),
        // One line: test/tour/drawer_presence_ban_test.dart reads it line by line.
        drawer: context.isRailLayout ? null : const AppDrawer(activeRoute: 'customers'),
        body: DrawerHost(
          // Side insets (a cutout, a sideways nav bar) are cleared here; under
          // MainLayout they are already removed, so this is a no-op there.
          child: SafeArea(
            top: false,
            bottom: false,
            child: Builder(
              builder: (context) {
                if (ref.watch(zeroStoresEmptySurfaceProvider)) {
                  return const FirstRunEmptyState();
                }
                final customers = ref.watch(customerServiceProvider).value;
                final balances =
                    ref.watch(creditBalancesKoboProvider).valueOrNull ??
                    const <String, int>{};
                if (_isFirstLoad) {
                  return const Center(child: CircularProgressIndicator());
                }

                // The walk-in is never a registered customer. It is synthetic
                // (never stored), so this only guards the rule (#395).
                final registered = customers.where((c) => !c.isWalkIn);
                List<Customer> filtered;

                if (storeFilter == null) {
                  // "All Stores" selected
                  filtered = registered.toList();
                } else {
                  // A specific store selected
                  filtered = registered
                      .where((c) => c.storeId == storeFilter)
                      .toList();
                }

                if (filtered.isEmpty) {
                  return const AppRefreshWrapper(
                    child: CustomScrollView(
                      slivers: [
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: CustomersEmptyMessage(
                              message: 'No customers found.',
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }
                return LayoutBuilder(
                  builder: (context, constraints) {
                    // Settings-style list (#369): capped at 720dp and centred
                    // on wide screens; the top bar still spans the width.
                    final gutter = math.max(
                      context.getRSize(16),
                      (constraints.maxWidth - kSettingsMaxContentWidth) / 2,
                    );
                    return AppRefreshWrapper(
                      child: ListView.separated(
                        key: CustomersKeys.list,
                        padding: EdgeInsets.fromLTRB(
                          gutter,
                          context.getRSize(16),
                          gutter,
                          // Clears the Add Customer button.
                          context.getRSize(100) + context.deviceBottomPadding,
                        ),
                        itemCount: filtered.length,
                        separatorBuilder: (context, index) =>
                            SizedBox(height: context.getRSize(12)),
                        itemBuilder: (context, index) {
                          final c = filtered[index];
                          final balanceKobo = balances[c.id] ?? 0;
                          final hasWholesale = !businessSellsOnePrice(
                            ref.watch(currentBusinessProvider),
                          );
                          return CustomerListRow(
                            key: CustomersKeys.row(c.id),
                            name: c.name,
                            address: c.addressText,
                            tierLabel: c.priceTier.name.toUpperCase(),
                            balanceLabel: formatCurrency(balanceKobo / 100.0),
                            owes: balanceKobo < 0,
                            showTier: hasWholesale,
                            onTap: () {
                              Navigator.push(
                                context,
                                slideDownRoute(
                                  CustomerDetailScreen(customer: c),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
        floatingActionButton:
            (ref.watch(allStoresProvider).valueOrNull?.isNotEmpty == true &&
                !ref.watch(zeroStoresEmptySurfaceProvider) &&
                Gates.addCustomer.allows(ref))
            ? AppFAB(
                heroTag: 'customers_fab',
                onPressed: () => AddCustomerSheet.show(context),
                icon: AppIcons.userAdd,
                label: 'Add Customer',
              )
            : null,
      ),
    );
  }
}
