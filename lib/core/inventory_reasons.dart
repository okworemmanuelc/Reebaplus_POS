// Stock-movement reason classifiers (domain vocabulary shared by the
// reconciliation engine and stock screens). Pure string predicates (#574).

/// A stock adjustment is a damage/loss when its reason names one. Catches both
/// recording paths (§17.2): Record Damages stamps `damage:<key>`; a Manager/CEO
/// manual removal stores the free-text reason ("Theft", "Damage"…). Excludes
/// count reconciliations ("Daily stock count adjustment"), deletion sweeps and
/// `initial_stock`, so a shortage is never double-counted as a damage.
bool isDamageReason(String reason) {
  final r = reason.toLowerCase();
  return r.startsWith('damage') ||
      r.startsWith('theft') ||
      r.startsWith('expired') ||
      r.startsWith('spilled') ||
      r.startsWith('broken');
}

/// A damage/loss reason that specifically names expiry (spoilage past date).
/// The ADR 0014 stock flow-equation card breaks **Expired** out of Damages as
/// its own line. Record Damages stamps `damage:expired` (`stock_count_screen`);
/// a Manager/CEO free-text removal stores "Expired". Both contain "expired", so
/// match on that, case-insensitively. Callers pair this with [isDamageReason]:
/// a non-expired damage is `isDamageReason(r) && !isExpiredReason(r)`.
bool isExpiredReason(String reason) => reason.toLowerCase().contains('expired');

/// A stock-increment reason that names a goods RECEIPT (stock coming in), for
/// the ADR 0014 flow-equation "Goods received" line. Both Receive Stock and Add
/// Product opening stock route through `adjustStock` with the reason "Stock
/// received"; a few synonyms are accepted for robustness. Count reconciliations
/// ("Daily stock count adjustment") and manual removals are deliberately NOT
/// receipts — they fall to the "other movements" residual.
bool isReceiptReason(String reason) {
  final r = reason.toLowerCase();
  return r.contains('received') ||
      r.contains('receipt') ||
      r.contains('restock') ||
      r.contains('opening') ||
      r.contains('initial');
}

/// The machine reason a product-delete write-off stamps (#170 #7c) — matches
/// `InventoryDao.productDeletedReason` verbatim, kept as a local const so the
/// pure recon compute needn't reach into the DAO layer. #176 breaks these rows
/// out of the stock card's "Other movements" residual as their own labelled
/// line ("Product deletions") so a delete can't hide a loss unlabeled.
const String kProductDeletedReason = 'product_deleted';

/// A product-delete write-off adjustment (#170 #7c / #176). Exact match on the
/// machine reason — never a substring, so a free-text "deleted extra" removal
/// stays in the residual.
bool isProductDeleteReason(String reason) => reason == kProductDeletedReason;

/// A daily-stock-count reconciliation adjustment ("Daily stock count
/// adjustment", `stock_count_screen`) — the count-correction class #176 breaks
/// out of the stock card's "Other movements" residual as its own line ("Count
/// corrections"). Matches the "stock count" phrase (not a bare "count", which
/// would also catch "dis**count**"/"ac**count**" in a free-text removal reason).
bool isCountReconciliationReason(String reason) =>
    reason.toLowerCase().contains('stock count');

/// §17.2 crate-aware damages — FULL crate lost. When a damaged tracked-bottle
/// product also forfeits its refundable crate deposit because the full crate
/// (item + its container) was lost, Record Damages appends this suffix to the
/// `damage:<key>` reason. The held-empties pool is untouched — that container
/// was never a returned empty — so only the deposit is forfeited on the
/// Statement. The suffix keeps the `damage:` prefix so [isDamageReason] still
/// classifies the row. Deposit basis is 1 tracked bottle unit = 1 crate (the
/// same basis `watchFullCratesByManufacturer`/`createOrder` use).
///
/// The other fate — a STORED empty was damaged — is a crate-only loss: no drink
/// is involved, so it removes no bottle stock and writes no stock_adjustment. It
/// is recorded purely as a `damaged` crate_ledger movement
/// ([InventoryDao.recordEmptyCrateDamage]); its forfeited deposit is summed from
/// that ledger in [computeReconData], not from a damage reason.
const String kCrateLostSuffix = '+cratelost';

/// True when a damage reason forfeits the per-crate deposit (a full crate lost).
bool damageForfeitsFullCrate(String reason) =>
    reason.toLowerCase().contains(kCrateLostSuffix);
