import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:reebaplus_pos/features/pos/services/camera_permission.dart';
import 'package:reebaplus_pos/features/pos/services/scan_camera.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// The production [ScanCamera], backed by the device camera via
/// `mobile_scanner` (#118, continuous since #319).
///
/// Camera runtime permission is requested by `mobile_scanner` itself when the
/// preview starts; a denial surfaces through the error view rather than
/// crashing. The platform manifests declare the permission (Android `CAMERA`,
/// iOS `NSCameraUsageDescription`).
///
/// Because we supply the controller, `mobile_scanner` does NOT follow the app
/// lifecycle on its own — [BarcodeScanPage] stops and resumes it (#319).
///
/// Camera calls run one after another, each waiting for any start still in
/// flight: `mobile_scanner` ignores a stop that lands mid-start, so an
/// un-queued stop (e.g. an auto-lock right after the app comes back) would
/// leave the camera running with no screen over it.
class MobileScannerScanCamera implements ScanCamera {
  MobileScannerScanCamera({
    @visibleForTesting MobileScannerController? controller,
    CameraPermission permission = const PermissionHandlerCameraPermission(),
  }) : _permission = permission,
       _controller =
          controller ??
          // DetectionSpeed.normal, not noDuplicates (#319): the scanner stays
          // open, so the same product must scan again after the debounce —
          // noDuplicates would swallow a repeat of the last code for good.
          // [ScanGate] handles repeats.
          MobileScannerController(detectionSpeed: DetectionSpeed.normal) {
    _controller.addListener(_syncTorch);
  }

  final MobileScannerController _controller;

  /// Opens the phone's settings from the "camera is off" view.
  final CameraPermission _permission;

  final ValueNotifier<bool?> _torch = ValueNotifier<bool?>(null);

  /// The cashier's torch choice. A stop (app backgrounded) turns the torch
  /// off; [resume] turns it back on when this is set.
  bool _wantsTorch = false;

  bool _isDisposed = false;

  /// The tail of the camera-call queue (see the class doc).
  Future<void> _queue = Future<void>.value();

  void _syncTorch() {
    _torch.value = switch (_controller.value.torchState) {
      TorchState.unavailable => null,
      TorchState.on => true,
      TorchState.off || TorchState.auto => false,
    };
  }

  /// Runs [op] after every earlier camera call and after the preview's own
  /// first start has settled. Never throws.
  Future<void> _enqueue(String label, Future<void> Function() op) {
    return _queue = _queue.then((_) async {
      try {
        await _startSettled();
        await op();
      } catch (e) {
        debugPrint('[MobileScannerScanCamera] $label error: $e');
      }
    });
  }

  /// Waits out a start the [MobileScanner] widget began itself (its first
  /// start is not in the queue).
  Future<void> _startSettled() async {
    if (!_controller.value.isStarting) return;
    final settled = Completer<void>();
    void check() {
      if (!_controller.value.isStarting && !settled.isCompleted) {
        settled.complete();
      }
    }

    _controller.addListener(check);
    await settled.future;
    _controller.removeListener(check);
  }

  @override
  ValueListenable<bool?> get torch => _torch;

  @override
  Widget buildPreview(BuildContext context, ValueChanged<String> onRead) {
    return MobileScanner(
      controller: _controller,
      onDetect: (capture) {
        for (final barcode in capture.barcodes) {
          final value = barcode.rawValue?.trim();
          if (value != null && value.isNotEmpty) {
            onRead(value);
            return;
          }
        }
      },
      errorBuilder: (context, error) => ScannerErrorView(
        isPermissionDenied:
            error.errorCode == MobileScannerErrorCode.permissionDenied,
        onOpenSettings: () => unawaited(_permission.openSettings()),
      ),
      overlayBuilder: (context, constraints) => const _ScannerHint(),
    );
  }

  @override
  Future<void> resume() => _enqueue('resume', () async {
    final state = _controller.value;
    // Disposed, not started yet (the widget starts it), or the camera can't
    // run (e.g. permission denied — keep the error view, don't re-prompt).
    if (_isDisposed || !state.isInitialized || state.error != null) return;
    await _controller.start();
    final started = _controller.value;
    if (_wantsTorch &&
        !_isDisposed &&
        started.isRunning &&
        started.torchState == TorchState.off) {
      await _controller.toggleTorch();
    }
  });

  @override
  Future<void> stop() => _enqueue('stop', _controller.stop);

  @override
  Future<void> toggleTorch() async {
    final state = _controller.value;
    if (!state.isRunning || state.torchState == TorchState.unavailable) return;
    _wantsTorch = state.torchState != TorchState.on;
    try {
      await _controller.toggleTorch();
    } catch (e) {
      debugPrint('[MobileScannerScanCamera] torch error: $e');
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _controller.removeListener(_syncTorch);
    _torch.dispose();
    // Queued, so a start still in flight lands first and is then stopped —
    // disposing alone can't stop a camera whose start hasn't replied yet.
    unawaited(
      _enqueue('dispose', () async {
        await _controller.stop();
        await _controller.dispose();
      }),
    );
  }
}

/// Shown when the camera cannot start. Keeps the flow calm (invariant #7)
/// instead of surfacing a raw error. When the camera permission is off (it was
/// turned off while the app was open, after the pre-open check in
/// `MobileScannerBarcodeScanner`) it also offers a shortcut to the phone's
/// settings.
class ScannerErrorView extends StatelessWidget {
  const ScannerErrorView({
    super.key,
    required this.isPermissionDenied,
    required this.onOpenSettings,
  });

  final bool isPermissionDenied;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    // Material fallback icon.
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(AppIcons.noPhotography, color: Colors.white, size: 40),
            const SizedBox(height: 16),
            Text(
              isPermissionDenied
                  ? 'Camera is off for this app. Turn it on in your phone '
                        'settings, then close and reopen the scanner.'
                  : 'Camera unavailable. Allow camera access for this app in '
                        'your device settings to scan barcodes.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
            if (isPermissionDenied) ...[
              const SizedBox(height: 24),
              AppButton(
                text: 'Open settings',
                icon: AppIcons.settings,
                isFullWidth: false,
                onPressed: onOpenSettings,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A simple centred aiming frame + hint over the live preview.
class _ScannerHint extends StatelessWidget {
  const _ScannerHint();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 240,
          height: 140,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white70, width: 2),
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'Point the camera at a barcode',
          style: TextStyle(color: Colors.white, fontSize: 14),
        ),
      ],
    );
  }
}
