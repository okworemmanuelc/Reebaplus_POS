import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/tag_pill.dart';

/// One tag on a [ProfileCard] ("PRO", "CEO").
typedef ProfileTag = ({String label, TagPillTone tone});

/// The profile card at the top of settings (#352 PR 2;
/// `phone-ceo-settings-light.png`): a gradient initial tile, the business name
/// (ExtraBold), the person's name (muted) and tags such as PRO / CEO.
///
/// Plain data; the caller resolves the subscription and role labels. With
/// [onTap] the card is one tap target.
class ProfileCard extends StatelessWidget {
  const ProfileCard({
    super.key,
    required this.title,
    this.subtitle,
    this.tags = const [],
    this.logo,
    this.onTap,
  });

  /// Business name; its first letter fills the tile.
  final String title;

  /// The signed-in person's name.
  final String? subtitle;
  final List<ProfileTag> tags;

  /// The business logo, drawn in the tile instead of the initial (#369).
  /// Null, or an image that fails to load, shows the initial.
  final ImageProvider? logo;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final initial = title.trim().isEmpty
        ? '?'
        : title.trim().characters.first.toUpperCase();
    final edge = context.getRSize(56);
    final initialText = Text(
      initial,
      style: context
          .extraBoldStyle(24)
          .copyWith(color: t.colorScheme.onPrimary),
    );
    final content = Padding(
      padding: EdgeInsets.all(context.getRSize(14)),
      child: Row(
        children: [
          Container(
            width: edge,
            height: edge,
            alignment: Alignment.center,
            decoration: AppDecorations.primaryButtonGradient(
              context,
              radius: AppSpacing.borderRadiusL,
            ),
            child: logo == null
                ? initialText
                : ClipRRect(
                    borderRadius: BorderRadius.circular(
                      AppSpacing.borderRadiusL,
                    ),
                    child: Image(
                      image: logo!,
                      width: edge,
                      height: edge,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Center(child: initialText),
                    ),
                  ),
          ),
          SizedBox(width: context.getRSize(14)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context
                      .extraBoldStyle(18)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.regularStyle(14).copyWith(color: muted),
                  ),
              ],
            ),
          ),
          if (tags.isNotEmpty) ...[
            SizedBox(width: context.getRSize(8)),
            Wrap(
              spacing: context.getRSize(6),
              runSpacing: context.getRSize(4),
              children: [
                for (final tag in tags)
                  TagPill(label: tag.label, tone: tag.tone),
              ],
            ),
          ],
        ],
      ),
    );
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: onTap == null
          ? content
          : Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.circular(AppSpacing.borderRadiusXL),
                onTap: onTap,
                child: content,
              ),
            ),
    );
  }
}
