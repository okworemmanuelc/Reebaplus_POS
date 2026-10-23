import 'package:flutter/widgets.dart';

/// Handles one scanned barcode inside a scan session (#319). [scannerContext]
/// is the scanner page's own context, so anything the handler shows (the
/// quantity sheet, the "Which one?" list, messages, Add Product) appears OVER
/// the camera and closing it lands back on the live scanner. The session
/// ignores other reads until the returned future completes.
typedef ScanCodeHandler =
    Future<void> Function(BuildContext scannerContext, String code);

/// A thin seam over the device camera barcode scanner (#118).
///
/// Continuous by contract (#319, ADR 0017 amendment): [scanSession] opens the
/// scanner and keeps it open until the cashier closes it (✕ or system back).
/// Every read is handed to `onCode` — trimmed and non-empty — and other reads
/// are ignored while the handler runs; the session then carries on scanning.
///
/// The camera lives behind this interface so widget/unit tests inject a fake
/// instead of driving a real camera, which cannot run headless. The production
/// implementation is [MobileScannerBarcodeScanner].
abstract class BarcodeScanner {
  /// Presents the scanner and completes when it closes. Each scanned code is
  /// passed to [onCode] with the scanner page's context.
  Future<void> scanSession(
    BuildContext context, {
    required ScanCodeHandler onCode,
  });
}
