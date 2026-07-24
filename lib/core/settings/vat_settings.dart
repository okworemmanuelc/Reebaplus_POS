/// VAT (value-added tax) is an **opt-in, per-business** setting: not every
/// business is registered/authorised to charge it, so it is OFF by default and
/// only surfaces once the CEO enables it in Settings → Business Info.
///
/// Storage is the synced `settings` key/value table (like `default_currency`),
/// so enabling it needs no schema migration and propagates across devices:
///   • `vat_enabled`  — `'true'` / `'false'` (absent ⇒ disabled)
///   • `vat_rate_bps` — the rate in **basis points** (`750` = 7.5%), absent ⇒ 0
///   • `vat_basis`    — `'inclusive'` / `'exclusive'` (absent ⇒ **inclusive**)
///
/// Phase 1 (this change) surfaces the VAT **due on the period's net sales** in
/// the standardized daily closing only. Adding VAT to the cart/receipt at
/// checkout is deliberately parked for a later slice.
library;

const String kVatEnabledKey = 'vat_enabled';
const String kVatRateBpsKey = 'vat_rate_bps';
const String kVatBasisKey = 'vat_basis';

/// Nigeria's standard VAT rate (7.5%), a sensible default when a business first
/// enables VAT and hasn't typed a rate yet.
const int kDefaultVatRateBps = 750;

/// Whether a shop's recorded prices already INCLUDE VAT (inclusive) or the VAT
/// is charged on top (exclusive). Most SMEs price VAT-inclusive, so inclusive is
/// the default (#176 product decision): the exclusive formula overstated the
/// liability by a factor of (1+r) for an inclusive-price shop.
enum VatBasis { inclusive, exclusive }

/// Parsed VAT configuration for a business. [enabled] gates every VAT surface;
/// [rateBps] is the rate in basis points (750 = 7.5%); [basis] selects how the
/// due figure is computed from recorded takings. A row that is enabled with a
/// zero/blank rate yields no VAT (guarded by callers via [computeVatKobo]).
class VatConfig {
  const VatConfig({
    required this.enabled,
    required this.rateBps,
    this.basis = VatBasis.inclusive,
  });

  final bool enabled;
  final int rateBps;
  final VatBasis basis;

  static const VatConfig off = VatConfig(enabled: false, rateBps: 0);

  /// The rate as a display percentage string, trimming a trailing `.0`
  /// (`750` → `"7.5"`, `2000` → `"20"`).
  String get ratePercentLabel {
    final pct = rateBps / 100.0;
    return pct == pct.roundToDouble()
        ? pct.toStringAsFixed(0)
        : pct.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
  }

  /// Short label for the active basis, for card copy ("inclusive"/"exclusive").
  String get basisLabel =>
      basis == VatBasis.inclusive ? 'inclusive' : 'exclusive';
}

/// VAT (in kobo) on a [baseKobo] amount (period net sales) at [rateBps] basis
/// points, computed on the chosen [basis] and rounded half-away-from-zero to the
/// nearest kobo — the same rounding the rest of the money math uses. Returns 0
/// for a non-positive base or rate, so an enabled-but-unconfigured business
/// shows no phantom VAT.
///
///   • [VatBasis.exclusive] — prices EXCLUDE VAT, so the base is net and VAT is
///     added on top: `base × rate`.
///   • [VatBasis.inclusive] — prices INCLUDE VAT, so the recorded takings
///     already contain it and the VAT portion is `base × rate / (1 + rate)` —
///     never `(1 + rate) ×` the net, which overstated an inclusive shop's
///     liability (₦100,000 @ 7.5% ⇒ ₦6,977 inclusive, not ₦7,500).
int computeVatKobo(
  int baseKobo,
  int rateBps, {
  VatBasis basis = VatBasis.inclusive,
}) {
  if (baseKobo <= 0 || rateBps <= 0) return 0;
  switch (basis) {
    case VatBasis.exclusive:
      return (baseKobo * rateBps / 10000).round();
    case VatBasis.inclusive:
      return (baseKobo * rateBps / (10000 + rateBps)).round();
  }
}

/// Parse the stored `vat_rate_bps` string into basis points, tolerating a blank
/// or malformed value (⇒ 0). Accepts an integer bps string (`'750'`).
int parseVatRateBps(String? raw) {
  if (raw == null) return 0;
  final v = int.tryParse(raw.trim());
  return (v == null || v < 0) ? 0 : v;
}

/// Parse the stored `vat_basis` string, defaulting to **inclusive** for any
/// absent/blank/unrecognized value (#176 product decision).
VatBasis parseVatBasis(String? raw) =>
    raw?.trim().toLowerCase() == 'exclusive'
        ? VatBasis.exclusive
        : VatBasis.inclusive;
