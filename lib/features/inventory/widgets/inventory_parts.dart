import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/settings/screens/settings_screen.dart'
    show kSettingsMaxContentWidth;
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/notifications_modal.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

// The Inventory feature's own redesign parts (#392, Wave 2 A). Plain data in,
// theme-only styling, 48dp targets. Each one is a shared-part candidate; they
// live here because a Wave 2 feature never adds files to the shared folder.

/// The widest the Inventory list and form content grows (#392): the settings
/// cap (720, #369 / #389), centred on wider screens. Fixed, not scaled — the
/// batch-wide rule for list and form screens.
const double kInventoryMaxContentWidth = kSettingsMaxContentWidth;

/// The side gutter that keeps [kInventoryMaxContentWidth] centred in [width]
/// (a measured width — never a viewport predicate), never under 16dp scaled.
double inventoryGutter(BuildContext context, double width) =>
    math.max(context.getRSize(16), (width - kInventoryMaxContentWidth) / 2);

/// The Inventory top bars' height: Home's rule (`homeTopBarHeight`, #374) —
/// the theme's 68dp, grown when the scaled header tile or a 48dp control would
/// touch its edges. Repeated because a feature never reaches into another
/// feature's widgets.
double inventoryTopBarHeight(BuildContext context) => math.max(
  kToolbarHeight + 12,
  math.max(context.getRSize(44), kMinInteractiveDimension) +
      context.getRSize(16),
);

/// The solid Inventory top bar (#392): `colorScheme.surface`, a hairline at the
/// bottom and the soft `topBarShadow`, never changing on scroll — the Home /
/// POS / CEO Settings bar with the shared [ScreenHeader].
class InventoryTopBar extends StatelessWidget implements PreferredSizeWidget {
  const InventoryTopBar({
    super.key,
    required this.icon,
    required this.title,
    required this.height,
    this.subtitle,
    this.leading,
    this.actions = const [],
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final double height;

  /// The menu or back button (a 48dp target), or null.
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
      toolbarHeight: preferredSize.height,
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
      title: ScreenHeader(
        icon: icon,
        title: title,
        subtitle: subtitle,
        leading: leading,
        actions: actions,
      ),
    );
  }
}

/// A plain icon action in an Inventory top bar: a 48dp target with the icon in
/// the text colour (the POS view selector's look).
class InventoryBarAction extends StatelessWidget {
  const InventoryBarAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      constraints: const BoxConstraints(
        minWidth: kMinInteractiveDimension,
        minHeight: kMinInteractiveDimension,
      ),
      onPressed: onPressed,
      icon: AppIcon(
        icon,
        size: context.getRSize(24),
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }
}

/// The shared [HeaderBell] fed by the live notification service; a tap opens
/// the same notifications modal as the app's `NotificationBell` (Home's
/// `HomeLiveBell`, repeated here — a shared-part candidate).
class InventoryLiveBell extends ConsumerWidget {
  const InventoryLiveBell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifService = ref.read(notificationProvider);
    return ValueListenableBuilder(
      valueListenable: notifService,
      builder: (context, _, _) => HeaderBell(
        count: notifService.unreadCount,
        onPressed: () => NotificationsModal.show(context),
      ),
    );
  }
}

/// A compact figure card that may also be a filter (#392): a pale icon tile,
/// an ExtraBold figure and a muted label; a 2dp primary border while its
/// filter is on. The Inventory summary row and the Empty Crates / History
/// figures. Shared-part candidate (a selectable compact `StatCard`).
class InventoryFigureCard extends StatelessWidget {
  const InventoryFigureCard({
    super.key,
    required this.icon,
    required this.tone,
    required this.value,
    required this.label,
    this.selected = false,
    this.onTap,
  });

