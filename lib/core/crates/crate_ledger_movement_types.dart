/// The closed set of `crate_ledger.movement_type` values (PRD #284 decision 15).
///
/// The wire values mirror the Drift `customConstraints` CHECK on `CrateLedger`
/// and the cloud CHECK re-issued in
/// `supabase/migrations/0179_crate_count_movements.sql`. A value outside this
/// list is rejected on both sides, and a client that writes one before the
/// cloud migration lands jams its outbox — so the cloud CHECK always ships
/// first.
library;

// ── The original six ─────────────────────────────────────────────────────────

/// Crates handed to a customer with a sale.
const String kCrateMovementIssued = 'issued';

/// Crates coming back (from a customer) or going back (to a manufacturer).
const String kCrateMovementReturned = 'returned';

/// Stored empties damaged or lost (§17.2).
const String kCrateMovementDamaged = 'damaged';

/// A generic system correction: pool credits, cancel compensations, the v63
/// opening-balance seed. **Never a count** — since #290 a count has its own
/// types below, so the Crate Shortage can be derived from count rows alone.
const String kCrateMovementAdjusted = 'adjusted';

/// One leg of a store-to-store move (§16.9).
const String kCrateMovementTransferredIn = 'transferred_in';

/// The other leg of a store-to-store move (§16.9).
const String kCrateMovementTransferredOut = 'transferred_out';

// ── PRD #284 ─────────────────────────────────────────────────────────────────

/// A **Crate Count Correction**: someone counted a brand's empties at a store
/// and the ledger was moved by `counted − expected`. Store-stamped and
/// attributed (`performed_by`), always. A count below expected is what opens a
/// Crate Shortage (#293).
const String kCrateMovementCount = 'count';

/// An **Opening Count**: the first count of a brand at a store — no earlier
/// [kCrateMovementCount] or [kCrateMovementOpeningCount] row exists for that
/// `(manufacturer, store)`. It sets the number and raises no shortage, so years
/// of unreliable pre-release numbers never surface as this week's loss.
const String kCrateMovementOpeningCount = 'opening_count';

/// The crate leg of a **full crate of drinks** being damaged (#299). Shown in
/// the brand's Damaged status but never part of the Empties Pool — it was
/// never an empty.
const String kCrateMovementFullCrateDamage = 'full_crate_damage';

/// Crates bought from a manufacturer into a store's warehouse (#294). Carries
/// the price paid in `rate_per_crate_kobo`; writes no money leg.
const String kCrateMovementPurchase = 'purchase';

/// Every value `crate_ledger.movement_type` may hold.
const List<String> kCrateLedgerMovementTypes = [
  kCrateMovementIssued,
  kCrateMovementReturned,
  kCrateMovementDamaged,
  kCrateMovementAdjusted,
  kCrateMovementTransferredIn,
  kCrateMovementTransferredOut,
  kCrateMovementCount,
  kCrateMovementOpeningCount,
  kCrateMovementFullCrateDamage,
  kCrateMovementPurchase,
];

/// The two movement types that are counts. A `(manufacturer, store)` with any
/// row of either type has had its Opening Count.
const List<String> kCrateCountMovementTypes = [
  kCrateMovementCount,
  kCrateMovementOpeningCount,
];
