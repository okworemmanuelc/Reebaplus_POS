import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/features/pos/services/barcode_scanner.dart';
import 'package:reebaplus_pos/features/pos/services/mobile_scanner_barcode_scanner.dart';

/// The active barcode scanner (#118). Production resolves to the camera-backed
/// [MobileScannerBarcodeScanner]; tests override this with a fake so the scan
/// flow can be driven without a camera.
final barcodeScannerProvider = Provider<BarcodeScanner>(
  (_) => const MobileScannerBarcodeScanner(),
);
