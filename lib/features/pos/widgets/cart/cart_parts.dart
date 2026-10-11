import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/frame/cart_panel.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/fly_to_cart.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/screen_header.dart';

// The Cart screen's local parts (#385; `tablet-cart-panel-*.png`,
// `wide-pos-cart-*.png`). Plain data and callbacks only — every figure shown
// here is computed by `CartScreen` and passed in already final. Nothing in
// this file does arithmetic on money.
//
// Shared-part candidates: [CartOutlineButton] (an outlined primary button that
// never truncates its label) and [CartClearButton] (the red-tint pill).

/// Keys the Cart tests find the parts by.
abstract final class CartKeys {
  static const topBar = Key('cart-top-bar');
  static const clear = Key('cart-clear');
  static const customerCard = Key('cart-customer-card');
  static const change = Key('cart-change-customer');
  static const subtotal = Key('cart-subtotal');
  static const crateValueMissing = Key('cart-crate-value-missing');
  static const emptyCrates = Key('cart-empty-crates');
  static const requiredDeposit = Key('cart-required-deposit');
  static const discount = Key('cart-discount');
  static const footer = Key('cart-footer');
  static const total = Key('cart-total');
  static const save = Key('cart-save');
  static const recall = Key('cart-recall');
  static const checkout = Key('cart-checkout');
}

/// Height of the Cart top bar: room for the 44 icon tile (or a 48dp control)
/// plus 8 above and below, never less than the app's bar height.
double cartTopBarHeight(BuildContext context) => math.max(
  kToolbarHeight + 12,
  math.max(context.getRSize(44), kMinInteractiveDimension) +
      context.getRSize(16),
);

/// The Cart's solid top bar (as Home / CEO Settings): the shared
/// [ScreenHeader] with the primary cart tile, "Cart" and "N items", then the
/// bell (Cart tab only), the red Clear pill (when the cart has lines) and the
/// panel's ✕ (in the frame's cart panel only).
///
/// Nothing in the row may squeeze the title: the actions are sized to their
/// content and the title is a plain one-line [Text] (no `FittedBox`, which is
/// what shrank it to a dot in the tablet panel before #385).
class CartTopBar extends StatelessWidget implements PreferredSizeWidget {
  const CartTopBar({
    super.key,
    required this.height,
    required this.subtitle,
    this.leading,
    this.bell,
    this.onClear,
    this.onClose,
  });

  final double height;
  final String subtitle;

  /// The menu button (under 600dp), a 48dp target.
  final Widget? leading;

  /// The live notification bell; null in the cart panel, where POS's own
  /// header beside it already carries one.
  final Widget? bell;

  /// Clears the cart; null hides the pill (an empty cart).
  final VoidCallback? onClear;

