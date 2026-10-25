import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/online_order_providers.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/orders/screens/online_order_detail_screen.dart';
import 'package:reebaplus_pos/features/orders/widgets/online_order_parts.dart';
import 'package:reebaplus_pos/features/orders/widgets/orders_parts.dart';
import 'package:reebaplus_pos/shared/widgets/slide_route.dart';

/// The Orders screen's Online tab body (#427), as one sliver: a summary strip
/// (New / Accepted) and the active store scope's Online Orders, newest first.
/// Shown only with `online_orders.view` (the screen hides the tab otherwise).
class OnlineOrdersTabSliver extends ConsumerWidget {
  const OnlineOrdersTabSliver({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = ref.watch(scopedOnlineOrdersProvider);
    final newCount = ref.watch(newOnlineOrderCountProvider);
    final accepted = orders.where((o) => o.status == 'accepted').length;
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;

    Widget capped(Widget child) => LayoutBuilder(
      builder: (context, c) => Padding(
        padding: EdgeInsets.symmetric(
          horizontal: ordersCapPadding(c.maxWidth, context.getRSize(16)),
        ),
        child: child,
      ),
    );

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: context.getRSize(16)),
            child: capped(
              OrdersSummaryStrip(
                stats: [
                  (
                    label: 'New',
                    value: '$newCount',
                    color: t.colorScheme.primary,
                  ),
                  (label: 'Accepted', value: '$accepted', color: null),
                  (label: 'All', value: '${orders.length}', color: muted),
                ],
              ),
            ),
          ),
        ),
        if (orders.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: context.getRSize(40)),
              child: const Center(
                child: OrdersEmptyState(
                  icon: AppIcons.public,
                  text: 'No online orders yet',
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: EdgeInsets.only(
              top: context.getRSize(12),
              bottom: context.getRSize(16) + context.deviceBottomPadding,
            ),
            sliver: SliverList.builder(
              itemCount: orders.length,
              itemBuilder: (context, i) => capped(
                OnlineOrderCard(
                  order: orders[i],
                  onTap: () => Navigator.of(context).push(
                    slideLeftRoute(
                      OnlineOrderDetailScreen(onlineOrderId: orders[i].id),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
