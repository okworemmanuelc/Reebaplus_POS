import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/pos/widgets/camera_permission_sheet.dart';

/// Whether the app may use the camera, as far as the barcode scanner cares.
enum CameraAccess {
  /// Allowed — the scanner can open.
  granted,

  /// Not allowed yet, but the phone's own prompt can still ask.
  askable,

  /// Turned off in a way only the phone's settings can undo ("Don't allow"
  /// twice, "Don't ask again", or a device restriction).
  blocked,
}

/// A thin seam over the phone's camera permission, so tests can drive the
/// "camera is off" path without a real permission prompt. Production is
/// [PermissionHandlerCameraPermission].
abstract class CameraPermission {
  Future<CameraAccess> status();

  /// Shows the phone's own camera prompt and returns what the user chose.
  Future<CameraAccess> request();

  /// Opens this app's page in the phone's settings. False when it couldn't.
  Future<bool> openSettings();
}

/// The production [CameraPermission], backed by `permission_handler`.
class PermissionHandlerCameraPermission implements CameraPermission {
  const PermissionHandlerCameraPermission();

  @override
  Future<CameraAccess> status() async => _map(await Permission.camera.status);

  @override
  Future<CameraAccess> request() async =>
      _map(await Permission.camera.request());

  @override
  Future<bool> openSettings() => openAppSettings();

  static CameraAccess _map(PermissionStatus status) {
    if (status.isGranted || status.isLimited) return CameraAccess.granted;
    if (status.isPermanentlyDenied || status.isRestricted) {
      return CameraAccess.blocked;
    }
    return CameraAccess.askable;
  }
}

/// Makes sure the scanner may use the camera before it opens. Returns true
/// when it may.
///
/// Not allowed yet → the phone's own prompt asks first. Still not allowed →
/// the "Camera is off" sheet offers a shortcut to this app's settings page;
/// the cashier turns Camera on there, comes back and taps Scan again.
///
/// If the permission can't be read at all, this returns true and leaves it to
/// the scanner, which asks for the camera itself and shows its own error view.
Future<bool> ensureCameraAccess(
  BuildContext context,
  CameraPermission permission,
) async {
  try {
    var access = await permission.status();
    if (access == CameraAccess.askable) access = await permission.request();
    if (access == CameraAccess.granted) return true;
  } catch (e) {
    debugPrint('[ensureCameraAccess] permission check failed: $e');
    return true;
  }

  if (!context.mounted) return false;
  final openSettings = await CameraPermissionSheet.show(context);
  if (openSettings != true) return false;

  var opened = false;
  try {
    opened = await permission.openSettings();
  } catch (e) {
    debugPrint('[ensureCameraAccess] open settings failed: $e');
  }
  if (!opened && context.mounted) {
    AppNotification.showError(
      context,
      "Couldn't open settings. Open your phone's Settings, find Reebaplus "
      'POS, and allow Camera.',
    );
  }
  return false;
}
