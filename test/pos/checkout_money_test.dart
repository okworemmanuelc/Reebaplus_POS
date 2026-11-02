// Pins every Checkout money figure and what Confirm Payment hands to
// `OrderService.addOrder` (#393, PRD #346 Wave 2 A). Written against the
// Checkout as it was BEFORE the restyle, and kept unchanged after it: the
// restyle may move things on screen, never a figure, a split, a default or a
// validation.
//
// Fixture (a crate business, sample data only): Star Lager ×2 (₦9,600, crate
// bottle of Nigerian Breweries, ₦1,000 a crate) with a ₦500 discount, Hero
// Lager ×1 (₦8,400, crate bottle of Hero Breweries, which has no crate value),
// Eva Water ×2 (₦2,700). Subtotal ₦33,000,
// goods total ₦32,500. A registered customer holding ₦5,000 credit with a
// ₦50,000 debt limit.

import 'dart:async';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/pos/screens/cart_screen.dart';
import 'package:reebaplus_pos/features/pos/screens/checkout_page.dart';
import 'package:reebaplus_pos/features/pos/widgets/cart/cart_parts.dart';
import 'package:reebaplus_pos/shared/services/cart_service.dart';
import 'package:reebaplus_pos/shared/services/orders/order_service.dart';
import 'package:reebaplus_pos/shared/services/printer_service.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

import '../helpers/screen_harness.dart';
import 'cart_fixture.dart';
import 'checkout_fixture.dart';

/// Records the one `addOrder` call Confirm Payment makes; writes nothing.
class _RecordingOrderService extends OrderService {
  _RecordingOrderService(super.db);

  final calls = <Map<String, Object?>>[];

  /// When set, addOrder waits on it after recording the call (a slow save).
  Completer<void>? gate;

  @override
  Future<String> addOrder({
    required String? customerId,
    required List<Map<String, dynamic>> cart,
    required int totalAmountKobo,
    required int amountPaidKobo,
    required String paymentType,
    String? staffId,
    String? storeId,
    int crateDepositPaidKobo = 0,
    int discountKobo = 0,
    String paymentSubType = 'cash',
    int walletBalanceKobo = 0,
    Map<String, int> crateDepositPaidByManufacturer = const {},
    Map<String, double> cratesReturnedByManufacturer = const {},
    String? onlineOrderId,
  }) async {
    calls.add({
      if (onlineOrderId != null) 'onlineOrderId': onlineOrderId,
      if (cratesReturnedByManufacturer.isNotEmpty)
        'cratesReturnedByManufacturer': Map<String, double>.from(
          cratesReturnedByManufacturer,
        ),
      'customerId': customerId,
      'lines': cart.length,
      'totalAmountKobo': totalAmountKobo,
      'amountPaidKobo': amountPaidKobo,
      'paymentType': paymentType,
      'storeId': storeId,
      'crateDepositPaidKobo': crateDepositPaidKobo,
      'discountKobo': discountKobo,
      'paymentSubType': paymentSubType,
      'walletBalanceKobo': walletBalanceKobo,
      'crateDepositPaidByManufacturer': Map<String, int>.from(
        crateDepositPaidByManufacturer,
      ),
    });
    await gate?.future;
    return 'ORD-000001-TEST01';
  }
}

/// No printer: the auto-print after Confirm stops at the permission ask.
class _NoPrinter extends PrinterService {
  @override
  Future<bool> requestPermissions() async => false;
}

/// A device that HAS a printer set up, which fails to print (#614).
class _BrokenPrinter extends PrinterService {
  @override
  Future<bool> hasPrinterSetUp() async => true;

  @override
  Future<bool> requestPermissions() async => false;
}

/// A set-up printer that holds the print open until [gate] completes (#659).
class _SlowPrinter extends PrinterService {
  final gate = Completer<void>();
  int permissionAsks = 0;

  @override
  Future<bool> hasPrinterSetUp() async => true;

