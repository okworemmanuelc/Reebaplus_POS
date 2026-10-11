// #385 — the Cart restyle keeps every rule. These pin the behaviour the new
// look carries: the header's Clear, the customer card and Change, the line
// stepper (the bin at the last unit), exactly when each crate / discount card
// shows, the money figures for a cart with crates, a discount and a deposit,
// the checkout hand-off, and no overflow at the tight sizes.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/pos/screens/cart_screen.dart';
import 'package:reebaplus_pos/features/pos/screens/checkout_page.dart';
import 'package:reebaplus_pos/features/pos/widgets/cart/cart_parts.dart';
import 'package:reebaplus_pos/shared/services/cart_service.dart';

import '../helpers/screen_harness.dart';
import 'cart_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

  tearDown(() async {
    await env.dispose();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  /// Pumps the Cart tab's screen with [fill] run on the cart before the first
  /// frame, and returns the cart.
  Future<CartService> pumpCart(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    EdgeInsets padding = const EdgeInsets.only(top: 24, bottom: 48),
    EdgeInsets viewInsets = EdgeInsets.zero,
    TextScaler? textScaler,
    void Function(CartService cart)? fill,
  }) async {
    late CartService cart;
    await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: padding,
      viewInsets: viewInsets,
      textScaler: textScaler,
      screen: _Prefilled(
        fill: (c) {
          cart = c;
          fill?.call(c);
        },
        // As MainLayout builds the panel's Cart: with the cart's customer.
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
      ],
      sharedPreferences: const {'hint_cart_tap_edit': 2},
      settle: false,
    );
    await settle(tester);
    return cart;
  }

  final regular = Customer(
    id: 'cust-1',
    name: 'Chinedu Okafor',
    addressText: '',
    googleMapsLocation: '',
  );

  /// The mockup cart with crates, a ₦500 discount on Star Lager and,
  /// optionally, a registered customer.
  void Function(CartService) fullFixture({Customer? customer}) => (cart) {
    fillMockupCart(cart, crates: true);
    cart.setLineDiscount(
      'Star Lager',
      kind: 'naira',
      enteredValue: 500,
      discountKobo: 50000,
    );
    if (customer != null) cart.setActiveCustomer(customer);
  };

  group('header', () {
    setUp(() async => env = await setupScreenTestEnvironment());

    testWidgets('shows Cart, the line count and Clear; Clear empties the cart '
        '(as today: no confirm step)', (tester) async {
      final cart = await pumpCart(tester, fill: fillMockupCart);

      expect(find.text('Cart'), findsOneWidget);
      expect(find.text('3 items'), findsOneWidget);
      expect(find.byKey(CartKeys.clear), findsOneWidget);

      await tester.tap(find.byKey(CartKeys.clear));
      await settle(tester);

      expect(cart.value, isEmpty);
      expect(find.text('Cart is empty'), findsOneWidget);
      expect(find.byKey(CartKeys.clear), findsNothing);
      await disposeScreen(tester);
    });
  });

  group('customer card', () {
    setUp(() async => env = await setupScreenTestEnvironment());

    testWidgets('Walk-in Customer with a clear balance; Change opens the '
        'picker', (tester) async {
      await pumpCart(tester, fill: fillMockupCart);

      final card = find.byKey(CartKeys.customerCard);
      expect(
        find.descendant(of: card, matching: find.text('Walk-in Customer')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: card,
          matching: find.text('Bal: ${formatCurrency(0)} clear'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(CartKeys.change));
      await settle(tester);
      expect(find.text('Select Customer'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('shows the chosen customer', (tester) async {
      await pumpCart(
        tester,
        fill: (c) {
          fillMockupCart(c);
          c.setActiveCustomer(regular);
        },
      );
      expect(find.text('Chinedu Okafor'), findsOneWidget);
      await disposeScreen(tester);
    });
  });

  group('line stepper', () {
    setUp(() async => env = await setupScreenTestEnvironment());

    Finder lineOf(String name) =>
        find.byKey(cartLineKey(productId: null, name: name));

    testWidgets('+ adds one, − takes one off, and at 1 the − is a bin that '
        'removes the line with Undo', (tester) async {
      final cart = await pumpCart(tester, fill: fillMockupCart);
      double qtyOf(String name) =>
          (cart.value.firstWhere((l) => l['name'] == name)['qty'] as num)
              .toDouble();

      final star = lineOf('Star Lager');
      await tester.tap(
        find.descendant(
          of: star,
          matching: find.byKey(const Key('stepper-increment')),
        ),
      );
      await tester.pump();
      expect(qtyOf('Star Lager'), 3);

      await tester.tap(
        find.descendant(
          of: star,
          matching: find.byKey(const Key('stepper-decrement')),
        ),
      );
      await tester.pump();
      expect(qtyOf('Star Lager'), 2);

      // Hero Lager is at 1: its minus is the red bin.
      final hero = lineOf('Hero Lager');
      expect(
        find.descendant(of: hero, matching: find.byTooltip('Remove')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: star, matching: find.byTooltip('Decrease')),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(
          of: hero,
          matching: find.byKey(const Key('stepper-decrement')),
        ),
      );
      await tester.pump();
      expect(cart.value.any((l) => l['name'] == 'Hero Lager'), isFalse);

      expect(find.text('Undo'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(qtyOf('Hero Lager'), 1);
      await settle(tester);
      await disposeScreen(tester);
    });

    testWidgets('+ stops at the line\'s stock cap', (tester) async {
      final cart = await pumpCart(
        tester,
        fill: (c) => c.addItem(
          mockupLine(name: 'Star Lager', price: 9600, subtitle: '60cl'),
          qty: 2,
          maxStock: 2,
        ),
      );
      await tester.tap(find.byKey(const Key('stepper-increment')));
      await tester.pump();
      expect((cart.value.single['qty'] as num).toDouble(), 2);
      expect(find.textContaining('2 in stock'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await settle(tester);
      await disposeScreen(tester);
    });

    testWidgets('a discounted line shows its badge and the struck-out gross', (
      tester,
    ) async {
      await pumpCart(tester, fill: fullFixture());
      final star = lineOf('Star Lager');
      expect(
        find.descendant(
          of: star,
          matching: find.text('−${activeCurrencySymbol}500'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: star, matching: find.text(formatCurrency(19200))),
        findsOneWidget,
      );
      expect(
        find.descendant(of: star, matching: find.text(formatCurrency(18700))),
        findsOneWidget,
      );
      await disposeScreen(tester);
    });
  });

  // Tall enough that the whole summary is laid out (a sliver below the
  // viewport is not built).
  const tall = Size(800, 1280);

  group('crate and discount cards show exactly when they do today', () {
    group('crate business', () {
      setUp(
        () async => env = await setupScreenTestEnvironment(businessType: 'Bar'),
      );

      testWidgets('walk-in: the missing-value warning, no Empty Crates', (
        tester,
      ) async {
        await pumpCart(tester, size: tall, fill: fullFixture());
        expect(find.byKey(CartKeys.crateValueMissing), findsOneWidget);
        expect(find.text('Hero Lager'), findsWidgets);
        expect(find.byKey(CartKeys.emptyCrates), findsNothing);
        expect(find.byKey(CartKeys.discount), findsOneWidget);
        await disposeScreen(tester);
      });

      testWidgets('registered customer: Empty Crates with the deposit', (
        tester,
      ) async {
        await pumpCart(
          tester,
          size: tall,
          fill: fullFixture(customer: regular),
        );
        expect(find.byKey(CartKeys.crateValueMissing), findsOneWidget);
        expect(find.byKey(CartKeys.emptyCrates), findsOneWidget);
        expect(find.text('3 going out'), findsOneWidget);
        expect(find.byKey(CartKeys.discount), findsOneWidget);
        await disposeScreen(tester);
      });

      testWidgets('no discount: no Discount card', (tester) async {
        await pumpCart(
          tester,
          size: tall,
          fill: (c) => fillMockupCart(c, crates: true),
        );
        expect(find.byKey(CartKeys.discount), findsNothing);
        await disposeScreen(tester);
      });
    });

    group('non-crate business', () {
      setUp(
        () async =>
            env = await setupScreenTestEnvironment(businessType: 'Pharmacy'),
      );

      testWidgets('no crate cards even for crate bottles', (tester) async {
        await pumpCart(
          tester,
          size: tall,
          fill: fullFixture(customer: regular),
        );
        expect(find.byKey(CartKeys.crateValueMissing), findsNothing);
        expect(find.byKey(CartKeys.emptyCrates), findsNothing);
        expect(find.byKey(CartKeys.discount), findsOneWidget);
        await disposeScreen(tester);
      });
    });
  });

  group('money', () {
    setUp(
      () async => env = await setupScreenTestEnvironment(businessType: 'Bar'),
    );

    testWidgets('figures for crates + a discount + a deposit are unchanged, '
        'and checkout receives them', (tester) async {
      await pumpCart(
        tester,
        size: const Size(800, 1280),
        padding: const EdgeInsets.only(top: 24, bottom: 24),
        fill: fullFixture(customer: regular),
      );

      // Subtotal = 2×9,600 + 8,400 + 2×2,700.
      expect(
        find.descendant(
          of: find.byKey(CartKeys.subtotal),
          matching: find.text(formatCurrency(33000)),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(CartKeys.discount),
          matching: find.text('−${formatCurrency(500)}'),
        ),
        findsOneWidget,
      );
      // Star Lager 2 × ₦1,000 + Hero Lager 1 × ₦0 (no crate value).
      expect(
        find.descendant(
          of: find.byKey(CartKeys.requiredDeposit),
          matching: find.text(formatCurrency(2000)),
        ),
        findsOneWidget,
      );
      // Total = subtotal − discounts; the deposit is captured at checkout.
      expect(
        find.descendant(
          of: find.byKey(CartKeys.total),
          matching: find.text(formatCurrency(32500)),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(CartKeys.checkout));
      await settle(tester);
      final page = tester.widget<CheckoutPage>(find.byType(CheckoutPage));
      expect(page.subtotal, 33000);
      expect(page.total, 32500);
      expect(page.customer?.id, 'cust-1');
      expect(page.cart.length, 3);
      await disposeScreen(tester);
    });
  });

  group('no overflow', () {
    setUp(
      () async => env = await setupScreenTestEnvironment(businessType: 'Bar'),
    );

    final cases =
        <
          String,
          ({
            Size size,
            EdgeInsets padding,
            TextScaler? scale,
            EdgeInsets keyboard,
          })
        >{
          '360x800 at 1.3x text': (
            size: const Size(360, 800),
            padding: const EdgeInsets.only(top: 24, bottom: 48),
            scale: const TextScaler.linear(1.3),
            keyboard: EdgeInsets.zero,
          ),
          '844x390 sideways with insets': (
            size: const Size(844, 390),
            padding: const EdgeInsets.only(top: 24, right: 48),
            scale: null,
            keyboard: EdgeInsets.zero,
          ),
          '844x390 sideways at 1.3x text': (
            size: const Size(844, 390),
            padding: const EdgeInsets.only(top: 24, right: 48),
            scale: const TextScaler.linear(1.3),
            keyboard: EdgeInsets.zero,
          ),
          '390x844 with the keyboard up': (
            size: const Size(390, 844),
            padding: const EdgeInsets.only(top: 24, bottom: 48),
            scale: null,
            keyboard: const EdgeInsets.only(bottom: 320),
          ),
        };

    cases.forEach((name, c) {
      testWidgets(name, (tester) async {
        await pumpCart(
          tester,
          size: c.size,
          padding: c.padding,
          textScaler: c.scale,
          viewInsets: c.keyboard,
          fill: fullFixture(customer: regular),
        );
        expectNoOverflow(tester, reason: 'Cart overflowed at $name');
        // Scroll to the end: the footer must lay out whole too.
        await tester.dragUntilVisible(
          find.byKey(CartKeys.checkout),
          find.byType(CustomScrollView).first,
          const Offset(0, -200),
        );
        await tester.pump();
        expectNoOverflow(tester, reason: 'Cart overflowed scrolled at $name');
        expectTextWhole(tester, find.text('Save Cart'), at: name);
        expectTextWhole(tester, find.text('Recall'), at: name);
        await disposeScreen(tester);
      });
    });
  });
}

/// Fills the cart after this widget's first frame (Riverpod forbids changing a
/// provider during build), then builds [child].
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
