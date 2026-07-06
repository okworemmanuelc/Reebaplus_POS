/// VAT (value-added tax) is an **opt-in, per-business** setting: not every
/// business is registered/authorised to charge it, so it is OFF by default and
/// only surfaces once the CEO enables it in Settings → Business Info.
///
/// Storage is the synced `settings` key/value table (like `default_currency`),
/// so enabling it needs no schema migration and propagates across devices:
///   • `vat_enabled`  — `'true'` / `'false'` (absent ⇒ disabled)
///   • `vat_rate_bps` — the rate in **basis points** (`750` = 7.5%), absent ⇒ 0
///
/// Phase 1 (this change) surfaces the VAT **due on the period's net sales** in
/// the standardized daily closing only. Adding VAT to the cart/receipt at
/// checkout is deliberately parked for a later slice.
library;

const String kVatEnabledKey = 'vat_enabled';
const String kVatRateBpsKey = 'vat_rate_bps';

/// Nigeria's standard VAT rate (7.5%), a sensible default when a business first
/// enables VAT and hasn't typed a rate yet.
const int kDefaultVatRateBps = 750;

/// Parsed VAT configuration for a business. [enabled] gates every VAT surface;
/// [rateBps] is the rate in basis points (750 = 7.5%). A row that is enabled
/// with a zero/blank rate yields no VAT (guarded by callers via [computeVatKobo]).
class VatConfig {
  const VatConfig({required this.enabled, required this.rateBps});

  final bool enabled;
  final int rateBps;

  static const VatConfig off = VatConfig(enabled: false, rateBps: 0);

  /// The rate as a display percentage string, trimming a trailing `.0`
  /// (`750` → `"7.5"`, `2000` → `"20"`).
  String get ratePercentLabel {
    final pct = rateBps / 100.0;
    return pct == pct.roundToDouble()
        ? pct.toStringAsFixed(0)
        : pct.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
  }
}

/// VAT (in kobo) charged on a [baseKobo] amount (net sales) at [rateBps] basis
/// points, rounded half-away-from-zero to the nearest kobo — the same rounding
/// the rest of the money math uses. Returns 0 for a non-positive base or rate,
/// so an enabled-but-unconfigured business shows no phantom VAT.
int computeVatKobo(int baseKobo, int rateBps) {
  if (baseKobo <= 0 || rateBps <= 0) return 0;
  return (baseKobo * rateBps / 10000).round();
}

/// Parse the stored `vat_rate_bps` string into basis points, tolerating a blank
/// or malformed value (⇒ 0). Accepts an integer bps string (`'750'`).
int parseVatRateBps(String? raw) {
  if (raw == null) return 0;
  final v = int.tryParse(raw.trim());
  return (v == null || v < 0) ? 0 : v;
}
