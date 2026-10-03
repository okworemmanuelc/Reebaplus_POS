import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/receiving/screens/receive_checkout_screen.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// Supplier is optional on the Receive Stock invoice unless a line moves
/// crates. No supplier = a cash purchase: stock goes up, nothing is owed, no
/// payment is recorded, and no crates move (crate debt needs an owner — #210).
void main() {
  late AppDatabase db;
  const businessId = 'biz-1';
  const userId = 'user-1';
  const storeId = 'store-1';
  const supplierId = 'sup-1';
  const manufacturerId = 'mfr-1';
  const waterId = 'p-water';
  const lagerId = 'p-lager';

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

    await db.into(db.businesses).insert(BusinessesCompanion.insert(
          id: const Value(businessId),
          name: 'Test Biz',
          type: const Value('bar'),
        ));
    await db.into(db.users).insert(UsersCompanion.insert(
          id: const Value(userId),
          businessId: businessId,
          name: 'Test User',
          pin: '0000',
        ));
    await db.into(db.stores).insert(StoresCompanion.insert(
          id: const Value(storeId),
          businessId: businessId,
          name: 'Main Store',
        ));
    await db.into(db.suppliers).insert(SuppliersCompanion.insert(
          id: const Value(supplierId),
          businessId: businessId,
          name: 'Acme Distributors',
        ));
    await db.into(db.manufacturers).insert(ManufacturersCompanion.insert(
          id: const Value(manufacturerId),
          businessId: businessId,
          name: 'Star Lager',
        ));
    await db.into(db.products).insert(ProductsCompanion.insert(
          id: const Value(waterId),
          businessId: businessId,
          name: 'Bottled Water',
          unit: const Value('Pack'),
          buyingPriceKobo: const Value(20000),
        ));
    await db.into(db.products).insert(ProductsCompanion.insert(
          id: const Value(lagerId),
          businessId: businessId,
          name: 'Star 60cl',
          unit: const Value('Bottle'),
          buyingPriceKobo: const Value(10000),
          manufacturerId: const Value(manufacturerId),
          trackEmpties: const Value(true),
        ));
  });

  tearDown(() => db.close());

  Future<ProviderContainer> containerWithCart(
    List<String> productIds, {
    Set<String> extraPermissions = const {},
  }) async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        currentUserPermissionsProvider.overrideWithValue({
          'products.edit_buying_price',
          'products.edit_price',
          'stock.add',
          ...extraPermissions,
        }),
        selectableStoresProvider.overrideWithValue([
          (await db.storesDao.getStore(storeId))!,
        ]),
      ],
    );
    container.read(authProvider).value = await db.storesDao.getUserById(userId);
    // A plain query: a Drift stream's `.first` hangs in the fake-async zone.
    final products = await db.select(db.products).get();
    for (final id in productIds) {
      container
          .read(receiveCartProvider.notifier)
          .addOrIncrement(products.firstWhere((p) => p.id == id), amount: 3);
    }
    return container;
  }

  Future<void> pumpCheckout(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const ReceiveCheckoutScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  AppButton confirmButton(WidgetTester tester) => tester.widget<AppButton>(
        find.widgetWithText(AppButton, 'Confirm Receipt'),
      );

  Future<void> pickSupplier(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Select supplier'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select supplier'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Acme Distributors'));
    await tester.pumpAndSettle();
  }

  testWidgets('no crate lines: supplier is optional and the receipt commits '
      'as a cash purchase', (tester) async {
    final container = await containerWithCart([waterId]);
    await pumpCheckout(tester, container);

    expect(find.text('SUPPLIER (optional)'), findsOneWidget);
    expect(confirmButton(tester).onPressed, isNotNull);

    await tester.tap(find.text('Confirm Receipt'));
    await tester.pumpAndSettle();
    expect(find.text('None (cash purchase)'), findsOneWidget);
    expect(
      find.textContaining('nothing is recorded as owed or paid'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(AppButton, 'Confirm'));
    await tester.pumpAndSettle();

    final inv = await db
        .customSelect(
          'SELECT quantity FROM inventory WHERE product_id = ?',
          variables: [const Variable(waterId)],
        )
        .getSingle();
    expect(inv.read<int>('quantity'), 3);
    final ledger = await db
        .customSelect('SELECT COUNT(*) AS c FROM supplier_ledger_entries')
        .getSingle();
    expect(ledger.read<int>('c'), 0);
    expect(find.text('Stock received'), findsOneWidget);

    // Let the success toast's 4s dismiss timer run out.
    await tester.pump(const Duration(seconds: 5));
    container.dispose();
    await tester.pump(Duration.zero);
  });

  testWidgets('a crate line keeps the supplier required', (tester) async {
    final container = await containerWithCart([waterId, lagerId]);
    await pumpCheckout(tester, container);

    expect(find.text('SUPPLIER *'), findsOneWidget);
    expect(confirmButton(tester).onPressed, isNull);

    await pickSupplier(tester);
    expect(confirmButton(tester).onPressed, isNotNull);

    container.dispose();
    await tester.pump(Duration.zero);
  });

  testWidgets('payment shows only once a supplier is picked, and clearing the '
      'supplier hides it again', (tester) async {
    final container = await containerWithCart(
      [waterId],
      extraPermissions: {'suppliers.manage'},
    );
    await pumpCheckout(tester, container);

    expect(find.text('Amount Paid Now'), findsNothing);

    await pickSupplier(tester);
    expect(find.text('Amount Paid Now'), findsOneWidget);

    // Clear (×) the supplier — back to a cash purchase, payment gone.
    await tester.tap(find.byWidgetPredicate(
      (w) => w is InkWell && w.customBorder is CircleBorder,
    ));
    await tester.pumpAndSettle();
    expect(find.text('Select supplier'), findsOneWidget);
    expect(find.text('Amount Paid Now'), findsNothing);
    expect(confirmButton(tester).onPressed, isNotNull);

    container.dispose();
    await tester.pump(Duration.zero);
  });
}
