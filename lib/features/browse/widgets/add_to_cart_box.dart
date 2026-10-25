import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/storefront/shopper_cart.dart';
import 'package:reebaplus_pos/core/storefront/storefront_models.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/browse/widgets/age_confirmation_dialog.dart';
import 'package:reebaplus_pos/features/browse/widgets/quantity_entry.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// Quantity + "Add to cart" on the product sheet (#426). The stepper moves by
/// the product's order step and stays inside its min/max (#473); a quantity
/// above a shown "Only N left" is refused with "The store can't supply that
/// many". The cloud re-checks everything (real stock too) at Place order.
class AddToCartBox extends ConsumerStatefulWidget {
  const AddToCartBox({super.key, required this.card, required this.onAdded});

  final StorefrontCard card;
  final VoidCallback onAdded;

  @override
  ConsumerState<AddToCartBox> createState() => _AddToCartBoxState();
}

class _AddToCartBoxState extends ConsumerState<AddToCartBox> {
  late final ShopperCartLine _probe = ShopperCartLine.fromCard(widget.card, 1);
  late int _qty = _probe.rule.smallestAllowed ?? _probe.minOrderQty;
  String? _error;
  bool _busy = false;

  int? get _max {
    final ruleMax = _probe.maxOrderQty;
    final left = _probe.onlyLeft;
    if (left == null) return ruleMax;
    return ruleMax == null || left < ruleMax ? left : ruleMax;
  }

  Future<void> _type() async {
    final picked = await showQuantityDialog(
      context,
      initial: _qty,
      validate: _probe.problemWith,
      hint: _probe.ruleText,
    );
    if (picked != null && mounted) {
      setState(() {
        _qty = picked;
        _error = null;
      });
    }
  }

  Future<void> _add() async {
    // An 18+ item needs the age answer first (#479); "Not now" keeps it out.
    if (widget.card.ageRestricted &&
        !await ensureShopperAgeConfirmed(context, ref)) {
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    final problem = await ref
        .read(shopperCartProvider.notifier)
        .add(widget.card, _qty);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = problem;
    });
    if (problem == null) widget.onAdded();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    if (!widget.card.orderable) return const SizedBox.shrink();
    final inCart = ref
        .watch(shopperCartProvider)
        .valueOrNull
        ?.lineFor(widget.card.storeId, widget.card.productId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (inCart != null)
          Padding(
            padding: EdgeInsets.only(bottom: context.getRSize(6)),
            child: Text(
              '${inCart.quantity} already in your cart',
              key: const Key('shopper-in-cart'),
              style: context
                  .semiBoldStyle(13)
                  .copyWith(color: t.colorScheme.primary),
            ),
          ),
        Wrap(
          spacing: context.getRSize(12),
          runSpacing: context.getRSize(8),
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            QuantityStepper(
              quantity: _qty,
              step: _probe.orderStep,
              min: _probe.rule.smallestAllowed ?? _probe.minOrderQty,
              max: _max,
              onChanged: (q) => setState(() {
                _qty = q;
                _error = null;
              }),
              onType: _type,
            ),
            AppButton(
              key: const Key('shopper-add-to-cart'),
              text: 'Add to cart',
              icon: AppIcons.cartAdd,
              isFullWidth: false,
              isLoading: _busy,
              onPressed: _busy ? null : _add,
            ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: EdgeInsets.only(top: context.getRSize(6)),
            child: Text(
              _error!,
              key: const Key('shopper-add-error'),
              style: context
                  .semiBoldStyle(13)
                  .copyWith(color: t.colorScheme.error),
            ),
          ),
      ],
    );
  }
}