  final IconData icon;
  final IconTileTone tone;
  final String value;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusL);
    // Tile and figure on one line, the label under them at full width, so a
    // narrow card (the phone's sideways row) still fits "Out of Stock".
    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(12)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconTile(icon: icon, tone: tone, size: 32),
                SizedBox(width: context.getRSize(8)),
                Expanded(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context
                        .extraBoldStyle(20)
                        .copyWith(color: t.colorScheme.onSurface),
                  ),
                ),
              ],
            ),
            SizedBox(height: context.getRSize(6)),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.semiBoldStyle(12).copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
    return Semantics(
      button: onTap != null,
      selected: selected,
      child: DecoratedBox(
        decoration:
            AppDecorations.card(
              context,
              radius: AppSpacing.borderRadiusL,
            ).copyWith(
              border: Border.all(
                color: selected ? t.colorScheme.primary : t.dividerColor,
                width: selected ? 2 : 1,
              ),
            ),
        child: onTap == null
            ? content
            : Material(
                type: MaterialType.transparency,
                child: InkWell(
                  borderRadius: radius,
                  onTap: onTap,
                  child: content,
                ),
              ),
      ),
    );
  }
}

/// How a product row's stock reads (#392).
enum InventoryStockState { ok, low, out }

/// One Inventory product row (#392): the product's photo, else its category
/// tile (`categoryVisual`, the PRD #346 product-tile rule), name, subtitle,
/// stock pill and expiry pill, then the stock figure and unit. Whole card taps;
/// long-press only when [onLongPress] is given.
class InventoryProductRow extends StatelessWidget {
  const InventoryProductRow({
    super.key,
    required this.name,
    required this.stockLabel,
    required this.state,
    this.subtitle,
    this.categoryName,
    this.photoPath,
    this.unit,
    this.expiryLabel,
    this.expired = false,
    this.onTap,
    this.onLongPress,
  });

  final String name;
  final String? subtitle;
  final String? categoryName;
  final String? photoPath;

  /// The stock figure ("24").
  final String stockLabel;
  final String? unit;
  final InventoryStockState state;

  /// "Expired" / "Expires in 3d", or null when not flagged.
  final String? expiryLabel;
  final bool expired;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final visual = categoryVisual(categoryName, f);
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    final tile = context.getRSize(52);

    final (
      String statusLabel,
      TagPillTone statusTone,
      Color figure,
      Color edge,
    ) = switch (state) {
      InventoryStockState.out => (
        'Out of Stock',
        TagPillTone.danger,
        f.danger,
        f.dangerOutline,
      ),
      InventoryStockState.low => (
        'Low Stock',
        TagPillTone.warning,
        f.warning,
        f.warningOutline,
      ),
      InventoryStockState.ok => (
        'In Stock',
        TagPillTone.green,
        t.colorScheme.onSurface,
        t.dividerColor,
      ),
    };

    final fallback = Center(
      child: AppIcon(
        visual.icon,
        filled: true,
        size: tile * 0.5,
        color: visual.iconColor,
      ),
    );
    final art = ClipRRect(
      borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
      child: SizedBox.square(
        dimension: tile,
        child: ColoredBox(
          color: visual.tint,
          child: photoPath == null
              ? fallback
              : Image.file(
                  File(photoPath!),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => fallback,
                ),
        ),
      ),
    );

