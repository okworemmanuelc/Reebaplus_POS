import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// The camera half of a scan session (#319). [BarcodeScanPage] owns the session
/// rules (freeze on a read, debounce, lifecycle, lock, close) and drives the
/// camera only through this interface, so the page runs in widget tests with a
/// fake camera. Production is [MobileScannerScanCamera].
abstract class ScanCamera {
  /// The live preview (plus its aiming overlay and error view). Calls [onRead]
  /// with every decoded value, trimmed and non-empty.
  Widget buildPreview(BuildContext context, ValueChanged<String> onRead);

  /// Freezes the camera while a read is handled.
  Future<void> pause();

  /// Restarts the camera after [pause] or [stop].
  Future<void> resume();

  /// Stops the camera (app backgrounded, app locked).
  Future<void> stop();

  /// Whether the torch is on; `null` when the device reports no torch.
  ValueListenable<bool?> get torch;

  Future<void> toggleTorch();

  /// Releases the camera. Called once, when the scanner page goes away.
  void dispose();
}
