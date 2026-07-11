import 'package:flutter/widgets.dart';

/// A thin seam over the device camera barcode scanner (#118).
///
/// One-shot by contract: [scanOnce] opens the camera, returns the FIRST decoded
/// barcode, then closes the scanner. A `null` result means the user dismissed
/// the scanner (or camera permission was denied) without a scan — callers treat
/// it as "cancelled" and do nothing.
///
/// The camera lives behind this interface so widget/unit tests inject a fake
/// (returning a canned code) instead of driving a real camera, which cannot run
/// headless. The production implementation is [MobileScannerBarcodeScanner].
abstract class BarcodeScanner {
  /// Presents a one-shot camera scanner and completes with the first scanned
  /// barcode's raw value (trimmed, non-empty), or `null` if nothing was scanned.
  Future<String?> scanOnce(BuildContext context);
}
