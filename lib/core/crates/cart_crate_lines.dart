/// The rules for reading crates off a cart, kept out of the widget layer so
/// they can be tested without a harness and stated once instead of per screen.
///
/// A cart line is an untyped `Map<String, dynamic>` (see `CartService`), so
/// every read here is defensive about missing keys: a Quick-Sale line carries
/// no crate fields at all.
library;

/// Whether this line's empties are tracked as crates.
///
/// The gate is unit == bottle AND trackEmpties, matching the write side exactly
/// — `createOrder` re-reads both from the product before it books any crate
/// ledger row. Unit is nullable by design (#108): no unit means "not a bottle",
/// so PET and packs never leak into a crate count.
bool lineBearsCrates(Map<String, dynamic> line) =>
    (line['unit'] as String?)?.toLowerCase() == 'bottle' &&
    (line['trackEmpties'] as bool? ?? false);

/// The crate-bearing lines of [items].
///
/// [isCrate] is the business-type gate (§13.4 / rule #13): empty-crate features
/// exist only for Bar / Beer Distributor businesses. A non-crate business can
/// still hold a legacy bottle product with trackEmpties on, so gating here
/// empties everything downstream — deposit lines, the crate lines handed to
/// checkout, the warning below — in one place.
List<Map<String, dynamic>> crateBearingLines(
  List<Map<String, dynamic>> items, {
  required bool isCrate,
}) {
  if (!isCrate) return const [];
  return items.where(lineBearsCrates).toList();
}

/// The per-crate deposit this line is currently valued at (kobo).
///
/// Held equal to the brand's canonical `manufacturers.deposit_amount_kobo` by
/// `CartCrateSync`; 0 when that has never been configured.
int lineCrateValueKobo(Map<String, dynamic> line) =>
    (line['emptyCrateValueKobo'] as int?) ?? 0;

/// Names of the crate-bearing lines whose crate value is not configured —
/// deduplicated and sorted, so the warning reads the same on every rebuild.
///
/// "Not configured" is a non-positive value. It is NOT a blocking condition:
/// the sale completes and the empties are still recorded as owed. What it costs
/// is the money on them — `createOrder` writes `depositRateKobo: 0` on the
/// order's crate line and issues the crate debt at ₦0 — which is invisible
/// unless something says so.
List<String> unconfiguredCrateValueProducts(
  List<Map<String, dynamic>> crateLines,
) {
  final names = <String>{
    for (final line in crateLines)
      if (lineCrateValueKobo(line) <= 0) (line['name'] as String?) ?? 'Item',
  }.toList();
  names.sort();
  return names;
}
