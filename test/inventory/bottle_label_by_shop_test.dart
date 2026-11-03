// #675 (supersedes the #487 "Bottle Crate" wording): every shop — a pharmacy,
// a supermarket, a bar that switched crate counting off, and a drinks
// distributor that counts crates — reads a stored Bottle as "Bottle" on the
// Inventory row's unit label. The unit is never put in front of the
// product name, on the row or on the receipt. Sample data only.

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

/// The shops under test: what each one is, and whether it counts crates.
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
    const expected = 'Bottle';

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
            .where((r) => r.unit == 'Bottle')
            .toList();
        expect(bottleRows, hasLength(3));
        for (final row in bottleRows) {
          // The unit shows in its own label, never in front of the name.
          expect(row.unit, expected);
          expect(row.name, isNot(startsWith('Bottle')));
        }
        expect(bottleRows.map((r) => r.name), contains('Star Lager'));
        expect(find.textContaining('Bottle Crate'), findsNothing);
        await disposeScreen(tester);
      });
    });

    group('${shop.label}: the receipt shows just the product name', () {
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
            matching: find.text('Star Lager'),
          ),
          findsOneWidget,
        );
        // The receipt line is the product name alone — no unit word.
        expect(
          find.descendant(of: sheet, matching: find.textContaining('Bottle')),
          findsNothing,
        );
        await tester.pump(const Duration(seconds: 5));
        await disposeScreen(tester);
      });
    });
  }
}
