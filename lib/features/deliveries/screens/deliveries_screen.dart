import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/theme/colors.dart';

import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer.dart';
import 'package:reebaplus_pos/features/deliveries/data/models/delivery.dart';
import 'package:reebaplus_pos/features/deliveries/widgets/receive_delivery_sheet.dart';
import 'package:reebaplus_pos/shared/widgets/notification_bell.dart';

class DeliveriesScreen extends ConsumerStatefulWidget {
  const DeliveriesScreen({super.key});

  @override
  ConsumerState<DeliveriesScreen> createState() => _DeliveriesScreenState();
}

class _DeliveriesScreenState extends ConsumerState<DeliveriesScreen> {
  String _filter = 'All';
  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get textCol => Theme.of(context).colorScheme.onSurface;
  Color get subtextCol => Theme.of(context).textTheme.bodySmall?.color ?? Theme.of(context).iconTheme.color!;
  Color get borderCol => Theme.of(context).dividerColor;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
          backgroundColor: _bg,
          drawer: const AppDrawer(activeRoute: 'deliveries'),
          appBar: _buildAppBar(context),
          body: Column(
            children: [
              _buildFilterChips(context),
              Expanded(
                child: Builder(
                  builder: (context) {
                    final deliveries = ref.watch(deliveryServiceProvider).value;
                    final filtered = _getFilteredDeliveries(deliveries);

                    if (filtered.isEmpty) {
                      return _buildEmptyState(context);
                    }

                    return _buildDeliveriesList(context, filtered);
                  },
                ),
              ),
            ],
          ),
          floatingActionButton: AppFAB(
            heroTag: 'deliveries_fab',
            onPressed: () => ReceiveDeliverySheet.show(context),
            icon: FontAwesomeIcons.truckRampBox,
            label: 'Receive Delivery',
          ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      backgroundColor: _surface,
      elevation: 0,
      iconTheme: IconThemeData(color: textCol),
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
      title: Text(
        'Deliveries',
        style: TextStyle(
          color: textCol,
          fontSize: context.getRFontSize(18),
          fontWeight: FontWeight.bold,
        ),
      ),
      centerTitle: true,
      actions: [
        const NotificationBell(),
        SizedBox(width: context.getRSize(8)),
      ],
    );
  }


  Widget _buildFilterChips(BuildContext context) {
    final filters = ['Today', 'This Week', 'This Month', 'This Year', 'All'];
    return Container(
      color: Colors.transparent,
      padding: EdgeInsets.symmetric(vertical: context.getRSize(16)),
      height: context.getRSize(64),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: context.getRSize(16)),
        itemCount: filters.length,
        separatorBuilder: (context, index) =>
            SizedBox(width: context.getRSize(8)),
        itemBuilder: (context, index) {
          final f = filters[index];
          final isSelected = f == _filter;
          return FilterChip(
            label: Text(
              f,
              style: TextStyle(
                fontSize: context.getRFontSize(12),
                color: isSelected ? Colors.white : textCol,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
            selected: isSelected,
            onSelected: (val) {
              setState(() => _filter = f);
            },
            selectedColor: Theme.of(context).colorScheme.primary,
            backgroundColor: _surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(
                color: isSelected ? Colors.transparent : borderCol,
              ),
            ),
            showCheckmark: false,
          );
        },
      ),
    );
  }

  List<Delivery> _getFilteredDeliveries(List<Delivery> deliveries) {
    final now = DateTime.now();
    return deliveries.where((d) {
      if (_filter == 'All') return true;
      final diff = now.difference(d.deliveredAt);
      if (_filter == 'Today') {
        return diff.inDays == 0 && now.day == d.deliveredAt.day;
      }
      if (_filter == 'This Week') return diff.inDays <= 7;
      if (_filter == 'This Month') return diff.inDays <= 30;
      if (_filter == 'This Year') return diff.inDays <= 365;
      return true;
    }).toList();
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            FontAwesomeIcons.boxOpen,
            size: context.getRSize(48),
            color: borderCol,
          ),
          SizedBox(height: context.getRSize(16)),
          Text(
            'No deliveries yet',
            style: TextStyle(
              color: subtextCol,
              fontSize: context.getRFontSize(16),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeliveriesList(BuildContext context, List<Delivery> deliveries) {
    // Group by supplier
    final Map<String, List<Delivery>> bySupplier = {};
    for (var del in deliveries) {
      bySupplier.putIfAbsent(del.supplierName, () => []).add(del);
    }

    // Convert map to a flat list for ListView with headers
    final List<dynamic> listItems = [];
    bySupplier.forEach((supplier, dels) {
      listItems.add(supplier);
      // Sort within group by date desc
      dels.sort((a, b) => b.deliveredAt.compareTo(a.deliveredAt));
      listItems.addAll(dels);
    });

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        0,
        context.getRSize(16),
        context.getRSize(100) + context.deviceBottomPadding,
      ),
      itemCount: listItems.length,
      itemBuilder: (context, index) {
        final item = listItems[index];
        if (item is String) {
          // Supplier Header
          return Padding(
            padding: EdgeInsets.only(
              top: index == 0 ? 0 : context.getRSize(16),
              bottom: context.getRSize(8),
              left: context.getRSize(4),
            ),
            child: Text(
              item,
              style: TextStyle(
                color: subtextCol,
                fontWeight: FontWeight.bold,
                fontSize: context.getRFontSize(14),
              ),
            ),
          );
        } else if (item is Delivery) {
          return _DeliveryCard(delivery: item);
        }
        return const SizedBox.shrink();
      },
    );
  }
}

