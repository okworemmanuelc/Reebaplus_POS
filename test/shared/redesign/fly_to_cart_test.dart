import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_tour_state.dart';
import 'package:reebaplus_pos/features/pos/widgets/product_grid.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/frame/frame_nav.dart';
import 'package:reebaplus_pos/shared/widgets/main_layout.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/fly_to_cart.dart';

import '../../helpers/screen_harness.dart';

/// #352 PR 3 — the shared fly-to-cart helper.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final particle = find.byKey(const Key('fly-to-cart-particle'));

  group('helper', () {
    setUp(FlyTargetRegistry.clear);

    /// A target in the top-right corner and a source button; tapping runs
    /// [onAdd] first, then launches the flight, as POS does.
    Widget app({
      bool withTarget = true,
      bool showSource = true,
      bool reducedMotion = false,
      required VoidCallback onAdd,
      void Function(FlyToCartFlight?)? onFlight,
    }) {
      return MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: reducedMotion),
            child: Scaffold(
              body: Stack(
                children: [
                  if (withTarget)
                    const Positioned(
                      top: 20,
                      right: 20,
                      child: FlyTarget(
                        id: FlyTargetId.cart,
                        child: SizedBox(
                          key: Key('target'),
                          width: 40,
                          height: 40,
                        ),
                      ),
                    ),
                  if (showSource)
                    Positioned(
                      left: 40,
                      top: 600,
                      child: Builder(
                        builder: (context) => SizedBox(
                          width: 120,
                          height: 120,
                          child: ElevatedButton(
                            key: const Key('source'),
                            onPressed: () {
                              onAdd();
                              final flight = flyToTarget(context);
                              onFlight?.call(flight);
                            },
                            child: const Text('Add'),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    _flyTest('flies to the registered target and removes its overlay '
        'entry when it lands', (tester) async {
      var adds = 0;
      FlyToCartFlight? flight;
      await tester.pumpWidget(
        app(onAdd: () => adds++, onFlight: (f) => flight = f),
      );
      await tester.tap(find.byKey(const Key('source')));
      await tester.pump();
      expect(adds, 1);
      expect(flight, isNotNull);
      expect(particle, findsOneWidget);

      final start = tester.getCenter(particle);
      await tester.pump(const Duration(milliseconds: 300));
      final mid = tester.getCenter(particle);
      expect(mid.dx, greaterThan(start.dx), reason: 'heading right');
      expect(mid.dy, lessThan(start.dy), reason: 'heading up');

      await tester.pump(kFlyToCartDuration);
      await tester.pump();
      expect(particle, findsNothing);
      expect(flight!.isActive, isFalse);
    });

    _flyTest('lands on the target', (tester) async {
      await tester.pumpWidget(app(onAdd: () {}));
      await tester.tap(find.byKey(const Key('source')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1)); // ticker starts
      await tester.pump(kFlyToCartDuration * 0.99);
      final end = tester.getCenter(particle);
      final target = tester.getCenter(find.byKey(const Key('target')));
      // At 99% the arc and the ease leave it a few dp short; it lands at 100%.
      expect((end - target).distance, lessThan(10));
      await tester.pump(kFlyToCartDuration);
    });

    _flyTest('no target showing → no flight, and the add still happens', (
      tester,
    ) async {
      var adds = 0;
      FlyToCartFlight? flight;
      await tester.pumpWidget(
        app(
          withTarget: false,
          onAdd: () => adds++,
          onFlight: (f) => flight = f,
        ),
      );
      await tester.tap(find.byKey(const Key('source')));
      await tester.pump();
      expect(adds, 1);
      expect(flight, isNull);
      expect(particle, findsNothing);
    });

    _flyTest('reduced motion → no flight, and the add still happens', (
      tester,
    ) async {
      var adds = 0;
      FlyToCartFlight? flight;
      await tester.pumpWidget(
        app(
          reducedMotion: true,
          onAdd: () => adds++,
          onFlight: (f) => flight = f,
        ),
      );
      await tester.tap(find.byKey(const Key('source')));
      await tester.pump();
      expect(adds, 1);
      expect(flight, isNull);
      expect(particle, findsNothing);
    });

    _flyTest('the source unmounting mid-flight is harmless', (tester) async {
      await tester.pumpWidget(app(onAdd: () {}));
      await tester.tap(find.byKey(const Key('source')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(particle, findsOneWidget);

      await tester.pumpWidget(app(onAdd: () {}, showSource: false));
      await tester.pump(kFlyToCartDuration);
      await tester.pump(kFlyToCartDuration);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(particle, findsNothing);
    });

    _flyTest('cancel removes the flight at once, and is safe twice', (
      tester,
    ) async {
      FlyToCartFlight? flight;
      await tester.pumpWidget(app(onAdd: () {}, onFlight: (f) => flight = f));
      await tester.tap(find.byKey(const Key('source')));
      await tester.pump(const Duration(milliseconds: 100));
      flight!.cancel();
      flight!.cancel();
      await tester.pump();
      expect(particle, findsNothing);
      expect(tester.takeException(), isNull);
    });

    _flyTest('the higher-priority visible target wins; an offstage one is '
        'ignored', (tester) async {
      Widget build({required bool panelOnstage}) => MaterialApp(
        home: Stack(
          children: [
            const Positioned(
              left: 10,
              top: 10,
              child: FlyTarget(
                id: FlyTargetId.cart,
                child: SizedBox(key: Key('nav'), width: 40, height: 40),
              ),
            ),
            Positioned(
              right: 10,
              top: 10,
              child: Offstage(
                offstage: !panelOnstage,
                child: const FlyTarget(
                  id: FlyTargetId.cart,
                  priority: 1,
                  child: SizedBox(key: Key('panel'), width: 40, height: 40),
                ),
              ),
            ),
          ],
        ),
      );
      const bounds = Rect.fromLTWH(0, 0, 800, 600);
      await tester.pumpWidget(build(panelOnstage: true));
      expect(
        FlyTargetRegistry.resolve(FlyTargetId.cart, bounds),
        tester.getCenter(find.byKey(const Key('panel'))),
      );
      await tester.pumpWidget(build(panelOnstage: false));
      expect(
        FlyTargetRegistry.resolve(FlyTargetId.cart, bounds),
        tester.getCenter(find.byKey(const Key('nav'))),
      );
    });
  });

  group('in the app frame', () {
    const posGrants = {'sales.make', 'stock.view', 'products.add'};
    const testPrefs = {
      'push_soft_ask_shown_v1': true,
      'pos_grid_columns': 2,
      'pos_is_list_view': false,
      'hint_pos_gestures': 2,
    };

    late ScreenTestEnvironment env;

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
      NavigationService()
        ..resetNavigation()
        ..beginSessionLanding()
        ..setIndex(NavigationService.posTab);
    });

    tearDown(() async {
      await env.dispose();
      NavigationService().resetNavigation();
    });

    Future<BuildContext> pumpPos(WidgetTester tester, Size size) async {
      final context = await pumpScreen(
        tester,
        env: env,
        size: size,
        screen: const MainLayout(),
        bottomNavHeight: 0,
        grantedKeys: posGrants,
        roleSlug: 'manager',
        overrides: [firstRunTourStopProvider.overrideWithValue(TourStop.none)],
        sharedPreferences: testPrefs,
        settle: false,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      return context;
    }

    Offset? resolveFor(Size size) =>
        FlyTargetRegistry.resolve(FlyTargetId.cart, Offset.zero & size);

    Rect cartItem(WidgetTester tester) =>
        tester.getRect(find.byKey(frameNavItemKey(8)));

    Rect panel(WidgetTester tester) =>
        tester.getRect(find.byKey(const Key('cart-panel')));

    Future<void> addOne(WidgetTester tester, BuildContext context) async {
      ProviderScope.containerOf(
        context,
        listen: false,
      ).read(cartProvider).addItem(env.products.first, qty: 1, maxStock: 100);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('390x844: the bottom-bar Cart item', (tester) async {
      const size = Size(390, 844);
      await pumpPos(tester, size);
      final point = resolveFor(size);
      expect(point, isNotNull);
      expect(cartItem(tester).contains(point!), isTrue);
      await disposeScreen(tester);
    });

    testWidgets('844x390: the rail Cart item', (tester) async {
      const size = Size(844, 390);
      await pumpPos(tester, size);
      final point = resolveFor(size)!;
      expect(cartItem(tester).contains(point), isTrue);
      expect(point.dx, lessThan(100), reason: 'on the rail, at the left');
      await disposeScreen(tester);
    });

    testWidgets('800x1280: the rail Cart while the slide-in is closed, the '
        'panel header once it is open', (tester) async {
      const size = Size(800, 1280);
      final context = await pumpPos(tester, size);
      await addOne(tester, context);
      expect(cartItem(tester).contains(resolveFor(size)!), isTrue);

      await tester.tap(find.byKey(const Key('view-cart-bar')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final point = resolveFor(size)!;
      expect(panel(tester).contains(point), isTrue);
      expect(point.dy, lessThan(panel(tester).top + 130), reason: 'header');
      await disposeScreen(tester);
    });

    testWidgets('1280x800: the fixed panel header', (tester) async {
      const size = Size(1280, 800);
      await pumpPos(tester, size);
      final point = resolveFor(size)!;
      expect(panel(tester).contains(point), isTrue);
      expect(point.dy, lessThan(130), reason: 'header');
      await disposeScreen(tester);
    });

    testWidgets('tapping a POS tile adds it and flies a particle that lands '
        'and goes away', (tester) async {
      const size = Size(390, 844);
      final context = await pumpPos(tester, size);
      final cart = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(cartProvider);
      expect(cart.value, isEmpty);

      await tester.tap(find.byKey(posProductTileKey(env.products.first.id)));
      await tester.pump();
      expect(cart.value, hasLength(1));
      expect(particle, findsOneWidget);

      // The first frame starts the ticker; the flight runs from there.
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(kFlyToCartDuration);
      await tester.pump();
      expect(particle, findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 4)); // let the toast go
      await disposeScreen(tester);
    });
  });
}

/// A widget test on a 400x800 view (the helper tests' layout needs the room).
void _flyTest(String description, WidgetTesterCallback body) {
  testWidgets(description, (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await body(tester);
  });
}
