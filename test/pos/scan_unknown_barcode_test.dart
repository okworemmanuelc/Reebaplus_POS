// scan_unknown_barcode_test.dart
//
// #320 — an unknown barcode scanned by someone who may add products opens the
// REAL Add Product screen over the scanner (no test seam), pre-filled with the
// code, once "Add as new product" is picked on the choice (#321). Saving it with stock in the active store goes straight on to the
// quantity sheet for the new product; backing out returns to scanning with
// nothing added. The seam-driven cases (Cashier message, 0 stock, "this
// store") live in barcode_scan_test.dart.

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
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/inventory/screens/add_product_screen.dart';
import 'package:reebaplus_pos/features/pos/providers/pos_providers.dart';
import 'package:reebaplus_pos/features/pos/widgets/barcode_scan_page.dart';
import 'package:reebaplus_pos/features/pos/widgets/edit_item_modal.dart';
import 'package:reebaplus_pos/features/pos/widgets/pos_barcode_scan_button.dart';
import 'package:reebaplus_pos/features/pos/widgets/scan_unknown_choice_sheet.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

import '../helpers/fake_barcode_scanner.dart';

void main() {
  late AppDatabase db;
  late FakeBarcodeScanner scanner;
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
            name: 'Manager',
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
    AppNotification.hide();
  });

  tearDown(() => db.close());

  /// A Manager (holds products.add) at the till, store "Main Store" active
  /// unless [activeStoreId] / [activeStoreName] name another.
  Future<ProviderContainer> pumpTill(
    WidgetTester tester, {
    String activeStoreId = storeId,
    String activeStoreName = 'Main Store',
  }) async {
    scanner = FakeBarcodeScanner('NEW-555');
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        barcodeScannerProvider.overrideWithValue(scanner),
        currentUserPermissionsProvider.overrideWithValue({
          'products.add',
          'products.edit_price',
          'products.edit_buying_price',
        }),
      ],
    );
    addTearDown(container.dispose);
    container.read(authProvider).value = await db.storesDao.getUserById(
      userId,
    );
    db.businessIdResolver = () => businessId;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            floatingActionButton: PosBarcodeScanButton(
              tier: PriceTier.retailer,
              // The grid's stream doesn't know the new product yet.
              loadedProducts: const [],
              storeName: activeStoreName,
              storeId: activeStoreId,
            ),
          ),
        ),
      ),
    );
    return container;
  }

  /// Scans the unknown code and picks "Add as new product" (#321).
  Future<void> scan(WidgetTester tester) async {
    await tester.tap(find.byType(PosBarcodeScanButton));
    await tester.pumpAndSettle();
    scanner.camera!.read(scanner.code!);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kScanUnknownAddNewKey));
    await tester.pumpAndSettle();
  }

  Finder fieldFor(String labelPart) => find.descendant(
    of: find.byWidgetPredicate(
      (w) => w is AppInput && (w.labelText?.contains(labelPart) ?? false),
    ),
    matching: find.byType(TextFormField),
  );

  Future<void> tapButton(WidgetTester tester, String label) async {
    final button = find.widgetWithText(AppButton, label);
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  Future<void> dispose(WidgetTester tester, ProviderContainer c) async {
    AppNotification.hide();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets('save with stock here → the quantity sheet opens for the new '
      'product; confirming adds it', (tester) async {
    final container = await pumpTill(tester);

    await scan(tester);

    expect(find.byType(AddProductScreen), findsOneWidget);
    expect(
      tester.widget<AddProductScreen>(find.byType(AddProductScreen))
          .prefilledBarcode,
      'NEW-555',
    );
    // The camera keeps running behind Add Product (it is never paused).
    expect(scanner.camera!.isRunning, isTrue);

    await tester.enterText(fieldFor('Product Name'), 'Malta Guinness');
    await tester.enterText(fieldFor('Selling Price'), '500');
    await tester.enterText(fieldFor('Quantity'), '12');
    await tester.pumpAndSettle();
    await tapButton(tester, 'Add Product');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // Back over the scanner with the quantity sheet for the new product.
    expect(find.byType(AddProductScreen), findsNothing);
    expect(find.byType(BarcodeScanPage), findsOneWidget);
    expect(find.byType(EditItemModal), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(EditItemModal),
        matching: find.text('Malta Guinness'),
      ),
      findsOneWidget,
    );

    await tapButton(tester, 'Add to Cart');

    final cart = container.read(cartProvider).value;
    expect(cart.single['name'], 'Malta Guinness');
    expect(cart.single['qty'], 1);
    // The scanned code was saved on the new product.
    final saved = await db.catalogDao.findProductByBarcode('NEW-555');
    expect(saved?.id, cart.single['id']);
    expect(find.byType(BarcodeScanPage), findsOneWidget);
    expect(scanner.camera!.isRunning, isTrue);

    await dispose(tester, container);
  });

  testWidgets('two stores, selling from the second → the opening stock lands '
      'in the POS store and the quantity sheet opens', (tester) async {
    // "Main Store" sorts first, so Add Product would default to it; the POS
    // is selling from "Store B".
    await db
        .into(db.stores)
        .insert(
          StoresCompanion.insert(
            id: const Value('store-B'),
            businessId: businessId,
            name: 'Store B',
          ),
        );
    final container = await pumpTill(
      tester,
      activeStoreId: 'store-B',
      activeStoreName: 'Store B',
    );

    await scan(tester);
    expect(find.byType(AddProductScreen), findsOneWidget);
    expect(
      tester.widget<AddProductScreen>(find.byType(AddProductScreen))
          .initialStoreId,
      'store-B',
    );

    await tester.enterText(fieldFor('Product Name'), 'Malta Guinness');
    await tester.enterText(fieldFor('Selling Price'), '500');
    await tester.enterText(fieldFor('Quantity'), '12');
    await tester.pumpAndSettle();
    await tapButton(tester, 'Add Product');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = await db.catalogDao.findProductByBarcode('NEW-555');
    expect(saved, isNotNull);
    expect(await db.stockLedgerDao.getCurrentStock(saved!.id, 'store-B'), 12);
    expect(await db.stockLedgerDao.getCurrentStock(saved.id, storeId), 0);

    // Not "no stock at Store B yet" — straight on to the quantity sheet.
    expect(find.byType(EditItemModal), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(EditItemModal),
        matching: find.text('Malta Guinness'),
      ),
      findsOneWidget,
    );

    await dispose(tester, container);
  });

  testWidgets('backing out of Add Product returns to scanning, nothing added', (
    tester,
  ) async {
    final container = await pumpTill(tester);

    await scan(tester);
    expect(find.byType(AddProductScreen), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(AddProductScreen), findsNothing);
    expect(find.byType(EditItemModal), findsNothing);
    expect(find.byType(BarcodeScanPage), findsOneWidget);
    expect(scanner.camera!.isRunning, isTrue);
    expect(container.read(cartProvider).value, isEmpty);
    expect(await db.catalogDao.findProductByBarcode('NEW-555'), isNull);

    await dispose(tester, container);
  });
}
