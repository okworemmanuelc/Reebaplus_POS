/// Which manufacturers the inventory Empty Crates tab lists (#389) — one pure
/// rule over plain data, no database or provider imports.
///
/// Empty crates exist only for returnable bottles (`unit == 'bottle' &&
/// trackEmpties`), so a can / PET / pack-only brand has none and is left out.
/// A brand that still has crates on the books in the current view is kept even
/// when its last tracked bottle product was removed or changed: hiding it would
/// hide crates (and the deposit money behind them) the shop still holds or is
/// short of.
library;

/// Whether one manufacturer belongs on the Empty Crates tab.
///
/// [hasTrackedBottleProduct] — it owns a non-deleted `bottle` product with
/// `trackEmpties` on. [emptyCount] / [shortCount] — its empties pool and open
/// Crate Shortage in the view the tab shows (the locked store, or All Stores).
bool showsOnEmptyCrates({
  required bool hasTrackedBottleProduct,
  required int emptyCount,
  required int shortCount,
}) => hasTrackedBottleProduct || emptyCount != 0 || shortCount != 0;
