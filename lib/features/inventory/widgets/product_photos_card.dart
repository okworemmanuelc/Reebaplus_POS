import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/inventory/widgets/product_detail_cards.dart';

/// Product Details "Photos" card (#474): the cover first (changed on the main
/// photo, not here), then up to four more photos, each with move up / move
/// down / remove, and an Add photo button while there is room. Plain data in;
/// the screen owns reads and writes. Shown only to `products.manage_listing`
/// holders.
class ProductPhotosCard extends StatelessWidget {
  const ProductPhotosCard({
    super.key,
    required this.hasCover,
    required this.cover,
    required this.photos,
    required this.thumbnail,
    required this.maxPhotos,
    this.busy = false,
    this.onAdd,
    this.onMove,
    this.onRemove,
  });

  final bool hasCover;

  /// The cover thumbnail (the main photo), or null when there is none.
  final Widget? cover;

  /// The gallery photo urls after the cover, in order.
  final List<String> photos;
  final Widget Function(BuildContext context, String url) thumbnail;
  final int maxPhotos;
  final bool busy;
  final VoidCallback? onAdd;
  final void Function(int from, int to)? onMove;
  final void Function(String url)? onRemove;

  int get _count => photos.length + (hasCover ? 1 : 0);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final full = photos.length >= maxPhotos - 1;
    return DetailPanel(
      key: const ValueKey('product-photos-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DetailPanelHeader(
            icon: AppIcons.image,
            title: 'Photos',
            subtitle: '$_count of $maxPhotos · shoppers swipe through them',
          ),
          SizedBox(height: context.getRSize(8)),
          _PhotoRow(
            thumb: cover ??
                ColoredBox(
                  color: f.neutralTile,
                  child: Center(
                    child: AppIcon(AppIcons.image,
                        size: context.getRSize(22), color: muted),
                  ),
                ),
            title: 'Cover photo',
            subtitle: hasCover
                ? 'Shown first. Change it on the main photo.'
                : 'No cover yet. Add it on the main photo.',
          ),
          for (var i = 0; i < photos.length; i++)
            _PhotoRow(
              key: ValueKey('product-photo-${i + 2}'),
              thumb: thumbnail(context, photos[i]),
              title: 'Photo ${i + 2}',
              actions: [
                _RowAction(
                  tooltip: 'Move photo ${i + 2} up',
                  icon: AppIcons.arrowUp,
                  onTap: busy || onMove == null || i == 0
                      ? null
                      : () => onMove!(i, i - 1),
                ),
                _RowAction(
                  tooltip: 'Move photo ${i + 2} down',
                  icon: AppIcons.arrowDown,
                  onTap: busy || onMove == null || i == photos.length - 1
                      ? null
                      : () => onMove!(i, i + 1),
                ),
                _RowAction(
                  tooltip: 'Remove photo ${i + 2}',
                  icon: AppIcons.delete,
                  color: t.colorScheme.error,
                  onTap: busy || onRemove == null
                      ? null
                      : () => onRemove!(photos[i]),
                ),
              ],
            ),
          SizedBox(height: context.getRSize(12)),
          if (full)
            Text(
              'This product has the most photos it can have ($maxPhotos).',
              style: context.regularStyle(13).copyWith(color: muted),
            )
          else if (onAdd != null)
            DetailTonalButton(
              key: const ValueKey('product-photos-add'),
              label: busy ? 'Adding photo…' : 'Add photo',
              icon: AppIcons.add,
              fill: t.colorScheme.primary.withValues(alpha: 0.12),
              ink: t.colorScheme.primary,
              onTap: busy ? () {} : onAdd!,
            ),
        ],
      ),
    );
  }
}

class _PhotoRow extends StatelessWidget {
  const _PhotoRow({
    super.key,
    required this.thumb,
    required this.title,
    this.subtitle,
    this.actions = const [],
  });

  final Widget thumb;
  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final size = context.getRSize(56);
    return Padding(
      padding: EdgeInsets.only(top: context.getRSize(8)),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
            child: SizedBox.square(dimension: size, child: thumb),
          ),
          SizedBox(width: context.getRSize(12)),
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
                      .boldStyle(14)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.regularStyle(12).copyWith(color: muted),
                  ),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.color,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return IconButton(
      tooltip: tooltip,
      constraints: const BoxConstraints(
        minWidth: kMinInteractiveDimension,
        minHeight: kMinInteractiveDimension,
      ),
      onPressed: onTap,
      icon: AppIcon(
        icon,
        size: context.getRSize(20),
        color: onTap == null
            ? t.disabledColor
            : (color ?? t.colorScheme.onSurface),
      ),
    );
  }
}
