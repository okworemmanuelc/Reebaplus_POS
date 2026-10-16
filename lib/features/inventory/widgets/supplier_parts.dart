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
