import 'package:flutter/material.dart';

import 'package:reebaplus_pos/features/pos/services/barcode_scanner.dart';
import 'package:reebaplus_pos/features/pos/services/mobile_scanner_scan_camera.dart';
import 'package:reebaplus_pos/features/pos/widgets/barcode_scan_page.dart';

/// The production [BarcodeScanner] (#118). Pushes the full-screen
/// [BarcodeScanPage] over the device camera and keeps it open until the
/// cashier closes it (#319); every read goes to `onCode`.
class MobileScannerBarcodeScanner implements BarcodeScanner {
  const MobileScannerBarcodeScanner();

  @override
  Future<void> scanSession(
    BuildContext context, {
    required ScanCodeHandler onCode,
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        // A factory, not an instance: the page creates the camera once, in
        // initState, however often the route rebuilds this builder.
        builder: (_) => BarcodeScanPage(
          createCamera: MobileScannerScanCamera.new,
          onCode: onCode,
        ),
      ),
    );
  }
}
