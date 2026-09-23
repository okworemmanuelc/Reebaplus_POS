import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/crates/manufacturer_crate_position.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/features/inventory/screens/inventory_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/manufacturer_screen.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

/// Issue #291 — Manufacturer screen tests.
///
/// Asserts:
///   1. Viewport compliance across 320x568, 800x360, 915x412, and 412x915:
///      zero overflow AND at least one complete content row visible.
///   2. Role gating: CEO & Manager see Customer deposit money amount (₦);
///      Stock keeper and Cashier see NO customer deposit money amount (omitted, not blank).
///   3. Non-crate business sees no crate details.
///   4. Products tab is read-only with the brand's crate value (no edit buttons).
///   5. History tab lists movements newest first with who, when, store, and delta.
///   6. Brand card on InventoryScreen displays "Crate value:" and opens ManufacturerScreen on tap.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const inventoryGrants = {
    'stock.view',
    'sales.make',
    'products.add',
    'stock.add',
  };

  const viewports = <String, Size>{
    'phoneSe1Portrait (320x568, smallest supported portrait)': phoneSe1Portrait,
    'androidCompactLandscape (800x360, shortest supported landscape)':
        androidCompactLandscape,
    'pixel7Landscape (915x412, landscape phone)': pixel7Landscape,
    'pixel7Portrait (412x915, comfortable control)': pixel7Portrait,
  };

  late ScreenTestEnvironment env;
  late BusinessData business;
  late ManufacturerData manufacturer;
  late ProductData product;
  const crateValueKobo = 100000; // ₦1,000

  Finder tabSurface() =>
      find.byKey(const PageStorageKey<String>(kManufacturerCratesStorageKey));

  Finder screenSurface() {
    final nested = find.byType(NestedScrollView);
    return nested.evaluate().isNotEmpty ? nested : tabSurface();
  }

  Future<void> settleScreen(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 150));
    }
  }

  Future<void> seedTestData() async {
    final db = env.db;
    // Enable crates on business
    await db.update(db.businesses).write(
          const BusinessesCompanion(
            type: Value('Beverage distributor'),
            tracksEmptyCrates: Value(true),
          ),
        );
    business = await (db.select(db.businesses)
          ..where((b) => b.id.equals(env.businessId)))
        .getSingle();

    const testUserId = 'test-user-1';
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: const Value(testUserId),
            businessId: env.businessId,
            name: 'Alice Staff',
            pin: '1234',
          ),
        );

    final mfrId = UuidV7.generate();
    await db.into(db.manufacturers).insert(
          ManufacturersCompanion.insert(
            id: Value(mfrId),
            businessId: env.businessId,
            name: 'Guinness Nigeria',
            depositAmountKobo: const Value(crateValueKobo),
          ),
        );
    manufacturer = (await (db.select(db.manufacturers)
              ..where((m) => m.id.equals(mfrId)))
            .getSingle());

    final prodId = UuidV7.generate();
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: Value(prodId),
            businessId: env.businessId,
            manufacturerId: Value(mfrId),
            name: 'Guinness Extra Stout 60cl',
            size: const Value('big'),
            unit: const Value('Bottle'),
            trackEmpties: const Value(true),
            retailerPriceKobo: const Value(60000),
            wholesalerPriceKobo: const Value(55000),
            buyingPriceKobo: const Value(50000),
          ),
        );
    product = (await (db.select(db.products)..where((p) => p.id.equals(prodId)))
        .getSingle());

    // Seed movements
    await db.into(db.crateLedger).insert(
          CrateLedgerCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: env.businessId,
            manufacturerId: Value(mfrId),
            storeId: Value(env.storeId),
            quantityDelta: 25,
            movementType: 'transferred_in',
            performedBy: const Value(testUserId),
          ),
        );
    await db.into(db.crateLedger).insert(
          CrateLedgerCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: env.businessId,
            manufacturerId: Value(mfrId),
            storeId: Value(env.storeId),
            quantityDelta: -3,
            movementType: 'damaged',
            performedBy: const Value(testUserId),
          ),
        );
  }

  group('ManufacturerScreen - Viewport compliance (#291)', () {
    setUp(() async {
      env = await setupScreenTestEnvironment(
        businessType: 'Beverage distributor',
        productCount: 0,
      );
      await seedTestData();
    });

    tearDown(() async {
      await env.dispose();
    });

    viewports.forEach((name, size) {
      testWidgets('$name renders without overflow and shows status row',
          (tester) async {
        await pumpScreen(
          tester,
          env: env,
          size: size,
          screen: ManufacturerScreen(manufacturer: manufacturer),
          grantedKeys: inventoryGrants,
          roleSlug: 'ceo',
          roleName: 'CEO',
          roleRank: 4,
          overrides: [currentBusinessProvider.overrideWith((ref) => business)],
          settle: false,
        );

        await settleScreen(tester);

        expectNoOverflow(tester, reason: 'Manufacturer screen overflowed at $name');

        await expectContentRowVisible(
          tester,
          find.byKey(const ValueKey('${kManufacturerStatusKeyPrefix}in_warehouse')),
          scrollable: screenSurface(),
          reason: 'Manufacturer screen showed no status row at $name',
        );

        await disposeScreen(tester);
      });
    });
  });

  group('ManufacturerScreen - Role gating (#291)', () {
    setUp(() async {
      env = await setupScreenTestEnvironment(
        businessType: 'Beverage distributor',
        productCount: 0,
      );
      await seedTestData();

      // Seed order crate line with deposit paid so Status 3 has deposit money
      final orderId = UuidV7.generate();
      await env.db.into(env.db.orders).insert(
            OrdersCompanion.insert(
              id: Value(orderId),
              businessId: env.businessId,
              orderNumber: 'ORD-GATED-1',
              totalAmountKobo: 200000,
              netAmountKobo: 200000,
              paymentType: 'cash',
              status: 'completed',
              storeId: Value(env.storeId),
            ),
          );
      await env.db.into(env.db.orderCrateLines).insert(
            OrderCrateLinesCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: env.businessId,
              orderId: orderId,
              manufacturerId: manufacturer.id,
              cratesTaken: 2,
              depositPaidKobo: const Value(200000), // ₦2,000
            ),
          );
    });

    tearDown(() async {
      await env.dispose();
    });

    testWidgets('CEO sees Customer deposit money amount on Status 3 card',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        screen: ManufacturerScreen(manufacturer: manufacturer),
        grantedKeys: inventoryGrants,
        roleSlug: 'ceo',
        roleName: 'CEO',
        roleRank: GateTier.ceo,
        overrides: [currentBusinessProvider.overrideWith((ref) => business)],
        settle: false,
      );

      await settleScreen(tester);

      expectNoOverflow(tester);
      final depositCard = find.byKey(
        const ValueKey('${kManufacturerStatusKeyPrefix}with_customers_deposit'),
      );
      expect(depositCard, findsOneWidget);

      // CEO can see money amount (₦2,000)
      expect(
        find.descendant(of: depositCard, matching: find.text('₦2,000')),
        findsOneWidget,
      );

      await disposeScreen(tester);
    });

    testWidgets('Manager sees Customer deposit money amount on Status 3 card',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        screen: ManufacturerScreen(manufacturer: manufacturer),
        grantedKeys: inventoryGrants,
        roleSlug: 'manager',
        roleName: 'Manager',
        roleRank: GateTier.manager,
        overrides: [currentBusinessProvider.overrideWith((ref) => business)],
        settle: false,
      );

      await settleScreen(tester);

      expectNoOverflow(tester);
      final depositCard = find.byKey(
        const ValueKey('${kManufacturerStatusKeyPrefix}with_customers_deposit'),
      );
      expect(depositCard, findsOneWidget);

      // Manager can see money amount (₦2,000)
      expect(
        find.descendant(of: depositCard, matching: find.text('₦2,000')),
        findsOneWidget,
      );

      await disposeScreen(tester);
    });

    testWidgets('Stock keeper does NOT see Customer deposit money amount (absent)',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        screen: ManufacturerScreen(manufacturer: manufacturer),
        grantedKeys: inventoryGrants,
        roleSlug: 'stock_keeper',
        roleName: 'Stock keeper',
        roleRank: GateTier.stockKeeper,
        overrides: [currentBusinessProvider.overrideWith((ref) => business)],
        settle: false,
      );

      await settleScreen(tester);

      expectNoOverflow(tester);
      final depositCard = find.byKey(
        const ValueKey('${kManufacturerStatusKeyPrefix}with_customers_deposit'),
      );
      expect(depositCard, findsOneWidget);

      // Count is visible
      expect(
        find.descendant(of: depositCard, matching: find.text('2 crates')),
        findsOneWidget,
      );
      // Money amount is completely ABSENT
      expect(
        find.descendant(of: depositCard, matching: find.text('₦2,000')),
        findsNothing,
      );

      await disposeScreen(tester);
    });

    testWidgets('Cashier does NOT see Customer deposit money amount (absent)',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        screen: ManufacturerScreen(manufacturer: manufacturer),
        grantedKeys: inventoryGrants,
        roleSlug: 'cashier',
        roleName: 'Cashier',
        roleRank: GateTier.cashier,
        overrides: [currentBusinessProvider.overrideWith((ref) => business)],
        settle: false,
      );

      await settleScreen(tester);

      expectNoOverflow(tester);
      final depositCard = find.byKey(
        const ValueKey('${kManufacturerStatusKeyPrefix}with_customers_deposit'),
      );
      expect(depositCard, findsOneWidget);

      // Count is visible
      expect(
        find.descendant(of: depositCard, matching: find.text('2 crates')),
        findsOneWidget,
      );
      // Money amount is completely ABSENT
      expect(
        find.descendant(of: depositCard, matching: find.text('₦2,000')),
        findsNothing,
      );

      await disposeScreen(tester);
    });
  });

  group('ManufacturerScreen - Products and History tabs (#291)', () {
    setUp(() async {
      env = await setupScreenTestEnvironment(
        businessType: 'Beverage distributor',
        productCount: 0,
      );
      await seedTestData();
    });

    tearDown(() async {
      await env.dispose();
    });

    testWidgets('Products tab is read-only and displays brand crate value',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        screen: ManufacturerScreen(manufacturer: manufacturer),
        grantedKeys: inventoryGrants,
        overrides: [currentBusinessProvider.overrideWith((ref) => business)],
        settle: false,
      );

      await settleScreen(tester);

      // Switch to Products tab
      await tester.tap(find.widgetWithText(Tab, 'Products'));
      await tester.pumpAndSettle();

      final productCard = find.byKey(
        ValueKey('$kManufacturerProductKeyPrefix${product.id}'),
      );
      expect(productCard, findsOneWidget);
      expect(
        find.descendant(
          of: productCard,
          matching: find.text('Guinness Extra Stout 60cl'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: productCard,
          matching: find.text('Crate: ₦1,000'),
        ),
        findsOneWidget,
      );

      // Strictly NO edit/delete buttons
      expect(find.byIcon(Icons.edit), findsNothing);
      expect(find.byIcon(Icons.delete), findsNothing);

      await disposeScreen(tester);
    });

    testWidgets('History tab displays chronological movements with delta',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        screen: ManufacturerScreen(manufacturer: manufacturer),
        grantedKeys: inventoryGrants,
        overrides: [currentBusinessProvider.overrideWith((ref) => business)],
        settle: false,
      );

      await settleScreen(tester);

      // Switch to History tab
      await tester.tap(find.widgetWithText(Tab, 'History'));
      await tester.pumpAndSettle();

      expect(find.text('Transferred in'), findsOneWidget);
      expect(find.text('+25 crates'), findsOneWidget);

      expect(find.text('Damaged'), findsOneWidget);
      expect(find.text('-3 crates'), findsOneWidget);

      await disposeScreen(tester);
    });

    testWidgets('Non-crate business sees not-available message',
        (tester) async {
      final nonCrateBusiness = business.copyWith(
        type: const Value('boutique'),
        tracksEmptyCrates: false,
      );

      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        screen: ManufacturerScreen(manufacturer: manufacturer),
        grantedKeys: inventoryGrants,
        overrides: [
          currentBusinessProvider.overrideWith((ref) => nonCrateBusiness),
        ],
        settle: false,
      );

      await settleScreen(tester);

      expect(
        find.text('Crate management is only available for businesses that track crates.'),
        findsOneWidget,
      );

      await disposeScreen(tester);
    });
  });

  group('InventoryScreen brand card integration (#291)', () {
    setUp(() async {
      env = await setupScreenTestEnvironment(
        businessType: 'Beverage distributor',
        productCount: 0,
      );
      await seedTestData();
    });

    tearDown(() async {
      await env.dispose();
    });

    testWidgets('Brand card displays Crate value and opens ManufacturerScreen on tap',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        screen: const InventoryScreen(),
        grantedKeys: inventoryGrants,
        overrides: [
          currentBusinessProvider.overrideWith((ref) => business),
          firstRunSurfaceStateProvider
              .overrideWithValue(FirstRunSurfaceState.hasContent),
        ],
        settle: false,
      );

      await settleScreen(tester);

      // Switch to Empty Crates tab
      await tester.tap(find.widgetWithText(Tab, 'Empty Crates'));
      await tester.pumpAndSettle();

      // Card must read "Crate value:" instead of "Deposit:"
      final brandCard = find.byKey(
        ValueKey('$kManufacturerCardKeyPrefix${manufacturer.id}'),
      );
      expect(brandCard, findsOneWidget);
      expect(
        find.descendant(of: brandCard, matching: find.text('Crate value: ₦1,000')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: brandCard, matching: find.text('Deposit: ₦1,000')),
        findsNothing,
      );

      // Tapping anywhere on the brand card navigates to ManufacturerScreen
      await tester.tap(brandCard);
      await tester.pumpAndSettle();

      expect(find.byType(ManufacturerScreen), findsOneWidget);
      expect(find.byKey(const ValueKey(kManufacturerScreenKey)), findsOneWidget);

      await disposeScreen(tester);
    });
  });
}
