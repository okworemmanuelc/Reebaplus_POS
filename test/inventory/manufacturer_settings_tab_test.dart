import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/crates/crate_value_change_impact.dart';
import 'package:reebaplus_pos/core/crates/manufacturer_crate_position.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/inventory/screens/manufacturer_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/crate_value_change_sheet.dart';
import 'package:reebaplus_pos/features/inventory/widgets/manufacturer_settings_tab.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

/// Issue #295 — the Manufacturer Settings tab: one crate value box, a
/// consequence confirmation, the arrangement on its own, and no Manage sheet.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const baseGrants = {'stock.view', 'sales.make', 'stock.add'};
  const managerGrants = {...baseGrants, 'products.edit_price'};
  const ceoGrants = {...managerGrants, 'settings.manage'};
  const crateValueKobo = 100000; // ₦1,000

  late ScreenTestEnvironment env;
  late BusinessData business;
  late ManufacturerData manufacturer;

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
    required Set<String> grants,
    String roleSlug = 'ceo',
    int roleRank = GateTier.ceo,
    Size size = pixel7Portrait,
  }) async {
    await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: ManufacturerScreen(manufacturer: manufacturer),
      grantedKeys: grants,
      roleSlug: roleSlug,
      roleName: roleSlug,
      roleRank: roleRank,
      overrides: [currentBusinessProvider.overrideWith((ref) => business)],
      settle: false,
    );
    await settle(tester);
  }

  Future<void> openSettingsTab(WidgetTester tester) async {
    await tester.tap(find.text('Settings'));
    await settle(tester);
  }

  Future<ManufacturerData> reload() async => (env.db.select(env.db.manufacturers)
        ..where((m) => m.id.equals(manufacturer.id)))
      .getSingle();

  Future<void> enterFields(
    WidgetTester tester, {
    String? name,
    String? value,
  }) async {
    if (name != null) {
      await tester.enterText(
        find.byKey(const ValueKey(kManufacturerSettingsNameFieldKey)),
        name,
      );
    }
    if (value != null) {
      await tester.enterText(
        find.byKey(const ValueKey(kManufacturerSettingsCrateValueFieldKey)),
        value,
      );
    }
    await tester.pump();
  }

  /// Drags the screen up until [target] is fully on screen.
  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    for (var i = 0; i < 12 && visibleRowCount(tester, target) < 1; i++) {
      await tester.drag(find.byType(NestedScrollView), const Offset(0, -120));
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  /// The success toast holds a 4s timer; let it lapse before teardown.
  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await disposeScreen(tester);
  }

  Future<void> tapSave(WidgetTester tester) async {
    final save = find.byKey(const ValueKey(kManufacturerSettingsSaveButtonKey));
    await scrollTo(tester, save);
    await tester.tap(save);
    await settle(tester);
  }

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
    final mfrId = UuidV7.generate();
    await db.into(db.manufacturers).insert(
          ManufacturersCompanion.insert(
            id: Value(mfrId),
            businessId: env.businessId,
            name: 'Guinness Nigeria',
            depositAmountKobo: const Value(crateValueKobo),
            lastUpdatedAt: Value(DateTime(2020)),
          ),
        );
    manufacturer = await (db.select(db.manufacturers)
          ..where((m) => m.id.equals(mfrId)))
        .getSingle();
    // Empties in the warehouse, so a value change has something to move.
    await db.into(db.crateLedger).insert(
          CrateLedgerCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: env.businessId,
            manufacturerId: Value(mfrId),
            storeId: Value(env.storeId),
            quantityDelta: 10,
            movementType: 'transferred_in',
          ),
        );
  });

  tearDown(() => env.dispose());

  group('computeCrateValueChangeImpact', () {
    test('re-prices count-based statuses; customer deposit does not move', () {
      final position = computeManufacturerCratePosition(
        manufacturerId: 'm',
        crateValueKobo: 100000,
        warehouseCrates: 10,
        fullCrates: 4,
        customerOnDepositCrates: 2,
        customerOnDepositKobo: 200000,
        customerNoDepositCrates: 3,
        shortCrates: 1,
      );
      final impact = computeCrateValueChangeImpact(
        position: position,
        newKobo: 150000,
        supplierDebtCrates: 5,
      );

      expect(
        impact.statusMoves.map((m) => m.label),
        isNot(contains('With customers, on deposit')),
      );
      final warehouse =
          impact.statusMoves.firstWhere((m) => m.label == 'In the warehouse');
      expect(warehouse.beforeKobo, 1000000);
      expect(warehouse.afterKobo, 1500000);
      expect(impact.supplierDebt!.deltaKobo, 5 * 50000);
      // (10 + 4 + 3 + 1) crates + 5 owed, each +₦500.
      expect(impact.totalDeltaKobo, 23 * 50000);
    });

    test('a snapshotted damage loss is history and does not re-price', () {
      final position = computeManufacturerCratePosition(
        manufacturerId: 'm',
        crateValueKobo: 100000,
        damagedCrates: 2,
        damagedLossKobo: 150000,
      );
      final impact =
          computeCrateValueChangeImpact(position: position, newKobo: 200000);
      expect(impact.statusMoves, isEmpty);
    });
  });

  group('Settings tab gating', () {
    testWidgets('CEO sees Settings with name, value and the arrangement',
        (tester) async {
      await openScreen(tester, grants: ceoGrants);
      await openSettingsTab(tester);

      expect(
        find.byKey(const ValueKey(kManufacturerSettingsNameFieldKey)),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey(kManufacturerSettingsCrateValueFieldKey)),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey(kManufacturerSettingsArrangementKey)),
        findsOneWidget,
      );
      // One box for the value: no Add/Change mode chips.
      expect(find.text('Add'), findsNothing);
      expect(find.text('Change'), findsNothing);
      await finish(tester);
    });

    testWidgets('Manager sees name + value but not the arrangement',
        (tester) async {
      await openScreen(
        tester,
        grants: managerGrants,
        roleSlug: 'manager',
        roleRank: GateTier.manager,
      );
      await openSettingsTab(tester);

      expect(
        find.byKey(const ValueKey(kManufacturerSettingsNameFieldKey)),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey(kManufacturerSettingsArrangementKey)),
        findsNothing,
      );
      await finish(tester);
    });

    for (final entry in {
      'stock_keeper': GateTier.stockKeeper,
      'cashier': GateTier.cashier,
    }.entries) {
      testWidgets('${entry.key} sees no Settings tab', (tester) async {
        await openScreen(
          tester,
          grants: baseGrants,
          roleSlug: entry.key,
          roleRank: entry.value,
        );
        expect(find.text('Settings'), findsNothing);
        expect(find.text('Crates'), findsWidgets);
        await finish(tester);
      });
    }
  });

  group('Saving', () {
    testWidgets('confirming persists name + value, bumps last_updated_at, '
        'leaves the arrangement alone', (tester) async {
      final before = await reload();
      await openScreen(tester, grants: ceoGrants);
      await openSettingsTab(tester);

      await enterFields(tester, name: 'Guinness Foreign', value: '1500');
      await tapSave(tester);

      // The consequence is shown in naira before anything is written.
      expect(find.byKey(const ValueKey(kCrateValueChangeSheetKey)),
          findsOneWidget);
      expect(find.textContaining('₦1,000'), findsWidgets);
      expect(find.textContaining('₦1,500'), findsWidgets);
      expect(find.textContaining('Past sales, damages'), findsOneWidget);
      expect((await reload()).depositAmountKobo, crateValueKobo);

      await tester.tap(
        find.byKey(const ValueKey(kCrateValueChangeConfirmKey)),
      );
      await settle(tester);

      final after = await reload();
      expect(after.name, 'Guinness Foreign');
      expect(after.depositAmountKobo, 150000);
      expect(after.crateMoneyArrangement, before.crateMoneyArrangement);
      expect(after.lastUpdatedAt.isAfter(before.lastUpdatedAt), isTrue);
      await finish(tester);
    });

    testWidgets('backing out of the confirmation writes nothing',
        (tester) async {
      final before = await reload();
      await openScreen(tester, grants: ceoGrants);
      await openSettingsTab(tester);

      await enterFields(tester, name: 'Renamed', value: '2500');
      await tapSave(tester);
      await tester.tap(
        find.byKey(const ValueKey(kCrateValueChangeCancelKey)),
      );
      await settle(tester);

      final after = await reload();
      expect(after.name, before.name);
      expect(after.depositAmountKobo, before.depositAmountKobo);
      expect(after.lastUpdatedAt, before.lastUpdatedAt);
      await finish(tester);
    });

    testWidgets('a rename alone saves without the value confirmation',
        (tester) async {
      await openScreen(tester, grants: managerGrants, roleSlug: 'manager',
          roleRank: GateTier.manager);
      await openSettingsTab(tester);

      await enterFields(tester, name: 'Guinness Plc');
      await tapSave(tester);

      expect(find.byKey(const ValueKey(kCrateValueChangeSheetKey)),
          findsNothing);
      final after = await reload();
      expect(after.name, 'Guinness Plc');
      expect(after.depositAmountKobo, crateValueKobo);
      await finish(tester);
    });

    testWidgets('a change leaves past sales at their snapshotted rate',
        (tester) async {
      final db = env.db;
      final orderId = UuidV7.generate();
      await db.into(db.orders).insert(
            OrdersCompanion.insert(
              id: Value(orderId),
              businessId: env.businessId,
              orderNumber: 'ORD-SNAP-1',
              totalAmountKobo: 200000,
              netAmountKobo: 200000,
              paymentType: 'cash',
              status: 'completed',
              storeId: Value(env.storeId),
            ),
          );
      final lineId = UuidV7.generate();
      await db.into(db.orderCrateLines).insert(
            OrderCrateLinesCompanion.insert(
              id: Value(lineId),
              businessId: env.businessId,
              orderId: orderId,
              manufacturerId: manufacturer.id,
              cratesTaken: 2,
              depositRateKobo: const Value(crateValueKobo),
              depositPaidKobo: const Value(200000),
            ),
          );

      await openScreen(tester, grants: ceoGrants);
      await openSettingsTab(tester);
      await enterFields(tester, value: '3000');
      await tapSave(tester);
      await tester.tap(
        find.byKey(const ValueKey(kCrateValueChangeConfirmKey)),
      );
      await settle(tester);

      expect((await reload()).depositAmountKobo, 300000);
      final line = await (db.select(db.orderCrateLines)
            ..where((l) => l.id.equals(lineId)))
          .getSingle();
      expect(line.depositRateKobo, crateValueKobo);
      expect(line.depositPaidKobo, 200000);
      await finish(tester);
    });
  });

  group('Viewport contract (#239)', () {
    for (final entry in {
      '320x568': phoneSe1Portrait,
      '800x360': androidCompactLandscape,
    }.entries) {
      testWidgets('Settings tab and confirmation fit at ${entry.key}',
          (tester) async {
        await openScreen(tester, grants: ceoGrants, size: entry.value);
        await openSettingsTab(tester);
        expectNoOverflow(tester, reason: 'Settings tab overflowed');

        await enterFields(tester, value: '1500');
        await tapSave(tester);
        expectNoOverflow(tester, reason: 'Confirmation overflowed');
        final confirm =
            find.byKey(const ValueKey(kCrateValueChangeConfirmKey));
        expect(confirm, findsOneWidget);
        await scrollTo(tester, confirm);
        expect(visibleRowCount(tester, confirm), 1);
        await finish(tester);
      });
    }
  });
}
