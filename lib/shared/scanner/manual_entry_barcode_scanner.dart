import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:reebaplus_pos/shared/scanner/barcode_scanner.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// Whether the `mobile_scanner` camera plugin has an implementation on this
/// platform. It ships Android, iOS, macOS and web only; on Windows and Linux
/// its method channels do not exist and any call throws
/// `MissingPluginException` (#61).
bool cameraScanningSupported({
  TargetPlatform? platform,
  bool isWeb = kIsWeb,
}) {
  if (isWeb) return true;
  switch (platform ?? defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return true;
    case TargetPlatform.windows:
    case TargetPlatform.linux:
    case TargetPlatform.fuchsia:
      return false;
  }
}

/// The [BarcodeScanner] for platforms with no camera plugin (Windows, Linux).
/// It opens a small dialog with a focused text box: type or paste a code, or
/// scan with a USB / keyboard-wedge scanner (which types the digits then sends
/// Enter). Each submitted code goes to `onCode` exactly like a camera read, and
/// the box clears and stays open for the next one until the cashier closes it.
class ManualEntryBarcodeScanner implements BarcodeScanner {
  const ManualEntryBarcodeScanner();

  @override
  Future<void> scanSession(
    BuildContext context, {
    required ScanCodeHandler onCode,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => _ManualEntryDialog(onCode: onCode),
    );
  }
}

class _ManualEntryDialog extends StatefulWidget {
  const _ManualEntryDialog({required this.onCode});

  final ScanCodeHandler onCode;

  @override
  State<_ManualEntryDialog> createState() => _ManualEntryDialogState();
}

class _ManualEntryDialogState extends State<_ManualEntryDialog> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit([String? _]) async {
    final code = _controller.text.trim();
    // Same contract as the camera: trimmed, non-empty, and other reads are
    // ignored while the handler runs.
    if (code.isEmpty || _busy) return;
    _busy = true;
    _controller.clear();
    try {
      await widget.onCode(context, code);
    } finally {
      _busy = false;
      if (mounted) _focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('manual-barcode-dialog'),
      scrollable: true,
      title: const Text('Enter barcode'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This device has no camera scanner. Type the barcode, or scan it '
            'with a USB scanner, then press Enter.',
          ),
          const SizedBox(height: 12),
          AppInput(
            key: const Key('manual-barcode-input'),
            controller: _controller,
            focusNode: _focus,
            autofocus: true,
            labelText: 'Barcode',
            textInputAction: TextInputAction.done,
            onFieldSubmitted: _submit,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Add')),
      ],
    );
  }
}
