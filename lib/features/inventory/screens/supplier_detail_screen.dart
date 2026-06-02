import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/theme/colors.dart';

import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/core/utils/stock_calculator.dart';
import 'package:reebaplus_pos/features/inventory/data/inventory_data.dart';
import 'package:reebaplus_pos/features/inventory/data/models/supplier.dart';
import 'package:reebaplus_pos/features/inventory/data/models/inventory_item.dart';
import 'package:reebaplus_pos/features/inventory/data/models/crate_group.dart';
import 'package:reebaplus_pos/features/inventory/data/models/crate_stock.dart';
import 'package:reebaplus_pos/features/inventory/data/models/inventory_log.dart';
import 'package:reebaplus_pos/features/pos/data/products_data.dart';

class SupplierDetailScreen extends StatefulWidget {
  final Supplier supplier;

  const SupplierDetailScreen({super.key, required this.supplier});

  @override
  State<SupplierDetailScreen> createState() => _SupplierDetailScreenState();
}

class _SupplierDetailScreenState extends State<SupplierDetailScreen> {
  String _timeFilter = 'Last 30 days'; // §30.6/§30.11 default
  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _cardBg => Theme.of(context).cardColor;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _border => Theme.of(context).dividerColor;

  @override
  Widget build(BuildContext context) {
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
            'Supplier Details',
            style: TextStyle(
              color: _text,
              fontSize: context.getRFontSize(18),
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        body: ListView(
          padding: EdgeInsets.all(context.getRSize(20)).copyWith(
            bottom: context.getRSize(20) + context.deviceBottomInset,
          ),
          children: [
            _buildHeader(context),
            SizedBox(height: context.getRSize(24)),
            _buildFinancials(context),
            SizedBox(height: context.getRSize(24)),
            _buildEmptyCrates(context),
            SizedBox(height: context.getRSize(24)),
            _buildFilterTabs(context),
            SizedBox(height: context.getRSize(16)),
            _buildGoodsReceivedList(context),
            SizedBox(height: context.getRSize(40)),
          ],
        ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Column(
      children: [
        Container(
          width: context.getRSize(80),
          height: context.getRSize(80),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(
            FontAwesomeIcons.buildingColumns,
            color: Theme.of(context).colorScheme.primary,
            size: context.getRSize(32),
          ),
        ),
        SizedBox(height: context.getRSize(16)),
        Text(
          widget.supplier.name,
          style: TextStyle(
            fontSize: context.getRFontSize(22),
            fontWeight: FontWeight.w800,
            color: _text,
          ),
          textAlign: TextAlign.center,
        ),
        if (widget.supplier.contactDetails.isNotEmpty) ...[
          SizedBox(height: context.getRSize(8)),
          Text(
            widget.supplier.contactDetails,
            style: TextStyle(
              fontSize: context.getRFontSize(14),
              color: _subtext,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }

  Widget _buildFinancials(BuildContext context) {
    final outstanding = widget.supplier.supplierWallet;
    // Owed (negative balance) -> Red, Credit (positive balance) -> Green
    final balanceColor = outstanding < 0 ? danger : success;
    final balanceLabel = outstanding < 0 ? 'Amount Owed' : 'Credit Balance';

    return Container(
      padding: EdgeInsets.all(context.getRSize(20)),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _border),
      ),
      child: Column(
        children: [
          _finRow(
            context,
            'Amount Paid',
            formatCurrency(widget.supplier.amountPaid),
            _text,
          ),
          Divider(height: context.getRSize(24), color: _border),
          _finRow(
            context,
            balanceLabel,
            formatCurrency(outstanding),
            balanceColor,
          ),
        ],
      ),
    );
  }

  Widget _finRow(
    BuildContext context,
    String label,
    String amount,
    Color color,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: context.getRFontSize(15),
            color: _subtext,
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(
          amount,
          style: TextStyle(
            fontSize: context.getRFontSize(18),
            color: color,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyCrates(BuildContext context) {
    // Hidden crate group linkage to find crates for this supplier
    final crateStock = kCrateStocks.firstWhere(
      (c) => c.group == widget.supplier.crateGroup,
      orElse: () => CrateStock(group: widget.supplier.crateGroup),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Available Empty Crates',
          style: TextStyle(
            fontSize: context.getRFontSize(16),
            fontWeight: FontWeight.w800,
            color: _text,
          ),
        ),
        SizedBox(height: context.getRSize(12)),
        Container(
          padding: EdgeInsets.all(context.getRSize(16)),
          decoration: BoxDecoration(
            color: _cardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _border),
          ),
          child: Row(
            children: [
              Container(
                width: context.getRSize(40),
                height: context.getRSize(40),
                decoration: BoxDecoration(
                  color: widget.supplier.crateGroup.color.withValues(
                    alpha: 0.1,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  FontAwesomeIcons.beerMugEmpty,
                  color: widget.supplier.crateGroup.color,
                  size: context.getRSize(18),
                ),
              ),
              SizedBox(width: context.getRSize(16)),
              Expanded(
                child: Text(
                  crateStock.label,
                  style: TextStyle(
                    fontSize: context.getRFontSize(15),
                    fontWeight: FontWeight.bold,
                    color: _text,
                  ),
                ),
              ),
              Text(
                '${crateStock.available.toInt()} crates',
                style: TextStyle(
                  fontSize: context.getRFontSize(15),
                  fontWeight: FontWeight.bold,
                  color: _text,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFilterTabs(BuildContext context) {
    const filters = kDatePeriodLabels;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: filters.map((f) {
          final active = _timeFilter == f;
          return Padding(
            padding: EdgeInsets.only(right: context.getRSize(8)),
            child: GestureDetector(
              onTap: () => setState(() => _timeFilter = f),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: EdgeInsets.symmetric(
                  horizontal: context.getRSize(16),
                  vertical: context.getRSize(8),
                ),
                decoration: BoxDecoration(
                  color: active ? blueMain : _cardBg,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: active ? blueMain : _border),
                ),
                child: Text(
                  f,
                  style: TextStyle(
                    fontSize: context.getRFontSize(13),
                    fontWeight: active ? FontWeight.bold : FontWeight.w600,
                    color: active ? Colors.white : _subtext,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  List<InventoryLog> _getFilteredLogs() {
    final itemsForSupplier = kInventoryItems.where(
      (i) => i.supplierId == widget.supplier.id,
    );
    final itemIds = itemsForSupplier.map((e) => e.id).toSet();

    final window = datePeriodFromLabel(_timeFilter);

    return kInventoryLogs.where((log) {
      if (log.action != 'restock' && log.action != 'new_product') return false;
      if (!itemIds.contains(log.itemId)) return false;
      if (!window.includes(log.timestamp)) return false;
      return true;
    }).toList()..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  }

  Widget _buildGoodsReceivedList(BuildContext context) {
    final logs = _getFilteredLogs();

    // Map log itemId to its corresponding product's buying price
    // Since kProducts has "wholesale_price" and kInventoryItems maps to kProducts by name (in this mock setup)
    double totalValue = 0;
    for (var log in logs) {
      final item = kInventoryItems.firstWhere(
        (i) => i.id == log.itemId,
        orElse: () => InventoryItem(
          id: '',
          productName: log.itemName,
          subtitle: '',
          supplierId: widget.supplier.id,
          icon: Icons.error,
          color: Colors.grey,
        ),
      );
      final product = kProducts.firstWhere(
        (p) => p['name'] == item.productName,
        orElse: () => <String, dynamic>{},
      );
      final buyingPrice = (product['wholesale_price'] as int?) ?? 0;
      final qty = (log.newValue - log.previousValue).abs();
      totalValue += stockValue(buyingPrice.toDouble(), qty);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Goods Received',
              style: TextStyle(
                fontSize: context.getRFontSize(16),
                fontWeight: FontWeight.w800,
                color: _text,
              ),
            ),
            Text(
              'Total: ${formatCurrency(totalValue)}',
              style: TextStyle(
                fontSize: context.getRFontSize(15),
                fontWeight: FontWeight.w800,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
        ),
        SizedBox(height: context.getRSize(16)),
        if (logs.isEmpty)
          Center(
            child: Padding(
              padding: EdgeInsets.all(context.getRSize(20)),
              child: Text(
                'No goods received in this period',
                style: TextStyle(color: _subtext),
              ),
            ),
          )
        else
          ...logs.map((log) {
            final qty = (log.newValue - log.previousValue).abs();
            final item = kInventoryItems.firstWhere(
              (i) => i.id == log.itemId,
              orElse: () => InventoryItem(
                id: '',
                productName: log.itemName,
                subtitle: '',
                supplierId: widget.supplier.id,
                icon: Icons.local_drink,
                color: Colors.grey,
              ),
            );
            final product = kProducts.firstWhere(
              (p) => p['name'] == item.productName,
              orElse: () => <String, dynamic>{},
            );
            final buyingPrice = (product['wholesale_price'] as int?) ?? 0;

            return Container(
              margin: EdgeInsets.only(bottom: context.getRSize(12)),
              padding: EdgeInsets.all(context.getRSize(16)),
              decoration: BoxDecoration(
                color: _cardBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _border),
              ),
              child: Row(
                children: [
                  Container(
                    width: context.getRSize(40),
                    height: context.getRSize(40),
                    decoration: BoxDecoration(
                      color: item.color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      item.icon,
                      color: item.color,
                      size: context.getRSize(18),
                    ),
                  ),
                  SizedBox(width: context.getRSize(16)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          log.itemName,
                          style: TextStyle(
                            fontSize: context.getRFontSize(15),
                            fontWeight: FontWeight.bold,
                            color: _text,
                          ),
                        ),
                        SizedBox(height: context.getRSize(4)),
                        Text(
                          '${log.timestamp.day}/${log.timestamp.month}/${log.timestamp.year} • ${formatCurrency(buyingPrice)}/unit',
                          style: TextStyle(
                            fontSize: context.getRFontSize(12),
                            color: _subtext,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '+${qty.toInt()}',
                    style: TextStyle(
                      fontSize: context.getRFontSize(16),
                      fontWeight: FontWeight.w800,
                      color: success,
                    ),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }
}
