import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

// Product Detail's local parts (#392 PR 3, Wave 2 A). Plain data in, theme-only
// styling. Each is a shared-part candidate; a Wave 2 feature never adds files
// to `lib/shared/widgets/redesign/`.

/// The widest a detail screen's content grows (#392): a fixed 960, centred.
/// The batch-wide detail rule (Product, Supplier, Manufacturer, Customer).
const double kDetailMaxContentWidth = 960;

/// The measured width from which a detail screen's header cards sit side by
/// side; narrower, they stack.
const double kDetailSideBySideWidth = 900;

/// The side gutter that keeps [kDetailMaxContentWidth] centred in [width] (a
/// measured width — never a viewport predicate), never under 16dp scaled.
double detailGutter(BuildContext context, double width) =>
    math.max(context.getRSize(16), (width - kDetailMaxContentWidth) / 2);

/// Two cards side by side when [sideBySide], else stacked with the same gap.
class DetailPair extends StatelessWidget {
  const DetailPair({
    super.key,
    required this.sideBySide,
    required this.first,
    required this.second,
  });

  final bool sideBySide;
  final Widget first;
  final Widget second;

  @override
  Widget build(BuildContext context) {
    final gap = context.getRSize(16);
    if (sideBySide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: first),
          SizedBox(width: gap),
          Expanded(child: second),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        first,
        SizedBox(height: gap),
        second,
      ],
    );
  }
}

/// A [SectionHeader] over a [child] (usually a [DetailCard]).
class DetailSection extends StatelessWidget {
  const DetailSection({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(title: title, subtitle: subtitle),
        SizedBox(height: context.getRSize(10)),
        child,
      ],
    );
  }
}

/// A flat card holding hairline-separated rows (`AppDecorations.card`).
class DetailCard extends StatelessWidget {
  const DetailCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: AppDecorations.card(context),
      child: Column(children: children),
    );
  }
}

/// A label / value row inside a [DetailCard]: a 40 [IconTile], a SemiBold
/// muted label, an optional Bold value and an optional trailing control. At
/// least 48dp tall at any text size.
class DetailInfoRow extends StatelessWidget {
  const DetailInfoRow({
    super.key,
    required this.icon,
    required this.tone,
    required this.label,
    this.value = '',
    this.trailing,
  });

  final IconData icon;
  final IconTileTone tone;
  final String label;
  final String value;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.getRSize(14),
          vertical: context.getRSize(10),
        ),
        child: LayoutBuilder(
          builder: (context, c) => _row(context, c.maxWidth),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, double rowWidth) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Row(
      children: [
        IconTile(icon: icon, tone: tone, size: 40),
        SizedBox(width: context.getRSize(12)),
        Expanded(
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.semiBoldStyle(13).copyWith(color: muted),
          ),
        ),
        if (value.isNotEmpty) ...[
          SizedBox(width: context.getRSize(8)),
          // The value hugs the end and never takes more than half the row.
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: rowWidth * 0.45),
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: context
                  .boldStyle(14)
                  .copyWith(color: t.colorScheme.onSurface),
            ),
          ),
        ],
        if (trailing != null) ...[
          SizedBox(width: context.getRSize(8)),
          trailing!,
        ],
      ],
    );
  }
}

/// The hairline between rows of a [DetailCard].
class DetailDivider extends StatelessWidget {
  const DetailDivider({super.key});

  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    color: Theme.of(context).dividerColor,
    indent: context.getRSize(14),
    endIndent: context.getRSize(14),
  );
}

// ── Product Details top bar (#487 PR 3) ─────────────────────────────────────

/// A 48dp tonal rounded square holding one icon (the back button and the ⋮
/// button of the Product Details bar).
class DetailBarSquare extends StatelessWidget {
  const DetailBarSquare({
    super.key,
    required this.icon,
    this.tooltip,
    this.onTap,
  });

  final IconData icon;

  /// Null when a menu button around the square already carries the tooltip.
  final String? tooltip;

  /// Null when the square is only the face of a menu button, which handles the
  /// tap itself.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final face = Container(
      width: context.getRSize(44),
      height: context.getRSize(44),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: f.neutralTile,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
      ),
      child: AppIcon(
        icon,
        size: context.getRSize(22),
        color: t.colorScheme.onSurface,
      ),
    );
    final square = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: kMinInteractiveDimension,
          minHeight: kMinInteractiveDimension,
        ),
        child: Center(child: face),
      ),
    );
    return tooltip == null ? square : Tooltip(message: tooltip!, child: square);
  }
}

/// The solid Product Details bar: a tonal back button, "Product Details" with
/// the primary subtitle "Inventory", then [actions]. The same surface, hairline
/// and soft shadow as the other Inventory bars (`InventoryTopBar`).
class ProductDetailTopBar extends StatelessWidget
    implements PreferredSizeWidget {
  const ProductDetailTopBar({
    super.key,
    required this.height,
    required this.onBack,
    this.actions = const [],
  });

  final double height;
  final VoidCallback onBack;
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
      titleSpacing: context.getRSize(8),
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
      title: Row(
        children: [
          DetailBarSquare(
            icon: AppIcons.arrowBack,
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onTap: onBack,
          ),
          SizedBox(width: context.getRSize(8)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Product Details',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.screenTitleStyle.copyWith(
                    color: t.colorScheme.onSurface,
                  ),
                ),
                Text(
                  'Inventory',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context
                      .semiBoldStyle(13)
                      .copyWith(color: t.colorScheme.primary),
                ),
              ],
            ),
          ),
          for (final a in actions) ...[SizedBox(width: context.getRSize(8)), a],
          // Match the back button's inset on the right.
          if (actions.isNotEmpty) SizedBox(width: context.getRSize(8)),
        ],
      ),
    );
  }
}