class _DeliveryCard extends StatelessWidget {
  final Delivery delivery;

  const _DeliveryCard({required this.delivery});

  @override
  Widget build(BuildContext context) {
    final textCol = Theme.of(context).colorScheme.onSurface;
    final subtextCol = Theme.of(context).textTheme.bodySmall?.color ?? Theme.of(context).iconTheme.color!;
    final borderCol = Theme.of(context).dividerColor;
    final cardCol = Theme.of(context).cardColor;
    final isPending = delivery.status == 'pending';
    final statusColor = isPending ? const Color(0xFFF59E0B) : success;

    final time = delivery.deliveredAt;
    final isToday =
        time.year == DateTime.now().year &&
        time.month == DateTime.now().month &&
        time.day == DateTime.now().day;
    final dateStr = isToday
        ? 'Today, '
        : '${time.day}/${time.month}/${time.year} ';
    final timeStr =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    return Container(
      margin: EdgeInsets.only(bottom: context.getRSize(12)),
      decoration: BoxDecoration(
        color: cardCol,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderCol),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      FontAwesomeIcons.truck,
                      size: context.getRSize(14),
                      color: subtextCol,
                    ),
                    SizedBox(width: context.getRSize(8)),
                    Text(
                      '$dateStr$timeStr',
                      style: TextStyle(
                        color: subtextCol,
                        fontSize: context.getRFontSize(13),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.getRSize(8),
                    vertical: context.getRSize(4),
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: statusColor.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Text(
                    delivery.status.toUpperCase(),
                    style: TextStyle(
                      color: statusColor,
                      fontWeight: FontWeight.bold,
                      fontSize: context.getRFontSize(10),
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: context.getRSize(12)),
            Divider(height: 1, color: borderCol),
            SizedBox(height: context.getRSize(12)),

            // Items Summary
            Text(
              '${delivery.items.length} Product(s)',
              style: TextStyle(
                color: textCol,
                fontWeight: FontWeight.bold,
                fontSize: context.getRFontSize(14),
              ),
            ),
            SizedBox(height: context.getRSize(4)),
            ...delivery.items.take(3).map((item) {
              return Padding(
                padding: EdgeInsets.only(bottom: context.getRSize(2)),
                child: Text(
                  '${item.quantity.toInt()}x ${item.productName}',
                  style: TextStyle(
                    color: subtextCol,
                    fontSize: context.getRFontSize(13),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              );
            }),
            if (delivery.items.length > 3)
              Text(
                '...and ${delivery.items.length - 3} more',
                style: TextStyle(
                  color: subtextCol,
                  fontSize: context.getRFontSize(12),
                  fontStyle: FontStyle.italic,
                ),
              ),

            SizedBox(height: context.getRSize(12)),
            Divider(height: 1, color: borderCol),
            SizedBox(height: context.getRSize(12)),

            // Total Value
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Total Value',
                  style: TextStyle(
                    color: subtextCol,
                    fontSize: context.getRFontSize(13),
                  ),
                ),
                Text(
                  formatCurrency(delivery.totalValue),
                  style: TextStyle(
                    color: textCol,
                    fontWeight: FontWeight.w800,
                    fontSize: context.getRFontSize(15),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}




