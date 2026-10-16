// Visual goldens for the receiving flow after Receive Stock (#394 PR 2,
// PRD #346 Wave 2 A):
//
// - `receive_cart_{390x844,844x390_insets,800x1280,1280x800}_*`: two lines
//   (Star Lager ×12, Eva Water ×6), the "Cost" tag, the totals footer.
// - `receive_checkout_{…same sizes…}_*`: the invoice for those lines — total
//   card, store, supplier (required: Star Lager moves crates), date, note,
//   payment hidden (no supplier yet), items, the crate row, Confirm Receipt.
// - `receive_edit_item_{390x844,844x390}_*`: the Edit sheet over the cart.
// - `receive_supplier_picker_{390x844,844x390}_*`: the supplier picker over
//   the invoice.
//
// Light + dark. "Stallion Global" / "Abuja HQ". At 600dp+ the frame's rail is
// a blank strip (as the harness draws it); 844x390 carries a sideways
// phone's insets (top 24, right 48). Regenerate with:
//
//     flutter test --update-goldens test/redesign/receive_cart_checkout_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/receiving/screens/receive_cart_screen.dart';
import 'package:reebaplus_pos/features/receiving/screens/receive_checkout_screen.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/features/receiving/widgets/receive_parts.dart';

import '../helpers/screen_harness.dart';
import '../receiving/receive_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ReceiveFixture fx;

  setUp(() async => fx = await ReceiveFixture.create());
  tearDown(() => fx.env.dispose());

  // Sheet goldens capture the whole navigator, which the debug banner would
  // otherwise draw over.
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

  Future<void> open(
    WidgetTester tester, {
    required Widget screen,
    required Size size,
    required EdgeInsets padding,
    required Brightness brightness,
  }) async {
    await pumpScreen(
      tester,
      env: fx.env,
      size: size,
      padding: padding,
      screen: _Launcher(screen: screen),
      bottomNavHeight: size.width >= 600 ? kBottomNavBodyHeight : 0,
      grantedKeys: const {
        'stock.add',
        'products.add',
        'products.edit_price',
        'products.edit_buying_price',
        'suppliers.manage',
      },
      theme: brightness == Brightness.light
          ? AppTheme.light()
          : AppTheme.dark(),
      settle: false,
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(_Launcher)),
    );
    final notifier = container.read(receiveCartProvider.notifier);
    notifier.addOrIncrement(fx.products[0], amount: 12);
    notifier.addOrIncrement(fx.products[3], amount: 6);
    await settle(tester);
    await tester.tap(find.text('open'));
    await settle(tester);
  }

  const screens = <(String, Size, EdgeInsets)>[
    ('390x844', Size(390, 844), EdgeInsets.zero),
    ('844x390_insets', Size(844, 390), EdgeInsets.only(top: 24, right: 48)),
    ('800x1280', Size(800, 1280), EdgeInsets.zero),
    ('1280x800', Size(1280, 800), EdgeInsets.zero),
  ];
  const sheets = <(String, Size, EdgeInsets)>[
    ('390x844', Size(390, 844), EdgeInsets.zero),
    ('844x390', Size(844, 390), EdgeInsets.zero),
  ];

  for (final brightness in Brightness.values) {
    final theme = brightness == Brightness.light ? 'light' : 'dark';

    for (final (name, size, padding) in screens) {
      testWidgets('receive cart $name $theme', (tester) async {
        await open(
          tester,
          screen: const ReceiveCartScreen(),
          size: size,
          padding: padding,
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(ReceiveCartScreen),
          matchesGoldenFile('goldens/receive_cart_${name}_$theme.png'),
        );
        await disposeScreen(tester);
      });

      testWidgets('receive checkout $name $theme', (tester) async {
        await open(
          tester,
          screen: const ReceiveCheckoutScreen(),
          size: size,
          padding: padding,
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(ReceiveCheckoutScreen),
          matchesGoldenFile('goldens/receive_checkout_${name}_$theme.png'),
        );
        await disposeScreen(tester);
      });
    }

    for (final (name, size, padding) in sheets) {
      testWidgets('receive edit item sheet $name $theme', (tester) async {
        await open(
          tester,
          screen: const ReceiveCartScreen(),
          size: size,
          padding: padding,
          brightness: brightness,
        );
        await tester.tap(find.byKey(receiveCartLineKey(fx.productIds[0])));
        await tester.pumpAndSettle();
        // Drop the autofocus caret blink from the picture.
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(Navigator).first,
          matchesGoldenFile('goldens/receive_edit_item_${name}_$theme.png'),
        );
        await disposeScreen(tester);
      });

      testWidgets('receive supplier picker $name $theme', (tester) async {
        await open(
          tester,
          screen: const ReceiveCheckoutScreen(),
          size: size,
          padding: padding,
          brightness: brightness,
        );
        await tester.tap(find.byKey(ReceiveKeys.supplierField));
        await tester.pumpAndSettle();
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(Navigator).first,
          matchesGoldenFile(
            'goldens/receive_supplier_picker_${name}_$theme.png',
          ),
        );
        await disposeScreen(tester);
      });
    }
  }
}

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
