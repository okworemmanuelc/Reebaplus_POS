import 'package:flutter/material.dart';

import 'package:reebaplus_pos/features/pos/services/barcode_scanner.dart';
import 'package:reebaplus_pos/features/pos/services/camera_permission.dart';
import 'package:reebaplus_pos/features/pos/services/mobile_scanner_scan_camera.dart';
import 'package:reebaplus_pos/features/pos/widgets/barcode_scan_page.dart';

/// The production [BarcodeScanner] (#118). Pushes the full-screen
/// [BarcodeScanPage] over the device camera and keeps it open until the
/// cashier closes it (#319); every read goes to `onCode`.
///
/// The camera permission is checked first ([ensureCameraAccess]): when the app
/// may not use the camera, the scanner doesn't open and the "Camera is off"
/// sheet offers a shortcut to the phone's settings instead.
class MobileScannerBarcodeScanner implements BarcodeScanner {
  const MobileScannerBarcodeScanner({
    this.permission = const PermissionHandlerCameraPermission(),
  });

  final CameraPermission permission;

  @override
  Future<void> scanSession(
    BuildContext context, {
    required ScanCodeHandler onCode,
  }) async {
    if (!await ensureCameraAccess(context, permission)) return;
    if (!context.mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        // A factory, not an instance: the page creates the camera once, in
        // initState, however often the route rebuilds this builder.
        builder: (_) => BarcodeScanPage(
          // The same permission, so the camera's "Open settings" uses it too.
          createCamera: () => MobileScannerScanCamera(permission: permission),
          onCode: onCode,
        ),
      ),
    );
  }
}
