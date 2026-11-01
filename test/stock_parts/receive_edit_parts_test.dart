// The Edit Receive Item sheet in parts (#630): a product with its parts switch
// on takes a quarter and shows the decimal; a switched-off product takes whole
// numbers only.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/receiving/screens/receive_cart_screen.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/features/receiving/widgets/receive_parts.dart';

import '../helpers/screen_harness.dart';
import '../receiving/receive_fixture.dart';

const _keys = {
  'stock.add',
  'products.add',
  'products.edit_price',
  'products.edit_buying_price',
  'suppliers.manage',
};

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

  Future<ProviderContainer> open(
    WidgetTester tester, {
    required bool parts,
  }) async {
    await pumpScreen(
      tester,
      env: fx.env,
      size: const Size(390, 844),
      padding: const EdgeInsets.only(top: 24, bottom: 48),
      screen: const ReceiveCartScreen(),
      bottomNavHeight: 0,
      grantedKeys: _keys,
      theme: AppTheme.light(),
      settle: false,
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReceiveCartScreen)),
    );
    final product = fx.products[0].copyWith(allowFractionalSales: parts);
    container.read(receiveCartProvider.notifier).addOrIncrement(product);
    await settle(tester);
    await tester.tap(find.byKey(receiveCartLineKey(fx.productIds[0])));
    await tester.pumpAndSettle();
    expect(find.byKey(ReceiveKeys.editSheet), findsOneWidget);
    return container;
  }

  double qtyOf(ProviderContainer c) => c.read(receiveCartProvider).single.qty;

  testWidgets('switch on: typing 1.5 saves a part and the line shows it', (
    tester,
  ) async {
    final c = await open(tester, parts: true);
    await tester.enterText(find.byType(TextField).first, '1.5');
    await tester.pump();
    await tester.tap(find.text('Save Changes'));
    await tester.pumpAndSettle();
    expect(qtyOf(c), 1.5);
    // 1.5 x N7,500 = N11,250
    expect(find.text('1.5 × ₦7,500'), findsOneWidget);
    expect(find.text('₦11,250'), findsWidgets);
    await disposeScreen(tester);
  });

  testWidgets('switch on: a quarter that is not a quarter is refused', (
    tester,
  ) async {
    final c = await open(tester, parts: true);
    await tester.enterText(find.byType(TextField).first, '1.3');
    await tester.pump();
    await tester.tap(find.text('Save Changes'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(qtyOf(c), 1.0);
    expect(find.byKey(ReceiveKeys.editSheet), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await disposeScreen(tester);
  });

  testWidgets('switch off: the dot is filtered, so only whole numbers go in', (
    tester,
  ) async {
    final c = await open(tester, parts: false);
    await tester.enterText(find.byType(TextField).first, '2.5');
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      '25',
    );
    await tester.tap(find.text('Save Changes'));
    await tester.pumpAndSettle();
    expect(qtyOf(c), 25);
    await disposeScreen(tester);
  });

  testWidgets('whole numbers still step by one with + and −', (tester) async {
    final c = await open(tester, parts: true);
    await tester.tap(find.byKey(ReceiveKeys.editPlus));
    await tester.pump();
    await tester.tap(find.text('Save Changes'));
    await tester.pumpAndSettle();
    expect(qtyOf(c), 2);
    expect(find.text('2 × ₦7,500'), findsOneWidget);
    await disposeScreen(tester);
  });
}
