// #659: the supplier "Record crate activity" sheet stays open with a spinner
// until the save finishes. Two quick taps save once; success closes the sheet;
// a failure keeps it open; a sheet dragged away mid-save never pops the screen.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/inventory/screens/supplier_detail_screen.dart';
import 'package:reebaplus_pos/shared/services/supplier_crate_service.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

import '../helpers/screen_harness.dart';

class _SlowCrates extends SupplierCrateService {
  _SlowCrates(super.db);

  int receipts = 0;
  Completer<void> gate = Completer<void>();
  bool fail = false;

  @override
  Future<void> recordReceipt({
    required String supplierId,
    required String supplierName,
    required String manufacturerId,
    required String manufacturerName,
    required double quantity,
    required String staffId,
    String? storeId,
    int depositPaidKobo = 0,
    String? note,
  }) async {
    receipts++;
    await gate.future;
    if (fail) throw StateError('boom');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late _SlowCrates crates;
  late String supplierId;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      businessType: 'Bar',
      manufacturerCount: 1,
    );
    supplierId = await env.db.catalogDao.insertSupplier(
      SuppliersCompanion.insert(businessId: env.businessId, name: 'Depot'),
    );
    crates = _SlowCrates(env.db);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> openSheetAndFill(WidgetTester tester) async {
    await pumpScreen(
      tester,
      env: env,
      size: const Size(412, 915),
      screen: SupplierDetailScreen(supplierId: supplierId),
      grantedKeys: const {'suppliers.manage', 'sales.make'},
      overrides: [supplierCrateServiceProvider.overrideWithValue(crates)],
      settle: false,
    );
    await settle(tester);
    // The crate card lives on the Empty Crates tab.
    await tester.drag(find.byType(NestedScrollView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Empty Crates').last);
    await settle(tester);
    final card = find.text('Record crate activity');
    await tester.ensureVisible(card);
    await tester.tap(card);
    await settle(tester);
    await tester.tap(find.byType(AppDropdown<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(env.manufacturers.first.name).last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(AppInput).first, '3');
    await tester.pump();
  }

  Finder saveButton() => find.widgetWithText(AppButton, 'Record Receipt');

  testWidgets('two quick taps save once; the sheet spins, then closes',
      (tester) async {
    await openSheetAndFill(tester);
    await tester.tap(saveButton());
    await tester.tap(saveButton());
    expect(crates.receipts, 1);
    await tester.pump();
    expect(saveButton(), findsOneWidget, reason: 'sheet stays open while saving');
    expect(
      find.descendant(
        of: saveButton(),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );

    crates.gate.complete();
    await settle(tester);
    expect(saveButton(), findsNothing, reason: 'sheet closes on success');
    expect(crates.receipts, 1);
    expect(find.byType(SupplierDetailScreen), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('a failed save keeps the sheet open with what was typed',
      (tester) async {
    await openSheetAndFill(tester);
    await tester.tap(saveButton());
    await tester.pump();
    expect(crates.receipts, 1);
    crates.fail = true;
    crates.gate.complete();
    await settle(tester);
    expect(saveButton(), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(
      find.text('Could not record crate activity. Please try again.'),
      findsOneWidget,
    );
    AppNotification.hide();
    await disposeScreen(tester);
  });

  testWidgets('a sheet dragged away mid-save does not pop the screen',
      (tester) async {
    await openSheetAndFill(tester);
    await tester.tap(saveButton());
    await tester.pump();
    // Swipe the sheet down and away.
    await tester.drag(find.byType(AppDropdown<String>), const Offset(0, 900));
    await settle(tester);
    crates.gate.complete();
    await settle(tester);
    expect(find.byType(SupplierDetailScreen), findsOneWidget);
    await disposeScreen(tester);
  });
}
