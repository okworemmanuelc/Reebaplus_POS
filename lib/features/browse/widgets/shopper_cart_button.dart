import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/storefront/shopper_cart.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/features/browse/screens/shopper_cart_screen.dart';
import 'package:reebaplus_pos/features/browse/widgets/shopper_parts.dart';

/// The cart button for Browse top bars (#426), badged with the line count.
class ShopperCartButton extends ConsumerWidget {
  const ShopperCartButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(shopperCartProvider).valueOrNull?.lineCount ?? 0;
    return ShopperBarButton(
      key: const Key('browse-cart'),
      icon: AppIcons.cart,
      tooltip: 'Your cart',
      count: count,
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const ShopperCartScreen()),
      ),
    );
  }
}
