import 'dart:io';

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

// The drawer's building blocks (#368, `phone-drawer-dark.png`,
// `wide-drawer-*.png`). Plain data and callbacks only — `AppDrawer` reads the
// providers and gates and decides what shows; these only draw it.

/// The drawer's width before the left system inset: the mockups' ~328dp
/// (phone: 656 of 780px at 2x; wide: 655 of 2560px at 2x), never more than
/// [kAppDrawerMaxWidthFraction] of the screen. A share of the window, not a
/// scaled spacing value — the same rule as the cart panel's width.
const double kAppDrawerMaxWidth = 328;

/// See [kAppDrawerMaxWidth]; the phone mockup's drawer is 84% of the screen.
const double kAppDrawerMaxWidthFraction = 0.84;

/// The drawer's width at the current size, including the left system inset
/// (a display cutout on a sideways phone), which the drawer's Surface runs
/// under while its content stays clear of it.
double appDrawerWidth(BuildContext context) {
  final share = context.screenWidth * kAppDrawerMaxWidthFraction;
  final base = share < kAppDrawerMaxWidth ? share : kAppDrawerMaxWidth;
  return base + MediaQuery.paddingOf(context).left;
}

/// Keys the tests use to find the drawer's regions.
abstract final class AppDrawerKeys {
  static const header = Key('drawer-header');
  static const list = Key('drawer-list');
  static const footer = Key('drawer-footer');
  static const profileTile = Key('drawer-profile-tile');
  static const lock = Key('drawer-lock');
  static const close = Key('drawer-close');
  static const syncBanner = Key('drawer-sync-banner');
  static const storePicker = Key('drawer-store-picker');
  static const display = Key('drawer-display');
  static const logOut = Key('drawer-log-out');
}

/// One tag under the person's name: PRO / FREE TRIAL, the role.
typedef DrawerTag = ({String label, TagPillTone tone});

/// The top of the drawer: the business tile (logo, else its initial) and name,
/// the lock and close buttons, the person's name and tags, then [banner].
class DrawerHeaderBlock extends StatelessWidget {
  const DrawerHeaderBlock({
    super.key,
    required this.businessName,
    required this.logoPath,
    required this.userName,
    required this.tags,
    required this.terminalLabel,
    required this.onOpenProfile,
    required this.onLock,
    required this.onClose,
    this.banner,
  });

  final String businessName;

  /// A local file of the business logo; null draws the initial.
  final String? logoPath;
  final String userName;
  final List<DrawerTag> tags;
  final String terminalLabel;
  final VoidCallback onOpenProfile;

  /// Null hides the lock button (nobody is signed in).
  final VoidCallback? onLock;
  final VoidCallback onClose;

  /// The sync banner, when there is one to show.
  final Widget? banner;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final onSurface = t.colorScheme.onSurface;
    final muted = t.textTheme.bodySmall?.color ?? onSurface;
    final gap = context.getRSize(12);
    return Column(
      key: AppDrawerKeys.header,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            _BusinessTile(
              businessName: businessName,
              logoPath: logoPath,
              onTap: onOpenProfile,
            ),
            SizedBox(width: gap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    businessName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.screenTitleStyle.copyWith(color: onSurface),
                  ),
                  Text(
                    'Tap logo to open profile',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context
                        .semiBoldStyle(12)
                        .copyWith(color: t.colorScheme.primary),
                  ),
                ],
              ),
            ),
            if (onLock != null) ...[
              SizedBox(width: context.getRSize(8)),
              _LockButton(onPressed: onLock!),
            ],
            IconButton(
              key: AppDrawerKeys.close,
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              onPressed: onClose,
              icon: AppIcon(
                AppIcons.close,
                size: context.getRSize(24),
                color: muted,
              ),
            ),
          ],
        ),
        SizedBox(height: gap),
        Text(
          userName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.boldStyle(17).copyWith(color: onSurface),
        ),
        SizedBox(height: context.getRSize(6)),
        Wrap(
          spacing: context.getRSize(8),
          runSpacing: context.getRSize(6),
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final tag in tags) TagPill(label: tag.label, tone: tag.tone),
            Text(
              terminalLabel,
              maxLines: 1,
              softWrap: false,
              style: context.monoStyle.copyWith(color: muted),
            ),
          ],
        ),
        if (banner != null) ...[SizedBox(height: gap), banner!],
      ],
    );
  }
}

