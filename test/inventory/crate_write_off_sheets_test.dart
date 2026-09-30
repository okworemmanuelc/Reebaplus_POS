import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/crates/crate_shortfall.dart';
import 'package:reebaplus_pos/core/crates/manufacturer_crate_position.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/inventory/screens/manufacturer_screen.dart';
import 'package:reebaplus_pos/shared/widgets/crate_shortage_write_off_sheet.dart';
import 'package:reebaplus_pos/shared/widgets/reverse_crate_write_off_sheet.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

/// Issue #296: Write off and Reverse write-off on the manufacturer screen's
/// Short status. CEO and Manager see them; a Stock keeper and a Cashier don't.
/// Each sheet states what will be recorded, writes on save, writes nothing on
/// cancel, rejects more than is open, and scrolls on the shortest viewports.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const managerGrants = {'stock.view', 'sales.make', 'expenses.approve'};
  const userId = 'test-user-id';

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
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: const Value(userId),
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

  Future<void> count(int counted) =>
      env.db.cratePoolDao.recordManualCountCorrection(
        manufacturerId: manufacturer.id,
        storeId: env.storeId,
        performedBy: userId,
        countedEmpties: counted,
      );

  // Real gaps between the steps: the fold orders same-second rows by their
  // millisecond UUIDv7 ids, so each step needs its own millisecond.
  Future<void> gap(WidgetTester tester) => tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );

  /// 2 crates missing and not written off.
  Future<void> seedShort(WidgetTester tester) async {
    await count(30);
    await gap(tester);
    await count(28);
  }

  /// 1 written-off crate found and reversible. A brand at one store is never
  /// both short and reversible: found crates close what is open first, and a
  /// new gap takes found crates back first.
  Future<void> seedReversible(WidgetTester tester) async {
    await count(30);
    await gap(tester);
    await count(20);
    await gap(tester);
    await env.db.cratePoolDao.writeOffCrateShortage(
      manufacturerId: manufacturer.id,
      storeId: env.storeId,
      crateCount: 10,
      performedBy: userId,
    );
    await gap(tester);
    await count(21);
  }

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
      overrides: [
        currentBusinessProvider.overrideWith((ref) => business),
        firstRunSurfaceStateProvider
            .overrideWithValue(FirstRunSurfaceState.hasContent),
      ],
      settle: false,
    );
    await settle(tester);
  }

  // The Short card sits below the fold at phone height.
  Finder writeOffButton() => find.byKey(
        const ValueKey(kManufacturerWriteOffButtonKey),
        skipOffstage: false,
      );
  Finder reverseButton() => find.byKey(
        const ValueKey(kManufacturerReverseWriteOffButtonKey),
        skipOffstage: false,
      );
  Finder shortCard() => find.byKey(
        const ValueKey('${kManufacturerStatusKeyPrefix}short'),
        skipOffstage: false,
      );
  Finder field(String key) => find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(TextField),
      );
  String textOf(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(ValueKey(key))).data!;

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    // Let a just-focused field finish scrolling itself into view first, or it
    // scrolls the button back out after ensureVisible.
    await tester.pumpAndSettle();
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
    // A save reads and writes in one transaction; give it real time.
    await settle(tester);
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, Finder button, Type sheet) async {
    await Scrollable.ensureVisible(tester.element(button), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byType(sheet), findsOneWidget);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await disposeScreen(tester);
  }

  Future<List<CrateShortfallWriteoffData>> writeOffRows() =>
      env.db.select(env.db.crateShortfallWriteoffs).get();

  group('visibility', () {
    const roles = [
      (slug: 'ceo', name: 'CEO', rank: GateTier.ceo, grants: managerGrants, sees: true),
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
          '${role.name} ${role.sees ? 'sees' : 'does not see'} Write off',
          (tester) async {
        await seedShort(tester);
        await openScreen(
          tester,
          grantedKeys: role.grants,
          roleSlug: role.slug,
          roleName: role.name,
          roleRank: role.rank,
        );
        // Guards the "doesn't see" cases against passing on a dead screen.
        expect(shortCard(), findsOneWidget);
        expect(
          find.descendant(
            of: shortCard(),
            matching: find.text('2 crates', skipOffstage: false),
          ),
          findsOneWidget,
        );
        expect(writeOffButton(), role.sees ? findsOneWidget : findsNothing);
        expect(reverseButton(), findsNothing);
        await finish(tester);
      });

      testWidgets(
          '${role.name} ${role.sees ? 'sees' : 'does not see'} Reverse',
          (tester) async {
        await seedReversible(tester);
        await openScreen(
          tester,
          grantedKeys: role.grants,
          roleSlug: role.slug,
          roleName: role.name,
          roleRank: role.rank,
        );
        expect(shortCard(), findsOneWidget);
        expect(writeOffButton(), findsNothing);
        expect(reverseButton(), role.sees ? findsOneWidget : findsNothing);
        await finish(tester);
      });
    }

    testWidgets('with nothing short and nothing to reverse, neither shows',
        (tester) async {
      await count(30);
      await openScreen(tester);
      expect(shortCard(), findsOneWidget);
      expect(writeOffButton(), findsNothing);
      expect(reverseButton(), findsNothing);
      await finish(tester);
    });
  });

  group('Write off sheet', () {
    testWidgets('shows what will be recorded, then writes one count-shortage '
        'write-off', (tester) async {
      await count(30);
      await count(26);
      await openScreen(tester);
      await open(tester, writeOffButton(), CrateShortageWriteOffSheet);

      // One brand, one store: neither is asked.
      expect(find.byKey(const ValueKey(kCrateWriteOffBrandPickerKey)), findsNothing);
      expect(find.byKey(const ValueKey(kCrateWriteOffStorePickerKey)), findsNothing);

      await tester.enterText(field(kCrateWriteOffQuantityFieldKey), '3');
      await tester.pumpAndSettle();
      expect(
        textOf(tester, kCrateWriteOffRecordedLineKey),
        allOf(
          contains('3 Guinness Nigeria crates'),
          contains(env.store.name),
          contains('₦4,500'),
          contains('No earlier day changes'),
        ),
      );

      await tapVisible(
        tester,
        find.byKey(const ValueKey(kCrateWriteOffSaveButtonKey)),
      );
      expect(find.byType(CrateShortageWriteOffSheet), findsNothing);
      final row = (await writeOffRows()).single;
      expect(row.source, kCrateWriteOffSourceCountShortage);
      expect(row.crateCount, 3);
      expect(row.ratePerCrateKobo, 150000);
      expect(row.storeId, env.storeId);
      expect(row.performedBy, userId);
      await finish(tester);
    });

    testWidgets('rejects more than is missing, and Cancel writes nothing',
        (tester) async {
      await count(30);
      await count(26);
      await openScreen(tester);
      await open(tester, writeOffButton(), CrateShortageWriteOffSheet);

      await tester.enterText(field(kCrateWriteOffQuantityFieldKey), '5');
      await tapVisible(
        tester,
        find.byKey(const ValueKey(kCrateWriteOffSaveButtonKey)),
      );
      expect(find.text('Only 4 missing'), findsOneWidget);
      expect(await writeOffRows(), isEmpty);

      await tapVisible(
        tester,
        find.byKey(const ValueKey(kCrateWriteOffCancelButtonKey)),
      );
      expect(find.byType(CrateShortageWriteOffSheet), findsNothing);
      expect(await writeOffRows(), isEmpty);
      await finish(tester);
    });
  });

  group('Reverse write-off sheet', () {
    testWidgets('shows the gain, then writes a compensating row; Cancel writes '
        'nothing', (tester) async {
      await seedReversible(tester);
      final before = (await writeOffRows()).length;
      await openScreen(tester);

      await open(tester, reverseButton(), ReverseCrateWriteOffSheet);
      await tester.enterText(field(kReverseWriteOffQuantityFieldKey), '1');
      await tapVisible(
        tester,
        find.byKey(const ValueKey(kReverseWriteOffCancelButtonKey)),
      );
      expect(await writeOffRows(), hasLength(before));

      await open(tester, reverseButton(), ReverseCrateWriteOffSheet);
      await tester.enterText(field(kReverseWriteOffQuantityFieldKey), '2');
      await tapVisible(
        tester,
        find.byKey(const ValueKey(kReverseWriteOffSaveButtonKey)),
      );
      expect(find.text('Only 1 can be reversed'), findsOneWidget);

      await tester.enterText(field(kReverseWriteOffQuantityFieldKey), '1');
      await tester.pumpAndSettle();
      expect(
        textOf(tester, kReverseWriteOffRecordedLineKey),
        allOf(contains('₦1,500'), contains('No earlier day changes')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey(kReverseWriteOffSaveButtonKey)),
      );
      expect(find.byType(ReverseCrateWriteOffSheet), findsNothing);
      final reversal =
          (await writeOffRows()).where((r) => r.crateCount < 0).single;
      expect(reversal.crateCount, -1);
      expect(reversal.ratePerCrateKobo, 150000);
      await finish(tester);
    });
  });

  group('viewports', () {
    for (final size in [phoneSe1Portrait, androidCompactLandscape]) {
      testWidgets(
          'both sheets scroll, clear the device bottom padding and save at '
          '${size.width.toInt()}x${size.height.toInt()}', (tester) async {
        await seedShort(tester);
        await openScreen(tester, size: size);

        await open(tester, writeOffButton(), CrateShortageWriteOffSheet);
        var scroll = find.descendant(
          of: find.byType(CrateShortageWriteOffSheet),
          matching: find.byType(SingleChildScrollView),
        );
        expect(scroll, findsOneWidget);
        var padding =
            tester.widget<SingleChildScrollView>(scroll).padding! as EdgeInsets;
        var ctx = tester.element(find.byType(CrateShortageWriteOffSheet));
        expect(padding.bottom, ctx.getRSize(24) + ctx.deviceBottomPadding);
        await tester.enterText(field(kCrateWriteOffQuantityFieldKey), '2');
        await tapVisible(
          tester,
          find.byKey(const ValueKey(kCrateWriteOffSaveButtonKey)),
        );
        expectNoOverflow(tester);
        expect(find.byType(CrateShortageWriteOffSheet), findsNothing);
        await tester.pump(const Duration(seconds: 5));

        // A later count finds one of the written-off crates.
        await gap(tester);
        await tester.runAsync(() => count(29));
        await settle(tester);
        await tester.pumpAndSettle();

        await open(tester, reverseButton(), ReverseCrateWriteOffSheet);
        scroll = find.descendant(
          of: find.byType(ReverseCrateWriteOffSheet),
          matching: find.byType(SingleChildScrollView),
        );
        expect(scroll, findsOneWidget);
        padding =
            tester.widget<SingleChildScrollView>(scroll).padding! as EdgeInsets;
        ctx = tester.element(find.byType(ReverseCrateWriteOffSheet));
        expect(padding.bottom, ctx.getRSize(24) + ctx.deviceBottomPadding);
        await tester.enterText(field(kReverseWriteOffQuantityFieldKey), '1');
        await tapVisible(
          tester,
          find.byKey(const ValueKey(kReverseWriteOffSaveButtonKey)),
        );
        expectNoOverflow(tester);
        expect(find.byType(ReverseCrateWriteOffSheet), findsNothing);
        await finish(tester);
      });
    }
  });
}
