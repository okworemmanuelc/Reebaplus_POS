import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// How a [SectionHeader] looks.
enum SectionHeaderVariant {
  /// ExtraBold 17 title in the main text colour (Home's "Performance
  /// Overview").
  standard,

  /// A smaller, muted group label above a list of rows — SemiBold 15 in the
  /// muted text colour (`phone-ceo-settings-light.png`: "Business",
  /// "Access & Security"; #369).
  group,
}

/// A section title with a muted subtitle (#352 PR 2; "Performance Overview ·
/// Analytics for the selected period" in `phone-landscape-home-dark.png`).
///
/// The two sit on one line when there is room and wrap the subtitle under the
/// title when there is not (upright phone). Display only.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.variant = SectionHeaderVariant.standard,
  });

  final String title;
  final String? subtitle;

  /// Defaults to [SectionHeaderVariant.standard].
  final SectionHeaderVariant variant;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.end,
      spacing: context.getRSize(10),
      runSpacing: context.getRSize(2),
      children: [
        Text(
          title,
          style: switch (variant) {
            SectionHeaderVariant.standard =>
              context
                  .extraBoldStyle(17)
                  .copyWith(color: t.colorScheme.onSurface),
            SectionHeaderVariant.group =>
              context.semiBoldStyle(15).copyWith(color: muted),
          },
        ),
        if (subtitle != null)
          Text(
            subtitle!,
            style: context.regularStyle(13).copyWith(color: muted),
          ),
      ],
    );
  }
}
