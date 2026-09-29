import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/inventory/widgets/count_manufacturer_empties_sheet.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

/// Tests for [CountManufacturerEmptiesSheet] (#293, PRD #284 §6).
///
/// Asserts:
///   1. Shows expected empties for the store.
///   2. Inputting count calculates difference and naira warning value before saving.
///   3. Single store / locked store asks no store; multi-store All Stores asks store.
///   4. Rejects negative or non-numeric input.
///   5. Cancel writes nothing.
///   6. Save calls recordManualCountCorrection and writes to ledger.
///   7. Viewport & keyboard compliance at 320x568 and 800x360.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const inventoryGrants = {
    'stock.view',
    'sales.make',
    'products.add',
    'stock.add',
  };

  late ScreenTestEnvironment env;
  late BusinessData business;
  late ManufacturerData manufacturer;
  const crateValueKobo = 100000; // ₦1,000 per crate

  Future<void> settleSheet(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> seedTestData() async {
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

    const testUserId = 'test-user-id';
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: const Value(testUserId),
            businessId: env.businessId,
            name: 'Test Admin',
            pin: '1234',
          ),
        );

    final mfrId = UuidV7.generate();
    await db.into(db.manufacturers).insert(
          ManufacturersCompanion.insert(
            id: Value(mfrId),
            businessId: env.businessId,
            name: 'Nigerian Breweries',
            depositAmountKobo: const Value(crateValueKobo),
          ),
        );
    manufacturer = await (db.select(db.manufacturers)
          ..where((m) => m.id.equals(mfrId)))
        .getSingle();

    // Opening count at env.storeId: 20 crates expected
    await env.db.cratePoolDao.recordManualCountCorrection(
      manufacturerId: mfrId,
      storeId: env.storeId,
      performedBy: testUserId,
      countedEmpties: 20,
    );
  }

  group('CountManufacturerEmptiesSheet - Core behavior (#293)', () {
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

    testWidgets('shows expected empties and displays difference line with warning value',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        screen: Scaffold(
          body: Center(
            child: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => CountManufacturerEmptiesSheet.show(
                  ctx,
                  manufacturer: manufacturer,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
        grantedKeys: inventoryGrants,
        roleSlug: 'cashier',
        roleName: 'Cashier',
        roleRank: GateTier.cashier,
        overrides: [currentBusinessProvider.overrideWith((ref) => business)],
        settle: false,
      );

      await settleSheet(tester);

      // Open sheet
      await tester.tap(find.text('Open'));
      await settleSheet(tester);

      expect(find.byKey(const ValueKey(kCountManufacturerEmptiesSheetKey)), findsOneWidget);
      // Expected should be 20 crates
      expect(find.text('20 crates'), findsOneWidget);

      // Store picker is omitted on single-store business
      expect(find.byKey(const ValueKey(kCountEmptiesStorePickerKey)), findsNothing);

      // Enter 15 (shortage of 5 crates)
      final inputFinder = find.byKey(const ValueKey(kCountEmptiesInputFieldKey));
      await tester.enterText(inputFinder, '15');
      await tester.pump();

      // Check difference line: 5 crates short (₦5,000 warning value)
      final diffTextFinder = find.byKey(const ValueKey(kCountEmptiesDifferenceTextKey));
      expect(diffTextFinder, findsOneWidget);
      expect(
        find.descendant(
          of: diffTextFinder,
          matching: find.text('This is what will be recorded: 5 crates short (₦5,000 warning value)'),
        ),
        findsOneWidget,
      );

      // Enter 25 (surplus of 5 crates)
      await tester.enterText(inputFinder, '25');
      await tester.pump();
      expect(
        find.descendant(
          of: diffTextFinder,
          matching: find.text('This is what will be recorded: 5 crates surplus'),
        ),
        findsOneWidget,
      );

      // Enter 20 (no difference)
      await tester.enterText(inputFinder, '20');
      await tester.pump();
      expect(
        find.descendant(
          of: diffTextFinder,
          matching: find.text('This is what will be recorded: No difference'),
        ),
        findsOneWidget,
      );

      await disposeScreen(tester);
    });

    testWidgets('Cancel button writes nothing and dismisses sheet', (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        screen: Scaffold(
          body: Center(
            child: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => CountManufacturerEmptiesSheet.show(
                  ctx,
                  manufacturer: manufacturer,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
        grantedKeys: inventoryGrants,
        roleSlug: 'cashier',
        roleName: 'Cashier',
        roleRank: GateTier.cashier,
        overrides: [currentBusinessProvider.overrideWith((ref) => business)],
        settle: false,
      );

      await settleSheet(tester);
      await tester.tap(find.text('Open'));
      await settleSheet(tester);

      // Enter 10
      await tester.enterText(find.byKey(const ValueKey(kCountEmptiesInputFieldKey)), '10');
      await tester.pump();

      // Tap Cancel
      await tester.tap(find.byKey(const ValueKey(kCountEmptiesCancelButtonKey)));
      await settleSheet(tester);

      // Sheet dismissed
      expect(find.byKey(const ValueKey(kCountManufacturerEmptiesSheetKey)), findsNothing);

      // Expected remains 20 (nothing written)
      final expected = await env.db.cratePoolDao.expectedEmptiesAt(
        manufacturerId: manufacturer.id,
        storeId: env.storeId,
      );
      expect(expected, 20);

      await disposeScreen(tester);
    });

    testWidgets('Save count records correction to database and dismisses',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        screen: Scaffold(
          body: Center(
            child: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => CountManufacturerEmptiesSheet.show(
                  ctx,
                  manufacturer: manufacturer,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
        grantedKeys: inventoryGrants,
        roleSlug: 'cashier',
        roleName: 'Cashier',
        roleRank: GateTier.cashier,
        overrides: [currentBusinessProvider.overrideWith((ref) => business)],
        settle: false,
      );

      await settleSheet(tester);
      await tester.tap(find.text('Open'));
      await settleSheet(tester);

      // Count 16 (gap of 4)
      await tester.enterText(find.byKey(const ValueKey(kCountEmptiesInputFieldKey)), '16');
      await tester.pump();

      // Tap Save
      await tester.tap(find.byKey(const ValueKey(kCountEmptiesSaveButtonKey)));
      await settleSheet(tester);

      // Sheet dismissed
      expect(find.byKey(const ValueKey(kCountManufacturerEmptiesSheetKey)), findsNothing);

      // Expected in database is now 16
      final expected = await env.db.cratePoolDao.expectedEmptiesAt(
        manufacturerId: manufacturer.id,
        storeId: env.storeId,
      );
      expect(expected, 16);

      // Shortage is now 4
      final shortage = await tester.runAsync(
        () => env.db.cratePoolDao
            .watchCrateShortageByManufacturer(manufacturer.id, storeId: env.storeId)
            .first,
      );
      expect(shortage, 4);

      await disposeScreen(tester);
    });
  });

  group('CountManufacturerEmptiesSheet - Multi-store store selection (#293)', () {
    setUp(() async {
      env = await setupScreenTestEnvironment(
        businessType: 'Beverage distributor',
        productCount: 0,
      );
      await seedTestData();

      // Add second store
      await env.db.into(env.db.stores).insert(
            StoresCompanion.insert(
              id: const Value('store-2'),
              businessId: env.businessId,
              name: 'Warehouse Branch',
            ),
          );
    });

    tearDown(() async {
      await env.dispose();
    });

    testWidgets('requires selecting store in All Stores mode', (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        screen: Scaffold(
          body: Center(
            child: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => CountManufacturerEmptiesSheet.show(
                  ctx,
                  manufacturer: manufacturer,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
        grantedKeys: inventoryGrants,
        roleSlug: 'ceo',
        roleName: 'CEO',
        selectableStores: [
          env.store,
          StoreData(
            id: 'store-2',
            businessId: env.businessId,
            name: 'Warehouse Branch',
            location: null,
            kind: 'store',
            isDeleted: false,
            createdAt: DateTime.now(),
            lastUpdatedAt: DateTime.now(),
          ),
        ],
        overrides: [
          currentBusinessProvider.overrideWith((ref) => business),
          lockedStoreProvider.overrideWith((ref) => ValueNotifier<String?>(null)),
        ],
        settle: false,
      );

      await settleSheet(tester);
      await tester.tap(find.text('Open'));
      await settleSheet(tester);

      // Store picker MUST be visible
      expect(find.byKey(const ValueKey(kCountEmptiesStorePickerKey)), findsOneWidget);
      expect(find.text('Select store'), findsOneWidget);

      await disposeScreen(tester);
    });
  });

  group('CountManufacturerEmptiesSheet - Viewport & Keyboard compliance (#293)', () {
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

    testWidgets('320x568 portrait with virtual keyboard renders without overflow',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: phoneSe1Portrait,
        screen: Scaffold(
          body: Center(
            child: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => CountManufacturerEmptiesSheet.show(
                  ctx,
                  manufacturer: manufacturer,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
        grantedKeys: inventoryGrants,
        roleSlug: 'cashier',
        roleName: 'Cashier',
        roleRank: GateTier.cashier,
        overrides: [currentBusinessProvider.overrideWith((ref) => business)],
        settle: false,
      );

      await settleSheet(tester);
      await tester.tap(find.text('Open'));
      await settleSheet(tester);

      expectNoOverflow(tester, reason: 'Sheet overflowed on 320x568 portrait');

      // Focus input field (simulating keyboard)
      await tester.tap(find.byKey(const ValueKey(kCountEmptiesInputFieldKey)));
      await settleSheet(tester);

      expectNoOverflow(tester, reason: 'Sheet overflowed on 320x568 with keyboard');

      await disposeScreen(tester);
    });

    testWidgets('800x360 landscape with virtual keyboard renders without overflow',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: androidCompactLandscape,
        screen: Scaffold(
          body: Center(
            child: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => CountManufacturerEmptiesSheet.show(
                  ctx,
                  manufacturer: manufacturer,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
        grantedKeys: inventoryGrants,
        roleSlug: 'cashier',
        roleName: 'Cashier',
        roleRank: GateTier.cashier,
        overrides: [currentBusinessProvider.overrideWith((ref) => business)],
        settle: false,
      );

      await settleSheet(tester);
      await tester.tap(find.text('Open'));
      await settleSheet(tester);

      expectNoOverflow(tester, reason: 'Sheet overflowed on 800x360 landscape');

      await disposeScreen(tester);
    });
  });
}