/// The business tile: the logo when one is set, else a primary-gradient square
/// with the business initial. Tapping it opens Profile.
class _BusinessTile extends StatelessWidget {
  const _BusinessTile({
    required this.businessName,
    required this.logoPath,
    required this.onTap,
  });

  final String businessName;
  final String? logoPath;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final edge = context
        .getRSize(56)
        .clamp(kMinInteractiveDimension, double.infinity);
    final radius = BorderRadius.circular(AppSpacing.borderRadiusL);
    final trimmed = businessName.trim();
    final initial = trimmed.isEmpty
        ? '?'
        : trimmed.characters.first.toUpperCase();
    final initialTile = Container(
      alignment: Alignment.center,
      decoration: AppDecorations.primaryButtonGradient(
        context,
        radius: AppSpacing.borderRadiusL,
      ),
      child: Text(
        initial,
        style: context
            .extraBoldStyle(24)
            .copyWith(color: t.colorScheme.onPrimary),
      ),
    );
    final path = logoPath;
    return SizedBox(
      key: AppDrawerKeys.profileTile,
      width: edge,
      height: edge,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: path == null
              ? initialTile
              : ClipRRect(
                  borderRadius: radius,
                  child: Image.file(
                    File(path),
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stack) => initialTile,
                  ),
                ),
        ),
      ),
    );
  }
}

