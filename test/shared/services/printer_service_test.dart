import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';
import 'package:reebaplus_pos/shared/services/printer_service.dart';

import '../../helpers/fake_usb_printer_channel.dart';

class _FakePrinterService extends PrinterService {
  _FakePrinterService({
    super.writeBytes,
    super.connectToPrinter,
    super.wait,
    super.isAndroid,
    super.usb,
    this.connected = true,
  });

  final bool connected;

  @override
  Future<bool> get isConnected async => connected;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('PrinterService', () {
    test(
      '1. Android printBytesDirectly(body): writes [1B 40], then wait(500ms), then body unsplit',
      () async {
        final written = <List<int>>[];
        final waited = <Duration>[];

        final service = _FakePrinterService(
          isAndroid: true,
          writeBytes: (bytes) async {
            written.add(bytes);
            return true;
          },
          wait: (d) async {
            waited.add(d);
          },
        );

        final body = [0x01, 0x02, 0x03, 0x04];
        final result = await service.printBytesDirectly(body);

        expect(result, isTrue);
        expect(written.length, 2);
        expect(written[0], [0x1B, 0x40]);
        expect(waited, [const Duration(milliseconds: 500)]);
        expect(written[1], body);
      },
    );

    test(
      '2. Android: the ESC @ write returns false -> result false, body never written',
      () async {
        final written = <List<int>>[];
        final waited = <Duration>[];

        final service = _FakePrinterService(
          isAndroid: true,
          writeBytes: (bytes) async {
            written.add(bytes);
            return false;
          },
          wait: (d) async {
            waited.add(d);
          },
        );

        final body = [0x01, 0x02, 0x03];
        final result = await service.printBytesDirectly(body);

        expect(result, isFalse);
        expect(written.length, 1);
        expect(written[0], [0x1B, 0x40]);
        expect(waited, isEmpty);
      },
    );

    test('3. Not Android: body only, no ESC @, no wait', () async {
      final written = <List<int>>[];
      final waited = <Duration>[];

      final service = _FakePrinterService(
        isAndroid: false,
        writeBytes: (bytes) async {
          written.add(bytes);
          return true;
        },
        wait: (d) async {
          waited.add(d);
        },
      );

      final body = [0x10, 0x20, 0x30];
      final result = await service.printBytesDirectly(body);

      expect(result, isTrue);
      expect(written.length, 1);
      expect(written[0], body);
      expect(waited, isEmpty);
    });

    test(
      '4. Android connect(): success -> wait(1000ms) then true; failure -> no wait, false',
      () async {
        // Success case
        final waitedSuccess = <Duration>[];
        final serviceSuccess = _FakePrinterService(
          isAndroid: true,
          connectToPrinter: (mac) async => true,
          wait: (d) async {
            waitedSuccess.add(d);
          },
        );

        final ok = await serviceSuccess.connect('00:11:22:33:44:55');
        expect(ok, isTrue);
        expect(waitedSuccess, [const Duration(milliseconds: 1000)]);

        // Failure case
        final waitedFailure = <Duration>[];
        final serviceFailure = _FakePrinterService(
          isAndroid: true,
          connectToPrinter: (mac) async => false,
          wait: (d) async {
            waitedFailure.add(d);
          },
        );

        final failed = await serviceFailure.connect('00:11:22:33:44:55');
        expect(failed, isFalse);
        expect(waitedFailure, isEmpty);
      },
    );

    test(
      '5. printBytes with a live connection uses the same ESC @ -> wait -> body sequence',
      () async {
        final written = <List<int>>[];
        final waited = <Duration>[];

        final service = _FakePrinterService(
          isAndroid: true,
          connected: true,
          writeBytes: (bytes) async {
            written.add(bytes);
            return true;
          },
          wait: (d) async {
            waited.add(d);
          },
        );

        final body = [0xAA, 0xBB, 0xCC];
        final result = await service.printBytes(body);

        expect(result, isTrue);
        expect(written.length, 2);
        expect(written[0], [0x1B, 0x40]);
        expect(waited, [const Duration(milliseconds: 500)]);
        expect(written[1], body);
      },
    );
  });

