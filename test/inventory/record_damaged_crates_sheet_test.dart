import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/crates/manufacturer_crate_position.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/features/inventory/screens/manufacturer_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/record_damaged_crates_sheet.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

/// Issue #297: Record damaged empties from the manufacturer screen.
/// Gated by Gates.countCrates (stock.view).
/// Validates quantity against the store's warehouse count; previews loss;
/// writes a damaged crate_ledger movement with snapshotted rate; scrolls on compact viewports.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    // Attribute to test-user-id
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: const Value('test-user-id'),
            businessId: env.businessId,
            name: 'Test Staff',
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

    // Seed 10 empties in the primary store
    await db.into(db.crateLedger).insert(
          CrateLedgerCompanion.insert(
            businessId: env.businessId,
            manufacturerId: Value(mfrId),
            storeId: Value(env.storeId),
            quantityDelta: 10,
            movementType: 'count',
          ),
        );
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
    Set<String> grantedKeys = const {'stock.view'},
    String roleSlug = 'stock_keeper',
    String roleName = 'Stock keeper',
    int roleRank = GateTier.stockKeeper,
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

  Finder recordDamagedButton() =>
      find.byKey(const ValueKey(kManufacturerRecordDamagedButtonKey));
  Finder sheet() => find.byType(RecordDamagedCratesSheet);
  Finder field(String key) => find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(TextField),
      );
  Finder saveButton() =>
      find.byKey(const ValueKey(kRecordDamagedSaveButtonKey));
  Finder cancelButton() =>
      find.byKey(const ValueKey(kRecordDamagedCancelButtonKey));
  String lossPreview(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey(kRecordDamagedLossPreviewKey)))
      .data!;

  Future<void> openSheet(WidgetTester tester) async {
    await Scrollable.ensureVisible(
      tester.element(recordDamagedButton()),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(recordDamagedButton());
    await tester.pumpAndSettle();
    expect(sheet(), findsOneWidget);
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await disposeScreen(tester);
  }

  Future<List<CrateLedgerData>> ledger() =>
      env.db.select(env.db.crateLedger).get();

  group('Record damaged button visibility', () {
    const roles = [
      (
        slug: 'ceo',
        name: 'CEO',
        rank: GateTier.ceo,
        grants: {'stock.view'},
        sees: true,
      ),
      (
        slug: 'manager',
        name: 'Manager',
        rank: GateTier.manager,
        grants: {'stock.view'},
        sees: true,
      ),
      (
        slug: 'stock_keeper',
        name: 'Stock keeper',
        rank: GateTier.stockKeeper,
        grants: {'stock.view'},
        sees: true,
      ),
      (
        slug: 'cashier',
        name: 'Cashier',
        rank: GateTier.cashier,
        grants: {'stock.view'},
        sees: true,
      ),
      (
        slug: 'cashier',
        name: 'Cashier without stock.view',
        rank: GateTier.cashier,
        grants: {'sales.make'},
        sees: false,
      ),
    ];

    for (final role in roles) {
      testWidgets(
          '${role.name} ${role.sees ? 'sees' : 'does not see'} Record damaged button',
          (tester) async {
        await openScreen(
          tester,
          grantedKeys: role.grants,
          roleSlug: role.slug,
          roleName: role.name,
          roleRank: role.rank,
        );
        if (role.sees) {
          expect(find.text('In warehouse'), findsOneWidget);
        } else {
          expect(find.text('You do not have permission to view inventory.'),
              findsOneWidget);
        }
        expect(recordDamagedButton(), role.sees ? findsOneWidget : findsNothing);
        await finish(tester);
      });
    }
  });

  group('Record damaged sheet', () {
    testWidgets(
        'shows loss preview, validates quantity against warehouse count, '
        'and records damaged crate movement with snapshotted rate',
        (tester) async {
      await openScreen(tester);
      await openSheet(tester);

      // Single locked store: store picker is omitted
      expect(find.byKey(const ValueKey(kRecordDamagedStorePickerKey)),
          findsNothing);

      // Warehouse count is shown in the field label
      expect(find.textContaining('10 in warehouse'), findsOneWidget);

      await tester.enterText(field(kRecordDamagedQuantityFieldKey), '3');
      await tester.pumpAndSettle();

      expect(
        lossPreview(tester),
        allOf(
          contains('-3 crates from ${env.store.name}\'s warehouse'),
          contains('Loss: ₦4,500'),
          contains('(3 × ₦1,500)'),
          contains('Broken'),
        ),
      );

      await tapVisible(tester, saveButton());

      expect(sheet(), findsNothing);

      final rows = await ledger();
      final damaged = rows.where((r) => r.movementType == 'damaged').toList();
      expect(damaged.length, 1);
      final row = damaged.single;
      expect(row.quantityDelta, -3);
      expect(row.storeId, env.storeId);
      expect(row.performedBy, 'test-user-id');
      expect(row.ratePerCrateKobo, 150000);

      await finish(tester);
    });

    testWidgets('rejects damage exceeding warehouse count', (tester) async {
      await openScreen(tester);
      await openSheet(tester);

      // Enter 15 when warehouse has 10
      await tester.enterText(field(kRecordDamagedQuantityFieldKey), '15');
      await tester.pumpAndSettle();

      await tapVisible(tester, saveButton());

      // Validation error shown, sheet stays open
      expect(find.text('Only 10 empty crates in warehouse'), findsOneWidget);
      expect(sheet(), findsOneWidget);

      final rows = await ledger();
      expect(rows.where((r) => r.movementType == 'damaged'), isEmpty);

      await finish(tester);
    });

    testWidgets('Cancel writes nothing', (tester) async {
      await openScreen(tester);
      await openSheet(tester);

      await tester.enterText(field(kRecordDamagedQuantityFieldKey), '2');
      await tester.pumpAndSettle();

      await tapVisible(tester, cancelButton());

      expect(sheet(), findsNothing);
      final rows = await ledger();
      expect(rows.where((r) => r.movementType == 'damaged'), isEmpty);

      await finish(tester);
    });

    testWidgets('multi-store All Stores requires picking a store',
        (tester) async {
      await env.db.into(env.db.stores).insert(
            StoresCompanion.insert(
              id: const Value('store-2'),
              businessId: env.businessId,
              name: 'Annex',
            ),
          );
      final store2 = await (env.db.select(env.db.stores)
            ..where((s) => s.id.equals('store-2')))
          .getSingle();

      // Seed 5 empties in store-2
      await env.db.into(env.db.crateLedger).insert(
            CrateLedgerCompanion.insert(
              businessId: env.businessId,
              manufacturerId: Value(manufacturer.id),
              storeId: const Value('store-2'),
              quantityDelta: 5,
              movementType: 'count',
            ),
          );

      await openScreen(
        tester,
        selectableStores: [env.store, store2],
        allStores: true,
      );
      await openSheet(tester);

      // Store picker is present
      expect(find.byKey(const ValueKey(kRecordDamagedStorePickerKey)),
          findsOneWidget);

      // Pick store
      await tester.tap(find.byKey(const ValueKey(kRecordDamagedStorePickerKey)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(env.store.name).last);
      await tester.pumpAndSettle();

      await tester.enterText(field(kRecordDamagedQuantityFieldKey), '2');
      await tester.pumpAndSettle();

      await tapVisible(tester, saveButton());

      expect(sheet(), findsNothing);
      final rows = await ledger();
      expect(rows.where((r) => r.movementType == 'damaged').length, 1);

      await finish(tester);
    });

    testWidgets('scrolls and saves at 320x568 compact viewport',
        (tester) async {
      await openScreen(tester, size: phoneSe1Portrait);
      await openSheet(tester);

      await tester.enterText(field(kRecordDamagedQuantityFieldKey), '1');
      await tester.pumpAndSettle();

      await tapVisible(tester, saveButton());

      expect(sheet(), findsNothing);
      final rows = await ledger();
      expect(rows.where((r) => r.movementType == 'damaged').length, 1);

      await finish(tester);
    });

    testWidgets('scrolls and saves at 800x360 landscape viewport',
        (tester) async {
      await openScreen(tester, size: androidCompactLandscape);
      await openSheet(tester);

      await tester.enterText(field(kRecordDamagedQuantityFieldKey), '1');
      await tester.pumpAndSettle();

      await tapVisible(tester, saveButton());

      expect(sheet(), findsNothing);
      final rows = await ledger();
      expect(rows.where((r) => r.movementType == 'damaged').length, 1);

      await finish(tester);
    });
  });
}
