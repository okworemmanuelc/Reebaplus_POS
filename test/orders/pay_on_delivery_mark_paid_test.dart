// #432 on the Orders screen: a Pay on delivery order is labelled "Pay on
// delivery · ₦X to collect" (never "credit"); Mark as paid is hidden without
// orders.pay_on_delivery.mark_paid (hide-don't-block) and re-checked at save.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/online_orders/pay_on_delivery.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/features/orders/screens/orders_screen.dart';
import 'package:reebaplus_pos/features/orders/widgets/mark_paid_dialog.dart';
import 'package:reebaplus_pos/features/orders/widgets/orders_parts.dart';

import '../helpers/screen_harness.dart';
import 'orders_fixture.dart';

const _markPaid = 'orders.pay_on_delivery.mark_paid';
// The fixture's pending credit sale: Hero Lager ×3 at ₦8,400 = ₦25,200.
const _creditOrderId = 'order-pending-3';

void main() {
  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 3,
      manufacturerCount: 1,
      businessType: 'Bar',
    );
    await seedOrdersSample(env);
    await env.db.into(env.db.onlineOrders).insert(
      OnlineOrdersCompanion.insert(
        id: 'online-pod-1',
        businessId: env.businessId,
        storeId: env.storeId,
        customerId: const Value(kOrdersOtherCustomerId),
        status: const Value('fulfilled'),
        reference: 'ON-POD00001',
        shopperName: 'Ngozi',
        deliveryPhone: '08030000000',
        deliveryState: 'Lagos',
        deliveryLga: 'Ikeja',
        deliveryStreet: '1 Road',
        linkedOrderId: const Value(_creditOrderId),
      ),
    );
  });
  tearDown(() async => env.dispose());

  Future<void> pump(WidgetTester tester, Set<String> keys) async {
    await pumpScreen(
      tester,
      env: env,
      size: const Size(390, 2400),
      padding: const EdgeInsets.only(top: 24, bottom: 48),
      screen: const OrdersScreen(),
      theme: AppTheme.light(),
      grantedKeys: keys,
      roleSlug: 'ceo',
      roleName: 'CEO',
      roleRank: 0,
      overrides: [
        firstRunSurfaceStateProvider.overrideWithValue(
          FirstRunSurfaceState.hasContent,
        ),
        creditBalancesKoboProvider.overrideWith(
          (ref) => Stream.value({kOrdersOtherCustomerId: -2520000}),
        ),
      ],
      settle: false,
    );
    await settleOrders(tester);
  }

  testWidgets('labelled Pay on delivery with what to collect, never credit',
      (tester) async {
    await pump(tester, ordersCeoGrants);
    expect(find.byKey(OrdersKeys.payOnDeliveryPill), findsOneWidget);
    expect(find.text('Pay on delivery'), findsOneWidget);
    final label = find.byKey(OrdersKeys.payOnDeliveryLabel);
    await tester.ensureVisible(label);
    expect(
      tester.widget<Text>(label).data,
      'Pay on delivery · ${formatCurrency(25200)} to collect',
    );
    // The fixture's only credit sale is this order: no "Credit" badge left.
    expect(find.text('Credit'), findsNothing);
    await disposeScreen(tester);
  });

  testWidgets('Mark as paid is hidden without the permission',
      (tester) async {
    await pump(tester, ordersCeoGrants);
    expect(find.byKey(MarkPaidKeys.button), findsNothing);
    await disposeScreen(tester);
  });

  testWidgets('Mark as paid shows with the permission', (tester) async {
    await pump(tester, {...ordersCeoGrants, _markPaid});
    final button = find.byKey(MarkPaidKeys.button);
    await tester.ensureVisible(button);
    expect(button, findsOneWidget);
    await tester.tap(button);
    await settleOrders(tester);
    expect(find.byKey(MarkPaidKeys.dialog), findsOneWidget);
    expect(
      tester.widget<AlertDialog>(find.byKey(MarkPaidKeys.dialog)).scrollable,
      isTrue,
    );
    expect(find.byKey(MarkPaidKeys.cash), findsOneWidget);
    expect(find.byKey(MarkPaidKeys.transfer), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settleOrders(tester);
    await disposeScreen(tester);
  });

  testWidgets('a permission revoked while the dialog is open is refused at '
      'save', (tester) async {
    final grants = StateProvider<Set<String>>((_) => {_markPaid});
    late WidgetRef capturedRef;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gateContextProvider.overrideWith(
            (ref) => GateContext(
              grantedKeys: ref.watch(grants),
              roleRank: 1,
              isReady: true,
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                capturedRef = ref;
                return TextButton(
                  onPressed: () => markPayOnDeliveryPaid(
                    context,
                    ref,
                    const PayOnDeliveryOrder(
                      orderId: _creditOrderId,
                      onlineOrderId: 'online-pod-1',
                      storeId: null,
                      customerId: kOrdersOtherCustomerId,
                      status: 'pending',
                      dueKobo: 2520000,
                      collectedKobo: 0,
                    ),
                  ),
                  child: const Text('open'),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(MarkPaidKeys.dialog), findsOneWidget);

    capturedRef.read(grants.notifier).state = const {};
    await tester.tap(find.byKey(MarkPaidKeys.confirm));
    await tester.pump();
    expect(
      find.text('You no longer have access to Mark pay-on-delivery orders '
          'paid.'),
      findsOneWidget,
    );
    final credits = await (env.db.select(env.db.walletTransactions)
          ..where((t) => t.orderId.equals(_creditOrderId)))
        .get();
    expect(credits, isEmpty, reason: 'nothing was posted');
    await tester.pump(const Duration(seconds: 5));
  });
}