  group('per-printer paper size', () {
    const printerA = '00:11:22:33:44:55';
    const printerB = '66:77:88:99:AA:BB';

    test('a printer that was never set up has no paper size', () async {
      expect(await PrinterService().paperSizeFor(printerA), isNull);
    });

    test('each printer keeps its own paper size', () async {
      final service = PrinterService();
      await service.savePaperSizeFor(printerA, ReceiptPaperSize.mm80);
      await service.savePaperSizeFor(printerB, ReceiptPaperSize.mm58);

      expect(await service.paperSizeFor(printerA), ReceiptPaperSize.mm80);
      expect(await service.paperSizeFor(printerB), ReceiptPaperSize.mm58);
    });

    test('a successful connect records the printer in use', () async {
      final service = _FakePrinterService(
        connectToPrinter: (mac) async => true,
        wait: (_) async {},
      );
      expect(await service.lastConnectedMac(), isNull);

      await service.connect(printerB);

      expect(await service.lastConnectedMac(), printerB);
    });

    test('a failed connect does not change the printer in use', () async {
      SharedPreferences.setMockInitialValues({'last_printer_mac': printerA});
      final service = _FakePrinterService(
        connectToPrinter: (mac) async => false,
        wait: (_) async {},
      );

      await service.connect(printerB);

      expect(await service.lastConnectedMac(), printerA);
    });

    test(
      'the old device-wide size moves onto the printer used with it',
      () async {
        SharedPreferences.setMockInitialValues({
          'last_printer_mac': printerA,
          'printer_paper_size': 'mm80',
        });
        final service = _FakePrinterService(
          connectToPrinter: (mac) async => true,
          wait: (_) async {},
        );

        // Connecting to a different printer must not steal the old answer.
        await service.connect(printerB);

        expect(await service.paperSizeFor(printerA), ReceiptPaperSize.mm80);
        expect(await service.paperSizeFor(printerB), isNull);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey('printer_paper_size'), isFalse);
      },
    );

    test('the old size is dropped when no printer was ever used', () async {
      SharedPreferences.setMockInitialValues({'printer_paper_size': 'mm80'});
      final service = PrinterService();

      expect(await service.paperSizeFor(printerA), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('printer_paper_size'), isFalse);
    });
  });

  group('hasPrinterSetUp (#614 auto-print)', () {
    test('nothing plugged in and no Bluetooth printer used -> false', () async {
      final service = _FakePrinterService(usb: FakeUsbPrinterChannel());
      expect(await service.hasPrinterSetUp(), isFalse);
    });

    test('a USB printer plugged in -> true', () async {
      final service = _FakePrinterService(
        usb: FakeUsbPrinterChannel(printers: [fakeUsbPrinter()]),
      );
      expect(await service.hasPrinterSetUp(), isTrue);
    });

    test('a Bluetooth printer used before -> true', () async {
      SharedPreferences.setMockInitialValues({
        'last_printer_mac': '00:11:22:33:44:55',
      });
      final service = _FakePrinterService(usb: FakeUsbPrinterChannel());
      expect(await service.hasPrinterSetUp(), isTrue);
    });
  });

  group('USB first, Bluetooth backup (#614)', () {
    const btMac = '00:11:22:33:44:55';
    final body = [0x1B, 0x40, 0x41, 0x42];

    ({_FakePrinterService service, List<List<int>> btWrites}) build(
      FakeUsbPrinterChannel usb,
    ) {
      final btWrites = <List<int>>[];
      final service = _FakePrinterService(
        isAndroid: true,
        usb: usb,
        wait: (_) async {},
        writeBytes: (bytes) async {
          btWrites.add(bytes);
          return true;
        },
      );
      return (service: service, btWrites: btWrites);
    }

    test(
      'an attached USB printer gets the bytes as-is, no Bluetooth',
      () async {
        final usb = FakeUsbPrinterChannel(printers: [fakeUsbPrinter()]);
        final r = build(usb);

        expect(await r.service.printBytes(body), isTrue);
        expect(usb.writes.single.$1, 'usb:1208:514');
        // No ESC @ wake write and no wake gap: the job goes over unchanged.
        expect(usb.writes.single.$2, body);
        expect(r.btWrites, isEmpty);
      },
    );

    test('a failed USB write falls back to Bluetooth', () async {
      final usb = FakeUsbPrinterChannel(
        printers: [fakeUsbPrinter()],
        writeSucceeds: false,
      );
      final r = build(usb);

      expect(await r.service.printBytes(body), isTrue);
      expect(usb.writes, hasLength(1));
      expect(r.btWrites, [
        [0x1B, 0x40],
        body,
      ]);
    });

    test('no USB printer prints on Bluetooth', () async {
      final usb = FakeUsbPrinterChannel();
      final r = build(usb);

      expect(await r.service.printBytes(body), isTrue);
      expect(usb.writes, isEmpty);
      expect(r.btWrites.last, body);
    });

    test('USB access denied prints on Bluetooth and asks only once', () async {
      final usb = FakeUsbPrinterChannel(
        printers: [fakeUsbPrinter(hasPermission: false)],
        grantPermission: false,
      );
      final r = build(usb);

      expect(await r.service.printBytes(body), isTrue);
      expect(await r.service.printBytes(body), isTrue);
      expect(usb.permissionRequests, ['usb:1208:514']);
      expect(usb.writes, isEmpty);
      expect(r.btWrites.where((b) => b == body), hasLength(2));
    });

    test('USB access granted on the prompt prints on USB', () async {
      final usb = FakeUsbPrinterChannel(
        printers: [fakeUsbPrinter(hasPermission: false)],
      );
      final r = build(usb);

      expect(await r.service.printBytes(body), isTrue);
      expect(usb.writes, hasLength(1));
      expect(r.btWrites, isEmpty);
    });

    test(
      'a USB printer seen for the first time is saved as 80mm + Text',
      () async {
        SharedPreferences.setMockInitialValues({
          'printer_print_style:usb:9:9': 'picture',
        });
        final usb = FakeUsbPrinterChannel(
          printers: [
            fakeUsbPrinter(),
            fakeUsbPrinter(id: 'usb:9:9'),
          ],
        );
        final service = build(usb).service;

        await service.usbPrinters();

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('printer_paper_size:usb:1208:514'), 'mm80');
        expect(prefs.getString('printer_print_style:usb:1208:514'), 'text');
        // An existing choice is never overwritten.
        expect(
          await service.printStyleFor('usb:9:9'),
          ReceiptPrintStyle.picture,
        );
      },
    );

    test('a saved USB choice is kept on the next sighting', () async {
      SharedPreferences.setMockInitialValues({
        'printer_paper_size:usb:1208:514': 'mm58',
      });
      final service = build(
        FakeUsbPrinterChannel(printers: [fakeUsbPrinter()]),
      ).service;

      await service.attachedUsbPrinter();

      expect(await service.paperSizeFor('usb:1208:514'), ReceiptPaperSize.mm58);
    });

    test(
      'currentPrinterId: allowed USB, else last Bluetooth, else none',
      () async {
        SharedPreferences.setMockInitialValues({'last_printer_mac': btMac});
        final usb = FakeUsbPrinterChannel(printers: [fakeUsbPrinter()]);
        final service = build(usb).service;

        expect(await service.currentPrinterId(), 'usb:1208:514');

        usb.printers = [fakeUsbPrinter(hasPermission: false)];
        expect(await service.currentPrinterId(), btMac);
        // Looking up the current printer never shows the permission prompt.
        expect(usb.permissionRequests, isEmpty);

        usb.printers = [];
        expect(await service.currentPrinterId(), btMac);

        SharedPreferences.setMockInitialValues({});
        expect(await service.currentPrinterId(), isNull);
      },
    );

    test(
      'currentPrintStyle reads the USB printer when one is attached',
      () async {
        SharedPreferences.setMockInitialValues({
          'last_printer_mac': btMac,
          'printer_print_style:$btMac': 'picture',
          'printer_print_style:usb:1208:514': 'text',
        });
        final usb = FakeUsbPrinterChannel(printers: [fakeUsbPrinter()]);
        final service = build(usb).service;

        expect(await service.currentPrintStyle(), ReceiptPrintStyle.text);
        usb.printers = [];
        expect(await service.currentPrintStyle(), ReceiptPrintStyle.picture);
      },
    );

    test('printBytesDirectly stays Bluetooth-only', () async {
      final usb = FakeUsbPrinterChannel(printers: [fakeUsbPrinter()]);
      final r = build(usb);

      expect(await r.service.printBytesDirectly(body), isTrue);
      expect(usb.writes, isEmpty);
      expect(r.btWrites.last, body);
    });

    test('test print writes a cut slip to the USB printer', () async {
      final usb = FakeUsbPrinterChannel(printers: [fakeUsbPrinter()]);
      final service = build(usb).service;

      expect(
        await service.testPrintUsb('usb:1208:514', businessName: 'Ada Bar'),
        isTrue,
      );
      final bytes = usb.writes.single.$2;
      expect(bytes.take(2), [0x1B, 0x40]);
      expect(bytes.skip(bytes.length - 4), [0x1D, 0x56, 0x42, 0x00]);
      final text = String.fromCharCodes(bytes);
      expect(text, contains('Ada Bar'));
      expect(text, contains('Test print'));
      expect(text, contains('Paper: 80mm'));
    });
  });

  group('receipt size + Bluetooth test print (#676)', () {
    test('receipt size is per printer and defaults to full', () async {
      final service = _FakePrinterService();
      expect(await service.receiptSizeFor('aa'), ReceiptSize.full);
      await service.saveReceiptSizeFor('aa', ReceiptSize.compact);
      expect(await service.receiptSizeFor('aa'), ReceiptSize.compact);
      expect(await service.receiptSizeFor('bb'), ReceiptSize.full);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('printer_receipt_size:aa'), 'compact');
    });

    test('test slip: full is unchanged, compact 58mm adds Font B + ruler', () {
      final full = PrinterService.buildTestPrintBytes(
        paperSize: ReceiptPaperSize.mm58,
        printStyle: ReceiptPrintStyle.text,
      );
      expect(String.fromCharCodes(full), isNot(contains('Compact')));
      final compact = PrinterService.buildTestPrintBytes(
        paperSize: ReceiptPaperSize.mm58,
        printStyle: ReceiptPrintStyle.text,
        receiptSize: ReceiptSize.compact,
      );
      expect(compact.sublist(2, 5), [0x1B, 0x4D, 0x01]);
      final text = String.fromCharCodes(compact);
      expect(text, contains('Size: Compact'));
      expect(
        text,
        contains(
          '123456789012345678901234567890123456789012'.replaceAll('0', '0'),
        ),
      );
    });

    test(
      'testPrintBluetooth connects to the printer and writes the slip',
      () async {
        final written = <List<int>>[];
        final connected = <String>[];
        final service = _FakePrinterService(
          connected: false,
          isAndroid: false,
          connectToPrinter: (mac) async {
            connected.add(mac);
            return true;
          },
          wait: (_) async {},
          writeBytes: (b) async {
            written.add(b);
            return true;
          },
        );
        await service.saveReceiptSizeFor('aa', ReceiptSize.compact);
        final ok = await service.testPrintBluetooth('aa', businessName: 'Ada');
        expect(ok, isTrue);
        expect(connected, ['aa']);
        expect(String.fromCharCodes(written.single), contains('Size: Compact'));
      },
    );
  });
}