    return DecoratedBox(
      decoration: AppDecorations.card(
        context,
      ).copyWith(border: Border.all(color: edge)),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: EdgeInsets.all(context.getRSize(12)),
            child: Row(
              children: [
                art,
                SizedBox(width: context.getRSize(12)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context
                            .boldStyle(15)
                            .copyWith(color: t.colorScheme.onSurface),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context
                              .regularStyle(12)
                              .copyWith(color: muted),
                        ),
                      SizedBox(height: context.getRSize(6)),
                      Wrap(
                        spacing: context.getRSize(6),
                        runSpacing: context.getRSize(4),
                        children: [
                          TagPill(label: statusLabel, tone: statusTone),
                          if (expiryLabel != null)
                            TagPill(
                              label: expiryLabel!,
                              tone: expired
                                  ? TagPillTone.danger
                                  : TagPillTone.warning,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                SizedBox(width: context.getRSize(10)),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      stockLabel,
                      style: context.extraBoldStyle(22).copyWith(color: figure),
                    ),
                    // A unitless product (#108) shows just the count.
                    if ((unit ?? '').isNotEmpty)
                      Text(
                        unit!,
                        style: context.regularStyle(12).copyWith(color: muted),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A flat card for an empty list (#392): neutral icon tile, Bold title, muted
/// subtitle.
class InventoryEmptyCard extends StatelessWidget {
  const InventoryEmptyCard({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(16),
        vertical: context.getRSize(28),
      ),
      decoration: AppDecorations.card(context),
      child: Column(
        children: [
          IconTile(icon: icon, tone: IconTileTone.neutral, size: 48),
          SizedBox(height: context.getRSize(12)),
          Text(
            title,
            textAlign: TextAlign.center,
            style: context
                .boldStyle(15)
                .copyWith(color: t.colorScheme.onSurface),
          ),
          if (subtitle != null) ...[
            SizedBox(height: context.getRSize(2)),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: context.regularStyle(13).copyWith(color: muted),
            ),
          ],
        ],
      ),
    );
  }
}

/// The top of an Inventory bottom sheet (#392, as the customer payment sheet):
/// a hairline handle, the title in `screenTitleStyle` and an optional primary
/// SemiBold subtitle.
class InventorySheetHeader extends StatelessWidget {
  const InventorySheetHeader({super.key, required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Center(
          child: Container(
            width: context.getRSize(40),
            height: context.getRSize(4),
            decoration: BoxDecoration(
              color: t.dividerColor,
              borderRadius: BorderRadius.circular(AppSpacing.borderRadiusS),
            ),
          ),
        ),
        SizedBox(height: context.getRSize(16)),
        Text(
          title,
          style: context.screenTitleStyle.copyWith(
            color: t.colorScheme.onSurface,
          ),
        ),
        if (subtitle != null) ...[
          SizedBox(height: context.getRSize(2)),
          Text(
            subtitle!,
            style: context
                .semiBoldStyle(13)
                .copyWith(color: t.colorScheme.primary),
          ),
        ],
      ],
    );
  }
}

/// A period pill (#392, History tab): the `CategoryChip` stadium without the
/// category dot — primary when selected, Surface with a hairline otherwise.
/// A 48dp target.
class InventoryPeriodChip extends StatelessWidget {
  const InventoryPeriodChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final ink = selected ? t.colorScheme.onPrimary : t.colorScheme.onSurface;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: kMinInteractiveDimension,
            minWidth: kMinInteractiveDimension,
          ),
          child: Center(
            widthFactor: 1,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: context.getRSize(14),
                vertical: context.getRSize(8),
              ),
              decoration: ShapeDecoration(
                color: selected ? t.colorScheme.primary : t.colorScheme.surface,
                shape: StadiumBorder(
                  side: BorderSide(
                    color: selected ? t.colorScheme.primary : t.dividerColor,
                  ),
                ),
              ),
              child: Text(
                label,
                maxLines: 1,
                softWrap: false,
                style: context.semiBoldStyle(14).copyWith(color: ink),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Form parts (#392 PR 2: Add Product, Update Product) ─────────────────────

/// A flat card holding a group of form fields (#392): `AppDecorations.card`
/// with a 16dp inset. Shared-part candidate.
class InventoryFormCard extends StatelessWidget {
  const InventoryFormCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(context.getRSize(16)),
      decoration: AppDecorations.card(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

/// The small uppercase label over a field that has none of its own
/// ("PRODUCT UNIT", "EXPIRY DATE", "STORE *"): SemiBold 12, muted.
class InventoryFieldLabel extends StatelessWidget {
  const InventoryFieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Text(
      text,
      style: context
          .semiBoldStyle(12)
          .copyWith(color: muted, letterSpacing: 0.6),
    );
  }
}

/// A one-line hint under a field: Regular 12, muted (or [color]).
class InventoryFieldHelper extends StatelessWidget {
  const InventoryFieldHelper(this.text, {super.key, this.color, this.icon});

  final String text;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final ink =
        color ?? t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Padding(
      padding: EdgeInsets.only(
        top: context.getRSize(6),
        left: context.getRSize(4),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            AppIcon(icon!, size: context.getRSize(14), color: ink),
            SizedBox(width: context.getRSize(6)),
          ],
          Expanded(
            child: Text(
              text,
              style: context.regularStyle(12).copyWith(color: ink),
            ),
          ),
        ],
      ),
    );
  }
}

/// A tinted notice in a fixed tone (#392): the form's error banner (`danger`)
/// and "Adding stock to existing …" (`green`). Optional [title] above the
/// message; [onClose] adds a 48dp ✕.
class InventoryNotice extends StatelessWidget {
  const InventoryNotice({
    super.key,
    required this.icon,
    required this.tone,
    required this.message,
    this.title,
    this.onClose,
    this.closeTooltip = 'Dismiss',
  });

  final IconData icon;
  final IconTileTone tone;
  final String message;
  final String? title;
  final VoidCallback? onClose;
  final String closeTooltip;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final (fill, ink) = tone.resolve(f);
    return Container(
      width: double.infinity,
      padding: EdgeInsetsDirectional.fromSTEB(
        context.getRSize(14),
        context.getRSize(10),
        context.getRSize(onClose == null ? 14 : 2),
        context.getRSize(10),
      ),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
      ),
      child: Row(
        children: [
          AppIcon(icon, filled: true, size: context.getRSize(20), color: ink),
          SizedBox(width: context.getRSize(10)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null)
                  Text(
                    title!,
                    style: context.semiBoldStyle(12).copyWith(color: ink),
                  ),
                Text(
                  message,
                  style: title == null
                      ? context.semiBoldStyle(13).copyWith(color: ink)
                      : context
                            .extraBoldStyle(14)
                            .copyWith(color: t.colorScheme.onSurface),
                ),
              ],
            ),
          ),
          if (onClose != null)
            IconButton(
              tooltip: closeTooltip,
              onPressed: onClose,
              constraints: const BoxConstraints(
                minWidth: kMinInteractiveDimension,
                minHeight: kMinInteractiveDimension,
              ),
              icon: AppIcon(
                AppIcons.close,
                size: context.getRSize(18),
                color: ink,
              ),
            ),
        ],
      ),
    );
  }
}

