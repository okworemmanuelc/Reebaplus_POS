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
import 'package:reebaplus_pos/features/inventory/screens/add_product_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

void main() {
  late AppDatabase db;
  const businessId = 'biz-1';
  const userId = 'user-1';
  const storeId = 'store-1';

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
            type: const Value('supermarket'),
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
    await db.into(db.stores).insert(
          StoresCompanion.insert(
            id: const Value(storeId),
            businessId: businessId,
            name: 'Main Store',
            location: const Value('Lagos, Nigeria'),
            kind: const Value('store'),
          ),
        );
    await db.into(db.userStores).insert(
          UserStoresCompanion.insert(
            id: const Value('us-1'),
            businessId: businessId,
            userId: userId,
            storeId: storeId,
          ),
        );
  });

  tearDown(() => db.close());

  testWidgets('AddProductScreen prompts confirmation dialog before saving',
      (tester) async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        currentUserPermissionsProvider.overrideWithValue({
          'products.edit_buying_price',
          'products.edit_price',
          'products.add',
        }),
      ],
    );

    final user = await db.storesDao.getUserById(userId);
    container.read(authProvider).value = user;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: AddProductScreen(receiveMode: false),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Finder fieldFor(String labelPart) => find.descendant(
          of: find.ancestor(
            of: find.textContaining(labelPart),
            matching: find.byType(AppInput),
          ),
          matching: find.byType(TextFormField),
        );

    // Fill in required Fast-Add fields
    await tester.enterText(fieldFor('Product Name'), 'Biscuits 50g');
    await tester.enterText(fieldFor('Selling Price'), '250');
    await tester.enterText(fieldFor('Quantity'), '10');
    await tester.pumpAndSettle();

    // Tap Add Product
    final saveButtonFinder = find.widgetWithText(AppButton, 'Add Product');
    await tester.ensureVisible(saveButtonFinder);
    await tester.tap(saveButtonFinder);
    await tester.pumpAndSettle();

    // Verification: confirmation dialog is shown
    expect(find.text('Save Product?'), findsOneWidget);
    expect(find.text('Are you sure you want to save "Biscuits 50g"?'),
        findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);

    // Tap Cancel -> dialog closes, product is not saved yet
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Save Product?'), findsNothing);

    var products = await (db.select(db.products)
          ..where((tbl) => tbl.businessId.equals(businessId)))
        .get();
    expect(products.isEmpty, isTrue);

    // Tap Add Product again and confirm
    await tester.tap(saveButtonFinder);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // Verification: product was saved to Drift
    products = await (db.select(db.products)
          ..where((tbl) => tbl.businessId.equals(businessId)))
        .get();
    expect(products.length, 1);
    expect(products.first.name, 'Biscuits 50g');

    await tester.pump(const Duration(seconds: 5));

    container.dispose();
    await tester.pump(Duration.zero);
  });
}
