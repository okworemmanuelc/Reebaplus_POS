/// Persona-aware first-run surface state (Seam 2 — issue #34, ADR 0006).
///
/// A first-time CEO who just created their business should land on their real
/// (empty) Point of Sale / Inventory and be told exactly what to do — "Add your
/// first product" — while a cashier who cannot add products sees a neutral "a
/// manager can add them" message instead. Neither must ever flash while the
/// catalogue is still streaming in on a joining staff member's device
/// (invariant #11).
///
/// This unit answers one question for the POS and Inventory empty states: given
/// (the first pull settled?, are there local products?, may this user add
/// products?), which of four surfaces should the empty body show —
/// `{ skeleton, addProductCta, neutralEmpty, hasContent }`?
///
/// The top half is a pure, widget-free, Riverpod-free derivation
/// ([computeFirstRunSurfaceState]); the provider below wires it to the live app
/// signals it reuses — [firstLoadSkeletonActiveProvider] (the same "still
/// streaming in" signal the tab skeletons key off, so a CTA never flashes over a
/// downloading catalogue), [hasLocalProductsProvider], and `Gates.addProduct`
/// via [gateContextProvider]. Both halves are unit-tested via input overrides.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/sync/controllers/first_load_overlay_controller.dart';

/// The four first-run surfaces the POS / Inventory empty body can present.
enum FirstRunSurfaceState {
  /// The first-load treatment: the catalogue is still streaming in (or between
  /// silent retries). Never a CTA — invariant #11.
  skeleton,

  /// Settled, genuinely zero products, and this user may add products: the
  /// primary "Add your first product" call to action.
  addProductCta,

  /// Settled, genuinely zero products, but this user cannot add products: a
  /// no-button "a manager can add them" message.
  neutralEmpty,

  /// The catalogue has products — render the grid, no first-run surface.
  hasContent,
}

/// Pure derivation of the first-run surface for an empty POS / Inventory body.
///
/// Rules (ADR 0006):
/// - Products present always wins → [FirstRunSurfaceState.hasContent] (the grid
///   renders; no first-run surface). A populated catalogue is never a first run.
/// - While the first load is still in progress → [FirstRunSurfaceState.skeleton]
///   even with zero products, so the "Add your first product" CTA never flashes
///   over a catalogue that is still downloading (invariant #11).
/// - Settled with zero products splits on the add-product gate:
///   [FirstRunSurfaceState.addProductCta] when the user may add products,
///   [FirstRunSurfaceState.neutralEmpty] otherwise.
FirstRunSurfaceState computeFirstRunSurfaceState({
  required bool hasProducts,
  required bool firstLoadInProgress,
  required bool canAddProduct,
}) {
  if (hasProducts) return FirstRunSurfaceState.hasContent;
  if (firstLoadInProgress) return FirstRunSurfaceState.skeleton;
  return canAddProduct
      ? FirstRunSurfaceState.addProductCta
      : FirstRunSurfaceState.neutralEmpty;
}

/// The derived first-run surface state for the POS and Inventory empty bodies
/// (Seam 2). Composes the live product-presence stream, the shared first-load
/// "still streaming in" signal, and the add-product gate through
/// [computeFirstRunSurfaceState]. Consumed by [FirstRunEmptyState] on both
/// screens so the two empty states stay in lockstep.
final firstRunSurfaceStateProvider = Provider<FirstRunSurfaceState>((ref) {
  final hasProducts = ref.watch(hasLocalProductsProvider).valueOrNull ?? false;

  // The exact signal the tab skeletons key off: true while a first-load pull is
  // streaming (or between silent retries) with the store still empty. Reusing it
  // keeps the CTA and the skeleton in lockstep, so neither flashes over the
  // other (invariant #11).
  final firstLoadInProgress = ref.watch(firstLoadSkeletonActiveProvider);

  final canAddProduct = Gates.addProduct.rule.evaluate(
    ref.watch(gateContextProvider),
  );

  return computeFirstRunSurfaceState(
    hasProducts: hasProducts,
    firstLoadInProgress: firstLoadInProgress,
    canAddProduct: canAddProduct,
  );
});
