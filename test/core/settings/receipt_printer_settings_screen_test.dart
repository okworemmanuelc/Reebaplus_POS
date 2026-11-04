// receipt_printer_settings_screen_test.dart
//
// Settings > Receipt printer: the place to correct a printer's paper width
// without having to make a print fail first.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/settings/screens/receipt_printer_settings_screen.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';
import 'package:reebaplus_pos/shared/services/printer_service.dart';

import '../../helpers/fake_usb_printer_channel.dart';

const _small = '00:11:22:33:44:55';
const _large = '66:77:88:99:AA:BB';

/// Never touches the Bluetooth plugin or `permission_handler`.
class _FakePrinterService extends PrinterService {
  _FakePrinterService({super.usb});

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<List<BluetoothInfo>> getPairedDevices() async => [
    BluetoothInfo(name: 'Counter printer', macAdress: _small),
    BluetoothInfo(name: 'Back office printer', macAdress: _large),
  ];
}

/// A device with nothing paired.
class _EmptyPrinterService extends PrinterService {
  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<List<BluetoothInfo>> getPairedDevices() async => [];
}

const _phone = Size(390, 4000);
const _tablet = Size(1194, 834);

Future<PrinterService> _pump(
  WidgetTester tester, {
  FakeUsbPrinterChannel? usb,
  Size size = _phone,
}) async {
  final printer = _FakePrinterService(usb: usb);
  // Tall enough that the lazy list builds every card.
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        printerServiceProvider.overrideWithValue(printer),
        currentBusinessNameProvider.overrideWithValue('Ada Bar'),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: const ReceiptPrinterSettingsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return printer;
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

const _usbId = 'usb:1208:514';
const _usbSummary = 'USB · 80mm · Text · Full · 3 blank lines';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('phone', () {
    testWidgets('the last-used printer leads; others wait behind a card', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({'last_printer_mac': _large});
      await _pump(tester);

      expect(find.text('LAST USED'), findsOneWidget);
      expect(find.text('Back office printer'), findsOneWidget);
      expect(find.text('Other devices (1)'), findsOneWidget);
      expect(find.text('Counter printer'), findsNothing);
      // Closed, yet Test Print stays one tap away on the last-used printer.
      expect(find.byKey(const Key('bt-test-print-$_large')), findsOneWidget);
      expect(find.text('Paper width'), findsNothing);

      await _tap(tester, find.text('Other devices (1)'));
      expect(find.text('Counter printer'), findsOneWidget);
      expect(find.byKey(const Key('bt-test-print-$_small')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('with nothing used yet every printer is on show', (
      tester,
    ) async {
      await _pump(tester);

      expect(find.text('LAST USED'), findsNothing);
      expect(find.text('Other devices (2)'), findsOneWidget);
      // The two printers and the Other devices card itself.
      expect(find.text('Not set yet. Asked on first print.'), findsNWidgets(3));
    });

    testWidgets('a card summarises its settings', (tester) async {
      SharedPreferences.setMockInitialValues({
        'last_printer_mac': _small,
        'printer_paper_size:$_small': 'mm58',
        'printer_paper_end:$_small': 0,
      });
      final printer = await _pump(tester);
      await printer.saveReceiptSizeFor(_small, ReceiptSize.compact);
      await tester.tap(find.byTooltip('Refresh printers'));
      await tester.pumpAndSettle();

      expect(
        find.text('58mm · Text · Compact · No blank lines'),
        findsOneWidget,
      );
    });

    testWidgets('the longest summary fits on one line at 390 wide', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'last_printer_mac': _small,
        'printer_paper_size:$_small': 'mm58',
        'printer_paper_end:$_small': 0,
        'printer_receipt_size:$_small': 'compact',
      });
      await _pump(tester, size: const Size(390, 844));

      final line = find.text('58mm · Text · Compact · No blank lines');
      final fontSize = tester.widget<Text>(line).style!.fontSize!;
      expect(tester.getSize(line).height, lessThan(fontSize * 2));
    });

    testWidgets('one card opens at a time and saves for that printer only', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'printer_paper_size:$_small': 'mm58',
      });
      final printer = await _pump(tester);

      await _tap(tester, find.text('Back office printer'));
      expect(find.text('Paper width'), findsOneWidget);
      await _tap(tester, find.text('80mm (large)'));
      expect(await printer.paperSizeFor(_large), ReceiptPaperSize.mm80);
      expect(await printer.paperSizeFor(_small), ReceiptPaperSize.mm58);

      await _tap(tester, find.text('Counter printer'));
      expect(find.text('Paper width'), findsOneWidget);

      await _tap(tester, find.text('Counter printer'));
      expect(find.text('Paper width'), findsNothing);
    });

    testWidgets('print style defaults to text and saves per printer', (
      tester,
    ) async {
      final printer = await _pump(tester);
      await _tap(tester, find.text('Back office printer'));
      expect(await printer.printStyleFor(_large), ReceiptPrintStyle.text);
      expect(find.text('Text: fast and sharp (recommended)'), findsOneWidget);

      await _tap(tester, find.text('Picture'));

      expect(await printer.printStyleFor(_large), ReceiptPrintStyle.picture);
      expect(await printer.printStyleFor(_small), ReceiptPrintStyle.text);
      expect(find.text('Picture: matches the design exactly'), findsOneWidget);
    });

    testWidgets('print size defaults to Full and saves per printer (#676)', (
      tester,
    ) async {
      final printer = await _pump(tester);
      expect(await printer.receiptSizeFor(_small), ReceiptSize.full);
      await _tap(tester, find.text('Back office printer'));

      await _tap(tester, find.text('Compact'));

      expect(await printer.receiptSizeFor(_large), ReceiptSize.compact);
      expect(await printer.receiptSizeFor(_small), ReceiptSize.full);
    });

    testWidgets('blank paper steps from 0 to 5 and stops there (#717)', (
      tester,
    ) async {
      final printer = await _pump(tester);
      await _tap(tester, find.text('Back office printer'));
      final less = find.byTooltip('Less blank paper');
      final more = find.byTooltip('More blank paper');
      InkWell ink(Finder f) => tester.widget<InkWell>(
        find.descendant(of: f, matching: find.byType(InkWell)),
      );

      await _tap(tester, less);
      await _tap(tester, less);
      await _tap(tester, less);
      expect(await printer.paperEndLinesFor(_large), 0);
      expect(ink(less).onTap, isNull);

      for (var i = 0; i < 5; i++) {
        await _tap(tester, more);
      }
      expect(await printer.paperEndLinesFor(_large), 5);
      expect(ink(more).onTap, isNull);
      expect(await printer.paperEndLinesFor(_small), 3);
    });
  });

  group('tablet (#742)', () {
    testWidgets('list on the left, the chosen printer on the right', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({'last_printer_mac': _large});
      final printer = await _pump(tester, size: _tablet);

      expect(find.text('OTHER DEVICES (1)'), findsOneWidget);
      expect(find.text('Last used'), findsOneWidget);
      expect(find.text('No blank lines'), findsNothing);
      expect(find.text('3 blank lines'), findsOneWidget);
      expect(find.text('Search Again'), findsOneWidget);
      expect(find.byTooltip('Refresh printers'), findsNothing);
      final listRight = tester
          .getTopRight(find.byKey(const Key('receipt-printer-list')))
          .dx;
      final panelLeft = tester
          .getTopLeft(find.byKey(const Key('printer-detail-panel')))
          .dx;
      expect(listRight, lessThan(panelLeft));
      // Paper width and Print style share a row.
      expect(
        tester.getTopLeft(find.text('Paper width')).dy,
        tester.getTopLeft(find.text('Print style')).dy,
      );

      await _tap(tester, find.text('OTHER DEVICES (1)'));
      await _tap(tester, find.text('Counter printer').first);
      await _tap(tester, find.text('80mm (large)'));
      expect(await printer.paperSizeFor(_small), ReceiptPaperSize.mm80);
      expect(await printer.paperSizeFor(_large), isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no printers at all shows the help, not an empty panel', (
      tester,
    ) async {
      final printer = _EmptyPrinterService();
      tester.view.physicalSize = _tablet;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [printerServiceProvider.overrideWithValue(printer)],
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: const ReceiptPrinterSettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('printer-detail-panel')), findsNothing);
      expect(find.textContaining('tap refresh'), findsOneWidget);
    });
  });

  group('USB printers (#614)', () {
    testWidgets('a plugged-in USB printer is never hidden', (tester) async {
      SharedPreferences.setMockInitialValues({'last_printer_mac': _large});
      final usb = FakeUsbPrinterChannel(printers: [fakeUsbPrinter()]);
      await _pump(tester, usb: usb);

      expect(find.text('TM-T20'), findsOneWidget);
      expect(find.text(_usbSummary), findsOneWidget);
      expect(find.text('USB and Bluetooth printers'), findsOneWidget);
    });

    testWidgets('it heads the list at 80mm + Text, and says it prints first', (
      tester,
    ) async {
      final usb = FakeUsbPrinterChannel(printers: [fakeUsbPrinter()]);
      final printer = await _pump(tester, usb: usb);

      expect(find.byKey(const Key('usb-printer-help')), findsNothing);
      final usbY = tester.getTopLeft(find.text('TM-T20')).dy;
      final btY = tester.getTopLeft(find.text('Counter printer')).dy;
      expect(usbY, lessThan(btY));
      expect(await printer.paperSizeFor(_usbId), ReceiptPaperSize.mm80);
      expect(await printer.printStyleFor(_usbId), ReceiptPrintStyle.text);

      await _tap(tester, find.text('TM-T20'));
      expect(find.text('USB. Receipts print here first'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a Bluetooth printer used more recently sits above USB '
        '(#724)', (tester) async {
      SharedPreferences.setMockInitialValues({
        'printer_recent_ids': [_large, _usbId],
      });
      final usb = FakeUsbPrinterChannel(printers: [fakeUsbPrinter()]);
      await _pump(tester, usb: usb);

      final recentY = tester.getTopLeft(find.text('Back office printer')).dy;
      final usbY = tester.getTopLeft(find.text('TM-T20')).dy;
      final unusedY = tester.getTopLeft(find.text('Counter printer')).dy;
      expect(recentY, lessThan(usbY));
      expect(usbY, lessThan(unusedY));
    });

    testWidgets('Test Print writes to the USB printer', (tester) async {
      SharedPreferences.setMockInitialValues({
        'printer_recent_ids': [_usbId],
      });
      final usb = FakeUsbPrinterChannel(printers: [fakeUsbPrinter()]);
      await _pump(tester, usb: usb);

      await tester.tap(find.byKey(const Key('usb-test-print-$_usbId')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // The sample receipt loads printer assets: needs real async time.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();

      // Test print opens the preview screen, which sends the print.
      expect(find.text('Printed'), findsOneWidget);
      expect(usb.writes.single.$1, _usbId);
      expect(String.fromCharCodes(usb.writes.single.$2), contains('ADA BAR'));
    });

    testWidgets('opening the screen asks access for a new USB printer', (
      tester,
    ) async {
      final usb = FakeUsbPrinterChannel(
        printers: [fakeUsbPrinter(hasPermission: false)],
      );
      await _pump(tester, usb: usb);

      expect(usb.permissionRequests, [_usbId]);
      expect(find.text(_usbSummary), findsOneWidget);
    });

    testWidgets('no USB printer shows the plug-in help line', (tester) async {
      await _pump(tester, usb: FakeUsbPrinterChannel());

      expect(
        find.text(
          'Plug an 80mm USB receipt printer into this tablet to use '
          'it.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('off Android there is no USB section', (tester) async {
      await _pump(tester, usb: FakeUsbPrinterChannel(isSupported: false));

      expect(find.byKey(const Key('usb-printer-help')), findsNothing);
    });
  });
}
