import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer.dart';
import 'package:reebaplus_pos/shared/widgets/notification_bell.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/customers/widgets/add_customer_sheet.dart';
import 'package:reebaplus_pos/features/customers/screens/customer_detail_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/slide_route.dart';

class CustomersScreen extends ConsumerStatefulWidget {
  const CustomersScreen({super.key});

  @override
  ConsumerState<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends ConsumerState<CustomersScreen> {
  bool _isFirstLoad = true;
  List<StoreData> _stores = [];
  // null = "All Stores"
  String? _selectedStoreId;

  @override
  void initState() {
    super.initState();
    _loadStores();
  }

  Future<void> _loadStores() async {
    final db = ref.read(databaseProvider);
    final ws = await db.select(db.stores).get();

    final nav = ref.read(navigationProvider);
    final oneShot = nav.customersInitialStoreId.value;

    String? defaultId;
    if (oneShot != null) {
      // One-shot pre-filter set by another screen (e.g. store details
      // "Customers" card). Consume immediately so it only applies once.
      defaultId = oneShot;
      nav.customersInitialStoreId.value = null;
    } else {
      // Lone owner: default to the store currently selected on the POS screen
      defaultId = nav.lockedStoreId.value;
    }

    if (mounted) {
      setState(() {
        _stores = ws;
        _selectedStoreId = defaultId;
        _isFirstLoad = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
        final bgCol = Theme.of(context).scaffoldBackgroundColor;
        final surfaceCol = Theme.of(context).colorScheme.surface;
        final textCol = Theme.of(context).colorScheme.onSurface;
        final subtextCol =
            Theme.of(context).textTheme.bodySmall?.color ??
            Theme.of(context).iconTheme.color!;
        final borderCol = Theme.of(context).dividerColor;
        final cardCol = Theme.of(context).cardColor;

        return Scaffold(
          backgroundColor: bgCol,
          appBar: _buildAppBar(context, surfaceCol, textCol, borderCol),
          drawer: const AppDrawer(activeRoute: 'customers'),
          body: Column(
            children: [
              _buildStoreFilter(
                context,
                surfaceCol,
                textCol,
                subtextCol,
                borderCol,
              ),

              Expanded(
                child: Builder(
                  builder: (context) {
                    final customers = ref.watch(customerServiceProvider).value;
                    final balances = ref
                            .watch(walletBalancesKoboProvider)
                            .valueOrNull ??
                        const <String, int>{};
                    if (_isFirstLoad) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    List<Customer> filtered;

                    if (_selectedStoreId == null) {
                      // "All" selected
                      filtered = customers;
                    } else {
                      // A specific store selected
                      filtered = customers
                          .where((c) => c.storeId == _selectedStoreId)
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
                    return AppRefreshWrapper(
                      child: ListView.separated(
                        padding: context.rPadding(16).copyWith(
                              bottom: context.getRSize(100) + context.bottomInset,
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
                    );
                  },
                ),
              ),
            ],
          ),
          floatingActionButton: AppFAB(
            heroTag: 'customers_fab',
            onPressed: () => AddCustomerSheet.show(context),
            icon: FontAwesomeIcons.userPlus,
            label: 'Add Customer',
          ),
        );
  }

  Widget _buildStoreFilter(
    BuildContext context,
    Color surfaceCol,
    Color textCol,
    Color subtextCol,
    Color borderCol,
  ) {
    return Container(
      color: surfaceCol,
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(8),
        context.getRSize(16),
        context.getRSize(8),
      ),
      child: Row(
        children: [
          Icon(
            FontAwesomeIcons.store,
            size: context.getRSize(13),
            color: subtextCol,
          ),
          SizedBox(width: context.getRSize(8)),
          Text(
            'Showing:',
            style: TextStyle(
              fontSize: context.getRFontSize(13),
              color: subtextCol,
            ),
          ),
          SizedBox(width: context.getRSize(8)),
          Expanded(
            child: AppDropdown<String?>(
              value: _selectedStoreId,
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text(
                    'All Stores',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                ..._stores.map(
                  (w) => DropdownMenuItem<String?>(
                    value: w.id,
                    child: Text(w.name, overflow: TextOverflow.ellipsis),
                  ),
                ),
              ],
              onChanged: (id) => setState(() => _selectedStoreId = id),
            ),
          ),
        ],
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
      backgroundColor: surfaceCol,
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
              FontAwesomeIcons.users,
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
                  'Client Management',
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

    return InkWell(
      onTap: () {
        Navigator.push(
          context,
          slideDownRoute(CustomerDetailScreen(customer: customer)),
        );
      },
      borderRadius: BorderRadius.circular(context.getRSize(16)),
      child: Container(
        decoration: BoxDecoration(
          color: surfaceCol,
          borderRadius: BorderRadius.circular(context.getRSize(16)),
          border: Border.all(color: borderCol),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.02),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
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
                        customer.customerGroup.name.toUpperCase(),
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
