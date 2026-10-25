import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/storefront/shopper_models.dart';
import 'package:reebaplus_pos/core/storefront/shopper_providers.dart';
import 'package:reebaplus_pos/core/storefront/shopper_service.dart';
import 'package:reebaplus_pos/core/storefront/shopper_session.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/browse/screens/shopper_sign_in_screen.dart';
import 'package:reebaplus_pos/features/browse/widgets/browse_parts.dart';
import 'package:reebaplus_pos/features/browse/widgets/shopper_parts.dart';
import 'package:reebaplus_pos/features/browse/widgets/shopper_texts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// My Orders (#426, stories 31–33, 39): the Shopper's own Online Orders —
/// shop, reference, items, estimated total and a plain-word status. Cancel
/// only while the order is still Placed (the shop has not answered).
class MyOrdersScreen extends ConsumerWidget {
  const MyOrdersScreen({super.key});

  Future<void> _cancel(
    BuildContext context,
    WidgetRef ref,
    ShopperOrder order,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel this order?'),
        content: Text(
          '${order.sellerLabel} · ${order.reference}. The shop will see it '
          'was cancelled.',
        ),
        actions: [
          AppButton(
            text: 'Keep it',
            variant: AppButtonVariant.ghost,
            isFullWidth: false,
            onPressed: () => Navigator.of(dialogContext).pop(false),
          ),
          AppButton(
            key: const Key('shopper-cancel-confirm'),
            text: 'Cancel order',
            variant: AppButtonVariant.danger,
            isFullWidth: false,
            onPressed: () => Navigator.of(dialogContext).pop(true),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(shopperServiceProvider).cancelOrder(order.id);
      if (context.mounted) {
        AppNotification.showSuccess(context, 'Order cancelled');
      }
    } on ShopperException catch (e) {
      if (context.mounted) {
        AppNotification.showError(context, shopperFailureText(e.failure));
      }
    }
    ref.invalidate(shopperOrdersProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(shopperSessionProvider);
    final orders = ref.watch(shopperOrdersProvider);
    final Widget body;
    if (!session.isSignedIn) {
      body = BrowseMessage(
        key: const Key('my-orders-signed-out'),
        icon: AppIcons.orders,
        title: 'Sign in to see your orders',
        actionLabel: 'Sign in',
        onAction: () => Navigator.of(context).push(
          MaterialPageRoute<bool>(builder: (_) => const ShopperSignInScreen()),
        ),
      );
    } else {
      body = switch (orders) {
        AsyncData(:final value) when value.isEmpty => const BrowseMessage(
          key: Key('my-orders-empty'),
          icon: AppIcons.orders,
          title: 'No orders yet',
          text: 'Orders you place appear here.',
        ),
        AsyncData(:final value) => ListView(
          key: const Key('my-orders-list'),
          padding: EdgeInsets.fromLTRB(
            context.getRSize(16),
            context.getRSize(16),
            context.getRSize(16),
            context.getRSize(16) + context.deviceBottomPadding,
          ),
          children: [
            for (final o in value)
              ShopperOrderCard(
                order: o,
                onCancel: o.canCancel ? () => _cancel(context, ref, o) : null,
              ),
          ],
        ),
        AsyncError(:final error) => BrowseMessage(
          key: const Key('my-orders-failed'),
          icon: AppIcons.cloudOff,
          tone: IconTileTone.warning,
          title: error is ShopperException
              ? shopperFailureText(error.failure)
              : "Couldn't load your orders",
          actionLabel: 'Try again',
          onAction: () => ref.invalidate(shopperOrdersProvider),
        ),
        _ => const Center(child: CircularProgressIndicator()),
      };
    }
    return ShopperPage(
      icon: AppIcons.orders,
      title: 'My orders',
      actions: [
        if (session.isSignedIn)
          ShopperBarButton(
            icon: AppIcons.refresh,
            tooltip: 'Refresh',
            onPressed: () => ref.invalidate(shopperOrdersProvider),
          ),
      ],
      body: body,
    );
  }
}

/// One order in My Orders.
class ShopperOrderCard extends StatelessWidget {
  const ShopperOrderCard({super.key, required this.order, this.onCancel});

  final ShopperOrder order;
  final VoidCallback? onCancel;

  TagPillTone get _tone => switch (order.status) {
    OnlineOrderStatus.placed => TagPillTone.info,
    OnlineOrderStatus.accepted ||
    OnlineOrderStatus.sentOut => TagPillTone.green,
    OnlineOrderStatus.declined ||
    OnlineOrderStatus.cancelledByShop ||
    OnlineOrderStatus.expired => TagPillTone.danger,
    OnlineOrderStatus.cancelled => TagPillTone.neutral,
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final reason = order.declineReason ?? order.cancelReason;
    return ShopperSection(
      key: ValueKey('my-order-${order.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      order.sellerLabel,
                      style: context
                          .boldStyle(15)
                          .copyWith(color: t.colorScheme.onSurface),
                    ),
                    Text(
                      'Ref ${order.reference}',
                      style: context.monoStyle.copyWith(color: muted),
                    ),
                  ],
                ),
              ),
              TagPill(label: order.statusText, tone: _tone),
            ],
          ),
          SizedBox(height: context.getRSize(8)),
          for (final l in order.lines)
            Text(
              l.isChanged
                  ? '${l.acceptedQty} × ${l.name} (you asked for ${l.requestedQty})'
                  : '${l.requestedQty} × ${l.name}',
              style: context
                  .regularStyle(13)
                  .copyWith(color: t.colorScheme.onSurface),
            ),
          if (reason != null && reason.trim().isNotEmpty) ...[
            SizedBox(height: context.getRSize(6)),
            Text(
              'Reason: $reason',
              style: context.regularStyle(13).copyWith(color: muted),
            ),
          ],
          SizedBox(height: context.getRSize(8)),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Estimated total '
                  '${formatCurrencyIn(order.totalKobo / 100, order.currency)}',
                  style: context
                      .semiBoldStyle(14)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
              ),
              if (onCancel != null)
                AppButton(
                  key: ValueKey('my-order-cancel-${order.id}'),
                  text: 'Cancel',
                  variant: AppButtonVariant.ghost,
                  isFullWidth: false,
                  onPressed: onCancel,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
