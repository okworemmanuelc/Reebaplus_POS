import 'package:flutter/material.dart';

import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/online_orders/online_order_answer.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/tag_pill.dart';

// Parts for the Online tab and the Online Order detail (#427). Plain data and
// callbacks only: nothing here decides a status or writes.

/// Keys the Online Orders tests find the parts by.
abstract final class OnlineOrderKeys {
  static const tab = Key('orders-online-tab');
  static const tabBadge = Key('orders-online-badge');
  static const accept = Key('online-order-accept');
  static const decline = Key('online-order-decline');
  static const cancelOrder = Key('online-order-cancel');
  static const cancelReason = Key('online-order-cancel-reason');
  static const cancelConfirm = Key('online-order-cancel-confirm');
  static Key lineLower(String id) => ValueKey('online-order-lower-$id');
  static Key lineRemove(String id) => ValueKey('online-order-remove-$id');
  static Key linePriceFlag(String id) => ValueKey('online-order-price-$id');
  static const declineOther = Key('online-order-decline-other');
  static const declineConfirm = Key('online-order-decline-confirm');
  static const linkSearch = Key('online-order-link-search');
  static const linkNew = Key('online-order-link-new');
  static Key card(String id) => ValueKey('online-order-card-$id');
  static Key linkCustomer(String id) => ValueKey('online-order-link-$id');
}

/// The status words and tone of an Online Order.
(String, TagPillTone) onlineOrderStatusPill(String status) => switch (status) {
  'new' => ('NEW', TagPillTone.warning),
  'accepted' => ('ACCEPTED', TagPillTone.green),
  'declined' => ('DECLINED', TagPillTone.danger),
  'cancelled_by_customer' => ('CANCELLED', TagPillTone.danger),
  'cancelled_by_shop' => ('CANCELLED', TagPillTone.danger),
  'fulfilled' => ('DONE', TagPillTone.info),
  _ => ('EXPIRED', TagPillTone.neutral),
};

/// The sentence under a closed order's status, if any.
String? onlineOrderStatusNote(OnlineOrderData o) => switch (o.status) {
  // A Shopper can cancel only while the order is `new`, so this is always
  // true of a customer cancel — including the one that beat an Accept.
  'cancelled_by_customer' => kCancelledBeforeAcceptText,
  'declined' => 'You declined: ${o.declineReason ?? ''}',
  'cancelled_by_shop' => 'You cancelled: ${o.cancelReason ?? ''}',
  'expired' => 'Not answered in time',
  _ => null,
};

/// The delivery address on one line.
String onlineOrderAddress(OnlineOrderData o) => [
  o.deliveryStreet,
  o.deliveryLga,
  o.deliveryState,
].where((p) => p.trim().isNotEmpty).join(', ');

String _money(int kobo) => formatCurrency(kobo / 100.0);

/// The status pill of an Online Order.
class OnlineOrderStatusPill extends StatelessWidget {
  const OnlineOrderStatusPill({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final (label, tone) = onlineOrderStatusPill(status);
    return TagPill(label: label, tone: tone);
  }
}

/// One Online Order in the Online tab list.
class OnlineOrderCard extends StatelessWidget {
  const OnlineOrderCard({super.key, required this.order, required this.onTap});

