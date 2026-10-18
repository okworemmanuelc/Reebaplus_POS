import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/settings/settings_screen.dart'
    show kSettingsMaxContentWidth;
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

// Redesign parts for the Sync Issues screens and dialogs (#443, PRD #346 Wave 2
// batch C). Plain data in, theme-only styling, 48dp targets. Each one is a
// shared-part candidate; they live here because a Wave 2 feature never adds
// files to the shared folder or imports another feature's widgets.

/// Keys for the Sync Issues screens and dialogs (#443).
abstract final class SyncKeys {
  static const Key topBar = ValueKey<String>('sync-top-bar');
  static const Key back = ValueKey<String>('sync-back');
  static const Key list = ValueKey<String>('sync-list');
  static const Key noAccess = ValueKey<String>('sync-no-access');
  static const Key healthCard = ValueKey<String>('sync-health-card');
  static const Key deferredCard = ValueKey<String>('sync-deferred-card');
  static const Key retryPull = ValueKey<String>('sync-retry-pull');
  static const Key retryAllOrphans = ValueKey<String>('sync-retry-all-orphans');
  static const Key auditToggle = ValueKey<String>('sync-audit-toggle');
  static const Key runAudit = ValueKey<String>('sync-run-audit');
  static const Key projectUrl = ValueKey<String>('sync-project-url');
  static const Key serviceKey = ValueKey<String>('sync-service-key');
  static const Key accessList = ValueKey<String>('sync-access-list');
  static const Key accessIntro = ValueKey<String>('sync-access-intro');
  static const Key resolveInput = ValueKey<String>('sync-resolve-input');

  static Key pendingItem(String id) => ValueKey<String>('sync-pending-$id');
  static Key failedItem(String id) => ValueKey<String>('sync-failed-$id');
  static Key orphanItem(String id) => ValueKey<String>('sync-orphan-$id');
  static Key retryItem(String id) => ValueKey<String>('sync-retry-$id');
  static Key discardItem(String id) => ValueKey<String>('sync-discard-$id');
  static Key roleRow(String slug) => ValueKey<String>('sync-access-role-$slug');
  static Key roleSwitch(String slug) =>
      ValueKey<String>('sync-access-switch-$slug');
}

/// List and form content caps at the settings width (720, raw — the batch-wide
/// rule); under it the gutter is `getRSize(16)`.
double syncGutter(BuildContext context, double width) =>
    math.max(context.getRSize(16), (width - kSettingsMaxContentWidth) / 2);

/// The top bars' height: Home's rule (the theme's 68dp, grown when the scaled
/// header tile or a 48dp control would touch its edges). Repeated because a
/// feature never reaches into another feature's widgets; shared-part
/// candidate.
double syncTopBarHeight(BuildContext context) => math.max(
  kToolbarHeight + 12,
  math.max(context.getRSize(44), kMinInteractiveDimension) +
      context.getRSize(16),
);

/// The solid top bar of the Sync Issues screens: `colorScheme.surface`, a
/// hairline at the bottom and the soft `topBarShadow`, never changing on
/// scroll (PRD #346 decision 4). Carries a 48dp back arrow, as the plain
/// `AppBar` it replaces did.
class SyncTopBar extends StatelessWidget implements PreferredSizeWidget {
  const SyncTopBar({
    super.key,
    required this.height,
    required this.title,
    this.icon = AppIcons.cloudSync,
  });

  final double height;
  final String title;
  final IconData icon;

  /// Builds the bar at the height the current screen needs.
  factory SyncTopBar.of(
    BuildContext context, {
    Key? key,
    required String title,
    IconData icon = AppIcons.cloudSync,
  }) => SyncTopBar(
    key: key ?? SyncKeys.topBar,
    height: syncTopBarHeight(context),
    title: title,
    icon: icon,
  );

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
        leading: IconButton(
          key: SyncKeys.back,
          onPressed: () => Navigator.maybePop(context),
          tooltip: 'Back',
          constraints: const BoxConstraints(
            minWidth: kMinInteractiveDimension,
            minHeight: kMinInteractiveDimension,
          ),
          icon: AppIcon(
            AppIcons.arrowBack,
            size: context.getRSize(24),
            color: t.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

/// A flat card (`AppDecorations.card`) holding [child].
class SyncCard extends StatelessWidget {
  const SyncCard({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding ?? EdgeInsets.all(context.getRSize(14)),
      decoration: AppDecorations.card(context),
      child: child,
    );
  }
}

/// The muted explanation line under a section header.
class SyncHint extends StatelessWidget {
  const SyncHint(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Text(
      text,
      style: context.regularStyle(13).copyWith(color: muted, height: 1.35),
    );
  }
}

/// An empty or failed-to-load line, in a flat card.
class SyncMessageCard extends StatelessWidget {
  const SyncMessageCard(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return SyncCard(
      padding: EdgeInsets.all(context.getRSize(18)),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: context.mediumStyle(14).copyWith(color: muted),
        ),
      ),
    );
  }
}

/// How a fact reads on the Health card.
enum SyncFactTone { normal, ok, bad }

/// One labelled fact: a small icon, the label and the value on the right.
class SyncFactRow extends StatelessWidget {
  const SyncFactRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.tone = SyncFactTone.normal,
  });

  final IconData icon;
  final String label;
  final String value;
  final SyncFactTone tone;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final valueColor = switch (tone) {
      SyncFactTone.normal => t.colorScheme.onSurface,
      SyncFactTone.ok => f.green,
      SyncFactTone.bad => f.danger,
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(top: context.getRSize(2)),
          child: AppIcon(icon, size: context.getRSize(16), color: muted),
        ),
        SizedBox(width: context.getRSize(10)),
        Flexible(
          child: Text(
            label,
            style: context.mediumStyle(13).copyWith(color: muted),
          ),
        ),
        SizedBox(width: context.getRSize(8)),
        Flexible(
          flex: 2,
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: context.boldStyle(13).copyWith(color: valueColor),
          ),
        ),
      ],
    );
  }
}

