import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/providers/first_run_tour_state.dart';
import 'package:reebaplus_pos/core/widgets/app_speed_dial_fab.dart';
import 'package:reebaplus_pos/features/dashboard/controllers/first_run_tour_controller.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer.dart';
import 'package:reebaplus_pos/shared/widgets/spotlight_overlay.dart';
import 'package:reebaplus_pos/shared/widgets/spotlight_target.dart';

class _AcknowledgedIntro extends TourIntroAcknowledgedNotifier {
  @override
  bool build() => true;
}

class _OwedCardHandoff extends TourCardHandoffNotifier {
  @override
  bool build() => true;
}

/// Everything the rail reads that is not the thing under test.
List<Override> _baseOverrides({
  TourStop stop = TourStop.createStore,
  bool introAcknowledged = false,
  String firstName = 'Okwor',
  String? storeName,
}) {
  return [
    firstRunTourStopProvider.overrideWithValue(stop),
    tourOwnerFirstNameProvider.overrideWithValue(firstName),
    tourFirstStoreNameProvider.overrideWithValue(storeName),
    if (introAcknowledged)
      tourIntroAcknowledgedProvider.overrideWith(_AcknowledgedIntro.new),
  ];
}

Widget _harness(ProviderContainer container, {List<Widget> targets = const []}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            ...targets,
            const FirstRunRailTourView(
              targetLookupTimeout: Duration(milliseconds: 100),
              stallPatience: Duration(seconds: 20),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SpotlightTargetRegistry.clear();
    // NavigationService is a singleton, so a test that pushes a page has to
    // hand the next one a clean tab stack.
    NavigationService().currentTabCanPop.value = false;
    NavigationService().resetNavigation();
  });

  group('the introduction', () {
    testWidgets('opens the rail, before any instruction to tap anything',
        (tester) async {
      final container = ProviderContainer(overrides: _baseOverrides());
      addTearDown(container.dispose);

      await tester.pumpWidget(_harness(container));
      await tester.pump();

      expect(find.text('Welcome, Okwor'), findsOneWidget);
      expect(find.textContaining('A store is where your stock'), findsOneWidget);
      expect(find.text('Tap the menu to get started'), findsNothing);
    });

    testWidgets('"Set up my store" hands over to the first instruction',
        (tester) async {
      final container = ProviderContainer(overrides: _baseOverrides());
      addTearDown(container.dispose);

      await tester.pumpWidget(
        _harness(container, targets: const [
          SpotlightTarget(
            id: SpotlightTargetId.menuButton,
            child: SizedBox(width: 48, height: 48),
          ),
        ]),
      );
      await tester.pump();

      await tester.tap(find.text('Set up my store'));
      await tester.pump();

      expect(find.text('Welcome, Okwor'), findsNothing);
      expect(find.text('Tap the menu to get started'), findsOneWidget);
    });

    testWidgets('falls back to a plain greeting when the name is unknown',
        (tester) async {
      final container =
          ProviderContainer(overrides: _baseOverrides(firstName: ''));
      addTearDown(container.dispose);

      await tester.pumpWidget(_harness(container));
      await tester.pump();

      expect(find.text('Welcome'), findsOneWidget);
    });
  });

  group('declining', () {
    testWidgets('"I\'ll look around first" ends the session but is not a strike',
        (tester) async {
      final container = ProviderContainer(overrides: _baseOverrides());
      addTearDown(container.dispose);

      await tester.pumpWidget(_harness(container));
      await tester.pump();

      await tester.tap(find.text('I’ll look around first'));
      await tester.pump();

      expect(container.read(tourSessionAbortedProvider), isTrue,
          reason: 'the rail should stand down for the rest of the session');
      expect(container.read(tourDeviceAbortCountProvider), 0,
          reason: 'a deliberate decline is not evidence the rail is broken '
              'here, and three of them must not retire it on this device');
    });
  });

  group('the stall net', () {
    testWidgets('offers a way out once a step has sat there long enough',
        (tester) async {
      final container =
          ProviderContainer(overrides: _baseOverrides(introAcknowledged: true));
      addTearDown(container.dispose);

      await tester.pumpWidget(
        _harness(container, targets: const [
          SpotlightTarget(
            id: SpotlightTargetId.menuButton,
            child: SizedBox(width: 48, height: 48),
          ),
        ]),
      );
      await tester.pump();

      expect(find.text('Having trouble? Skip setup'), findsNothing);

      await tester.pump(const Duration(seconds: 21));
      expect(find.text('Having trouble? Skip setup'), findsOneWidget);
    });

    testWidgets('offers a way out after three taps the sheet swallowed',
        (tester) async {
      final container =
          ProviderContainer(overrides: _baseOverrides(introAcknowledged: true));
      addTearDown(container.dispose);

      await tester.pumpWidget(
        _harness(container, targets: const [
          SpotlightTarget(
            id: SpotlightTargetId.menuButton,
            child: SizedBox(width: 48, height: 48),
          ),
        ]),
      );
      await tester.pump();

      // Well clear of the hole, which sits top-left over the 48x48 target.
      // (The test surface is 800x600, so this is on screen.)
      for (var i = 0; i < 3; i++) {
        await tester.tapAt(const Offset(400, 400));
        await tester.pump();
      }

      expect(find.text('Having trouble? Skip setup'), findsOneWidget);
    });

    testWidgets('taking the way out counts as a strike against this device',
        (tester) async {
      final container =
          ProviderContainer(overrides: _baseOverrides(introAcknowledged: true));
      addTearDown(container.dispose);

      await tester.pumpWidget(
        _harness(container, targets: const [
          SpotlightTarget(
            id: SpotlightTargetId.menuButton,
            child: SizedBox(width: 48, height: 48),
          ),
        ]),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 21));

      await tester.tap(find.text('Having trouble? Skip setup'));
      await tester.pump();

      expect(container.read(tourSessionAbortedProvider), isTrue);
      expect(container.read(tourDeviceAbortCountProvider), 1,
          reason: 'the owner reporting they are stuck is the best evidence '
              'available that the rail does not work on this phone');
    });

    testWidgets('withdraws the offer once the owner makes progress',
        (tester) async {
      final container =
          ProviderContainer(overrides: _baseOverrides(introAcknowledged: true));
      addTearDown(container.dispose);
      final nav = NavigationService();
      addTearDown(() => nav.currentIndex.value = NavigationService.homeTab);

      await tester.pumpWidget(
        _harness(container, targets: const [
          SpotlightTarget(
            id: SpotlightTargetId.menuButton,
            child: SizedBox(width: 48, height: 48),
          ),
          SpotlightTarget(
            id: SpotlightTargetId.createStoreFab,
            child: SizedBox(width: 56, height: 56),
          ),
        ]),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 21));
      expect(find.text('Having trouble? Skip setup'), findsOneWidget);

      // Reaching the Stores tab is progress: this is a different step.
      nav.currentIndex.value = NavigationService.storesTab;
      await tester.pump();

      expect(find.text('Tap to create your first store'), findsOneWidget);
      expect(find.text('Having trouble? Skip setup'), findsNothing);
    });
  });

  group('the scroll step', () {
    testWidgets('cuts no hole, so no other destination is tappable',
        (tester) async {
      final container =
          ProviderContainer(overrides: _baseOverrides(introAcknowledged: true));
      addTearDown(container.dispose);
      final nav = NavigationService();
      nav.drawerMounted();
      addTearDown(nav.drawerDismounted);

      await tester.pumpWidget(_harness(container));
      await tester.pump();

      // Drawer open, Stores entry never registered — the below-the-fold case.
      expect(find.text('Scroll down to find Stores'), findsOneWidget);

      final overlay =
          tester.widget<SpotlightOverlay>(find.byType(SpotlightOverlay));
      expect(overlay.targetId, isNull);
      expect(overlay.blocking, isTrue);

      final background = tester.renderObject<RenderSpotlightOverlay>(
        find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_SpotlightOverlayBackground',
        ),
      );
      expect(background.paddedHoleRect, isNull);
    });
  });

  group('the hand-off', () {
    testWidgets('follows the store the owner just saved', (tester) async {
      final stopSource = StateProvider<TourStop>((ref) => TourStop.createStore);

      final container = ProviderContainer(overrides: [
        firstRunTourStopProvider.overrideWith((ref) => ref.watch(stopSource)),
        tourOwnerFirstNameProvider.overrideWithValue('Okwor'),
        tourFirstStoreNameProvider.overrideWithValue('Main Shop'),
        tourIntroAcknowledgedProvider.overrideWith(_AcknowledgedIntro.new),
      ]);
      addTearDown(container.dispose);

      await tester.pumpWidget(
        _harness(container, targets: const [
          SpotlightTarget(
            id: SpotlightTargetId.menuButton,
            child: SizedBox(width: 48, height: 48),
          ),
        ]),
      );
      await tester.pump();
      expect(container.read(tourHandoffProvider), isFalse);

      // The store saves: stop one is over.
      container.read(stopSource.notifier).state = TourStop.addProduct;
      await tester.pump();

      expect(container.read(tourHandoffProvider), isTrue);
      expect(find.text('Main Shop is ready.'), findsOneWidget);
      expect(find.text('Next, add something to sell.'), findsOneWidget);
    });

    testWidgets('never appears for an owner who already had a store',
        (tester) async {
      final container = ProviderContainer(
        overrides: _baseOverrides(
          stop: TourStop.addProduct,
          introAcknowledged: true,
        ),
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        _harness(container, targets: const [
          SpotlightTarget(
            id: SpotlightTargetId.addProductFab,
            child: SizedBox(width: 56, height: 56),
          ),
        ]),
      );
      await tester.pump();

      expect(container.read(tourHandoffProvider), isFalse);
      expect(find.textContaining('is ready.'), findsNothing);
      expect(find.text('Tap to add your first product'), findsOneWidget);
    });

    testWidgets('"Not now" settles it and leaves the pointer behind',
        (tester) async {
      final container = ProviderContainer(
        overrides: _baseOverrides(
          stop: TourStop.addProduct,
          introAcknowledged: true,
          storeName: 'Main Shop',
        ),
      );
      addTearDown(container.dispose);
      container.read(tourHandoffProvider.notifier).owe();

      await tester.pumpWidget(
        _harness(container, targets: const [
          SpotlightTarget(
            id: SpotlightTargetId.addProductFab,
            child: SizedBox(width: 56, height: 56),
          ),
        ]),
      );
      await tester.pump();
      expect(find.text('Main Shop is ready.'), findsOneWidget);

      await tester.tap(find.text('Not now'));
      await tester.pump();

      expect(container.read(tourHandoffProvider), isFalse);
      expect(find.text('Tap to add your first product'), findsOneWidget);
    });

    testWidgets(
        'tapping "Add a product" navigates to inventory and suppresses the product pointer',
        (tester) async {
      final container = ProviderContainer(
        overrides: _baseOverrides(
          stop: TourStop.addProduct,
          introAcknowledged: true,
          storeName: 'Main Shop',
        ),
      );
      addTearDown(container.dispose);
      container.read(tourHandoffProvider.notifier).owe();

      await tester.pumpWidget(
        _harness(container, targets: const [
          SpotlightTarget(
            id: SpotlightTargetId.addProductFab,
            child: SizedBox(width: 56, height: 56),
          ),
        ]),
      );
      await tester.pump();
      expect(find.text('Main Shop is ready.'), findsOneWidget);

      await tester.tap(find.text('Add a product'));
      await tester.pump();

      expect(container.read(tourHandoffProvider), isFalse);
      expect(container.read(tourProductPointerDismissedProvider), isTrue);
      expect(NavigationService().currentIndex.value, 2);
      expect(find.text('Tap to add your first product'), findsNothing);
    });
  });

  group('the product pointer', () {
    /// Stop 2 with its target mounted and nothing in the way.
    Future<ProviderContainer> pumpPointer(WidgetTester tester) async {
      // The stop is derived rather than pinned, so standing the rail down
      // actually takes the pointer off the screen.
      final container = ProviderContainer(overrides: [
        firstRunTourStopProvider.overrideWith(
          (ref) => ref.watch(tourSessionAbortedProvider)
              ? TourStop.none
              : TourStop.addProduct,
        ),
        tourOwnerFirstNameProvider.overrideWithValue('Okwor'),
        tourFirstStoreNameProvider.overrideWithValue(null),
        tourIntroAcknowledgedProvider.overrideWith(_AcknowledgedIntro.new),
      ]);
      addTearDown(container.dispose);

      await tester.pumpWidget(
        _harness(container, targets: const [
          SpotlightTarget(
            id: SpotlightTargetId.addProductFab,
            child: SizedBox(width: 56, height: 56),
          ),
        ]),
      );
      await tester.pump();
      return container;
    }

    testWidgets('can be put away, and putting it away is not a strike',
        (tester) async {
      final container = await pumpPointer(tester);
      expect(find.text('Tap to add your first product'), findsOneWidget);

      await tester.tap(find.text('Not now'));
      await tester.pump();

      expect(find.text('Tap to add your first product'), findsNothing,
          reason: 'the last stop needs a way out of its own — the hand-off '
              'card is gone by the time the pointer is up');
      expect(container.read(tourSessionAbortedProvider), isTrue);
      expect(container.read(tourDeviceAbortCountProvider), 0,
          reason: 'putting a pointer away is a preference, not a rail that '
              'failed on this device');
    });

    testWidgets(
        'tapping caption bubble dismisses the pointer without aborting session',
        (tester) async {
      final container = await pumpPointer(tester);
      expect(find.text('Tap to add your first product'), findsOneWidget);

      await tester.tap(find.text('Tap to add your first product'));
      await tester.pump();

      expect(find.text('Tap to add your first product'), findsNothing);
      expect(container.read(tourProductPointerDismissedProvider), isTrue);
      expect(container.read(tourSessionAbortedProvider), isFalse);
      expect(container.read(tourDeviceAbortCountProvider), 0);
    });

    testWidgets(
        'saving product when pointer was dismissed still triggers handoff to GetStartedCard',
        (tester) async {
      final stopSource = StateProvider<TourStop>((ref) => TourStop.addProduct);
      final container = ProviderContainer(overrides: [
        firstRunTourStopProvider.overrideWith((ref) => ref.watch(stopSource)),
        tourOwnerFirstNameProvider.overrideWithValue('Okwor'),
        tourFirstStoreNameProvider.overrideWithValue(null),
        tourIntroAcknowledgedProvider.overrideWith(_AcknowledgedIntro.new),
      ]);
      addTearDown(container.dispose);

      container.read(tourProductPointerDismissedProvider.notifier).dismiss();

      await tester.pumpWidget(
        _harness(container, targets: const [
          SpotlightTarget(
            id: SpotlightTargetId.getStartedCard,
            child: SizedBox(width: 200, height: 100),
          ),
        ]),
      );
      await tester.pump();
      expect(find.text('Tap to add your first product'), findsNothing);
      expect(find.text('Finish your setup here'), findsNothing);

      // Product saved -> TourStop.none
      container.read(stopSource.notifier).state = TourStop.none;
      await tester.pump();

      expect(container.read(tourCardHandoffProvider), isTrue);
      expect(find.text('Finish your setup here'), findsOneWidget);
    });

    testWidgets('stands aside while a page is open over the tab',
        (tester) async {
      await pumpPointer(tester);
      expect(find.text('Tap to add your first product'), findsOneWidget);

      // Add Product and Receive Stock are both pushed onto the tab's own
      // Navigator, which sits below this overlay. Left up, the pointer would
      // hang over the form it just asked the owner to fill in.
      NavigationService().currentTabCanPop.value = true;
      await tester.pump();

      expect(find.text('Tap to add your first product'), findsNothing);

      NavigationService().currentTabCanPop.value = false;
      await tester.pump();

      expect(find.text('Tap to add your first product'), findsOneWidget,
          reason: 'backing out without saving should bring it back');
    });

    testWidgets('stands aside once the target opens its own menu',
        (tester) async {
      final container = ProviderContainer(overrides: [
        firstRunTourStopProvider.overrideWithValue(TourStop.addProduct),
        tourOwnerFirstNameProvider.overrideWithValue('Okwor'),
        tourFirstStoreNameProvider.overrideWithValue(null),
        tourIntroAcknowledgedProvider.overrideWith(_AcknowledgedIntro.new),
      ]);
      addTearDown(container.dispose);

      await tester.pumpWidget(
        _harness(container, targets: [
          Align(
            alignment: Alignment.bottomRight,
            child: SpotlightTarget(
              id: SpotlightTargetId.addProductFab,
              child: AppSpeedDialFab(
                reserveBottomInset: false,
                actions: [
                  AppSpeedDialAction(
                    icon: Icons.sell,
                    label: 'Add Product',
                    description: 'Create a product and set what’s on your shelf',
                    onPressed: () {},
                  ),
                  AppSpeedDialAction(
                    icon: Icons.local_shipping,
                    label: 'Receive Stock',
                    description: 'Log a delivery from a supplier',
                    onPressed: () {},
                  ),
                ],
              ),
            ),
          ),
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.text('Tap to add your first product'), findsOneWidget);

      // The "+" is a speed dial; its options open into an Overlay the pointer
      // renders above, so the caption and its "Not now" landed straight across
      // both of them.
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      expect(find.text('Add Product'), findsOneWidget);
      expect(find.text('Receive Stock'), findsOneWidget);
      expect(find.text('Tap to add your first product'), findsNothing,
          reason: 'the instruction is stale the moment it is obeyed');
      expect(find.text('Not now'), findsNothing);

      // Backing out of the menu brings the pointer back. Tapped on the dial's
      // own scrim rather than the toggle, which the scrim now covers.
      await tester.tapAt(const Offset(100, 100));
      await tester.pumpAndSettle();

      expect(find.text('Tap to add your first product'), findsOneWidget);
    });

    testWidgets('rings the target instead of darkening the app',
        (tester) async {
      await pumpPointer(tester);

      final render = tester.allRenderObjects
          .whereType<RenderSpotlightOverlay>()
          .single;

      // The sheet is a full-size Path with the hole subtracted; the ring is a
      // pair of stroked RRects over an untouched app. Painting the sheet here
      // buried the Inventory "+" menu, which lives in the tab's Overlay below
      // this one, under ~72% black.
      expect(render, isNot(paints..path()),
          reason: 'a non-blocking pointer must not cover the app');
      expect(render, paints..rrect()..rrect());
    });

    testWidgets('the blocking sheet still covers the app', (tester) async {
      final container = ProviderContainer(
        overrides: _baseOverrides(introAcknowledged: true),
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        _harness(container, targets: const [
          SpotlightTarget(
            id: SpotlightTargetId.menuButton,
            child: SizedBox(width: 48, height: 48),
          ),
        ]),
      );
      await tester.pump();

      final render = tester.allRenderObjects
          .whereType<RenderSpotlightOverlay>()
          .single;

      expect(render, paints..path(),
          reason: 'stop 1 blocks by covering everything but the hole');
    });
  });

  group('the get-started card hand-off', () {
    testWidgets('points at the GetStartedCard when stop 2 finishes and settles on Got it',
        (tester) async {
      final container = ProviderContainer(overrides: [
        firstRunTourStopProvider.overrideWithValue(TourStop.none),
        tourCardHandoffProvider.overrideWith(_OwedCardHandoff.new),
        tourOwnerFirstNameProvider.overrideWithValue('Okwor'),
      ]);
      addTearDown(container.dispose);

      await tester.pumpWidget(
        _harness(container, targets: const [
          SpotlightTarget(
            id: SpotlightTargetId.getStartedCard,
            child: SizedBox(width: 300, height: 150),
          ),
        ]),
      );
      await tester.pump();

      expect(find.text('Finish your setup here'), findsOneWidget);
      expect(find.text('Got it'), findsOneWidget);

      await tester.tap(find.text('Got it'));
      await tester.pump();

      expect(container.read(tourCardHandoffProvider), isFalse);
    });
  });

  group('drawer presence', () {
    testWidgets(
        'a drawer on any Scaffold — not just MainLayout\'s — reports itself open',
        (tester) async {
      final nav = NavigationService();
      expect(nav.isDrawerOpen, isFalse);

      final scaffoldKey = GlobalKey<ScaffoldState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            key: scaffoldKey,
            // Deliberately NOT the Scaffold NavigationService holds a key to,
            // and with no onDrawerChanged — exactly how every screen in this
            // app declares its drawer.
            drawer: const Drawer(
              child: DrawerPresence(child: SizedBox.shrink()),
            ),
            body: const SizedBox.shrink(),
          ),
        ),
      );

      scaffoldKey.currentState!.openDrawer();
      await tester.pumpAndSettle();
      expect(nav.isDrawerOpen, isTrue,
          reason: 'the tour reads this to know it may stop saying '
              '"tap the menu"');

      Navigator.of(tester.element(find.byType(Drawer))).pop();
      await tester.pumpAndSettle();
      expect(nav.isDrawerOpen, isFalse);
    });

    testWidgets('reporting from initState never marks a sibling dirty mid-build',
        (tester) async {
      final nav = NavigationService();
      addTearDown(() {
        while (nav.drawerOpenNotifier.value) {
          nav.drawerDismounted();
        }
      });

      final scaffoldKey = GlobalKey<ScaffoldState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            key: scaffoldKey,
            drawer: const Drawer(
              child: DrawerPresence(child: SizedBox.shrink()),
            ),
            // A listener that is a sibling of the drawer, never an ancestor —
            // the shape that crashes if the notifier is written mid-frame.
            body: ListenableBuilder(
              listenable: nav.drawerOpenNotifier,
              builder: (context, _) =>
                  Text(nav.drawerOpenNotifier.value ? 'open' : 'shut'),
            ),
          ),
        ),
      );

      scaffoldKey.currentState!.openDrawer();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('open'), findsOneWidget);
    });
  });
}
