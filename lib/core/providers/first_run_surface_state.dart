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
/// `{ waitingForFirstDownload, addProductCta, neutralEmpty, hasContent }`?
///
/// The top half is a pure, widget-free, Riverpod-free derivation
/// ([computeFirstRunSurfaceState]); the provider below wires it to the live app
/// signals it reuses — [firstDownloadInProgressProvider] (the shared "first
/// download has not finished" signal, so a CTA never flashes over a downloading
/// catalogue), [hasLocalProductsProvider], and `Gates.addProduct`
/// via [gateContextProvider]. Both halves are unit-tested via input overrides.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_download_state.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';

/// The first-run surfaces the POS / Inventory and other reachable empty bodies can present.
enum FirstRunSurfaceState {
  /// The first download on this phone has not finished (or the store list is
  /// still being read), so nothing is known yet. The empty body stays blank:
  /// never a CTA, never a "nothing here" message — invariant #11.
  waitingForFirstDownload,

  /// Settled, genuinely zero stores, and this user may create stores: the
  /// primary "Create your first store" call to action. Outranks addProductCta.
  createStoreCta,

  /// Settled, has stores, genuinely zero products, and this user may add products: the
  /// primary "Add your first product" call to action.
  addProductCta,

  /// Settled, genuinely zero stores/products, but this user cannot create/add: a
  /// no-button neutral empty message that never mentions the owner.
  neutralEmpty,

  /// The catalogue has products — render the grid, no first-run surface.
  hasContent,
}

/// Pure derivation of the first-run surface for an empty body.
///
/// Rules (ADR 0006, Issue #231):
/// - Products present always wins → [FirstRunSurfaceState.hasContent] (the grid
///   renders; no first-run surface). A populated catalogue is never a first run.
/// - While the first load is still in progress →
///   [FirstRunSurfaceState.waitingForFirstDownload] even with zero
///   products/stores, so CTAs never flash over a stream (invariant #11).
/// - Settled with zero stores splits on the manage-stores gate:
///   [FirstRunSurfaceState.createStoreCta] when the user may create stores (outranking addProductCta),
///   [FirstRunSurfaceState.neutralEmpty] otherwise.
/// - Settled with stores but zero products splits on the add-product gate:
///   [FirstRunSurfaceState.addProductCta] when the user may add products,
///   [FirstRunSurfaceState.neutralEmpty] otherwise.
FirstRunSurfaceState computeFirstRunSurfaceState({
  required bool hasProducts,
  required bool firstLoadInProgress,
  required bool canAddProduct,
  required bool hasStores,
  required bool canCreateStore,
}) {
  if (hasProducts) return FirstRunSurfaceState.hasContent;
  if (firstLoadInProgress) return FirstRunSurfaceState.waitingForFirstDownload;
  if (!hasStores) {
    return canCreateStore
        ? FirstRunSurfaceState.createStoreCta
        : FirstRunSurfaceState.neutralEmpty;
  }
  return canAddProduct
      ? FirstRunSurfaceState.addProductCta
      : FirstRunSurfaceState.neutralEmpty;
}

/// The derived first-run surface state for empty bodies (Seam 2, Issue #231).
/// Composes the live product-presence stream, the active store list, the shared
/// first-load "still streaming in" signal, and the permission gates through
/// [computeFirstRunSurfaceState]. Consumed by [FirstRunEmptyState] and reachable
/// screens so empty states stay in lockstep.
final firstRunSurfaceStateProvider = Provider<FirstRunSurfaceState>((ref) {
  final hasProducts = ref.watch(hasLocalProductsProvider).valueOrNull ?? false;

  // The shared first-download signal (#313): true from sign-in until the first
  // pull for this business completes — including before the pull starts and
  // under the "Setting up…" overlay — so a CTA never shows over a catalogue
  // that simply has not downloaded yet (invariant #11).
  final firstLoadInProgress = ref.watch(firstDownloadInProgressProvider);

  final storesAsync = ref.watch(allStoresProvider);
  final storesStillResolving =
      (storesAsync.isLoading || storesAsync.hasError) && !hasProducts;
  final stores = storesAsync.valueOrNull;

  final canAddProduct = Gates.addProduct.rule.evaluate(
    ref.watch(gateContextProvider),
  );
  final canCreateStore = Gates.manageStores.rule.evaluate(
    ref.watch(gateContextProvider),
  );

  return computeFirstRunSurfaceState(
    hasProducts: hasProducts,
    firstLoadInProgress: firstLoadInProgress || storesStillResolving,
    canAddProduct: canAddProduct,
    hasStores: stores != null && stores.isNotEmpty,
    canCreateStore: canCreateStore,
  );
});

/// True when the business has zero stores and should show the store-creation
/// empty surface (or neutral empty surface for non-owners).
final zeroStoresEmptySurfaceProvider = Provider<bool>((ref) {
  final surface = ref.watch(firstRunSurfaceStateProvider);
  if (surface == FirstRunSurfaceState.createStoreCta) return true;
  if (surface == FirstRunSurfaceState.neutralEmpty) {
    final storesAsync = ref.watch(allStoresProvider);
    if (storesAsync.isLoading || storesAsync.hasError) return false;
    final stores = storesAsync.valueOrNull;
    return stores != null && stores.isEmpty;
  }
  return false;
});
