import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/inventory/screens/inventory_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/add_manufacturer_sheet.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

/// Issue #292: Add Manufacturer asks only name + crate value, only CEO and
/// Manager see it, and the Crate Size Group Assets tiles leave the Crates tab.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const baseGrants = {'sales.make', 'stock.view'};
  const ownerGrants = {...baseGrants, 'products.add', 'products.edit_price'};

  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 1,
      businessType: 'Beverage distributor',
    );
    // The save logs activity against the signed-in 'test-user-id' (FK).
    await env.db.into(env.db.users).insert(
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

  Future<void> openCratesTab(
    WidgetTester tester, {
    Size size = pixel7Portrait,
    Set<String> grantedKeys = ownerGrants,
    String roleSlug = 'ceo',
    String roleName = 'CEO',
    int roleRank = GateTier.ceo,
  }) async {
    await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: const InventoryScreen(),
      grantedKeys: grantedKeys,
      roleSlug: roleSlug,
      roleName: roleName,
      roleRank: roleRank,
      overrides: [
        firstRunSurfaceStateProvider
            .overrideWithValue(FirstRunSurfaceState.hasContent),
      ],
    );
    await tester.tap(find.text('Empty Crates').first);
    await tester.pumpAndSettle();
    // Guards the "doesn't see" cases against passing on the wrong tab.
    expect(find.text('Empty In Stock'), findsOneWidget);
  }

  Finder addNewButton() => find.widgetWithText(AppButton, 'Add New');

  Future<void> openSheet(WidgetTester tester) async {
    // On a short viewport the header row is below the fold and not yet built.
    await tester.scrollUntilVisible(
      addNewButton(),
      100,
      scrollable: find.byType(Scrollable).hitTestable().first,
    );
    // Centre it so the pinned tab bar doesn't cover it.
    await Scrollable.ensureVisible(
      tester.element(addNewButton()),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(addNewButton());
    await tester.pumpAndSettle();
    expect(find.byType(AddManufacturerSheet), findsOneWidget);
  }

  Finder sheetField(String label) => find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is AppInput && w.labelText == label,
        ),
        matching: find.byType(TextField),
      );

  Finder sheetSaveButton() => find.descendant(
        of: find.byType(AddManufacturerSheet),
        matching: find.widgetWithText(AppButton, 'Add Manufacturer'),
      );

  Future<List<ManufacturerData>> manufacturers() =>
      env.db.select(env.db.manufacturers).get();

  group('Add Manufacturer visibility', () {
    const roles = [
      (
        slug: 'ceo',
        name: 'CEO',
        rank: GateTier.ceo,
        grants: ownerGrants,
        sees: true,
      ),
      (
        slug: 'manager',
        name: 'Manager',
        rank: GateTier.manager,
        grants: ownerGrants,
        sees: true,
      ),
      (
        slug: 'cashier',
        name: 'Cashier',
        rank: GateTier.cashier,
        grants: baseGrants,
        sees: false,
      ),
      (
        slug: 'stock_keeper',
        name: 'Stock keeper',
        rank: GateTier.stockKeeper,
        grants: {...baseGrants, 'stock.add'},
        sees: false,
      ),
      // A custom grant of the key alone doesn't reach below Manager.
      (
        slug: 'cashier',
        name: 'Cashier granted Edit product',
        rank: GateTier.cashier,
        grants: ownerGrants,
        sees: false,
      ),
    ];
    for (final role in roles) {
      testWidgets(
          '${role.name} ${role.sees ? 'sees' : 'does not see'} Add Manufacturer',
          (tester) async {
        await openCratesTab(
          tester,
          grantedKeys: role.grants,
          roleSlug: role.slug,
          roleName: role.name,
          roleRank: role.rank,
        );
        expect(addNewButton(), role.sees ? findsOneWidget : findsNothing);
        await disposeScreen(tester);
      });
    }
  });

  group('Add Manufacturer sheet', () {
    testWidgets('asks for name and crate value only, and saves them',
        (tester) async {
      await openCratesTab(tester);
      await openSheet(tester);

      final fields = find.descendant(
        of: find.byType(AddManufacturerSheet),
        matching: find.byType(TextField),
      );
      expect(fields, findsNWidgets(2));
      expect(sheetField('Name'), findsOneWidget);
      expect(sheetField('Crate value (₦)'), findsOneWidget);
      expect(find.textContaining('Initial Empty'), findsNothing);

      await tester.enterText(sheetField('Name'), '  Guinness Nigeria  ');
      await tester.enterText(sheetField('Crate value (₦)'), '1500');
      await tester.tap(sheetSaveButton());
      await tester.pumpAndSettle();

      expect(find.byType(AddManufacturerSheet), findsNothing);
      final rows = await manufacturers();
      expect(rows, hasLength(1));
      expect(rows.single.name, 'Guinness Nigeria');
      expect(rows.single.depositAmountKobo, 150000);
      expect(rows.single.emptyCrateStock, 0);
      await disposeScreen(tester);
    });

    testWidgets('an empty name is rejected and nothing is written',
        (tester) async {
      await openCratesTab(tester);
      await openSheet(tester);

      await tester.enterText(sheetField('Name'), '   ');
      await tester.enterText(sheetField('Crate value (₦)'), '1500');
      await tester.tap(sheetSaveButton());
      await tester.pumpAndSettle();

      expect(find.text('Enter the manufacturer name'), findsOneWidget);
      expect(find.byType(AddManufacturerSheet), findsOneWidget);
      expect(await manufacturers(), isEmpty);
      await disposeScreen(tester);
    });

    testWidgets('a name already in use is rejected and nothing is written',
        (tester) async {
      await env.db.inventoryDao.insertManufacturer(
        ManufacturersCompanion.insert(
          name: 'Guinness Nigeria',
          businessId: env.businessId,
        ),
      );
      await openCratesTab(tester);
      await openSheet(tester);

      await tester.enterText(sheetField('Name'), 'guinness nigeria');
      await tester.tap(sheetSaveButton());
      await tester.pumpAndSettle();

      expect(
        find.text('A manufacturer with this name already exists'),
        findsOneWidget,
      );
      expect(await manufacturers(), hasLength(1));
      await disposeScreen(tester);
    });

    testWidgets(
        'a failed activity log still keeps the manufacturer and closes the '
        'sheet', (tester) async {
      await openCratesTab(tester);
      await openSheet(tester);
      // No staff row → the activity log insert fails its foreign key.
      await env.db.delete(env.db.users).go();

      await tester.enterText(sheetField('Name'), 'Guinness Nigeria');
      await tester.tap(sheetSaveButton());
      await tester.pumpAndSettle();

      expect(await manufacturers(), hasLength(1));
      expect(find.byType(AddManufacturerSheet), findsNothing);
      expect(
        find.text(
          'Manufacturer added, but the activity log could not be saved.',
        ),
        findsOneWidget,
      );
      expect(find.text('Could not add manufacturer. Please try again.'),
          findsNothing);
      // Let the error banner's auto-hide timer run out.
      await tester.pump(const Duration(seconds: 5));
      await disposeScreen(tester);
    });

    testWidgets('the save re-checks access and writes nothing when denied',
        (tester) async {
      // Opened directly: a Cashier holding the key alone fails the gate.
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        grantedKeys: ownerGrants,
        roleSlug: 'cashier',
        roleName: 'Cashier',
        roleRank: GateTier.cashier,
        screen: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  AddManufacturerSheet.show(context, existingNames: const []),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(sheetField('Name'), 'Guinness Nigeria');
      await tester.tap(sheetSaveButton());
      await tester.pumpAndSettle();

      expect(
        find.text('You no longer have access to Add Manufacturer.'),
        findsOneWidget,
      );
      expect(await manufacturers(), isEmpty);
      // Let the error banner's auto-hide timer run out.
      await tester.pump(const Duration(seconds: 5));
      await disposeScreen(tester);
    });

    for (final size in [phoneSe1Portrait, androidCompactLandscape]) {
      testWidgets(
          'scrolls and clears the device bottom padding at '
          '${size.width.toInt()}x${size.height.toInt()}', (tester) async {
        await openCratesTab(tester, size: size);
        await openSheet(tester);

        final scroll = find.descendant(
          of: find.byType(AddManufacturerSheet),
          matching: find.byType(SingleChildScrollView),
        );
        expect(scroll, findsOneWidget);
        final padding =
            tester.widget<SingleChildScrollView>(scroll).padding! as EdgeInsets;
        final sheetContext = tester.element(find.byType(AddManufacturerSheet));
        expect(padding.bottom, 24 + sheetContext.deviceBottomPadding);

        // The save button can be scrolled into view and used.
        await tester.enterText(sheetField('Name'), 'Guinness Nigeria');
        await tester.ensureVisible(sheetSaveButton());
        await tester.pumpAndSettle();
        await tester.tap(sheetSaveButton());
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(await manufacturers(), hasLength(1));
        await disposeScreen(tester);
      });
    }
  });

  group('Crates tab', () {
    testWidgets(
        'no longer shows Crate Size Group Assets, leaves its rows untouched, '
        'and keeps the stats row', (tester) async {
      const groupId = 'crate-group-1';
      await env.db.into(env.db.crateSizeGroups).insert(
            CrateSizeGroupsCompanion.insert(
              id: const Value(groupId),
              businessId: env.businessId,
              name: 'Big Crate',
              emptyCrateStock: const Value(20),
            ),
          );
      final before = await (env.db.select(env.db.crateSizeGroups)
            ..where((t) => t.id.equals(groupId)))
          .getSingle();

      await openCratesTab(tester);

      expect(find.text('Crate Size Group Assets'), findsNothing);
      expect(find.text('Big Crate'), findsNothing);
      expect(find.text('Empty In Stock'), findsOneWidget);
      expect(find.text('Full (Crate)'), findsOneWidget);

      final after = await (env.db.select(env.db.crateSizeGroups)
            ..where((t) => t.id.equals(groupId)))
          .getSingle();
      expect(after, before);
      await disposeScreen(tester);
    });
  });
}
