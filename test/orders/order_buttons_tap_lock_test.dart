// #659: the Orders Refund button locks on the first tap and spins until the
// whole refund (dialog, then save) ends. Two quick taps on Issue Refund write
// once.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/orders/screens/orders_screen.dart';
import 'package:reebaplus_pos/features/orders/widgets/orders_parts.dart';
import 'package:reebaplus_pos/features/orders/widgets/refund_destination_dialog.dart';
import 'package:reebaplus_pos/shared/services/orders/order_service.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

import '../helpers/screen_harness.dart';
import 'orders_fixture.dart';

class _SlowRefund extends OrderService {
  _SlowRefund(super.db);

  int refunds = 0;
  final gate = Completer<void>();

  // The seeded order has no payment rows; pretend money was paid so the
  // destination pop-up (#710) shows.
  @override
  Future<int> refundablePaidKobo(String orderId) async => 100000;

  @override
  Future<void> markAsCancelled(
    String orderId,
    String reason,
    String staffId, {
    required GateContext gateContext,
    RefundDestination destination = RefundDestination.cashOrTransfer,
    String? refundMethod,
  }) {
    refunds++;
    return gate.future;
  }
}

void main() {
  late ScreenTestEnvironment env;
  late _SlowRefund service;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 3,
      manufacturerCount: 1,
      businessType: 'Bar',
    );
    await seedOrdersSample(env);
    service = _SlowRefund(env.db);
  });
  tearDown(() async => env.dispose());

  testWidgets('Refund spins through the save and writes once', (tester) async {
    await pumpScreen(
      tester,
      env: env,
      size: const Size(390, 844),
      screen: const OrdersScreen(),
      settle: false,
      grantedKeys: ordersCeoGrants,
      roleSlug: 'ceo',
      roleName: 'CEO',
      roleRank: 0,
      overrides: [orderServiceProvider.overrideWithValue(service)],
    );
    try {
      await settleOrders(tester);
      final refund = find.byKey(OrdersKeys.refund).first;
      await Scrollable.ensureVisible(tester.element(refund));
      await tester.tap(refund);
      await settleOrders(tester);
      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('orders-refund-reason')),
          matching: find.byType(TextField),
        ),
        'Changed mind',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(AppButton, 'Issue Refund'));
      await settleOrders(tester);
      // #710 — a paid order asks where the money goes.
      await tester.tap(find.byKey(RefundDestinationKeys.cash));
      await tester.pump();
      await tester.tap(find.byKey(RefundDestinationKeys.confirm));
      await settleOrders(tester);
      expect(service.refunds, 1);

      // The card's Refund button spins while the save is running, and a
      // second tap on it does nothing.
      expect(
        find.descendant(
          of: find.byKey(OrdersKeys.refund).first,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      await Scrollable.ensureVisible(
        tester.element(find.byKey(OrdersKeys.refund).first),
      );
      await tester.tap(find.byKey(OrdersKeys.refund).first);
      await tester.pump();
      expect(find.byKey(const Key('orders-refund-reason')), findsNothing);

      service.gate.complete();
      await settleOrders(tester);
      expect(service.refunds, 1);
    } finally {
      AppNotification.hide();
      await disposeScreen(tester);
    }
  });
}
