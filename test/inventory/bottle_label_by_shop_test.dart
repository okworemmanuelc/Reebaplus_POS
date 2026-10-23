// #487 PR 1 fix: the "Bottle Crate" wording belongs ONLY to shops that count
// empty crates (`businessTracksCrates`: a crate business type AND
// `tracks_empty_crates`). A pharmacy, a supermarket, or a bar that switched
// crate counting off sells a "Bottle" of something and must read "Bottle":
// on the Inventory row and on the receipt. Sample data only.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/features/inventory/screens/inventory_screen.dart';
import 'package:reebaplus_pos/features/inventory/widgets/inventory_parts.dart';
import 'package:reebaplus_pos/features/orders/screens/orders_screen.dart';
import 'package:reebaplus_pos/features/orders/widgets/orders_parts.dart';

import '../helpers/inventory_seed.dart';
import '../helpers/screen_harness.dart';
import '../orders/orders_fixture.dart';

/// The shops under test: what each one is, and whether a Bottle reads
/// "Bottle Crate" there.
const _shops = <({String label, String type, bool tracksCrates, bool crate})>[
  (label: 'Pharmacy', type: 'Pharmacy', tracksCrates: true, crate: false),
  (label: 'Supermarket', type: 'Supermarket', tracksCrates: true, crate: false),
  (
    label: 'Bar that does not count crates',
    type: 'Bar',
    tracksCrates: false,
    crate: false,
  ),
  (
    label: 'Beverage distributor that counts crates',
    type: 'Beverage distributor',
    tracksCrates: true,
    crate: true,
  ),
];

Future<void> _setTracksCrates(ScreenTestEnvironment env, bool on) =>
    (env.db.update(env.db.businesses)
          ..where((t) => t.id.equals(env.businessId)))
        .write(BusinessesCompanion(tracksEmptyCrates: Value(on)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final shop in _shops) {
    final expected = shop.crate ? 'Bottle Crate' : 'Bottle';

    group('${shop.label}: a Bottle reads "$expected" on the Inventory row', () {
      late ScreenTestEnvironment env;

      setUp(() async {
        env = await setupScreenTestEnvironment(
          productCount: 0,
          businessName: 'Sample Shop',
          businessType: shop.type,
        );
        await _setTracksCrates(env, shop.tracksCrates);
        await seedInventorySample(env);
      });
      tearDown(() => env.dispose());

      testWidgets('every Bottle row', (tester) async {
        await pumpScreen(
          tester,
          env: env,
          // Tall enough that every sample product row is built.
          size: const Size(1280, 2000),
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

        // Star Lager, Gulder and Guinness Foreign Extra are saved as Bottle.
        final bottleRows = tester
            .widgetList<InventoryProductRow>(find.byType(InventoryProductRow))
            .where((r) => r.unit == 'Bottle' || r.unit == 'Bottle Crate')
            .toList();
        expect(bottleRows, hasLength(3));
        for (final row in bottleRows) {
          expect(row.unit, expected);
          expect(row.name, startsWith('$expected '));
        }
        expect(bottleRows.map((r) => r.name), contains('$expected Star Lager'));
        if (!shop.crate) {
          expect(find.textContaining('Bottle Crate'), findsNothing);
        }
        await disposeScreen(tester);
      });
    });

    group('${shop.label}: a Bottle reads "$expected" on the receipt', () {
      late ScreenTestEnvironment env;

      setUp(() async {
        env = await setupScreenTestEnvironment(
          productCount: 3,
          manufacturerCount: 1,
          businessType: shop.type,
        );
        await seedOrdersSample(env);
        await _setTracksCrates(env, shop.tracksCrates);
      });
      tearDown(() => env.dispose());

      testWidgets('a completed order\'s receipt', (tester) async {
        await pumpOrders(
          tester,
          env: env,
          screen: const OrdersScreen(initialIndex: 1),
        );
        // A completed order: 1 × Star Lager (a Bottle) + 1 × Eva Water.
        await tester.tap(find.text('Order #ORD-000104-A1B2C3'));
        await settleOrders(tester);

        final sheet = find.byKey(OrdersKeys.receiptSheet);
        expect(sheet, findsOneWidget);
        expect(
          find.descendant(
            of: sheet,
            matching: find.text('$expected Star Lager  ×1.0'),
          ),
          findsOneWidget,
        );
        if (!shop.crate) {
          expect(
            find.descendant(
              of: sheet,
              matching: find.textContaining('Bottle Crate'),
            ),
            findsNothing,
          );
        }
        await tester.pump(const Duration(seconds: 5));
        await disposeScreen(tester);
      });
    });
  }
}
