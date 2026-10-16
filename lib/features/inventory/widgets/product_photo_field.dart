import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';

/// The one product-photo picker shared by Add Product and Update Product (#78,
/// PRD #76) — a tappable square that shows, in priority order, a freshly picked
/// image ([pendingBytes]), the cached local file ([existingPath]), or a clean
/// "Add photo" placeholder. The photo is optional, so a photo-less product
/// always renders the placeholder and never blocks saving.
///
/// Pure presentation: the owning screen holds the picked bytes / cached path
/// and does the upload on save (via ProductImageService). Mirrors the design
/// system idiom of `_LogoSection` (business_info_screen) — every size via
/// `context.getRSize`, every font via `context.getRFontSize`, colours resolved
/// through the theme so it stays responsive and theme-aware.
class ProductPhotoField extends StatelessWidget {
  const ProductPhotoField({
    super.key,
    this.pendingBytes,
    this.existingPath,
    required this.onPick,
    this.onRemove,
  });

  /// A freshly picked image not yet saved — takes precedence over [existingPath].
  final Uint8List? pendingBytes;

  /// Path to the cached local file for an already-saved photo (edit flow).
  final String? existingPath;

  /// Open the picker.
  final VoidCallback onPick;

  /// Clear the current photo. Null hides the remove affordance.
  final VoidCallback? onRemove;

  bool get _hasImage =>
      pendingBytes != null ||
      (existingPath != null && File(existingPath!).existsSync());

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final tint =
        t.extension<AppSchemeColors>()?.primaryTint ??
        t.colorScheme.primary.withValues(alpha: 0.12);
    final box = context.getRSize(80);
    final radius = BorderRadius.circular(AppSpacing.borderRadiusM);

    Widget preview;
    if (pendingBytes != null) {
      preview = Image.memory(
        pendingBytes!,
        width: box,
        height: box,
        fit: BoxFit.cover,
      );
    } else if (existingPath != null && File(existingPath!).existsSync()) {
      preview = Image.file(
        File(existingPath!),
        width: box,
        height: box,
        fit: BoxFit.cover,
      );
    } else {
      preview = AppIcon(
        AppIcons.image,
        size: context.getRSize(28),
        color: muted,
      );
    }

    return Row(
      children: [
        Container(
          width: box,
          height: box,
          alignment: Alignment.center,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: t.inputDecorationTheme.fillColor ?? t.colorScheme.surface,
            borderRadius: radius,
            border: Border.all(color: t.dividerColor),
          ),
          child: preview,
        ),
        SizedBox(width: context.getRSize(16)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 48dp targets (#392): the pick pill and the remove link.
              Material(
                color: tint,
                borderRadius: radius,
                child: InkWell(
                  borderRadius: radius,
                  onTap: onPick,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: kMinInteractiveDimension,
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: context.getRSize(16),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AppIcon(
                            AppIcons.image,
                            size: context.getRSize(18),
                            color: t.colorScheme.primary,
                          ),
                          SizedBox(width: context.getRSize(8)),
                          Text(
                            _hasImage ? 'Change photo' : 'Add photo',
                            style: context
                                .semiBoldStyle(14)
                                .copyWith(color: t.colorScheme.primary),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (_hasImage && onRemove != null)
                InkWell(
                  borderRadius: radius,
                  onTap: onRemove,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: kMinInteractiveDimension,
                    ),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      widthFactor: 1,
                      child: Text(
                        'Remove photo',
                        style: context
                            .semiBoldStyle(14)
                            .copyWith(color: f.danger),
                      ),
                    ),
                  ),
                ),
              SizedBox(height: context.getRSize(4)),
              Text(
                'Optional — shown on the product’s details.',
                style: context.regularStyle(12).copyWith(color: muted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
