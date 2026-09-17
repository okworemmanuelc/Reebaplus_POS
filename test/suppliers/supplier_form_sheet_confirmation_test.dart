import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/payments/widgets/supplier_form_sheet.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

void main() {
  late AppDatabase db;
  const businessId = 'biz-1';
  const userId = 'user-1';

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://placeholder.supabase.co',
      anonKey: 'placeholder',
    );
  });

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    db.businessIdResolver = () => businessId;
    await db.customSelect('SELECT 1').get();

    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(
            id: const Value(businessId),
            name: 'Test Biz',
            type: const Value('beverage_distributor'),
          ),
        );
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: const Value(userId),
            businessId: businessId,
            name: 'Test User',
            pin: '0000',
            avatarColor: const Value('#3B82F6'),
            biometricEnabled: const Value(false),
          ),
        );
  });

  tearDown(() => db.close());

  testWidgets(
      'SupplierFormSheet prompts confirmation before saving and aborts on Cancel',
      (tester) async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        currentUserPermissionsProvider.overrideWithValue({'suppliers.manage'}),
      ],
    );

    final user = await db.storesDao.getUserById(userId);
    container.read(authProvider).value = user;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: SupplierFormSheet(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Fill in name
    final nameField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == 'e.g. SABMiller Nigeria',
    );
    expect(nameField, findsOneWidget);
    await tester.enterText(nameField, 'Acme Breweries');
    await tester.pumpAndSettle();

    // Tap Add Supplier button
    final submitButton = find.widgetWithText(AppButton, 'Add Supplier');
    expect(submitButton, findsOneWidget);
    await tester.tap(submitButton);
    await tester.pumpAndSettle();

    // Confirmation dialog should be visible
    expect(find.text('Save Supplier?'), findsOneWidget);
    expect(find.text('Are you sure you want to save "Acme Breweries"?'), findsOneWidget);

    // Tap Cancel
    final cancelButton = find.widgetWithText(AppButton, 'Cancel');
    expect(cancelButton, findsOneWidget);
    await tester.tap(cancelButton);
    await tester.pumpAndSettle();

    // Dialog closed, sheet still present, no supplier in database
    expect(find.text('Save Supplier?'), findsNothing);
    final suppliers = await db.catalogDao.getAllSuppliers();
    expect(suppliers, isEmpty);
  });

  testWidgets(
      'SupplierFormSheet saves to database when confirmation is accepted',
      (tester) async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        currentUserPermissionsProvider.overrideWithValue({'suppliers.manage'}),
      ],
    );

    final user = await db.storesDao.getUserById(userId);
    container.read(authProvider).value = user;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: SupplierFormSheet(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Fill in name
    final nameField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == 'e.g. SABMiller Nigeria',
    );
    await tester.enterText(nameField, 'Acme Breweries');
    await tester.pumpAndSettle();

    // Tap Add Supplier button
    final submitButton = find.widgetWithText(AppButton, 'Add Supplier');
    await tester.tap(submitButton);
    await tester.pumpAndSettle();

    // Confirmation dialog appears
    expect(find.text('Save Supplier?'), findsOneWidget);

    // Tap Save in dialog
    final saveConfirmButton = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(AppButton, 'Save'),
    );
    expect(saveConfirmButton, findsOneWidget);
    await tester.tap(saveConfirmButton);
    await tester.pumpAndSettle();

    // Supplier row should now exist in database
    final suppliers = await db.catalogDao.getAllSuppliers();
    expect(suppliers.length, 1);
    expect(suppliers.first.name, 'Acme Breweries');
  });
}
