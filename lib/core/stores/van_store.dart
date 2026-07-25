/// The van predicate — the single place the app decides "is this location a
/// van?" (#140, van-sales spec §4.1, ADR 0019).
///
/// A van is a `stores` row with `kind = 'van'`. Modelling it as a location is
/// what buys the van real per-SKU inventory, transfers, FIFO costing and
/// offline sync for free — but it also means every surface that says "store"
/// would happily show one. So the exclusion is centralised here rather than
/// spread as `kind == 'van'` comparisons: **this file holds the only van test
/// in the codebase.**
///
/// What is excluded and what is not (spec §4.1 — the distinction is the whole
/// point):
///
/// * **Revenue and per-store figures exclude vans.** Store pickers, store
///   lists, the orders list, `reconStoreFilter`, the profit report and the
///   dashboard tiles all drop van locations, so a warehouse cashier never sees
///   or sells van stock and All-Stores revenue is never inflated by road sales
///   that carry no cost against them yet.
/// * **Assets do NOT exclude vans.** `inventoryOnHandKobo` and
///   `businessNetPositionKobo` count van stock on the All-Stores view: goods on
///   wheels are still the company's, and excluding them would make net worth
///   drop by the value of every load. They fall out naturally when a concrete
///   store is locked, because a van is never the locked store for a non-driver.
library;

import 'package:reebaplus_pos/core/database/app_database.dart';

/// True when [store] is a van rather than a normal location.
///
/// The `StoreData`-typed predicate — the form most call sites want, because
/// they already hold the row. Use [VanStores] when all you have is a store id.
bool isVanStore(StoreData store) => store.kind == kStoreKindVan;

/// Every non-van location in [stores], input order preserved.
///
/// The workhorse for pickers and store lists: `withoutVans(allStores)`.
List<StoreData> withoutVans(Iterable<StoreData> stores) =>
    [for (final s in stores) if (!isVanStore(s)) s];

/// Every van in [stores], input order preserved.
///
/// Vans are hidden from the normal lists, so they need one list of their own —
/// the Vans section in Settings → Stores today, the Van Sales hub in #141.
List<StoreData> onlyVans(Iterable<StoreData> stores) =>
    [for (final s in stores) if (isVanStore(s)) s];

/// The business's van locations, in the shape a store-**id**-keyed filter
/// needs.
///
/// Report scopes (`reconStoreFilter`, the profit report's order set, the
/// dashboard tiles) see an order's `storeId`, not its store row, so they ask
/// `vans.isVan(order.storeId)`. Holding the id set in one value keeps that a
/// single lookup instead of a list scan per row.
class VanStores {
  const VanStores(this.ids);

  /// The empty scope — a business with no vans, and the value every
  /// van-unaware test fixture wants.
  const VanStores.none() : ids = const <String>{};

  /// Derives the scope from a full store list (typically `allStoresProvider`).
  factory VanStores.of(Iterable<StoreData> stores) =>
      VanStores({for (final s in stores) if (isVanStore(s)) s.id});

  /// The ids of every van in the business.
  final Set<String> ids;

  /// True when this business has no vans at all — the common case, and worth
  /// short-circuiting on before building a filtered copy of anything.
  bool get isEmpty => ids.isEmpty;

  /// True when [storeId] names a van. A null id (a legacy, pre-store row) is
  /// never a van.
  bool isVan(String? storeId) => storeId != null && ids.contains(storeId);

  /// The complement of [isVan] — reads better inside a `where`.
  bool isNotVan(String? storeId) => !isVan(storeId);
}
