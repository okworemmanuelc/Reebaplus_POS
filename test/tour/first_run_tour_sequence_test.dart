import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/providers/first_run_tour_state.dart';
import 'package:reebaplus_pos/features/dashboard/controllers/first_run_tour_controller.dart';
import 'package:reebaplus_pos/shared/widgets/spotlight_overlay.dart';
import 'package:reebaplus_pos/shared/widgets/spotlight_target.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('computeStopOneStep (pure derivation)', () {
    test('on Stores tab -> createStoreAction regardless of drawer state', () {
      expect(
        computeStopOneStep(
          isStoresTab: true,
          isDrawerOpen: false,
          isStoresItemVisible: false,
        ),
        StopOneStep.createStoreAction,
      );

      expect(
        computeStopOneStep(
          isStoresTab: true,
          isDrawerOpen: true,
          isStoresItemVisible: true,
        ),
        StopOneStep.createStoreAction,
      );
    });

    test('drawer closed -> menuButton', () {
      expect(
        computeStopOneStep(
          isStoresTab: false,
          isDrawerOpen: false,
          isStoresItemVisible: false,
        ),
        StopOneStep.menuButton,
      );
    });

    test('drawer open and stores item NOT visible -> scrollDrawer', () {
      expect(
        computeStopOneStep(
          isStoresTab: false,
          isDrawerOpen: true,
          isStoresItemVisible: false,
        ),
        StopOneStep.scrollDrawer,
      );
    });

    test('drawer open and stores item IS visible -> storesMenuItem', () {
      expect(
        computeStopOneStep(
          isStoresTab: false,
          isDrawerOpen: true,
          isStoresItemVisible: true,
        ),
        StopOneStep.storesMenuItem,
      );
    });

    test('form sheet open -> createStoreForm regardless of other flags', () {
      expect(
        computeStopOneStep(
          isStoresTab: true,
          isDrawerOpen: false,
          isStoresItemVisible: false,
          isCreateStoreFormOpen: true,
        ),
        StopOneStep.createStoreForm,
      );

      expect(
        computeStopOneStep(
          isStoresTab: false,
          isDrawerOpen: true,
          isStoresItemVisible: true,
          isCreateStoreFormOpen: true,
        ),
        StopOneStep.createStoreForm,
      );
    });
  });

  group('Stop 1 captions and targets', () {
    test('each step has expected caption and targetId', () {
      expect(captionForStopOneStep(StopOneStep.menuButton), 'Tap the menu to get started');
      expect(targetIdForStopOneStep(StopOneStep.menuButton), SpotlightTargetId.menuButton);

      expect(captionForStopOneStep(StopOneStep.scrollDrawer), 'Scroll down to find Stores');
      expect(targetIdForStopOneStep(StopOneStep.scrollDrawer), SpotlightTargetId.drawerMenuList);

      expect(captionForStopOneStep(StopOneStep.storesMenuItem), 'Tap Stores');
      expect(targetIdForStopOneStep(StopOneStep.storesMenuItem), SpotlightTargetId.drawerStoresItem);

      expect(captionForStopOneStep(StopOneStep.createStoreAction), 'Tap to create your first store');
      expect(targetIdForStopOneStep(StopOneStep.createStoreAction), SpotlightTargetId.createStoreFab);

      expect(captionForStopOneStep(StopOneStep.createStoreForm), 'Enter store details and tap Save Store');
      expect(targetIdForStopOneStep(StopOneStep.createStoreForm), SpotlightTargetId.createStoreForm);
    });
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('abortFirstRunTour', () {
    test('marks session aborted and increments device abort count', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(tourSessionAbortedProvider), isFalse);
      expect(container.read(tourDeviceAbortCountProvider), 0);

      // Trigger abort via notifiers
      container.read(tourSessionAbortedProvider.notifier).abort();
      await container.read(tourDeviceAbortCountProvider.notifier).recordAbort();

      expect(container.read(tourSessionAbortedProvider), isTrue);
      expect(container.read(tourDeviceAbortCountProvider), 1);
    });
  });

  group('FirstRunRailTourView Widget', () {
    testWidgets('renders nothing when tourStop is none', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            firstRunTourStopProvider.overrideWithValue(TourStop.none),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: FirstRunRailTourView(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SpotlightOverlay), findsNothing);
    });

    testWidgets('renders SpotlightOverlay with menuButton target when drawer closed', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            firstRunTourStopProvider.overrideWithValue(TourStop.createStore),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  SpotlightTarget(
                    id: SpotlightTargetId.menuButton,
                    child: SizedBox(
                      width: 50,
                      height: 50,
                      child: Icon(Icons.menu),
                    ),
                  ),
                  FirstRunRailTourView(),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SpotlightOverlay), findsOneWidget);
      expect(find.text('Tap the menu to get started'), findsOneWidget);
    });

    testWidgets('missing target triggers abort and hides tour', (tester) async {
      final container = ProviderContainer(
        overrides: [
          firstRunTourStopProvider.overrideWith((ref) {
            final aborted = ref.watch(tourSessionAbortedProvider);
            return aborted ? TourStop.none : TourStop.createStore;
          }),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  // No SpotlightTarget mounted!
                  Consumer(
                    builder: (context, ref, _) {
                      final isAborted = ref.watch(tourSessionAbortedProvider);
                      if (isAborted) {
                        return const Text('Tour Aborted Fallback');
                      }
                      return const FirstRunRailTourView(
                        targetLookupTimeout: Duration(milliseconds: 100),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      // Pump initial frame then advance past targetLookupTimeout
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();

      // Session abort should be recorded and fallback displayed
      expect(container.read(tourSessionAbortedProvider), isTrue);
      expect(find.text('Tour Aborted Fallback'), findsOneWidget);
      expect(find.byType(SpotlightOverlay), findsNothing);
    });

    testWidgets('tour completes atomically when store is created', (tester) async {
      final hasStoresNotifier = ValueNotifier<bool>(false);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: hasStoresNotifier,
              builder: (context, hasStores, _) {
                return ProviderScope(
                  overrides: [
                    firstRunTourStopProvider.overrideWithValue(
                      hasStores ? TourStop.none : TourStop.createStore,
                    ),
                  ],
                  child: const Stack(
                    children: [
                      SpotlightTarget(
                        id: SpotlightTargetId.createStoreFab,
                        child: SizedBox(width: 56, height: 56),
                      ),
                      FirstRunRailTourView(),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Initially on Stop 1
      expect(find.byType(SpotlightOverlay), findsOneWidget);

      // Now simulate store created (hasStores flips to true)
      hasStoresNotifier.value = true;
      await tester.pumpAndSettle();

      // Overlay disappears atomically
      expect(find.byType(SpotlightOverlay), findsNothing);
    });

    testWidgets('points to createStoreForm when form target is mounted', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            firstRunTourStopProvider.overrideWithValue(TourStop.createStore),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  SpotlightTarget(
                    id: SpotlightTargetId.createStoreForm,
                    child: SizedBox(
                      width: 300,
                      height: 400,
                      child: Text('Store Form'),
                    ),
                  ),
                  FirstRunRailTourView(),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SpotlightOverlay), findsOneWidget);
      expect(find.text('Enter store details and tap Save Store'), findsOneWidget);
    });

    testWidgets('renders non-blocking SpotlightOverlay when tourStop is addProduct', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            firstRunTourStopProvider.overrideWithValue(TourStop.addProduct),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  SpotlightTarget(
                    id: SpotlightTargetId.addProductFab,
                    child: SizedBox(
                      width: 56,
                      height: 56,
                      child: Icon(Icons.add),
                    ),
                  ),
                  FirstRunRailTourView(),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SpotlightOverlay), findsOneWidget);
      expect(find.text('Tap to add your first product'), findsOneWidget);

      final overlayWidget = tester.widget<SpotlightOverlay>(find.byType(SpotlightOverlay));
      expect(overlayWidget.blocking, isFalse);
    });
  });
}
