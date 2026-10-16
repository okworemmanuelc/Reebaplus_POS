import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

// Redesign parts for Supplier Detail, the Manufacturer screen and the crate
// sheets (#392 PR 4). Plain data in, theme-only styling, 48dp targets. Each is
// a shared-part candidate; they live here because a Wave 2 feature never adds
// files to the shared folder.

/// The Surface-less body of a crate sheet (#392): the theme supplies the sheet
/// shape and colour (the old sheets drew a 28dp Surface of their own), so this
/// is a keyed, scrolling column — [InventorySheetHeader], then [children] —
/// with `deviceBottomPadding` under the last control. Scrolls as one list, so a
/// keyboard or a short window never overflows. Width is the M3 sheet's 640.
class CrateSheetFrame extends StatelessWidget {
  const CrateSheetFrame({
    super.key,
    required this.frameKey,
    required this.title,
    required this.children,
    this.subtitle,
  });

  /// The key the sheet's tests find the whole sheet by.
  final Key frameKey;
  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final gutter = context.getRSize(20);
    return Container(
      key: frameKey,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          gutter,
          context.getRSize(12),
          gutter,
          context.getRSize(24) + context.deviceBottomPadding,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InventorySheetHeader(title: title, subtitle: subtitle),
            SizedBox(height: context.getRSize(20)),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// "This is what will be recorded" (#392): a tinted card with a primary
/// SemiBold caption and the [message] under it (the message carries
/// [messageKey] so tests read it). [tone] picks the fixed tint; the default is
/// the primary tint the old box used.
class CrateRecordBox extends StatelessWidget {
  const CrateRecordBox({
    super.key,
    required this.message,
    this.messageKey,
    this.caption = 'This is what will be recorded',
    this.icon,
    this.tone,
  });

  final String message;
  final Key? messageKey;
  final String? caption;
  final IconData? icon;
  final IconTileTone? tone;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final Color fill;
    final Color ink;
    if (tone == null) {
      fill = t.colorScheme.primary.withValues(alpha: 0.08);
      ink = t.colorScheme.primary;
    } else {
      (fill, ink) = tone!.resolve(f);
    }
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            AppIcon(
              icon!,
              filled: true,
              size: context.getRSize(18),
              color: ink,
            ),
            SizedBox(width: context.getRSize(10)),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (caption != null) ...[
                  Text(
                    caption!,
                    style: context.semiBoldStyle(12).copyWith(color: ink),
                  ),
                  SizedBox(height: context.getRSize(4)),
                ],
                Text(
                  message,
                  key: messageKey,
                  style: context
                      .mediumStyle(13)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A label / value line on a flat card (#392): the muted label on the left, the
/// Bold value on the right ("Expected empties in warehouse · 40 crates").
class CrateFactRow extends StatelessWidget {
  const CrateFactRow({
    super.key,
    required this.label,
    required this.value,
    this.valueKey,
  });

  final String label;
  final String value;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(14),
        vertical: context.getRSize(8),
      ),
      decoration: AppDecorations.card(context),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: context.semiBoldStyle(13).copyWith(color: muted),
            ),
          ),
          SizedBox(width: context.getRSize(8)),
          Text(
            value,
            key: valueKey,
            style: context
                .extraBoldStyle(14)
                .copyWith(color: t.colorScheme.onSurface),
          ),
        ],
      ),
    );
  }
}

/// The Cancel / confirm pair that ends a crate sheet (#392): two equal
/// `AppButton`s, 12 apart.
class CrateSheetActions extends StatelessWidget {
  const CrateSheetActions({
    super.key,
    required this.cancelKey,
    required this.confirmKey,
    required this.confirmText,
    required this.onCancel,
    required this.onConfirm,
    this.confirming = false,
    this.cancelVariant = AppButtonVariant.outline,
  });

  final Key cancelKey;
  final Key confirmKey;
  final String confirmText;
  final VoidCallback? onCancel;
  final VoidCallback? onConfirm;
  final bool confirming;
  final AppButtonVariant cancelVariant;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: AppButton(
            key: cancelKey,
            text: 'Cancel',
            variant: cancelVariant,
            onPressed: onCancel,
          ),
        ),
        SizedBox(width: context.getRSize(12)),
        Expanded(
          child: AppButton(
            key: confirmKey,
            text: confirmText,
            variant: AppButtonVariant.primary,
            isLoading: confirming,
            onPressed: onConfirm,
          ),
        ),
      ],
    );
  }
}

// ── Detail-screen parts (Supplier Detail, Manufacturer) ─────────────────────

/// The widest a detail screen's content grows (#392, batch-wide rule): a fixed
/// 960, not scaled, centred on wider screens.
const double kInventoryDetailMaxContentWidth = 960;

/// The measured content width from which a detail screen's header cards sit
/// side by side (below it they stack).
const double kInventoryDetailSideBySideWidth = 900;

/// Centres [child] in at most [kInventoryDetailMaxContentWidth]. The top bar
/// stays full width; only the body is capped.
class InventoryDetailColumn extends StatelessWidget {
  const InventoryDetailColumn({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: kInventoryDetailMaxContentWidth,
        ),
        child: child,
      ),
    );
  }
}

