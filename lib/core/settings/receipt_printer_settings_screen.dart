import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_card.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_scaffold.dart';

/// Settings > Receipt printer. Lists this device's printers with the paper
/// width saved for each, so a wrong answer to the one-time "which paper?"
/// question (see `prepareReceiptPrinter`) can be fixed without making a print
/// fail. Device-local hardware setting — reachable from both CEO Settings and
/// Staff Settings, since whoever runs the till may need it.
class ReceiptPrinterSettingsScreen extends ConsumerStatefulWidget {
  const ReceiptPrinterSettingsScreen({super.key});

  @override
  ConsumerState<ReceiptPrinterSettingsScreen> createState() =>
      _ReceiptPrinterSettingsScreenState();
}

class _ReceiptPrinterSettingsScreenState
    extends ConsumerState<ReceiptPrinterSettingsScreen> {
  bool _loading = true;
  List<BluetoothInfo> _devices = [];
  Map<String, ReceiptPaperSize?> _sizes = {};
  String? _lastMac;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final printer = ref.read(printerServiceProvider);
    List<BluetoothInfo> devices = [];
    final sizes = <String, ReceiptPaperSize?>{};
    String? lastMac;
    try {
      await printer.requestPermissions();
      devices = await printer.getPairedDevices();
      lastMac = await printer.lastConnectedMac();
      for (final d in devices) {
        sizes[d.macAdress] = await printer.paperSizeFor(d.macAdress);
      }
    } catch (_) {
      // No Bluetooth adapter / read failed — show the empty state.
    }
    // Last-used printer first; it is the one receipts go to.
    devices.sort((a, b) {
      if (a.macAdress == lastMac) return -1;
      if (b.macAdress == lastMac) return 1;
      return 0;
    });
    if (!mounted) return;
    setState(() {
      _devices = devices;
      _sizes = sizes;
      _lastMac = lastMac;
      _loading = false;
    });
  }

  Future<void> _setSize(String mac, ReceiptPaperSize size) async {
    setState(() => _sizes[mac] = size);
    await ref.read(printerServiceProvider).savePaperSizeFor(mac, size);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final subtext = t.colorScheme.onSurface.withValues(alpha: 0.6);

    return GlassyScaffold(
      title: 'Receipt printer',
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh_rounded),
          tooltip: 'Refresh printers',
          onPressed: _loading ? null : _load,
        ),
      ],
      body: _loading
          ? Center(
              child: CircularProgressIndicator(color: t.colorScheme.primary),
            )
          : SettingsFadeIn(
              child: ListView(
                  padding: EdgeInsets.fromLTRB(
                    24,
                    24,
                    24,
                    24 + context.deviceBottomPadding,
                  ),
                  children: [
                    Text(
                      'Printers cannot tell the app which paper they use, so '
                      'the app asks the first time it prints to a new '
                      'printer. Change the answer here if a receipt comes out '
                      'too narrow or too wide.',
                      style: TextStyle(fontSize: 13, color: subtext),
                    ),
                    const SizedBox(height: 20),
                    if (_devices.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 24),
                        child: Text(
                          Platform.isAndroid
                              ? 'No paired printers found.\nPair your printer '
                                    'in Bluetooth settings, then tap refresh.'
                              : 'No printers found nearby.\nMake sure your '
                                    'printer is switched on and in range, '
                                    'then tap refresh.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: subtext),
                        ),
                      ),
                    for (final d in _devices) ...[
                      _printerCard(context, d),
                      const SizedBox(height: 16),
                    ],
                  ],
                ),
            ),
    );
  }

  Widget _printerCard(BuildContext context, BluetoothInfo device) {
    final t = Theme.of(context);
    final subtext = t.colorScheme.onSurface.withValues(alpha: 0.6);
    final size = _sizes[device.macAdress];
    final isLast = device.macAdress == _lastMac;

    return GlassyCard(
      padding: const EdgeInsets.all(16),
      radius: 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: t.colorScheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.print_rounded,
                  color: t.colorScheme.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.name.isEmpty ? device.macAdress : device.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: t.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isLast
                          ? 'Last used'
                          : size == null
                          ? 'Not set yet. Asked on first print'
                          : device.macAdress,
                      style: TextStyle(fontSize: 13, color: subtext),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<ReceiptPaperSize>(
              showSelectedIcon: false,
              emptySelectionAllowed: true,
              segments: const [
                ButtonSegment(
                  value: ReceiptPaperSize.mm58,
                  label: Text('58mm (small)'),
                ),
                ButtonSegment(
                  value: ReceiptPaperSize.mm80,
                  label: Text('80mm (large)'),
                ),
              ],
              selected: size == null ? const {} : {size},
              onSelectionChanged: (selection) {
                if (selection.isEmpty) return;
                _setSize(device.macAdress, selection.first);
              },
            ),
          ),
        ],
      ),
    );
  }
}
