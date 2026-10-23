import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';

import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/sales_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// Key of the "Open settings" button (tests tap it).
const ValueKey<String> kCameraPermissionOpenSettingsKey = ValueKey<String>(
  'camera-permission-open-settings',
);

/// Key of the "Not now" button (tests tap it).
const ValueKey<String> kCameraPermissionNotNowKey = ValueKey<String>(
  'camera-permission-not-now',
);

/// Shown when the cashier taps Scan but the app may not use the camera. Offers
/// a shortcut straight to this app's page in the phone's settings, where
/// Camera can be turned on. Returns true for "Open settings", false for "Not
/// now", null when dismissed.
class CameraPermissionSheet extends StatelessWidget {
  const CameraPermissionSheet({super.key});

  static Future<bool?> show(BuildContext context) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const CameraPermissionSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;

    return Container(
      decoration: salesSheetDecoration(context),
      // Scrolls so it never overflows a short (landscape) viewport. Bottom
      // padding is nav-only (deviceBottomPadding), like EditItemModal.
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          context.getRSize(20),
          context.getRSize(12),
          context.getRSize(20),
          context.deviceBottomPadding + context.getRSize(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SalesSheetHandle(),
            SizedBox(height: context.getRSize(20)),
            const Center(
              child: IconTile(
                icon: AppIcons.noPhotography,
                tone: IconTileTone.warning,
                size: 56,
              ),
            ),
            SizedBox(height: context.getRSize(16)),
            Text(
              'Camera is off',
              textAlign: TextAlign.center,
              style: context.screenTitleStyle.copyWith(
                color: t.colorScheme.onSurface,
              ),
            ),
            SizedBox(height: context.getRSize(8)),
            Text(
              'To scan barcodes, this app needs your camera. Tap Open '
              'settings, go to Permissions, and allow Camera. Then come back '
              'and tap Scan again.',
              textAlign: TextAlign.center,
              style: context
                  .regularStyle(14)
                  .copyWith(color: muted, height: 1.4),
            ),
            SizedBox(height: context.getRSize(24)),
            AppButton(
              key: kCameraPermissionOpenSettingsKey,
              text: 'Open settings',
              icon: AppIcons.settings,
              onPressed: () => Navigator.pop(context, true),
            ),
            SizedBox(height: context.getRSize(8)),
            AppButton(
              key: kCameraPermissionNotNowKey,
              text: 'Not now',
              variant: AppButtonVariant.ghost,
              onPressed: () => Navigator.pop(context, false),
            ),
          ],
        ),
      ),
    );
  }
}
