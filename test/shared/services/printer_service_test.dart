import 'package:flutter_test/flutter_test.dart';
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
}
