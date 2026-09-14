import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/providers/first_run_tour_state.dart';
import 'package:reebaplus_pos/features/dashboard/controllers/first_run_tour_controller.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer.dart';
import 'package:reebaplus_pos/shared/widgets/spotlight_overlay.dart';
import 'package:reebaplus_pos/shared/widgets/spotlight_target.dart';

class _AcknowledgedIntro extends TourIntroAcknowledgedNotifier {
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
