import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer.dart';
import 'package:reebaplus_pos/shared/widgets/notification_bell.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/customers/widgets/add_customer_sheet.dart';
import 'package:reebaplus_pos/features/customers/screens/customer_detail_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/slide_route.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_card.dart';

class CustomersScreen extends ConsumerStatefulWidget {
  const CustomersScreen({super.key});

  @override
  ConsumerState<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends ConsumerState<CustomersScreen> {
  bool _isFirstLoad = true;
  bool _isScrolled = false;

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
    final surfaceCol = Theme.of(context).colorScheme.surface;
    final textCol = Theme.of(context).colorScheme.onSurface;
    final subtextCol =
        Theme.of(context).textTheme.bodySmall?.color ??
        Theme.of(context).iconTheme.color!;
    final borderCol = Theme.of(context).dividerColor;
    final cardCol = Theme.of(context).cardColor;
    // §12.1: the store filter comes from the nav-drawer store picker
    // (null = "All Stores"); no per-screen store dropdown.
    final storeFilter = ref.watch(lockedStoreProvider).value;

    return Container(
      decoration: AppDecorations.glassyBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: _buildAppBar(context, surfaceCol, textCol, borderCol),
        drawer: const AppDrawer(activeRoute: 'customers'),
        body: Column(
          children: [
          Expanded(
            child: Builder(
              builder: (context) {
                final customers = ref.watch(customerServiceProvider).value;
                final balances =
                    ref.watch(walletBalancesKoboProvider).valueOrNull ??
                    const <String, int>{};
                if (_isFirstLoad) {
                  return const Center(child: CircularProgressIndicator());
                }

                List<Customer> filtered;

                if (storeFilter == null) {
                  // "All Stores" selected
                  filtered = customers;
                } else {
                  // A specific store selected
                  filtered = customers
                      .where((c) => c.storeId == storeFilter)
                      .toList();
                }

                if (filtered.isEmpty) {
                  return const AppRefreshWrapper(
                    child: CustomScrollView(
                      slivers: [
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(child: Text('No customers found.')),
                        ),
                      ],
                    ),
                  );
                }
                return NotificationListener<ScrollUpdateNotification>(
                  onNotification: (notif) {
                    if (notif.metrics.axis == Axis.vertical) {
                      final scrolled = notif.metrics.pixels > 10;
                      if (scrolled != _isScrolled) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) setState(() => _isScrolled = scrolled);
                        });
                      }
                    }
                    return false;
                  },
                  child: AppRefreshWrapper(
                    child: ListView.separated(
                      padding: context
                        .rPadding(16)
                        .copyWith(
                          bottom:
                              context.getRSize(100) +
                              context.deviceBottomPadding,
                        ),
                    itemCount: filtered.length,
                    separatorBuilder: (context, index) =>
                        SizedBox(height: context.getRSize(12)),
                    itemBuilder: (context, index) {
                      final c = filtered[index];
                      return _buildCustomerCard(
                        context,
                        c,
                        balances[c.id] ?? 0,
                        cardCol,
                        surfaceCol,
                        textCol,
                        subtextCol,
                        borderCol,
                      );
                    },
                  ),
                ),
              );
            },
            ),
          ),
        ],
      ),
      floatingActionButton: hasPermission(ref, 'customers.add')
          ? AppFAB(
              heroTag: 'customers_fab',
              onPressed: () => AddCustomerSheet.show(context),
              icon: FontAwesomeIcons.userPlus.data,
              label: 'Add Customer',
            )
          : null,
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(
    BuildContext context,
    Color surfaceCol,
    Color textCol,
    Color borderCol,
  ) {
    return AppBar(
      backgroundColor: _isScrolled ? Theme.of(context).colorScheme.surface.withValues(alpha: 0.8) : Colors.transparent,
      elevation: 0,
      actions: [
        const NotificationBell(),
        SizedBox(width: context.getRSize(8)),
      ],
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
                    color: textCol,
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
                    color: textCol,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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
              FontAwesomeIcons.users.data,
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
                    'Customers',
                    style: TextStyle(
                      fontSize: context.getRFontSize(18),
                      fontWeight: FontWeight.w800,
                      color: textCol,
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

  Widget _buildCustomerCard(
    BuildContext context,
    Customer customer,
    int balanceKobo,
    Color cardCol,
    Color surfaceCol,
    Color textCol,
    Color subtextCol,
    Color borderCol,
  ) {
    final isNegative = balanceKobo < 0;
    final balanceColor = isNegative ? danger : success;
    final formattedBalance = formatCurrency(balanceKobo / 100.0);

    return GlassyCard(
      radius: context.getRSize(16),
      padding: EdgeInsets.zero,
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            slideDownRoute(CustomerDetailScreen(customer: customer)),
          );
        },
        borderRadius: BorderRadius.circular(context.getRSize(16)),
        child: Padding(
          padding: context.rPadding(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: context.getRSize(24),
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.1),
                child: Text(
                  customer.name.isNotEmpty
                      ? customer.name.substring(0, 1).toUpperCase()
                      : '?',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.bold,
                    fontSize: context.getRFontSize(18),
                  ),
                ),
              ),
              SizedBox(width: context.getRSize(16)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      customer.name,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: context.getRFontSize(16),
                        color: textCol,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    SizedBox(height: context.getRSize(4)),
                    Text(
                      customer.addressText,
                      style: TextStyle(
                        fontSize: context.getRFontSize(13),
                        color: subtextCol,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    SizedBox(height: context.getRSize(6)),
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: context.getRSize(8),
                        vertical: context.getRSize(2),
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.2),
                        ),
                      ),
                      child: Text(
                        customer.priceTier.name.toUpperCase(),
                        style: TextStyle(
                          fontSize: context.getRFontSize(9),
                          fontWeight: FontWeight.w800,
                          color: Theme.of(context).colorScheme.primary,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: context.getRSize(12)),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'Balance',
                    style: TextStyle(
                      fontSize: context.getRFontSize(11),
                      color: subtextCol,
                    ),
                  ),
                  SizedBox(height: context.getRSize(2)),
                  Text(
                    formattedBalance,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: context.getRFontSize(16),
                      color: balanceColor,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
