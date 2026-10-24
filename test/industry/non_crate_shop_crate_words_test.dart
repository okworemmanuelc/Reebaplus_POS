import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/orders/screens/orders_screen.dart';
import 'package:reebaplus_pos/features/sync/screens/sync_issues_screen.dart';
import 'package:reebaplus_pos/shared/models/notification.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/services/cart_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/notifications_modal.dart';

import '../helpers/screen_harness.dart';
import '../orders/orders_fixture.dart';
import '../sync/sync_issues_fixture.dart';

class _FakeAuth extends ChangeNotifier implements AuthService {
  @override
  UserData? get currentUser => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeNav implements NavigationService {
  @override
  final ValueNotifier<String?> lockedStoreId = ValueNotifier<String?>(null);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// G2 (#492) — Ensure non-crate businesses (e.g. Pharmacy) see no crate words:
///   1. cart_service: default unit "Bottle" is gone; no unit when none is set.
///   2. Orders "Crate Deposits" stat is gated on businessTracksCrates(business).
///   3. Sync Issues rejected sale confirmation wording is gated on tracksCrates.
///   4. Notifications modal rejected sale wording is gated on tracksCrates.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => WidgetsApp.debugAllowBannerOverride = false);
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  group('CartService default unit', () {
    test(
      'adding a product Map with no unit results in null unit, never Bottle',
      () {
        final cart = CartService(_FakeAuth(), _FakeNav());

        final added = cart.addItem({
          'id': 'med-1',
          'name': 'Paracetamol 500mg',
          'price': 250.0,
        });
        expect(added, isTrue);
        expect(cart.value, hasLength(1));
        expect(cart.value.first['unit'], isNull);

        final addedWithUnit = cart.addItem({
          'id': 'med-2',
          'name': 'Bandages',
          'price': 500.0,
          'unit': 'Pack',
        });
        expect(addedWithUnit, isTrue);
        expect(cart.value, hasLength(2));
        expect(cart.value[1]['unit'], equals('Pack'));

        cart.dispose();
      },
    );
  });

  group('Pharmacy (non-crate) shop', () {
    late ScreenTestEnvironment env;

    setUp(() async {
      env = await setupScreenTestEnvironment(
        productCount: 3,
        manufacturerCount: 1,
        businessType: 'Pharmacy',
      );
      await seedOrdersSample(env);
      await seedSyncSample(env);
    });

    tearDown(() async => env.dispose());

    testWidgets('Orders Completed tab hides Crate Deposits stat card', (
      tester,
    ) async {
      await pumpOrders(
        tester,
        env: env,
        screen: const OrdersScreen(initialIndex: 1),
      );

      expect(find.text('Revenue'), findsOneWidget);
      expect(find.text('Collected'), findsOneWidget);
      expect(find.text('Crate Deposits'), findsNothing);

      await tester.pump(const Duration(seconds: 5));
      await disposeScreen(tester);
    });

    testWidgets('Sync Issues rejected sale dialog uses neutral wording', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        env: env,
        size: const Size(390, 4000),
        screen: const SyncIssuesScreen(),
        grantedKeys: const {'sync.view'},
        settle: false,
      );
      await settle(tester);

      await tester.tap(find.text('Cancel this sale'));
      await tester.pumpAndSettle();

      expect(find.text('Cancel this rejected sale?'), findsOneWidget);
      expect(
        find.textContaining('the stock goes back to what it was before it'),
        findsOneWidget,
      );
      expect(find.textContaining('customer empties'), findsNothing);

      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await disposeScreen(tester);
    });

    testWidgets('Notifications modal rejected sale uses neutral wording', (
      tester,
    ) async {
      final notif = NotificationModel(
        id: 'notif-1',
        type: 'sale_rejected',
        message: 'A sale was rejected during sync.',
        severity: 'alert',
        linkedRecordId: 'ord-202',
        timestamp: DateTime(2026, 10, 24, 12, 0),
      );

      await pumpScreen(
        tester,
        env: env,
        size: const Size(390, 844),
        screen: Scaffold(body: NotificationCard(notification: notif)),
        settle: false,
      );
      await settle(tester);

      await tester.tap(find.byType(NotificationCard));
      await tester.pumpAndSettle();

      expect(find.text('Sale could not be completed'), findsOneWidget);
      expect(
        find.textContaining(
          'the stock goes back to what it was before the sale.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('customer empties'), findsNothing);

      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await disposeScreen(tester);
    });
  });

  group('Bar (crate) shop', () {
    late ScreenTestEnvironment env;

    setUp(() async {
      env = await setupScreenTestEnvironment(
        productCount: 3,
        manufacturerCount: 1,
        businessType: 'Bar',
      );
      await seedOrdersSample(env);
      await seedSyncSample(env);
    });

    tearDown(() async => env.dispose());

    testWidgets('Orders Completed tab shows Crate Deposits stat card', (
      tester,
    ) async {
      await pumpOrders(
        tester,
        env: env,
        screen: const OrdersScreen(initialIndex: 1),
      );

      expect(find.text('Revenue'), findsOneWidget);
      expect(find.text('Collected'), findsOneWidget);
      expect(find.text('Crate Deposits'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      await disposeScreen(tester);
    });

    testWidgets('Sync Issues rejected sale dialog mentions empties balance', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        env: env,
        size: const Size(390, 4000),
        screen: const SyncIssuesScreen(),
        grantedKeys: const {'sync.view'},
        settle: false,
      );
      await settle(tester);

      await tester.tap(find.text('Cancel this sale'));
      await tester.pumpAndSettle();

      expect(find.text('Cancel this rejected sale?'), findsOneWidget);
      expect(
        find.textContaining(
          'the stock and any customer empties balance go back to what they were before it',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await disposeScreen(tester);
    });

    testWidgets('Notifications modal rejected sale mentions empties balance', (
      tester,
    ) async {
      final notif = NotificationModel(
        id: 'notif-1',
        type: 'sale_rejected',
        message: 'A sale was rejected during sync.',
        severity: 'alert',
        linkedRecordId: 'ord-202',
        timestamp: DateTime(2026, 10, 24, 12, 0),
      );

      await pumpScreen(
        tester,
        env: env,
        size: const Size(390, 844),
        screen: Scaffold(body: NotificationCard(notification: notif)),
        settle: false,
      );
      await settle(tester);

      await tester.tap(find.byType(NotificationCard));
      await tester.pumpAndSettle();

      expect(find.text('Sale could not be completed'), findsOneWidget);
      expect(
        find.textContaining(
          'the stock and any customer empties balance go back to what they were before the sale.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await disposeScreen(tester);
    });
  });
}
