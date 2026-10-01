// add_product_barcode_keep_test.dart
//
// #320 — picking an existing product by name in Add Product must not wipe a
// barcode already in the field (scanned or typed): the kept code is what gets
// saved onto the product. An EMPTY field still takes the product's own
// barcode, as before.

import 'package:drift/drift.dart' show Value;
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
  const productId = 'prod-coke';

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
    await db
        .into(db.businesses)
        .insert(
          BusinessesCompanion.insert(
            id: const Value(businessId),
            name: 'Test Biz',
            type: const Value('supermarket'),
          ),
        );
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: const Value(userId),
            businessId: businessId,
            name: 'Test User',
            pin: '0000',
            avatarColor: const Value('#3B82F6'),
            biometricEnabled: const Value(false),
          ),
        );
    await db
        .into(db.stores)
        .insert(
          StoresCompanion.insert(
            id: const Value(storeId),
            businessId: businessId,
            name: 'Main Store',
          ),
        );
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: const Value(productId),
            businessId: businessId,
            name: 'Coke 50cl',
            barcode: const Value('OLD-1'),
            retailerPriceKobo: const Value(30000),
            wholesalerPriceKobo: const Value(28000),
          ),
        );
  });

  tearDown(() => db.close());

  Future<ProviderContainer> pumpScreen(
    WidgetTester tester, {
    String? prefilledBarcode,
  }) async {
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
    addTearDown(container.dispose);
    container.read(authProvider).value = await db.storesDao.getUserById(
      userId,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: AddProductScreen(prefilledBarcode: prefilledBarcode),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Finder fieldFor(String labelPart) => find.descendant(
    of: find.byWidgetPredicate(
      (w) => w is AppInput && (w.labelText?.contains(labelPart) ?? false),
    ),
    matching: find.byType(TextFormField),
  );

  Future<void> pickExisting(WidgetTester tester) async {
    await tester.enterText(fieldFor('Product Name'), 'Cok');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Coke 50cl'));
    await tester.pumpAndSettle();
  }

  /// The Barcode field's text. A new product shows the Fast-Add layout, with
  /// the field under the collapsed "More details"; an existing pick switches
  /// to the classic layout, where it is always shown.
  Future<String> barcodeText(WidgetTester tester) async {
    final header = find.text('More details');
    if (header.evaluate().isNotEmpty && fieldFor('Barcode').evaluate().isEmpty) {
      await tester.ensureVisible(header);
      await tester.tap(header);
      await tester.pumpAndSettle();
    }
    final field = fieldFor('Barcode');
    await tester.ensureVisible(field);
    return tester.widget<TextFormField>(field).controller!.text;
  }

  Future<void> dispose(WidgetTester tester, ProviderContainer c) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets('a scanned barcode survives picking an existing product and is '
      'saved onto it', (tester) async {
    final container = await pumpScreen(tester, prefilledBarcode: 'SCAN-1');

    await pickExisting(tester);
    expect(await barcodeText(tester), 'SCAN-1');

    // Save as "Add Stock" on the existing product.
    await tester.enterText(fieldFor('QUANTITY TO ADD'), '4');
    await tester.pumpAndSettle();
    final save = find.widgetWithText(AppButton, 'Add Stock');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = await db.catalogDao.findProductByBarcode('SCAN-1');
    expect(saved?.id, productId);

    await dispose(tester, container);
  });

  testWidgets('a typed barcode survives picking an existing product', (
    tester,
  ) async {
    final container = await pumpScreen(tester);

    // Type the code first (More details open), then pick by name.
    await barcodeText(tester);
    await tester.enterText(fieldFor('Barcode'), 'TYPED-7');
    await tester.pumpAndSettle();
    await tester.ensureVisible(fieldFor('Product Name'));
    await pickExisting(tester);

    final field = fieldFor('Barcode');
    await tester.ensureVisible(field);
    expect(tester.widget<TextFormField>(field).controller!.text, 'TYPED-7');

    await dispose(tester, container);
  });

  testWidgets('an empty barcode field still takes the product\'s barcode', (
    tester,
  ) async {
    final container = await pumpScreen(tester);

    await pickExisting(tester);
    expect(await barcodeText(tester), 'OLD-1');

    await dispose(tester, container);
  });
}
