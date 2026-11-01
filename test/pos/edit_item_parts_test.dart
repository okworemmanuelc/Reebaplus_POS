import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/features/pos/widgets/edit_item_modal.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

import '../helpers/screen_harness.dart';
import 'sales_sheet_hosts.dart';

/// #628 — the Edit Quantity sheet (reached from the till, a scan and the cart):
/// ±0.5 on a product in parts, none on a whole-numbers product, and a typed
/// quantity that can't be saved stops the sheet.
void main() {
  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(productCount: 1);
  });
  tearDown(() async => env.dispose());

  Future<void> open(WidgetTester tester, {required bool allowParts}) async {
    await pumpScreen(
      tester,
      env: env,
      size: const Size(390, 844),
      padding: const EdgeInsets.only(top: 24, bottom: 48),
      grantedKeys: const {'sales.make'},
      screen: Scaffold(
        body: Center(
          child: Builder(
            builder: (context) => TextButton(
              key: kOpenSheetKey,
              onPressed: () => EditItemModal.show(context, {
                ...editItemLine(),
                'allowFractionalSales': allowParts,
              }),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      settle: false,
    );
    await settleSheet(tester);
    await tester.tap(find.byKey(kOpenSheetKey));
    await settleSheet(tester);
  }

  Finder qtyField() => find.descendant(
    of: find.byKey(EditItemKeys.quantity),
    matching: find.byType(TextField),
  );

  String qtyText(WidgetTester tester) =>
      tester.widget<TextField>(qtyField()).controller!.text;

  AppButton saveButton(WidgetTester tester) => tester.widget<AppButton>(
    find.ancestor(
      of: find.text('Save Changes'),
      matching: find.byType(AppButton),
    ),
  );

  testWidgets('switch on: ±0.5 chips move in halves and display decimals', (
    tester,
  ) async {
    await open(tester, allowParts: true);
    expect(qtyText(tester), '2');
    await tester.tap(find.text('+0.5'));
    await tester.pump();
    expect(qtyText(tester), '2.5');
    await tester.tap(find.text('-0.5'));
    await tester.tap(find.text('-0.5'));
    await tester.tap(find.text('-0.5'));
    await tester.tap(find.text('-0.5'));
    await tester.pump();
    expect(qtyText(tester), '0.5');
    await tester.tap(find.text('-0.5'));
    await tester.pump();
    expect(qtyText(tester), '0.5', reason: 'the buttons stop at 0.5');
  });

  testWidgets('switch on: 0.25 and 0.75 can be typed; 0.3 cannot be saved', (
    tester,
  ) async {
    await open(tester, allowParts: true);
    await tester.enterText(qtyField(), '0.25');
    await tester.pump();
    expect(find.byKey(EditItemKeys.qtyError), findsNothing);
    expect(saveButton(tester).onPressed, isNotNull);

    await tester.enterText(qtyField(), '0.3');
    await tester.pump();
    expect(find.byKey(EditItemKeys.qtyError), findsOneWidget);
    expect(saveButton(tester).onPressed, isNull);

    await tester.enterText(qtyField(), '0.75');
    await tester.pump();
    expect(find.byKey(EditItemKeys.qtyError), findsNothing);
  });

  testWidgets('switch off: no chips, the − stops at 1, a part cannot be saved', (
    tester,
  ) async {
    await open(tester, allowParts: false);
    expect(find.text('+0.5'), findsNothing);
    expect(find.text('-0.5'), findsNothing);

    await tester.tap(find.byKey(EditItemKeys.minus));
    await tester.tap(find.byKey(EditItemKeys.minus));
    await tester.pump();
    expect(qtyText(tester), '1');

    await tester.enterText(qtyField(), '1.5');
    await tester.pump();
    expect(find.byKey(EditItemKeys.qtyError), findsOneWidget);
    expect(saveButton(tester).onPressed, isNull);
  });
}
