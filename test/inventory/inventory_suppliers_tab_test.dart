import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/features/inventory/screens/inventory_screen.dart';
import 'package:reebaplus_pos/features/payments/widgets/supplier_form_sheet.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const inventoryGrantsWithSuppliers = {
    'sales.make',
    'stock.view',
    'products.add',
    'stock.add',
    'products.edit_price',
    'suppliers.manage',
  };

  group('InventoryScreen Suppliers tab', () {
    late ScreenTestEnvironment env;

    setUp(() async {
      env = await setupScreenTestEnvironment(productCount: 2);
      // pumpScreen signs in 'test-user-id'; the sheet's save logs activity
      // against that staff id, so the users row must exist (FK).
      await env.db.into(env.db.users).insert(
            UsersCompanion.insert(
              id: const Value('test-user-id'),
              businessId: env.businessId,
              name: 'Test Admin',
              pin: '1234',
            ),
          );
    });

    tearDown(() async {
      await env.dispose();
    });

    testWidgets(
        'Suppliers tab: Add Supplier saves via SupplierFormSheet and the list updates reactively',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        screen: const InventoryScreen(),
        grantedKeys: inventoryGrantsWithSuppliers,
        overrides: [
          firstRunSurfaceStateProvider
              .overrideWithValue(FirstRunSurfaceState.hasContent),
        ],
      );

      // Tap the Suppliers tab
      await tester.tap(find.text('Suppliers'));
      await tester.pumpAndSettle();

      // Verify empty state
      expect(find.text('No suppliers added yet'), findsOneWidget);

      // Tap "Add Supplier" button
      final addSupplierBtn = find.widgetWithText(AppButton, 'Add Supplier');
      expect(addSupplierBtn, findsOneWidget);
      await tester.tap(addSupplierBtn);
      await tester.pumpAndSettle();

      // Verify that SupplierFormSheet is displayed
      final sheet = find.byType(SupplierFormSheet);
      expect(sheet, findsOneWidget);

      // Fill the form through the real sheet (not a direct DAO insert)
      await tester.enterText(
        find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              w.decoration?.hintText == 'e.g. SABMiller Nigeria',
        ),
        'Guinness Nigeria',
      );
      await tester.pumpAndSettle();

      // Tap the sheet's own "Add Supplier" (the tab has one too)
      await tester.tap(
        find.descendant(
          of: sheet,
          matching: find.widgetWithText(AppButton, 'Add Supplier'),
        ),
      );
      await tester.pumpAndSettle();

      // Confirm the save prompt
      await tester.tap(find.widgetWithText(AppButton, 'Save'));
      await tester.pumpAndSettle();

      // Sheet closes and the tab reactively shows the saved supplier
      expect(find.byType(SupplierFormSheet), findsNothing);
      expect(find.text('Guinness Nigeria'), findsOneWidget);

      await disposeScreen(tester);
    });
  });
}
