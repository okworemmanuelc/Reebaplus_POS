import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/receiving/screens/receive_checkout_screen.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/features/receiving/widgets/edit_receive_item_modal.dart';
import 'package:reebaplus_pos/features/receiving/widgets/receive_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/cart_line.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/category_visual.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/tag_pill.dart';
import 'package:reebaplus_pos/core/utils/product_unit.dart';

/// The receiving cart (#394): the lines on this receipt, each a shared
/// [CartLine] without a stepper (tap opens the Edit sheet, swipe left
/// removes, as before), then "Invoice Total:" and "Continue (N items)".
/// Content caps at [kReceiveMaxContentWidth], centred; the bars span the
/// screen.
class ReceiveCartScreen extends ConsumerWidget {
  const ReceiveCartScreen({super.key});

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final f =
        Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Cart'),
        content: const Text(
          'Are you sure you want to remove all items from the cart?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Clear', style: TextStyle(color: f.danger)),
          ),
        ],
      ),
    );

    if (confirm == true && context.mounted) {
      ref.read(receiveCartProvider.notifier).clear();
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.watch(receiveCartProvider);
    final lineCount = cart.length;

    return DecoratedBox(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: ReceiveTopBar(
          height: receiveTopBarHeight(context),
          icon: AppIcons.cart,
          title: 'Receive Stock Cart',
          subtitle: '$lineCount ${lineCount == 1 ? 'item' : 'items'}',
          actions: [
            if (cart.isNotEmpty)
              ReceiveClearButton(onPressed: () => _confirmClear(context, ref)),
          ],
        ),
        body: cart.isEmpty
            ? const _EmptyReceiveCart()
            : LayoutBuilder(
                builder: (context, constraints) {
                  final side = receiveSidePadding(
                    context,
                    constraints.maxWidth,
                  );
                  // The footer stays pinned while there is room for it and a
                  // useful list (the Cart's measured rule, #385); on a
                  // sideways phone it scrolls at the end of the list.
                  final pinned = constraints.maxHeight >= context.getRSize(440);
                  final footer = _ReceiveCartFooter(
                    sidePadding: side,
                    pinned: pinned,
                  );
                  final list = ListView.separated(
                    key: ReceiveKeys.cartList,
                    padding: EdgeInsets.fromLTRB(
                      side,
                      context.getRSize(16),
                      side,
                      pinned
                          ? context.getRSize(16)
                          : context.getRSize(16) + context.deviceBottomPadding,
                    ),
                    itemCount: cart.length + (pinned ? 0 : 1),
                    separatorBuilder: (_, __) =>
                        SizedBox(height: context.getRSize(12)),
                    itemBuilder: (context, index) {
                      if (index == cart.length) return footer;
                      return _ReceiveCartLineCard(line: cart[index]);
                    },
                  );
                  if (!pinned) return list;
                  return Column(
                    children: [
                      Expanded(child: list),
                      footer,
                    ],
                  );
                },
              ),
      ),
    );
  }
}

/// One line: category tile, name, "qty × cost", line total, the "Cost: ₦X"
/// tag, and "unit · Ret: ₦X • Whls: ₦Y". Swipe left removes it; tap edits.
class _ReceiveCartLineCard extends ConsumerWidget {
  const _ReceiveCartLineCard({required this.line});

  final ReceiveCartLine line;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final categories = ref.watch(allCategoriesProvider).value ?? const [];
    final categoryName = categories
        .where((c) => c.id == line.categoryId)
        .firstOrNull
        ?.name;
    final visual = categoryVisual(categoryName, f);
    final cost = formatCurrency(line.buyingPriceKobo / 100);
    final prices =
        'Ret: ${formatCurrency(line.retailKobo / 100)} • '
        'Whls: ${formatCurrency(line.wholesaleKobo / 100)}';
    // A unitless product (#108) shows no unit label — just its prices.
    final detail = (line.unit ?? '').isNotEmpty
        ? '${unitLabel(line.unit, crates: businessTracksCrates(ref.watch(currentBusinessProvider)))} · $prices'
        : prices;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    return Dismissible(
      key: ValueKey(line.productId),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: EdgeInsets.only(right: context.getRSize(20)),
        decoration: BoxDecoration(color: f.danger, borderRadius: radius),
        child: AppIcon(
          AppIcons.delete,
          color: f.onSolid,
          size: context.getRSize(22),
        ),
      ),
      onDismissed: (_) {
        ref.read(receiveCartProvider.notifier).remove(line.productId);
      },
      child: CartLine(
        key: receiveCartLineKey(line.productId),
        name: line.productName,
        icon: visual.icon,
        tileTint: visual.tint,
        tileIconColor: visual.iconColor,
        quantityLabel: '${line.qty}',
        unitPriceLabel: cost,
        totalLabel: formatCurrency(line.buyingPriceKobo * line.qty / 100),
        detail: detail,
        badges: [TagPill(label: 'Cost: $cost', dense: true)],
        onTap: () => EditReceiveItemModal.show(context, line),
      ),
    );
  }
}

/// "Invoice Total:" + the figure, and "Continue (N items)" to checkout.
/// Pinned under the list (Surface + hairline) or, on a short screen, the last
/// item of the list.
class _ReceiveCartFooter extends ConsumerWidget {
  const _ReceiveCartFooter({required this.sidePadding, required this.pinned});

  final double sidePadding;
  final bool pinned;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(receiveCartProvider);
    final notifier = ref.read(receiveCartProvider.notifier);
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Invoice Total:',
                style: context.semiBoldStyle(16).copyWith(color: muted),
              ),
            ),
            Text(
              formatCurrency(notifier.invoiceTotalKobo / 100),
              style: context
                  .extraBoldStyle(24)
                  .copyWith(color: t.colorScheme.primary),
            ),
          ],
        ),
        SizedBox(height: context.getRSize(16)),
        AppButton(
          key: ReceiveKeys.continueButton,
          text: 'Continue (${notifier.totalUnits} items)',
          isFullWidth: true,
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ReceiveCheckoutScreen()),
            );
          },
        ),
      ],
    );
    if (!pinned) {
      return Padding(
        key: ReceiveKeys.cartFooter,
        padding: EdgeInsets.only(top: context.getRSize(8)),
        child: content,
      );
    }
    return Container(
      key: ReceiveKeys.cartFooter,
      padding: EdgeInsets.fromLTRB(
        sidePadding,
        context.getRSize(16),
        sidePadding,
        context.getRSize(16) + context.deviceBottomPadding,
      ),
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        border: Border(top: BorderSide(color: t.dividerColor)),
      ),
      child: content,
    );
  }
}

class _EmptyReceiveCart extends StatelessWidget {
  const _EmptyReceiveCart();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(context.getRSize(24)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const IconTile(
              icon: AppIcons.box,
              tone: IconTileTone.neutral,
              size: 64,
            ),
            SizedBox(height: context.getRSize(20)),
            Text(
              'Your receive cart is empty',
              textAlign: TextAlign.center,
              style: context
                  .boldStyle(18)
                  .copyWith(color: t.colorScheme.onSurface),
            ),
            SizedBox(height: context.getRSize(8)),
            Text(
              'Tap products from the grid to add them.',
              textAlign: TextAlign.center,
              style: context.regularStyle(14).copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}
