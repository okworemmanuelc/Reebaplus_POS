import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/settings/screens/receipt_printer_parts.dart';
import 'package:reebaplus_pos/features/settings/screens/settings_page_parts.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/pos/services/paper_end.dart';
import 'package:reebaplus_pos/shared/services/printer_service.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';
import 'package:reebaplus_pos/features/settings/screens/test_print_preview_screen.dart';
import 'package:reebaplus_pos/shared/services/usb_printer_channel.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// Settings > Receipt printer. Lists this device's printers with the settings
/// saved for each, so a wrong answer to the one-time "which paper?" question
/// (see `prepareReceiptPrinter`) can be fixed without making a print fail.
/// Device-local hardware setting — reachable from both CEO Settings and Staff
/// Settings, since whoever runs the till may need it.
///
/// The last-used printer leads; the rest sit behind Other devices, most
/// recently used first (#724). A phone opens a printer's settings inside its
/// card; a wider screen shows them in a panel beside the list (#742).
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
  Map<String, ReceiptPaperSize?> _sizes = {};
  Map<String, ReceiptPrintStyle> _styles = {};
  Map<String, ReceiptSize> _receiptSizes = {};
  Map<String, int> _paperEnds = {};
  // USB ids and Bluetooth MACs, most recently printed on first (#724).
  List<String> _recent = const [];
  // The printer whose settings are showing. Null on a phone = all closed.
  String? _openId;
  // Null until tapped, then Other devices follows the choice.
  bool? _othersOpen;

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
    final paperEnds = <String, int>{};
    if (supportsUsb) {
      // Opening this screen is setting up: ask Android for access to any
      // plugged-in printer not allowed yet.
      usbPrinters = await printer.usbPrinters(askPermission: true);
      for (final u in usbPrinters) {
        sizes[u.id] = await printer.paperSizeFor(u.id);
        styles[u.id] = await printer.printStyleFor(u.id);
        receiptSizes[u.id] = await printer.receiptSizeFor(u.id);
        paperEnds[u.id] = await printer.paperEndLinesFor(u.id);
      }
    }
    try {
      await printer.requestPermissions();
      devices = await printer.getPairedDevices();
      for (final d in devices) {
        sizes[d.macAdress] = await printer.paperSizeFor(d.macAdress);
        styles[d.macAdress] = await printer.printStyleFor(d.macAdress);
        receiptSizes[d.macAdress] = await printer.receiptSizeFor(d.macAdress);
        paperEnds[d.macAdress] = await printer.paperEndLinesFor(d.macAdress);
      }
    } catch (_) {
      // No Bluetooth adapter / read failed — show the empty state.
    }
    final recent = await printer.recentPrinterIds();
    if (!mounted) return;
    setState(() {
      _devices = devices;
      _usbPrinters = usbPrinters;
      _supportsUsb = supportsUsb;
      _sizes = sizes;
      _styles = styles;
      _receiptSizes = receiptSizes;
      _paperEnds = paperEnds;
      _recent = recent;
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

  Future<void> _setPaperEnd(String id, int lines) async {
    setState(() => _paperEnds[id] = lines);
    await ref.read(printerServiceProvider).savePaperEndLinesFor(id, lines);
  }

  Future<void> _openPreview(String id, String name, TestPrintSender send) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TestPrintPreviewScreen(
          printerId: id,
          printerName: name,
          send: send,
        ),
      ),
    );
  }

  Future<void> _testPrint(UsbPrinterInfo usb) => _openPreview(
    usb.id,
    usb.name,
    (printer, name, date) =>
        printer.testPrintUsb(usb.id, businessName: name, saleDate: date),
  );

  Future<void> _testPrintBluetooth(BluetoothInfo device) => _openPreview(
    device.macAdress,
    device.name.isEmpty ? device.macAdress : device.name,
    (printer, name, date) => printer.testPrintBluetooth(
      device.macAdress,
      businessName: name,
      saleDate: date,
    ),
  );

  /// USB and Bluetooth printers in one list, most recently used first.
  List<_Printer> get _printers => PrinterService.sortByRecent(
    [
      if (_supportsUsb)
        for (final u in _usbPrinters)
          _Printer(
            id: u.id,
            name: u.name,
            testKey: Key('usb-test-print-${u.id}'),
            isUsb: true,
            allowed: u.hasPermission,
            test: () => _testPrint(u),
          ),
      for (final d in _devices)
        _Printer(
          id: d.macAdress,
          name: d.name.isEmpty ? d.macAdress : d.name,
          testKey: Key('bt-test-print-${d.macAdress}'),
          test: () => _testPrintBluetooth(d),
        ),
    ],
    (p) => p.id,
    _recent,
  );

  /// What a printer's card says under its name.
  String _subtitle(_Printer p) {
    if (p.isUsb && !p.allowed) {
      return 'USB. Not allowed yet, tap refresh and allow it';
    }
    final summary = printerSummary(
      paperSize: _sizes[p.id],
      style: _styles[p.id] ?? ReceiptPrintStyle.text,
      receiptSize: _receiptSizes[p.id] ?? ReceiptSize.full,
      paperEndLines: _paperEnds[p.id] ?? kDefaultPaperEndLines,
    );
    return p.isUsb ? 'USB · $summary' : summary;
  }

  @override
  Widget build(BuildContext context) {
    final printers = _printers;
    final lastUsed = printers.isNotEmpty && _recent.contains(printers.first.id)
        ? printers.first
        : null;
    final others = lastUsed == null ? printers : printers.sublist(1);
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= kPrinterTwoPaneMinWidth;
        return SettingsPageScaffold(
          icon: AppIcons.print,
          title: 'Receipt printer',
          subtitle: _usbPrinters.isEmpty
              ? 'Bluetooth printers near you'
              : 'USB and Bluetooth printers',
          actions: [wide ? _searchAgainButton() : _refreshButton(context)],
          body: _loading
              ? Center(
                  child: CircularProgressIndicator(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                )
              : SettingsFadeIn(
                  child: wide && printers.isNotEmpty
                      ? _twoPanes(context, printers, lastUsed, others)
                      : _phoneList(context, lastUsed, others),
                ),
        );
      },
    );
  }

  Widget _refreshButton(BuildContext context) {
    final t = Theme.of(context);
    return IconButton(
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
    );
  }

  Widget _searchAgainButton() => AppButton(
    key: const Key('printer-search-again'),
    text: 'Search Again',
    variant: AppButtonVariant.outline,
    size: AppButtonSize.small,
    isFullWidth: false,
    icon: AppIcons.refresh,
    onPressed: _loading ? null : _load,
  );

  /// Starts open when closing it would hide a plugged-in USB printer, or when
  /// nothing leads the list yet.
  bool _isOthersOpen(_Printer? lastUsed, List<_Printer> others) =>
      _othersOpen ?? (lastUsed == null || others.any((p) => p.isUsb));

  Widget _phoneList(
    BuildContext context,
    _Printer? lastUsed,
    List<_Printer> others,
  ) {
    final muted = _muted(context);
    final gap = SizedBox(height: context.getRSize(12));
    final othersOpen = _isOthersOpen(lastUsed, others);
    final allUnset = others.every((p) => _sizes[p.id] == null);
    return SettingsPageList(
      listKey: const Key('receipt-printer-list'),
      children: [
        if (lastUsed != null || others.isNotEmpty) ...[
          Text(
            'Tap a printer to see or change its settings.',
            style: context.regularStyle(14).copyWith(color: muted),
          ),
          SizedBox(height: context.getRSize(16)),
        ],
        if (lastUsed != null) ...[
          const PrinterSectionLabel('LAST USED'),
          SizedBox(height: context.getRSize(10)),
          _phoneCard(context, lastUsed, alwaysShowTest: true),
          SizedBox(height: context.getRSize(20)),
        ],
        if (others.isNotEmpty) ...[
          PrinterCard(
            key: const Key('printer-others-toggle'),
            icon: AppIcons.bluetooth,
            title: 'Other devices (${others.length})',
            subtitle: allUnset ? kPrinterNotSetYet : 'Tap to show or hide',
            chevronUp: othersOpen,
            onTap: () => setState(() => _othersOpen = !othersOpen),
          ),
          gap,
          if (othersOpen)
            for (final p in others) ...[_phoneCard(context, p), gap],
        ],
        ..._emptyNotes(context),
      ],
    );
  }

  Widget _phoneCard(
    BuildContext context,
    _Printer p, {
    bool alwaysShowTest = false,
  }) {
    final open = _openId == p.id;
    return PrinterCard(
      key: Key('printer-card-${p.id}'),
      icon: AppIcons.print,
      title: p.name,
      subtitle: _subtitle(p),
      strongIcon: alwaysShowTest || open,
      outlined: open,
      chevronUp: open,
      onTap: () => setState(() => _openId = open ? null : p.id),
      body: open ? _settings(context, p) : null,
      footer: open || alwaysShowTest ? _testButton(p) : null,
    );
  }

  Widget _twoPanes(
    BuildContext context,
    List<_Printer> printers,
    _Printer? lastUsed,
    List<_Printer> others,
  ) {
    final selected = printers.firstWhere(
      (p) => p.id == _openId,
      orElse: () => printers.first,
    );
    final othersOpen = _isOthersOpen(lastUsed, others);
    final gap = SizedBox(height: context.getRSize(12));
    final listPad = EdgeInsets.only(
      bottom: context.getRSize(24) + context.deviceBottomPadding,
    );
    Widget card(_Printer p) => PrinterCard(
      key: Key('printer-card-${p.id}'),
      icon: AppIcons.print,
      title: p.name,
      subtitle: _subtitle(p),
      strongIcon: p.id == selected.id || p.id == lastUsed?.id,
      outlined: p.id == selected.id,
      onTap: () => setState(() => _openId = p.id),
    );

    return SafeArea(
      top: false,
      bottom: false,
      child: LayoutBuilder(
        builder: (context, box) {
          final listWidth = (box.maxWidth * 0.32).clamp(280.0, 380.0);
          return Padding(
            padding: EdgeInsets.fromLTRB(
              context.getRSize(16),
              context.getRSize(16),
              context.getRSize(16),
              0,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: listWidth,
                  child: ListView(
                    key: const Key('receipt-printer-list'),
                    padding: listPad,
                    children: [
                      if (lastUsed != null) ...[
                        const PrinterSectionLabel('LAST USED'),
                        SizedBox(height: context.getRSize(10)),
                        card(lastUsed),
                        SizedBox(height: context.getRSize(12)),
                      ],
                      if (others.isNotEmpty) ...[
                        PrinterOthersHeader(
                          key: const Key('printer-others-toggle'),
                          label: 'OTHER DEVICES (${others.length})',
                          open: othersOpen,
                          onTap: () =>
                              setState(() => _othersOpen = !othersOpen),
                        ),
                        if (othersOpen)
                          for (final p in others) ...[card(p), gap],
                      ],
                      ..._emptyNotes(context),
                    ],
                  ),
                ),
                SizedBox(width: context.getRSize(20)),
                Expanded(
                  child: _detailPanel(context, selected, lastUsed, listPad),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _detailPanel(
    BuildContext context,
    _Printer p,
    _Printer? lastUsed,
    EdgeInsets scrollPad,
  ) {
    final t = Theme.of(context);
    final pad = EdgeInsets.all(context.getRSize(20));
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        key: const Key('printer-detail-panel'),
        padding: scrollPad,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: (box.maxHeight - scrollPad.bottom).clamp(
              0.0,
              double.infinity,
            ),
          ),
          child: SettingsCard(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: pad,
                  child: SettingsControlRow(
                    icon: AppIcons.print,
                    tone: IconTileTone.neutral,
                    title: p.name,
                    subtitle: p.id == lastUsed?.id ? 'Last used' : _subtitle(p),
                    trailing: _testButton(p, fullWidth: false),
                  ),
                ),
                Divider(height: 1, thickness: 1, color: t.dividerColor),
                Padding(
                  padding: pad,
                  child: _settings(context, p, stackStepper: true),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Why the list is short: what to plug in or pair.
  List<Widget> _emptyNotes(BuildContext context) {
    final muted = _muted(context);
    return [
      if (_supportsUsb && _usbPrinters.isEmpty)
        Padding(
          padding: EdgeInsets.only(top: context.getRSize(12)),
          child: Text(
            'Plug an 80mm USB receipt printer into this tablet to use it.',
            key: const Key('usb-printer-help'),
            style: context.regularStyle(13).copyWith(color: muted),
          ),
        ),
      if (_devices.isEmpty)
        Padding(
          padding: EdgeInsets.only(top: context.getRSize(24)),
          child: Text(
            (!kIsWeb && Platform.isAndroid)
                ? 'No paired printers found.\nPair your printer '
                      'in Bluetooth settings, then tap refresh.'
                : 'No printers found nearby.\nMake sure your '
                      'printer is switched on and in range, '
                      'then tap refresh.',
            textAlign: TextAlign.center,
            style: context.regularStyle(14).copyWith(color: muted),
          ),
        ),
    ];
  }

  Widget _testButton(_Printer p, {bool fullWidth = true}) => AppButton(
    key: p.testKey,
    text: 'Test Print',
    variant: AppButtonVariant.outline,
    size: fullWidth ? AppButtonSize.normal : AppButtonSize.small,
    isFullWidth: fullWidth,
    icon: AppIcons.print,
    onAsyncPressed: p.isUsb && !p.allowed ? null : p.test,
  );

  /// The four settings: one above the other, or two to a row when
  /// [stackStepper] (the side panel) has the width for it.
  Widget _settings(
    BuildContext context,
    _Printer p, {
    bool stackStepper = false,
  }) {
    final id = p.id;
    final ink = Theme.of(context).colorScheme.onSurface;
    final style = _styles[id] ?? ReceiptPrintStyle.text;
    final receiptSize = _receiptSizes[id] ?? ReceiptSize.full;
    final paperEndLines = _paperEnds[id] ?? kDefaultPaperEndLines;
    const paperEndHelp =
        'Lines of blank paper after each receipt. Lower saves paper; '
        'raise it if the last line gets torn off.';

    final paperWidth = PrinterSettingField(
      label: 'Paper width',
      child: AppSegmented<ReceiptPaperSize>(
        solid: true,
        unselectedColor: ink,
        value: _sizes[id],
        items: const {
          ReceiptPaperSize.mm58: '58mm (small)',
          ReceiptPaperSize.mm80: '80mm (large)',
        },
        onChanged: (v) => _setSize(id, v),
      ),
    );
    final printStyle = PrinterSettingField(
      label: 'Print style',
      help: style == ReceiptPrintStyle.text
          ? 'Text: fast and sharp (recommended)'
          : 'Picture: matches the design exactly',
      child: AppSegmented<ReceiptPrintStyle>(
        solid: true,
        unselectedColor: ink,
        value: style,
        items: const {
          ReceiptPrintStyle.text: 'Text',
          ReceiptPrintStyle.picture: 'Picture',
        },
        onChanged: (v) => _setStyle(id, v),
      ),
    );
    final printSize = PrinterSettingField(
      label: 'Print size',
      help: receiptSize == ReceiptSize.full
          ? 'Full: the normal receipt'
          : 'Compact: smaller text, no logo or address, uses less paper',
      child: AppSegmented<ReceiptSize>(
        key: Key('receipt-size-$id'),
        solid: true,
        unselectedColor: ink,
        value: receiptSize,
        items: const {ReceiptSize.full: 'Full', ReceiptSize.compact: 'Compact'},
        onChanged: (v) => _setReceiptSize(id, v),
      ),
    );
    final stepper = PaperEndStepper(
      key: Key('paper-end-$id'),
      lines: paperEndLines,
      showWords: stackStepper,
      onChanged: (v) => _setPaperEnd(id, v),
    );
    final blankPaper = stackStepper
        ? PrinterSettingField(
            label: 'Blank paper after receipt',
            help: paperEndHelp,
            child: stepper,
          )
        : PrinterSettingField(
            label: 'Blank paper after receipt',
            help: paperEndHelp,
            trailing: stepper,
          );

    final usbNote = p.isUsb && p.allowed
        ? Padding(
            padding: EdgeInsets.only(bottom: context.getRSize(14)),
            child: Text(
              'USB. Receipts print here first',
              style: context.regularStyle(13).copyWith(color: _muted(context)),
            ),
          )
        : null;
    final rowGap = SizedBox(height: context.getRSize(18));

    return LayoutBuilder(
      builder: (context, box) {
        if (stackStepper && box.maxWidth >= kPrinterTwoColumnMinWidth) {
          final columnGap = SizedBox(width: context.getRSize(24));
          Widget row(Widget a, Widget b) => Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: a),
              columnGap,
              Expanded(child: b),
            ],
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ?usbNote,
              row(paperWidth, printStyle),
              rowGap,
              row(printSize, blankPaper),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ?usbNote,
            paperWidth,
            rowGap,
            printStyle,
            rowGap,
            printSize,
            rowGap,
            blankPaper,
          ],
        );
      },
    );
  }

  Color _muted(BuildContext context) {
    final t = Theme.of(context);
    return t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
  }
}

/// One line of the list: a USB or Bluetooth printer, flattened.
class _Printer {
  const _Printer({
    required this.id,
    required this.name,
    required this.testKey,
    required this.test,
    this.isUsb = false,
    this.allowed = true,
  });

  final String id;
  final String name;
  final Key testKey;
  final Future<void> Function() test;
  final bool isUsb;

  /// Android has let the app use this USB printer. Always true for Bluetooth.
  final bool allowed;
}