  @override
  Future<bool> requestPermissions() async {
    permissionAsks++;
    await gate.future;
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late _RecordingOrderService orders;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      businessType: 'Bar',
      manufacturerCount: 2,
    );
    final db = env.db;
    await (db.update(
      db.manufacturers,
    )..where((t) => t.id.equals(env.manufacturers[0].id))).write(
      const ManufacturersCompanion(
        name: Value('Nigerian Breweries'),
        depositAmountKobo: Value(100000),
      ),
    );
    await (db.update(db.manufacturers)
          ..where((t) => t.id.equals(env.manufacturers[1].id)))
        .write(const ManufacturersCompanion(name: Value('Hero Breweries')));
    orders = _RecordingOrderService(env.db);
  });
  tearDown(() async => env.dispose());

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  final regular = Customer(
    id: 'cust-1',
    name: 'Chinedu Okafor',
    addressText: '',
    googleMapsLocation: '',
    walletLimitKobo: 5000000, // ₦50,000
  );

  /// Pumps the Cart with the fixture, taps Proceed to Checkout and returns
  /// once Checkout shows.
  Future<void> openCheckout(
    WidgetTester tester, {
    Customer? customer,
    int creditKobo = 0,
    String? onlineOrderId,
    PrinterService? printer,
  }) async {
    final starId = env.manufacturers[0].id;
    final heroId = env.manufacturers[1].id;
    await pumpScreen(
      tester,
      env: env,
      size: const Size(800, 1280),
      padding: const EdgeInsets.only(top: 24, bottom: 24),
      screen: _Prefilled(
        fill: (cart) {
          cart.addItem(
            mockupLine(
              name: 'Star Lager',
              price: 9600,
              subtitle: '60cl',
              category: 'Beer',
              bottle: true,
              crateKobo: 100000,
              manufacturerId: starId,
            ),
            qty: 2,
          );
          cart.addItem(
            mockupLine(
              name: 'Hero Lager',
              price: 8400,
              subtitle: '60cl',
              category: 'Beer',
              bottle: true,
              manufacturerId: heroId,
            ),
          );
          cart.addItem(
            mockupLine(
              name: 'Eva Water',
              price: 2700,
              subtitle: '75cl',
              category: 'Water',
            ),
            qty: 2,
          );
          cart.setLineDiscount(
            'Star Lager',
            kind: 'naira',
            enteredValue: 500,
            discountKobo: 50000,
          );
          if (customer != null) cart.setActiveCustomer(customer);
          // #431 — a Cart sent to the till from an Online Order.
          if (onlineOrderId != null) {
            cart.loadCart([
              for (final l in cart.value)
                {...l, CartService.kOnlineOrderIdKey: onlineOrderId},
            ], customer);
          }
        },
        builder: (c) => CartScreen(
          cart: const [],
          activeCustomer: c.activeCustomer.value,
          onCustomerChanged: (_) {},
        ),
      ),
      overrides: [
        firstRunSurfaceStateProvider.overrideWithValue(
          FirstRunSurfaceState.hasContent,
        ),
        orderServiceProvider.overrideWithValue(orders),
        printerServiceProvider.overrideWithValue(printer ?? _NoPrinter()),
        creditBalancesKoboProvider.overrideWith(
          (ref) => Stream.value({'cust-1': creditKobo}),
        ),
      ],
      sharedPreferences: const {'hint_cart_tap_edit': 2},
      settle: false,
    );
    await settle(tester);
    await tester.tap(find.byKey(CartKeys.checkout));
    await settle(tester);
    expect(find.byType(CheckoutPage), findsOneWidget);
  }

  /// Lets every toast run out (4s) before the tree is disposed.
  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await disposeScreen(tester);
  }

  Finder inCheckout(Finder f) =>
      find.descendant(of: find.byType(CheckoutPage), matching: f);

  Future<void> tapButton(WidgetTester tester, String label) async {
    final button = inCheckout(find.widgetWithText(AppButton, label));
    await tester.ensureVisible(button);
    await tester.pump();
    await tester.tap(button);
    await settle(tester);
  }

  Future<void> tapReceiptPrint(WidgetTester tester) async {
    await tester.tap(inCheckout(find.text('Print Receipt')));
    await tester.pump();
  }

  Future<void> enterAmountPaid(WidgetTester tester, String text) async {
    final field = inCheckout(
      find.descendant(
        of: find.widgetWithText(AppInput, 'Amount Paid'),
        matching: find.byType(TextField),
      ),
    );
    await tester.ensureVisible(field);
    await tester.pump();
    await tester.enterText(field, text);
    await tester.pump();
  }

  String starId() => env.manufacturers[0].id;
  String heroId() => env.manufacturers[1].id;

  Finder emptiesField(String manufacturerId) => inCheckout(
    find.descendant(
      of: find.byKey(CheckoutKeys.emptiesReturned(manufacturerId)),
      matching: find.byType(TextField),
    ),
  );

  Future<void> enterEmpties(
    WidgetTester tester,
    String manufacturerId,
    String text,
  ) async {
    final field = emptiesField(manufacturerId);
    await tester.ensureVisible(field);
    await tester.pump();
    await tester.enterText(field, text);
    await tester.pump();
  }

  /// #656 — a walk-in returns every empty: Star 2, Hero 1.
  Future<void> returnAllEmpties(WidgetTester tester) async {
    await enterEmpties(tester, starId(), '2');
    await enterEmpties(tester, heroId(), '1');
  }

  testWidgets('registered customer: crates + discount + part deposit + part '
      'payment — every figure and what Confirm sends', (tester) async {
    await openCheckout(tester, customer: regular, creditKobo: 500000);
    final starId = env.manufacturers[0].id;

    // Before any deposit: subtotal, discount and the goods total.
    expect(inCheckout(find.text(formatCurrency(33000))), findsOneWidget);
    expect(inCheckout(find.text(formatCurrency(-500))), findsOneWidget);
    expect(inCheckout(find.text(formatCurrency(32500))), findsWidgets);
    // The full deposit reference: Star 2 × ₦1,000 + Hero 1 × ₦0.
    expect(inCheckout(find.text('Full deposit if collected')), findsOneWidget);
    expect(inCheckout(find.text(formatCurrency(2000))), findsWidgets);
    // Hero Lager has no crate value set.
    expect(
      inCheckout(find.text('No crate value set for Hero Breweries')),
      findsOneWidget,
    );
    // Each brand starts at no deposit.
    expect(
      inCheckout(find.text('1 crate · Full ${formatCurrency(0)} · No deposit')),
      findsOneWidget,
    );
    expect(
      inCheckout(
        find.text('2 crates · Full ${formatCurrency(2000)} · No deposit'),
      ),
      findsOneWidget,
    );

    // Enter a part deposit of ₦1,500 for Nigerian Breweries (Star Lager).
    final starRow = inCheckout(
      find.text('2 crates · Full ${formatCurrency(2000)} · No deposit'),
    );
    await tester.ensureVisible(starRow);
    await tester.pump();
    await tester.tap(starRow);
    await settle(tester);
    expect(find.text('Deposit — Nigerian Breweries'), findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(TextField),
      ),
      '1500',
    );
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.widgetWithText(AppButton, 'Save'),
      ),
    );
    await settle(tester);

    // Deposit row + summary: Total = ₦32,500 goods + ₦1,500 deposit.
    expect(
      inCheckout(find.text('2 crates · Full ${formatCurrency(2000)} · Part')),
      findsOneWidget,
    );
    expect(inCheckout(find.text('Crate Deposit')), findsWidgets);
    expect(inCheckout(find.text(formatCurrency(1500))), findsWidgets);
    expect(inCheckout(find.text(formatCurrency(34000))), findsWidgets);

    // Auto-fill suggests total − credit = ₦34,000 − ₦5,000.
    expect(
      inCheckout(find.text('Auto-fill ${formatCurrency(29000)}')),
      findsOneWidget,
    );

    // Pay ₦20,000 now: the balance lands on 5,000 + 20,000 − 34,000 = −9,000;
    // the hint names the cash shortfall against the total, ₦14,000.
    await enterAmountPaid(tester, '20000');
    expect(inCheckout(find.text('Resulting Credits Balance')), findsOneWidget);
    expect(inCheckout(find.text(formatCurrency(-9000))), findsOneWidget);
    expect(
      inCheckout(
        find.textContaining('Shortfall ${formatCurrency(14000)} added to'),
      ),
      findsOneWidget,
    );

    await tapButton(tester, 'Confirm Payment');

    expect(orders.calls, hasLength(1));
    expect(orders.calls.single, {
      'customerId': 'cust-1',
      'lines': 3,
      'totalAmountKobo': 3400000,
      'amountPaidKobo': 2000000,
      'paymentType': 'Cash / Credit',
      'storeId': env.storeId,
      'crateDepositPaidKobo': 150000,
      'discountKobo': 50000,
      'paymentSubType': 'cash',
      'walletBalanceKobo': 500000,
      // Every crate brand is sent, an untouched one at 0.
      'crateDepositPaidByManufacturer': {
        starId: 150000,
        env.manufacturers[1].id: 0,
      },
    });
    // On to the receipt.
    expect(inCheckout(find.text('Receipt Options')), findsOneWidget);
    await finish(tester);
  });

  testWidgets('no printer set up: the sale finishes with no print error', (
    tester,
  ) async {
    await openCheckout(tester, customer: regular, creditKobo: 0);
    await enterAmountPaid(tester, '32500');
    await tapButton(tester, 'Confirm Payment');
    await tester.pump();
    expect(orders.calls, hasLength(1));
    expect(find.text('Bluetooth permissions denied'), findsNothing);
    expect(find.text("Couldn't print — check the printer"), findsNothing);
    await finish(tester);
  });

  testWidgets('a set-up printer that fails shows Couldn\'t print + Retry', (
    tester,
  ) async {
    await openCheckout(
      tester,
      customer: regular,
      creditKobo: 0,
      printer: _BrokenPrinter(),
    );
    await enterAmountPaid(tester, '32500');
    await tapButton(tester, 'Confirm Payment');
    await tester.pump();
    await tester.pump();
    expect(orders.calls, hasLength(1));
    expect(find.text("Couldn't print — check the printer"), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    // The notice stays 8s, longer than finish() waits.
    await tester.pump(const Duration(seconds: 9));
    await finish(tester);
  });

  testWidgets('two quick taps on Confirm Payment record one sale (#659)', (
    tester,
  ) async {
    orders.gate = Completer<void>();
    await openCheckout(tester, customer: regular, creditKobo: 0);
    await enterAmountPaid(tester, '32500');
    final confirm = inCheckout(find.byKey(CheckoutKeys.confirm));
    await tester.ensureVisible(confirm);
    await tester.pump();
    // No frame between the taps: the lock must already be taken.
    await tester.tap(confirm);
    await tester.tap(confirm);
    await settle(tester);
    expect(orders.calls, hasLength(1));

    // While the sale saves, Back is locked too: the in-app arrow and the
    // Android back gesture. Leaving would keep the cart to be sold again.
    final back = tester.widget<IconButton>(
      find.descendant(
        of: find.byKey(CheckoutKeys.topBar),
        matching: find.byType(IconButton),
      ),
    );
    expect(back.onPressed, isNull);
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.byType(CheckoutPage), findsOneWidget);

    orders.gate!.complete();
    await settle(tester);
    expect(orders.calls, hasLength(1));
    await finish(tester);
  });

  testWidgets('only one print runs at a time, auto or manual (#659)', (
    tester,
  ) async {
    final printer = _SlowPrinter();
    await openCheckout(
      tester,
      customer: regular,
      creditKobo: 0,
      printer: printer,
    );
    await enterAmountPaid(tester, '32500');
    await tapButton(tester, 'Confirm Payment');
    await tester.pump();
    // Auto-print is waiting on the printer.
    expect(printer.permissionAsks, 1);
    // A manual tap, twice, during auto-print is ignored.
    await tapReceiptPrint(tester);
    await tapReceiptPrint(tester);
    expect(printer.permissionAsks, 1);

    printer.gate.complete();
    await settle(tester);
    // After it ends, a manual print runs again.
    await tapReceiptPrint(tester);
    expect(printer.permissionAsks, 2);
    await tester.pump(const Duration(seconds: 9));
    await finish(tester);
  });

  testWidgets('a deposit the payment does not cover is refused', (
    tester,
  ) async {
    await openCheckout(tester, customer: regular, creditKobo: 500000);
    final starRow = inCheckout(
      find.text('2 crates · Full ${formatCurrency(2000)} · No deposit'),
    );
    await tester.ensureVisible(starRow);
    await tester.pump();
    await tester.tap(starRow);
    await settle(tester);
    // "Use full" fills the whole ₦2,000.
    await tester.tap(find.text('Use full (${formatCurrency(2000)})'));
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.widgetWithText(AppButton, 'Save'),
      ),
    );
    await settle(tester);
    expect(
      inCheckout(find.text('2 crates · Full ${formatCurrency(2000)} · Full')),
      findsOneWidget,
    );
    expect(inCheckout(find.text(formatCurrency(34500))), findsWidgets);

    await enterAmountPaid(tester, '1000');
    await tapButton(tester, 'Confirm Payment');
    expect(orders.calls, isEmpty);
    expect(
      find.textContaining('Amount paid must cover the crate deposit of'),
      findsOneWidget,
    );
    await finish(tester);
  });

  testWidgets('Transfer tender is what Confirm writes', (tester) async {
    await openCheckout(tester, customer: regular, creditKobo: 0);
    final transfer = inCheckout(find.text('Transfer'));
    await tester.ensureVisible(transfer);
    await tester.pump();
    await tester.tap(transfer);
    await tester.pump();
    await enterAmountPaid(tester, '32500');
    await tapButton(tester, 'Confirm Payment');
    expect(orders.calls.single['paymentSubType'], 'transfer');
    expect(orders.calls.single['paymentType'], 'Transfer');
    expect(orders.calls.single['amountPaidKobo'], 3250000);
    expect(orders.calls.single['totalAmountKobo'], 3250000);
    expect(orders.calls.single['crateDepositPaidKobo'], 0);
    await finish(tester);
  });

  testWidgets('empty amount with enough credit switches to Pay with Credit', (
    tester,
  ) async {
    await openCheckout(tester, customer: regular, creditKobo: 5000000);
    await tapButton(tester, 'Confirm Payment');
    expect(orders.calls.single['paymentSubType'], 'wallet');
    expect(orders.calls.single['paymentType'], 'Credit Payment');
    expect(orders.calls.single['amountPaidKobo'], 0);
    expect(orders.calls.single['totalAmountKobo'], 3250000);
    expect(orders.calls.single['walletBalanceKobo'], 5000000);
    await finish(tester);
  });

  testWidgets('Register as Credit Sale books the whole total as debt', (
    tester,
  ) async {
    await openCheckout(tester, customer: regular, creditKobo: 0);
    final card = inCheckout(find.text('Register as Credit Sale'));
    await tester.ensureVisible(card);
    await tester.pump();
    await tester.tap(card);
    await tester.pump();
    expect(inCheckout(find.text(formatCurrency(-32500))), findsOneWidget);
    await tapButton(tester, 'Confirm Payment');
    expect(orders.calls.single['paymentType'], 'Credit Sale');
    expect(orders.calls.single['paymentSubType'], 'cash');
    expect(orders.calls.single['amountPaidKobo'], 0);
    expect(orders.calls.single['crateDepositPaidKobo'], 0);
    await finish(tester);
  });

  testWidgets('a Cart sent to the till hands its Online Order to Checkout '
      '(#431)', (tester) async {
    await openCheckout(tester, onlineOrderId: 'online-1');
    await returnAllEmpties(tester);
    await tapButton(tester, 'Confirm Payment');
    expect(orders.calls.single['onlineOrderId'], 'online-1');
    expect(orders.calls.single['totalAmountKobo'], 3250000);
    await finish(tester);
  });

  // ── #432 Pay on delivery ────────────────────────────────────────────────
  final newOnline = Customer(
    id: 'cust-1',
    name: 'Ada Buyer',
    addressText: '',
    googleMapsLocation: '',
    walletLimitKobo: 0, // a new online customer: no debt limit
  );

  Future<void> tapPayOnDelivery(WidgetTester tester) async {
    final card = inCheckout(find.byKey(CheckoutKeys.modePayOnDelivery));
    await tester.ensureVisible(card);
    await tester.pump();
    await tester.tap(card);
    await tester.pump();
  }

  testWidgets('Pay on delivery is offered only for a Cart from an online '
      'order (#432)', (tester) async {
    await openCheckout(tester, customer: regular);
    expect(
      inCheckout(find.byKey(CheckoutKeys.modePayOnDelivery)),
      findsNothing,
    );
    expect(inCheckout(find.byKey(CheckoutKeys.modeCredit)), findsOneWidget);
    await finish(tester);
  });

  testWidgets('Pay on delivery books a credit sale labelled with what to '
      'collect, never credit (#432)', (tester) async {
    await openCheckout(tester, customer: regular, onlineOrderId: 'online-1');
    expect(inCheckout(find.byKey(CheckoutKeys.modeCredit)), findsNothing);
    expect(inCheckout(find.text('Register as Credit Sale')), findsNothing);
    final label = 'Pay on delivery · ${formatCurrency(32500)} to collect';
    expect(inCheckout(find.text(label)), findsOneWidget);
    await tapPayOnDelivery(tester);
    await tapButton(tester, 'Confirm Payment');
    final call = orders.calls.single;
    expect(call['paymentType'], label);
    expect(
      (call['paymentType'] as String).toLowerCase(),
      isNot(contains('credit')),
    );
    // Underneath: exactly the credit-sale call.
    expect(call['paymentSubType'], 'cash');
    expect(call['amountPaidKobo'], 0);
    expect(call['crateDepositPaidKobo'], 0);
    expect(call['totalAmountKobo'], 3250000);
    expect(call['onlineOrderId'], 'online-1');
    await finish(tester);
  });

  testWidgets('a new customer with no debt limit can be served Pay on '
      'delivery (#432)', (tester) async {
    await openCheckout(tester, customer: newOnline, onlineOrderId: 'online-1');
    await tapPayOnDelivery(tester);
    expect(inCheckout(find.byKey(CheckoutKeys.debtLimit)), findsNothing);
    await tapButton(tester, 'Confirm Payment');
    expect(orders.calls, hasLength(1));
    await finish(tester);
  });

  testWidgets('a customer with no debt limit can book an ordinary credit '
      'sale, uncapped (#621)', (tester) async {
    await openCheckout(tester, customer: newOnline);
    final card = inCheckout(find.text('Register as Credit Sale'));
    await tester.ensureVisible(card);
    await tester.pump();
    await tester.tap(card);
    await tester.pump();
    await tapButton(tester, 'Confirm Payment');
    expect(orders.calls, hasLength(1));
    expect(inCheckout(find.byKey(CheckoutKeys.debtLimit)), findsNothing);
    await finish(tester);
  });

  testWidgets('prior debt over the limit still blocks Pay on delivery '
      '(#432)', (tester) async {
    // Owes ₦60,000 against a ₦50,000 limit before this order.
    await openCheckout(
      tester,
      customer: regular,
      creditKobo: -6000000,
      onlineOrderId: 'online-1',
    );
    await tapPayOnDelivery(tester);
    expect(inCheckout(find.byKey(CheckoutKeys.debtLimit)), findsOneWidget);
    await tapButton(tester, 'Confirm Payment');
    expect(orders.calls, isEmpty);
    expect(find.textContaining('already over their debt limit'), findsWidgets);
    await finish(tester);
  });

  testWidgets('prior debt within the limit: Pay on delivery ignores this '
      'order\'s own amount (#432)', (tester) async {
    // Owes ₦40,000 of ₦50,000; this ₦32,500 order would break the limit if
    // it counted, but only the earlier debt is checked.
    await openCheckout(
      tester,
      customer: regular,
      creditKobo: -4000000,
      onlineOrderId: 'online-1',
    );
    await tapPayOnDelivery(tester);
    await tapButton(tester, 'Confirm Payment');
    expect(orders.calls, hasLength(1));
    await finish(tester);
  });

  testWidgets('prior debt with no limit set is fine for Pay on delivery '
      '(unlimited credit, #621)', (tester) async {
    await openCheckout(
      tester,
      customer: newOnline,
      creditKobo: -100000,
      onlineOrderId: 'online-1',
    );
    await tapPayOnDelivery(tester);
    await tapButton(tester, 'Confirm Payment');
    expect(orders.calls, hasLength(1));
    await finish(tester);
  });

  testWidgets('walk-in: the wrong amount is refused; empty pays the total', (
    tester,
  ) async {
    await openCheckout(tester);
    // Walk-ins pay no deposit: no deposit section, total is the goods total.
    expect(inCheckout(find.text('Full deposit if collected')), findsNothing);
    expect(inCheckout(find.text('Empty Crates Being Taken')), findsOneWidget);
    await returnAllEmpties(tester);

    await enterAmountPaid(tester, '30000');
    await tapButton(tester, 'Confirm Payment');
    expect(orders.calls, isEmpty);
    expect(
      find.text('Walk-in customers must pay exactly the cart total.'),
      findsOneWidget,
    );

    await enterAmountPaid(tester, '');
    await tapButton(tester, 'Confirm Payment');
    expect(orders.calls.single['customerId'], isNull);
    expect(orders.calls.single['amountPaidKobo'], 3250000);
    expect(orders.calls.single['totalAmountKobo'], 3250000);
    expect(orders.calls.single['paymentType'], 'Cash');
    expect(orders.calls.single['discountKobo'], 50000);
    await finish(tester);
  });

  group('Empties Exchange (#649)', () {
    Finder note() => inCheckout(find.byKey(CheckoutKeys.emptiesReturnedNote));

    testWidgets('every brand gets a blank number field above Confirm', (
      tester,
    ) async {
      await openCheckout(tester, customer: regular);
      for (final id in [starId(), heroId()]) {
        final field = tester.widget<TextField>(emptiesField(id));
        expect(field.controller!.text, isEmpty, reason: 'never pre-filled');
        expect(field.keyboardType.index, TextInputType.number.index);
        expect(field.keyboardType.decimal, isTrue, reason: 'quarter crates');
        expect(field.keyboardType.signed, isNot(isTrue));
        expect(
          tester.getBottomLeft(emptiesField(id)).dy,
          lessThan(tester.getTopLeft(find.byKey(CheckoutKeys.confirm)).dy),
          reason: 'counted before the receipt prints on Confirm',
        );
      }
      expect(inCheckout(find.text('1 crate in this sale')), findsOneWidget);
      expect(inCheckout(find.text('2 crates in this sale')), findsOneWidget);
      expect(note(), findsNothing);
      await finish(tester);
    });

    testWidgets('all back: no deposit, note, Confirm sends the counts', (
      tester,
    ) async {
      await openCheckout(tester, customer: regular);
      await enterEmpties(tester, starId(), '2');
      await enterEmpties(tester, heroId(), '1');

      expect(
        tester.widget<Text>(note()).data,
        'All crates back. This sale completes now.',
      );
      expect(inCheckout(find.byKey(CheckoutKeys.crateDeposit)), findsNothing);
      expect(inCheckout(find.byKey(CheckoutKeys.cratesTaken)), findsNothing);
      expect(
        inCheckout(find.byKey(CheckoutKeys.crateValueMissing)),
        findsNothing,
      );

      await enterAmountPaid(tester, '32500');
      await tapButton(tester, 'Confirm Payment');

      expect(orders.calls.single['totalAmountKobo'], 3250000);
      expect(orders.calls.single['crateDepositPaidKobo'], 0);
      expect(orders.calls.single['cratesReturnedByManufacturer'], {
        starId(): 2.0,
        heroId(): 1.0,
      });
      await finish(tester);
    });

    testWidgets('some back: the deposit shrinks and the payable moves live', (
      tester,
    ) async {
      await openCheckout(tester, customer: regular);
      final starRow = inCheckout(
        find.text('2 crates · Full ${formatCurrency(2000)} · No deposit'),
      );
      await tester.ensureVisible(starRow);
      await tester.pump();
      await tester.tap(starRow);
      await settle(tester);
      await tester.tap(find.text('Use full (${formatCurrency(2000)})'));
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.widgetWithText(AppButton, 'Save'),
        ),
      );
      await settle(tester);
      expect(inCheckout(find.text(formatCurrency(34500))), findsWidgets);

      // 1.5 of Star's 2 back: the ₦2,000 deposit clamps to the ₦500 now full.
      await enterEmpties(tester, starId(), '1.5');
      expect(
        tester.widget<Text>(note()).data,
        '1.5 crates still to come back. This sale goes to Pending.',
      );
      expect(
        inCheckout(
          find.text('0.5 crates · Full ${formatCurrency(500)} · Full'),
        ),
        findsOneWidget,
      );
      expect(inCheckout(find.text(formatCurrency(33000))), findsWidgets);

      // All of Star back: its deposit goes, and clearing the field keeps it 0.
      await enterEmpties(tester, starId(), '2');
      expect(inCheckout(find.text(formatCurrency(32500))), findsWidgets);
      await enterEmpties(tester, starId(), '');
      expect(note(), findsNothing);
      expect(
        inCheckout(
          find.text('2 crates · Full ${formatCurrency(2000)} · No deposit'),
        ),
        findsOneWidget,
      );

      await enterEmpties(tester, heroId(), '1');
      await enterAmountPaid(tester, '32500');
      await settle(tester); // the caret's scroll ignores taps until it stops
      await tapButton(tester, 'Confirm Payment');
      expect(orders.calls.single['crateDepositPaidKobo'], 0);
      expect(orders.calls.single['cratesReturnedByManufacturer'], {
        heroId(): 1.0,
      });
      await finish(tester);
    });

    testWidgets('a count off the quarter step is refused', (tester) async {
      await openCheckout(tester, customer: regular);
      await enterEmpties(tester, starId(), '0.3');
      expect(note(), findsNothing);
      await enterAmountPaid(tester, '32500');
      await tapButton(tester, 'Confirm Payment');
      expect(orders.calls, isEmpty);
      expect(
        find.text('Crate counts go in quarters: 0, 0.25, 0.5, 0.75, 1 …'),
        findsOneWidget,
      );
      await finish(tester);
    });

    testWidgets('more than this sale holds is refused', (tester) async {
      await openCheckout(tester, customer: regular);
      await enterEmpties(tester, starId(), '3');
      expect(note(), findsNothing);
      await enterAmountPaid(tester, '32500');
      await tapButton(tester, 'Confirm Payment');
      expect(orders.calls, isEmpty);
      expect(
        find.text('Only 2 crates of Nigerian Breweries are in this sale.'),
        findsOneWidget,
      );
      await finish(tester);
    });

    testWidgets('a walk-in must return every empty (#656)', (tester) async {
      await openCheckout(tester);
      // Star is Nigerian Breweries (2 crates); Hero Breweries (1) sorts first.
      const heroNone =
          'A walk-in must return all 1 Hero Breweries empty '
          '(0 entered).';
      const starNone =
          'A walk-in must return all 2 Nigerian Breweries '
          'empties (0 entered).';

      // Nothing entered: the first brand on the screen is the short one.
      await tapButton(tester, 'Confirm Payment');
      expect(orders.calls, isEmpty);
      expect(find.text(heroNone), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));

      // Hero in full: the note is the refusal about Star, not "Pending".
      await enterEmpties(tester, heroId(), '1');
      expect(tester.widget<Text>(note()).data, starNone);
      await tapButton(tester, 'Confirm Payment');
      expect(orders.calls, isEmpty);
      expect(find.text(starNone), findsWidgets);
      await tester.pump(const Duration(seconds: 5));

      // A part count names the number entered.
      await enterEmpties(tester, starId(), '1.5');
      await tapButton(tester, 'Confirm Payment');
      expect(orders.calls, isEmpty);
      expect(
        find.text(
          'A walk-in must return all 2 Nigerian Breweries empties '
          '(1.5 entered).',
        ),
        findsWidgets,
      );
      await finish(tester);
    });

    testWidgets('a registered customer may still part-exchange', (
      tester,
    ) async {
      await openCheckout(tester, customer: regular);
      await enterEmpties(tester, starId(), '1');
      expect(
        tester.widget<Text>(note()).data,
        '2 crates still to come back. This sale goes to Pending.',
      );
      await finish(tester);
    });

    testWidgets('walk-ins can use it too', (tester) async {
      await openCheckout(tester);
      await returnAllEmpties(tester);
      await tapButton(tester, 'Confirm Payment');
      expect(orders.calls.single['customerId'], isNull);
      expect(orders.calls.single['cratesReturnedByManufacturer'], {
        starId(): 2.0,
        heroId(): 1.0,
      });
      await finish(tester);
    });

    testWidgets('no field without the Record Crate Return gate', (
      tester,
    ) async {
      await pumpCheckout(tester, env: env, crates: true, grantedKeys: const {});
      expect(
        inCheckout(find.byKey(CheckoutKeys.emptiesReturnedSection)),
        findsNothing,
      );
      expect(inCheckout(find.byKey(CheckoutKeys.cratesTaken)), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('the keyboard never covers the focused count', (tester) async {
      const keyboard = 300.0;
      await pumpCheckout(
        tester,
        env: env,
        crates: true,
        viewInsets: const EdgeInsets.only(bottom: keyboard),
      );
      for (final id in ['mfr-hero', 'mfr-nb']) {
        await tester.showKeyboard(emptiesField(id));
        await settleCheckout(tester);
        expect(
          tester.getBottomLeft(emptiesField(id)).dy,
          lessThanOrEqualTo(844 - keyboard),
        );
      }
      FocusManager.instance.primaryFocus?.unfocus();
      await disposeScreen(tester);
    });
  });
}

class _Prefilled extends ConsumerStatefulWidget {
  const _Prefilled({required this.fill, required this.builder});

  final void Function(CartService cart) fill;
  final Widget Function(CartService cart) builder;

  @override
  ConsumerState<_Prefilled> createState() => _PrefilledState();
}

class _PrefilledState extends ConsumerState<_Prefilled> {
  bool _filled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.fill(ref.read(cartProvider));
      setState(() => _filled = true);
    });
  }

  @override
  Widget build(BuildContext context) => _filled
      ? widget.builder(ref.read(cartProvider))
      : const SizedBox.shrink();
}
