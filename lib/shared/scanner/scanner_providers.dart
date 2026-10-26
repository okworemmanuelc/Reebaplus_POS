import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';

import 'package:reebaplus_pos/shared/scanner/barcode_scanner.dart';
import 'package:reebaplus_pos/shared/scanner/manual_entry_barcode_scanner.dart';
import 'package:reebaplus_pos/shared/scanner/mobile_scanner_barcode_scanner.dart';

/// The active barcode scanner (#118). Production resolves to the camera-backed
/// [MobileScannerBarcodeScanner]; on platforms with no camera plugin (Windows,
/// Linux — #61) it falls back to [ManualEntryBarcodeScanner], so typing or a
/// USB scanner still works. Tests override this with a fake so the scan flow
/// can be driven without a camera.
final barcodeScannerProvider = Provider<BarcodeScanner>(
  (_) => cameraScanningSupported()
      ? const MobileScannerBarcodeScanner()
      : const ManualEntryBarcodeScanner(),
);

/// Units in the active cart — the sum of every line's qty, not the number of
/// lines and not money (#319). Drives the scanner's running "‹N› items in
/// cart" so the cashier sees each confirmed scan land without leaving the
/// camera.
final cartUnitCountProvider = Provider<double>(
  (ref) => ref.watch(cartProvider).totalItems,
);
