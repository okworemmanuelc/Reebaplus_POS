import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/features/pos/screens/cart_screen.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

/// Issue #255 / PRD #239 — the Cart screen must hold its content at every
/// supported viewport, with or without items in it.
///
/// Before the fix, on an emulator held sideways (800x360) with nothing in the
/// cart: a red "BOTTOM OVERFLOWED BY 15 PIXELS" band, and the Recall button cut
/// off beneath it. The customer card is fixed, and the empty-cart message under
/// it (icon, "Cart is empty", Recall) sat in a block that could not scroll, so
/// on a short phone it had nowhere to go.
///
/// Acceptance criteria covered here:
///   1. With an empty cart, no overflow at the smallest supported portrait
///      phone (320x568), the shortest supported landscape phone (800x360) and
///      a comfortable portrait control (412x915) — plus 915x412.
///   2. At each of those the Recall button is laid out in full and
///      hit-testable; the assertion may scroll first.
///   3. A cart with items still passes both assertions: no overflow, and at
///      least one complete cart line.
///   4. The customer card's Change button stays reachable in both states.
///   5. Unconditional — the same tests run at every size; nothing branches on
///      orientation or a short-viewport predicate.
///
/// ### Why the #241 sweep called Cart unaffected
///
/// The shared harness stands the bottom bar in with a bare 56dp box, and the
/// Scaffold still strips the 24dp bottom inset from the body — so the body is
/// handed 24dp the phone does not have. MainLayout's real bar is Material's
/// `BottomNavigationBar`, which is `56 + viewPadding.bottom` tall. Measured at
/// 800x360: 56dp leaves the empty block 14.6dp spare; the real 80dp overflows
/// it by 9.4px. Test fonts draw lines shorter than a device font, which is the
/// rest of the 15px the device showed. This suite therefore passes the bar's
/// real height ([_kRealBottomBarHeight]) rather than the harness default.
///
/// The harness default is left alone here: correcting it turns four tests in
/// other suites red (Inventory, POS, Supplier Detail), each its own slice.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

  Finder cartLines() => find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith(kCartLineKeyPrefix),
        description: 'cart line',
      );

  Finder recallButton() => find.widgetWithText(AppButton, 'Recall');

  Finder changeButton() => find.text('Change');

  /// The cart's one scrollable surface, below the fixed customer card.
  Finder cartSurface() => find.byType(CustomScrollView).first;

  /// Drift's stream plumbing resolves in real async time; step the clock by
  /// hand as the other viewport suites do rather than `pumpAndSettle`.
  Future<void> settleScreen(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  /// Unmounts the screen and closes the database inside `runAsync`, so Drift's
  /// stream cancellations get the real async time they need.
  Future<void> teardownScreen(WidgetTester tester) async {
    await disposeScreen(tester);
    await tester.runAsync(() => env.dispose());
  }

  Future<void> pumpCart(
    WidgetTester tester, {
    required Size size,
    bool hasItems = false,
    TextScaler? textScaler,
  }) async {
    final cart = CartScreen(cart: const [], onCustomerChanged: (_) {});
    await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: hasItems
          ? _PrefilledCart(products: env.products, child: cart)
          : cart,
      textScaler: textScaler,
      bottomNavHeight: _kRealBottomBarHeight,
      overrides: [
        firstRunSurfaceStateProvider
            .overrideWithValue(FirstRunSurfaceState.hasContent),
      ],
      settle: false,
    );
    await settleScreen(tester);
  }

  /// The customer card is how a cashier puts a sale on a customer's account;
  /// it must never be the thing that gets squeezed out.
  void expectChangeReachable(WidgetTester tester, {required String at}) {
    expect(
      visibleRowCount(tester, changeButton()),
      1,
      reason: 'The customer card\'s Change button was not laid out in full '
          'and hit-testable at $at',
    );
  }

  /// Scrolls [target] into view and asserts it then sits wholly inside
  /// whatever can clip it: the cart's scroll view, or — when the block does
  /// not scroll at all — the screen.
  ///
  /// [expectContentRowVisible] measures a row against the whole screen, not
  /// the scroll view that clips it, so it counts a Recall button whose centre
  /// is in view while its lower part is clipped behind the bottom bar — at
  /// 800x360 it does exactly that at rest. This closes the gap, as the Supplier
  /// Detail suite (#246) does. It does not require a scroll view to exist, so
  /// it judges the defect and not the shape of any one fix.
  Future<void> expectScrollsWhollyIntoView(
    WidgetTester tester,
    Finder target, {
    required String reason,
  }) async {
    await tester.ensureVisible(target);
    await tester.pump(const Duration(milliseconds: 250));
    final inner = tester.getRect(target);
    final outer = find.byType(CustomScrollView).evaluate().isEmpty
        ? Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio
        : tester.getRect(cartSurface());
    expect(
      inner.top >= outer.top - 0.5 &&
          inner.bottom <= outer.bottom + 0.5 &&
          inner.left >= outer.left - 0.5 &&
          inner.right <= outer.right + 0.5,
      isTrue,
      reason: '$reason (target $inner, surface $outer)',
    );
  }

  const viewports = <String, Size>{
    'phoneSe1Portrait (320x568, smallest supported portrait)': phoneSe1Portrait,
    'androidCompactLandscape (800x360, shortest supported landscape)':
        androidCompactLandscape,
    'pixel7Landscape (915x412, landscape phone)': pixel7Landscape,
    'pixel7Portrait (412x915, comfortable control)': pixel7Portrait,
  };

  group('Cart holds its content — empty', () {
    setUp(() async {
      env = await setupScreenTestEnvironment();
    });

    viewports.forEach((name, size) {
      testWidgets('$name shows the empty message and a whole Recall button',
          (tester) async {
        await pumpCart(tester, size: size);

        expectNoOverflow(tester, reason: 'Empty Cart overflowed at $name');
        expect(find.text('Cart is empty'), findsOneWidget);
        expectChangeReachable(tester, at: name);
        await expectContentRowVisible(
          tester,
          recallButton(),
          scrollable: cartSurface(),
          reason: 'Recall was not laid out in full and hit-testable at $name',
        );
        await expectScrollsWhollyIntoView(
          tester,
          recallButton(),
          reason: 'Recall could not be scrolled wholly into view at $name',
        );
        expectChangeReachable(tester, at: '$name, after scrolling');
        expectNoOverflow(
          tester,
          reason: 'Empty Cart overflowed while scrolling at $name',
        );

        await teardownScreen(tester);
      });
    });

    // The largest text size the app allows (main.dart clamps at 1.3). Test
    // fonts draw lines shorter than a device font does, so this is also the
    // margin that covers the gap between the harness and a real phone.
    for (final entry in {
      'phoneSe1Portrait': phoneSe1Portrait,
      'androidCompactLandscape': androidCompactLandscape,
    }.entries) {
      testWidgets('${entry.key} at 1.3x text keeps Recall reachable',
          (tester) async {
        await pumpCart(
          tester,
          size: entry.value,
          textScaler: const TextScaler.linear(1.3),
        );

        expectNoOverflow(
          tester,
          reason: 'Empty Cart overflowed at ${entry.key}, 1.3x text',
        );
        expectChangeReachable(tester, at: '${entry.key}, 1.3x text');
        await expectContentRowVisible(
          tester,
          recallButton(),
          scrollable: cartSurface(),
          reason: 'Recall was not reachable at ${entry.key}, 1.3x text',
        );
        await expectScrollsWhollyIntoView(
          tester,
          recallButton(),
          reason: 'Recall could not be scrolled wholly into view at '
              '${entry.key}, 1.3x text',
        );

        await teardownScreen(tester);
      });
    }

    testWidgets('Recall opens the saved carts sheet from an empty cart',
        (tester) async {
      await pumpCart(tester, size: androidCompactLandscape);

      await expectScrollsWhollyIntoView(
        tester,
        recallButton(),
        reason: 'Recall could not be scrolled wholly into view',
      );
      await tester.tap(recallButton());
      await settleScreen(tester);

      expect(find.text('Saved Carts'), findsOneWidget);

      await teardownScreen(tester);
    });
  });

  group('Cart holds its content — with items', () {
    setUp(() async {
      env = await setupScreenTestEnvironment();
    });

    viewports.forEach((name, size) {
      testWidgets('$name shows a complete cart line without overflowing',
          (tester) async {
        await pumpCart(tester, size: size, hasItems: true);

        expectNoOverflow(tester, reason: 'Cart with items overflowed at $name');
        expectChangeReachable(tester, at: name);
        await expectContentRowVisible(
          tester,
          cartLines(),
          scrollable: cartSurface(),
          reason: 'Cart showed no complete line at $name',
        );
        await expectScrollsWhollyIntoView(
          tester,
          cartLines().first,
          reason: 'No cart line could be scrolled wholly into view at $name',
        );
        expectChangeReachable(tester, at: '$name, after scrolling');
        expectNoOverflow(
          tester,
          reason: 'Cart with items overflowed while scrolling at $name',
        );

        await teardownScreen(tester);
      });
    });
  });
}

