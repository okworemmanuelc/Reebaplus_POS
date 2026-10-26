import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/shared/scanner/manual_entry_barcode_scanner.dart';

void main() {
  test('camera scanning is gated by platform (#61)', () {
    for (final p in [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    ]) {
      expect(cameraScanningSupported(platform: p, isWeb: false), isTrue);
    }
    expect(cameraScanningSupported(platform: TargetPlatform.windows, isWeb: false), isFalse);
    expect(cameraScanningSupported(platform: TargetPlatform.linux, isWeb: false), isFalse);
    expect(cameraScanningSupported(platform: TargetPlatform.windows, isWeb: true), isTrue);
  });

  testWidgets('manual entry hands typed codes to onCode and stays open', (
    tester,
  ) async {
    final codes = <String>[];
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      ),
    );
    const ManualEntryBarcodeScanner().scanSession(
      ctx,
      onCode: (_, code) async => codes.add(code),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('manual-barcode-input')), ' 12345 ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('manual-barcode-input')), '999');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(codes, ['12345', '999']);
    expect(find.byKey(const Key('manual-barcode-dialog')), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('manual-barcode-dialog')), findsNothing);
  });
}
