// Seam 2 — Persona-aware first-run surface state (issue #34, #231, ADR 0006).
//
// Two layers, both asserting external behaviour (which surface a given set of
// inputs resolves to), never widget internals:
//   1. `computeFirstRunSurfaceState` — the pure derivation, exhaustive over the
//      inputs and their precedence (hasContent > skeleton > createStoreCta > addProductCta > neutralEmpty).
//   2. `firstRunSurfaceStateProvider` and `zeroStoresEmptySurfaceProvider` — the live wiring,
//      driven purely through its input providers in a ProviderContainer (no widget tree, no database):
//      the product-presence stream, the all-stores stream, the shared first-load skeleton signal,
//      and the permission gates (`Gates.addProduct`, `Gates.manageStores`).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/sync/controllers/first_load_overlay_controller.dart';

/// A resolved [GateContext] that grants (or denies) `products.add` and `stores.manage`.
GateContext _ctx({
  bool canAddProduct = true,
  bool canCreateStore = true,
}) {
  final keys = <String>{};
  if (canAddProduct) keys.add('products.add');
  if (canCreateStore) keys.add('stores.manage');
  return GateContext(
    grantedKeys: keys,
    roleRank: (canAddProduct || canCreateStore) ? 0 : 2,
    isReady: true,
  );
}

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

/// Drives [firstRunSurfaceStateProvider] through its input providers only.
Future<FirstRunSurfaceState> _evaluate({
  bool hasProducts = false,
  bool hasStores = true,
  bool firstLoadInProgress = false,
  bool canAddProduct = true,
  bool canCreateStore = true,
}) async {
  final container = ProviderContainer(
    overrides: [
      hasLocalProductsProvider.overrideWith((ref) => Stream.value(hasProducts)),
      allStoresProvider.overrideWith(
        (ref) => Stream.value(hasStores ? [_store('s1')] : <StoreData>[]),
      ),
      firstLoadSkeletonActiveProvider.overrideWithValue(firstLoadInProgress),
      gateContextProvider.overrideWithValue(
        _ctx(canAddProduct: canAddProduct, canCreateStore: canCreateStore),
      ),
    ],
  );
  addTearDown(container.dispose);

  // Let the overridden streams deliver their first value before reading.
  await container.read(hasLocalProductsProvider.future);
  await container.read(allStoresProvider.future);
  return container.read(firstRunSurfaceStateProvider);
}

