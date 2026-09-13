import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_tour_state.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/sync/controllers/first_load_overlay_controller.dart';

RoleData _role(String slug) => RoleData(
      id: 'r-$slug',
      businessId: 'biz',
      name: slug.toUpperCase(),
      slug: slug,
      isSystemDefault: true,
      isDeleted: false,
      createdAt: DateTime.utc(2026, 1, 1),
      lastUpdatedAt: DateTime.utc(2026, 1, 1),
    );

StoreData _store(String id) => StoreData(
      id: id,
      businessId: 'biz',
      name: 'Store $id',
      location: null,
      kind: 'store',
      isDeleted: false,
      createdAt: DateTime.utc(2026, 1, 1),
      lastUpdatedAt: DateTime.utc(2026, 1, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });
  group('computeTourStop (pure derivation)', () {
    test('remote off-switch true outranks everything → none', () {
      final stop = computeTourStop(
        isOwner: true,
        hasStores: false,
        hasProducts: false,
        abortedThisSession: false,
        deviceAbortCount: 0,
        remoteOffSwitch: true,
      );
      expect(stop, TourStop.none);
    });

    test('non-owner never receives a stop → none', () {
      final stop = computeTourStop(
        isOwner: false,
        hasStores: false,
        hasProducts: false,
        abortedThisSession: false,
        deviceAbortCount: 0,
        remoteOffSwitch: false,
      );
      expect(stop, TourStop.none);
    });

    test('device abort count >= 3 stops rail permanently → none', () {
      for (final count in [3, 4, 10]) {
        final stop = computeTourStop(
          isOwner: true,
          hasStores: false,
          hasProducts: false,
          abortedThisSession: false,
          deviceAbortCount: count,
          remoteOffSwitch: false,
        );
        expect(stop, TourStop.none, reason: 'failed for abort count $count');
      }
    });

    test('aborted this session suppresses the tour → none', () {
      final stop = computeTourStop(
        isOwner: true,
        hasStores: false,
        hasProducts: false,
        abortedThisSession: true,
        deviceAbortCount: 1,
        remoteOffSwitch: false,
      );
      expect(stop, TourStop.none);
    });

    test('has both stores and products → none (rail complete)', () {
      final stop = computeTourStop(
        isOwner: true,
        hasStores: true,
        hasProducts: true,
        abortedThisSession: false,
        deviceAbortCount: 0,
        remoteOffSwitch: false,
      );
      expect(stop, TourStop.none);
    });

    test('zero stores (settled, owner, no aborts) → createStore (Stop 1)', () {
      final stop = computeTourStop(
        isOwner: true,
        hasStores: false,
        hasProducts: false,
        abortedThisSession: false,
        deviceAbortCount: 0,
        remoteOffSwitch: false,
      );
      expect(stop, TourStop.createStore);
    });

    test('has stores but zero products → addProduct (Stop 2)', () {
      final stop = computeTourStop(
        isOwner: true,
        hasStores: true,
        hasProducts: false,
        abortedThisSession: false,
        deviceAbortCount: 0,
        remoteOffSwitch: false,
      );
      expect(stop, TourStop.addProduct);
    });

    test('precedence: session abort beats zero stores', () {
      final stop = computeTourStop(
        isOwner: true,
        hasStores: false,
        hasProducts: false,
        abortedThisSession: true,
        deviceAbortCount: 0,
        remoteOffSwitch: false,
      );
      expect(stop, TourStop.none);
    });

    test('precedence: non-owner beats zero stores', () {
      final stop = computeTourStop(
        isOwner: false,
        hasStores: false,
        hasProducts: false,
        abortedThisSession: false,
        deviceAbortCount: 0,
        remoteOffSwitch: false,
      );
      expect(stop, TourStop.none);
    });
  });

  group('firstRunTourStopProvider (live wiring via input overrides)', () {
    test('owner with zero stores and no products → createStore', () async {
      final container = ProviderContainer(
        overrides: [
          currentUserRoleProvider.overrideWithValue(_role('ceo')),
          allStoresProvider.overrideWith((ref) => Stream.value(<StoreData>[])),
          hasLocalProductsProvider.overrideWith((ref) => Stream.value(false)),
          firstLoadSkeletonActiveProvider.overrideWithValue(false),
          tourSessionAbortedProvider.overrideWith(TourSessionAbortedNotifier.new),
          tourDeviceAbortCountProvider.overrideWith(TourDeviceAbortCountNotifier.new),
          tourRemoteOffSwitchProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);

      // Await streams to emit
      await container.read(allStoresProvider.future);
      await container.read(hasLocalProductsProvider.future);

      final stop = container.read(firstRunTourStopProvider);
      expect(stop, TourStop.createStore);
    });

    test('initial firstLoadSkeletonActive in progress → none (Invariant #11)', () async {
      final container = ProviderContainer(
        overrides: [
          currentUserRoleProvider.overrideWithValue(_role('ceo')),
          allStoresProvider.overrideWith((ref) => Stream.value(<StoreData>[])),
          hasLocalProductsProvider.overrideWith((ref) => Stream.value(false)),
          firstLoadSkeletonActiveProvider.overrideWithValue(true),
          tourSessionAbortedProvider.overrideWith(TourSessionAbortedNotifier.new),
          tourDeviceAbortCountProvider.overrideWith(TourDeviceAbortCountNotifier.new),
          tourRemoteOffSwitchProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);

      final stop = container.read(firstRunTourStopProvider);
      expect(stop, TourStop.none);
    });

    test('non-owner (cashier) with zero stores → none', () async {
      final container = ProviderContainer(
        overrides: [
          currentUserRoleProvider.overrideWithValue(_role('cashier')),
          allStoresProvider.overrideWith((ref) => Stream.value(<StoreData>[])),
          hasLocalProductsProvider.overrideWith((ref) => Stream.value(false)),
          firstLoadSkeletonActiveProvider.overrideWithValue(false),
          tourSessionAbortedProvider.overrideWith(TourSessionAbortedNotifier.new),
          tourDeviceAbortCountProvider.overrideWith(TourDeviceAbortCountNotifier.new),
          tourRemoteOffSwitchProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);

      await container.read(allStoresProvider.future);
      await container.read(hasLocalProductsProvider.future);

      final stop = container.read(firstRunTourStopProvider);
      expect(stop, TourStop.none);
    });

    test('owner with stores but zero products → addProduct', () async {
      final container = ProviderContainer(
        overrides: [
          currentUserRoleProvider.overrideWithValue(_role('ceo')),
          allStoresProvider.overrideWith((ref) => Stream.value([_store('s1')])),
          hasLocalProductsProvider.overrideWith((ref) => Stream.value(false)),
          firstLoadSkeletonActiveProvider.overrideWithValue(false),
          tourSessionAbortedProvider.overrideWith(TourSessionAbortedNotifier.new),
          tourDeviceAbortCountProvider.overrideWith(TourDeviceAbortCountNotifier.new),
          tourRemoteOffSwitchProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);

      await container.read(allStoresProvider.future);
      await container.read(hasLocalProductsProvider.future);

      final stop = container.read(firstRunTourStopProvider);
      expect(stop, TourStop.addProduct);
    });

    test('session abort suppresses the tour stop', () async {
      final container = ProviderContainer(
        overrides: [
          currentUserRoleProvider.overrideWithValue(_role('ceo')),
          allStoresProvider.overrideWith((ref) => Stream.value(<StoreData>[])),
          hasLocalProductsProvider.overrideWith((ref) => Stream.value(false)),
          firstLoadSkeletonActiveProvider.overrideWithValue(false),
          tourSessionAbortedProvider.overrideWith(TourSessionAbortedNotifier.new),
          tourDeviceAbortCountProvider.overrideWith(TourDeviceAbortCountNotifier.new),
          tourRemoteOffSwitchProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);

      await container.read(allStoresProvider.future);
      await container.read(hasLocalProductsProvider.future);

      expect(container.read(firstRunTourStopProvider), TourStop.createStore);

      // Trigger session abort
      container.read(tourSessionAbortedProvider.notifier).abort();

      expect(container.read(firstRunTourStopProvider), TourStop.none);
    });

    test('device abort count >= 3 suppresses the tour stop', () async {
      final container = ProviderContainer(
        overrides: [
          currentUserRoleProvider.overrideWithValue(_role('ceo')),
          allStoresProvider.overrideWith((ref) => Stream.value(<StoreData>[])),
          hasLocalProductsProvider.overrideWith((ref) => Stream.value(false)),
          firstLoadSkeletonActiveProvider.overrideWithValue(false),
          tourSessionAbortedProvider.overrideWith(TourSessionAbortedNotifier.new),
          tourDeviceAbortCountProvider.overrideWith(TourDeviceAbortCountNotifier.new),
          tourRemoteOffSwitchProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);

      await container.read(allStoresProvider.future);
      await container.read(hasLocalProductsProvider.future);

      container.read(tourDeviceAbortCountProvider.notifier).setCount(3);

      expect(container.read(firstRunTourStopProvider), TourStop.none);
    });

    test('remote off-switch suppresses the tour stop', () async {
      final container = ProviderContainer(
        overrides: [
          currentUserRoleProvider.overrideWithValue(_role('ceo')),
          allStoresProvider.overrideWith((ref) => Stream.value(<StoreData>[])),
          hasLocalProductsProvider.overrideWith((ref) => Stream.value(false)),
          firstLoadSkeletonActiveProvider.overrideWithValue(false),
          tourSessionAbortedProvider.overrideWith(TourSessionAbortedNotifier.new),
          tourDeviceAbortCountProvider.overrideWith(TourDeviceAbortCountNotifier.new),
          tourRemoteOffSwitchProvider.overrideWithValue(true),
        ],
      );
      addTearDown(container.dispose);

      await container.read(allStoresProvider.future);
      await container.read(hasLocalProductsProvider.future);

      expect(container.read(firstRunTourStopProvider), TourStop.none);
    });
  });
}
