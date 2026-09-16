import 'package:drift/drift.dart';
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
    });

    tearDown(() async {
      await env.dispose();
    });

    testWidgets(
        'Suppliers tab shows reactive supplier list and Add Supplier opens SupplierFormSheet',
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
      expect(find.byType(SupplierFormSheet), findsOneWidget);

      // Close the sheet
      Navigator.of(tester.element(find.byType(SupplierFormSheet))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(SupplierFormSheet), findsNothing);

      // Insert a supplier into Drift database
      await env.db.catalogDao.insertSupplier(
        SuppliersCompanion.insert(
          businessId: env.businessId,
          name: 'Guinness Nigeria',
          phone: const Value('08099998888'),
        ),
      );
      await tester.pumpAndSettle();

      // The tab should reactively show the newly added supplier
      expect(find.text('Guinness Nigeria'), findsOneWidget);
      expect(find.text('08099998888'), findsOneWidget);

      await disposeScreen(tester);
    });
  });
}
