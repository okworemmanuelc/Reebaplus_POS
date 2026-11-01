import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/features/stores/widgets/stock_request_quantity_sheet.dart';

/// Request Stock quantity sheet + list in parts (#630).
void main() {
  Future<double?> openSheet(
    WidgetTester tester, {
    required bool parts,
    required String typed,
  }) async {
    double? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  result = await StockRequestQuantitySheet.show(
                    context,
                    productName: 'Rice',
                    sourceStoreName: 'Main',
                    available: 2.5,
                    allowParts: parts,
                    initialQuantity: 1,
                  ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Main has 2.5'), findsOneWidget);
    await tester.enterText(
      find.byKey(StockRequestQuantitySheetKeys.field),
      typed,
    );
    await tester.tap(find.byKey(StockRequestQuantitySheetKeys.save));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('switch on: 0.75 is returned', (tester) async {
    expect(await openSheet(tester, parts: true, typed: '0.75'), 0.75);
  });

  testWidgets('switch on: 0.3 is refused with the quarter wording', (
    tester,
  ) async {
    expect(await openSheet(tester, parts: true, typed: '0.3'), isNull);
    expect(find.textContaining('quarters'), findsOneWidget);
  });

  testWidgets('switch off: the dot is filtered, a whole number returns', (
    tester,
  ) async {
    expect(await openSheet(tester, parts: false, typed: '1.5'), 15);
  });
}