  /// Closes the cart panel; set only when hosted in it.
  final VoidCallback? onClose;

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final topBarShadow =
        t.extension<AppSchemeColors>()?.topBarShadow ?? Colors.transparent;
    final gap = context.getRSize(8);
    Widget header = ScreenHeader(
      icon: AppIcons.cart,
      title: 'Cart',
      subtitle: subtitle,
      leading: leading,
      actions: [
        if (bell != null) ...[SizedBox(width: gap), bell!],
        if (onClear != null) ...[
          SizedBox(width: gap),
          CartClearButton(onPressed: onClear!),
        ],
        if (onClose != null) ...[
          SizedBox(width: gap),
          CartPanelCloseButton(onPressed: onClose!),
        ],
      ],
    );
    // In the frame's cart panel the header is where fly-to-cart lands
    // (#352 PR 3), ahead of the rail's Cart item: on the icon tile at the
    // header's left edge.
    if (onClose != null) {
      header = FlyTarget(
        id: FlyTargetId.cart,
        priority: 1,
        anchor: Alignment.centerLeft,
        anchorOffset: Offset(context.getRSize(22), 0),
        child: header,
      );
    }
    return AppBar(
      key: CartKeys.topBar,
      automaticallyImplyLeading: false,
      toolbarHeight: height,
      titleSpacing: context.getRSize(leading == null ? 16 : 8),
      centerTitle: false,
      backgroundColor: t.colorScheme.surface,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      flexibleSpace: Container(
        decoration: BoxDecoration(
          color: t.colorScheme.surface,
          border: Border(bottom: BorderSide(color: t.dividerColor, width: 1)),
          boxShadow: [
            BoxShadow(
              color: topBarShadow,
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
      ),
      title: Padding(
        padding: EdgeInsets.only(right: context.getRSize(12)),
        child: header,
      ),
    );
  }
}

/// The red-tint "Clear" pill with a bin icon (`AppFixedColors.danger*`). A
/// 48dp tall tap target around a smaller visible pill.
class CartClearButton extends StatelessWidget {
  const CartClearButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final f =
        Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusM);
    return Semantics(
      button: true,
      child: InkWell(
        key: CartKeys.clear,
        onTap: onPressed,
        borderRadius: radius,
        child: SizedBox(
          height: kMinInteractiveDimension,
          child: Center(
            child: Container(
              height: math.min(context.getRSize(40), kMinInteractiveDimension),
              padding: EdgeInsets.symmetric(horizontal: context.getRSize(12)),
              decoration: BoxDecoration(
                color: f.dangerTint,
                borderRadius: radius,
                border: Border.all(color: f.dangerOutline),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIcon(
                    AppIcons.delete,
                    size: context.getRSize(18),
                    color: f.danger,
                  ),
                  SizedBox(width: context.getRSize(6)),
                  Text(
                    'Clear',
                    maxLines: 1,
                    style: context.boldStyle(14).copyWith(color: f.danger),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The customer card: person tile, the customer's name ("Walk-in Customer"
/// when none), the balance line in [balanceColor], and Change.
///
/// The name wraps to a second line rather than being cut short.
class CartCustomerCard extends StatelessWidget {
  const CartCustomerCard({
    super.key,
    required this.name,
    required this.balanceLabel,
    required this.balanceColor,
    required this.onChange,
  });

  final String name;
  final String balanceLabel;
  final Color balanceColor;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final surface2 =
        t.inputDecorationTheme.fillColor ?? t.colorScheme.surfaceContainerHigh;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusM);
    return DecoratedBox(
      key: CartKeys.customerCard,
      decoration: AppDecorations.card(context),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(12)),
        child: Row(
          children: [
            const IconTile(icon: AppIcons.user, size: 40),
            SizedBox(width: context.getRSize(10)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context
                        .boldStyle(15)
                        .copyWith(color: t.colorScheme.onSurface),
                  ),
                  Text(
                    balanceLabel,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context
                        .semiBoldStyle(12)
                        .copyWith(color: balanceColor),
                  ),
                ],
              ),
            ),
            SizedBox(width: context.getRSize(6)),
            Semantics(
              button: true,
              child: InkWell(
                key: CartKeys.change,
                onTap: onChange,
                borderRadius: radius,
                child: SizedBox(
                  height: kMinInteractiveDimension,
                  child: Center(
                    child: Container(
                      height: math.min(
                        context.getRSize(40),
                        kMinInteractiveDimension,
                      ),
                      padding: EdgeInsets.symmetric(
                        horizontal: context.getRSize(12),
                      ),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: surface2,
                        borderRadius: radius,
                        border: Border.all(color: t.dividerColor),
                      ),
                      child: Text(
                        'Change',
                        maxLines: 1,
                        style: context
                            .boldStyle(13)
                            .copyWith(color: t.colorScheme.onSurface),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small tag on a cart line ("Custom price", "−10%").
class CartLineBadge extends StatelessWidget {
  const CartLineBadge({
    super.key,
    required this.label,
    required this.color,
    required this.fill,
  });

  final String label;
  final Color color;
  final Color fill;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(8),
        vertical: context.getRSize(2),
      ),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusS),
      ),
      child: Text(
        label,
        maxLines: 1,
        style: context.boldStyle(11).copyWith(color: color),
      ),
    );
  }
}

/// "Subtotal ₦33,000": a muted label and a bold figure, outside any card.
class CartSubtotalRow extends StatelessWidget {
  const CartSubtotalRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Padding(
      key: CartKeys.subtotal,
      padding: EdgeInsets.symmetric(horizontal: context.getRSize(4)),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: context.semiBoldStyle(14).copyWith(color: muted),
            ),
          ),
          Text(
            value,
            maxLines: 1,
            style: context
                .boldStyle(15)
                .copyWith(color: t.colorScheme.onSurface),
          ),
        ],
      ),
    );
  }
}

/// The amber "No crate value set" card: names the crate-tracked items whose
/// brand has no crate value, so somebody can go and fix the product.
///
/// Informational, not a blocker: the sale still completes and the empties are
/// still tracked as owed. What is wrong is the MONEY on them — an unconfigured
/// brand values every crate at ₦0, on this order and on the customer's crate
/// balance — and that is invisible without this.
class CrateValueMissingCard extends StatelessWidget {
  const CrateValueMissingCard({super.key, required this.productNames});

  /// Deduplicated, sorted product names. Never empty (the caller gates on it).
  final List<String> productNames;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final isOne = productNames.length == 1;
    return Container(
      key: CartKeys.crateValueMissing,
      width: double.infinity,
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: BoxDecoration(
        color: f.warningTint,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
        border: Border.all(color: f.warningOutline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(
            AppIcons.warning,
            filled: true,
            size: context.getRSize(20),
            color: f.warning,
          ),
          SizedBox(width: context.getRSize(10)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isOne
                      ? 'No crate value set for this item'
                      : 'No crate value set for these items',
                  style: context
                      .boldStyle(14)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
                SizedBox(height: context.getRSize(4)),
                Text(
                  productNames.join(', '),
                  style: context.boldStyle(13).copyWith(color: f.warning),
                ),
                SizedBox(height: context.getRSize(4)),
                Text(
                  isOne
                      ? 'Its empty crates are worth nothing until a crate value '
                            'is set on the product. You can still complete this '
                            'sale.'
                      : 'Their empty crates are worth nothing until a crate '
                            'value is set on each product. You can still '
                            'complete this sale.',
                  style: context.regularStyle(12).copyWith(color: muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One brand's crates on the Empty Crates card, already computed by the cart.
typedef CartCrateRow = ({
  String label,
  Color color,
  String qtyLabel,
  String amountLabel,
});

/// The Empty Crates card: crate tile, "Empty Crates", "N going out", then one
/// row per brand ("Star Lager ×2 ₦2,000") and the Required Deposit.
class EmptyCratesCard extends StatelessWidget {
  const EmptyCratesCard({
    super.key,
    required this.goingOutLabel,
    required this.rows,
    required this.requiredDepositLabel,
  });

  final String goingOutLabel;
  final List<CartCrateRow> rows;
  final String requiredDepositLabel;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final text = t.colorScheme.onSurface;
    return DecoratedBox(
      key: CartKeys.emptyCrates,
      decoration: AppDecorations.card(context),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(12)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const IconTile(
                  icon: AppIcons.crates,
                  tone: IconTileTone.warning,
                  size: 44,
                ),
                SizedBox(width: context.getRSize(12)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Empty Crates',
                        style: context.boldStyle(15).copyWith(color: text),
                      ),
                      Text(
                        goingOutLabel,
                        style: context.regularStyle(13).copyWith(color: muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            SizedBox(height: context.getRSize(10)),
            for (final row in rows)
              Padding(
                padding: EdgeInsets.only(bottom: context.getRSize(8)),
                child: Row(
                  children: [
                    Container(
                      width: context.getRSize(8),
                      height: context.getRSize(8),
                      decoration: BoxDecoration(
                        color: row.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    SizedBox(width: context.getRSize(8)),
                    Expanded(
                      child: Text(
                        '${row.label}  ×${row.qtyLabel}',
                        overflow: TextOverflow.ellipsis,
                        style: context.semiBoldStyle(13).copyWith(color: muted),
                      ),
                    ),
                    SizedBox(width: context.getRSize(8)),
                    Text(
                      row.amountLabel,
                      style: context.boldStyle(13).copyWith(color: text),
                    ),
                  ],
                ),
              ),
            Divider(height: 1, thickness: 1, color: t.dividerColor),
            SizedBox(height: context.getRSize(8)),
            Row(
              key: CartKeys.requiredDeposit,
              children: [
                Expanded(
                  child: Text(
                    'Required Deposit',
                    style: context.boldStyle(13).copyWith(color: text),
                  ),
                ),
                Text(
                  requiredDepositLabel,
                  style: context
                      .extraBoldStyle(14)
                      .copyWith(color: t.colorScheme.primary),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The Discount card: green tag tile, "Discount", the green amount off.
class CartDiscountRow extends StatelessWidget {
  const CartDiscountRow({super.key, required this.amountLabel});

  /// Already signed ("−₦500").
  final String amountLabel;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    return DecoratedBox(
      key: CartKeys.discount,
      decoration: AppDecorations.card(context),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(12)),
        child: Row(
          children: [
            const IconTile(
              icon: AppIcons.tag,
              tone: IconTileTone.green,
              size: 44,
            ),
            SizedBox(width: context.getRSize(12)),
            Expanded(
              child: Text(
                'Discount',
                style: context
                    .boldStyle(15)
                    .copyWith(color: t.colorScheme.onSurface),
              ),
            ),
            SizedBox(width: context.getRSize(8)),
            Text(
              amountLabel,
              maxLines: 1,
              style: context.boldStyle(15).copyWith(color: f.green),
            ),
          ],
        ),
      ),
    );
  }
}

/// The footer: "Total" with the big primary figure, Save Cart and Recall side
/// by side (stacked when the two labels cannot both fit whole), and the full-
/// width gradient Proceed to Checkout.
///
/// [pinned] draws it as a Surface strip with a hairline on top (under the
/// scrolling lines); otherwise it sits at the end of the scroll, on the page.
class CartFooter extends StatelessWidget {
  const CartFooter({
    super.key,
    required this.totalLabel,
    required this.onSave,
    required this.onRecall,
    required this.onCheckout,
    required this.bottomPadding,
    required this.pinned,
  });

  final String totalLabel;
  final VoidCallback onSave;
  final VoidCallback onRecall;
  final VoidCallback onCheckout;

  /// `deviceBottomPadding`, added below the checkout button.
  final double bottomPadding;
  final bool pinned;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final gutter = context.getRSize(16);
    final content = Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        context.getRSize(pinned ? 14 : 8),
        gutter,
        context.getRSize(16) + bottomPadding,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            key: CartKeys.total,
            children: [
              Text(
                'Total',
                style: context
                    .boldStyle(18)
                    .copyWith(color: t.colorScheme.onSurface),
              ),
              SizedBox(width: context.getRSize(12)),
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  // A figure, not a label: a very large total scales down
                  // rather than spilling out of the panel.
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      totalLabel,
                      maxLines: 1,
                      style: context
                          .extraBoldStyle(26)
                          .copyWith(color: t.colorScheme.primary),
                    ),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: context.getRSize(12)),
          _SaveRecallRow(onSave: onSave, onRecall: onRecall),
          SizedBox(height: context.getRSize(12)),
          AppButton(
            key: CartKeys.checkout,
            text: 'Proceed to Checkout',
            variant: AppButtonVariant.primary,
            icon: AppIcons.cartCheckout,
            onPressed: onCheckout,
          ),
        ],
      ),
    );
    if (!pinned) return KeyedSubtree(key: CartKeys.footer, child: content);
    return DecoratedBox(
      key: CartKeys.footer,
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        border: Border(top: BorderSide(color: t.dividerColor)),
      ),
      child: content,
    );
  }
}

/// Save Cart and Recall. Side by side when both labels fit whole in half the
/// width; otherwise one above the other — never cut short (#385: they were
/// truncated in the tablet panel at the 1.15 scale cap).
class _SaveRecallRow extends StatelessWidget {
  const _SaveRecallRow({required this.onSave, required this.onRecall});

  final VoidCallback onSave;
  final VoidCallback onRecall;

  @override
  Widget build(BuildContext context) {
    final gap = context.getRSize(12);
    final save = CartOutlineButton(
      key: CartKeys.save,
      label: 'Save Cart',
      icon: AppIcons.save,
      onPressed: onSave,
    );
    final recall = CartOutlineButton(
      key: CartKeys.recall,
      label: 'Recall',
      icon: AppIcons.history,
      onPressed: onRecall,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final half = (constraints.maxWidth - gap) / 2;
        final need = math.max(
          CartOutlineButton.widthNeeded(context, 'Save Cart'),
          CartOutlineButton.widthNeeded(context, 'Recall'),
        );
        if (need > half) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              save,
              SizedBox(height: gap),
              recall,
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: save),
            SizedBox(width: gap),
            Expanded(child: recall),
          ],
        );
      },
    );
  }
}

/// An outlined primary button (1.5 primary border, icon + Bold label) whose
/// label is never ellipsized: [widthNeeded] tells a parent how wide it must
/// be. A shared-part candidate.
class CartOutlineButton extends StatelessWidget {
  const CartOutlineButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  static const double _border = 1.5;

  static TextStyle _labelStyle(BuildContext context) => context
      .boldStyle(15)
      .copyWith(color: Theme.of(context).colorScheme.primary);

  static double _iconSize(BuildContext context) => context.getRSize(20);
  static double _iconGap(BuildContext context) => context.getRSize(8);
  static double _padding(BuildContext context) => context.getRSize(12);

  /// The width this button needs to draw [label] whole at the current text
  /// scale.
  static double widthNeeded(BuildContext context, String label) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: _labelStyle(context)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width +
        _iconSize(context) +
        _iconGap(context) +
        2 * _padding(context) +
        2 * _border +
        2; // rounding slack
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusM);
    return Semantics(
      button: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onPressed,
          borderRadius: radius,
          child: Container(
            height: math.max(kMinInteractiveDimension, context.getRSize(52)),
            padding: EdgeInsets.symmetric(horizontal: _padding(context)),
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: primary, width: _border),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AppIcon(icon, size: _iconSize(context), color: primary),
                SizedBox(width: _iconGap(context)),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: _labelStyle(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What the Cart shows with nothing in it: a pale cart tile, "Cart is empty",
/// and a Recall button so a saved cart can be restored before adding items.
///
/// Scrolls rather than clips (#255). Centred while there is room; on a short
/// phone — sideways, under the fixed customer card — the message grows past
/// the viewport and one scroll reaches Recall. `SliverFillRemaining` sizes to
/// the larger of the space left and the message itself.
class EmptyCartMessage extends StatelessWidget {
  const EmptyCartMessage({super.key, required this.onRecall});

  final VoidCallback onRecall;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return CustomScrollView(
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: context.getRSize(16)),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const IconTile(
                    icon: AppIcons.cartAdd,
                    tone: IconTileTone.neutral,
                    size: 64,
                  ),
                  SizedBox(height: context.getRSize(16)),
                  Text(
                    'Cart is empty',
                    style: context.boldStyle(16).copyWith(color: muted),
                  ),
                  SizedBox(height: context.getRSize(20)),
                  AppButton(
                    text: 'Recall',
                    variant: AppButtonVariant.outline,
                    icon: AppIcons.history,
                    isFullWidth: false,
                    onPressed: onRecall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The one-time "Tap an item to edit quantity, price or discount." hint, in
/// the pale primary tint with a 48dp ✕.
class CartEditHint extends StatelessWidget {
  const CartEditHint({super.key, required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final tint =
        t.extension<AppSchemeColors>()?.primaryTint ??
        t.colorScheme.primary.withValues(alpha: 0.12);
    final primary = t.colorScheme.primary;
    return Container(
      padding: EdgeInsetsDirectional.only(start: context.getRSize(12)),
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
      ),
      child: Row(
        children: [
          AppIcon(
            AppIcons.infoCircle,
            size: context.getRSize(18),
            color: primary,
          ),
          SizedBox(width: context.getRSize(10)),
          Expanded(
            child: Text(
              'Tap an item to edit quantity, price or discount.',
              style: context.mediumStyle(13).copyWith(color: primary),
            ),
          ),
          IconButton(
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            constraints: const BoxConstraints(
              minWidth: kMinInteractiveDimension,
              minHeight: kMinInteractiveDimension,
            ),
            icon: AppIcon(
              AppIcons.close,
              size: context.getRSize(16),
              color: primary,
            ),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}
