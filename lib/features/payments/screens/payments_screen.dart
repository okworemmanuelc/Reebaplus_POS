import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/theme/colors.dart';

import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer.dart';
import 'package:reebaplus_pos/features/payments/data/models/payment.dart';
import 'package:reebaplus_pos/features/payments/widgets/add_payment_sheet.dart';
import 'package:reebaplus_pos/shared/widgets/notification_bell.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/features/inventory/data/models/supplier.dart';
import 'package:reebaplus_pos/features/inventory/screens/supplier_detail_screen.dart';
import 'package:reebaplus_pos/features/inventory/data/models/inventory_log.dart';
import 'package:reebaplus_pos/features/inventory/data/inventory_data.dart';
import 'package:reebaplus_pos/features/inventory/data/models/crate_group.dart';

class PaymentsScreen extends ConsumerStatefulWidget {
  const PaymentsScreen({super.key});

  @override
  ConsumerState<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends ConsumerState<PaymentsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String _periodFilter = 'This Month';
  String _supplierFilter = 'All';
  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext => Theme.of(context).textTheme.bodySmall?.color ?? Theme.of(context).iconTheme.color!;
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
            onPressed: () => AddPaymentSheet.show(context),
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
              gradient: LinearGradient(colors: [Theme.of(context).colorScheme.primary.withValues(alpha: 0.7), Theme.of(context).colorScheme.primary]),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
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
              value: _periodFilter,
              width: context.getRSize(130),
              items: [
                'Today',
                'This Week',
                'This Month',
                'This Year',
                'All Time',
              ].map((String val) {
                return DropdownMenuItem<String>(value: val, child: Text(val));
              }).toList(),
              onChanged: (val) {
                if (val != null) {
                  setState(() {
                    _periodFilter = val;
                    _supplierFilter = 'All'; // Reset supplier filter on period change
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
    return Builder(
      builder: (context) {
        final paymentSvc = ref.watch(paymentServiceProvider);
        final periodPayments = paymentSvc.getByPeriod(_periodFilter);

        // Compute unique suppliers for chips
        final Set<String> supplierNames = {};
        for (var p in periodPayments) {
          supplierNames.add(p.supplierName);
        }
        final supplierList = supplierNames.toList()..sort();
        supplierList.insert(0, 'All');

        // Apply supplier filter
        final filteredPayments = periodPayments.where((p) {
          if (_supplierFilter == 'All') return true;
          return p.supplierName == _supplierFilter;
        }).toList();

        filteredPayments.sort((a, b) => b.date.compareTo(a.date));

        final totalForPeriod = filteredPayments.fold(
          0.0,
          (sum, p) => sum + p.amount,
        );

        return Column(
          children: [
            _buildHeaderArea(context, totalForPeriod),
            if (supplierList.length > 1)
              _buildFilterChips(context, supplierList),
            Expanded(child: _buildPaymentsList(context, filteredPayments)),
          ],
        );
      },
    );
  }

  Widget _buildSuppliersTab(BuildContext context) {
    final supplierSvc = ref.watch(supplierServiceProvider);
    final suppliers = supplierSvc.getAll();
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.all(context.getRSize(16)),
          child: AppButton(
            text: 'Add Supplier',
            variant: AppButtonVariant.secondary,
            icon: FontAwesomeIcons.plus,
            onPressed: _showAddSupplierDialog,
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
                    return GestureDetector(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SupplierDetailScreen(supplier: s),
                        ),
                      ).then((_) => setState(() {})),
                      child: Container(
                        margin: EdgeInsets.only(bottom: context.getRSize(12)),
                        padding: EdgeInsets.all(context.getRSize(16)),
                        decoration: BoxDecoration(
                          color: Theme.of(context).cardColor,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: _border),
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
                                    s.name,
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: context.getRFontSize(16),
                                      color: _text,
                                    ),
                                  ),
                                  if (s.contactDetails.isNotEmpty) ...[
                                    SizedBox(height: context.getRSize(4)),
                                    Text(
                                      s.contactDetails,
                                      style: TextStyle(
                                        color: _subtext,
                                        fontSize: context.getRFontSize(13),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            Icon(
                              Icons.chevron_right,
                              color: _subtext,
                              size: context.getRSize(20),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _showAddSupplierDialog() {
    final nameCtrl = TextEditingController();
    final contactCtrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setB) => Padding(
          padding: EdgeInsets.only(bottom: ctx.deviceBottomInset),
          child: Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
            ),
            padding: EdgeInsets.fromLTRB(
              ctx.getRSize(20),
              ctx.getRSize(20),
              ctx.getRSize(20),
              ctx.getRSize(32),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: _border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                SizedBox(height: ctx.getRSize(20)),
                Text(
                  'Add New Supplier',
                  style: TextStyle(
                    fontSize: ctx.getRFontSize(20),
                    fontWeight: FontWeight.w800,
                    color: _text,
                  ),
                ),
                SizedBox(height: ctx.getRSize(4)),
                Text(
                  'Enter the company and contact details',
                  style: TextStyle(
                    fontSize: ctx.getRFontSize(13),
                    color: _subtext,
                  ),
                ),
                SizedBox(height: ctx.getRSize(20)),
                _inputField(
                  'Supplier / Company Name',
                  nameCtrl,
                  'e.g. SABMiller Nigeria',
                ),
                SizedBox(height: ctx.getRSize(16)),
                _inputField(
                  'Contact Details / Rep Info',
                  contactCtrl,
                  'e.g. John Doe, 08012345678',
                ),
                SizedBox(height: ctx.getRSize(32)),
                AppButton(
                  text: 'Add Supplier',
                  onPressed: () {
                    if (nameCtrl.text.trim().isEmpty) return;
                    final newSupplier = Supplier(
                      id: 's${DateTime.now().millisecondsSinceEpoch}',
                      name: nameCtrl.text.trim(),
                      crateGroup: CrateGroup.nbPlc,
                      trackInventory: true,
                      contactDetails: contactCtrl.text.trim(),
                      amountPaid: 0.0,
                      supplierWallet: 0.0,
                    );
                    final log = InventoryLog(
                      timestamp: DateTime.now(),
                      user: ref.read(authProvider).currentUser?.name ?? 'Unknown',
                      itemId: newSupplier.id,
                      itemName: newSupplier.name,
                      action: 'new_supplier',
                      previousValue: 0,
                      newValue: 0,
                      note: 'Supplier added: ${newSupplier.name}',
                    );
                    setState(() {
                      ref.read(supplierServiceProvider).addSupplier(newSupplier);
                      kInventoryLogs.add(log);
                    });
                    Navigator.pop(ctx);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _inputField(String label, TextEditingController ctrl, String hint) {
    return AppInput(
      controller: ctrl,
      labelText: label,
      hintText: hint,
      fillColor: _bg,
    );
  }

  Widget _buildPaymentsList(BuildContext context, List<Payment> list) {
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
      padding: EdgeInsets.all(
        context.getRSize(16),
      ).copyWith(bottom: context.getRSize(100) + context.deviceBottomInset),
      itemCount: list.length,
      itemBuilder: (context, index) {
        final payment = list[index];
        return _PaymentCard(payment: payment);
      },
    );
  }
}

class _PaymentCard extends StatelessWidget {
  final Payment payment;

  const _PaymentCard({required this.payment});

  @override
  Widget build(BuildContext context) {
    
    final cardBg = Theme.of(context).cardColor;
    final textCol = Theme.of(context).colorScheme.onSurface;
    final subtextCol = Theme.of(context).textTheme.bodySmall?.color ?? Theme.of(context).iconTheme.color!;
    final borderCol = Theme.of(context).dividerColor;

    final dateStr = DateFormat('MMM d, y • h:mm a').format(payment.date);

    return Container(
      margin: EdgeInsets.only(bottom: context.getRSize(12)),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderCol),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
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
                FontAwesomeIcons.arrowUpRightFromSquare,
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
                          payment.supplierName,
                          style: TextStyle(
                            color: textCol,
                            fontWeight: FontWeight.bold,
                            fontSize: context.getRFontSize(15),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        formatCurrency(payment.amount),
                        style: TextStyle(
                          color: textCol,
                          fontWeight: FontWeight.bold,
                          fontSize: context.getRFontSize(15),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: context.getRSize(6)),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        payment.paymentMethod,
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
                  if (payment.referenceNumber != null &&
                      payment.referenceNumber!.isNotEmpty) ...[
                    SizedBox(height: context.getRSize(8)),
                    Row(
                      children: [
                        Icon(
                          FontAwesomeIcons.hashtag,
                          size: context.getRSize(10),
                          color: subtextCol,
                        ),
                        SizedBox(width: context.getRSize(4)),
                        Text(
                          payment.referenceNumber!,
                          style: TextStyle(
                            color: subtextCol,
                            fontSize: context.getRFontSize(12),
                            fontFamily: 'monospace',
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
    );
  }
}







