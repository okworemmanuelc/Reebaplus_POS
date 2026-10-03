// receipt_paper_size_prompt_test.dart
//
// Printers cannot report their paper width, so the app asks once per printer
// and remembers the answer. These tests pin when `prepareReceiptPrinter` asks
// and when it must stay quiet.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';
import 'package:reebaplus_pos/shared/services/printer_service.dart';
import 'package:reebaplus_pos/shared/widgets/receipt_paper_size_prompt.dart';

const _printer = '00:11:22:33:44:55';

/// Never touches the Bluetooth plugin: connection state is scripted.
class _FakePrinterService extends PrinterService {
  _FakePrinterService({required this.connected, this.autoConnects = false});

  final bool connected;
  final bool autoConnects;

  @override
  Future<bool> get isConnected async => connected;

  @override
  Future<bool> autoConnect() async => autoConnects;
}

/// Pumps a button that runs [prepareReceiptPrinter] and stores its result.
Future<Future<ReceiptPrinterTarget?> Function()> _pumpRunner(
  WidgetTester tester,
  PrinterService printer,
) async {
  ReceiptPrinterTarget? result;
  var done = false;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result = await prepareReceiptPrinter(context, printer);
              done = true;
            },
            child: const Text('print'),
          ),
        ),
      ),
    ),
  );
  return () async {
    await tester.pumpAndSettle();
    return done ? result : null;
  };
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a known printer prints at its saved size without asking', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'last_printer_mac': _printer,
      'printer_paper_size:$_printer': 'mm80',
    });
    final read = await _pumpRunner(tester, _FakePrinterService(connected: true));
    await tester.tap(find.text('print'));
    final result = await read();

    expect(find.text('Which paper does this printer use?'), findsNothing);
    expect(result, (connected: true, paperSize: ReceiptPaperSize.mm80));
  });

  testWidgets('a new printer asks once, then remembers the answer', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'last_printer_mac': _printer});
    final printer = _FakePrinterService(connected: true);
    final read = await _pumpRunner(tester, printer);
    await tester.tap(find.text('print'));
    await tester.pumpAndSettle();
    expect(find.text('Which paper does this printer use?'), findsOneWidget);

    await tester.tap(find.text('80mm'));
    final result = await read();

    expect(result, (connected: true, paperSize: ReceiptPaperSize.mm80));
    expect(await printer.paperSizeFor(_printer), ReceiptPaperSize.mm80);

    // Second print: no question.
    await tester.tap(find.text('print'));
    await tester.pumpAndSettle();
    expect(find.text('Which paper does this printer use?'), findsNothing);
  });

  testWidgets('the question cannot be dismissed by tapping outside', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'last_printer_mac': _printer});
    final read = await _pumpRunner(tester, _FakePrinterService(connected: true));
    await tester.tap(find.text('print'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(find.text('Which paper does this printer use?'), findsOneWidget);
    await tester.tap(find.text('58mm'));
    expect(
      await read(),
      (connected: true, paperSize: ReceiptPaperSize.mm58),
    );
  });

  testWidgets('an unreachable printer is not asked about', (tester) async {
    SharedPreferences.setMockInitialValues({'last_printer_mac': _printer});
    final read = await _pumpRunner(tester, _FakePrinterService(connected: false));
    await tester.tap(find.text('print'));
    final result = await read();

    expect(find.text('Which paper does this printer use?'), findsNothing);
    expect(result, (connected: false, paperSize: ReceiptPaperSize.mm58));
  });

  testWidgets('auto-connect counts as connected', (tester) async {
    SharedPreferences.setMockInitialValues({
      'last_printer_mac': _printer,
      'printer_paper_size:$_printer': 'mm58',
    });
    final read = await _pumpRunner(
      tester,
      _FakePrinterService(connected: false, autoConnects: true),
    );
    await tester.tap(find.text('print'));

    expect(
      await read(),
      (connected: true, paperSize: ReceiptPaperSize.mm58),
    );
  });
}
