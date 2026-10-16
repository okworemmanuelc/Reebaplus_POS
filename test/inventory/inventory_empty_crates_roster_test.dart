import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/crates/empty_crates_roster.dart';
import 'package:reebaplus_pos/core/crates/manufacturer_crate_position.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/features/inventory/screens/inventory_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/manufacturer_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_manufacturers_tab.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

/// Issue #389 — Inventory → Empty Crates lists only manufacturers with a
/// tracked bottle product (`unit == 'bottle' && trackEmpties`), keeps a brand
/// that still holds crates after its bottles were removed, and the new
/// Manufacturers tab lists every manufacturer and opens one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const grants = {
    'sales.make',
    'stock.view',
    'products.add',
    'stock.add',
    'products.edit_price',
  };

  late ScreenTestEnvironment env;
  // Manufacturer ids by name, seeded per test.
  final ids = <String, String>{};

  Future<String> addManufacturer(String name) async {
    final id = UuidV7.generate();
    await env.db
        .into(env.db.manufacturers)
        .insert(
          ManufacturersCompanion.insert(
            id: Value(id),
            businessId: env.businessId,
            name: name,
            depositAmountKobo: const Value(150000),
          ),
        );
    ids[name] = id;
    return id;
  }

  Future<void> addProduct(
    String manufacturerId, {
    required String unit,
    bool trackEmpties = true,
    bool isDeleted = false,
  }) async {
    await env.db
        .into(env.db.products)
        .insert(
          ProductsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: env.businessId,
            manufacturerId: Value(manufacturerId),
            name: '$unit product',
            unit: Value(unit),
            trackEmpties: Value(trackEmpties),
            isDeleted: Value(isDeleted),
            retailerPriceKobo: const Value(60000),
          ),
        );
  }

  /// Bottle, can-only, PET-only, mixed, a brand with nothing yet, a brand
  /// whose bottles were removed but still holds empties, and one whose
  /// bottles were removed with nothing left.
  Future<void> seedRoster() async {
    await addProduct(await addManufacturer('Bottle Co'), unit: 'Bottle');
    await addProduct(await addManufacturer('Can Co'), unit: 'Can');
    await addProduct(await addManufacturer('Pet Co'), unit: 'PET');
    final mixed = await addManufacturer('Mixed Co');
    await addProduct(mixed, unit: 'Can');
    await addProduct(mixed, unit: 'Bottle');
    await addManufacturer('Fresh Co');
    final kept = await addManufacturer('Kept Co');
    await addProduct(kept, unit: 'Bottle', isDeleted: true);
    await env.db.cratePoolDao.recordManualCountCorrection(
      manufacturerId: kept,
      storeId: env.storeId,
      performedBy: 'test-user-id',
      countedEmpties: 6,
    );
    final gone = await addManufacturer('Gone Co');
    await addProduct(gone, unit: 'Bottle', isDeleted: true);
  }

  setUp(() async {
    ids.clear();
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessType: 'Beverage distributor',
    );
    await env.db
        .into(env.db.users)
        .insert(
          UsersCompanion.insert(
            id: const Value('test-user-id'),
            businessId: env.businessId,
            name: 'Test Admin',
            pin: '1234',
          ),
        );
  });

  tearDown(() async {
    await env.dispose();
  });

  Future<void> openTab(
    WidgetTester tester,
    String label, {
    Size size = pixel7Portrait,
    EdgeInsets padding = kRealisticPhoneInsets,
    TextScaler? textScaler,
  }) async {
    await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: padding,
      textScaler: textScaler,
      screen: const InventoryScreen(),
      grantedKeys: grants,
      overrides: [
        firstRunSurfaceStateProvider.overrideWithValue(
          FirstRunSurfaceState.hasContent,
        ),
      ],
    );
    await tester.tap(find.widgetWithText(Tab, label));
    await tester.pumpAndSettle();
  }

  Finder crateCard(String name) =>
      find.byKey(ValueKey('$kManufacturerCardKeyPrefix${ids[name]}'));

  Finder manufacturerRow(String name) =>
      find.byKey(ValueKey('$kInventoryManufacturerRowKeyPrefix${ids[name]}'));

  /// The open tab's own scroll view.
  Finder tabScrollable() => find.byType(Scrollable).hitTestable().first;

  Future<bool> isListed(WidgetTester tester, Finder card) async {
    if (card.evaluate().isNotEmpty) return true;
    try {
      await tester.scrollUntilVisible(card, 200, scrollable: tabScrollable());
      return true;
    } on StateError {
      return false;
    }
  }

  group('showsOnEmptyCrates', () {
    test('a tracked bottle brand shows; a brand with nothing on the books '
        'does not', () {
      expect(
        showsOnEmptyCrates(
          hasTrackedBottleProduct: true,
          emptyCount: 0,
          shortCount: 0,
        ),
        isTrue,
      );
      expect(
        showsOnEmptyCrates(
          hasTrackedBottleProduct: false,
          emptyCount: 0,
          shortCount: 0,
        ),
        isFalse,
      );
    });

    test('a brand without bottles still holding empties or short stays', () {
      expect(
        showsOnEmptyCrates(
          hasTrackedBottleProduct: false,
          emptyCount: 3,
          shortCount: 0,
        ),
        isTrue,
      );
      expect(
        showsOnEmptyCrates(
          hasTrackedBottleProduct: false,
          emptyCount: 0,
          shortCount: 2,
        ),
        isTrue,
      );
    });
  });

  test(
    'watchCrateTrackedManufacturerIds counts only live tracked bottles',
    () async {
      await seedRoster();
      final untracked = await addManufacturer('Untracked Bottle Co');
      await addProduct(untracked, unit: 'Bottle', trackEmpties: false);

      final tracked = await env.db.inventoryDao
          .watchCrateTrackedManufacturerIds()
          .first;
      expect(tracked, {ids['Bottle Co'], ids['Mixed Co']});
    },
  );

  group('Empty Crates tab', () {
    testWidgets(
      'lists bottle and mixed brands, keeps a brand still holding empties, '
      'and leaves out can, PET, new and emptied brands',
      (tester) async {
        await seedRoster();
        await openTab(tester, 'Empty Crates');

        expect(await isListed(tester, crateCard('Bottle Co')), isTrue);
        expect(await isListed(tester, crateCard('Mixed Co')), isTrue);
        expect(
          await isListed(tester, crateCard('Kept Co')),
          isTrue,
          reason: 'A brand still holding 6 empties must not vanish',
        );
        expect(
          find.descendant(of: crateCard('Kept Co'), matching: find.text('6')),
          findsWidgets,
        );
        for (final name in ['Can Co', 'Pet Co', 'Fresh Co', 'Gone Co']) {
          expect(crateCard(name), findsNothing, reason: '$name has no bottles');
        }
        // Scrolling the whole list never builds them either.
        await tester.drag(tabScrollable(), const Offset(0, -2000));
        await tester.pumpAndSettle();
        for (final name in ['Can Co', 'Pet Co', 'Fresh Co', 'Gone Co']) {
          expect(crateCard(name), findsNothing, reason: '$name has no bottles');
        }
        // Add New moved to the Manufacturers tab.
        expect(find.text('Add New'), findsNothing);
        await disposeScreen(tester);
      },
    );

    testWidgets('says so when no manufacturer has bottles', (tester) async {
      await addProduct(await addManufacturer('Can Co'), unit: 'Can');
      await openTab(tester, 'Empty Crates');

      expect(crateCard('Can Co'), findsNothing);
      expect(find.text('No bottle manufacturers yet'), findsOneWidget);
      await disposeScreen(tester);
    });
  });

  group('Manufacturers tab', () {
    testWidgets('sits right after Empty Crates', (tester) async {
      await openTab(tester, 'Manufacturers');
      final labels = [
        for (final tab in tester.widgetList<Tab>(find.byType(Tab))) tab.text,
      ];
      expect(
        labels.indexOf('Manufacturers'),
        labels.indexOf('Empty Crates') + 1,
      );
      await disposeScreen(tester);
    });

    testWidgets('lists every manufacturer, bottle or not, and opens one', (
      tester,
    ) async {
      await seedRoster();
      await openTab(tester, 'Manufacturers');

      for (final name in ids.keys) {
        expect(
          await isListed(tester, manufacturerRow(name)),
          isTrue,
          reason: '$name must be listed',
        );
      }
      expect(
        find.descendant(
          of: manufacturerRow('Can Co'),
          matching: find.text('No returnable bottles'),
        ),
        findsOneWidget,
      );

      await tester.scrollUntilVisible(
        manufacturerRow('Can Co'),
        -200,
        scrollable: tabScrollable(),
      );
      await Scrollable.ensureVisible(
        tester.element(manufacturerRow('Can Co')),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(manufacturerRow('Can Co'));
      await tester.pumpAndSettle();

      expect(find.byType(ManufacturerScreen), findsOneWidget);
      expect(
        tester
            .widget<ManufacturerScreen>(find.byType(ManufacturerScreen))
            .manufacturer
            .id,
        ids['Can Co'],
      );
      await disposeScreen(tester);
    });
  });

  group('no overflow', () {
    for (final label in ['Empty Crates', 'Manufacturers']) {
      testWidgets('$label at 360dp, text scale 1.3', (tester) async {
        await seedRoster();
        await openTab(
          tester,
          label,
          size: const Size(360, 740),
          textScaler: const TextScaler.linear(1.3),
        );
        expectNoOverflow(tester, reason: '$label overflowed at 360 @1.3');
        await tester.drag(tabScrollable(), const Offset(0, -2000));
        await tester.pumpAndSettle();
        expectNoOverflow(tester, reason: '$label overflowed scrolled');
        await disposeScreen(tester);
      });

      testWidgets('$label at 844x390 with insets (top 24, right 48)', (
        tester,
      ) async {
        const insets = EdgeInsets.only(top: 24, right: 48);
        tester.view.padding = const FakeViewPadding(top: 24, right: 48);
        tester.view.viewPadding = const FakeViewPadding(top: 24, right: 48);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        await seedRoster();
        await openTab(
          tester,
          label,
          size: const Size(844, 390),
          padding: insets,
        );
        expectNoOverflow(tester, reason: '$label overflowed at 844x390');
        final row = label == 'Manufacturers'
            ? find.byType(SettingsRow)
            : find.byWidgetPredicate(
                (w) =>
                    w.key is ValueKey<String> &&
                    (w.key! as ValueKey<String>).value.startsWith(
                      kManufacturerCardKeyPrefix,
                    ),
              );
        await tester.scrollUntilVisible(
          row.first,
          100,
          scrollable: tabScrollable(),
        );
        expect(row.evaluate(), isNotEmpty, reason: 'a row must be laid out');
        expectNoOverflow(tester, reason: '$label overflowed scrolled');
        await disposeScreen(tester);
      });
    }
  });
}
