// mobile_scanner_scan_camera_test.dart
//
// #319 — the production camera's call ordering, over a fake controller (no
// platform camera). `mobile_scanner` ignores a stop that lands while a start
// is in flight, so the camera must queue its calls; and a stop (app
// backgrounded) turns the torch off, so resume must bring the cashier's torch
// back. A read never pauses the camera (#319 follow-up).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:reebaplus_pos/features/pos/services/mobile_scanner_scan_camera.dart';

/// Mirrors the `mobile_scanner` 7.2.0 rules that matter here: stop does
/// nothing unless running, stop turns the torch off, start may take a
/// while ([startGate]) and comes back with the torch off.
class _FakeController extends MobileScannerController {
  _FakeController() {
    value = value.copyWith(
      isInitialized: true,
      isRunning: true,
      torchState: TorchState.off,
    );
  }

  /// When set, a start waits for it before the camera comes on.
  Completer<void>? startGate;
  final List<String> calls = [];

  /// Whether the device camera is actually on.
  bool cameraOn = true;

  @override
  Future<void> start({
    CameraFacing? cameraDirection,
    CameraLensType? cameraLensType,
  }) async {
    calls.add('start');
    value = value.copyWith(isStarting: true);
    await startGate?.future;
    cameraOn = true;
    value = value.copyWith(
      isStarting: false,
      isRunning: true,
      torchState: TorchState.off,
    );
  }

  void _halt(String call) {
    calls.add(call);
    if (!value.isRunning) return;
    cameraOn = false;
    value = value.copyWith(isRunning: false, torchState: TorchState.off);
  }

  @override
  Future<void> stop() async => _halt('stop');

  @override
  Future<void> toggleTorch() async {
    if (!value.isRunning) return;
    calls.add('torch');
    value = value.copyWith(
      torchState: value.torchState == TorchState.on
          ? TorchState.off
          : TorchState.on,
    );
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeController controller;
  late MobileScannerScanCamera camera;

  setUp(() {
    controller = _FakeController();
    camera = MobileScannerScanCamera(controller: controller);
  });

  test('a stop that lands mid-start runs after the start, so the camera '
      'ends off', () async {
    await camera.stop(); // the app went to the background.
    controller.startGate = Completer<void>();
    final resuming = camera.resume();
    final stopping = camera.stop(); // e.g. the auto-lock landing now.
    await pumpEventQueue();
    expect(controller.calls, ['stop', 'start']);

    controller.startGate!.complete();
    await resuming;
    await stopping;

    expect(controller.calls, ['stop', 'start', 'stop']);
    expect(controller.cameraOn, isFalse);
    camera.dispose();
  });

  test('disposing mid-start stops the camera once the start lands, then '
      'releases it', () async {
    await camera.stop();
    controller.startGate = Completer<void>();
    unawaited(camera.resume());
    await pumpEventQueue();
    camera.dispose();

    controller.startGate!.complete();
    await pumpEventQueue();

    expect(controller.calls, ['stop', 'start', 'stop', 'dispose']);
    expect(controller.cameraOn, isFalse);
  });

  test("a stop waits out the preview's own first start", () async {
    // The MobileScanner widget starts the camera itself; that start is not
    // queued, so the camera watches the controller instead.
    controller.value = controller.value.copyWith(
      isRunning: false,
      isStarting: true,
    );
    controller.cameraOn = false;
    final stopping = camera.stop();
    await pumpEventQueue();
    expect(controller.calls, isEmpty);

    controller.cameraOn = true;
    controller.value = controller.value.copyWith(
      isStarting: false,
      isRunning: true,
    );
    await stopping;

    expect(controller.calls, ['stop']);
    expect(controller.cameraOn, isFalse);
    camera.dispose();
  });

  test('the torch comes back on when the app returns, and stays off when '
      'the cashier turned it off', () async {
    await camera.toggleTorch();
    expect(camera.torch.value, isTrue);

    await camera.stop(); // the app went to the background — torch goes off.
    expect(camera.torch.value, isFalse);
    await camera.resume();
    expect(camera.torch.value, isTrue);

    await camera.toggleTorch();
    expect(camera.torch.value, isFalse);
    await camera.stop();
    await camera.resume();
    expect(camera.torch.value, isFalse);
    camera.dispose();
  });
}
