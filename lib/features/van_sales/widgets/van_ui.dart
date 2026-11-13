import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// Small look-only building blocks shared by the Van Sales screens (#810), so
/// every card, row, banner and tonal action reads the same everywhere. No
/// logic lives here.

/// The one card surface: flat card recipe, optional padding.
class VanCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;

  const VanCard({super.key, required this.child, this.padding});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding ?? EdgeInsets.all(context.getRSize(16)),
      decoration: AppDecorations.card(context),
      child: child,
    );
  }
}

/// A card header: bold title, optional quiet caption under it.
class VanSectionHeader extends StatelessWidget {
  final String title;
  final String? caption;

  const VanSectionHeader({super.key, required this.title, this.caption});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: context.getRSize(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: t.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (caption != null) ...[
            SizedBox(height: context.getRSize(2)),
            Text(caption!, style: t.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

/// Label on the left, figure right-aligned on the right.
class VanKvRow extends StatelessWidget {
  final String label;
  final String value;
  final bool strong;
  final Color? valueColor;

  const VanKvRow({
    super.key,
    required this.label,
    required this.value,
    this.strong = false,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(4)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: t.textTheme.bodyMedium?.copyWith(
                color: strong ? t.colorScheme.onSurface : subtext,
                fontWeight: strong ? FontWeight.w700 : null,
              ),
            ),
          ),
          SizedBox(width: context.getRSize(12)),
          Text(
            value,
            textAlign: TextAlign.right,
            style: t.textTheme.bodyMedium?.copyWith(
              color: valueColor ?? t.colorScheme.onSurface,
              fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// A slim info banner: icon + one short note on a soft tint.
class VanInfoBanner extends StatelessWidget {
  final String text;
  final IconData icon;

  const VanInfoBanner({
    super.key,
    required this.text,
    this.icon = AppIcons.infoCircle,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final info = t.extension<AppSemanticColors>()!.info;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(12),
        vertical: context.getRSize(10),
      ),
      decoration: BoxDecoration(
        color: info.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: context.getRSize(14), color: info),
          SizedBox(width: context.getRSize(10)),
          Expanded(child: Text(text, style: t.textTheme.bodySmall)),
        ],
      ),
    );
  }
}

/// Tonal action with an icon beside a one-line label (shrinks, never wraps).
class VanTonalButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  const VanTonalButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final enabled = onPressed != null;
    final color = enabled
        ? t.colorScheme.primary
        : t.colorScheme.onSurface.withValues(alpha: 0.38);
    return Material(
      color: t.colorScheme.primary.withValues(alpha: enabled ? 0.12 : 0.05),
      borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
        child: Container(
          constraints: BoxConstraints(minHeight: context.getRSize(48)),
          padding: EdgeInsets.symmetric(horizontal: context.getRSize(10)),
          alignment: Alignment.center,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: context.getRSize(16), color: color),
                SizedBox(width: context.getRSize(8)),
                Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  style: t.textTheme.labelLarge?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
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

/// Tonal tile: icon above a one-line label, no outline.
class VanTonalTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  const VanTonalTile({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final enabled = onPressed != null;
    final color = enabled
        ? t.colorScheme.primary
        : t.colorScheme.onSurface.withValues(alpha: 0.38);
    return Material(
      color: t.colorScheme.primary.withValues(alpha: enabled ? 0.12 : 0.05),
      borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.getRSize(4),
            vertical: context.getRSize(10),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: context.getRSize(20), color: color),
              SizedBox(height: context.getRSize(4)),
              SizedBox(
                width: double.infinity,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    style: t.textTheme.labelMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
