import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/pos/services/barcode_scanner.dart';
import 'package:reebaplus_pos/features/pos/services/scan_camera.dart';
import 'package:reebaplus_pos/features/pos/services/scan_gate.dart';
import 'package:reebaplus_pos/features/pos/widgets/scan_cart_count.dart';

/// The full-screen scan session (#319). Stays open until the cashier closes it
/// (✕ or system back) and lands back on the till with the cart intact.
///
/// On each read: a short buzz, the camera freezes, [onCode] runs with THIS
/// page's context (so its sheets and messages sit over the camera), then the
/// camera resumes. Reads while a code is being handled are ignored, and the
/// code just handled is ignored for [sameCodeDebounce] after resuming
/// ([ScanGate]).
///
/// The camera never runs behind the app: it stops when the app is backgrounded
/// and, if the app locks (auto-lock, suspension), the page stops it and closes.
/// In production a lock also rebuilds the root navigator (main.dart
/// `_onAuthChanged`), which disposes this page and releases the camera.
class BarcodeScanPage extends ConsumerStatefulWidget {
  const BarcodeScanPage({
    super.key,
    required this.createCamera,
    required this.onCode,
    this.now,
  });

  /// Creates the camera once, when the page mounts.
  final ScanCamera Function() createCamera;

  final ScanCodeHandler onCode;

  /// Test seam: the clock for the same-code debounce.
  final DateTime Function()? now;

  @override
  ConsumerState<BarcodeScanPage> createState() => _BarcodeScanPageState();
}

class _BarcodeScanPageState extends ConsumerState<BarcodeScanPage>
    with WidgetsBindingObserver {
  late final ScanCamera _camera = widget.createCamera();
  late final ScanGate _gate = ScanGate(now: widget.now);

  /// Set once the session is ending (app locked); nothing restarts the camera
  /// after this.
  bool _isClosing = false;

  bool _isAppActive = true;

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _isAppActive = state == null || state == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _camera.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _isAppActive = true;
        // Coming back to a locked app: the camera stays off — the lock screen
        // is about to cover this page.
        if (ref.read(authProvider).currentUser == null) return;
        _maybeResume();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // Background / lock screen / app switcher: the camera stops. Resuming
        // waits for both the app to come back and any open read to finish.
        _isAppActive = false;
        unawaited(_camera.stop());
    }
  }

  void _onRead(String code) {
    if (_isClosing || !_isAppActive || !_gate.tryBegin(code)) return;
    unawaited(_handle(code));
  }

  Future<void> _handle(String code) async {
    unawaited(HapticFeedback.mediumImpact());
    await _camera.pause();
    try {
      if (mounted) await widget.onCode(context, code);
    } finally {
      _gate.finish();
      _maybeResume();
    }
  }

  void _maybeResume() {
    if (!mounted || _isClosing || !_isAppActive || _gate.isBusy) return;
    unawaited(_camera.resume());
  }

  /// The app locked under the scanner: stop the camera now, then close the
  /// scanner (and anything open over it). The cart itself is untouched here.
  void _onLocked() {
    if (_isClosing) return;
    _isClosing = true;
    unawaited(_camera.stop());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return; // the navigator was rebuilt — already gone.
      final route = ModalRoute.of(context);
      final navigator = Navigator.of(context);
      navigator.popUntil((r) => r == route);
      if (route?.isCurrent ?? false) navigator.pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(
      authProvider.select((auth) => auth.currentUser == null),
      (wasLocked, isLocked) {
        if (isLocked && wasLocked == false) _onLocked();
      },
    );

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Scan barcode'),
        leading: IconButton(
          icon: Icon(FontAwesomeIcons.xmark.data),
          tooltip: 'Close scanner',
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [_TorchButton(camera: _camera)],
      ),
      body: Stack(
        children: [
          Positioned.fill(child: _camera.buildPreview(context, _onRead)),
          // Below the centred aiming frame, clear of the system nav bar.
          Positioned(
            left: 0,
            right: 0,
            bottom: context.getRSize(28) + context.deviceBottomPadding,
            child: const Center(child: ScanCartCount()),
          ),
        ],
      ),
    );
  }
}

/// The torch toggle; hidden while the device reports no torch (#319).
class _TorchButton extends StatelessWidget {
  const _TorchButton({required this.camera});

  final ScanCamera camera;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool?>(
      valueListenable: camera.torch,
      builder: (context, isOn, _) {
        if (isOn == null) return const SizedBox.shrink();
        // Material icons — font_awesome_flutter has no bolt-slash glyph.
        return IconButton(
          icon: Icon(isOn ? Icons.flash_on : Icons.flash_off),
          tooltip: isOn ? 'Turn torch off' : 'Turn torch on',
          onPressed: () => unawaited(camera.toggleTorch()),
        );
      },
    );
  }
}
