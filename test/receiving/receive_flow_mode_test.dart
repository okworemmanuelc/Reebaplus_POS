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
import 'package:reebaplus_pos/features/receiving/widgets/receive_product_grid.dart';

void main() {
  late AppDatabase db;
  const businessId = 'biz-1';
  const userId = 'user-1';
  const storeId = 'store-1';
  const supplierId = 'sup-1';
  const manufacturerId = 'mfr-1';
  const categoryId = 'cat-1';

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
    await db.customSelect('SELECT 1').get(); // Force onCreate.

    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(
            id: const Value(businessId),
            name: 'Test Biz',
            type: const Value('bar'),
          ),
        );
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: const Value(userId),
            businessId: businessId,
            name: 'Test User',
            pin: '0000',
          ),
        );
    await db.into(db.stores).insert(
          StoresCompanion.insert(
            id: const Value(storeId),
            businessId: businessId,
            name: 'Main Store',
          ),
        );
    await db.into(db.suppliers).insert(
          SuppliersCompanion.insert(
            id: const Value(supplierId),
            businessId: businessId,
            name: 'Supplier A',
          ),
        );
    await db.into(db.manufacturers).insert(
          ManufacturersCompanion.insert(
            id: const Value(manufacturerId),
            businessId: businessId,
            name: 'Manufacturer A',
          ),
        );
    await db.into(db.categories).insert(
          CategoriesCompanion.insert(
            id: const Value(categoryId),
            businessId: businessId,
            name: 'Category A',
          ),
        );
  });

  tearDown(() => db.close());

  testWidgets('AddProductScreen receiveMode = false: single-store hides '
      'Store, Supplier sits in the open More details card (#487)', (
    tester,
  ) async {
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

    // The three required fields are all on screen (ADR 0006).
    expect(find.text('Product Name'), findsOneWidget);
    expect(find.text('Retail Price'), findsOneWidget);
    expect(find.text('Opening Quantity'), findsOneWidget);

    // A single-store business is never asked which store to stock into.
    expect(find.byKey(AddProductKeys.store), findsNothing);

    // More details is an open card (no fold): Supplier is already there.
    expect(find.text('More details'), findsOneWidget);
    expect(find.byKey(AddProductKeys.supplier), findsOneWidget);

    container.dispose();
    await tester.pump(Duration.zero);
  });

  testWidgets('AddProductScreen receiveMode = true hides Store and Supplier fields', (tester) async {
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
            body: AddProductScreen(receiveMode: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The same form; the Store box is hidden (the quantity goes onto the
    // delivery list) and the delivery carries its own supplier.
    expect(find.text('Opening Quantity'), findsOneWidget);
    expect(find.byKey(AddProductKeys.store), findsNothing);
    expect(find.byKey(AddProductKeys.supplier), findsNothing);

    container.dispose();
    await tester.pump(Duration.zero);
  });

  ProductData gridProduct() => ProductData(
        id: 'prod-1',
        businessId: businessId,
        name: 'Star 60cl',
        retailerPriceKobo: 12000,
        wholesalerPriceKobo: 11000,
        buyingPriceKobo: 10000,
        unit: 'Bottle',
        trackEmpties: true,
        emptyCrateValueKobo: 200,
        allowFractionalSales: false,
        lowStockThreshold: 5,
        avgDailySales: 0.0,
        leadTimeDays: 0,
        safetyStockQty: 0,
        monthlyTargetUnits: 0,
        isAvailable: true,
        isDeleted: false,
        version: 1,
        createdAt: DateTime.now(),
        lastUpdatedAt: DateTime.now(),
      );

  Future<void> pumpGrid(WidgetTester tester, Set<String> permissions) async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        currentUserPermissionsProvider.overrideWithValue(permissions),
      ],
    );
    final user = await db.storesDao.getUserById(userId);
    container.read(authProvider).value = user;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            // The grid is a sliver since #394 (one scroll view, PRD #239).
            body: CustomScrollView(
              slivers: [
                ReceiveProductGrid(
                  products: [
                    ProductDataWithStock(
                      product: gridProduct(),
                      totalStock: 10,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() {
      container.dispose();
    });
  }

  testWidgets('ReceiveProductGrid shows the New Product card with products.add', (tester) async {
    await pumpGrid(tester, {'products.add', 'stock.add'});

    expect(find.text('New Product'), findsOneWidget);
    expect(find.text('Star 60cl'), findsWidgets);
  });

  testWidgets('ReceiveProductGrid hides the New Product card without products.add (stock keeper)', (tester) async {
    await pumpGrid(tester, {'stock.add'});

    expect(find.text('New Product'), findsNothing);
    // Existing products are still receivable (tap-to-add).
    expect(find.text('Star 60cl'), findsWidgets);
  });
}
