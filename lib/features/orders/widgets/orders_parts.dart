import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/settings/settings_screen.dart'
    show kSettingsMaxContentWidth;
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/screen_header.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/tag_pill.dart';

// Local parts for the Orders restyle (#393 PR 2, PRD #346 Wave 2 A): the
// Orders tab, the crate return sheet and Crate Return Approval. Plain data and
// callbacks only — nothing here computes money or decides a status.
//
// Shared-part candidates: [OrdersTopBar] (a solid bar with ScreenHeader — the
// same recipe as Home / POS / Cart / Checkout), [OrdersSummaryStrip] (a row of
// small figures in one card) and [OrdersEmptyState].

/// Keys the Orders tests find the parts by.
abstract final class OrdersKeys {
  static const topBar = Key('orders-top-bar');
  static const tabBar = Key('orders-tab-bar');
  static const summary = Key('orders-summary');
  static const search = Key('orders-search');
  static const period = Key('orders-period');
  static const refund = Key('orders-refund');
  static const confirm = Key('orders-confirm');
  static const rider = Key('orders-rider');
  static const receiptSheet = Key('orders-receipt-sheet');
  static const crateReturnSheet = Key('orders-crate-return-sheet');
  static const refundCredit = Key('orders-refund-to-credit');
  static const refundCash = Key('orders-refund-to-cash');
  static const payOnDeliveryPill = Key('orders-pay-on-delivery-pill');
  static const payOnDeliveryLabel = Key('orders-pay-on-delivery-label');
}

/// Height of the Orders top bar: room for the 44 icon tile (or a 48dp
/// control) plus 8 above and below, never less than the app's bar height.
double ordersTopBarHeight(BuildContext context) => math.max(
  kToolbarHeight + 12,
  math.max(context.getRSize(44), kMinInteractiveDimension) +
      context.getRSize(16),
);

/// Horizontal padding that centres content at most [kSettingsMaxContentWidth]
/// wide in [width], never less than [gutter] on either side.
double ordersCapPadding(double width, double gutter) =>
    math.max(gutter, (width - kSettingsMaxContentWidth) / 2 + gutter);

/// The solid top bar (as Home / POS / Cart): Surface, hairline,
/// `topBarShadow`, with the shared [ScreenHeader].
class OrdersTopBar extends StatelessWidget implements PreferredSizeWidget {
  const OrdersTopBar({
    super.key,
    required this.height,
    required this.icon,
    required this.title,
    this.subtitle,
    this.leading,
    this.actions = const [],
  });

  final double height;
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final topBarShadow =
        t.extension<AppSchemeColors>()?.topBarShadow ?? Colors.transparent;
    return AppBar(
      automaticallyImplyLeading: false,
      toolbarHeight: height,
      titleSpacing: context.getRSize(leading == null ? 16 : 4),
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
        padding: EdgeInsets.only(right: context.getRSize(8)),
        child: ScreenHeader(
          icon: icon,
          title: title,
          subtitle: subtitle,
          leading: leading,
          actions: actions,
        ),
      ),
    );
  }
}

/// A 48dp back button for [OrdersTopBar] on a pushed screen.
class OrdersBackButton extends StatelessWidget {
  const OrdersBackButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Back',
      constraints: const BoxConstraints(
        minWidth: kMinInteractiveDimension,
        minHeight: kMinInteractiveDimension,
      ),
      icon: AppIcon(
        AppIcons.arrowBackIosNew,
        size: context.getRSize(22),
        color: Theme.of(context).colorScheme.onSurface,
      ),
      onPressed: onPressed,
    );
  }
}

/// One figure of the summary strip; [color] null = plain text colour.
typedef OrdersStat = ({String label, String value, Color? color});

/// The figures above an Orders tab, side by side in one flat card with
/// hairlines between them. A figure scales down rather than being cut short.
class OrdersSummaryStrip extends StatelessWidget {
  const OrdersSummaryStrip({super.key, required this.stats});

  final List<OrdersStat> stats;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return DecoratedBox(
      key: OrdersKeys.summary,
      decoration: AppDecorations.card(
        context,
        radius: AppSpacing.borderRadiusL,
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: context.getRSize(10)),
        child: IntrinsicHeight(
          child: Row(
            children: [
              for (int i = 0; i < stats.length; i++) ...[
                if (i > 0) VerticalDivider(width: 1, color: t.dividerColor),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: context.getRSize(6),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            stats[i].value,
                            maxLines: 1,
                            style: context
                                .extraBoldStyle(16)
                                .copyWith(
                                  color:
                                      stats[i].color ?? t.colorScheme.onSurface,
                                ),
                          ),
                        ),
                        SizedBox(height: context.getRSize(2)),
                        Text(
                          stats[i].label,
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          style: context
                              .semiBoldStyle(11)
                              .copyWith(color: muted),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A centred empty state: neutral 64 tile + one line.
class OrdersEmptyState extends StatelessWidget {
  const OrdersEmptyState({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Padding(
      padding: EdgeInsets.all(context.getRSize(16)),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          IconTile(icon: icon, tone: IconTileTone.neutral, size: 64),
          SizedBox(height: context.getRSize(14)),
          Text(
            text,
            textAlign: TextAlign.center,
            style: context.semiBoldStyle(15).copyWith(color: muted),
          ),
        ],
      ),
    );
  }
}

/// The fixed colour of an order status (accent stripe and pill): pending =
/// the scheme primary, completed = green, refunded = info, else danger.
Color orderStatusColor(BuildContext context, String status) {
  final f =
      Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;
  return switch (status) {
    'pending' => Theme.of(context).colorScheme.primary,
    'completed' => f.green,
    'refunded' => f.info,
    _ => f.danger,
  };
}

/// The status pill on a Completed / Cancelled card (words unchanged).
class OrderStatusPill extends StatelessWidget {
  const OrderStatusPill({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final (label, tone, icon) = switch (status) {
      'completed' => ('DONE', TagPillTone.green, AppIcons.check),
      // LEGACY ROWS ONLY (#196): `refunded` is a retired status, still listed.
      'refunded' => ('REFUNDED', TagPillTone.info, AppIcons.refresh),
      _ => ('CANCELLED', TagPillTone.danger, AppIcons.block),
    };
    return TagPill(label: label, tone: tone, icon: icon);
  }
}
