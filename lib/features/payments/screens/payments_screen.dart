import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer.dart';
import 'package:reebaplus_pos/features/payments/widgets/record_supplier_activity.dart';
import 'package:reebaplus_pos/features/payments/widgets/supplier_form_sheet.dart';
import 'package:reebaplus_pos/shared/widgets/notification_bell.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/features/inventory/screens/supplier_detail_screen.dart';

class PaymentsScreen extends ConsumerStatefulWidget {
  const PaymentsScreen({super.key});

  @override
  ConsumerState<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends ConsumerState<PaymentsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String _periodFilter = 'This Month'; // §30.6/§30.11 default

  /// Period labels this viewer may choose (§19.2/§30.11 — roles below Manager
  /// are capped to Today/This Week/This Month).
  List<String> get _periodOptions =>
      datePeriodLabelsForRole(managerUp: isManagerOrAbove(ref));

  String get _effectivePeriod => _periodOptions.contains(_periodFilter)
      ? _periodFilter
      : _periodOptions.last;
  String _supplierFilter = 'All';
  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _border => Theme.of(context).dividerColor;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider);
    // §21 access: Supplier Accounts is gated by `suppliers.manage`. Fail CLOSED:
    // `perms` is empty while grants load → spinner, not a flash of no-access.
    final perms = ref.watch(currentUserPermissionsProvider);
    if (!perms.contains('suppliers.manage')) {
      return Scaffold(
        backgroundColor: _bg,
        drawer: const AppDrawer(activeRoute: 'supplier_accounts'),
        appBar: _buildAppBar(context),
        body: Center(
          child: perms.isEmpty
              ? const CircularProgressIndicator()
              : Text(
                  'You don’t have access to Supplier Accounts.',
                  style: TextStyle(
                    color: _subtext,
                    fontSize: context.getRFontSize(14),
                  ),
                ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: _bg,
      drawer: const AppDrawer(activeRoute: 'supplier_accounts'),
      appBar: _buildAppBar(context),
      body: Column(
        children: [
          _buildTabBar(context),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildPaymentsTab(context),
                _buildSuppliersTab(context),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: AppFAB(
        heroTag: 'payments_fab',
        onPressed: () => RecordPaymentSheet.show(context),
        icon: FontAwesomeIcons.plus,
        label: 'Add Payment',
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      backgroundColor: _surface,
      elevation: 0,
      iconTheme: IconThemeData(color: _text),
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
                    color: _text,
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
                    color: _text,
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
              gradient: LinearGradient(colors: [
                Theme.of(context).colorScheme.primary.withValues(alpha: 0.7),
                Theme.of(context).colorScheme.primary
              ]),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color:
                      Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(
              FontAwesomeIcons.moneyBillWave,
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
                      color: _text,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
                Text(
                  'Manage supplier payments',
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

  Widget _buildHeaderArea(BuildContext context, double totalAmount) {
    return Container(
      color: _surface,
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(8),
        context.getRSize(16),
        context.getRSize(16),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Total Payments',
                style: TextStyle(
                  color: _subtext,
                  fontSize: context.getRFontSize(13),
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: context.getRSize(4)),
              Text(
                formatCurrency(totalAmount),
                style: TextStyle(
                  color: _text,
                  fontSize: context.getRFontSize(24),
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.5,
                ),
              ),
            ],
          ),
          AppDropdown<String>(
            value: _effectivePeriod,
            width: context.getRSize(130),
            items: _periodOptions.map((String val) {
              return DropdownMenuItem<String>(value: val, child: Text(val));
            }).toList(),
            onChanged: (val) {
              if (val != null) {
                setState(() {
                  _periodFilter = val;
                  _supplierFilter = 'All';
                });
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChips(BuildContext context, List<String> suppliers) {
    return Container(
      color: _surface,
      padding: EdgeInsets.symmetric(
        vertical: context.getRSize(8),
        horizontal: context.getRSize(16),
      ),
      height: context.getRSize(56),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: suppliers.length,
        separatorBuilder: (context, index) =>
            SizedBox(width: context.getRSize(8)),
        itemBuilder: (context, index) {
          final sName = suppliers[index];
          final isSelected = sName == _supplierFilter;
          return FilterChip(
            label: Text(
              sName,
              style: TextStyle(
                fontSize: context.getRFontSize(12),
                color: isSelected ? Colors.white : _text,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
            selected: isSelected,
            onSelected: (val) {
              setState(() => _supplierFilter = sName);
            },
            selectedColor: Theme.of(context).colorScheme.primary,
            backgroundColor: _bg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(
                color: isSelected ? Colors.transparent : _border,
              ),
            ),
            showCheckmark: false,
          );
        },
      ),
    );
  }

  Widget _buildTabBar(BuildContext context) {
    return Container(
      color: _surface,
      child: TabBar(
        controller: _tabController,
        labelColor: Theme.of(context).colorScheme.primary,
        unselectedLabelColor: _subtext,
        indicatorColor: Theme.of(context).colorScheme.primary,
        indicatorWeight: 3,
        labelStyle: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: context.getRFontSize(14),
        ),
        tabs: const [
          Tab(text: 'Payments'),
          Tab(text: 'Suppliers'),
        ],
      ),
    );
  }

  Widget _buildPaymentsTab(BuildContext context) {
    final entries =
        ref.watch(supplierPaymentEntriesProvider).valueOrNull ??
            const <SupplierLedgerEntryData>[];
    final suppliers =
        ref.watch(allSuppliersProvider).valueOrNull ?? const <SupplierData>[];
    final nameById = {for (final s in suppliers) s.id: s.name};

    final window = datePeriodFromLabel(_effectivePeriod);
    final periodEntries =
        entries.where((e) => window.includes(e.activityDate)).toList();

    final supplierNames = <String>{
      for (final e in periodEntries) nameById[e.supplierId] ?? 'Unknown',
    }.toList()
      ..sort();
    supplierNames.insert(0, 'All');

    final filtered = periodEntries.where((e) {
      if (_supplierFilter == 'All') return true;
      return (nameById[e.supplierId] ?? 'Unknown') == _supplierFilter;
    }).toList();

    final total =
        filtered.fold<int>(0, (sum, e) => sum + e.amountKobo) / 100;

    return Column(
      children: [
        _buildHeaderArea(context, total.toDouble()),
        if (supplierNames.length > 1)
          _buildFilterChips(context, supplierNames),
        Expanded(child: _buildPaymentsList(context, filtered, nameById)),
      ],
    );
  }

  Widget _buildPaymentsList(
    BuildContext context,
    List<SupplierLedgerEntryData> list,
    Map<String, String> nameById,
  ) {
    if (list.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              FontAwesomeIcons.moneyCheckDollar,
              size: context.getRSize(48),
              color: _border,
            ),
            SizedBox(height: context.getRSize(16)),
            Text(
              'No payments found',
              style: TextStyle(
                color: _subtext,
                fontSize: context.getRFontSize(16),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.all(context.getRSize(16))
          .copyWith(bottom: context.getRSize(100) + context.deviceBottomInset),
      itemCount: list.length,
      itemBuilder: (context, index) {
        final e = list[index];
        return _PaymentCard(
          entry: e,
          supplierName: nameById[e.supplierId] ?? 'Unknown supplier',
        );
      },
    );
  }

  Widget _buildSuppliersTab(BuildContext context) {
    final suppliers =
        ref.watch(allSuppliersProvider).valueOrNull ?? const <SupplierData>[];
    final balances =
        ref.watch(supplierBalancesKoboProvider).valueOrNull ??
            const <String, int>{};
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.all(context.getRSize(16)),
          child: AppButton(
            text: 'Add Supplier',
            variant: AppButtonVariant.secondary,
            icon: FontAwesomeIcons.plus,
            onPressed: () => SupplierFormSheet.show(context),
          ),
        ),
        Expanded(
          child: suppliers.isEmpty
              ? Center(
                  child: Text(
                    'No suppliers added yet',
                    style: TextStyle(color: _subtext),
                  ),
                )
              : ListView.builder(
                  padding: EdgeInsets.fromLTRB(
                    context.getRSize(16),
                    0,
                    context.getRSize(16),
                    context.getRSize(120) + context.deviceBottomInset,
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
      ],
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
    final subtext = Theme.of(context).textTheme.bodySmall?.color ??
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
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                FontAwesomeIcons.buildingColumns,
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

class _PaymentCard extends StatelessWidget {
  final SupplierLedgerEntryData entry;
  final String supplierName;

  const _PaymentCard({required this.entry, required this.supplierName});

  String get _methodLabel {
    switch (entry.paymentMethod) {
      case 'cash':
        return 'Cash';
      case 'transfer':
        return 'Bank Transfer';
      case 'pos':
        return 'POS Card';
      case 'other':
        return 'Other';
      default:
        return entry.paymentMethod ?? 'Payment';
    }
  }

  @override
  Widget build(BuildContext context) {
    final cardBg = Theme.of(context).cardColor;
    final textCol = Theme.of(context).colorScheme.onSurface;
    final subtextCol = Theme.of(context).textTheme.bodySmall?.color ??
        Theme.of(context).iconTheme.color!;
    final borderCol = Theme.of(context).dividerColor;
    final isVoided = entry.voidedAt != null;

    final dateStr = DateFormat('MMM d, y').format(entry.activityDate);
    final hasReceipt = (entry.receiptPath ?? '').isNotEmpty;

    return Opacity(
      opacity: isVoided ? 0.55 : 1,
      child: Container(
        margin: EdgeInsets.only(bottom: context.getRSize(12)),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderCol),
        ),
        child: Padding(
          padding: EdgeInsets.all(context.getRSize(16)),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: EdgeInsets.all(context.getRSize(10)),
                decoration: BoxDecoration(
                  color: success.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  FontAwesomeIcons.moneyBillTransfer,
                  color: success,
                  size: context.getRSize(14),
                ),
              ),
              SizedBox(width: context.getRSize(12)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            supplierName,
                            style: TextStyle(
                              color: textCol,
                              fontWeight: FontWeight.bold,
                              fontSize: context.getRFontSize(15),
                              decoration: isVoided
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          formatCurrency(entry.amountKobo / 100),
                          style: TextStyle(
                            color: textCol,
                            fontWeight: FontWeight.bold,
                            fontSize: context.getRFontSize(15),
                            decoration: isVoided
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: context.getRSize(6)),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _methodLabel,
                          style: TextStyle(
                            color: subtextCol,
                            fontSize: context.getRFontSize(13),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          dateStr,
                          style: TextStyle(
                            color: subtextCol,
                            fontSize: context.getRFontSize(12),
                          ),
                        ),
                      ],
                    ),
                    if ((entry.referenceNote ?? '').isNotEmpty ||
                        hasReceipt) ...[
                      SizedBox(height: context.getRSize(8)),
                      Row(
                        children: [
                          Icon(
                            hasReceipt
                                ? FontAwesomeIcons.paperclip
                                : FontAwesomeIcons.hashtag,
                            size: context.getRSize(10),
                            color: subtextCol,
                          ),
                          SizedBox(width: context.getRSize(4)),
                          Expanded(
                            child: Text(
                              entry.referenceNote?.isNotEmpty == true
                                  ? entry.referenceNote!
                                  : 'Receipt attached',
                              style: TextStyle(
                                color: subtextCol,
                                fontSize: context.getRFontSize(12),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