/// The lock button: a bordered square on Surface 2.
class _LockButton extends StatelessWidget {
  const _LockButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final edge = context
        .getRSize(48)
        .clamp(kMinInteractiveDimension, double.infinity);
    final radius = BorderRadius.circular(AppSpacing.borderRadiusL);
    return Tooltip(
      message: 'Lock app',
      child: SizedBox(
        key: AppDrawerKeys.lock,
        width: edge,
        height: edge,
        child: Material(
          color: t.inputDecorationTheme.fillColor ?? t.colorScheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(color: t.dividerColor),
          ),
          child: InkWell(
            borderRadius: radius,
            onTap: onPressed,
            child: Center(
              child: AppIcon(
                AppIcons.lock,
                filled: true,
                size: context.getRSize(22),
                color: t.colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// How serious the sync banner is: amber for records waiting, red once
/// something failed.
enum DrawerSyncTone { waiting, failed }

/// The sync banner under the person's tags: an icon, the status line and a
/// chevron. The whole banner opens Sync Issues.
class DrawerSyncBanner extends StatelessWidget {
  const DrawerSyncBanner({
    super.key,
    required this.label,
    required this.tone,
    required this.onTap,
  });

  final String label;
  final DrawerSyncTone tone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final (
      Color fill,
      Color outline,
      Color ink,
      IconData icon,
    ) = switch (tone) {
      DrawerSyncTone.waiting => (
        f.warningTint,
        f.warningOutline,
        f.warning,
        AppIcons.syncProblem,
      ),
      DrawerSyncTone.failed => (
        f.dangerTint,
        f.dangerOutline,
        f.danger,
        AppIcons.alertCircle,
      ),
    };
    final radius = BorderRadius.circular(AppSpacing.borderRadiusL);
    return Material(
      key: AppDrawerKeys.syncBanner,
      color: fill,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: outline),
      ),
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: kMinInteractiveDimension,
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.getRSize(14),
              vertical: context.getRSize(10),
            ),
            child: Row(
              children: [
                AppIcon(
                  icon,
                  filled: true,
                  size: context.getRSize(22),
                  color: ink,
                ),
                SizedBox(width: context.getRSize(10)),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context
                        .boldStyle(14)
                        .copyWith(color: t.colorScheme.onSurface),
                  ),
                ),
                SizedBox(width: context.getRSize(8)),
                AppIcon(
                  AppIcons.chevronRight,
                  size: context.getRSize(20),
                  color: t.textTheme.bodySmall?.color,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The store picker row: store icon, a small "Store" label over the store's
/// name, and an up/down chevron. The whole card opens the store sheet.
class DrawerStoreRow extends StatelessWidget {
  const DrawerStoreRow({
    super.key,
    required this.storeName,
    required this.onTap,
  });

  final String storeName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusL);
    return DecoratedBox(
      key: AppDrawerKeys.storePicker,
      decoration: AppDecorations.card(
        context,
        radius: AppSpacing.borderRadiusL,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: kMinInteractiveDimension,
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: context.getRSize(14),
                vertical: context.getRSize(10),
              ),
              child: Row(
                children: [
                  AppIcon(
                    AppIcons.storefront,
                    filled: true,
                    size: context.getRSize(26),
                    color: t.colorScheme.primary,
                  ),
                  SizedBox(width: context.getRSize(14)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Store',
                          maxLines: 1,
                          style: context
                              .semiBoldStyle(11)
                              .copyWith(color: muted),
                        ),
                        Text(
                          storeName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context
                              .boldStyle(15)
                              .copyWith(color: t.colorScheme.onSurface),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: context.getRSize(8)),
                  AppIcon(
                    AppIcons.unfoldMore,
                    size: context.getRSize(22),
                    color: muted,
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

/// One drawer item. Idle: outlined muted icon + label. Selected: the solid
/// primary-gradient bar with a white filled icon, white label and chevron
/// (#352; PRD #346 — the same on every size).
class DrawerNavTile extends StatelessWidget {
  const DrawerNavTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.isActive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final onPrimary = t.colorScheme.onPrimary;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusL);
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.getRSize(isActive ? 18 : 14),
          vertical: context.getRSize(isActive ? 16 : 11),
        ),
        child: Row(
          children: [
            AppIcon(
              icon,
              filled: isActive,
              size: context.getRSize(24),
              color: isActive ? onPrimary : muted,
            ),
            SizedBox(width: context.getRSize(isActive ? 18 : 16)),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: isActive
                    ? context.boldStyle(16).copyWith(color: onPrimary)
                    : context
                          .mediumStyle(15)
                          .copyWith(color: t.colorScheme.onSurface),
              ),
            ),
            if (isActive) ...[
              SizedBox(width: context.getRSize(8)),
              AppIcon(
                AppIcons.chevronRight,
                size: context.getRSize(22),
                color: onPrimary,
              ),
            ],
          ],
        ),
      ),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: context.getRSize(isActive ? 6 : 2)),
      child: Material(
        type: MaterialType.transparency,
        child: Ink(
          decoration: isActive
              ? AppDecorations.primaryButtonGradient(
                  context,
                  radius: AppSpacing.borderRadiusXL,
                )
              : null,
          child: InkWell(
            key: isActive ? const Key('drawer-selected-item') : null,
            borderRadius: isActive
                ? BorderRadius.circular(AppSpacing.borderRadiusXL)
                : radius,
            onTap: onTap,
            child: row,
          ),
        ),
      ),
    );
  }
}

/// The footer pinned under the list: the Display card (when shown) and the
/// full-width danger-outlined Log Out button.
class DrawerFooter extends StatelessWidget {
  const DrawerFooter({
    super.key,
    required this.onDisplay,
    required this.onLogOut,
    required this.bottomPadding,
  });

  /// Null hides the Display card (roles below CEO find it in Settings).
  final VoidCallback? onDisplay;
  final VoidCallback onLogOut;

  /// The system navigation inset under the footer.
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final side = context.getRSize(14);
    return DecoratedBox(
      key: AppDrawerKeys.footer,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.dividerColor)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          side,
          context.getRSize(12),
          side,
          context.getRSize(12) + bottomPadding,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (onDisplay != null) ...[
              SettingsRow(
                key: AppDrawerKeys.display,
                icon: AppIcons.darkMode,
                tone: IconTileTone.info,
                title: 'Display',
                subtitle: 'Light & dark mode',
                onTap: onDisplay!,
              ),
              SizedBox(height: context.getRSize(10)),
            ],
            _LogOutButton(onPressed: onLogOut),
          ],
        ),
      ),
    );
  }
}

/// Full-width Log Out, outlined in the fixed danger colour. Candidate for a
/// shared "danger outline button" part (no `AppButton` variant draws a
/// transparent fill with a red border).
class _LogOutButton extends StatelessWidget {
  const _LogOutButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final f =
        Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusL);
    final height = context
        .getRSize(54)
        .clamp(kMinInteractiveDimension, double.infinity);
    return SizedBox(
      key: AppDrawerKeys.logOut,
      height: height,
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: f.danger, width: 1.5),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: onPressed,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AppIcon(
                AppIcons.logout,
                size: context.getRSize(22),
                color: f.danger,
              ),
              SizedBox(width: context.getRSize(10)),
              Flexible(
                child: Text(
                  'Log Out',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.boldStyle(16).copyWith(color: f.danger),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
