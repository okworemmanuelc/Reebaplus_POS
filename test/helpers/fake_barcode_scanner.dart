// fake_barcode_scanner.dart
//
// #319 — test doubles for the continuous scan session. No camera can run
// headless, so the fake scanner pushes the REAL [BarcodeScanPage] over a
// [FakeScanCamera]; tests feed codes with `camera.read(code)` and see exactly
// what the page does with them (freeze, debounce, count, close, lock).

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:reebaplus_pos/features/pos/services/barcode_scanner.dart';
import 'package:reebaplus_pos/features/pos/services/scan_camera.dart';
import 'package:reebaplus_pos/features/pos/widgets/barcode_scan_page.dart';

/// A camera that "reads" whatever the test passes to [read], and records what
/// the page asked of it.
class FakeScanCamera implements ScanCamera {
  FakeScanCamera({bool? torch = false}) : _torch = ValueNotifier<bool?>(torch);

  final ValueNotifier<bool?> _torch;
  ValueChanged<String>? _onRead;

  /// False after pause/stop/dispose, true again after resume.
  bool isRunning = true;
  bool isDisposed = false;
  int pauseCount = 0;
  int stopCount = 0;

  /// Simulates the camera decoding [code].
  void read(String code) => _onRead!(code);

  /// Simulates the device reporting its torch (null = no torch).
  void reportTorch(bool? isOn) => _torch.value = isOn;

  @override
  Widget buildPreview(BuildContext context, ValueChanged<String> onRead) {
    _onRead = onRead;
    return const ColoredBox(color: Colors.black);
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    isRunning = false;
  }

  @override
  Future<void> resume() async {
    if (!isDisposed) isRunning = true;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    isRunning = false;
  }

  @override
  ValueListenable<bool?> get torch => _torch;

  @override
  Future<void> toggleTorch() async {
    final isOn = _torch.value;
    if (isOn != null) _torch.value = !isOn;
  }

  @override
  void dispose() {
    isDisposed = true;
    isRunning = false;
  }
}

/// A [BarcodeScanner] whose session is the real [BarcodeScanPage] over a
/// [FakeScanCamera]. [code] is the code a test's scan helper feeds by default.
/// The debounce clock is [now], which tests move by hand.
class FakeBarcodeScanner implements BarcodeScanner {
  FakeBarcodeScanner([this.code]);

  final String? code;
  int sessionCount = 0;

  /// The open session's camera (the latest one created).
  FakeScanCamera? camera;

  /// The debounce clock the page reads.
  DateTime now = DateTime(2026, 10, 1, 9);

  void advance(Duration d) => now = now.add(d);

  @override
  Future<void> scanSession(
    BuildContext context, {
    required ScanCodeHandler onCode,
  }) {
    sessionCount++;
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => BarcodeScanPage(
          createCamera: () => camera = FakeScanCamera(),
          onCode: onCode,
          now: () => now,
        ),
      ),
    );
  }
}