void main() {
  group('computeFirstRunSurfaceState (pure)', () {
    test('products present → hasContent, regardless of all other inputs', () {
      for (final inProgress in [false, true]) {
        for (final canAdd in [false, true]) {
          for (final hasStores in [false, true]) {
            for (final canCreateStore in [false, true]) {
              final s = computeFirstRunSurfaceState(
                hasProducts: true,
                firstLoadInProgress: inProgress,
                canAddProduct: canAdd,
                hasStores: hasStores,
                canCreateStore: canCreateStore,
              );
              expect(
                s,
                FirstRunSurfaceState.hasContent,
                reason:
                    'inProgress=$inProgress canAdd=$canAdd hasStores=$hasStores canCreate=$canCreateStore',
              );
            }
          }
        }
      }
    });

    test('first load in progress + zero products → skeleton, never CTA', () {
      // Even when the user could create store or add product, a still-streaming
      // catalogue or store list must show the skeleton.
      for (final hasStores in [false, true]) {
        for (final canCreateStore in [false, true]) {
          for (final canAdd in [false, true]) {
            final s = computeFirstRunSurfaceState(
              hasProducts: false,
              firstLoadInProgress: true,
              canAddProduct: canAdd,
              hasStores: hasStores,
              canCreateStore: canCreateStore,
            );
            expect(s, FirstRunSurfaceState.skeleton);
          }
        }
      }
    });

    test('settled + zero products + zero stores + can create store → createStoreCta', () {
      final s = computeFirstRunSurfaceState(
        hasProducts: false,
        firstLoadInProgress: false,
        canAddProduct: true,
        hasStores: false,
        canCreateStore: true,
      );
      expect(s, FirstRunSurfaceState.createStoreCta);
    });

    test('settled + zero products + zero stores + cannot create store → neutralEmpty', () {
      final s = computeFirstRunSurfaceState(
        hasProducts: false,
        firstLoadInProgress: false,
        canAddProduct: true, // even if canAddProduct is true, zero stores gates it
        hasStores: false,
        canCreateStore: false,
      );
      expect(s, FirstRunSurfaceState.neutralEmpty);
    });

    test('settled + zero products + has stores + can add → addProductCta', () {
      final s = computeFirstRunSurfaceState(
        hasProducts: false,
        firstLoadInProgress: false,
        canAddProduct: true,
        hasStores: true,
        canCreateStore: true,
      );
      expect(s, FirstRunSurfaceState.addProductCta);
    });

    test('settled + zero products + has stores + cannot add → neutralEmpty', () {
      final s = computeFirstRunSurfaceState(
        hasProducts: false,
        firstLoadInProgress: false,
        canAddProduct: false,
        hasStores: true,
        canCreateStore: false,
      );
      expect(s, FirstRunSurfaceState.neutralEmpty);
    });
  });

  group('firstRunSurfaceStateProvider (input overrides)', () {
    test('streaming in (pull not settled) → skeleton even with zero products', () async {
      final s = await _evaluate(
        firstLoadInProgress: true,
        canAddProduct: true,
        canCreateStore: true,
        hasStores: false,
      );
      expect(s, FirstRunSurfaceState.skeleton);
    });

    test('settled + zero products + zero stores + stores.manage → createStoreCta', () async {
      final s = await _evaluate(
        hasStores: false,
        canCreateStore: true,
      );
      expect(s, FirstRunSurfaceState.createStoreCta);
    });

    test('settled + zero products + zero stores without stores.manage → neutralEmpty', () async {
      final s = await _evaluate(
        hasStores: false,
        canCreateStore: false,
      );
      expect(s, FirstRunSurfaceState.neutralEmpty);
    });

    test('settled + zero products + has stores + products.add → addProductCta', () async {
      final s = await _evaluate(
        hasStores: true,
        canAddProduct: true,
      );
      expect(s, FirstRunSurfaceState.addProductCta);
    });

    test('settled + zero products + has stores without products.add → neutralEmpty', () async {
      final s = await _evaluate(
        hasStores: true,
        canAddProduct: false,
      );
      expect(s, FirstRunSurfaceState.neutralEmpty);
    });

    test('products present → hasContent (no CTA)', () async {
      final s = await _evaluate(
        hasProducts: true,
        hasStores: false,
        canAddProduct: false,
        canCreateStore: false,
      );
      expect(s, FirstRunSurfaceState.hasContent);
    });
  });

  group('zeroStoresEmptySurfaceProvider', () {
    test('returns true when zero stores and settled', () async {
      final container = ProviderContainer(
        overrides: [
          hasLocalProductsProvider.overrideWith((ref) => Stream.value(false)),
          allStoresProvider.overrideWith((ref) => Stream.value(<StoreData>[])),
          firstLoadSkeletonActiveProvider.overrideWithValue(false),
          gateContextProvider.overrideWithValue(_ctx(canCreateStore: true)),
        ],
      );
      addTearDown(container.dispose);

      await container.read(hasLocalProductsProvider.future);
      await container.read(allStoresProvider.future);
      expect(container.read(zeroStoresEmptySurfaceProvider), isTrue);
    });

    test('returns false when stores are present', () async {
      final container = ProviderContainer(
        overrides: [
          hasLocalProductsProvider.overrideWith((ref) => Stream.value(false)),
          allStoresProvider.overrideWith((ref) => Stream.value([_store('s1')])),
          firstLoadSkeletonActiveProvider.overrideWithValue(false),
          gateContextProvider.overrideWithValue(_ctx(canCreateStore: true)),
        ],
      );
      addTearDown(container.dispose);

      await container.read(hasLocalProductsProvider.future);
      await container.read(allStoresProvider.future);
      expect(container.read(zeroStoresEmptySurfaceProvider), isFalse);
    });

    test('returns false when firstLoadInProgress is true', () async {
      final container = ProviderContainer(
        overrides: [
          hasLocalProductsProvider.overrideWith((ref) => Stream.value(false)),
          allStoresProvider.overrideWith((ref) => Stream.value(<StoreData>[])),
          firstLoadSkeletonActiveProvider.overrideWithValue(true),
          gateContextProvider.overrideWithValue(_ctx(canCreateStore: true)),
        ],
      );
      addTearDown(container.dispose);

      await container.read(hasLocalProductsProvider.future);
      await container.read(allStoresProvider.future);
      expect(container.read(zeroStoresEmptySurfaceProvider), isFalse);
    });

    test('returns false and skeleton when allStoresProvider emits an error', () async {
      final container = ProviderContainer(
        overrides: [
          hasLocalProductsProvider.overrideWith((ref) => Stream.value(false)),
          allStoresProvider.overrideWith((ref) => Stream<List<StoreData>>.error(Exception('db error'))),
          firstLoadSkeletonActiveProvider.overrideWithValue(false),
          gateContextProvider.overrideWithValue(_ctx(canCreateStore: true)),
        ],
      );
      addTearDown(container.dispose);

      await container.read(hasLocalProductsProvider.future);
      // Wait for stream to emit error
      try {
        await container.read(allStoresProvider.future);
      } catch (_) {}

      expect(container.read(firstRunSurfaceStateProvider), FirstRunSurfaceState.skeleton);
      expect(container.read(zeroStoresEmptySurfaceProvider), isFalse);
    });
  });
}
