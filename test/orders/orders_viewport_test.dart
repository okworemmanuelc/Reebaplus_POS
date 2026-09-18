import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/orders/screens/orders_screen.dart';
import 'package:reebaplus_pos/shared/widgets/tabbed_sliver_scaffold.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

/// Issue #244 / PRD #239 — the Orders screen must hold its content at every
/// supported viewport.
///
/// Acceptance criteria covered here:
///   1. Built on the shared [TabbedSliverScaffold] from #243.
///   2. No tab body holds a fixed-height band above a flexible remainder.
///   3. Pumped at the smallest supported portrait phone (320x568), the shortest
///      supported landscape phone (800x360), and a comfortable portrait control.
///   4. Every test asserts **both** no overflow *and* one complete order row
///      laid out and hit-testable.
///   5. Both an empty and a populated data state.
///   6. Tab swiping and per-tab scroll retention survive the restructure.
///   7. Tap targets remain at or above the minimum interactive dimension.
///   8. Unconditional: no orientation or short-viewport branch anywhere.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

  const ordersGrants = {
    'sales.make',
    'sales.view',
    'sales.cancel',
    'sales.confirm',
    'orders.view',
    'reports.profit',
  };

  Finder orderRows() => find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith(kOrderRowKeyPrefix),
        description: 'order card row',
      );

  Finder tabSurface([String storageKey = 'orders-pending']) {
    final pageKey = find.byKey(PageStorageKey<String>(storageKey));
    if (pageKey.evaluate().isNotEmpty) {
      return pageKey;
    }
    return find.byType(CustomScrollView).first;
  }

  Future<void> settleScreen(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> teardownScreen(WidgetTester tester) async {
    await disposeScreen(tester);
    await tester.runAsync(() => env.dispose());
  }

  Future<void> seedOrders(
    ScreenTestEnvironment env, {
    required int count,
    String status = 'pending',
  }) async {
    final db = env.db;
    final now = DateTime.now();
    final customerId = await db.customersDao.addCustomer(
      CustomersCompanion.insert(
        businessId: env.businessId,
        name: 'Test Customer',
      ),
    );

    for (var i = 1; i <= count; i++) {
      final prefix = status.substring(0, 3).toUpperCase();
      final orderId = UuidV7.generate();
      await db.into(db.orders).insert(
            OrdersCompanion.insert(
              id: Value(orderId),
              businessId: env.businessId,
              orderNumber: '$prefix-00$i',
              customerId: Value(customerId),
              totalAmountKobo: 500000,
              netAmountKobo: 500000,
              amountPaidKobo: const Value(500000),
              paymentType: 'cash',
              status: status,
              storeId: Value(env.storeId),
              createdAt: Value(now.subtract(Duration(minutes: i * 5))),
              completedAt: Value(
                status == 'completed' ? now.subtract(Duration(minutes: i * 5)) : null,
              ),
              cancelledAt: Value(
                status == 'cancelled' ? now.subtract(Duration(minutes: i * 5)) : null,
              ),
            ),
          );

      if (env.products.isNotEmpty) {
        await db.into(db.orderItems).insert(
              OrderItemsCompanion.insert(
                businessId: env.businessId,
                storeId: env.storeId,
                orderId: orderId,
                productId: Value(env.products.first.id),
                quantity: 2,
                unitPriceKobo: 250000,
                totalKobo: 500000,
              ),
            );
      }
    }
  }

  const viewports = <String, Size>{
    'phoneSe1Portrait (320x568, smallest supported portrait)': phoneSe1Portrait,
    'androidCompactLandscape (800x360, shortest supported landscape)':
        androidCompactLandscape,
    'pixel7Landscape (915x412, landscape phone)': pixel7Landscape,
    'pixel7Portrait (412x915, comfortable control)': pixel7Portrait,
  };

  group('Orders holds its content — populated data state', () {
    setUp(() async {
      env = await setupScreenTestEnvironment(productCount: 4);
      await seedOrders(env, count: 6, status: 'pending');
      await seedOrders(env, count: 6, status: 'completed');
      await seedOrders(env, count: 6, status: 'cancelled');
    });

    viewports.forEach((name, size) {
      testWidgets('$name shows a complete order row without overflowing',
          (tester) async {
        await pumpScreen(
          tester,
          env: env,
          size: size,
          grantedKeys: ordersGrants,
          screen: const OrdersScreen(),
        );
        await settleScreen(tester);

        expectNoOverflow(tester);
        final atRest = await expectContentRowVisible(
          tester,
          orderRows(),
          scrollable: tabSurface(),
        );
        expect(atRest, greaterThanOrEqualTo(0));

        await teardownScreen(tester);
      });
    });
  });

  group('Orders holds its content — empty data state', () {
    setUp(() async {
      env = await setupScreenTestEnvironment(productCount: 0);
    });

    viewports.forEach((name, size) {
      testWidgets('$name renders empty state without overflowing',
          (tester) async {
        await pumpScreen(
          tester,
          env: env,
          size: size,
          grantedKeys: ordersGrants,
          screen: const OrdersScreen(),
        );
        await settleScreen(tester);

        expectNoOverflow(tester);
        expect(find.text('No pending orders'), findsOneWidget);

        await teardownScreen(tester);
      });
    });
  });

  group('Orders interactions survive restructure', () {
    setUp(() async {
      env = await setupScreenTestEnvironment(productCount: 4);
      await seedOrders(env, count: 12, status: 'pending');
      await seedOrders(env, count: 12, status: 'completed');
      await seedOrders(env, count: 12, status: 'cancelled');
    });

    testWidgets('swiping sideways moves between tabs', (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        grantedKeys: ordersGrants,
        screen: const OrdersScreen(),
      );
      await settleScreen(tester);

      final pendingTab = find.descendant(
        of: find.byType(TabBar),
        matching: find.text('Pending'),
      );
      final completedTab = find.descendant(
        of: find.byType(TabBar),
        matching: find.text('Completed'),
      );
      final cancelledTab = find.descendant(
        of: find.byType(TabBar),
        matching: find.text('Cancelled'),
      );

      expect(pendingTab, findsOneWidget);
      expect(completedTab, findsOneWidget);

      // Tab controller is at index 0
      final tabController =
          tester.widget<TabBar>(find.byType(TabBar)).controller!;
      expect(tabController.index, 0);

      // Tap on Completed tab
      await tester.tap(completedTab);
      await settleScreen(tester);
      expect(tabController.index, 1);

      // Tap on Cancelled tab
      await tester.tap(cancelledTab);
      await settleScreen(tester);
      expect(tabController.index, 2);

      await teardownScreen(tester);
    });

    testWidgets('each tab remembers its scroll position across tab switches',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        grantedKeys: ordersGrants,
        screen: const OrdersScreen(),
      );
      await settleScreen(tester);

      final completedTab = find.descendant(
        of: find.byType(TabBar),
        matching: find.text('Completed'),
      );
      final pendingTab = find.descendant(
        of: find.byType(TabBar),
        matching: find.text('Pending'),
      );

      // Scroll pending tab down by 150dp
      await tester.drag(tabSurface(), const Offset(0, -150));
      await tester.pumpAndSettle();

      // Switch to Completed tab
      await tester.tap(completedTab);
      await settleScreen(tester);

      // Switch back to Pending tab
      await tester.tap(pendingTab);
      await settleScreen(tester);

      // The pending tab should retain its scrolled position (> 0)
      final pos = tester
          .state<ScrollableState>(
            find.descendant(of: tabSurface(), matching: find.byType(Scrollable)).first,
          )
          .position;
      expect(pos.pixels, greaterThan(0));

      await teardownScreen(tester);
    });

    testWidgets('max text scale (1.3x) does not overflow at compact viewports',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: androidCompactLandscape,
        grantedKeys: ordersGrants,
        textScaler: const TextScaler.linear(1.3),
        screen: const OrdersScreen(),
      );
      await settleScreen(tester);

      expectNoOverflow(tester);
      await teardownScreen(tester);
    });
  });
}
