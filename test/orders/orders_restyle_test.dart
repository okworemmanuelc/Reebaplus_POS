// Behaviour and layout tests for the Orders restyle (#393 PR 2): the Orders
// tab, the receipt and crate return sheets, the Refund dialog and Crate Return
// Approval. Every control renders, the main actions still work, permission-
// hidden controls stay hidden, tap targets are 48dp, wide screens cap at 720,
// and nothing overflows at 360dp @1.3, 390×844, 844×390 with insets, 800×1280
// and 1280×800, or with the keyboard up in a form.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/features/settings/screens/settings_screen.dart'
    show kSettingsMaxContentWidth;
import 'package:reebaplus_pos/features/orders/screens/crate_return_approval_screen.dart';
import 'package:reebaplus_pos/features/orders/screens/orders_screen.dart';
import 'package:reebaplus_pos/features/orders/widgets/orders_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

import '../helpers/screen_harness.dart';
import 'orders_fixture.dart';

final _layouts = <String, ({Size size, EdgeInsets padding, TextScaler? scale})>{
  '360x800 @1.3': (
    size: const Size(360, 800),
    padding: const EdgeInsets.only(top: 24, bottom: 48),
    scale: const TextScaler.linear(1.3),
  ),
  '390x844 3-button': (
    size: const Size(390, 844),
    padding: const EdgeInsets.only(top: 24, bottom: 48),
    scale: null,
  ),
  '390x844 gesture': (
    size: const Size(390, 844),
    padding: const EdgeInsets.only(top: 24, bottom: 24),
    scale: null,
  ),
  '844x390 insets': (
    size: const Size(844, 390),
    padding: const EdgeInsets.only(top: 24, right: 48),
    scale: null,
  ),
  '800x1280': (
    size: const Size(800, 1280),
    padding: const EdgeInsets.only(top: 24, bottom: 24),
    scale: null,
  ),
  '1280x800': (
    size: const Size(1280, 800),
    padding: const EdgeInsets.only(top: 24),
    scale: null,
  ),
};

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

  Future<void> centre(WidgetTester tester, Finder f) async {
    if (f.evaluate().isEmpty) {
      // A short screen (keyboard up) may not have built the card yet.
      await tester.scrollUntilVisible(
        f,
        100,
        scrollable: find
            .descendant(
              of: find.byKey(const PageStorageKey<String>('orders-pending')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
    }
    // Scrolled to the top it would sit under the pinned tab bar.
    await Scrollable.ensureVisible(tester.element(f), alignment: 0.5);
    await tester.pump();
  }

  double h(WidgetTester tester, Finder f) => tester.getSize(f).height;

  group('Orders tab', () {
    testWidgets('CEO: top bar, tabs, figures, search and every card control', (
      tester,
    ) async {
      await pumpOrders(tester, env: env, screen: const OrdersScreen());
      expect(find.byKey(OrdersKeys.topBar), findsOneWidget);
      expect(find.text('Orders'), findsOneWidget);
      expect(find.text('Abuja HQ'), findsOneWidget);
      expect(find.byKey(OrdersKeys.tabBar), findsOneWidget);
      expect(find.byKey(OrdersKeys.summary), findsOneWidget);
      expect(find.text('Total Value'), findsOneWidget);
      expect(find.byKey(OrdersKeys.search), findsOneWidget);
      // Pending has no period filter.
      expect(find.byKey(OrdersKeys.period), findsNothing);
      for (final key in [
        OrdersKeys.refund,
        OrdersKeys.confirm,
        OrdersKeys.rider,
      ]) {
        final f = inCard(kPendingCrateOrderId, find.byKey(key));
        expect(f, findsOneWidget, reason: '$key');
        expect(h(tester, f), greaterThanOrEqualTo(48), reason: '$key');
      }
      expect(
        inCard(kPendingCrateOrderId, find.text('Debt: ₦12,500')),
        findsOneWidget,
      );
      expect(
        inCard(kPendingCrateOrderId, find.text('Order #ORD-000101-A1B2C3')),
        findsOneWidget,
      );
      await finish(tester);
    });

    testWidgets('cashier: no Refund, no money, no debt; Confirm stays', (
      tester,
    ) async {
      await pumpOrders(
        tester,
        env: env,
        screen: const OrdersScreen(),
        cashier: true,
      );
      expect(find.byKey(OrdersKeys.refund), findsNothing);
      expect(find.byKey(OrdersKeys.confirm), findsWidgets);
      expect(find.text('Total Value'), findsNothing);
      expect(find.textContaining('Debt:'), findsNothing);
      expect(find.textContaining('Paid:'), findsNothing);
      await finish(tester);
    });

    testWidgets('Completed: period filter, DONE pill; a card opens the receipt '
        'sheet', (tester) async {
      await pumpOrders(
        tester,
        env: env,
        screen: const OrdersScreen(initialIndex: 1),
      );
      expect(find.byKey(OrdersKeys.period), findsOneWidget);
      expect(
        h(tester, find.byKey(OrdersKeys.period)),
        greaterThanOrEqualTo(48),
      );
      expect(find.text('DONE'), findsWidgets);
      expect(find.text('Revenue'), findsOneWidget);
      await tester.tap(find.text('Order #ORD-000104-A1B2C3'));
      await settleOrders(tester);
      expect(find.byKey(OrdersKeys.receiptSheet), findsOneWidget);
      expect(find.widgetWithText(AppButton, 'Print'), findsOneWidget);
      expect(find.widgetWithText(AppButton, 'Share'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('Cancelled: CANCELLED pill and the reason', (tester) async {
      await pumpOrders(
        tester,
        env: env,
        screen: const OrdersScreen(initialIndex: 2),
      );
      expect(find.text('CANCELLED'), findsOneWidget);
      expect(find.text('Customer changed their mind'), findsOneWidget);
      expect(find.text('Refunds Issued'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('search narrows the list; the clear button is 48dp', (
      tester,
    ) async {
      await pumpOrders(tester, env: env, screen: const OrdersScreen());
      await tester.enterText(
        find.descendant(
          of: find.byKey(OrdersKeys.search),
          matching: find.byType(TextField),
        ),
        'ngozi',
      );
      await settleOrders(tester);
      expect(find.text('Ngozi Bello'), findsOneWidget);
      expect(find.text('Chinedu Okafor'), findsNothing);
      final clear = find.byTooltip('Clear search');
      expect(h(tester, clear), greaterThanOrEqualTo(48));
      await tester.tap(clear);
      await settleOrders(tester);
      expect(find.text('Chinedu Okafor'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('Refund asks for a reason before Issue Refund works; Back '
        'closes it', (tester) async {
      await pumpOrders(tester, env: env, screen: const OrdersScreen());
      final refund = inCard(
        kPendingCrateOrderId,
        find.byKey(OrdersKeys.refund),
      );
      await centre(tester, refund);
      await tester.tap(refund);
      await settleOrders(tester);
      expect(find.text('Refund ORD-000101-A1B2C3'), findsOneWidget);
      final issue = find.widgetWithText(AppButton, 'Issue Refund');
      expect(tester.widget<AppButton>(issue).onPressed, isNull);
      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('orders-refund-reason')),
          matching: find.byType(TextField),
        ),
        'Wrong order',
      );
      await tester.pump();
      expect(tester.widget<AppButton>(issue).onPressed, isNotNull);
      await tester.tap(find.widgetWithText(AppButton, 'Back'));
      await settleOrders(tester);
      expect(find.text('Refund ORD-000101-A1B2C3'), findsNothing);
      await finish(tester);
    });

    testWidgets('Confirm opens the crate return sheet: count field, Credit and '
        'Cash (CEO), blank count refused', (tester) async {
      await pumpOrders(tester, env: env, screen: const OrdersScreen());
      final confirm = inCard(
        kPendingCrateOrderId,
        find.byKey(OrdersKeys.confirm),
      );
      await centre(tester, confirm);
      await tester.tap(confirm);
      await settleOrders(tester);
      expect(find.byKey(OrdersKeys.crateReturnSheet), findsOneWidget);
      expect(find.text('Nigerian Breweries'), findsOneWidget);
      expect(find.byKey(OrdersKeys.refundCredit), findsOneWidget);
      expect(find.byKey(OrdersKeys.refundCash), findsOneWidget);
      expect(
        h(tester, find.byKey(OrdersKeys.refundCash)),
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.widgetWithText(AppButton, 'Confirm').last);
      await settleOrders(tester);
      expect(
        find.text(
          'Enter the returned crate count for every manufacturer (0 is allowed).',
        ),
        findsOneWidget,
      );
      expect(find.byKey(OrdersKeys.crateReturnSheet), findsOneWidget);
      await finish(tester);
    });

    testWidgets('crate return sheet: Skip closes it without confirming or '
        'recording a crate return', (tester) async {
      await pumpOrders(tester, env: env, screen: const OrdersScreen());
      final confirm = inCard(
        kPendingCrateOrderId,
        find.byKey(OrdersKeys.confirm),
      );
      await centre(tester, confirm);
      await tester.tap(confirm);
      await settleOrders(tester);
      expect(find.byKey(OrdersKeys.crateReturnSheet), findsOneWidget);

      await tester.tap(find.widgetWithText(AppButton, 'Skip'));
      await settleOrders(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(OrdersKeys.crateReturnSheet), findsNothing);
      // Still pending: Skip is a cancel, not a confirm with no crates.
      expect(
        inCard(kPendingCrateOrderId, find.byKey(OrdersKeys.confirm)),
        findsOneWidget,
      );
      await finish(tester);
    });

    testWidgets('crate return sheet: no Cash refund without the wallet '
        'withdraw grant', (tester) async {
      await pumpOrders(
        tester,
        env: env,
        screen: const OrdersScreen(),
        cashier: true,
      );
      final confirm = inCard(
        kPendingCrateOrderId,
        find.byKey(OrdersKeys.confirm),
      );
      await centre(tester, confirm);
      await tester.tap(confirm);
      await settleOrders(tester);
      expect(find.byKey(OrdersKeys.refundCredit), findsOneWidget);
      expect(find.byKey(OrdersKeys.refundCash), findsNothing);
      await finish(tester);
    });

    testWidgets('caps the list at 720 on a wide screen', (tester) async {
      await pumpOrders(
        tester,
        env: env,
        screen: const OrdersScreen(),
        size: const Size(1280, 800),
        padding: const EdgeInsets.only(top: 24),
      );
      expect(
        tester.getSize(find.byKey(OrdersKeys.summary)).width,
        lessThanOrEqualTo(kSettingsMaxContentWidth),
      );
      expect(
        tester.getSize(find.byKey(orderRowKey(kPendingCrateOrderId))).width,
        lessThanOrEqualTo(kSettingsMaxContentWidth),
      );
      await finish(tester);
    });

    for (final MapEntry(key: name, value: l) in _layouts.entries) {
      testWidgets('no overflow on any tab at $name', (tester) async {
        for (final tab in [0, 1, 2]) {
          await pumpOrders(
            tester,
            env: env,
            screen: OrdersScreen(initialIndex: tab),
            size: l.size,
            padding: l.padding,
            textScaler: l.scale,
          );
          expectNoOverflow(tester, reason: 'tab $tab at $name');
          await finish(tester);
        }
      });
    }

    for (final (name, size, padding, keyboard) in [
      (
        '390x844 keyboard',
        const Size(390, 844),
        const EdgeInsets.only(top: 24),
        const EdgeInsets.only(bottom: 300),
      ),
      (
        '844x390 keyboard',
        const Size(844, 390),
        const EdgeInsets.only(top: 24, right: 48),
        const EdgeInsets.only(bottom: 180),
      ),
    ]) {
      testWidgets('no overflow with the $name (search, then the crate sheet)', (
        tester,
      ) async {
        await pumpOrders(
          tester,
          env: env,
          screen: const OrdersScreen(),
          size: size,
          padding: padding,
          followView: true,
        );
        tester.view.padding = FakeViewPadding(
          top: padding.top,
          right: padding.right,
          bottom: padding.bottom,
        );
        tester.view.viewPadding = tester.view.padding;
        // The keyboard over the screen (search field focused).
        await tester.tap(find.byKey(OrdersKeys.search));
        tester.view.viewInsets = FakeViewPadding(bottom: keyboard.bottom);
        await settleOrders(tester);
        expectNoOverflow(tester, reason: name);
        tester.view.viewInsets = FakeViewPadding.zero;
        FocusManager.instance.primaryFocus?.unfocus();
        await settleOrders(tester);

        // The crate sheet, then the keyboard for its count field.
        final confirm = inCard(
          kPendingCrateOrderId,
          find.byKey(OrdersKeys.confirm),
        );
        await centre(tester, confirm);
        await tester.tap(confirm);
        await settleOrders(tester);
        expect(find.byKey(OrdersKeys.crateReturnSheet), findsOneWidget);
        await tester.tap(
          find.byKey(Key('crate-return-count-${env.manufacturers.first.id}')),
        );
        tester.view.viewInsets = FakeViewPadding(bottom: keyboard.bottom);
        await settleOrders(tester);
        expectNoOverflow(tester, reason: '$name crate sheet');
        tester.view.resetViewInsets();
        tester.view.resetPadding();
        tester.view.resetViewPadding();
        await finish(tester);
      });
    }
  });

  group('Crate Return Approval', () {
    testWidgets('lists the returns with 48dp Approve / Reject; Reject asks for '
        'a reason', (tester) async {
      await pumpOrders(
        tester,
        env: env,
        screen: const CrateReturnApprovalScreen(),
      );
      expect(find.text('Crate Return Approval'), findsOneWidget);
      expect(find.text('Chinedu Okafor'), findsOneWidget);
      expect(find.text('Quantity: 2'), findsOneWidget);
      for (final key in [
        const Key('crate-return-approve-ret-1'),
        const Key('crate-return-reject-ret-1'),
      ]) {
        expect(h(tester, find.byKey(key)), greaterThanOrEqualTo(48));
      }
      await tester.tap(find.byKey(const Key('crate-return-reject-ret-1')));
      await settleOrders(tester);
      expect(find.text('Reject Crate Return'), findsOneWidget);
      await tester.tap(find.widgetWithText(AppButton, 'Cancel'));
      await settleOrders(tester);
      expect(find.text('Reject Crate Return'), findsNothing);
      await finish(tester);
    });

    testWidgets('caps at 720 on a wide screen', (tester) async {
      await pumpOrders(
        tester,
        env: env,
        screen: const CrateReturnApprovalScreen(),
        size: const Size(1280, 800),
        padding: const EdgeInsets.only(top: 24),
      );
      final row = find.ancestor(
        of: find.text('Chinedu Okafor'),
        matching: find.byType(Container),
      );
      expect(
        tester.getSize(row.last).width,
        lessThanOrEqualTo(kSettingsMaxContentWidth),
      );
      await finish(tester);
    });

    for (final MapEntry(key: name, value: l) in _layouts.entries) {
      testWidgets('no overflow at $name', (tester) async {
        await pumpOrders(
          tester,
          env: env,
          screen: const CrateReturnApprovalScreen(),
          size: l.size,
          padding: l.padding,
          textScaler: l.scale,
        );
        expectNoOverflow(tester, reason: name);
        await finish(tester);
      });
    }
  });
}
