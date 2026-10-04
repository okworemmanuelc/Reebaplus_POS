import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_tour_state.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/pos/screens/checkout_page.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/frame/frame_nav.dart';
import 'package:reebaplus_pos/shared/widgets/main_layout.dart';
import 'package:reebaplus_pos/shared/widgets/spotlight_target.dart';

import '../helpers/screen_harness.dart';

/// Issue #352 (PRD #346) PR 1 — the app frame.
///
/// Pinned:
///   * bottom bar under 600dp wide, side rail at 600dp+ (599 / 600);
///   * cart panel slides in at 600–1023dp and is fixed at 1024dp+ (1023 / 1024);
///   * the ✕ and the dim close the panel; the View Cart bar opens it;
///   * selected = filled primary icon + primary label, idle = outlined + muted;
///   * permission hiding is identical on the bar and the rail;
///   * every frame tap target is at least kMinInteractiveDimension.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const posGrants = {'sales.make', 'stock.view', 'products.add'};

  const testPrefs = {
    'push_soft_ask_shown_v1': true,
    'pos_grid_columns': 2,
    'pos_is_list_view': false,
    'hint_pos_gestures': 2,
  };

  const bottomBar = Key('main-bottom-nav');
  const rail = Key('main-nav-rail');
  const panel = Key('cart-panel');
  const panelClose = Key('cart-panel-close');
  const scrim = Key('cart-panel-scrim');
  const viewCart = Key('view-cart-bar');

  late ScreenTestEnvironment env;

  // Checkout starts a connectivity listener; the plugin has no test
  // implementation, so answer "online over wifi" instead of throwing.
  setUpAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (call) async => <String>['wifi'],
    );
    messenger.setMockStreamHandler(
      const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
      MockStreamHandler.inline(
        onListen: (arguments, events) => events.success(<String>['wifi']),
      ),
    );
  });

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 6,
      sharedPreferences: testPrefs,
    );
    final nav = NavigationService();
    nav.resetNavigation();
    nav.beginSessionLanding();
  });

  tearDown(() async {
    await env.dispose();
    NavigationService().resetNavigation();
  });

  Future<BuildContext> pumpFrame(
    WidgetTester tester,
    Size size, {
    int tab = NavigationService.homeTab,
    Set<String> grants = posGrants,
    String roleSlug = 'manager',
  }) async {
    NavigationService().setIndex(tab);
    final context = await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: const MainLayout(),
      bottomNavHeight: 0,
      grantedKeys: grants,
      roleSlug: roleSlug,
      overrides: [firstRunTourStopProvider.overrideWithValue(TourStop.none)],
      sharedPreferences: testPrefs,
      settle: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    return context;
  }

  Future<void> addToCart(WidgetTester tester, BuildContext context) async {
    final cart = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(cartProvider);
    cart.addItem(env.products.first, qty: 2, maxStock: 100);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Whether the cart panel is on screen and takes taps.
  bool panelShowing() => find.byKey(panel).hitTestable().evaluate().isNotEmpty;

  AppIcon iconOf(WidgetTester tester, int tabIndex) => tester.widget<AppIcon>(
    find.descendant(
      of: find.byKey(frameNavItemKey(tabIndex)),
      matching: find.byType(AppIcon),
    ),
  );

  Text labelOf(WidgetTester tester, int tabIndex) => tester.widget<Text>(
    find
        .descendant(
          of: find.byKey(frameNavItemKey(tabIndex)),
          matching: find.byType(Text),
        )
        .last,
  );

  group('bar vs rail', () {
    testWidgets('599dp wide: bottom bar, no rail', (tester) async {
      await pumpFrame(tester, const Size(599, 900));
      expect(find.byKey(bottomBar), findsOneWidget);
      expect(find.byKey(rail), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('600dp wide: rail, no bottom bar', (tester) async {
      await pumpFrame(tester, const Size(600, 900));
      expect(find.byKey(rail), findsOneWidget);
      expect(find.byKey(bottomBar), findsNothing);
      expect(find.byKey(const Key('frame-rail-menu')), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('the rail menu button opens the drawer over the whole screen', (
      tester,
    ) async {
      await pumpFrame(tester, const Size(1280, 800));
      await tester.tap(find.byKey(const Key('frame-rail-menu')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(NavigationService().isDrawerOpen, isTrue);
      final drawer = tester.getRect(find.byType(Drawer));
      expect(
        drawer.left,
        0.0,
        reason: 'the drawer pops over the rail, it is not beside it',
      );
      expect(find.byKey(const Key('drawer-selected-item')), findsOneWidget);
      await disposeScreen(tester);
    });
  });

  group('first-run tour target', () {
    testWidgets('600dp+: the tour finds the menu button on the rail', (
      tester,
    ) async {
      final context = await pumpFrame(tester, const Size(1280, 800));
      final rect = SpotlightTargetRegistry.getTargetRect(
        SpotlightTargetId.menuButton,
      );
      expect(rect, isNotNull);
      expect(rect!.right, lessThanOrEqualTo(context.navRailWidth));
      await disposeScreen(tester);
    });

    testWidgets('under 600dp: the tour finds the screen\'s own menu button', (
      tester,
    ) async {
      await pumpFrame(tester, const Size(390, 844));
      final rect = SpotlightTargetRegistry.getTargetRect(
        SpotlightTargetId.menuButton,
      );
      expect(rect, isNotNull);
      expect(find.byKey(rail), findsNothing);
      await disposeScreen(tester);
    });
  });

  group('cart panel', () {
    testWidgets(
      '1023dp wide: closed until View Cart, then slides in over a dim',
      (tester) async {
        final context = await pumpFrame(
          tester,
          const Size(1023, 800),
          tab: NavigationService.posTab,
        );
        await addToCart(tester, context);

        expect(panelShowing(), isFalse);
        expect(find.byKey(viewCart), findsOneWidget);

        await tester.tap(find.byKey(viewCart));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(panelShowing(), isTrue);
        expect(find.byKey(scrim).hitTestable(), findsOneWidget);
        expect(
          find.byKey(viewCart),
          findsNothing,
          reason: 'the panel is showing the cart',
        );
        await disposeScreen(tester);
      },
    );

    testWidgets('1024dp wide: fixed on the right from the start, no dim', (
      tester,
    ) async {
      await pumpFrame(
        tester,
        const Size(1024, 800),
        tab: NavigationService.posTab,
      );

      expect(panelShowing(), isTrue);
      expect(find.byKey(scrim), findsNothing);
      final rect = tester.getRect(find.byKey(panel));
      expect(rect.right, 1024.0);
      await disposeScreen(tester);
    });

    testWidgets('tapping the dim closes the slide-in panel', (tester) async {
      final context = await pumpFrame(
        tester,
        const Size(800, 1280),
        tab: NavigationService.posTab,
      );
      await addToCart(tester, context);
      await tester.tap(find.byKey(viewCart));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(panelShowing(), isTrue);

      // Tap the dim well to the left of the panel.
      await tester.tapAt(const Offset(150, 640));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(panelShowing(), isFalse);
      expect(find.byKey(viewCart), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('✕ closes the slide-in panel', (tester) async {
      final context = await pumpFrame(
        tester,
        const Size(800, 1280),
        tab: NavigationService.posTab,
      );
      await addToCart(tester, context);
      await tester.tap(find.byKey(viewCart));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.byKey(panelClose));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(panelShowing(), isFalse);
      await disposeScreen(tester);
    });

    testWidgets('✕ hides the fixed panel and brings back View Cart, which '
        'reopens it', (tester) async {
      final context = await pumpFrame(
        tester,
        const Size(1280, 800),
        tab: NavigationService.posTab,
      );
      await addToCart(tester, context);
      expect(panelShowing(), isTrue);
      expect(find.byKey(viewCart), findsNothing);

      await tester.tap(find.byKey(panelClose));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(panelShowing(), isFalse);
      expect(find.byKey(viewCart), findsOneWidget);

      await tester.tap(find.byKey(viewCart));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(panelShowing(), isTrue);
      await disposeScreen(tester);
    });

    testWidgets('Proceed to Checkout from the panel opens checkout inside '
        'the panel, and back unwinds it before closing', (tester) async {
      final context = await pumpFrame(
        tester,
        const Size(800, 1280),
        tab: NavigationService.posTab,
      );
      await addToCart(tester, context);
      await tester.tap(find.byKey(viewCart));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final proceed = find.descendant(
        of: find.byKey(panel),
        matching: find.text('Proceed to Checkout'),
      );
      await tester.ensureVisible(proceed);
      await tester.tap(proceed);
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(
        find.descendant(
          of: find.byKey(panel),
          matching: find.byType(CheckoutPage),
        ),
        findsOneWidget,
        reason: 'checkout runs the Cart tab\'s own push, inside the panel',
      );
      expect(NavigationService().currentIndex.value, NavigationService.posTab);

      // System back: first pops checkout, then closes the slide-in panel.
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(CheckoutPage), findsNothing);
      expect(panelShowing(), isTrue);

      await tester.pump(const Duration(milliseconds: 600)); // back debounce
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(panelShowing(), isFalse);
      await disposeScreen(tester);
    });

    testWidgets('under 600dp View Cart opens the Cart tab', (tester) async {
      final context = await pumpFrame(
        tester,
        const Size(390, 844),
        tab: NavigationService.posTab,
      );
      await addToCart(tester, context);
      expect(find.byKey(panel), findsNothing);

      await tester.tap(find.byKey(viewCart));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(NavigationService().currentIndex.value, 8);
      await disposeScreen(tester);
    });

    testWidgets('the panel hosts the cart and leaving POS closes the '
        'slide-in panel', (tester) async {
      final context = await pumpFrame(
        tester,
        const Size(800, 1280),
        tab: NavigationService.posTab,
      );
      await addToCart(tester, context);
      await tester.tap(find.byKey(viewCart));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.descendant(
          of: find.byKey(panel),
          matching: find.text('Proceed to Checkout'),
        ),
        findsOneWidget,
      );

      NavigationService().setIndex(NavigationService.homeTab);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(panelShowing(), isFalse);
      await disposeScreen(tester);
    });
  });

  group('selected item', () {
    for (final size in const [Size(390, 844), Size(1280, 800)]) {
      testWidgets('${size.width.toInt()}dp: selected filled + primary, idle '
          'outlined + muted, POS label always primary', (tester) async {
        final context = await pumpFrame(tester, size);
        final primary = Theme.of(context).colorScheme.primary;

        final home = iconOf(tester, NavigationService.homeTab);
        expect(home.filled, isTrue);
        expect(home.color, primary);
        expect(
          labelOf(tester, NavigationService.homeTab).style?.color,
          primary,
        );

        final stock = iconOf(tester, 2);
        expect(stock.filled, isFalse);
        expect(stock.color, isNot(primary));
        expect(labelOf(tester, 2).style?.color, isNot(primary));

        expect(labelOf(tester, NavigationService.posTab).style?.color, primary);
        await disposeScreen(tester);
      });
    }
  });

  group('permission hiding', () {
    for (final size in const [Size(390, 844), Size(1280, 800)]) {
      testWidgets('${size.width.toInt()}dp: no sales.make / stock.view hides '
          'Stock, POS and Cart', (tester) async {
        await pumpFrame(
          tester,
          size,
          grants: const {'products.add'},
          roleSlug: 'stock_keeper',
        );
        expect(
          find.byKey(frameNavItemKey(NavigationService.homeTab)),
          findsOneWidget,
        );
        expect(find.byKey(frameNavItemKey(3)), findsOneWidget);
        expect(find.byKey(frameNavItemKey(2)), findsNothing);
        expect(
          find.byKey(frameNavItemKey(NavigationService.posTab)),
          findsNothing,
        );
        expect(find.byKey(frameNavItemKey(8)), findsNothing);
        await disposeScreen(tester);
      });

      testWidgets('${size.width.toInt()}dp: full grants show all five in '
          'order', (tester) async {
        await pumpFrame(tester, size);
        final xs = [
          NavigationService.homeTab,
          2,
          NavigationService.posTab,
          3,
          8,
        ].map((t) => tester.getCenter(find.byKey(frameNavItemKey(t)))).toList();
        for (var i = 1; i < xs.length; i++) {
          if (size.width < 600) {
            expect(xs[i].dx, greaterThan(xs[i - 1].dx));
          } else {
            expect(xs[i].dy, greaterThan(xs[i - 1].dy));
          }
        }
        await disposeScreen(tester);
      });
    }
  });

  group('tap targets', () {
    for (final size in const [
      Size(390, 844),
      Size(844, 390),
      Size(800, 1280),
      Size(1280, 800),
    ]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()}: every frame '
          'control is at least kMinInteractiveDimension', (tester) async {
        final context = await pumpFrame(
          tester,
          size,
          tab: NavigationService.posTab,
        );
        await addToCart(tester, context);

        final targets = <Finder>[
          for (final t in [
            NavigationService.homeTab,
            2,
            NavigationService.posTab,
            3,
            8,
          ])
            find.byKey(frameNavItemKey(t)),
          if (size.width >= 600) find.byKey(const Key('frame-rail-menu')),
          if (size.width >= 1024)
            find.byKey(panelClose)
          else
            find.byKey(viewCart),
        ];
        for (final target in targets) {
          expect(target, findsOneWidget);
          final s = tester.getSize(target);
          expect(
            s.width,
            greaterThanOrEqualTo(kMinInteractiveDimension),
            reason: '$target width',
          );
          expect(
            s.height,
            greaterThanOrEqualTo(kMinInteractiveDimension),
            reason: '$target height',
          );
        }
        expect(tester.takeException(), isNull);
        await disposeScreen(tester);
      });
    }
  });
}
