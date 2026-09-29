import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/crates/crate_ledger_movement_types.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/inventory/screens/manufacturer_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/buy_crates_sheet.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

/// Issue #294: Buy crates on the manufacturer screen. CEO and Manager see it;
/// a Stock keeper and a Cashier don't. The sheet states what will be recorded,
/// asks for a store only when it must, writes one purchase row on save and
/// nothing on cancel, and scrolls on the shortest supported viewports.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const managerGrants = {'stock.view', 'sales.make', 'expenses.approve'};

  late ScreenTestEnvironment env;
  late BusinessData business;
  late ManufacturerData manufacturer;

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
    // The purchase is attributed to the signed-in 'test-user-id'.
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: const Value('test-user-id'),
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
            name: 'Guinness Nigeria',
            depositAmountKobo: const Value(150000),
          ),
        );
    manufacturer = await (db.select(db.manufacturers)
          ..where((m) => m.id.equals(mfrId)))
        .getSingle();
  });

  tearDown(() async {
    await env.dispose();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 150));
    }
  }

  Future<void> openScreen(
    WidgetTester tester, {
    Size size = pixel7Portrait,
    Set<String> grantedKeys = managerGrants,
    String roleSlug = 'manager',
    String roleName = 'Manager',
    int roleRank = GateTier.manager,
    List<StoreData>? selectableStores,
    bool allStores = false,
  }) async {
    await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: ManufacturerScreen(manufacturer: manufacturer),
      grantedKeys: grantedKeys,
      roleSlug: roleSlug,
      roleName: roleName,
      roleRank: roleRank,
      selectableStores: selectableStores,
      overrides: [
        currentBusinessProvider.overrideWith((ref) => business),
        firstRunSurfaceStateProvider
            .overrideWithValue(FirstRunSurfaceState.hasContent),
      ],
      settle: false,
    );
    if (allStores) NavigationService().clearStoreLock();
    await settle(tester);
  }

  Finder buyButton() => find.byKey(const ValueKey(kBuyCratesButtonKey));
  Finder sheet() => find.byType(BuyCratesSheet);
  Finder field(String key) => find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(TextField),
      );
  Finder saveButton() => find.byKey(const ValueKey(kBuyCratesSaveButtonKey));
  Finder cancelButton() =>
      find.byKey(const ValueKey(kBuyCratesCancelButtonKey));
  String recordedLine(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey(kBuyCratesRecordedLineKey)))
      .data!;

  Future<void> openSheet(WidgetTester tester) async {
    // Centre it so the pinned tab bar doesn't cover it.
    await Scrollable.ensureVisible(
      tester.element(buyButton()),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(buyButton());
    await tester.pumpAndSettle();
    expect(sheet(), findsOneWidget);
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// Lets the save toast's dismiss timer run out, then unmounts.
  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await disposeScreen(tester);
  }

  Future<List<CrateLedgerData>> ledger() =>
      env.db.select(env.db.crateLedger).get();

  group('Buy crates visibility', () {
    const roles = [
      (
        slug: 'ceo',
        name: 'CEO',
        rank: GateTier.ceo,
        grants: managerGrants,
        sees: true,
      ),
      (
        slug: 'manager',
        name: 'Manager',
        rank: GateTier.manager,
        grants: managerGrants,
        sees: true,
      ),
      (
        slug: 'stock_keeper',
        name: 'Stock keeper',
        rank: GateTier.stockKeeper,
        grants: {'stock.view', 'stock.add'},
        sees: false,
      ),
      (
        slug: 'cashier',
        name: 'Cashier',
        rank: GateTier.cashier,
        grants: {'stock.view', 'sales.make'},
        sees: false,
      ),
    ];

    for (final role in roles) {
      testWidgets(
          '${role.name} ${role.sees ? 'sees' : 'does not see'} Buy crates',
          (tester) async {
        await openScreen(
          tester,
          grantedKeys: role.grants,
          roleSlug: role.slug,
          roleName: role.name,
          roleRank: role.rank,
        );
        // Guards the "doesn't see" cases against passing on a dead screen.
        expect(find.text('In warehouse'), findsOneWidget);
        expect(buyButton(), role.sees ? findsOneWidget : findsNothing);
        await finish(tester);
      });
    }
  });

  group('Buy crates sheet', () {
    testWidgets(
        'shows what will be recorded, then writes one store-stamped, '
        'attributed purchase with the price paid', (tester) async {
      await openScreen(tester);
      await openSheet(tester);

      // One store, locked: no store is asked.
      expect(find.byKey(const ValueKey(kBuyCratesStorePickerKey)),
          findsNothing);

      await tester.enterText(field(kBuyCratesQuantityFieldKey), '4');
      await tester.enterText(field(kBuyCratesPriceFieldKey), '1200');
      await tester.pumpAndSettle();
      expect(
        recordedLine(tester),
        allOf(
          contains('+4 crates'),
          contains(env.store.name),
          contains('₦4,800'),
          contains('does not change profit'),
        ),
      );

      await tapVisible(tester, saveButton());

      expect(sheet(), findsNothing);
      final row = (await ledger()).single;
      expect(row.movementType, kCrateMovementPurchase);
      expect(row.quantityDelta, 4);
      expect(row.storeId, env.storeId);
      expect(row.performedBy, 'test-user-id');
      expect(row.ratePerCrateKobo, 120000);
      await finish(tester);
    });

    testWidgets('Cancel writes nothing', (tester) async {
      await openScreen(tester);
      await openSheet(tester);
      await tester.enterText(field(kBuyCratesQuantityFieldKey), '4');
      await tester.enterText(field(kBuyCratesPriceFieldKey), '1200');
      await tapVisible(tester, cancelButton());

      expect(sheet(), findsNothing);
      expect(await ledger(), isEmpty);
      expect(await env.db.select(env.db.syncQueue).get(), isEmpty);
      await finish(tester);
    });

    testWidgets('a blank quantity or price is rejected and writes nothing',
        (tester) async {
      await openScreen(tester);
      await openSheet(tester);

      await tapVisible(tester, saveButton());
      expect(sheet(), findsOneWidget);
      expect(find.text('Enter how many crates you bought'), findsOneWidget);
      expect(find.text('Enter the price paid per crate'), findsOneWidget);

      await tester.enterText(field(kBuyCratesQuantityFieldKey), '0');
      await tester.enterText(field(kBuyCratesPriceFieldKey), '500');
      await tapVisible(tester, saveButton());
      expect(sheet(), findsOneWidget);
      expect(await ledger(), isEmpty);
      await finish(tester);
    });

    testWidgets('All Stores on a one-store business asks no store',
        (tester) async {
      await openScreen(tester, allStores: true);
      await openSheet(tester);
      expect(find.byKey(const ValueKey(kBuyCratesStorePickerKey)),
          findsNothing);
      await finish(tester);
    });

    testWidgets(
        'All Stores on a multi-store business must choose a store, and the '
        'crates land in the chosen one', (tester) async {
      const otherStoreId = 'store-other';
      await env.db.into(env.db.stores).insert(
            StoresCompanion.insert(
              id: const Value(otherStoreId),
              businessId: env.businessId,
              name: 'Warehouse Two',
            ),
          );
      final otherStore = (await env.db.storesDao.getStore(otherStoreId))!;
      await openScreen(
        tester,
        selectableStores: [env.store, otherStore],
        allStores: true,
      );
      await openSheet(tester);

      expect(find.byKey(const ValueKey(kBuyCratesStorePickerKey)),
          findsOneWidget);
      await tester.enterText(field(kBuyCratesQuantityFieldKey), '2');
      await tester.enterText(field(kBuyCratesPriceFieldKey), '1000');
      await tester.pumpAndSettle();
      expect(recordedLine(tester), contains('Choose the store'));

      // No store yet: nothing is written.
      await tapVisible(tester, saveButton());
      expect(sheet(), findsOneWidget);
      expect(await ledger(), isEmpty);

      await tapVisible(
        tester,
        find.byKey(const ValueKey(kBuyCratesStorePickerKey)),
      );
      await tester.tap(find.text('Warehouse Two').last);
      await tester.pumpAndSettle();
      expect(recordedLine(tester), contains('Warehouse Two'));

      await tapVisible(tester, saveButton());
      expect(sheet(), findsNothing);
      expect((await ledger()).single.storeId, otherStoreId);
      await finish(tester);
    });

    for (final size in [phoneSe1Portrait, androidCompactLandscape]) {
      testWidgets(
          'scrolls, clears the device bottom padding, and saves at '
          '${size.width.toInt()}x${size.height.toInt()}', (tester) async {
        await openScreen(tester, size: size);
        await openSheet(tester);

        final scroll = find.descendant(
          of: sheet(),
          matching: find.byType(SingleChildScrollView),
        );
        expect(scroll, findsOneWidget);
        final padding =
            tester.widget<SingleChildScrollView>(scroll).padding! as EdgeInsets;
        final sheetContext = tester.element(sheet());
        expect(
          padding.bottom,
          sheetContext.getRSize(24) + sheetContext.deviceBottomPadding,
        );

        await tester.enterText(field(kBuyCratesQuantityFieldKey), '3');
        await tester.enterText(field(kBuyCratesPriceFieldKey), '1500');
        await tapVisible(tester, saveButton());

        expectNoOverflow(tester);
        expect(sheet(), findsNothing);
        expect(await ledger(), hasLength(1));
        await finish(tester);
      });
    }
  });
}
