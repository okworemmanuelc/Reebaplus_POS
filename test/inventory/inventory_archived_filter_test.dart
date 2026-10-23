// #487 archive groundwork on Inventory: an archived product (`isAvailable ==
// false`) leaves the normal Products list and the figure cards, and an
// "Archived" card — shown only once something is archived — lists just the
// archived products, each still opening Product Details.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/features/inventory/screens/inventory_screen.dart';
import 'package:reebaplus_pos/features/inventory/screens/product_detail_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_parts.dart';

import '../helpers/inventory_seed.dart';
import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late InventorySample sample;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
      businessType: 'Beverage distributor',
    );
    sample = await seedInventorySample(env);
  });

  tearDown(() => env.dispose());

  Future<void> pump(WidgetTester tester) => pumpScreen(
    tester,
    env: env,
    size: const Size(1280, 800),
    padding: kRealisticPhoneInsets,
    screen: const InventoryScreen(),
    grantedKeys: kInventorySampleGrants,
    roleRank: GateTier.ceo,
    roleSlug: 'ceo',
    overrides: [
      firstRunSurfaceStateProvider.overrideWithValue(
        FirstRunSurfaceState.hasContent,
      ),
    ],
  );

  Finder productRow(String name) =>
      find.byKey(inventoryProductRowKey(sample.productIds[name]!));

  const archivedCard = ValueKey('inventory-summary-archived');

  String cardValue(WidgetTester tester, String key) =>
      tester.widget<InventoryFigureCard>(find.byKey(ValueKey(key))).value;

  testWidgets('no Archived card until something is archived', (tester) async {
    await pump(tester);
    expect(find.byKey(archivedCard), findsNothing);
    expect(cardValue(tester, 'inventory-summary-total'), '6');
    await disposeScreen(tester);
  });

  testWidgets('an archived product leaves the list and the figure cards', (
    tester,
  ) async {
    // Gulder is the one Low Stock product (4 on hand).
    await env.db.catalogDao.setProductArchived(
      sample.productIds['Gulder']!,
      true,
    );
    await pump(tester);

    expect(productRow('Gulder'), findsNothing);
    expect(productRow('Coca-Cola'), findsOneWidget);
    expect(cardValue(tester, 'inventory-summary-total'), '5');
    expect(cardValue(tester, 'inventory-summary-low'), '0');
    expect(find.byKey(archivedCard), findsOneWidget);
    expect(cardValue(tester, 'inventory-summary-archived'), '1');

    // Low Stock no longer lists it either.
    await tester.tap(find.byKey(const ValueKey('inventory-summary-low')));
    await tester.pumpAndSettle();
    expect(productRow('Gulder'), findsNothing);
    await disposeScreen(tester);
  });

  testWidgets('the Archived card lists only archived products, and one opens '
      'Product Details', (tester) async {
    await env.db.catalogDao.setProductArchived(
      sample.productIds['Gulder']!,
      true,
    );
    await pump(tester);

    await tester.tap(find.byKey(archivedCard));
    await tester.pumpAndSettle();
    expect(
      tester.widget<InventoryFigureCard>(find.byKey(archivedCard)).selected,
      isTrue,
    );
    expect(productRow('Gulder'), findsOneWidget);
    expect(productRow('Coca-Cola'), findsNothing);
    expect(productRow('Eva Water'), findsNothing);

    await tester.tap(productRow('Gulder'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ProductDetailScreen), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('unarchiving the last one drops the card and the list falls '
      'back to every product', (tester) async {
    final gulder = sample.productIds['Gulder']!;
    await env.db.catalogDao.setProductArchived(gulder, true);
    await pump(tester);
    await tester.tap(find.byKey(archivedCard));
    await tester.pumpAndSettle();

    await tester.runAsync(
      () => env.db.catalogDao.setProductArchived(gulder, false),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(archivedCard), findsNothing);
    expect(cardValue(tester, 'inventory-summary-total'), '6');
    expect(
      tester
          .widget<InventoryFigureCard>(
            find.byKey(const ValueKey('inventory-summary-total')),
          )
          .selected,
      isTrue,
      reason: 'the filter falls back to every product',
    );
    expect(productRow('Coca-Cola'), findsOneWidget);
    await disposeScreen(tester);
  });
}
