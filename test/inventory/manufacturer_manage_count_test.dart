import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/features/inventory/screens/inventory_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

/// #290 — the Manage sheet's count belongs to a store and a person. It passes
/// the active store and the signed-in user to the Crate Pool seam, asks for a
/// store only in All Stores on a multi-store business, and writes nothing when
/// the count is rejected or left alone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const grants = {'sales.make', 'stock.view', 'products.add', 'stock.add'};
  const userId = 'test-user-id';

  late ScreenTestEnvironment env;
  late BusinessData business;
  late StoreData secondStore;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      manufacturerCount: 1,
      businessType: 'Bar',
    );
    await env.db.into(env.db.users).insert(
          UsersCompanion.insert(
            id: const Value(userId),
            businessId: env.businessId,
            name: 'Test Admin',
            pin: '1234',
          ),
        );
    final storeId = UuidV7.generate();
    await env.db.into(env.db.stores).insert(
          StoresCompanion.insert(
            id: Value(storeId),
            businessId: env.businessId,
            name: 'Second Store',
          ),
        );
    secondStore = (await env.db.storesDao.getStore(storeId))!;
    business = await (env.db.select(env.db.businesses)
          ..where((t) => t.id.equals(env.businessId)))
        .getSingle();
  });

  tearDown(() => env.dispose());

  Future<void> openManage(
    WidgetTester tester, {
    List<StoreData>? selectableStores,
    bool allStores = false,
  }) async {
    await pumpScreen(
      tester,
      env: env,
      // A tablet width: at phone width the Crates tab's brand card already
      // overflows on main (a pre-existing defect the #291 card redesign
      // replaces). This file pins the count's behaviour, not that layout.
      size: tabletMiniPortrait,
      screen: const InventoryScreen(),
      grantedKeys: grants,
      selectableStores: selectableStores,
      overrides: [
        firstRunSurfaceStateProvider
            .overrideWithValue(FirstRunSurfaceState.hasContent),
        currentBusinessProvider.overrideWith((ref) => business),
      ],
    );
    if (allStores) {
      NavigationService().clearStoreLock();
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Empty Crates'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manage').first);
    await tester.pumpAndSettle();
  }

  Finder countField() => find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is AppInput && w.labelText == 'Empty Crates In Stock',
        ),
        matching: find.byType(TextField),
      );

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(AppButton, 'Save Changes'));
    await tester.pumpAndSettle();
  }

  /// A read of a store's expected empties needs real async time between
  /// frames before the sheet can show it.
  Future<void> settleDatabase(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<List<CrateLedgerData>> ledger() =>
      env.db.select(env.db.crateLedger).get();

  testWidgets('with a store active, the count is stamped with that store and '
      'the signed-in user, and no store is asked', (tester) async {
    await openManage(tester);
    expect(find.text('Store counted'), findsNothing);

    await tester.enterText(countField(), '7');
    await save(tester);

    final row = (await tester.runAsync(ledger))!.single;
    expect(row.movementType, 'opening_count');
    expect(row.storeId, env.storeId);
    expect(row.performedBy, userId);
    expect(row.quantityDelta, 7);
    await disposeScreen(tester);
  });

  testWidgets('saving without changing the count records no count',
      (tester) async {
    await openManage(tester);
    await save(tester);
    expect(await tester.runAsync(ledger), isEmpty);
    await disposeScreen(tester);
  });

  testWidgets('a blank count is rejected and nothing is written',
      (tester) async {
    await openManage(tester);
    await tester.enterText(countField(), '');
    await save(tester);
    expect(await tester.runAsync(ledger), isEmpty);
    expect(find.widgetWithText(AppButton, 'Save Changes'), findsOneWidget,
        reason: 'the sheet stays open');
    // Let the error toast's timer run out before the tree is torn down.
    await tester.pump(const Duration(seconds: 6));
    await disposeScreen(tester);
  });

  testWidgets('All Stores with one store to pick uses that store without '
      'asking, and compares against THAT store\'s empties', (tester) async {
    // 5 empties at the store this user can pick, 3 at one they can't. The
    // All-Stores card shows the business-wide 8; the count must start from 5.
    final mfrId = env.manufacturers.single.id;
    await tester.runAsync(() async {
      await env.db.cratePoolDao.addEmptiesToPool(mfrId, 5, storeId: env.storeId);
      await env.db.cratePoolDao
          .addEmptiesToPool(mfrId, 3, storeId: secondStore.id);
    });
    await openManage(tester, allStores: true);
    expect(find.text('Store counted'), findsNothing);
    await settleDatabase(tester);
    expect(
      tester.widget<TextField>(countField()).controller?.text,
      '5',
      reason: 'the inferred store\'s own pool, not the business-wide total',
    );

    await tester.enterText(countField(), '4');
    await save(tester);

    final rows = (await tester.runAsync(ledger))!;
    final count = rows.singleWhere((r) => r.movementType == 'opening_count');
    expect(count.storeId, env.storeId);
    expect(count.performedBy, userId);
    expect(count.quantityDelta, -1);
    await disposeScreen(tester);
  });

  testWidgets('All Stores on a multi-store business must pick the store '
      'counted', (tester) async {
    await openManage(
      tester,
      selectableStores: [env.store, secondStore],
      allStores: true,
    );
    expect(find.text('Store counted'), findsOneWidget);

    // Nothing picked, nothing typed: saving records no count.
    await save(tester);
    expect(await tester.runAsync(ledger), isEmpty);

    await disposeScreen(tester);
  });

  testWidgets('picking a store records the count against it', (tester) async {
    await openManage(
      tester,
      selectableStores: [env.store, secondStore],
      allStores: true,
    );
    await tester.tap(find.text('Choose a store'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second Store').last);
    await settleDatabase(tester);
    expect(
      tester.widget<TextField>(countField()).controller?.text,
      '0',
      reason: 'the chosen store\'s expected empties are prefilled',
    );

    await tester.enterText(countField(), '9');
    await save(tester);

    final row = (await tester.runAsync(ledger))!.single;
    expect(row.storeId, secondStore.id);
    expect(row.performedBy, userId);
    expect(row.movementType, 'opening_count');
    expect(row.quantityDelta, 9);
    await disposeScreen(tester);
  });
}
