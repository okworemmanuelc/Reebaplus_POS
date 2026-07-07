import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

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
    final theme = Theme.of(context);
    final box = context.getRSize(80);

    Widget preview;
    if (pendingBytes != null) {
      preview =
          Image.memory(pendingBytes!, width: box, height: box, fit: BoxFit.cover);
    } else if (existingPath != null && File(existingPath!).existsSync()) {
      preview = Image.file(
        File(existingPath!),
        width: box,
        height: box,
        fit: BoxFit.cover,
      );
    } else {
      preview = Icon(
        FontAwesomeIcons.image.data,
        size: context.getRSize(26),
        color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
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
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: theme.dividerColor),
          ),
          child: preview,
        ),
        SizedBox(width: context.getRSize(16)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: onPick,
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.getRSize(16),
                    vertical: context.getRSize(10),
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _hasImage ? 'Change photo' : 'Add photo',
                    style: theme.textTheme.labelLarge
                        ?.copyWith(color: theme.colorScheme.primary),
                  ),
                ),
              ),
              if (_hasImage && onRemove != null) ...[
                SizedBox(height: context.getRSize(8)),
                GestureDetector(
                  onTap: onRemove,
                  child: Text(
                    'Remove photo',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
              ],
              SizedBox(height: context.getRSize(6)),
              Text(
                'Optional — shown on the product’s details.',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
