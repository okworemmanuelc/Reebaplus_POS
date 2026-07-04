// Seam 2 — Persona-aware first-run surface state (issue #34, ADR 0006).
//
// Two layers, both asserting external behaviour (which surface a given set of
// inputs resolves to), never widget internals:
//   1. `computeFirstRunSurfaceState` — the pure derivation, exhaustive over the
//      three inputs and their precedence.
//   2. `firstRunSurfaceStateProvider` — the live wiring, driven purely through
//      its input providers in a ProviderContainer (no widget tree, no database):
//      the product-presence stream, the shared first-load skeleton signal, and
//      the add-product gate. Prior art:
//      test/providers/business_scoped_stream_test.dart (drives a provider
//      through states via overrides) and test/dashboard/get_started_checklist_test.dart.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/features/sync/controllers/first_load_overlay_controller.dart';

/// A resolved [GateContext] that grants (or denies) `products.add` — the sole
/// key `Gates.addProduct` evaluates. Role rank is set consistently but only the
/// granted key matters to this gate.
GateContext _ctx({required bool canAddProduct}) => GateContext(
      grantedKeys: canAddProduct ? {'products.add'} : <String>{},
      roleRank: canAddProduct ? 0 : 2,
      isReady: true,
    );

/// Drives [firstRunSurfaceStateProvider] through its three input providers only.
Future<FirstRunSurfaceState> _evaluate({
  bool hasProducts = false,
  bool firstLoadInProgress = false,
  bool canAddProduct = true,
}) async {
  final container = ProviderContainer(
    overrides: [
      hasLocalProductsProvider.overrideWith((ref) => Stream.value(hasProducts)),
      firstLoadSkeletonActiveProvider.overrideWithValue(firstLoadInProgress),
      gateContextProvider.overrideWithValue(_ctx(canAddProduct: canAddProduct)),
    ],
  );
  addTearDown(container.dispose);

  // Let the overridden product stream deliver its first value before reading the
  // derived provider (a StreamProvider is `loading` until it emits).
  await container.read(hasLocalProductsProvider.future);
  return container.read(firstRunSurfaceStateProvider);
}

void main() {
  group('computeFirstRunSurfaceState (pure)', () {
    test('products present → hasContent, regardless of the other inputs', () {
      for (final inProgress in [false, true]) {
        for (final canAdd in [false, true]) {
          final s = computeFirstRunSurfaceState(
            hasProducts: true,
            firstLoadInProgress: inProgress,
            canAddProduct: canAdd,
          );
          expect(s, FirstRunSurfaceState.hasContent,
              reason: 'inProgress=$inProgress canAdd=$canAdd');
        }
      }
    });

    test('first load in progress + zero products → skeleton, never the CTA', () {
      // Even when the user COULD add a product, a still-streaming catalogue must
      // show the skeleton, so the CTA never flashes over the download (#11).
      final s = computeFirstRunSurfaceState(
        hasProducts: false,
        firstLoadInProgress: true,
        canAddProduct: true,
      );
      expect(s, FirstRunSurfaceState.skeleton);
    });

    test('settled + zero products + can add → addProductCta', () {
      final s = computeFirstRunSurfaceState(
        hasProducts: false,
        firstLoadInProgress: false,
        canAddProduct: true,
      );
      expect(s, FirstRunSurfaceState.addProductCta);
    });

    test('settled + zero products + cannot add → neutralEmpty', () {
      final s = computeFirstRunSurfaceState(
        hasProducts: false,
        firstLoadInProgress: false,
        canAddProduct: false,
      );
      expect(s, FirstRunSurfaceState.neutralEmpty);
    });
  });

  group('firstRunSurfaceStateProvider (input overrides)', () {
    test('streaming in (pull not settled) → skeleton even with zero products',
        () async {
      final s = await _evaluate(
        firstLoadInProgress: true,
        canAddProduct: true,
      );
      expect(s, FirstRunSurfaceState.skeleton);
    });

    test('settled + zero products + products.add → addProductCta', () async {
      final s = await _evaluate(canAddProduct: true);
      expect(s, FirstRunSurfaceState.addProductCta);
    });

    test('settled + zero products without products.add → neutralEmpty',
        () async {
      final s = await _evaluate(canAddProduct: false);
      expect(s, FirstRunSurfaceState.neutralEmpty);
    });

    test('products present → hasContent (no CTA)', () async {
      // Products present wins even if the gate would otherwise deny.
      final s = await _evaluate(hasProducts: true, canAddProduct: false);
      expect(s, FirstRunSurfaceState.hasContent);
    });
  });
}