/// The drop-down list of suggestions under a search field (#392): a flat card
/// of [InventorySuggestionTile]s.
class InventorySuggestionList extends StatelessWidget {
  const InventorySuggestionList({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(top: context.getRSize(6)),
      clipBehavior: Clip.antiAlias,
      decoration: AppDecorations.card(
        context,
        radius: AppSpacing.borderRadiusM,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

/// One suggestion: primary icon + SemiBold 14 label; a 48dp row. [emphasis]
/// draws the label in primary ("Create …"). An optional [trailing] (a tag such
/// as "Archived", #487) sits at the end.
class InventorySuggestionTile extends StatelessWidget {
  const InventorySuggestionTile({
    super.key,
    required this.label,
    required this.onTap,
    this.icon = AppIcons.user,
    this.emphasis = false,
    this.trailing,
  });

  final String label;
  final IconData icon;
  final bool emphasis;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.getRSize(14),
            vertical: context.getRSize(10),
          ),
          child: Row(
            children: [
              AppIcon(
                icon,
                size: context.getRSize(18),
                color: t.colorScheme.primary,
              ),
              SizedBox(width: context.getRSize(10)),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: context
                      .semiBoldStyle(14)
                      .copyWith(
                        color: emphasis
                            ? t.colorScheme.primary
                            : t.colorScheme.onSurface,
                      ),
                ),
              ),
              if (trailing != null) ...[
                SizedBox(width: context.getRSize(8)),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A tappable date field in the `AppInput` shape (#392, the expiry date): the
/// theme's input fill, 14 radius, calendar icon, the date or [placeholder],
/// and a 48dp clear ✕ when a date is set. The whole field is a 48dp target.
class InventoryDateField extends StatelessWidget {
  const InventoryDateField({
    super.key,
    required this.label,
    required this.placeholder,
    required this.onTap,
    this.onClear,
  });

  /// The formatted date, or null for none.
  final String? label;
  final String placeholder;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    // The AppInput shape: the theme's input border radius.
    final themeBorder = t.inputDecorationTheme.border;
    final radius = themeBorder is OutlineInputBorder
        ? themeBorder.borderRadius
        : BorderRadius.circular(AppSpacing.borderRadiusM);
    final has = label != null;
    return Material(
      color: t.inputDecorationTheme.fillColor ?? t.colorScheme.surface,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: kMinInteractiveDimension,
          ),
          child: Padding(
            padding: EdgeInsetsDirectional.only(
              start: context.getRSize(16),
              end: context.getRSize(has && onClear != null ? 0 : 16),
            ),
            child: Row(
              children: [
                AppIcon(
                  AppIcons.event,
                  size: context.getRSize(20),
                  color: t.colorScheme.primary,
                ),
                SizedBox(width: context.getRSize(12)),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      vertical: context.getRSize(12),
                    ),
                    child: Text(
                      label ?? placeholder,
                      style: has
                          ? context
                                .semiBoldStyle(14)
                                .copyWith(color: t.colorScheme.onSurface)
                          : context.regularStyle(14).copyWith(color: muted),
                    ),
                  ),
                ),
                if (has && onClear != null)
                  IconButton(
                    tooltip: 'Clear date',
                    onPressed: onClear,
                    constraints: const BoxConstraints(
                      minWidth: kMinInteractiveDimension,
                      minHeight: kMinInteractiveDimension,
                    ),
                    icon: AppIcon(
                      AppIcons.close,
                      size: context.getRSize(18),
                      color: muted,
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

/// A checkbox row (#392): the same `CheckboxListTile` (leading box, whole row
/// taps), with the title SemiBold 14 and the subtitle Regular 12 muted.
class InventoryCheckRow extends StatelessWidget {
  const InventoryCheckRow({
    super.key,
    required this.value,
    required this.onChanged,
    required this.title,
    required this.subtitle,
  });

  final bool value;
  final ValueChanged<bool?> onChanged;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Material(
      type: MaterialType.transparency,
      child: CheckboxListTile(
        value: value,
        onChanged: onChanged,
        title: Text(
          title,
          style: context
              .semiBoldStyle(14)
              .copyWith(color: t.colorScheme.onSurface),
        ),
        subtitle: Text(
          subtitle,
          style: context.regularStyle(12).copyWith(color: muted),
        ),
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: EdgeInsets.zero,
        dense: true,
      ),
    );
  }
}

/// A clear ✕ inside a search field's suffix: a 48dp target.
class InventoryFieldClear extends StatelessWidget {
  const InventoryFieldClear({
    super.key,
    required this.onPressed,
    this.tooltip = 'Clear',
  });

  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      constraints: const BoxConstraints(
        minWidth: kMinInteractiveDimension,
        minHeight: kMinInteractiveDimension,
      ),
      icon: AppIcon(AppIcons.close, size: context.getRSize(18), color: muted),
    );
  }
}

/// A search-field prefix icon in primary (the redesign's search fields).
class InventorySearchIcon extends StatelessWidget {
  const InventorySearchIcon({super.key});

  @override
  Widget build(BuildContext context) => AppIcon(
    AppIcons.search,
    size: context.getRSize(20),
    color: Theme.of(context).colorScheme.primary,
  );
}

/// The pinned footer under a form (#392): Surface, a hairline on top, the
/// [child] (the save button) capped at [maxWidth] and centred, and
/// `deviceBottomPadding` below it.
class InventoryFormFooter extends StatelessWidget {
  const InventoryFormFooter({
    super.key,
    required this.child,
    this.maxWidth = kInventoryMaxContentWidth,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        border: Border(top: BorderSide(color: t.dividerColor)),
      ),
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(10),
        context.getRSize(16),
        context.getRSize(12) + context.deviceBottomPadding,
      ),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: child,
        ),
      ),
    );
  }
}
