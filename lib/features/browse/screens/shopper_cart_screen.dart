import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/storefront/shopper_cart.dart';
import 'package:reebaplus_pos/core/storefront/shopper_models.dart';
import 'package:reebaplus_pos/core/storefront/shopper_providers.dart';
import 'package:reebaplus_pos/core/storefront/shopper_service.dart';
import 'package:reebaplus_pos/core/storefront/shopper_session.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/browse/screens/place_order_screen.dart';
import 'package:reebaplus_pos/features/browse/screens/shopper_details_screen.dart';
import 'package:reebaplus_pos/features/browse/screens/shopper_sign_in_screen.dart';
import 'package:reebaplus_pos/features/browse/widgets/browse_parts.dart';
import 'package:reebaplus_pos/features/browse/widgets/quantity_entry.dart';
import 'package:reebaplus_pos/features/browse/widgets/shopper_parts.dart';
import 'package:reebaplus_pos/features/browse/widgets/shopper_texts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// The Shopper's one cart across shops (#426): lines grouped by shop, each
/// shop with its own subtotal (never a grand total — shops may use different
/// currencies). Lives on the phone; survives restarts and sign-in.
///
/// **Place order** asks for sign-in (email + code) only now, then the
/// first-time details, then opens [PlaceOrderScreen].
class ShopperCartScreen extends ConsumerWidget {
  const ShopperCartScreen({super.key});

  Future<void> _placeOrder(BuildContext context, WidgetRef ref) async {
    final nav = Navigator.of(context);
    if (!ref.read(shopperSessionProvider).isSignedIn) {
      final signedIn = await nav.push<bool>(
        MaterialPageRoute(builder: (_) => const ShopperSignInScreen()),
      );
      if (signedIn != true) return;
    }
    ShopperProfile? profile;
    try {
      profile = await ref.read(shopperServiceProvider).profile();
    } on ShopperException catch (e) {
      if (context.mounted) {
        AppNotification.showError(context, shopperFailureText(e.failure));
      }
      return;
    }
    profile ??= await nav.push<ShopperProfile>(
      MaterialPageRoute(builder: (_) => const ShopperDetailsScreen()),
    );
    if (profile == null) return;
    await nav.push<void>(
      MaterialPageRoute(builder: (_) => PlaceOrderScreen(profile: profile!)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart =
        ref.watch(shopperCartProvider).valueOrNull ?? const ShopperCart();
    final groups = cart.groups;
    return ShopperPage(
      icon: AppIcons.cart,
      title: 'Your cart',
      subtitle: groups.isEmpty
          ? null
          : groups.length == 1
          ? '1 shop'
          : '${groups.length} shops',
      bottom: cart.isEmpty
          ? null
          : AppButton(
              key: const Key('shopper-cart-place-order'),
              text: groups.length == 1
                  ? 'Place order'
                  : 'Place ${groups.length} orders',
              icon: AppIcons.cartCheckout,
              onPressed: () => _placeOrder(context, ref),
            ),
      body: cart.isEmpty
          ? BrowseMessage(
              key: const Key('shopper-cart-empty'),
              icon: AppIcons.cart,
              title: 'Your cart is empty',
              text: 'Add products from any shop, then place your order here.',
              actionLabel: 'Keep browsing',
              onAction: () => Navigator.maybePop(context),
            )
          : ListView(
              key: const Key('shopper-cart-list'),
              padding: EdgeInsets.all(context.getRSize(16)),
              children: [
                if (groups.length > 1)
                  Padding(
                    padding: EdgeInsets.only(bottom: context.getRSize(10)),
                    child: Text(
                      'Each shop gets its own order with its own reference.',
                      style: context
                          .regularStyle(13)
                          .copyWith(
                            color: Theme.of(context).textTheme.bodySmall?.color,
                          ),
                    ),
                  ),
                for (final g in groups) CartGroupCard(group: g),
              ],
            ),
    );
  }
}

/// One shop's lines, editable, with its subtotal.
class CartGroupCard extends ConsumerWidget {
  const CartGroupCard({super.key, required this.group});

  final ShopperCartGroup group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final notifier = ref.read(shopperCartProvider.notifier);
    Future<void> set(ShopperCartLine line, int qty) async {
      final problem = await notifier.setQuantity(
        line.storeId,
        line.productId,
        qty,
      );
      if (problem != null && context.mounted) {
        AppNotification.showError(context, problem);
      }
    }

    return ShopperSection(
      key: ValueKey('shopper-cart-group-${group.storeId}'),
      title: group.sellerLabel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final line in group.lines) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        line.name,
                        style: context
                            .semiBoldStyle(14)
                            .copyWith(color: t.colorScheme.onSurface),
                      ),
                      Text(
                        '${formatCurrencyIn(line.priceKobo / 100, line.currency)}'
                        '${line.unit == null ? '' : ' per ${line.unit}'}',
                        style: context
                            .regularStyle(12)
                            .copyWith(color: t.textTheme.bodySmall?.color),
                      ),
                      if (line.ruleText != null)
                        Text(
                          line.ruleText!,
                          style: context
                              .regularStyle(12)
                              .copyWith(color: t.textTheme.bodySmall?.color),
                        ),
                    ],
                  ),
                ),
                SizedBox.square(
                  dimension: kMinInteractiveDimension,
                  child: IconButton(
                    tooltip: 'Remove',
                    onPressed: () =>
                        notifier.remove(line.storeId, line.productId),
                    icon: AppIcon(
                      AppIcons.delete,
                      size: context.getRSize(20),
                      color: t.colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: context.getRSize(12),
              runSpacing: context.getRSize(6),
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.spaceBetween,
              children: [
                QuantityStepper(
                  key: ValueKey('shopper-cart-qty-${line.productId}'),
                  quantity: line.quantity,
                  step: line.orderStep,
                  min: line.rule.smallestAllowed ?? line.minOrderQty,
                  max: line.onlyLeft == null
                      ? line.maxOrderQty
                      : (line.maxOrderQty == null ||
                                line.onlyLeft! < line.maxOrderQty!
                            ? line.onlyLeft
                            : line.maxOrderQty),
                  onChanged: (q) => set(line, q),
                  onType: () async {
                    final picked = await showQuantityDialog(
                      context,
                      initial: line.quantity,
                      validate: line.problemWith,
                      hint: line.ruleText,
                    );
                    if (picked != null) await set(line, picked);
                  },
                ),
                Text(
                  formatCurrencyIn(line.lineTotalKobo / 100, line.currency),
                  style: context
                      .boldStyle(14)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
              ],
            ),
            Divider(height: context.getRSize(20)),
          ],
          Row(
            children: [
              Expanded(
                child: Text(
                  'Estimated subtotal',
                  style: context
                      .semiBoldStyle(14)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
              ),
              Text(
                formatCurrencyIn(group.subtotalKobo / 100, group.currency),
                key: ValueKey('shopper-cart-subtotal-${group.storeId}'),
                style: context
                    .boldStyle(16)
                    .copyWith(color: t.colorScheme.primary),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
