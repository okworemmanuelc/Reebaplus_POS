// Test print preview (#702): prints on open, shows the same sample receipt,
// and Print again retries after a failure.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/pos/widgets/paper_receipt.dart';
import 'package:reebaplus_pos/features/settings/screens/test_print_preview_screen.dart';
import 'package:reebaplus_pos/shared/services/printer_service.dart';

const _id = '00:11:22:33:44:55';

Future<void> _pump(WidgetTester tester, TestPrintSender send) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        printerServiceProvider.overrideWithValue(PrinterService()),
        currentBusinessNameProvider.overrideWithValue('Ada Bar'),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: TestPrintPreviewScreen(
          printerId: _id,
          printerName: 'Counter printer',
          send: send,
          saleDate: DateTime(2026, 11, 3, 10, 30),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('prints at once without waiting, then shows Printed', (
    tester,
  ) async {
    final gate = Completer<bool>();
    var sent = 0;
    await _pump(tester, (_, _, _) {
      sent++;
      return gate.future;
    });

    // The print started on the first frame, before the preview settled.
    expect(sent, 1);
    expect(find.text('Printing...'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('test-print-preview')), findsOneWidget);
    expect(find.textContaining('Spaghetti 500g'), findsOneWidget);
    expect(find.text('Counter printer · 58mm · Full'), findsOneWidget);

    gate.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('Printed'), findsOneWidget);
    expect(sent, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed print says so and Print again retries', (tester) async {
    var sent = 0;
    await _pump(tester, (_, _, _) async {
      sent++;
      return sent > 1;
    });
    await tester.pumpAndSettle();

    expect(find.textContaining('Failed'), findsOneWidget);
    expect(sent, 1);

    await tester.tap(find.byKey(const Key('test-print-again')));
    await tester.pumpAndSettle();

    expect(sent, 2);
    expect(find.text('Printed'), findsOneWidget);
  });

  testWidgets('Full picture style previews the paper receipt widget', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'printer_paper_size:$_id': 'mm80',
      'printer_print_style:$_id': 'picture',
    });
    await _pump(tester, (_, _, _) async => true);
    await tester.pumpAndSettle();

    expect(find.byType(PaperReceipt), findsOneWidget);
    expect(find.byType(ReceiptLinesPreview), findsNothing);
    expect(find.text('Counter printer · 80mm · Full'), findsOneWidget);
  });

  testWidgets('compact shows the column ruler and the size in the header', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'printer_paper_size:$_id': 'mm58',
      'printer_receipt_size:$_id': 'compact',
    });
    await _pump(tester, (_, _, _) async => true);
    await tester.pumpAndSettle();

    expect(find.text('Counter printer · 58mm · Compact'), findsOneWidget);
    expect(
      find.text('123456789012345678901234567890123456789012'),
      findsOneWidget,
    );
  });
}
