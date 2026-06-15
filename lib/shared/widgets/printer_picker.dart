import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

class PrinterPicker extends ConsumerStatefulWidget {
  final Function(BluetoothInfo) onSelected;

  const PrinterPicker({super.key, required this.onSelected});

  @override
  ConsumerState<PrinterPicker> createState() => _PrinterPickerState();
}

class _PrinterPickerState extends ConsumerState<PrinterPicker> {
  bool _isLoading = true;
  List<BluetoothInfo> _devices = [];

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    setState(() => _isLoading = true);
    final printer = ref.read(printerServiceProvider);
    // Reading device names from the OS bonded list needs BLUETOOTH_CONNECT on
    // Android 12+; without it the list comes back empty or unnamed. Ensure the
    // permission before loading so the picker list is accurate.
    List<BluetoothInfo> devices = [];
    try {
      await printer.requestPermissions();
      devices = await printer.getPairedDevices();
    } catch (_) {
      // No Bluetooth adapter / read failed — fall through to the empty state
      // rather than spinning forever.
    }
    if (mounted) {
      setState(() {
        _devices = devices;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).colorScheme.onSurface;
    final subtext = Theme.of(context).textTheme.bodySmall?.color ?? Colors.grey;
    final border = Theme.of(context).dividerColor;

    return Padding(
      padding: EdgeInsets.only(bottom: context.deviceBottomPadding),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.all(context.getRSize(16)),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Select Receipt Printer',
                  style: TextStyle(
                    color: text,
                    fontWeight: FontWeight.bold,
                    fontSize: context.getRFontSize(16),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.refresh, size: context.getRSize(20)),
                  onPressed: _loadDevices,
                ),
              ],
            ),
          ),
          Divider(height: 1, color: border),
          if (_isLoading)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Center(child: CircularProgressIndicator()),
                  // iOS/macOS scan for nearby printers (~5s); a bare spinner
                  // looks stuck, so label what's happening.
                  if (!Platform.isAndroid) ...[
                    SizedBox(height: context.getRSize(12)),
                    Text(
                      'Scanning for nearby printers…',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: subtext),
                    ),
                  ],
                ],
              ),
            )
          else if (_devices.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Text(
                  // iOS/macOS discover BLE printers by scanning while they're
                  // powered on — they are NOT paired in iOS Bluetooth settings,
                  // so don't tell users to go there.
                  Platform.isAndroid
                      ? 'No paired printers found.\nPair your printer in Bluetooth settings, then tap refresh.'
                      : 'No printers found nearby.\nMake sure your printer is switched on and in range and Bluetooth is enabled, then tap refresh.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: subtext),
                ),
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _devices.length,
                itemBuilder: (context, index) {
                  final device = _devices[index];
                  return ListTile(
                    leading: Icon(Icons.print, color: Theme.of(context).primaryColor),
                    title: Text(device.name, style: TextStyle(color: text)),
                    subtitle: Text(device.macAdress, style: TextStyle(color: subtext)),
                    onTap: () => widget.onSelected(device),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
