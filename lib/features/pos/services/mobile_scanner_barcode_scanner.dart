import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:reebaplus_pos/features/pos/services/barcode_scanner.dart';

/// The production [BarcodeScanner], backed by the device camera via
/// `mobile_scanner` (#118). Pushes a full-screen one-shot scanner page and
/// returns the first decoded barcode (or `null` if the user closed it).
///
/// Camera runtime permission is requested by `mobile_scanner` itself when the
/// preview starts; a denial surfaces through the page's error view rather than
/// crashing. The platform manifests declare the permission (Android
/// `CAMERA`, iOS `NSCameraUsageDescription`).
class MobileScannerBarcodeScanner implements BarcodeScanner {
  const MobileScannerBarcodeScanner();

  @override
  Future<String?> scanOnce(BuildContext context) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        fullscreenDialog: true,
        builder: (_) => const BarcodeScanPage(),
      ),
    );
  }
}

/// Full-screen one-shot camera scanner. Pops with the first non-empty barcode
/// value, or `null` when the user closes it. Continuous scanning is out of
/// scope (#118) — the page closes the moment a code is read.
class BarcodeScanPage extends StatefulWidget {
  const BarcodeScanPage({super.key});

  @override
  State<BarcodeScanPage> createState() => _BarcodeScanPageState();
}

class _BarcodeScanPageState extends State<BarcodeScanPage> {
  // noDuplicates so a barcode held in-frame does not fire repeatedly before we
  // pop; we still guard with [_handled] so the very first hit wins exactly once.
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    String? code;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim();
      if (value != null && value.isNotEmpty) {
        code = value;
        break;
      }
    }
    if (code == null) return;
    _handled = true; // one-shot: first successful read closes the scanner.
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Scan barcode'),
        leading: IconButton(
          icon: Icon(FontAwesomeIcons.xmark.data),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: MobileScanner(
        controller: _controller,
        onDetect: _onDetect,
        errorBuilder: (context, error) => const _ScannerError(),
        overlayBuilder: (context, constraints) => const _ScannerHint(),
      ),
    );
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
