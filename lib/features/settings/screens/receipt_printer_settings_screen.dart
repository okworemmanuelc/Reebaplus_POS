import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/settings/screens/settings_page_parts.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';
import 'package:reebaplus_pos/shared/services/printer_service.dart';
import 'package:reebaplus_pos/shared/services/usb_printer_channel.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// Settings > Receipt printer. Lists this device's printers with the paper
/// width saved for each, so a wrong answer to the one-time "which paper?"
/// question (see `prepareReceiptPrinter`) can be fixed without making a print
/// fail. Device-local hardware setting — reachable from both CEO Settings and
/// Staff Settings, since whoever runs the till may need it.
///
/// On Android, plugged-in USB printers (#614) are listed first — receipts go
/// to them before any Bluetooth printer — each with a Test print button.
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
  List<UsbPrinterInfo> _usbPrinters = [];
  bool _supportsUsb = false;
  String? _testingId;
  Map<String, ReceiptPaperSize?> _sizes = {};
  Map<String, ReceiptPrintStyle> _styles = {};
  Map<String, ReceiptSize> _receiptSizes = {};
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
    List<UsbPrinterInfo> usbPrinters = [];
    final supportsUsb = printer.supportsUsb;
    final sizes = <String, ReceiptPaperSize?>{};
    final styles = <String, ReceiptPrintStyle>{};
    final receiptSizes = <String, ReceiptSize>{};
    String? lastMac;
    if (supportsUsb) {
      // Opening this screen is setting up: ask Android for access to any
      // plugged-in printer not allowed yet.
      usbPrinters = await printer.usbPrinters(askPermission: true);
      for (final u in usbPrinters) {
        sizes[u.id] = await printer.paperSizeFor(u.id);
        styles[u.id] = await printer.printStyleFor(u.id);
        receiptSizes[u.id] = await printer.receiptSizeFor(u.id);
      }
    }
    try {
      await printer.requestPermissions();
      devices = await printer.getPairedDevices();
      lastMac = await printer.lastConnectedMac();
      for (final d in devices) {
        sizes[d.macAdress] = await printer.paperSizeFor(d.macAdress);
        styles[d.macAdress] = await printer.printStyleFor(d.macAdress);
        receiptSizes[d.macAdress] = await printer.receiptSizeFor(d.macAdress);
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
      _usbPrinters = usbPrinters;
      _supportsUsb = supportsUsb;
      _sizes = sizes;
      _styles = styles;
      _receiptSizes = receiptSizes;
      _lastMac = lastMac;
      _loading = false;
    });
  }

  Future<void> _setSize(String mac, ReceiptPaperSize size) async {
    setState(() => _sizes[mac] = size);
    await ref.read(printerServiceProvider).savePaperSizeFor(mac, size);
  }

  Future<void> _setStyle(String mac, ReceiptPrintStyle style) async {
    setState(() => _styles[mac] = style);
    await ref.read(printerServiceProvider).savePrintStyleFor(mac, style);
  }

  Future<void> _setReceiptSize(String id, ReceiptSize size) async {
    setState(() => _receiptSizes[id] = size);
    await ref.read(printerServiceProvider).saveReceiptSizeFor(id, size);
  }

  Future<void> _testPrint(UsbPrinterInfo usb) => _runTestPrint(
    usb.id,
    (printer, name) => printer.testPrintUsb(usb.id, businessName: name),
  );

  Future<void> _testPrintBluetooth(BluetoothInfo device) => _runTestPrint(
    device.macAdress,
    (printer, name) =>
        printer.testPrintBluetooth(device.macAdress, businessName: name),
  );

  Future<void> _runTestPrint(
    String id,
    Future<bool> Function(PrinterService printer, String? businessName) send,
  ) async {
    setState(() => _testingId = id);
    final ok = await send(
      ref.read(printerServiceProvider),
      ref.read(currentBusinessNameProvider),
    );
    if (!mounted) return;
    setState(() => _testingId = null);
    if (ok) {
      AppNotification.showSuccess(context, 'Test print sent');
    } else {
      AppNotification.showError(
        context,
        "Couldn't print. Check the printer is on, has paper and is "
        'plugged in.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;

    return SettingsPageScaffold(
      icon: AppIcons.print,
      title: 'Receipt printer',
      actions: [
        IconButton(
          icon: AppIcon(
            AppIcons.refresh,
            color: _loading ? t.disabledColor : t.colorScheme.onSurface,
          ),
          constraints: const BoxConstraints(
            minWidth: kMinInteractiveDimension,
            minHeight: kMinInteractiveDimension,
          ),
          tooltip: 'Refresh printers',
          onPressed: _loading ? null : _load,
        ),
      ],
      body: _loading
          ? Center(
              child: CircularProgressIndicator(color: t.colorScheme.primary),
            )
          : SettingsFadeIn(
              child: SettingsPageList(
                listKey: const Key('receipt-printer-list'),
                children: [
                  Text(
                    'Printers cannot tell the app which paper they use, so '
                    'the app asks the first time it prints to a new '
                    'printer. Change the answer here if a receipt comes out '
                    'too narrow or too wide.',
                    style: context.regularStyle(13).copyWith(color: muted),
                  ),
                  SizedBox(height: context.getRSize(20)),
                  if (_supportsUsb) ...[
                    if (_usbPrinters.isEmpty) ...[
                      Text(
                        'Plug an 80mm USB receipt printer into this tablet '
                        'to use it.',
                        key: const Key('usb-printer-help'),
                        style: context.regularStyle(13).copyWith(color: muted),
                      ),
                      SizedBox(height: context.getRSize(20)),
                    ],
                    for (final u in _usbPrinters) ...[
                      _usbCard(context, u),
                      SizedBox(height: context.getRSize(12)),
                    ],
                  ],
                  if (_devices.isEmpty)
                    Padding(
                      padding: EdgeInsets.only(top: context.getRSize(24)),
                      child: Text(
                        Platform.isAndroid
                            ? 'No paired printers found.\nPair your printer '
                                  'in Bluetooth settings, then tap refresh.'
                            : 'No printers found nearby.\nMake sure your '
                                  'printer is switched on and in range, '
                                  'then tap refresh.',
                        textAlign: TextAlign.center,
                        style: context.regularStyle(14).copyWith(color: muted),
                      ),
                    ),
                  for (final d in _devices) ...[
                    _printerCard(context, d),
                    SizedBox(height: context.getRSize(12)),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _printerCard(BuildContext context, BluetoothInfo device) {
    final size = _sizes[device.macAdress];
    final isLast = device.macAdress == _lastMac;
    return _card(
      context,
      id: device.macAdress,
      title: device.name.isEmpty ? device.macAdress : device.name,
      subtitle: isLast
          ? 'Last used'
          : size == null
          ? 'Not set yet. Asked on first print'
          : device.macAdress,
      footer: AppButton(
        key: Key('bt-test-print-${device.macAdress}'),
        text: 'Test print',
        variant: AppButtonVariant.outline,
        icon: AppIcons.print,
        isLoading: _testingId == device.macAdress,
        onPressed: _testingId == device.macAdress
            ? null
            : () => _testPrintBluetooth(device),
      ),
    );
  }

  Widget _usbCard(BuildContext context, UsbPrinterInfo usb) {
    final testing = _testingId == usb.id;
    return _card(
      context,
      id: usb.id,
      title: usb.name,
      subtitle: usb.hasPermission
          ? 'USB. Receipts print here first'
          : 'USB. Not allowed yet, tap refresh and allow it',
      footer: AppButton(
        key: Key('usb-test-print-${usb.id}'),
        text: 'Test print',
        variant: AppButtonVariant.outline,
        icon: AppIcons.print,
        isLoading: testing,
        onPressed: testing || !usb.hasPermission ? null : () => _testPrint(usb),
      ),
    );
  }

  Widget _card(
    BuildContext context, {
    required String id,
    required String title,
    required String subtitle,
    Widget? footer,
  }) {
    final size = _sizes[id];
    final style = _styles[id] ?? ReceiptPrintStyle.text;
    final receiptSize = _receiptSizes[id] ?? ReceiptSize.full;
    final muted =
        Theme.of(context).textTheme.bodySmall?.color ??
        Theme.of(context).colorScheme.onSurface;

    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsControlRow(
            icon: AppIcons.print,
            tone: IconTileTone.neutral,
            title: title,
            subtitle: subtitle,
          ),
          SizedBox(height: context.getRSize(14)),
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
                _setSize(id, selection.first);
              },
            ),
          ),
          SizedBox(height: context.getRSize(14)),
          Text('Print style', style: context.regularStyle(13)),
          SizedBox(height: context.getRSize(6)),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<ReceiptPrintStyle>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: ReceiptPrintStyle.text,
                  label: Text('Text'),
                ),
                ButtonSegment(
                  value: ReceiptPrintStyle.picture,
                  label: Text('Picture'),
                ),
              ],
              selected: {style},
              onSelectionChanged: (selection) {
                if (selection.isEmpty) return;
                _setStyle(id, selection.first);
              },
            ),
          ),
          SizedBox(height: context.getRSize(6)),
          Text(
            style == ReceiptPrintStyle.text
                ? 'Text: fast and sharp (recommended)'
                : 'Picture: matches the design exactly',
            style: context.regularStyle(12).copyWith(color: muted),
          ),
          SizedBox(height: context.getRSize(14)),
          Text('Print size', style: context.regularStyle(13)),
          SizedBox(height: context.getRSize(6)),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<ReceiptSize>(
              key: Key('receipt-size-$id'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: ReceiptSize.full, label: Text('Full')),
                ButtonSegment(
                  value: ReceiptSize.compact,
                  label: Text('Compact'),
                ),
              ],
              selected: {receiptSize},
              onSelectionChanged: (selection) {
                if (selection.isEmpty) return;
                _setReceiptSize(id, selection.first);
              },
            ),
          ),
          SizedBox(height: context.getRSize(6)),
          Text(
            receiptSize == ReceiptSize.full
                ? 'Full: the normal receipt'
                : 'Compact: smaller text, no logo or address, uses less paper',
            style: context.regularStyle(12).copyWith(color: muted),
          ),
          if (footer != null) ...[
            SizedBox(height: context.getRSize(14)),
            footer,
          ],
        ],
      ),
    );
  }
}
