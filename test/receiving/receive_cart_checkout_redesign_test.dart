// #394 PR 2 (PRD #346 Wave 2 A): the receive cart, the Edit Receive Item
// sheet, Receive Checkout and its supplier picker, restyled.
//
// Each renders its controls with today's wording, the main actions still work
// (edit, swipe-remove, clear, continue, pick / clear a supplier), the
// permission-hidden controls stay hidden, the content caps at 720dp (sheets at
// 640dp) on wide screens, and nothing overflows at the sizes the app runs at,
// keyboard up included.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/receiving/screens/receive_cart_screen.dart';
import 'package:reebaplus_pos/features/receiving/screens/receive_checkout_screen.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/features/receiving/widgets/receive_parts.dart';
import 'package:reebaplus_pos/features/receiving/widgets/uncosted_receive_warning.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/cart_line.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/stat_card.dart';

import '../helpers/screen_harness.dart';
import 'receive_fixture.dart';

const _ceoKeys = {
  'stock.add',
  'products.add',
  'products.edit_price',
  'products.edit_buying_price',
  'suppliers.manage',
};

const _upright = EdgeInsets.only(top: 24, bottom: 48);
const _sideways = EdgeInsets.only(top: 24, right: 48);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ReceiveFixture fx;

  setUp(() async => fx = await ReceiveFixture.create());
  tearDown(() => fx.env.dispose());

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Pushes [screen] from a launcher page (so back / pop work) with
  /// [lines] (product index → quantity) on the receive cart.
  Future<ProviderContainer> open(
    WidgetTester tester, {
    required Widget screen,
    Map<int, int> lines = const {0: 12, 3: 6},
    Size size = const Size(390, 844),
    EdgeInsets padding = _upright,
    EdgeInsets viewInsets = EdgeInsets.zero,
    Set<String> keys = _ceoKeys,
    TextScaler? textScaler,
    int zeroCostLine = -1,
  }) async {
    await pumpScreen(
      tester,
      env: fx.env,
      size: size,
      padding: padding,
      viewInsets: viewInsets,
      textScaler: textScaler,
      screen: _Launcher(screen: screen),
      bottomNavHeight: 0,
      grantedKeys: keys,
      theme: AppTheme.light(),
      settle: false,
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(_Launcher)),
    );
    final notifier = container.read(receiveCartProvider.notifier);
    for (final MapEntry(key: i, value: qty) in lines.entries) {
      notifier.addOrIncrement(fx.products[i], amount: qty);
      if (i == zeroCostLine) notifier.setBuyingPrice(fx.productIds[i], 0);
    }
    await settle(tester);
    await tester.tap(find.text('open'));
    await settle(tester);
    return container;
  }

  int qtyOf(ProviderContainer c, int i) =>
      c
          .read(receiveCartProvider)
          .where((l) => l.productId == fx.productIds[i])
          .firstOrNull
          ?.qty ??
      0;

  group('receive cart', () {
    testWidgets('renders lines, totals and actions with today\'s wording', (
      tester,
    ) async {
      await open(tester, screen: const ReceiveCartScreen());
      expect(find.text('Receive Stock Cart'), findsOneWidget);
      expect(find.text('2 items'), findsOneWidget);
      expect(find.byKey(ReceiveKeys.clear), findsOneWidget);
      expect(find.byType(CartLine), findsNWidgets(2));
      // No stepper: quantities change in the Edit sheet, as before.
      expect(find.byType(QuantityStepper), findsNothing);
      expect(find.text('Star Lager'), findsOneWidget);
      expect(find.text('12 × ₦7,500'), findsOneWidget);
      expect(find.text('Cost: ₦7,500'), findsNWidgets(2));
      expect(
        find.text('Bottle Crate · Ret: ₦9,600 • Whls: ₦9,000'),
        findsNWidgets(2),
      );
      expect(find.text('Invoice Total:'), findsOneWidget);
      // 18 × ₦7,500 = ₦135,000.
      expect(find.text('₦135,000'), findsOneWidget);
      expect(find.text('Continue (18 items)'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });

    testWidgets('tap a line → Edit sheet; Save changes the quantity', (
      tester,
    ) async {
      final c = await open(tester, screen: const ReceiveCartScreen());
      await tester.tap(find.byKey(receiveCartLineKey(fx.productIds[0])));
      await tester.pumpAndSettle();
      expect(find.byKey(ReceiveKeys.editSheet), findsOneWidget);
      expect(find.text('Edit Quantity & Prices'), findsOneWidget);
      await tester.tap(find.byKey(ReceiveKeys.editPlus));
      await tester.pump();
      await tester.tap(find.text('Save Changes'));
      await tester.pumpAndSettle();
      expect(qtyOf(c, 0), 13);
      expect(find.text('13 × ₦7,500'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('Edit sheet Remove drops the line; ✕ closes it', (
      tester,
    ) async {
      final c = await open(tester, screen: const ReceiveCartScreen());
      await tester.tap(find.byKey(receiveCartLineKey(fx.productIds[3])));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ReceiveKeys.editClose));
      await tester.pumpAndSettle();
      expect(find.byKey(ReceiveKeys.editSheet), findsNothing);
      expect(qtyOf(c, 3), 6);
      await tester.tap(find.byKey(receiveCartLineKey(fx.productIds[3])));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(qtyOf(c, 3), 0);
      expect(find.byType(CartLine), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('swipe left removes a line', (tester) async {
      final c = await open(tester, screen: const ReceiveCartScreen());
      await tester.drag(
        find.byKey(receiveCartLineKey(fx.productIds[0])),
        const Offset(-500, 0),
      );
      await tester.pumpAndSettle();
      expect(qtyOf(c, 0), 0);
      await disposeScreen(tester);
    });

    testWidgets('Clear asks, then empties the cart and goes back', (
      tester,
    ) async {
      final c = await open(tester, screen: const ReceiveCartScreen());
      await tester.tap(find.byKey(ReceiveKeys.clear));
      await tester.pumpAndSettle();
      expect(
        find.text('Are you sure you want to remove all items from the cart?'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(c.read(receiveCartProvider), hasLength(2));
      await tester.tap(find.byKey(ReceiveKeys.clear));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear').last);
      await tester.pumpAndSettle();
      expect(c.read(receiveCartProvider), isEmpty);
      expect(find.byType(ReceiveCartScreen), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('empty: the message, no Clear, no footer', (tester) async {
      await open(tester, screen: const ReceiveCartScreen(), lines: const {});
      expect(find.text('Your receive cart is empty'), findsOneWidget);
      expect(
        find.text('Tap products from the grid to add them.'),
        findsOneWidget,
      );
      expect(find.byKey(ReceiveKeys.clear), findsNothing);
      expect(find.byKey(ReceiveKeys.cartFooter), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('Continue opens the invoice', (tester) async {
      await open(tester, screen: const ReceiveCartScreen());
      await tester.tap(find.byKey(ReceiveKeys.continueButton));
      await tester.pumpAndSettle();
      expect(find.byType(ReceiveCheckoutScreen), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('Edit sheet without price keys: price fields are locked', (
      tester,
    ) async {
      await open(
        tester,
        screen: const ReceiveCartScreen(),
        keys: const {'stock.add'},
      );
      await tester.tap(find.byKey(receiveCartLineKey(fx.productIds[0])));
      await tester.pumpAndSettle();
      final fields = tester
          .widgetList<TextField>(
            find.descendant(
              of: find.byKey(ReceiveKeys.editSheet),
              matching: find.byType(TextField),
            ),
          )
          .toList();
      // Quantity is editable; cost, retail and wholesale are not.
      expect(fields.first.enabled, isNot(false));
      expect(fields.skip(1).every((f) => f.enabled == false), isTrue);
      await disposeScreen(tester);
    });

    group('layout', () {
      for (final (name, size, padding, scale) in [
        ('360 @1.3', const Size(360, 780), _upright, 1.3),
        ('390x844', const Size(390, 844), _upright, 1.0),
        ('844x390 insets', const Size(844, 390), _sideways, 1.0),
        ('844x390 insets @1.3', const Size(844, 390), _sideways, 1.3),
        ('800x1280', const Size(800, 1280), _upright, 1.0),
        ('1280x800', const Size(1280, 800), EdgeInsets.zero, 1.0),
      ]) {
        testWidgets('cart, no overflow, content ≤ 720dp: $name', (
          tester,
        ) async {
          await open(
            tester,
            screen: const ReceiveCartScreen(),
            size: size,
            padding: padding,
            textScaler: TextScaler.linear(scale),
          );
          expect(tester.takeException(), isNull);
          final line = tester.getRect(
            find.byKey(receiveCartLineKey(fx.productIds[0])),
          );
          expect(line.width, lessThanOrEqualTo(720));
          // The Continue button is reachable.
          await tester.ensureVisible(find.byKey(ReceiveKeys.continueButton));
          await tester.pump();
          expect(tester.takeException(), isNull);
          await disposeScreen(tester);
        });
      }

      for (final (name, size, padding) in [
        ('390x844', const Size(390, 844), _upright),
        ('844x390 insets', const Size(844, 390), _sideways),
      ]) {
        testWidgets('edit sheet, keyboard up: $name', (tester) async {
          await open(
            tester,
            screen: const ReceiveCartScreen(),
            size: size,
            padding: padding,
            viewInsets: const EdgeInsets.only(bottom: 300),
          );
          await tester.tap(find.byKey(receiveCartLineKey(fx.productIds[0])));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(find.text('Save Changes'));
          await tester.pump();
          expect(tester.takeException(), isNull);
          await disposeScreen(tester);
        });
      }

      testWidgets('edit sheet caps at 640dp on a wide screen', (tester) async {
        await open(
          tester,
          screen: const ReceiveCartScreen(),
          size: const Size(1280, 800),
          padding: EdgeInsets.zero,
        );
        await tester.tap(find.byKey(receiveCartLineKey(fx.productIds[0])));
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byKey(ReceiveKeys.editSheet)).width,
          lessThanOrEqualTo(640),
        );
        await disposeScreen(tester);
      });
    });
  });

  group('receive checkout', () {
    testWidgets('renders the invoice with today\'s labels; no supplier needed '
        'without crates', (tester) async {
      await open(
        tester,
        screen: const ReceiveCheckoutScreen(),
        lines: const {3: 6},
      );
      expect(find.text('Invoice'), findsOneWidget);
      expect(find.byType(StatCard), findsOneWidget);
      expect(find.text('Invoice Total'), findsOneWidget);
      expect(find.text('₦45,000'), findsWidgets);
      expect(find.text('6 units • 1 products'), findsOneWidget);
      expect(find.text('STOCKING INTO *'), findsOneWidget);
      expect(find.text('SUPPLIER (optional)'), findsOneWidget);
      expect(find.text('Select supplier'), findsOneWidget);
      expect(find.text('DATE RECEIVED'), findsOneWidget);
      expect(find.text('Reference Note (Optional)'), findsOneWidget);
      expect(find.text('ITEMS'), findsOneWidget);
      expect(find.text('CRATES WITH THIS DELIVERY'), findsNothing);
      expect(find.byType(UncostedReceiveWarning), findsNothing);
      expect(find.byKey(ReceiveKeys.confirmButton), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('a crate line needs a supplier and shows the crate row', (
      tester,
    ) async {
      await open(tester, screen: const ReceiveCheckoutScreen());
      expect(find.text('SUPPLIER *'), findsOneWidget);
      await tester.ensureVisible(find.text('CRATES WITH THIS DELIVERY'));
      await tester.pump();
      expect(find.text('Nigerian Breweries'), findsOneWidget);
      expect(find.text('12 drinks on this delivery'), findsOneWidget);
      expect(find.text('Full crates in'), findsOneWidget);
      expect(find.text('Empty crates back'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('uncosted line: the warning shows under the total', (
      tester,
    ) async {
      await open(
        tester,
        screen: const ReceiveCheckoutScreen(),
        lines: const {3: 6},
        zeroCostLine: 3,
      );
      expect(find.byType(UncostedReceiveWarning), findsOneWidget);
      expect(find.text('1 item has no buying price'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('supplier picker: card rows, pick, payment shows; clear ✕ '
        'hides it', (tester) async {
      await open(
        tester,
        screen: const ReceiveCheckoutScreen(),
        lines: const {3: 6},
      );
      await tester.tap(find.byKey(ReceiveKeys.supplierField));
      await tester.pumpAndSettle();
      expect(find.byKey(ReceiveKeys.supplierSheet), findsOneWidget);
      expect(find.text('Add Supplier'), findsOneWidget);
      await tester.tap(find.byKey(receiveSupplierRowKey(fx.supplierId)));
      await tester.pumpAndSettle();
      expect(find.text('Lagos Beverages Ltd'), findsOneWidget);
      expect(find.text('Amount Paid Now'), findsOneWidget);
      expect(find.byKey(ReceiveKeys.paymentMethod), findsOneWidget);
      final clear = tester.getSize(find.byKey(ReceiveKeys.supplierClear));
      expect(clear.width, greaterThanOrEqualTo(kMinInteractiveDimension));
      expect(clear.height, greaterThanOrEqualTo(kMinInteractiveDimension));
      await tester.tap(find.byKey(ReceiveKeys.supplierClear));
      await tester.pumpAndSettle();
      expect(find.text('Select supplier'), findsOneWidget);
      expect(find.text('Amount Paid Now'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('without suppliers.manage: no Add Supplier, no payment', (
      tester,
    ) async {
      await open(
        tester,
        screen: const ReceiveCheckoutScreen(),
        lines: const {3: 6},
        keys: const {'stock.add'},
      );
      await tester.tap(find.byKey(ReceiveKeys.supplierField));
      await tester.pumpAndSettle();
      expect(find.text('Add Supplier'), findsNothing);
      await tester.tap(find.byKey(receiveSupplierRowKey(fx.supplierId)));
      await tester.pumpAndSettle();
      expect(find.text('Amount Paid Now'), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('Confirm Receipt asks first (dialog wording unchanged)', (
      tester,
    ) async {
      await open(
        tester,
        screen: const ReceiveCheckoutScreen(),
        lines: const {3: 6},
      );
      await tester.tap(find.byKey(ReceiveKeys.confirmButton));
      await tester.pumpAndSettle();
      expect(find.text('Confirm Receipt'), findsWidgets);
      expect(find.text('None (cash purchase)'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await disposeScreen(tester);
    });

    group('layout', () {
      for (final (name, size, padding, scale, keyboard) in [
        ('360 @1.3', const Size(360, 780), _upright, 1.3, false),
        ('390x844', const Size(390, 844), _upright, 1.0, false),
        ('390x844 keyboard up', const Size(390, 844), _upright, 1.0, true),
        ('844x390 insets', const Size(844, 390), _sideways, 1.0, false),
        ('844x390 keyboard up', const Size(844, 390), _sideways, 1.0, true),
        ('800x1280', const Size(800, 1280), _upright, 1.0, false),
        ('1280x800', const Size(1280, 800), EdgeInsets.zero, 1.0, false),
      ]) {
        testWidgets('checkout, no overflow, form ≤ 720dp: $name', (
          tester,
        ) async {
          await open(
            tester,
            screen: const ReceiveCheckoutScreen(),
            size: size,
            padding: padding,
            textScaler: TextScaler.linear(scale),
            viewInsets: keyboard
                ? const EdgeInsets.only(bottom: 300)
                : EdgeInsets.zero,
          );
          expect(tester.takeException(), isNull);
          expect(
            tester.getSize(find.byKey(ReceiveKeys.supplierField)).width,
            lessThanOrEqualTo(720),
          );
          // Every field can be reached.
          for (final label in ['Reference Note (Optional)', 'Full crates in']) {
            await tester.ensureVisible(find.text(label));
            await tester.pump();
          }
          expect(tester.takeException(), isNull);
          await disposeScreen(tester);
        });
      }

      testWidgets('supplier picker caps at 640dp on a wide screen', (
        tester,
      ) async {
        await open(
          tester,
          screen: const ReceiveCheckoutScreen(),
          size: const Size(1280, 800),
          padding: EdgeInsets.zero,
        );
        await tester.tap(find.byKey(ReceiveKeys.supplierField));
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byKey(ReceiveKeys.supplierSheet)).width,
          lessThanOrEqualTo(640),
        );
        await disposeScreen(tester);
      });
    });
  });
}

/// A page with an "open" button that pushes [screen], so the screen has a
/// route to go back to (Clear pops, as from Receive Stock).
class _Launcher extends StatelessWidget {
  const _Launcher({required this.screen});

  final Widget screen;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => screen)),
          child: const Text('open'),
        ),
      ),
    );
  }
}
