// #394 (PRD #346 Wave 2 A): Receive Stock restyle + fly-to-cart.
//
// The screen renders its controls, each action still works (tap adds, hold
// edits, out of stock still adds, search, category filter, review bar), the
// permission-hidden controls stay hidden for a stock keeper, the new
// fly-to-cart flies to "Review Items" (and never under reduced motion), and
// nothing overflows at the sizes the app runs at.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/inventory/screens/add_product_screen.dart';
import 'package:reebaplus_pos/features/receiving/screens/receive_cart_screen.dart';
import 'package:reebaplus_pos/features/receiving/screens/receive_stock_screen.dart';
import 'package:reebaplus_pos/features/receiving/widgets/receive_parts.dart';
import 'package:reebaplus_pos/features/receiving/widgets/receive_product_grid.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/product_tile.dart';

import '../helpers/screen_harness.dart';
import 'receive_fixture.dart';

const _ceoKeys = {
  'stock.add',
  'products.add',
  'products.edit_price',
  'products.edit_buying_price',
  'suppliers.manage',
};

const _sidewaysInsets = EdgeInsets.only(top: 24, right: 48);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ReceiveFixture fx;

  setUp(() async => fx = await ReceiveFixture.create());
  tearDown(() => fx.env.dispose());

  final particle = find.byKey(const Key('fly-to-cart-particle'));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    EdgeInsets padding = const EdgeInsets.only(top: 24, bottom: 48),
    EdgeInsets viewInsets = EdgeInsets.zero,
    Set<String> keys = _ceoKeys,
    TextScaler? textScaler,
    bool reducedMotion = false,
  }) async {
    await pumpScreen(
      tester,
      env: fx.env,
      size: size,
      padding: padding,
      viewInsets: viewInsets,
      textScaler: textScaler,
      screen: reducedMotion
          ? Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: const ReceiveStockScreen(),
              ),
            )
          : const ReceiveStockScreen(),
      bottomNavHeight: 0,
      grantedKeys: keys,
      theme: AppTheme.light(),
      settle: false,
    );
    await settle(tester);
  }

  Finder tile(int i) => find.byKey(receiveProductTileKey(fx.productIds[i]));

  /// Scrolls tile [i] into view (clear of the "Review Items" bar), then taps.
  Future<void> tapTile(WidgetTester tester, int i) async {
    await tester.ensureVisible(tile(i));
    await tester.pump();
    await tester.tap(tile(i));
  }

  testWidgets('renders the top bar, search toggle, chips, New Product '
      'and the tiles with today\'s content', (tester) async {
    await open(tester);
    expect(find.text('Receive Stock'), findsOneWidget);
    expect(find.text('Abuja HQ'), findsOneWidget);
    expect(find.byKey(ReceiveKeys.searchToggle), findsOneWidget);
    expect(find.byKey(ReceiveKeys.search), findsNothing);
    for (final chip in ['All', 'Beer', 'Malt', 'Water', 'Stout']) {
      expect(find.text(chip), findsWidgets);
    }
    // No "tap and hold to edit" tip any more (#487 PR 4).
    expect(find.text('Tap and hold a product to edit it.'), findsNothing);
    expect(find.byKey(ReceiveKeys.newProduct), findsOneWidget);
    expect(find.text('New Product'), findsOneWidget);
    // Name, "size · unit" (the crate size and unit, as before), "Current: N"
    // — no price.
    expect(find.text('Star Lager'), findsOneWidget);
    expect(find.text('big · Bottle'), findsWidgets);
    expect(find.text('Can'), findsOneWidget);
    expect(find.text('Current: 48'), findsOneWidget);
    expect(find.textContaining('₦'), findsNothing);
    // No lines yet → no review bar.
    expect(find.byKey(ReceiveKeys.reviewBar), findsNothing);
    expect(tester.takeException(), isNull);
    await disposeScreen(tester);
  });

  testWidgets('an archived product is not offered for receiving (#487)', (
    tester,
  ) async {
    await fx.env.db.catalogDao.setProductArchived(fx.productIds[0], true);
    await open(tester);
    expect(tile(0), findsNothing);
    expect(find.text('Star Lager'), findsNothing);
    expect(tile(1), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('tap adds one (badge + review bar) and flies to "Review Items"', (
    tester,
  ) async {
    await open(tester);
    await tapTile(tester, 0);
    await tester.pump(); // the add + the bar appear
    await tester.pump(); // post-frame launch
    expect(find.byKey(ReceiveKeys.reviewBar), findsOneWidget);
    expect(find.text('Review Items (1)'), findsOneWidget);
    expect(particle, findsOneWidget, reason: 'the first add flies too');
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 610));
    final end = tester.getCenter(particle);
    final target = tester.getCenter(find.byKey(ReceiveKeys.reviewBar));
    expect((end - target).distance, lessThan(12));
    await tester.pump(const Duration(milliseconds: 700));
    expect(particle, findsNothing, reason: 'it lands and goes away');

    await tapTile(tester, 0);
    await tester.pump();
    final badge = find.descendant(of: tile(0), matching: find.text('2'));
    expect(badge, findsOneWidget);
    expect(fx.cartQty(tester, 0), 2);
    await tester.pump(const Duration(seconds: 1));
    await disposeScreen(tester);
  });

  testWidgets('a second tap on the same tile replaces its flight', (
    tester,
  ) async {
    await open(tester);
    await tapTile(tester, 0);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tapTile(tester, 0);
    await tester.pump();
    await tester.pump();
    expect(particle, findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await disposeScreen(tester);
  });

  testWidgets('a tile that unmounts mid-flight cancels its flight', (
    tester,
  ) async {
    await open(tester);
    await tapTile(tester, 3); // Eva Water
    await tester.pump();
    await tester.pump();
    expect(particle, findsOneWidget);
    // Search Eva Water away: its tile is disposed.
    await tester.tap(find.byKey(ReceiveKeys.searchToggle));
    await tester.pump();
    await tester.enterText(find.byKey(ReceiveKeys.search), 'malta');
    await tester.pump();
    await tester.pump();
    expect(tile(3), findsNothing);
    expect(particle, findsNothing);
    expect(tester.takeException(), isNull);
    await disposeScreen(tester);
  });

  testWidgets('reduced motion: the add happens, nothing flies', (tester) async {
    await open(tester, reducedMotion: true);
    await tapTile(tester, 0);
    await tester.pump();
    await tester.pump();
    expect(find.text('Review Items (1)'), findsOneWidget);
    expect(particle, findsNothing);
    await disposeScreen(tester);
  });

  testWidgets('out of stock is still tappable: it adds, not dimmed', (
    tester,
  ) async {
    await open(tester);
    final hero = tile(4);
    await tester.ensureVisible(hero);
    await tester.pump();
    expect(
      find.descendant(of: hero, matching: find.text('No stock')),
      findsOneWidget,
    );
    expect(find.text('Out of stock'), findsNothing);
    await tester.tap(hero);
    await tester.pump();
    expect(fx.cartQty(tester, 4), 1);
    await tester.pump(const Duration(seconds: 1));
    await disposeScreen(tester);
  });

  testWidgets('a hold opens no editor (no long-press edit)', (tester) async {
    await open(tester);
    await tester.ensureVisible(tile(0));
    await tester.pump();
    await tester.longPress(tile(0));
    await tester.pumpAndSettle();
    expect(find.byType(AddProductScreen), findsNothing);
    await disposeScreen(tester);
  });

  testWidgets('stock keeper (stock.add only): no New Product; tap still '
      'adds', (tester) async {
    await open(tester, keys: const {'stock.add'});
    expect(find.byKey(ReceiveKeys.newProduct), findsNothing);
    await tapTile(tester, 0);
    await tester.pump();
    expect(fx.cartQty(tester, 0), 1);
    // Let the flight run out.
    await tester.pump(const Duration(seconds: 6));
    await disposeScreen(tester);
  });

  testWidgets('no receive key: the screen is blocked', (tester) async {
    await open(tester, keys: const {'sales.make'});
    expect(find.byType(ProductTile), findsNothing);
    expect(find.byKey(ReceiveKeys.searchToggle), findsNothing);
    await disposeScreen(tester);
  });

  testWidgets(
    'search toggle opens the field, filters, and closes clearing it',
    (tester) async {
      await open(tester);
      // Opened while scrolled down, the field still comes into view.
      await tester.ensureVisible(tile(0));
      await tester.pump();
      await tester.tap(find.byKey(ReceiveKeys.searchToggle));
      await tester.pump();
      expect(find.byKey(ReceiveKeys.search), findsOneWidget);
      expect(
        tester.getRect(find.byKey(ReceiveKeys.search)).top,
        greaterThan(0),
      );
      await tester.enterText(find.byKey(ReceiveKeys.search), 'eva');
      await tester.pump();
      expect(find.text('Eva Water'), findsOneWidget);
      expect(find.text('Star Lager'), findsNothing);
      await tester.tap(find.byKey(ReceiveKeys.searchToggle));
      await tester.pump();
      expect(find.byKey(ReceiveKeys.search), findsNothing);
      expect(find.text('Star Lager'), findsOneWidget);
      await disposeScreen(tester);
    },
  );

  testWidgets('category chip filters; a deleted chosen category falls back to '
      'All instead of throwing', (tester) async {
    await open(tester);
    await tester.tap(find.text('Malt').first);
    await tester.pump();
    expect(find.text('Malta Guinness'), findsOneWidget);
    expect(find.text('Star Lager'), findsNothing);

    await tester.runAsync(() => fx.deleteCategory('Malt'));
    await settle(tester);
    expect(tester.takeException(), isNull);
    // Back to every product (the first row shows Eva Water again).
    expect(find.text('Eva Water'), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('Review Items opens the receive cart', (tester) async {
    await open(tester);
    await tapTile(tester, 0);
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(ReceiveKeys.reviewBar));
    await tester.pumpAndSettle();
    expect(find.byType(ReceiveCartScreen), findsOneWidget);
    await disposeScreen(tester);
  });

  group('layout', () {
    Future<void> check(
      WidgetTester tester, {
      required Size size,
      required EdgeInsets padding,
      TextScaler? textScaler,
      EdgeInsets viewInsets = EdgeInsets.zero,
      bool search = false,
      int columns = 0,
    }) async {
      await open(tester, size: size, padding: padding, textScaler: textScaler);
      await tapTile(tester, 0);
      await tester.pump(const Duration(seconds: 1));
      if (search) {
        await tester.tap(find.byKey(ReceiveKeys.searchToggle));
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
      if (columns > 0) {
        final ys = <double>{};
        final row = [
          for (var i = 0; i < fx.productIds.length; i++)
            if (tile(i).evaluate().isNotEmpty) tester.getTopLeft(tile(i)),
        ];
        final firstRowY = tester
            .getTopLeft(find.byKey(ReceiveKeys.newProduct))
            .dy;
        for (final p in row) {
          if ((p.dy - firstRowY).abs() < 1) ys.add(p.dx);
        }
        // New Product + the tiles beside it.
        expect(ys.length + 1, columns);
      }
      await disposeScreen(tester);
    }

    testWidgets('360dp @1.3', (tester) async {
      await check(
        tester,
        size: const Size(360, 780),
        padding: const EdgeInsets.only(top: 24, bottom: 48),
        textScaler: const TextScaler.linear(1.3),
        columns: 2,
      );
    });

    testWidgets('390x844, 3-button nav', (tester) async {
      await check(
        tester,
        size: const Size(390, 844),
        padding: const EdgeInsets.only(top: 24, bottom: 48),
        columns: 2,
      );
    });

    testWidgets('390x844, gesture nav, search open', (tester) async {
      await check(
        tester,
        size: const Size(390, 844),
        padding: const EdgeInsets.only(top: 24, bottom: 24),
        search: true,
      );
    });

    testWidgets('844x390 sideways with insets: the chrome scrolls away and a '
        'whole row of tiles fits above the review bar', (tester) async {
      await open(tester, size: const Size(844, 390), padding: _sidewaysInsets);
      await tapTile(tester, 0);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      // Scroll the chips and the hint away: the first row then shows whole
      // between the top bar and the "Review Items" bar.
      await tester.drag(find.byKey(ReceiveKeys.scroll), const Offset(0, -150));
      await tester.pump();
      final viewport = tester.getRect(find.byKey(ReceiveKeys.scroll));
      final first = tester.getRect(find.byKey(ReceiveKeys.newProduct));
      final bar = tester.getRect(find.byKey(ReceiveKeys.reviewBar));
      expect(first.height, lessThanOrEqualTo(viewport.height));
      expect(viewport.bottom, lessThanOrEqualTo(bar.top + 1));
      await disposeScreen(tester);
    });

    testWidgets('844x390 sideways @1.3', (tester) async {
      await check(
        tester,
        size: const Size(844, 390),
        padding: _sidewaysInsets,
        textScaler: const TextScaler.linear(1.3),
      );
    });

    testWidgets('800x1280: 4 columns', (tester) async {
      await check(
        tester,
        size: const Size(800, 1280),
        padding: const EdgeInsets.only(top: 24, bottom: 48),
        columns: 4,
      );
    });

    testWidgets('1280x800: 6 columns', (tester) async {
      await check(
        tester,
        size: const Size(1280, 800),
        padding: const EdgeInsets.only(top: 24),
        columns: 6,
      );
    });

    testWidgets('keyboard up while searching', (tester) async {
      await open(
        tester,
        viewInsets: const EdgeInsets.only(bottom: 320),
        padding: const EdgeInsets.only(top: 24, bottom: 48),
      );
      await tester.tap(find.byKey(ReceiveKeys.searchToggle));
      await tester.pump();
      await tester.enterText(find.byKey(ReceiveKeys.search), 'star');
      await tester.pump();
      await tapTile(tester, 0);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      expect(find.byKey(ReceiveKeys.search), findsOneWidget);
      expect(fx.cartQty(tester, 0), 1);
      await disposeScreen(tester);
    });
  });

  test('receiveGridColumns: 2 on phones, width / 170 up to 6', () {
    expect(receiveGridColumns(360), 2);
    expect(receiveGridColumns(390), 2);
    expect(receiveGridColumns(707), 4); // 800dp beside the rail
    expect(receiveGridColumns(1184), 6); // 1280dp beside the rail
  });
}