  final OnlineOrderData order;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final when = DateFormat('d MMM, h:mm a').format(order.placedAt);
    return Padding(
      padding: EdgeInsets.only(bottom: context.getRSize(10)),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: OnlineOrderKeys.card(order.id),
          borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
          onTap: onTap,
          child: Ink(
            decoration: AppDecorations.card(
              context,
              radius: AppSpacing.borderRadiusL,
            ),
            padding: EdgeInsets.all(context.getRSize(14)),
            child: Row(
              children: [
                IconTile(
                  icon: AppIcons.public,
                  tone: order.status == 'new'
                      ? IconTileTone.warning
                      : IconTileTone.neutral,
                  size: 40,
                ),
                SizedBox(width: context.getRSize(12)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        order.shopperName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.textTheme.titleSmall,
                      ),
                      SizedBox(height: context.getRSize(2)),
                      Text(
                        '${order.reference} · $when',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.textTheme.bodySmall?.copyWith(color: muted),
                      ),
                      Text(
                        order.deliveryLga,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.textTheme.bodySmall?.copyWith(color: muted),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: context.getRSize(8)),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    OnlineOrderStatusPill(status: order.status),
                    SizedBox(height: context.getRSize(6)),
                    Text(
                      _money(order.estimatedTotalKobo),
                      style: t.textTheme.titleSmall,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A titled card section of the Online Order detail.
class OnlineOrderSection extends StatelessWidget {
  const OnlineOrderSection({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: context.getRSize(12)),
      child: DecoratedBox(
        decoration: AppDecorations.card(
          context,
          radius: AppSpacing.borderRadiusL,
        ),
        child: Padding(
          padding: EdgeInsets.all(context.getRSize(14)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: t.textTheme.titleSmall),
              SizedBox(height: context.getRSize(8)),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// An icon + text row inside an [OnlineOrderSection].
class OnlineOrderInfoRow extends StatelessWidget {
  const OnlineOrderInfoRow({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(4)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(icon, size: context.getRSize(18), color: muted),
          SizedBox(width: context.getRSize(10)),
          Expanded(child: Text(text, style: t.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// One line of the order: name, quantity × price, line total.
class OnlineOrderLineRow extends StatelessWidget {
  const OnlineOrderLineRow({super.key, required this.line});

  final OnlineOrderLineData line;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final unit = line.unit == null ? '' : ' ${line.unit}';
    final qty = line.acceptedQty ?? line.requestedQty;
    final changed = qty != line.requestedQty;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(4)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(line.productName, style: t.textTheme.bodyMedium),
                Text(
                  qty == 0
                      ? 'Removed (asked for ${line.requestedQty}$unit)'
                      : '$qty$unit × ${_money(line.unitPriceKobo)}'
                            '${changed ? ' (asked for ${line.requestedQty})' : ''}',
                  style: t.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ],
            ),
          ),
          SizedBox(width: context.getRSize(8)),
          Text(
            _money(line.unitPriceKobo * qty),
            style: t.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

/// One line while the order is being accepted (#428): staff can lower the
/// quantity or remove the line, never raise it above what was asked. A price
/// flag shows when today's retail price differs from the one the Shopper saw.
class OnlineOrderEditableLineRow extends StatelessWidget {
  const OnlineOrderEditableLineRow({
    super.key,
    required this.line,
    required this.quantity,
    required this.currentPriceKobo,
    required this.onChanged,
  });

  final OnlineOrderLineData line;

  /// The quantity that will be accepted (0 = removed).
  final int quantity;

  /// Today's retail price, or null when the product is not found here.
  final int? currentPriceKobo;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final unit = line.unit == null ? '' : ' ${line.unit}';
    final removed = quantity == 0;
    final price = currentPriceKobo;
    final priceChanged = price != null && price != line.unitPriceKobo;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(4)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      line.productName,
                      style: t.textTheme.bodyMedium?.copyWith(
                        decoration: removed ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    Text(
                      removed
                          ? 'Removed (asked for ${line.requestedQty}$unit)'
                          : '$quantity$unit × ${_money(line.unitPriceKobo)}'
                                '${quantity < line.requestedQty ? ' (asked for ${line.requestedQty})' : ''}',
                      style: t.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: OnlineOrderKeys.lineLower(line.id),
                tooltip: 'Lower quantity',
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: quantity > 0 ? () => onChanged(quantity - 1) : null,
              ),
              IconButton(
                key: OnlineOrderKeys.lineRemove(line.id),
                tooltip: removed ? 'Put back' : 'Remove',
                icon: Icon(
                  removed ? Icons.undo : Icons.delete_outline,
                ),
                onPressed: () =>
                    onChanged(removed ? line.requestedQty : 0),
              ),
            ],
          ),
          if (priceChanged)
            Padding(
              padding: EdgeInsets.only(top: context.getRSize(2)),
              child: Text(
                key: OnlineOrderKeys.linePriceFlag(line.id),
                'Price changed: now ${_money(price)}, customer saw '
                '${_money(line.unitPriceKobo)}',
                style: t.textTheme.bodySmall?.copyWith(
                  color: t.colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The estimated total row under the lines.
class OnlineOrderTotalRow extends StatelessWidget {
  const OnlineOrderTotalRow({super.key, required this.totalKobo});

  final int totalKobo;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(top: context.getRSize(8)),
      child: Row(
        children: [
          Expanded(
            child: Text('Estimated total', style: t.textTheme.titleSmall),
          ),
          Text(_money(totalKobo), style: t.textTheme.titleSmall),
        ],
      ),
    );
  }
}
