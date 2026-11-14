import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart' show ImageSource;

import 'package:reebaplus_pos/core/services/product_image_service.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';

/// Keys for tests.
abstract final class PhotoSourceSheetKeys {
  static const sheet = Key('photo-source-sheet');
  static const camera = Key('photo-source-camera');
  static const gallery = Key('photo-source-gallery');
}

/// Asks where a product photo comes from (#763): "Take photo" with the camera
/// or "Choose from gallery". Resolves to the source tapped, or null when the
/// sheet is dismissed. Where the device has no camera to offer (desktop) it
/// skips the question and resolves to the gallery.
///
/// Modelled on Home's Record Payment chooser: handle, title, one card per
/// option, opened on the caller's navigator.
Future<ImageSource?> choosePhotoSource(BuildContext context) async {
  if (!ProductImageService.cameraAvailable) return ImageSource.gallery;
  return showModalBottomSheet<ImageSource>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const PhotoSourceSheet(),
  );
}

/// The sheet's body: handle, "Add Photo", camera and gallery options.
class PhotoSourceSheet extends StatelessWidget {
  const PhotoSourceSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final gutter = context.getRSize(20);
    return ConstrainedBox(
      key: PhotoSourceSheetKeys.sheet,
      constraints: BoxConstraints(maxHeight: context.screenHeight * 0.9),
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
            Center(
              child: Container(
                width: context.getRSize(40),
                height: context.getRSize(4),
                decoration: BoxDecoration(
                  color: t.dividerColor,
                  borderRadius: BorderRadius.circular(AppSpacing.borderRadiusS),
                ),
              ),
            ),
            SizedBox(height: context.getRSize(16)),
            Text(
              'Add Photo',
              style: context.screenTitleStyle.copyWith(
                color: t.colorScheme.onSurface,
              ),
            ),
            SizedBox(height: context.getRSize(2)),
            Text(
              'Where is the photo coming from?',
              style: context.semiBoldStyle(13).copyWith(color: muted),
            ),
            SizedBox(height: context.getRSize(16)),
            _SourceOption(
              key: PhotoSourceSheetKeys.camera,
              icon: AppIcons.camera,
              tone: IconTileTone.info,
              title: 'Take photo',
              subtitle: 'Use the camera now',
              onTap: () => Navigator.of(context).pop(ImageSource.camera),
            ),
            SizedBox(height: context.getRSize(10)),
            _SourceOption(
              key: PhotoSourceSheetKeys.gallery,
              icon: AppIcons.image,
              tone: IconTileTone.green,
              title: 'Choose from gallery',
              subtitle: 'A photo already on this device',
              onTap: () => Navigator.of(context).pop(ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
  }
}

/// One option: icon tile, title, subtitle and chevron. The whole card taps.
class _SourceOption extends StatelessWidget {
  const _SourceOption({
    super.key,
    required this.icon,
    required this.tone,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final IconTileTone tone;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppSpacing.borderRadiusXL),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: kMinInteractiveDimension,
            ),
            child: Padding(
              padding: EdgeInsets.all(context.getRSize(14)),
              child: Row(
                children: [
                  IconTile(icon: icon, tone: tone, size: 44),
                  SizedBox(width: context.getRSize(14)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context
                              .boldStyle(15)
                              .copyWith(color: t.colorScheme.onSurface),
                        ),
                        SizedBox(height: context.getRSize(2)),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context
                              .regularStyle(12)
                              .copyWith(color: muted),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: context.getRSize(8)),
                  Icon(
                    AppIcons.chevronRight,
                    size: context.getRSize(20),
                    color: muted,
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
