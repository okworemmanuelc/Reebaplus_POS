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
import 'package:reebaplus_pos/features/receiving/widgets/edit_receive_item_modal.dart';
import 'package:reebaplus_pos/features/receiving/widgets/uncosted_receive_warning.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// #199 / PRD #155 US 37 — receiving stock with no buying price must warn, and
/// the warning must NOT block the receipt. A stock keeper who does not yet know
/// what a delivery cost still has to be able to log the goods.
void main() {
  late AppDatabase db;
  const businessId = 'biz-1';
  const userId = 'user-1';
  const storeId = 'store-1';
  const supplierId = 'sup-1';

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
            name: 'Acme Distributors',
          ),
        );
  });

  tearDown(() => db.close());

  ProductData product({
    required String id,
    required String name,
    required int buyingPriceKobo,
  }) {
    return ProductData(
      id: id,
      businessId: businessId,
      name: name,
      retailerPriceKobo: 15000,
      wholesalerPriceKobo: 14000,
      buyingPriceKobo: buyingPriceKobo,
      unit: 'Pack',
      trackEmpties: false,
      emptyCrateValueKobo: 0,
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
  }

  /// A container wired for the checkout screen, with [cart] seeded.
  Future<ProviderContainer> containerWithCart(List<ProductData> cart) async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        // Receiving into the one store the user can reach; the payment section
        // stays out of the tree (no `suppliers.manage`) so the assertions are
        // about the disclosure, not the ledger.
        currentUserPermissionsProvider.overrideWithValue({
          'products.edit_buying_price',
          'products.edit_price',
          'stock.add',
        }),
        selectableStoresProvider.overrideWithValue([
          (await db.storesDao.getStore(storeId))!,
        ]),
      ],
    );
    final user = await db.storesDao.getUserById(userId);
    container.read(authProvider).value = user;
    for (final p in cart) {
      container.read(receiveCartProvider.notifier).addOrIncrement(p, amount: 3);
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
        // The real app theme: the warning reads the AppSemanticColors
        // extension, which only exists on it.
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const ReceiveCheckoutScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('ReceiveCartNotifier uncosted derivation', () {
    test('counts only the lines with no buying price, and their units', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(receiveCartProvider.notifier);

      notifier.addOrIncrement(
        product(id: 'p-costed', name: 'Costed', buyingPriceKobo: 10000),
        amount: 4,
      );
      notifier.addOrIncrement(
        product(id: 'p-free', name: 'Uncosted', buyingPriceKobo: 0),
        amount: 6,
      );

      expect(notifier.uncostedLineCount, 1);
      expect(notifier.uncostedUnits, 6);
      expect(notifier.totalUnits, 10);
    });

    test('a fully costed cart has nothing to disclose', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(receiveCartProvider.notifier);

      notifier.addOrIncrement(
        product(id: 'p-1', name: 'One', buyingPriceKobo: 10000),
        amount: 2,
      );

      expect(notifier.uncostedLineCount, 0);
      expect(notifier.uncostedUnits, 0);
    });

    test('editing a cost to 0 makes the line uncosted again', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(receiveCartProvider.notifier);

      notifier.addOrIncrement(
        product(id: 'p-1', name: 'One', buyingPriceKobo: 10000),
        amount: 2,
      );
      expect(notifier.uncostedLineCount, 0);

      notifier.setBuyingPrice('p-1', 0);
      expect(notifier.uncostedLineCount, 1);
      expect(notifier.uncostedUnits, 2);
    });
  });

  testWidgets('checkout warns when a line has no buying price', (tester) async {
    final container = await containerWithCart([
      product(id: 'p-costed', name: 'Costed Lager', buyingPriceKobo: 10000),
      product(id: 'p-free', name: 'Mystery Malt', buyingPriceKobo: 0),
    ]);
    await pumpCheckout(tester, container);

    expect(find.byType(UncostedReceiveWarning), findsOneWidget);
    expect(find.textContaining('1 item has no buying price'), findsOneWidget);
    // 3 of the 6 units are the uncosted line's.
    expect(
      find.textContaining('3 units would arrive with no recorded cost'),
      findsOneWidget,
    );

    container.dispose();
    await tester.pump(Duration.zero);
  });

  testWidgets('checkout stays silent when every line is costed', (
    tester,
  ) async {
    final container = await containerWithCart([
      product(id: 'p-costed', name: 'Costed Lager', buyingPriceKobo: 10000),
      product(id: 'p-costed-2', name: 'Costed Stout', buyingPriceKobo: 12000),
    ]);
    await pumpCheckout(tester, container);

    expect(find.byType(UncostedReceiveWarning), findsNothing);
    expect(find.textContaining('no buying price'), findsNothing);

    container.dispose();
    await tester.pump(Duration.zero);
  });

  testWidgets('the warning does not block the commit path', (tester) async {
    final container = await containerWithCart([
      product(id: 'p-free', name: 'Mystery Malt', buyingPriceKobo: 0),
    ]);
    await pumpCheckout(tester, container);

    expect(find.byType(UncostedReceiveWarning), findsOneWidget);

    // Pick the supplier — the only real precondition for confirming.
    await tester.ensureVisible(find.text('Select supplier'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select supplier'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Acme Distributors'));
    await tester.pumpAndSettle();

    // Confirm Receipt is live despite the uncosted line.
    final confirmButton = tester.widget<AppButton>(
      find.widgetWithText(AppButton, 'Confirm Receipt'),
    );
    expect(confirmButton.onPressed, isNotNull);

    // And the commit dialog opens, repeats the disclosure, and still offers an
    // enabled Confirm.
    await tester.tap(find.text('Confirm Receipt'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm Receipt'), findsWidgets);
    expect(
      find.textContaining('excludes 1 item with no recorded buying price'),
      findsOneWidget,
    );
    final dialogConfirm = tester.widget<AppButton>(
      find.widgetWithText(AppButton, 'Confirm'),
    );
    expect(dialogConfirm.onPressed, isNotNull);

    container.dispose();
    await tester.pump(Duration.zero);
  });

  group('EditReceiveItemModal inline warning', () {
    Future<ProviderContainer> modalContainer() async {
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          currentUserPermissionsProvider.overrideWithValue({
            'products.edit_buying_price',
            'products.edit_price',
          }),
        ],
      );
      container.read(authProvider).value =
          await db.storesDao.getUserById(userId);
      return container;
    }

    Future<void> pumpModal(
      WidgetTester tester,
      ProviderContainer container,
      ReceiveCartLine line,
    ) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(body: EditReceiveItemModal(item: line)),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    ReceiveCartLine line(int buyingPriceKobo) => ReceiveCartLine(
          productId: 'p-1',
          productName: 'Mystery Malt',
          unit: 'Pack',
          qty: 3,
          buyingPriceKobo: buyingPriceKobo,
          retailKobo: 15000,
          wholesaleKobo: 14000,
          trackEmpties: false,
        );

    testWidgets('warns on a 0 unit cost without disabling Save Changes', (
      tester,
    ) async {
      final container = await modalContainer();
      await pumpModal(tester, container, line(0));

      expect(find.textContaining('No buying price.'), findsOneWidget);
      final save = tester.widget<AppButton>(
        find.widgetWithText(AppButton, 'Save Changes'),
      );
      expect(save.onPressed, isNotNull);

      container.dispose();
      await tester.pump(Duration.zero);
    });

    testWidgets('stays silent once a unit cost is entered', (tester) async {
      final container = await modalContainer();
      await pumpModal(tester, container, line(10000));

      expect(find.textContaining('No buying price.'), findsNothing);

      container.dispose();
      await tester.pump(Duration.zero);
    });
  });
}