/// A queue item: a status pill, the action type and a meta line on the first
/// row, then the error text, detail lines, payload preview and [actions].
/// Used for pending, failed and orphaned items alike.
class SyncItemCard extends StatelessWidget {
  const SyncItemCard({
    super.key,
    required this.pillLabel,
    required this.pillTone,
    required this.actionType,
    required this.meta,
    required this.payloadPreview,
    this.errorText,
    this.detailLines = const [],
    this.actions = const [],
  });

  final String pillLabel;
  final TagPillTone pillTone;
  final String actionType;

  /// "attempts: 3" or "archived: ...", muted, at the right of the first row.
  final String meta;
  final String payloadPreview;
  final String? errorText;
  final List<String> detailLines;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Padding(
      padding: EdgeInsets.only(bottom: context.getRSize(10)),
      child: SyncCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: context.getRSize(10),
              runSpacing: context.getRSize(4),
              children: [
                TagPill(label: pillLabel, tone: pillTone),
                Text(
                  actionType,
                  style: context
                      .boldStyle(14)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
                Text(
                  meta,
                  style: context.regularStyle(12).copyWith(color: muted),
                ),
              ],
            ),
            if (errorText != null) ...[
              SizedBox(height: context.getRSize(8)),
              Text(
                errorText!,
                style: context.semiBoldStyle(13).copyWith(color: f.danger),
              ),
            ],
            for (final line in detailLines) ...[
              SizedBox(height: context.getRSize(6)),
              Text(
                line,
                style: context.regularStyle(12).copyWith(color: muted),
              ),
            ],
            SizedBox(height: context.getRSize(8)),
            Text(
              payloadPreview,
              style: context.monoStyle.copyWith(
                fontSize: context.getRFontSize(11),
                color: muted,
              ),
            ),
            if (actions.isNotEmpty) ...[
              SizedBox(height: context.getRSize(10)),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: context.getRSize(8),
                runSpacing: context.getRSize(8),
                children: actions,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A content-width 48dp action button for the tiles and cards (the shared
/// `AppButton` stretches inside a `Wrap`, so it is held to its content).
class SyncAction extends StatelessWidget {
  const SyncAction({
    super.key,
    required this.text,
    required this.onPressed,
    this.variant = AppButtonVariant.secondary,
    this.icon,
    this.isLoading = false,
  });

  final String text;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final IconData? icon;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return IntrinsicWidth(
      child: AppButton(
        text: text,
        onPressed: onPressed,
        variant: variant,
        icon: icon,
        isLoading: isLoading,
        size: AppButtonSize.small,
        height: kMinInteractiveDimension,
        isFullWidth: false,
      ),
    );
  }
}

/// One role on the Sync Issues access screen: a flat card with the cloud-sync
/// tile, the role name, a subtitle and the access switch. A null [onChanged]
/// locks the switch (the CEO row).
class SyncRoleToggleRow extends StatelessWidget {
  const SyncRoleToggleRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.switchKey,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Key? switchKey;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Container(
      constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: AppDecorations.card(context),
      child: Row(
        children: [
          const IconTile(
            icon: AppIcons.cloudSync,
            tone: IconTileTone.info,
            size: 48,
          ),
          SizedBox(width: context.getRSize(14)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context
                      .boldStyle(16)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.regularStyle(13).copyWith(color: muted),
                ),
              ],
            ),
          ),
          SizedBox(width: context.getRSize(8)),
          Switch(
            key: switchKey,
            value: value,
            onChanged: onChanged,
            activeThumbColor: t.colorScheme.primary,
          ),
        ],
      ),
    );
  }
}
