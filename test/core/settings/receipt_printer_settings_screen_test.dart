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
import 'package:reebaplus_pos/core/settings/receipt_printer_settings_screen.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';
import 'package:reebaplus_pos/shared/services/printer_service.dart';

const _small = '00:11:22:33:44:55';
const _large = '66:77:88:99:AA:BB';

/// Never touches the Bluetooth plugin or `permission_handler`.
class _FakePrinterService extends PrinterService {
  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<List<BluetoothInfo>> getPairedDevices() async => [
    BluetoothInfo(name: 'Counter printer', macAdress: _small),
    BluetoothInfo(name: 'Back office printer', macAdress: _large),
  ];
}

Future<PrinterService> _pump(WidgetTester tester) async {
  final printer = _FakePrinterService();
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

  testWidgets('a printer not set up yet says it will be asked', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('Not set yet. Asked on first print'), findsNWidgets(2));
  });

  testWidgets('choosing a size saves it for that printer only', (
    tester,
  ) async {
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
}
