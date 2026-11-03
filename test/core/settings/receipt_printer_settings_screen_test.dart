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

Future<PrinterService> _pump(
  WidgetTester tester, {
  FakeUsbPrinterChannel? usb,
}) async {
  final printer = _FakePrinterService(usb: usb);
  // Each card carries more controls now (print size, #676): tall enough
  // that the lazy list builds every card.
  tester.view.physicalSize = const Size(800, 4000);
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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('lists each printer, last-used first', (tester) async {
    SharedPreferences.setMockInitialValues({'last_printer_mac': _large});
    await _pump(tester);

    expect(find.text('Counter printer'), findsOneWidget);
    expect(find.text('Back office printer'), findsOneWidget);
    expect(find.text('Last used'), findsOneWidget);
    final lastUsedY = tester.getTopLeft(find.text('Back office printer')).dy;
    final otherY = tester.getTopLeft(find.text('Counter printer')).dy;
    expect(lastUsedY, lessThan(otherY));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a printer not set up yet says it will be asked', (tester) async {
    await _pump(tester);

    expect(find.text('Not set yet. Asked on first print'), findsNWidgets(2));
  });

  testWidgets('choosing a size saves it for that printer only', (tester) async {
    SharedPreferences.setMockInitialValues({
      'printer_paper_size:$_small': 'mm58',
    });
    final printer = await _pump(tester);

    // Second card's 80mm segment belongs to the back office printer.
    await tester.tap(find.text('80mm (large)').last);
    await tester.pumpAndSettle();

    expect(await printer.paperSizeFor(_large), ReceiptPaperSize.mm80);
    expect(await printer.paperSizeFor(_small), ReceiptPaperSize.mm58);
  });

  testWidgets(
    'print style defaults to text and switching saves it per printer',
    (tester) async {
      final printer = await _pump(tester);
      expect(await printer.printStyleFor(_large), ReceiptPrintStyle.text);
      expect(find.text('Text: fast and sharp (recommended)'), findsNWidgets(2));

      await tester.ensureVisible(find.text('Picture').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Picture').last);
      await tester.pumpAndSettle();

      expect(await printer.printStyleFor(_large), ReceiptPrintStyle.picture);
      expect(await printer.printStyleFor(_small), ReceiptPrintStyle.text);
      expect(find.text('Picture: matches the design exactly'), findsOneWidget);
    },
  );

  group('USB printers (#614)', () {
    testWidgets('a plugged-in USB printer is listed first at 80mm + Text', (
      tester,
    ) async {
      final usb = FakeUsbPrinterChannel(printers: [fakeUsbPrinter()]);
      final printer = await _pump(tester, usb: usb);

      expect(find.text('TM-T20'), findsOneWidget);
      expect(find.text('USB. Receipts print here first'), findsOneWidget);
      expect(find.byKey(const Key('usb-printer-help')), findsNothing);
      final usbY = tester.getTopLeft(find.text('TM-T20')).dy;
      final btY = tester.getTopLeft(find.text('Counter printer')).dy;
      expect(usbY, lessThan(btY));
      expect(await printer.paperSizeFor('usb:1208:514'), ReceiptPaperSize.mm80);
      expect(
        await printer.printStyleFor('usb:1208:514'),
        ReceiptPrintStyle.text,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Test print writes to the USB printer', (tester) async {
      final usb = FakeUsbPrinterChannel(printers: [fakeUsbPrinter()]);
      await _pump(tester, usb: usb);

      await tester.tap(find.byKey(const Key('usb-test-print-usb:1208:514')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // The sample receipt loads printer assets: needs real async time.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();

      // Test print opens the preview screen, which sends the print.
      expect(find.text('Printed'), findsOneWidget);
      expect(usb.writes.single.$1, 'usb:1208:514');
      expect(String.fromCharCodes(usb.writes.single.$2), contains('ADA BAR'));
    });

    testWidgets('opening the screen asks access for a new USB printer', (
      tester,
    ) async {
      final usb = FakeUsbPrinterChannel(
        printers: [fakeUsbPrinter(hasPermission: false)],
      );
      await _pump(tester, usb: usb);

      expect(usb.permissionRequests, ['usb:1208:514']);
      expect(find.text('USB. Receipts print here first'), findsOneWidget);
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

  testWidgets(
    'print size defaults to Full and switching saves it per printer (#676)',
    (tester) async {
      final printer = await _pump(tester);
      expect(await printer.receiptSizeFor(_small), ReceiptSize.full);

      await tester.tap(find.text('Compact').last);
      await tester.pumpAndSettle();

      expect(await printer.receiptSizeFor(_large), ReceiptSize.compact);
      expect(await printer.receiptSizeFor(_small), ReceiptSize.full);
      expect(find.byKey(const Key('bt-test-print-$_small')), findsOneWidget);
    },
  );
}
