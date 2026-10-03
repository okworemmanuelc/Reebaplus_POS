import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';
import 'package:reebaplus_pos/shared/services/printer_service.dart';

class _FakePrinterService extends PrinterService {
  _FakePrinterService({
    super.writeBytes,
    super.connectToPrinter,
    super.wait,
    super.isAndroid,
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

    test('the old device-wide size moves onto the printer used with it',
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
    });

    test('the old size is dropped when no printer was ever used', () async {
      SharedPreferences.setMockInitialValues({'printer_paper_size': 'mm80'});
      final service = PrinterService();

      expect(await service.paperSizeFor(printerA), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('printer_paper_size'), isFalse);
    });
  });
}
