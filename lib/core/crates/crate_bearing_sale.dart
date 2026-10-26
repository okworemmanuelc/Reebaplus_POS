import 'package:reebaplus_pos/core/industry/industry.dart';

/// A product's crate-relevant facts, as read from the DB (never the cart map).
typedef CrateProductFacts = ({String? unit, bool trackEmpties});

/// Whether one product is a crate-tracked bottle: unit `bottle` (compared
/// case-insensitively) AND "track empties" on. The per-line half of
/// [isCrateBearingSale].
bool isCrateTrackedBottle(CrateProductFacts p) =>
    p.unit?.toLowerCase() == 'bottle' && p.trackEmpties;

/// **THE crate-bearing-sale rule** (§13.4 / rule #13, PRD #337).
///
/// A Sale is *crate-bearing* when ALL of these hold:
///  1. the business is a crate business type ([isCrateBusiness], Bar / Beer
///     Distributor), AND
///  2. the business tracks empties — `businesses.tracks_empty_crates`, where
///     `null` is treated as **true** (the column default, and how
///     `OrdersDao.createOrder` reads it), AND
///  3. at least one line's product is a crate-tracked bottle
///     ([isCrateTrackedBottle]).
///
/// Quick Sale lines (no product) never count: callers simply omit them from
/// [products]. Those are the same three gates `createOrder` applies before it
/// writes any crate row, and the one place Checkout (status decision) and the
/// Empty-Crates sheet (skip guard) both read.
///
/// Checkout creates the Order `pending` only when this is true; every other
/// sale is born `completed`.
bool isCrateBearingSale({
  required String? businessType,
  required bool? tracksEmptyCrates,
  required Iterable<CrateProductFacts> products,
}) {
  if (!isCrateBusiness(businessType)) return false;
  if (!(tracksEmptyCrates ?? true)) return false;
  return products.any(isCrateTrackedBottle);
}
