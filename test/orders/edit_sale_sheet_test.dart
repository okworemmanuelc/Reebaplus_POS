// #732 (PR A) — widget tests for Edit sale (#713):
//   * the Edit sale button shows only for a CEO / Manager on a Completed sale
//     30 days old or less; a cashier, an older sale and a pending or cancelled
//     order never show it;
//   * the editor's minus / plus / Add item controls build the input the Order
//     Module turns into the right plan (minus lines, plus lines, EditAddedLine).

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/features/orders/screens/orders_screen.dart';
import 'package:reebaplus_pos/features/orders/widgets/edit_sale_sheet.dart';
import 'package:reebaplus_pos/features/orders/widgets/orders_parts.dart';

import '../helpers/screen_harness.dart';
import 'orders_fixture.dart';

const _completedWithCustomer = 'order-completed-4'; // Star Lager 1, Eva Water 1
const _completedWalkIn = 'order-completed-5'; // Hero Lager 2

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 3,
      manufacturerCount: 1,
      businessType: 'Bar',
    );
    await seedOrdersSample(env);
  });
  tearDown(() async => env.dispose());

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await disposeScreen(tester);
  }

  Finder inCard(String orderId, Finder f) =>
      find.descendant(of: find.byKey(orderRowKey(orderId)), matching: f);

  Future<void> pumpAs(
    WidgetTester tester, {
    required String role,
    int tab = 1,
  }) async {
    final cashier = role == 'cashier';
    await pumpScreen(
      tester,
      env: env,
      size: const Size(800, 1280),
      screen: OrdersScreen(initialIndex: tab),
      grantedKeys: cashier ? ordersCashierGrants : ordersCeoGrants,
      roleSlug: role,
      roleName: role,
      roleRank: switch (role) { 'ceo' => 0, 'manager' => 1, _ => 2 },
      overrides: [
        firstRunSurfaceStateProvider.overrideWithValue(
          FirstRunSurfaceState.hasContent,
        ),
      ],
      settle: false,
    );
    await settleOrders(tester);
  }

  group('Edit sale button', () {
    for (final role in ['ceo', 'manager']) {
      testWidgets('$role sees it on every recent Completed sale', (tester) async {
        await pumpAs(tester, role: role);
        for (final id in [_completedWithCustomer, _completedWalkIn]) {
          expect(inCard(id, find.byKey(OrdersKeys.editSale)), findsOneWidget,
              reason: id);
        }
        await finish(tester);
      });
    }

    testWidgets('a cashier never sees it', (tester) async {
      await pumpAs(tester, role: 'cashier');
      expect(find.byKey(orderRowKey(_completedWithCustomer)), findsOneWidget);
      expect(find.byKey(OrdersKeys.editSale), findsNothing);
      await finish(tester);
    });

    testWidgets('hidden on a sale more than 30 days old', (tester) async {
      // Sold 31 days ago, completed today: still listed under Today.
      await (env.db.update(env.db.orders)
            ..where((o) => o.id.equals(_completedWithCustomer)))
          .write(OrdersCompanion(
            createdAt: Value(DateTime.now().subtract(const Duration(days: 31))),
          ));
      await pumpAs(tester, role: 'ceo');
      expect(find.byKey(orderRowKey(_completedWithCustomer)), findsOneWidget);
      expect(inCard(_completedWithCustomer, find.byKey(OrdersKeys.editSale)),
          findsNothing);
      expect(inCard(_completedWalkIn, find.byKey(OrdersKeys.editSale)),
          findsOneWidget);
      await finish(tester);
    });

    testWidgets('a 29-day-old sale still shows it', (tester) async {
      await (env.db.update(env.db.orders)
            ..where((o) => o.id.equals(_completedWithCustomer)))
          .write(OrdersCompanion(
            createdAt: Value(DateTime.now().subtract(const Duration(days: 29))),
          ));
      await pumpAs(tester, role: 'ceo');
      expect(inCard(_completedWithCustomer, find.byKey(OrdersKeys.editSale)),
          findsOneWidget);
      await finish(tester);
    });

    for (final (name, tab) in [('Pending', 0), ('Cancelled', 2)]) {
      testWidgets('never on a $name order', (tester) async {
        await pumpAs(tester, role: 'ceo', tab: tab);
        expect(find.byKey(OrdersKeys.editSale), findsNothing);
        await finish(tester);
      });
    }

    testWidgets('tapping it opens the editor with the sale lines', (tester) async {
      await pumpAs(tester, role: 'ceo');
      await tester.tap(inCard(_completedWithCustomer, find.byKey(OrdersKeys.editSale)));
      await settleOrders(tester);
      expect(find.byKey(EditSaleKeys.editor), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Star Lager'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Eva Water'), findsOneWidget);
      await finish(tester);
    });
  });

  group('Editor', () {
    // Whole units, so one tap is one crate (products default to quarter steps).
    setUp(() async {
      await env.db.update(env.db.products).write(
            const ProductsCompanion(allowFractionalSales: Value(false)),
          );
    });

    Finder stepperIn(String name, IconData icon) => find.descendant(
          of: find.widgetWithText(ListTile, name),
          matching: find.byIcon(icon),
        );

    testWidgets('minus, plus and Add item build the right plan', (tester) async {
      final db = env.db;
      final lines = await (db.select(db.orderItems)
            ..where((i) => i.orderId.equals(_completedWithCustomer)))
          .get();
      final starLine =
          lines.singleWhere((l) => l.productId == env.products[0].id);
      final evaLine = lines.singleWhere((l) => l.productId == env.products[2].id);
      final hero = env.products[1].id;

      EditSaleInput? result;
      await pumpScreen(
        tester,
        env: env,
        size: const Size(390, 844),
        settle: false,
        screen: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                result = await showEditSaleEditor(
                  context,
                  orderNumber: 'ORD-000104-A1B2C3',
                  storeId: env.storeId,
                  priceTier: 'retailer',
                  lines: [
                    EditLineSeed(
                      lineId: starLine.id,
                      name: 'Star Lager',
                      current: 1,
                      unitPriceKobo: starLine.unitPriceKobo,
                      canRaise: true,
                      allowParts: false,
                    ),
                    EditLineSeed(
                      lineId: evaLine.id,
                      name: 'Eva Water',
                      current: 1,
                      unitPriceKobo: evaLine.unitPriceKobo,
                      canRaise: true,
                      allowParts: false,
                    ),
                  ],
                );
              },
              child: const Text('open editor'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open editor'));
      await settleOrders(tester);
      expect(find.byKey(EditSaleKeys.editor), findsOneWidget);

      await tester.tap(stepperIn('Star Lager', AppIcons.removeCircle)); // 1 -> 0
      await tester.pump();
      await tester.tap(stepperIn('Eva Water', AppIcons.addCircle)); // 1 -> 2
      await tester.pump();

      await tester.tap(find.byKey(EditSaleKeys.addItem));
      await settleOrders(tester);
      await tester.tap(find.widgetWithText(ListTile, 'Hero Lager'));
      await settleOrders(tester);
      expect(find.text('Added today'), findsOneWidget);
      await tester.tap(stepperIn('Hero Lager', AppIcons.addCircle)); // 1 -> 2
      await tester.pump();

      await tester.enterText(find.byKey(EditSaleKeys.reason), 'swapped drinks');
      await tester.pump();
      await tester.ensureVisible(find.byKey(EditSaleKeys.continueButton));
      await tester.tap(find.byKey(EditSaleKeys.continueButton));
      await settleOrders(tester);

      final input = result!;
      expect(input.reason, 'swapped drinks');
      expect(input.newQtyByLineId, {starLine.id: 0, evaLine.id: 2});
      expect(input.addedLines.single.productId, hero);
      expect(input.addedLines.single.quantity, 2);

      final plan = (await tester.runAsync(() => db.ordersDao.planEditSale(
            _completedWithCustomer,
            input.newQtyByLineId,
            input.addedLines,
          )))!;
      expect(plan.minus!.qtyByLine, {starLine.id: 1});
      expect(
        plan.plusLines.map((l) => (l.product.id, l.qty)).toList(),
        [(env.products[2].id, 1.0), (hero, 2.0)],
        reason: 'raised Eva Water by 1, added 2 Hero Lager',
      );
      expect(plan.addedKobo, 3 * 100000);
      expect(plan.returnedKobo, 960000);
      expect(plan.netKobo, 300000 - 960000);
      await finish(tester);
    });

    testWidgets('an unchanged editor cannot continue; lowering an added item '
        'to 0 removes it', (tester) async {
      EditSaleInput? result;
      var closed = false;
      await pumpScreen(
        tester,
        env: env,
        size: const Size(390, 844),
        settle: false,
        screen: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                result = await showEditSaleEditor(
                  context,
                  orderNumber: 'ORD-1',
                  storeId: env.storeId,
                  priceTier: 'retailer',
                  lines: const [
                    EditLineSeed(
                      lineId: 'line-1',
                      name: 'Star Lager',
                      current: 2,
                      unitPriceKobo: 100000,
                      canRaise: false,
                      allowParts: false,
                    ),
                  ],
                );
                closed = true;
              },
              child: const Text('open editor'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open editor'));
      await settleOrders(tester);

      await tester.enterText(find.byKey(EditSaleKeys.reason), 'no change');
      await tester.pump();
      await tester.tap(find.byKey(EditSaleKeys.continueButton));
      await settleOrders(tester);
      expect(closed, isFalse, reason: 'nothing changed yet');

      // A line that cannot be raised stops at what stands.
      final plus = tester.widget<IconButton>(find.ancestor(
        of: stepperIn('Star Lager', AppIcons.addCircle),
        matching: find.byType(IconButton),
      ));
      expect(plus.onPressed, isNull);

      await tester.tap(find.byKey(EditSaleKeys.addItem));
      await settleOrders(tester);
      await tester.tap(find.widgetWithText(ListTile, 'Eva Water'));
      await settleOrders(tester);
      await tester.tap(stepperIn('Eva Water', AppIcons.removeCircle)); // 1 -> 0
      await tester.pump();
      expect(find.text('Added today'), findsNothing);

      await tester.tap(stepperIn('Star Lager', AppIcons.removeCircle)); // 2 -> 1
      await tester.pump();
      await tester.tap(find.byKey(EditSaleKeys.continueButton));
      await settleOrders(tester);
      expect(closed, isTrue);
      expect(result!.newQtyByLineId, {'line-1': 1});
      expect(result!.addedLines, isEmpty);
      await finish(tester);
    });
  });
}
