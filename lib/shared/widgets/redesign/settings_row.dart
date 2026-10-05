import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';

/// A settings / menu row card (#352 PR 2; `phone-ceo-settings-light.png`): a
/// fixed-colour icon tile, a bold title, a muted subtitle and a chevron. The
/// whole card is one tap target (at least 48dp tall at any size).
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.icon,
    required this.tone,
    required this.title,
    this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final IconTileTone tone;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    return DecoratedBox(
      decoration: AppDecorations.card(context),
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
              padding: EdgeInsets.all(context.getRSize(14)),
              child: Row(
                children: [
                  IconTile(icon: icon, tone: tone, size: 48),
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
                        if (subtitle != null)
                          Text(
                            subtitle!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: context
                                .regularStyle(13)
                                .copyWith(color: muted),
                          ),
                      ],
                    ),
                  ),
                  SizedBox(width: context.getRSize(8)),
                  AppIcon(
                    AppIcons.chevronRight,
                    color: muted,
                    size: context.getRSize(22),
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
