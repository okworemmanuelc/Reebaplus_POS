import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';
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
    final border = t.dividerColor;
    final text = t.colorScheme.onSurface;
    final primary = t.colorScheme.primary;

    return Container(
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 30,
            offset: const Offset(0, -10),
          ),
        ],
      ),
      // Scrolls so it never overflows a short (landscape) viewport. Bottom
      // padding is nav-only (deviceBottomPadding), like EditItemModal.
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          context.getRSize(24),
          context.getRSize(16),
          context.getRSize(24),
          context.deviceBottomPadding + context.getRSize(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drag Handle
            Center(
              child: Container(
                width: context.getRSize(40),
                height: context.getRSize(4),
                decoration: BoxDecoration(
                  color: border.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            SizedBox(height: context.getRSize(24)),
            Center(
              child: Container(
                width: context.getRSize(56),
                height: context.getRSize(56),
                decoration: BoxDecoration(
                  color: primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  FontAwesomeIcons.camera.data,
                  color: primary,
                  size: context.getRSize(24),
                ),
              ),
            ),
            SizedBox(height: context.getRSize(20)),
            Text(
              'Camera is off',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.getRFontSize(20),
                fontWeight: FontWeight.w900,
                color: text,
                letterSpacing: -0.5,
              ),
            ),
            SizedBox(height: context.getRSize(10)),
            Text(
              'To scan barcodes, this app needs your camera. Tap Open '
              'settings, go to Permissions, and allow Camera. Then come back '
              'and tap Scan again.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.getRFontSize(14),
                color: text.withValues(alpha: 0.7),
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
            SizedBox(height: context.getRSize(28)),
            AppButton(
              key: kCameraPermissionOpenSettingsKey,
              text: 'Open settings',
              icon: FontAwesomeIcons.gear.data,
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
