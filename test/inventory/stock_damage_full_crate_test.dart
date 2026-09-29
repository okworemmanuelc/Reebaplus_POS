import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/inventory/screens/stock_count_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

/// Issue #299 — Damaging a full crate of drinks damages its crate too, with
/// the crate loss counted once.
///
/// Verifies:
/// 1. The product damage sheet no longer offers a crate fate dropdown for tracked bottles.
/// 2. Damaging a tracked bottle product lowers drink stock and writes one
///    `full_crate_damage` crate leg with a snapshotted deposit rate.
/// 3. The Empties Pool (warehouse count) is unchanged by that leg.
/// 4. Damaging a non-tracked product does not write a `full_crate_damage` leg.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late BusinessData business;
  late String manufacturerId;
  late String bottleProductId;
  late String canProductId;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      businessType: 'Beverage distributor',
      productCount: 0,
    );
    final db = env.db;

    await db.update(db.businesses).write(
          const BusinessesCompanion(
            type: Value('Beverage distributor'),
            tracksEmptyCrates: Value(true),
          ),
        );
    business = await (db.select(db.businesses)
          ..where((b) => b.id.equals(env.businessId)))
        .getSingle();

    // Attribute to test-user-id
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: const Value('test-user-id'),
            businessId: env.businessId,
            name: 'Test Staff',
            pin: '1234',
          ),
        );

    // Create a manufacturer with ₦2,000 (200000 kobo) crate value
    manufacturerId = UuidV7.generate();
    await db.into(db.manufacturers).insert(
          ManufacturersCompanion.insert(
            id: Value(manufacturerId),
            businessId: env.businessId,
            name: 'Nigerian Breweries',
            depositAmountKobo: const Value(200000),
          ),
        );

    // Seed 10 empties in the warehouse pool for this manufacturer
    await db.into(db.crateLedger).insert(
          CrateLedgerCompanion.insert(
            businessId: env.businessId,
            manufacturerId: Value(manufacturerId),
            storeId: Value(env.storeId),
            quantityDelta: 10,
            movementType: 'count',
          ),
        );

    // Create a tracked bottle product
    bottleProductId = UuidV7.generate();
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: Value(bottleProductId),
            businessId: env.businessId,
            name: 'Star Lager Bottle',
            buyingPriceKobo: const Value(50000),
            retailerPriceKobo: const Value(70000),
            wholesalerPriceKobo: const Value(65000),
            manufacturerId: Value(manufacturerId),
            unit: const Value('Bottle'),
            trackEmpties: const Value(true),
          ),
        );
    await db.into(db.inventory).insert(
          InventoryCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: env.businessId,
            storeId: env.storeId,
            productId: bottleProductId,
            quantity: const Value(20),
          ),
        );

    // Create a non-tracked can product
    canProductId = UuidV7.generate();
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: Value(canProductId),
            businessId: env.businessId,
            name: 'Heineken Can',
            buyingPriceKobo: const Value(60000),
            retailerPriceKobo: const Value(80000),
            wholesalerPriceKobo: const Value(75000),
            unit: const Value('Can'),
            trackEmpties: const Value(false),
          ),
        );
    await db.into(db.inventory).insert(
          InventoryCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: env.businessId,
            storeId: env.storeId,
            productId: canProductId,
            quantity: const Value(15),
          ),
        );
  });

  tearDown(() async {
    await env.dispose();
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await disposeScreen(tester);
  }

  testWidgets(
      'product damage sheet no longer offers crate fate dropdown, and damaging '
      'tracked bottles records drink adjustment and snapshotted full_crate_damage leg',
      (tester) async {
    await pumpScreen(
      tester,
      env: env,
      size: pixel7Portrait,
      screen: StockCountScreen(storeId: env.storeId),
      roleRank: GateTier.ceo,
      roleSlug: 'ceo',
      grantedKeys: const {'stock.adjust', 'stock.view'},
      overrides: [
        currentBusinessProvider.overrideWith((ref) => business),
      ],
      settle: false,
    );
    await settle(tester);

    // Open Record Damages sheet via the header IconButton
    final damageBtn =
        find.byKey(const Key('stock_count_record_damages_button'));
    expect(damageBtn, findsOneWidget);
    await tester.tap(damageBtn);
    await settle(tester);

    expect(find.text('Record Damages'), findsOneWidget);

    // Verify crate fate dropdown is NOT present
    expect(find.text('Empty crate'), findsNothing);
    expect(find.text('Keep crate'), findsNothing);
    expect(find.text('Full crate lost'), findsNothing);

    final productDropdownFinder = find.byType(AppDropdown<ProductStockWithStore>);
    final dropdownWidget = tester.widget<AppDropdown<ProductStockWithStore>>(productDropdownFinder);
    final bottleItem = dropdownWidget.items.firstWhere((i) => i.value?.product.id == bottleProductId);
    dropdownWidget.onChanged(bottleItem.value);
    await settle(tester);

    // Enter quantity 3
    final qtyField = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(TextField),
    );
    await tester.enterText(qtyField, '3');
    await settle(tester);

    // Warehouse pool before
    final poolBefore = await env.db.cratePoolDao
        .expectedEmptiesAt(manufacturerId: manufacturerId, storeId: env.storeId);
    expect(poolBefore, 10);

    // Submit the damage
    final submitBtn = find.widgetWithText(FilledButton, 'Record Damage');
    expect(submitBtn, findsOneWidget);
    await tester.tap(submitBtn);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.text('Record Damages').evaluate().isEmpty) break;
    }

    // Verify stock adjustment was written
    final adjustments = await env.db.select(env.db.stockAdjustments).get();
    expect(adjustments.length, 1);
    final adj = adjustments.single;
    expect(adj.productId, bottleProductId);
    expect(adj.quantityDiff, -3);
    expect(adj.reason, 'damage:broken');

    // Verify full_crate_damage crate leg was written with snapshotted rate
    final crateLegs = await (env.db.select(env.db.crateLedger)
          ..where((t) => t.movementType.equals('full_crate_damage')))
        .get();
    expect(crateLegs.length, 1);
    final leg = crateLegs.single;
    expect(leg.quantityDelta, -3);
    expect(leg.storeId, env.storeId);
    expect(leg.manufacturerId, manufacturerId);
    expect(leg.ratePerCrateKobo, 200000); // ₦2,000 snapshotted

    // Verify Empties Pool (warehouse count) is UNCHANGED (10)
    final poolAfter = await env.db.cratePoolDao
        .expectedEmptiesAt(manufacturerId: manufacturerId, storeId: env.storeId);
    expect(poolAfter, 10,
        reason: 'Warehouse pool must not be changed by full_crate_damage leg');

    await finish(tester);
  });

  testWidgets(
      'damaging a non-tracked product records drink adjustment and NO full_crate_damage leg',
      (tester) async {
    await pumpScreen(
      tester,
      env: env,
      size: pixel7Portrait,
      screen: StockCountScreen(storeId: env.storeId),
      roleRank: GateTier.ceo,
      roleSlug: 'ceo',
      grantedKeys: const {'stock.adjust', 'stock.view'},
      overrides: [
        currentBusinessProvider.overrideWith((ref) => business),
      ],
      settle: false,
    );
    await settle(tester);

    // Open Record Damages sheet via the header IconButton
    final damageBtn =
        find.byKey(const Key('stock_count_record_damages_button'));
    await tester.tap(damageBtn);
    await settle(tester);

    // Select the can product
    final productDropdownFinder = find.byType(AppDropdown<ProductStockWithStore>);
    final dropdownWidget = tester.widget<AppDropdown<ProductStockWithStore>>(productDropdownFinder);
    final canItem = dropdownWidget.items.firstWhere((i) => i.value?.product.id == canProductId);
    dropdownWidget.onChanged(canItem.value);
    await settle(tester);

    // Enter quantity 2
    final qtyField = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(TextField),
    );
    await tester.enterText(qtyField, '2');
    await settle(tester);

    // Submit the damage
    final submitBtn = find.widgetWithText(FilledButton, 'Record Damage');
    await tester.tap(submitBtn);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.text('Record Damages').evaluate().isEmpty) break;
    }

    // Verify stock adjustment was written
    final adjustments = await env.db.select(env.db.stockAdjustments).get();
    expect(adjustments.length, 1);
    expect(adjustments.single.productId, canProductId);
    expect(adjustments.single.quantityDiff, -2);

    // Verify NO full_crate_damage crate leg was written
    final crateLegs = await (env.db.select(env.db.crateLedger)
          ..where((t) => t.movementType.equals('full_crate_damage')))
        .get();
    expect(crateLegs, isEmpty);

    await finish(tester);
  });
}
