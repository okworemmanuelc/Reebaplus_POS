import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:reebaplus_pos/features/pos/services/scan_camera.dart';

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
class MobileScannerScanCamera implements ScanCamera {
  MobileScannerScanCamera() {
    _controller.addListener(_syncTorch);
  }

  // DetectionSpeed.normal, not noDuplicates (#319): the scanner stays open, so
  // the same product must scan again after the debounce — noDuplicates would
  // swallow a repeat of the last code for good. [ScanGate] handles repeats.
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
  );

  final ValueNotifier<bool?> _torch = ValueNotifier<bool?>(null);

  void _syncTorch() {
    _torch.value = switch (_controller.value.torchState) {
      TorchState.unavailable => null,
      TorchState.on => true,
      TorchState.off || TorchState.auto => false,
    };
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
      errorBuilder: (context, error) => const _ScannerError(),
      overlayBuilder: (context, constraints) => const _ScannerHint(),
    );
  }

  @override
  Future<void> pause() async {
    try {
      await _controller.pause();
    } catch (e) {
      debugPrint('[MobileScannerScanCamera] pause error: $e');
    }
  }

  @override
  Future<void> resume() async {
    final state = _controller.value;
    // Not started yet (the widget starts it), or the camera can't run (e.g.
    // permission denied — keep the error view, don't re-prompt).
    if (!state.isInitialized || state.error != null) return;
    try {
      await _controller.start();
    } catch (e) {
      debugPrint('[MobileScannerScanCamera] resume error: $e');
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _controller.stop();
    } catch (e) {
      debugPrint('[MobileScannerScanCamera] stop error: $e');
    }
  }

  @override
  Future<void> toggleTorch() async {
    try {
      await _controller.toggleTorch();
    } catch (e) {
      debugPrint('[MobileScannerScanCamera] torch error: $e');
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_syncTorch);
    _torch.dispose();
    // Disposing the controller stops the camera and releases it.
    _controller.dispose();
  }
}

/// Shown when the camera cannot start — most commonly a denied camera
/// permission. Keeps the flow calm (invariant #7) instead of surfacing a raw
/// error.
class _ScannerError extends StatelessWidget {
  const _ScannerError();

  @override
  Widget build(BuildContext context) {
    // Material fallback icon — font_awesome_flutter has no camera-slash glyph.
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.no_photography, color: Colors.white, size: 40),
            SizedBox(height: 16),
            Text(
              'Camera unavailable. Allow camera access for this app in your '
              'device settings to scan barcodes.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white),
            ),
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
