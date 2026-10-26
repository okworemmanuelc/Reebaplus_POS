import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/listings/listing_quality.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// The listing checklist (#475) inside the Online listing card: four rows,
/// ticked or showing the gap. A gap row is a 48dp tap target that opens the
/// matching editor. [onUseSharedPhoto] non-null adds the "Use the shared
/// photo" button under the photo gap.
class ListingQualityChecklist extends StatelessWidget {
  const ListingQualityChecklist({
    super.key,
    required this.gaps,
    required this.onFix,
    this.onUseSharedPhoto,
    this.sharedPhotoBusy = false,
  });

  final List<ListingGap> gaps;
  final void Function(ListingGap gap) onFix;
  final VoidCallback? onUseSharedPhoto;
  final bool sharedPhotoBusy;

  static const _done = {
    ListingGap.photo: 'Has a photo',
    ListingGap.marketplaceCategory: 'Has a marketplace category',
    ListingGap.description: 'Has an online description',
    ListingGap.onlineStock: 'In stock at an online store',
  };
  static const _todo = {
    ListingGap.photo: 'Add a photo',
    ListingGap.marketplaceCategory: 'Pick a marketplace category',
    ListingGap.description: 'Write an online description',
    ListingGap.onlineStock: 'Not in stock at an online store',
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    Widget row(ListingGap g) {
      final gap = gaps.contains(g);
      final content = ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
        child: Row(
          children: [
            Icon(
              gap ? AppIcons.warning : AppIcons.checkCircle,
              size: 20,
              color: gap ? t.colorScheme.error : t.colorScheme.primary,
            ),
            SizedBox(width: context.getRSize(12)),
            Expanded(
              child: Text(
                gap ? _todo[g]! : _done[g]!,
                style: (gap ? context.boldStyle(14) : context.regularStyle(14))
                    .copyWith(color: gap ? t.colorScheme.onSurface : muted),
              ),
            ),
            if (gap) Icon(AppIcons.chevronRight, color: muted),
          ],
        ),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          gap
              ? InkWell(
                  key: ValueKey('listing-gap-${g.name}'),
                  onTap: () => onFix(g),
                  child: content,
                )
              : KeyedSubtree(key: ValueKey('listing-ok-${g.name}'), child: content),
          if (g == ListingGap.photo && gap && onUseSharedPhoto != null)
            Padding(
              padding: EdgeInsets.only(bottom: context.getRSize(8)),
              child: AppButton(
                key: const ValueKey('use-shared-photo'),
                text: 'Use the shared photo',
                icon: AppIcons.download,
                variant: AppButtonVariant.outline,
                height: kMinInteractiveDimension,
                isLoading: sharedPhotoBusy,
                onPressed: sharedPhotoBusy ? null : onUseSharedPhoto,
              ),
            ),
        ],
      );
    }

    return Column(
      key: const ValueKey('listing-quality-checklist'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.only(top: context.getRSize(12)),
          child: Text(
            gaps.isEmpty ? 'Ready for shoppers' : 'Listing checklist',
            style: context.boldStyle(14).copyWith(color: t.colorScheme.onSurface),
          ),
        ),
        for (final g in ListingGap.values) row(g),
      ],
    );
  }
}
