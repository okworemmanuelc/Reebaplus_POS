import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// The pale primary coach banner above a product grid ("Tap a product to add
/// it…, or tap and hold to choose a quantity"), with a ✕ that dismisses it.
///
/// The same banner POS and Receive Stock draw privately (one combined tip per
/// screen, PR #148); this is the shared form, first used by Request Stock
/// (#380). The ✕ is a full 48dp tap target. The caller owns when it shows and
/// what a dismissal records (`UiHintService`).
class CoachHintBanner extends StatelessWidget {
  const CoachHintBanner({
    super.key,
    required this.message,
    required this.onDismiss,
  });

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final primary = t.colorScheme.primary;
    final tint =
        t.extension<AppSchemeColors>()?.primaryTint ??
        primary.withValues(alpha: 0.12);
    return Container(
      padding: EdgeInsetsDirectional.only(start: context.getRSize(12)),
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
      ),
      child: Row(
        children: [
          Icon(AppIcons.infoCircle, size: context.getRSize(16), color: primary),
          SizedBox(width: context.getRSize(12)),
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: context.getRSize(12)),
              child: Text(
                message,
                style: t.textTheme.bodyMedium?.copyWith(color: primary),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Dismiss',
            icon: Icon(
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