/// MainLayout's bar is Material's `BottomNavigationBar`: 56dp plus the
/// phone's bottom inset, which the harness models as [kRealisticPhoneInsets].
final double _kRealBottomBarHeight =
    kBottomNavBodyHeight + kRealisticPhoneInsets.bottom;

/// Puts [products] in the cart before [child] first builds, as on a phone when
/// the cashier opens Cart after ringing items up on POS. Filling it after
/// [child]'s first frame would lay the empty cart out first and blame its
/// overflow on the with-items state.
///
/// The fill runs after this widget's own first frame because Riverpod forbids
/// modifying a provider while the tree is building; [child] is not built until
/// it has run.
class _PrefilledCart extends ConsumerStatefulWidget {
  final List<ProductData> products;
  final Widget child;

  const _PrefilledCart({required this.products, required this.child});

  @override
  ConsumerState<_PrefilledCart> createState() => _PrefilledCartState();
}

class _PrefilledCartState extends ConsumerState<_PrefilledCart> {
  bool _isFilled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final cart = ref.read(cartProvider);
      for (final product in widget.products) {
        cart.addItem(product, qty: 2);
      }
      setState(() => _isFilled = true);
    });
  }

  @override
  Widget build(BuildContext context) =>
      _isFilled ? widget.child : const SizedBox.shrink();
}
