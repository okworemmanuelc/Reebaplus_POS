import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/van_sales/widgets/van_receipt_view.dart';

/// The receipt for one road sale, re-opened from the driver profile's Sales tab
/// (#146).
///
/// A read-back, not a till: the sale is long since rung and this is a manager
/// looking at what the driver handed the customer. It is deliberately built
/// from the ORDER ITEMS rather than from anything live — a road sale is priced
/// at the trip's load price (spec §5.1), and re-pricing the lines off today's
/// catalogue would show a receipt that was never issued.
///
/// It can be printed and shared (#208 item 1) through the same
/// [VanReceiptView] the driver terminal uses, so the copy a manager produces
/// from the office is byte-for-byte the copy the driver produced at the
/// tailgate. Because the original was issued on the road, a copy taken here is
/// stamped REPRINTED / RESHARED — the rule the orders list and the customer
/// profile already follow, and what stops a duplicate passing as an original.
///
/// No crate deposit line: the road is **swap-only** in v1 (spec §11), so a road
/// sale never took a deposit and printing one would invent money.
class VanSaleReceiptSheet extends StatelessWidget {
  final OrderWithItems sale;

  const VanSaleReceiptSheet({super.key, required this.sale});

  static Future<void> show(BuildContext context, OrderWithItems sale) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => VanSaleReceiptSheet(sale: sale),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final order = sale.order;

    // `price` is in NAIRA and `qty` a plain count — the shape every other
    // receipt surface in the app passes (`ReceiptWidget` and the thermal
    // builder both read those two keys).
    final cart = <Map<String, dynamic>>[
      for (final line in sale.items)
        {
          'id': line.item.productId ?? line.item.id,
          'name': line.displayName,
          'size': line.product?.size,
          'unit': line.product?.unit,
          'qty': line.item.quantity,
          'price': line.item.unitPriceKobo / 100.0,
        },
    ];

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          Container(
            margin: EdgeInsets.symmetric(vertical: context.getRSize(12)),
            width: context.getRSize(40),
            height: context.getRSize(5),
            decoration: BoxDecoration(
              color: t.dividerColor,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                context.getRSize(16),
                context.getRSize(4),
                context.getRSize(16),
                context.getRSize(16) + context.deviceBottomPadding,
              ),
              children: [
                VanReceiptView(
                  orderNumber: order.orderNumber,
                  cart: cart,
                  totalKobo: order.netAmountKobo,
                  cashReceivedKobo: order.amountPaidKobo,
                  orderStatus: order.status,
                  isReopened: true,
                ),
                SizedBox(height: context.getRSize(16)),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Done'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