/// A detail screen's header cards (#392): side by side, equal width, when the
/// MEASURED width is at least [kInventoryDetailSideBySideWidth]; stacked
/// otherwise. A `LayoutBuilder`, never a viewport predicate. Each builder gets
/// whether to be compact: regular `StatCard`s side by side, slim rows when
/// stacked so the stack stays short enough to leave the tabs room on a
/// sideways phone.
class InventoryDetailHeaderCards extends StatelessWidget {
  const InventoryDetailHeaderCards({super.key, required this.builders});

  final List<Widget Function(bool compact)> builders;

  @override
  Widget build(BuildContext context) {
    final gutter = context.getRSize(16);
    final gap = context.getRSize(12);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= kInventoryDetailSideBySideWidth;
        final children = [for (final build in builders) build(!wide)];
        return Padding(
          padding: EdgeInsets.fromLTRB(gutter, gap, gutter, gap),
          child: wide
              ? IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < children.length; i++) ...[
                        if (i > 0) SizedBox(width: gap),
                        Expanded(child: children[i]),
                      ],
                    ],
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < children.length; i++) ...[
                      if (i > 0) SizedBox(height: gap),
                      children[i],
                    ],
                  ],
                ),
        );
      },
    );
  }
}

/// The tab bar of a detail screen (#392): the Inventory tab bar's look (Bold /
/// SemiBold 14 labels, primary underline) on the page, with a hairline under
/// it. Labels start at the column's edge.
class InventoryDetailTabBar extends StatelessWidget {
  const InventoryDetailTabBar({
    super.key,
    required this.controller,
    required this.labels,
  });

  final TabController controller;
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Container(
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        border: Border(bottom: BorderSide(color: t.dividerColor)),
      ),
      child: TabBar(
        controller: controller,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        dividerColor: Colors.transparent,
        labelColor: t.colorScheme.primary,
        unselectedLabelColor: muted,
        labelStyle: context.boldStyle(14),
        unselectedLabelStyle: context.semiBoldStyle(14),
        indicatorColor: t.colorScheme.primary,
        indicatorWeight: 3,
        tabs: [for (final label in labels) Tab(text: label)],
      ),
    );
  }
}

/// One row card on a detail screen's list (#392): a 40 [IconTile], Bold 15
/// title, muted subtitle, a [trailing] figure and an optional [footer] under
/// the row (action buttons). A flat card with the 16 / 5 list margins.
class InventoryDetailRowCard extends StatelessWidget {
  const InventoryDetailRowCard({
    super.key,
    required this.icon,
    required this.tone,
    required this.title,
    this.subtitle,
    this.trailing,
    this.footer,
    this.onTap,
  });

  final IconData icon;
  final IconTileTone tone;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget? footer;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final row = Row(
      children: [
        IconTile(icon: icon, tone: tone, size: 40),
        SizedBox(width: context.getRSize(12)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: context
                    .boldStyle(15)
                    .copyWith(color: t.colorScheme.onSurface),
              ),
              if (subtitle != null) ...[
                SizedBox(height: context.getRSize(2)),
                Text(
                  subtitle!,
                  style: context.regularStyle(12).copyWith(color: muted),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          SizedBox(width: context.getRSize(8)),
          trailing!,
        ],
      ],
    );
    final body = Padding(
      padding: EdgeInsets.all(context.getRSize(14)),
      child: footer == null
          ? row
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                row,
                SizedBox(height: context.getRSize(10)),
                footer!,
              ],
            ),
    );
    return Container(
      margin: EdgeInsets.symmetric(
        horizontal: context.getRSize(16),
        vertical: context.getRSize(5),
      ),
      constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
      decoration: AppDecorations.card(context),
      child: onTap == null
          ? body
          : Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
                onTap: onTap,
                child: body,
              ),
            ),
    );
  }
}

/// A detail header figure (#392): the Home [StatCard] when [compact] is false,
/// a slim one-line-figure row (36 tile, muted label over an ExtraBold figure,
/// optional pill) when true. Same data either way.
class InventoryDetailStatCard extends StatelessWidget {
  const InventoryDetailStatCard({
    super.key,
    required this.compact,
    required this.icon,
    required this.tone,
    required this.title,
    required this.value,
    required this.subtitle,
    this.pillLabel,
    this.pillTone = TagPillTone.neutral,
  });

  final bool compact;
  final IconData icon;
  final IconTileTone tone;
  final String title;
  final String value;
  final String subtitle;
  final String? pillLabel;
  final TagPillTone pillTone;

  @override
  Widget build(BuildContext context) {
    if (!compact) {
      return StatCard(
        icon: icon,
        tone: tone,
        title: title,
        value: value,
        subtitle: subtitle,
        pillLabel: pillLabel,
        pillTone: pillTone,
      );
    }
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(14),
        vertical: context.getRSize(10),
      ),
      decoration: AppDecorations.card(context),
      child: Row(
        children: [
          IconTile(icon: icon, tone: tone, size: 36),
          SizedBox(width: context.getRSize(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$title · $subtitle',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.semiBoldStyle(12).copyWith(color: muted),
                ),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context
                      .extraBoldStyle(18)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
              ],
            ),
          ),
          if (pillLabel != null) ...[
            SizedBox(width: context.getRSize(8)),
            StatusPill(label: pillLabel!, tone: pillTone, dense: true),
          ],
        ],
      ),
    );
  }
}
