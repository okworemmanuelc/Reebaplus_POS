# Progress Tracker

Update this file after every meaningful implementation change.
The agent reads this file at the start of every session to restore full context.
The human updates it when resolving open questions or making architectural decisions.

---

## Current Phase

152 sessions logged. Codebase is live and being verified on-device.

### Money integrity #1 (#169) — payments compensating-row seam + sync/schema plumbing (prefactor) — CODE-COMPLETE (2026-07-24)
Root prefactor of the #155 money-integrity PRD (ADR **0021**). Behavior-preserving:
introduces the seam + schema/flag plumbing every later correction slice depends on,
with NO user-visible flow change. Branch `feat/money-integrity-1-payments-seam` off
`main` (HEAD 757a18e).
- **The seam.** New `PaymentTransactionsDao.postReversalPayment` (part file
  `daos_payments.dart`, registered in the `@DriftDatabase` daos list) posts a DATED
  compensating `payment_transactions` row: the ORIGINAL row is left untouched, the
  reversal lands on its OWN `created_at` day (the correction day), copies the
  original's single typed reference (so the exactly-one CHECK holds), inherits/
  overrides `store_id`, and enqueues for sync. Legacy in-place void columns stay
  read-only. The correction paths (cancel / expense reject-delete / top-up void) are
  wired to CALL it in later slices — this prefactor only introduces the verb.
- **Schema (Drift v63→**v64**, cloud `0153_money_integrity_payments_seam.sql`).**
  `payment_transactions` gains nullable `store_id` (stamped on new sale / expense /
  crate-refund rows; joins the ledger immutable-column set); `orders` gains nullable
  `confirmed_by` (unused until #171); the payment-type CHECK is widened via the
  established constraint-migration pattern (rebuild locally, DROP+re-add CHECK on
  cloud) to add the deposit-distinct **`crate_deposit`** type (unused until #175).
  The new type CHECK string:
  `CHECK (type IN ('sale','purchase','expense','refund','wallet_topup','crate_deposit'))`.
  All `*_kobo` columns stay bigint. v64 addColumn(store_id) BEFORE the TableMigration
  rebuild (else drift fills the new column with the literal name), then recreates the
  two indexes + three triggers (bump + immutable + no-delete). Cloud re-bakes the
  payment append-only trigger so `store_id` is immutable there too.
- **scrubCreatedAt for the crate ledgers.** `crate_ledger` + `supplier_crate_ledger`
  were NOT previously flagged (only wallet / supplier-ledger / payment were) — ADDED
  `scrubCreatedAt: true` in `sync_registry.dart`, closing the latent void-push P0001
  orphan trap before any crate-void feature ships. Golden test's frozen scrub set
  widened to match.
- **Cash-flow day-basis invariant (no-op today).** Verified the reconciliation
  cash-flow summary already counts each payment row on its OWN `created_at` day
  (`inSpan(p.createdAt)`), and no report sums cash by sale-day — the invariant the
  correction slices rely on. Comment updated; no code change needed.
- **Tests (TDD).** `test/payments/reversal_payment_seam_test.dart` (3: original
  untouched + lands on own day; enqueued as upsert; store/amount overridable);
  `test/database/migration_upgrade_test.dart` v63→v64 (confirmed_by + store_id added,
  widened CHECK admits crate_deposit, legacy row store_id NULL, triggers/indexes
  recreated, store_id now immutable); `test/sync/normalize_payload_whitelist_test.dart`
  crate-ledger + supplier-crate-ledger void re-push drops created_at.
- **Verification.** `flutter analyze` clean (0/0 project-wide). Full `flutter test` =
  **1023 pass / 110 skip / 1 fail** — the lone failure `who_is_working_screen_test` is
  the pre-existing environmental Supabase-400 flake (auth code untouched here).
- **Deviations / follow-ups.** `store_id` is stamped where a store is trivially in
  scope (sale / expense / crate-refund payment rows + the seam); the wallet top-up
  path (`CreditLedgerService.topUp/recordRepayment`) has NO store param today, so
  those new rows stay `store_id`-null (still valid → business-wide) until a later
  slice threads store context — a feature-layer change out of this prefactor's scope.
  DO NOT push/deploy the cloud migration; the orchestrator sequences merge/deploy.

### Crate pool #6 (#163) — net-position honesty (subtract held deposits + supplier debt) — CODE-COMPLETE (2026-07-24)
Sixth slice of the crate-pool ledger-as-truth refactor (PRD #156, ADR 0020).
Branch `feat/crate-pool-net-position-honesty` off `feat/crate-pool-cancel-completes-ledger`
(#162, HEAD 0c7488b — #163 is STACKED on #162, not main). Makes the Daily
Reconciliation "Business worth right now" figure (`businessNetPositionKobo`)
honest about crate liabilities: it already books the physical empties as an
ASSET (`crateDepositKobo`); this slice ALSO subtracts the two matching crate
LIABILITIES. This comes last because it is only trustworthy once the balances
are ledger-derived (#158/#159/#160/#162).
- **Two liability legs, both ledger-derived + business-wide.** (1) Held customer
  crate deposits — the money we still owe customers back on return — reuses the
  existing `crateDepositSummaryProvider.heldKobo` (the `crate_deposit` wallet
  family net: taken − refunded − forfeited). (2) Supplier crate debt — empties we
  owe suppliers for the full crates they delivered — a NEW business-wide derived
  read `CratePoolDao.watchSupplierCrateDebtValueKobo()` = `SUM(quantity_delta)`
  per manufacturer across EVERY supplier × that manufacturer's current
  `depositAmountKobo`, summed (the all-suppliers roll-up of #160's
  `watchSupplierCrateDebt`, same join to the current deposit rate). Surfaced via
  the new `supplierCrateDebtValueKoboProvider`.
- **The getter.** `businessNetPositionKobo` = `inventoryOnHand + customerDebt +
  crateAsset − supplierPayable − heldCustomerDeposits − supplierCrateDebt`. Both
  crate legs are valued at the SAME current per-manufacturer deposit rate as the
  physical-empties asset, so the asset and its two liabilities net symmetrically.
  Gated on `showCrates` (a non-crate business carries no crate legs — they'd be 0
  anyway: no deposit-family wallet rows, no `supplier_crate_ledger`). A shop
  holding deposits and owing suppliers now shows a LOWER, correct position.
- **UI + export.** The `_businessWorthCard` gains two subtracted lines ("Crate
  deposits held for customers (now)" / "Crate debt owed to suppliers (now)",
  shown only when non-zero) and the CSV export mirrors them (gated on
  `showCrates`), so the displayed breakdown ties to the computed figure.
- **No migration, no writes.** A pure derived read + getter; nothing enqueues,
  no schema change, append-only ledgers untouched. Only reads the ledgers #158–
  #162 already made authoritative.
- **Tests (TDD, red→green).** `test/dashboard/recon_data_test.dart` gains a
  net-position group (asset + both liability legs together; each leg subtracts
  independently; a non-crate business is unchanged; a shop with liabilities shows
  a lower position than the asset-only figure — the exact AC).
  `test/crates/supplier_crate_debt_derived_test.dart` gains a business-wide value
  group (all-suppliers roll-up = Σ net crates × rate; a supplier crate credit
  nets the debt down; a settled brand = 0; re-emits live). Analyzer clean on all
  touched files; `test/crates/` + `test/dashboard/` green (+136).

### Crate pool #5 (#162) — Cancel completes the crate ledger — CODE-COMPLETE (2026-07-24)
Fifth slice of the crate-pool ledger-as-truth refactor (PRD #156, ADR 0020).
Branch `feat/crate-pool-cancel-completes-ledger` off `main` (HEAD 12d0e4f). Makes
**Cancel complete the crate ledger** so a refunded sale leaves no phantom crate
debt and no inflated deposit liability — the A1 prerequisite of ledger-as-truth.
- **No phantom crate debt (crate-track).** `OrdersDao.markCancelled` (v1 path)
  now reverses the crate rows the sale ISSUED to the customer through a new Crate
  Pool seam verb `CratePoolDao.reverseIssuedByCustomer` — the ENQUEUED twin of
  the existing local-only `reverseIssuedByCustomerLocal` (both delegate to a
  shared private `_reverseIssuedByCustomer({required bool enqueue})`). A cancel
  reverses a sale the cloud ACCEPTED, so the compensating `-quantity` 'adjusted'
  `crate_ledger` row is enqueued and SYNCS (peers converge); the demoted
  `customer_crate_balances` cache is decremented locally but never pushed (#158
  local-only projection). The customer's derived crate debt
  (`watchCustomerCrateDebt` = SUM over the ledger) nets back to its exact pre-sale
  value. The crate write stays inside the seam, so `crate_seam_ban_test` is happy.
- **Correct deposit reversal (money-track).** The held `crate_deposit` wallet leg
  is now released with a DEPOSIT-FAMILY `crate_deposit_refunded` debit instead of
  the generic `'void'`. `'void'` is outside `kCrateDepositReferenceTypes`, so it
  landed in the SPENDABLE balance sum (wrongly docking the customer) and never
  offset the `+crate_deposit` credit (leaving "deposits held" permanently
  inflated). `crate_deposit_refunded` — the same release
  `settleCrateDepositReturn` posts — deflates held to 0 and is excluded from
  spendable, so spendable is untouched. The reversal filter also now skips legs
  that are THEMSELVES a reversal/settlement (refund/void + the deposit-family
  debits + the spendable `crate_refund`) so only the ORIGINAL sale legs are
  reversed, never a compensation.
- **Scope + known gap.** v1 (live) cancel path only; the v2 `pos_cancel_order`
  envelope is untouched (its flag stays held off until the RPC mints the reversal
  server-side). No migration — append-only `crate_ledger` + `wallet_transactions`
  rows only. This is the Checkout→Cancel path (an unsettled sale); a full reversal
  of a deposit already SETTLED at Confirm is out of scope — `markCancelled` has no
  status guard, so cancelling an already-settled order would over-release the held
  deposit. That confirm-then-cancel late-refund window is the deferred PRD #156 A6
  (with A3 Confirm idempotency) — flagged here, not built.
- **Tests.** New `test/crates/crate_cancel_completes_ledger_test.dart` (4), TDD
  (verified red against pre-fix `lib`): AC1 crate-track derived debt back to 0 +
  the compensating ledger row syncs (never the cache); AC2 deposits-held deflates
  to 0 with spendable unaffected + the release leg is a deposit-family type, never
  a `'void'` of the deposit amount. Full suite: 1008 pass / 110 skip / 1 fail
  (the pre-existing unrelated `who_is_working_screen_test`).

### Crate pool #7 (#166) — demote `manufacturer_crate_balances` off the push set — CODE-COMPLETE (2026-07-24)
Follow-up slice of the crate-pool ledger-as-truth refactor (PRD #156, ADR 0020).
Branch `feat/crate-pool-manufacturer-demote` off `main` (HEAD 6793ce5, post-#160).
Closes the LAST leak: the business-wide per-manufacturer physical-pool cache was
the one crate balance still pushed as an absolute "balance is now N" row. Its READ
already derived from the ledger (#159's business-wide `watchEmptiesPoolByManufacturer`);
this slice demotes its write/push so it becomes a local-only projection like the
other three caches.
- **The only enqueue removed.** `CratePoolDao.recordCrateReturnByManufacturer`
  (`daos_crates.dart`) was the SOLE site that pushed `manufacturer_crate_balances`
  — it re-read the updated balance and `enqueueUpsert`ed it. That block is gone;
  it now enqueues only the append-only `crate_ledger` row. The local cache
  `customInsert` is untouched (the Crates tab still reads a fresh value).
- **Off the push set.** Removed `'manufacturer_crate_balances': 34` from
  `_tablePushPriority` in `supabase_sync_service.dart`. It was never in
  `_naturalKeyPushConflictTargets` and had no `_backfillTable` call, so no other
  push path remained — comments in both spots updated to say so.
- **Restore-on-pull retained.** The `SyncedTable` isCache entry in
  `sync_registry.dart` stays (a legacy/web/RPC-authored cloud row still restores
  harmlessly into the now-unread projection). The golden test's cache-membership
  set is unchanged — same as `customer_crate_balances` stayed listed after #158.
- **Tests (TDD).** Updated `crate_ledger_dao_dispatch_test.dart` (flag-OFF now
  expects a single `crate_ledger:upsert`, cache still written locally) and added a
  "supplier return never enqueues `manufacturer_crate_balances`" case to
  `empties_pool_derived_test.dart`'s no-absolute-push group. Both red before the
  code change, green after. Full `test/crates/` + `test/sync/` green (+296);
  analyzer clean.
- **Result:** after this slice **no crate balance is pushed to the cloud at all** —
  only the append-only `crate_ledger` / `supplier_crate_ledger` sync. ADR 0020's
  hard contract now holds for all four caches plus the `empty_crate_stock` scalar.

### Crate pool #3 (#159) — physical empties pool derived from the ledger — CODE-COMPLETE (2026-07-23)
Third slice of the crate-pool ledger-as-truth refactor (PRD #156, ADR 0020).
Branch `feat/crate-pool-empties-derived` off `main` (post-#158 merge, HEAD
9d2576e). Flips the **physical empties pool** (business-wide + per-store) from the
`manufacturers.empty_crate_stock` scalar + `store_crate_balances` cache to a live
ledger sum, mirroring #158 exactly.
- **Derived read (the seam owns it).** New
  `CratePoolDao.watchEmptiesPoolByManufacturer({String? storeId})` =
  `SUM(quantity_delta)` over the business's **physical-pool** `crate_ledger` rows
  — the store-stamped, customer-less rows (`store_id IS NOT NULL AND
  customer_id IS NULL`), grouped by manufacturer. With `storeId` null it spans
  every store (business-wide); with a store it confines to it — the SAME set at
  two grouping levels, so **business total == Σ store totals by construction**.
  `InventoryDao.watchEmptyCratesByManufacturer` / `watchTotalCrateAssets`,
  `storeCrateBalancesProvider` (now `Map<String,int>`), `storeEmptiesByManufacturerProvider`,
  the Inventory Crates tab (business + locked-store), and product-detail's
  read-only empties row all forward to it, so the SUM logic lives in one place and
  every surface agrees.
- **Caches demoted to local-only projections.** `manufacturers.empty_crate_stock`
  is removed from the push set via a new `manufacturers` push-column whitelist that
  excludes it (the pool verbs still enqueue the full manufacturer row for the
  NOT-NULL `name`, but the scalar is scrubbed off the wire). `store_crate_balances`
  stops enqueuing in `applyDelta` / `setBalance`. Both keep their local writes
  (crate_pool_seam_test still green) and their `SyncedTable` restore entries
  (restore-on-pull retained, values unread). Only append-only `crate_ledger` rows
  sync for the pool. This kills the counter-only-grows asymmetry (a `returned`
  store-stamped row now pulls the pool down) and the cross-store clamp drift on a
  damaged-empty.
- **Dead reconciler deleted.** `verifyCrateReconciliation` (no callers,
  print-only) removed — the ledger IS the truth (ADR 0020 "retire the dead
  reconciler").
- **Tests.** New `test/crates/empties_pool_derived_test.dart` (10): derived pool
  == store-stamped ledger sum; business == Σ stores after every op; return-to-
  supplier reduces the business total; damaged-empty reduces the right store and
  can't push another store negative; store_crate_balances never enqueued;
  empty_crate_stock scrubbed off the manufacturers push; multi-device convergence
  (two offline tills → merge → derived == combined sum). Updated
  `manufacturer_partial_upsert_test` (updateManufacturerStock scrubs the scalar),
  `sync_registry_golden_test` (manufacturers push whitelist added — both sides in
  one commit), `crate_logic_test` (the business-wide live-refresh case now uses a
  store-stamped credit, matching the store-partitioned pool).
- **Verification.** `flutter analyze` 0/0 on the changed files; full `flutter test`
  = 993 pass, 110 skipped (Tier-2), 1 fail (`who_is_working_screen_test`, the same
  pre-existing environmental network flake as #158 — `PostgrestException 400`
  hitting placeholder Supabase, unrelated to crates). No migration (behavior-
  preserving on the read; the v63 opening seed from #157 already made
  SUM(store-stamped) == the store caches at cutover).
- **Known limitations / left for #160:** a store-LESS `addEmptyCrates` / `recordDamage`
  / manual-set writes a store-less ledger row that the store-partitioned pool
  excludes by design (in practice callers resolve a store); a manufacturer created
  with an opening `emptyCrateStock` (Add Manufacturer dialog) writes no ledger row,
  so the derived pool reads it as 0 (already inconsistent pre-#159); `recordManualCountCorrection`
  still computes its delta from the local store cache (single-device-correct).
  `manufacturer_crate_balances` + `supplier_crate_balances` are still pushed absolute
  (#160). `StoreCrateBalancesDao.watchForStore` is now dead (kept for the restore DAO).

### Crate pool #4 (#160) — supplier crate debt derived + Receive Stock posts both legs — CODE-COMPLETE (2026-07-23)
Fourth slice of the crate-pool ledger-as-truth refactor (PRD #156, ADR 0020).
Branch `feat/crate-pool-supplier-derived` off `main` (post-#158, HEAD 9d2576e).
Flips the **supplier** crate-debt balance from the stored cache to a live ledger
sum (the wallet model), and makes a supplier delivery a one-step operation.
- **Derived read (the seam owns it).** New
  `CratePoolDao.watchSupplierCrateDebt(supplierId)` = `SUM(quantity_delta)` over
  the supplier's `supplier_crate_ledger` rows grouped by manufacturer, inner-
  joined for the display name + current per-manufacturer deposit rate — the exact
  analogue of #158's `watchCustomerCrateDebt`. Returns the existing
  `SupplierCrateBalanceWithManufacturer` type so the Supplier Detail → Empty
  Crates tab is unchanged. `SupplierCrateBalancesDao.watchBySupplier` now just
  forwards to it; the UI (`supplierCrateBalancesProvider`) is untouched.
- **Receive Stock posts BOTH legs in one transaction (B3).** When a delivery
  returns empties, `ReceiveStockService.confirmReceipt` now appends, through the
  seam and inside its existing txn, the physical-pool `crate_ledger` movement
  (`recordCrateReturnByManufacturer`) AND the `supplier_crate_ledger` movement
  (`recordReturnToSupplier`) for the same manufacturer + quantity. One physical
  event → one operation; the stock keeper no longer opens the supplier screen to
  enter the return a second time, so the yard count and the supplier balance can
  no longer disagree.
- **Cache demoted to a local-only projection.** `_appendSupplierMovement` still
  writes `supplier_crate_balances` locally (a legacy/RPC pull row restores
  harmlessly; any local reader stays live) but **no longer `enqueueUpsert`s it** —
  only the append-only `supplier_crate_ledger` row crosses the wire. Also removed
  `supplier_crate_balances` from the sync service's `_tablePushPriority` and
  `_naturalKeyPushConflictTargets` maps (it is now genuinely off the push set).
  The `SyncedTable` registry entry (isCache) is retained — restore-on-pull kept,
  value unread — matching how #158 left `customer_crate_balances`. (There was no
  `_backfillTable(supplierCrateBalances,…)` recovery call to remove — only the
  customer one ever existed.)
- **Tests.** New `test/crates/supplier_crate_debt_derived_test.dart` (9): derived
  debt == ledger sum, fully-settled brand nets to 0, per-(supplier,manufacturer)
  scoping, the Empty-Crates read re-emits live with the deposit rate, the **B3
  regression** (one confirmReceipt updates BOTH the physical pool — summed off
  `crate_ledger` directly, not #159's method — and the supplier balance, one
  supplier ledger row), the cache is never enqueued (receipt + return), the cache
  is still written locally, and the headline **multi-device convergence** (two
  offline tills → merge both supplier ledgers → derived == combined sum). Existing
  `receive_stock_test` + `supplier_crate_test` stay green unchanged (the derived
  read is a drop-in; the supplier leg is additive).
- **Verification.** `flutter analyze` 0 issues on the changed files; full
  `flutter test` = 995 pass, 110 skipped (Tier-2), 1 fail — the lone failure
  `who_is_working_screen_test` is the pre-existing environmental
  Supabase/shared_preferences plugin flake (fails identically in isolation, no
  auth code touched here). No migration — the #157 v63 opening seed already made
  each supplier's ledger sum equal its pre-existing cache value at cutover.
- **Coordinate with #159 (parallel):** expected merge conflicts in
  `daos_crates.dart`, `supabase_sync_service.dart`, and the docs; edits kept
  localized + additive. The physical leg is posted as a manufacturer-owned,
  store-stamped `crate_ledger` row (the rows #159 sums), so the two slices compose.

### Crate pool #2 (#158) — customer crate debt derived from the ledger — CODE-COMPLETE (2026-07-23)
Second slice of the crate-pool ledger-as-truth refactor (PRD #156, ADR 0020).
Branch `feat/crate-pool-customer-derived` off `main` (post-#157 merge, HEAD
7d40fa7). Flips the **customer** crate-debt balance from the stored cache to a
live ledger sum, the way the wallet already works.
- **Derived read (the seam owns it).** New
  `CratePoolDao.watchCustomerCrateDebt(customerId)` = `SUM(quantity_delta)` over
  the customer's `crate_ledger` rows, grouped by manufacturer, inner-joined for
  the display name — the exact analogue of
  `WalletTransactionsDao.watchAllBalancesKobo`. Re-emits live because the
  underlying `crate_ledger` insert is a Drift builder write the stream tracker
  observes. `CustomersDao.watchCrateBalancesWithGroups` (the Crates-tab + the
  crate-debt notifier read) now just forwards to it — the two UI consumers are
  unchanged (`CrateBalanceEntry` type kept).
- **Cache demoted to a local-only projection.** The three customer write paths
  (`recordCrateIssueByCustomer`, `recordCrateReturnByCustomer` flag-off,
  `recordApprovedCustomerReturn` flag-off) still write `customer_crate_balances`
  locally but **no longer `enqueueUpsert` it** — only the append-only
  `crate_ledger` row crosses the wire. This removes the last-write-wins clobber:
  two offline tills' movements both survive the merge and the derived balance is
  their sum. (Registry entry + local writes kept — minimal blast radius; the
  fuller cache removal rides #159/#160 which demote the other three caches.)
- **Tests.** New `test/crates/customer_crate_debt_derived_test.dart` (6): derived
  read == ledger sum, fully-returned brand nets to 0 (not phantom debt), the
  Crates-tab read re-emits live, the cache is never enqueued (both issue + return
  paths), and the headline **multi-device convergence** (two offline tills → merge
  both ledgers → derived == combined sum, nothing clobbered). Updated the two
  dispatch tests (`crate_ledger_dao_dispatch_test`,
  `crate_return_approval_dispatch_test`) to assert the customer cache is no longer
  enqueued — the proof of AC #2. Golden suite (Dart DAO == `pos_record_crate_return`
  RPC ledger rows) unchanged/green — the ledger writes were untouched.
- **Verification.** `flutter analyze` 0/0 on the changed files; full `flutter test`
  = all crate/sync/orders/golden green (985 pass, 110 skipped Tier-2; the lone
  failure `who_is_working_screen_test` is a pre-existing environmental network
  flake, fails identically on clean `main`, unrelated to crates).
- **Docs.** ADR 0020 rollout marks #158 DONE; architecture.md storage row notes
  the customer cache is now local-only (not pushed). No migration (behavior-
  preserving on the read; the v63 opening seed from #157 already made each
  customer's ledger sum equal their pre-existing cache value at cutover).
- **Left for later slices:** `CustomerCrateBalancesDao.watchByCustomer` is dead
  (no consumers) and still reads the cache — left untouched (out of scope; delete
  when the cache is fully retired in #159/#160). The manufacturer/store/supplier
  caches are still pushed absolute (#159/#160).

### Crate pool #1 (#157) — the Crate Pool seam + a complete ledger (prefactor) — CODE-COMPLETE (2026-07-22)
First slice of the crate-pool ledger-as-truth refactor (PRD #156, ADR **0020**).
Branch `feat/crate-pool-seam-prefactor` off `main`. **Behavior-preserving**: the
balance caches are still written exactly as before, so nothing the user sees
changes — this slice only introduces the seam, completes the ledger, and seeds
opening balances so the later derive slices (#158–#160) don't zero existing
counts.
- **The seam.** `CrateLedgerDao` → **`CratePoolDao`** (`daos_crates.dart`), now the
  SOLE writer of the six crate tables (`crate_ledger`, `supplier_crate_ledger`,
  the four `*_crate_balances`) **and** the `manufacturers.empty_crate_stock`
  scalar. Absorbed the supplier-crate write path (`_appendSupplierMovement`), the
  physical-pool verbs (`addEmptiesToPool` / `recordDamage` /
  `recordManualCountCorrection`, moved from `InventoryDao`), and the store-transfer
  legs (`transferBetweenStores`, moved from `StockTransferDao`). Every former
  writer is now a thin delegator (InventoryDao add/damage/manual-set + transfer,
  `SupplierCrateLedgerDao` receipt/return, `CrateReturnApprovalService.approve`,
  Checkout/Confirm/Receive/customer-return callers) — public method names kept, so
  callers and the existing crate test-suite assertions are unchanged. Accessor
  renamed `crateLedgerDao` → `cratePoolDao` (~21 mechanical sites; codegen
  regenerated).
- **Ledger completeness.** The two paths that skipped the ledger now write a row:
  a manual "set to N" records a reconciling **delta** row (N − current); a
  store-less `addEmptyCrates`/damage writes a store-less row.
- **Migration (Drift v62→**v63**).** Data-only `_seedCrateOpeningLedger()` appends
  one reconciling `adjusted` opening row per non-zero cache balance (delta = cache
  − current SUM under that cache's filter), so `SUM(quantity_delta)` == the
  displayed count at cutover. **LOCAL-ONLY** (a migration write never enqueues;
  pushing would double-count across devices). No cloud migration — client-only
  data seed.
- **Guard.** New `test/crates/crate_seam_ban_test.dart` (models
  `sync_raw_write_leak_test`) fails the build if any crate-table write or
  `empty_crate_stock` mutation appears outside the seam; the sync engine +
  `app_database.dart` carry `// crate-seam-exempt-file:` markers (restore /
  DDL-triggers-seed-wipe, not movements).
- **Docs.** ADR `0020-crate-pool-ledger-as-truth.md`; CONTEXT.md gained a
  `### Crates` glossary (Empties Pool, Crate Ledger, Crate Deposit, Held Deposit,
  Money-Track vs Crate-Track). **Lexicon intentionally untouched** — its docstring
  keeps crate/empties nouns out by design (gated by `isCrateBusiness`), so the PRD's
  "keep beverage nouns in the Lexicon" reconciles to "leave them out, as they
  already are."
- **Verification.** `flutter analyze` 0/0; new `crate_pool_seam_test` (5, incl. the
  real v62→v63 migration-seed SUM==cache) + `crate_seam_ban_test` green; the
  existing crate/wallet/supplier/sync-dispatch suites (77) pass unchanged.
- **Noted, not fixed here (out of #157 scope):** `StockTransferDao.cancelTransfer`
  restores product stock but does NOT reverse crate legs (pre-existing gap);
  `recordCrateReceiveFromManufacturer` is dead (no callers); the
  `manufacturer_crate_balances` cache and the `empty_crate_stock` scalar remain two
  disjoint business-side tallies — unifying them and deriving the pool is #159.

### #153 provider-lifecycle crash (re-login) — FIXED (2026-07-20)
QA of the closed batch (during #117 offboarding) surfaced a re-login crash: four
`ChangeNotifierProvider`s returned a **service-owned** `ValueNotifier`, so Riverpod
disposed it out from under its owner (`A ValueNotifier<String?> was used after being
disposed`). Fixed with a non-owning `mirrorNotifier` factory
([mirror_notifier.dart](../lib/core/providers/mirror_notifier.dart)) — all 4 unsafe
sites (`deviceUserId`/`activeCustomer`/`pullStatus`/`isOnline`) plus the 3 pre-existing
safe proxy sites (`currentIndex`/`lockedStore`/`storeExplicitlyChosen`) routed through
it — and a static ban-test guard against any `ChangeNotifierProvider` returning a
borrowed notifier. `flutter analyze` clean, 6 new tests green. Branch
`fix/provider-disposes-service-owned-notifier`, commit `bd1f755` (PR pending). Details
in BUILD_LOG.

### 11-item feature/bug batch — PRD #106 + 13 issues filed; Phase 2 implementation STARTED (2026-07-11)
Ran the full idea→issues flow (`/ask-matt` → `/grill-with-docs` → `/to-prd` →
`/to-issues`) over a raw 11-item backlog (staff offboarding, optional units,
category CRUD, long-press hint, persistent POS search, industry form copy,
beer→beverage, barcode scanning, ListTile ink-splash bug, reports badge, printer
paper size). Grilled item-by-item against the code; several premises corrected by
ground truth.
- **PRD:** issue **#106** (`ready-for-agent`). **Sliced into 13 vertical-slice
  issues #107–#119** (all `ready-for-agent`, parent #106). Dependency chains:
  **#107→#117** (offboarding core→device-wipe/self-resign), **#113→#118** (barcode
  field→POS scan), **#115→#119** (fix stuck approvals count→reports dot). Other ten
  start immediately.
- **New ADRs:** **0016** (staff offboarding — detach-not-delete, free email by
  nulling `auth_user_id`, keep the `users` Attribution Stub, membership→`removed`,
  reuse the invariant-#12 wipe-gate) and **0017** (barcode — build one-shot now via
  `mobile_scanner` + optional `products.barcode`, soft uniqueness). **ADR 0015
  amended:** offer only 3 industries (Beverage/Pharmacy/Frozen Foods) via a
  `selectable` flag; registry keeps all nine so existing tenants don't regress.
- **Glossary (CONTEXT.md):** added Suspend / Offboard / Attribution Stub; refreshed
  the Industry entry. **project-overview.md:** barcode moved into scope (one-shot),
  continuous deferred.
- **Ground-truth corrections found while grilling:** items 6/7 (industry form copy +
  beer→beverage) already ~shipped by ADR 0015 — residual is a small copy audit;
  item 9's bug is `Container(color:)` not `DecoratedBox`, and only **4** real sites
  exist (login picker, stock-count sheet, receive-checkout sheet, CEO-signup crate
  toggle), all fixed by "keep bg, add a see-through Material"; item 10's badge/query
  logic is correct+live — "always 3" = pending approval rows that never clear
  (needs diagnosis).
- **Phase 2 (implementation) STARTED 2026-07-11** via `/git-issue-workflow` per
  issue, each branched off fresh `main` → PR (no self-merge). **First up: this
  foundation docs PR** (`docs/prd-106-domain-model`) landing the CONTEXT/ADR changes
  so every issue branch inherits the glossary + ADRs. Order after: independent quick
  wins (#114/#111/#110/#116, #115→#119), product-form group (#108→#112→#109), barcode
  (#113→#118), then offboarding (#107→#117) **after** the oversell PR #121 (shared
  unsynced-data wipe gate). Reserve migration numbers (0147+) late to dodge
  cross-branch collisions.

### Oversell orphan recovery (notify cashier + cancel) — reversal CODE-COMPLETE; go-live gated on device rollout (2026-07-08; Slice 2c 2026-07-11)
Resolves the A-S6 open question — the human chose: **notify the cashier + offer a
cancel**. Branch `feat/oversell-orphan-recovery` off `main` (post-#105). Gates the
go-live flag flip (below).
- **Slice 1 (notify) — DONE.** When `pos_record_sale_v2` permanently rejects a sale
  (`insufficient_stock`/`inventory_row_missing`), `_pushDomainItems` fires an **alert**
  notification via `_notifyCashierSaleRejected` — targeted at the cashier
  (`recipientUserId = p_actor_id`), linked to the order (`linkedRecordId = p_order_id`):
  "out of stock (likely sold on another till). Review and cancel it." Best-effort (never
  breaks the drain); synced like any notification.
  Test `test/sync/oversell_orphan_notification_test.dart` green.
- **Slice 2b (core local undo) — DONE.** `OrdersDao.reverseRejectedSaleLocal(orderId,
  items, staffId)` returns a device to its pre-sale state after a permanent rejection —
  **local-only, never enqueued** (the rejected sale never reached the cloud): cancels the
  order, refunds inventory from `items` (a v2 sale has no local `stock_transactions` to
  rewind), and reverses the §14.3 wallet double-entry via compensating legs
  (debit→refund credit, credit→void debit). Idempotent. The foreground
  `_compensateRejectedSale` now delegates to it (so the online-checkout rejection path
  ALSO reverses the wallet — previously it left the customer debited). Tests:
  `test/orders/reverse_rejected_sale_test.dart` (walk-in, register-as-credit balance
  restored, idempotency) green; sync/wallet/crates/costing suites green. **This closes
  the #105-introduced money-safety finding** (local wallet correctness on rejection).
- **Cloud-leak fix (held-outbox mechanism) — DONE.** The deeper pre-existing v2 finding
  (below) is fixed the clean way the human chose: Drift **v60** adds
  `sync_queue.held_by_order_id`; on the v2 path `createOrder` HOLDS the sale's child rows
  (cost_batches/crate/wallet — the delta the sale enqueues) so the drain
  (`getPendingItems`) skips them until the `pos_record_sale_v2` envelope CONFIRMS
  (`releaseHeldByOrder`) or is REJECTED (`discardHeldByOrder` → never leak).
  `reconcileHeldRows` (on the periodic tick) is the crash-safe backstop, deciding each
  held order from durable state (pending envelope → keep; orphaned → discard; gone →
  release). Bonus: also removes the offline FK-defer clutter (FK-bound legs no longer
  push before the order exists). Tests `test/sync/held_child_rows_test.dart` (hold /
  release / discard / keep) green; migration v57→v60 green; sync/orders/costing/crates
  (305) green. **Crate-balance reversal — DONE (Slice 2c).** `reverseRejectedSaleLocal`
  now un-issues the LOCAL crate balance too, via `CrateLedgerDao.reverseIssuedByCustomerLocal`
  (customer_crate_balances is LWW, won't self-heal): a compensating `-qty` 'adjusted' ledger
  row nets the sale's 'issued' `+qty` and the cache decrements to pre-sale — local-only, never
  enqueued (the cloud never saw the issue).
- **⚠ Deeper PRE-EXISTING v2 finding (FIXED above by the held mechanism).** On the v2 path
  `createOrder` eagerly ENQUEUES the sale's child rows, and two of them —
  `cost_batches` (FIFO draw-down) and `customer_crate_balances` — **do NOT FK to the
  order**, so on a rejection they PUSH successfully and **corrupt the cloud** (FIFO queue
  wrongly drawn down; a customer wrongly shows owing empties). The FK-bound rows
  (`wallet_transactions`, `crate_ledger`, `order_crate_lines`) correctly orphan instead.
  This predates #105 (v1 never rejects, so it never surfaced). The clean root fix was to
  **defer the child enqueues on the v2 path until the RPC confirms** (write locally, push
  after `_applyDomainResponse`), OR clean the orphaned/pending child rows out of the
  outbox on reversal. Local crate + cost reversal is entangled with this (a purely-local
  crate undo wouldn't stop the cloud leak). Held for a coherent fix + human alignment —
  it's an architecture change to the sale-sync path touching the sacred outbox (#12).
- **Slice 2c (Cancel button UI + background item-sourcing) — DONE (2026-07-11).** The
  `sale_rejected` alert in the notifications modal is now tappable → a plain-language confirm
  dialog → `OrderService.cancelRejectedSale(orderId, staffId)` →
  `OrderCommands.cancelRejectedSale`. Because a v2 sale writes no local `order_items`, the
  command re-sources the sold lines from the orphaned envelope via
  `SyncDao.rejectedSalePayload` (reads `p_items`/`p_store_id` out of `sync_queue_orphans`),
  then runs the complete local reversal (order + inventory + wallet + crate). Idempotent;
  gracefully cancels the phantom header even if the orphan is already gone. Tests:
  `test/orders/cancel_rejected_sale_test.dart` (source-from-envelope / orphan-gone /
  idempotent) + a crate-reversal case in `test/orders/reverse_rejected_sale_test.dart`;
  analyze clean, orders/crates/sync (270) green. **The complete reversal (incl. the crate
  balance) is now shipped in-code.**
- **Go-live flip: HELD** — the reversal is now code-complete (local wallet/inventory/crate all
  FIXED; the cloud cost/crate leak is fixed by the held-outbox mechanism). Still gated on
  shipping this branch to devices + flipping `feature.domain_rpcs_v2.record_sale` per-env.
  (Supabase MCP is disconnected this session, so the flip can't be applied from here anyway.)

### Workstream C (#102) — periodic pull safety net GUARDED — PR #120 OPEN, rebased on main post-B-merge (2026-07-11)
Closes the live-sync/exactly-once loop's independent leg (plan §Workstream C).
Branch `chore/retain-periodic-pull-safety-net` off `origin/main` (post-#105). The
periodic `catchUpPull` was already SHIPPED (#98/#99); C's job is to **keep** it and
make it un-removable, because it is the reconnect-replay backstop that makes
Workstream B's (Broadcast) deliberate "no replay" acceptable.
- **C-S1 (guard the safety net) — DONE.** Behaviour-preserving refactor of the 30 s
  tick in `supabase_sync_service.dart`: the inline `Timer.periodic` body is now
  `_installPeriodicSafetyNet()` (idempotent `??=`) → `_periodicSafetyNetTick()`, with
  four `@visibleForTesting` seams (`installPeriodicSafetyNetForTesting`,
  `isPeriodicSafetyNetActiveForTesting`, `periodicSafetyNetIntervalForTesting`,
  `runPeriodicSafetyNetTickForTesting`). New `test/sync/periodic_safety_net_test.dart`
  (5 tests, green) pins, via the **same** private installer/tick production uses:
  the timer is scheduled idempotently at the **30 s** cadence and **cancelled on
  logout** (`stopAutoPush`); each tick fires the silent `catchUpPull(reason:
  'periodic')` when foreground + online + business-bound; a tick **pulls nothing**
  when logged-out (backgrounded/suspended state) or offline; and — under `fakeAsync`
  — the scheduled 30 s timer actually invokes the pull tick and stops after logout.
  It fails if the safety net is ever silently removed or repointed.
- **C-S2 (cadence) — RESOLVED: KEEP 30 s** (human, 2026-07-11). B (Broadcast) has
  since landed (PR #126, merged) and gives near-instant convergence, so 30 s is the
  right backstop cadence; tighten toward ~10 s only if that proves too slow. No code
  change; the 30 s cadence is now test-pinned so any future change is forced through
  review.
- **C-S3 — DoD + PR.** `flutter analyze` clean; `flutter test test/sync/` 195 green.
  PR `Closes #102`; stop for human merge. Invariants: none touched — behaviour-
  preserving refactor, no schema/migration, outbox/append-only ledgers untouched.

### Broadcast live-signal (#101, Workstream B) — MERGED (PR #126, commit 3a8c1af, 2026-07-11)
All slices (B0–B7) done on branch `feat/broadcast-live-signal` (off `origin/main`
post-A-merge). A (#100) is merged (PR #105). **Re-framing:** the B0 gate (run
2026-07-11) found the original premise stale — `postgres_changes` is **no longer
refused** (the full 54-binding channel joins + delivers CDC after #96/#97), so B is
now **additive** (a writer-agnostic signal + a signal the web can subscribe to),
not a rescue. **Decision surfaced for the human:** the plan intended B to *replace*
`postgres_changes`, but it works now — so this PR **keeps both** (belt-and-
suspenders) and does **not** rip out the working `postgres_changes` path; retiring
it is a separate follow-up decision.
- **B1 — emit trigger (migration `0147`, DEPLOYED + verified).** One generic
  `zz_broadcast_sync_signal()` `AFTER INSERT/UPDATE/DELETE` trigger, attached to
  every `public` base table with a `business_id` (+ `businesses`) via a DB-driven
  loop — **60 tables**. Emits minimal `{table,id,op}` (no row data) to
  `store_<business_id>` via `realtime.send(...,'sync',...,private:=true)`.
  Write-safe (`EXCEPTION WHEN OTHERS THEN NULL`), fires last (`zz_` name, AFTER),
  skips no-op updates, `SECURITY DEFINER SET search_path=''`, and `EXECUTE`
  revoked from client roles (advisor flagged the RPC exposure — trigger fires
  regardless of the grant). Verified live via a rolled-back txn: an UPDATE emits
  the exact payload; the write succeeds; no-op-vs-bump behaviour understood
  (a bump trigger moves `last_updated_at`, so peers correctly learn the row
  changed). **Redundant-emit note:** a few not-app-synced tables (`devices`,
  `console_audit`, …) also emit — harmless (a debounced, redundant pull), never a
  correctness issue. Possible future optimisation (not done, keeps to spec):
  STATEMENT-level triggers would cut per-row volume (a multi-row INSERT = 1 emit).
- **B2 — RLS (migration `0148`, DEPLOYED + verified).** Exactly one `SELECT`
  policy on `realtime.messages` scoping topic `store_<business_id>` to
  `current_user_business_ids()` (profiles-based). **No `INSERT` policy** — clients
  only receive; the trigger emits as a definer, so a client can't spoof a signal.
  Verified via JWT-claim impersonation: own topic allowed, another tenant's
  denied, `realtime.topic()` integrates. **Op note (surface to human):** full
  private-channel *enforcement* also wants "Allow public access" OFF in the
  dashboard Realtime settings (can't be set from SQL); the app always joins with
  `private:true`, so the RLS gate applies regardless.
- **B3 — transport seam (ADR 0001).** `CloudTransport.startBroadcast(businessId,
  {onSignal})` / `stopBroadcast()`. `SupabaseCloudTransport` opens one private
  channel on `store_<biz>` (`setAuth` before subscribe, `replay` deliberately
  unset — ephemeral). `InMemoryCloudTransport` fake captures the callback +
  `emitBroadcastSignal()`; `onSignal` is a **bare `void Function()`** (no payload)
  — the structural guarantee that a signal can't write Drift.
- **B4 — signal → pull.** Broadcast starts/stops on the SAME lifecycle as
  realtime (piggybacks `startRealtimeSync` / `_tearDownRealtimeChannels`, so
  sign-in / resume / connectivity / logout all covered). `_onBroadcastSignal`
  resolves the *current* business (like the periodic tick) → debounced
  `catchUpPull(reason:'broadcast')`. Coexists with `postgres_changes`.
- **B5 — coexistence + no-replay.** Test proves convergence rides the periodic /
  reconnect pull (C), independent of any broadcast — a missed signal still
  recovers.
- **B6 — web reception is OUT OF SCOPE here.** Filed follow-up
  **`okworemmanuelc/reebaplus-web#55`** (web subscribes to the same
  `store_<biz>` topic, reacts by refetch/invalidate, NOT a Drift pull). web-pos
  moved to `reebaplus-web` per PR #104.
- **B7 — DoD.** `flutter analyze` clean project-wide (0 err/0 warn). `flutter
  test test/sync/` 198 green (incl. new `broadcast_signal_test.dart` +
  `cloud_transport_seam_test` broadcast fidelity). **End-to-end Tier-2 test**
  (`test/integration/broadcast_signal_live_test.dart`, `@Tags(['integration'])`,
  committed + env-gated) proves the full path against real dev Supabase: a
  service-role write on TEST_BUSINESS_ID delivered `{table:products,id,op:UPDATE}`
  to a subscribed private-channel client on `store_<biz>` in ~4s — B1+B2+B3
  composed. Invariants confirmed by name: #1 (Broadcast never writes Drift; only
  schedules a pull), #5 (per-tenant RLS, no cross-tenant leak), #10 (pull cursor
  path unchanged), #12 (outbox untouched).

### Exactly-once stock integrity (#100, Workstream A) — MERGED via PR #105 (2026-07-08)
All 8 slices (A-S0…A-S7) done; **PR #105** (`fix/exactly-once-stock-integrity` →
`main`) opened `Closes #100`. Stop-for-human-merge. Two decisions carried in the PR:
the **go-live flag flip** (per-env ops, fix inert until flipped) and the **orphan-UX
recovery flow** (undefined product behaviour, logged not invented). Workstream C (#102)
is independent and may proceed alongside; B (#101) stays blocked until A merges + B0.
Implementing Workstream A of the live-sync/exactly-once loop (plan:
`docs/design/live-sync-exactly-once-implementation-plan.md`, PRD:
`context/specs/brief-live-sync-signal-and-exactly-once.md` — both live on the
`docs/live-sync-exactly-once-prd` branch, not yet on `main`). Branch
`fix/exactly-once-stock-integrity` off `origin/main`.
- **A-S0/A-S1 done.** `test/sync/exactly_once_stock_integrity_test.dart` RED-first
  reproduces the silent oversell on the current v1 path: two devices, stock 1,
  both sell 1 offline (walk-in, so it's a pure stock movement), both push the
  absolute `inventory.quantity=0` row; the natural-key LWW cache collapses them to
  one row at 0 while **two** orders land — 2 sold from 1, no error. Green (it
  documents today's behaviour); flips to the fixed path in A-S3.
- **A-S2 done — committed A1-flag path is UNVIABLE as-is; re-scoped to "Option ①"
  (client-side wallet on the v2 path).** Verified `pos_record_sale_v2` against the
  LIVE db: its STOCK write is exactly what A wants (`SELECT … FOR UPDATE`, relative
  `quantity = quantity - n`, `insufficient_stock`/`inventory_row_missing` P0001,
  `ON CONFLICT (id) DO NOTHING`) with **no schema drift** (`store_id`,
  `stock_transactions.location_id`, null-product quick-sale handled), and
  `_applyDomainResponse` writes back authoritative `inventory_after` as the sole
  local writer (no dup). BUT its **wallet model is incompatible** with the live v1
  path: the RPC posts only a single `p_wallet_amount_kobo` debit (and only when
  >0), whereas v1 posts full double-entry for every registered sale (goods debit of
  total + cash credit of paid + held-deposit carve-out). A blanket flag flip would
  (a) drop wallet history on cash sales and (b) **reject "register-as-credit" sales**
  (`insufficient_wallet_balance` — the RPC has no debt-limit/negative path). The
  inline comment `daos_orders.dart:796-798` ("R2") already flagged this; PRD risk #2
  now confirmed negative. The narrow "route only the inventory delta" alternative is
  forbidden by design (`pos_inventory_delta_v2` rejects `movement_type='sale'`).
  **Human decision (2026-07-08): Option ①** — restructure `createOrder` so the full
  wallet double-entry posts client-side on the v2 path too (exactly as
  `crate_ledger`/`cost_batches` already do), pass `p_wallet_amount_kobo=0` so the
  RPC owns only the oversell-safe stock/order/items/payment, then flip. No
  migration, no money-model change; wallet stays append-only/derived (invariant #3),
  so credit sales work and aren't gated by the RPC's balance check.
- **FK-ordering note for A-S3:** `wallet_transactions.order_id`,
  `crate_ledger.reference_order_id`, `order_crate_lines.order_id` all have enforced
  cloud FKs to `orders`. On v2 the order is minted by the RPC (which must run to
  enforce the guard), so these client-authored children are enqueued before the
  order exists and converge via the engine's FK-deferred retry — the same behaviour
  crate rows already have on the v2 path; the new wallet legs match it.
- **A-S3 done (Option ① implemented) + A-S4 proven.** `OrdersDao.createOrder` now
  posts the wallet double-entry via a new `_postSaleWalletLegs` helper called
  **before** the v1/v2 split, so the legs are client-authored on BOTH paths
  (invariant #3). The v2 envelope no longer carries `p_wallet_amount_kobo` (the RPC's
  wallet branch stays a no-op), and the v2-only `walletDebitKobo` param was removed
  from `createOrder` (it fed only `p_wallet_amount_kobo`; the v1 legs always derived
  from total/paid/deposit). This ALSO removes a latent v2 split-brain: previously v2
  minted only a server-side wallet debit with no local mirror, which would have
  broken cancel/refund/reports on v2 — now v2's wallet rows are byte-identical to
  v1's, so every downstream flow already tested on v1 holds on v2. Tests: the
  headline `exactly_once_stock_integrity_test.dart` gains the v2 group — two devices
  race the last unit, the server accepts the first and **rejects the second**
  (`insufficient_stock` P0001), on-hand never goes below 0, and the loser's envelope
  **orphans visibly** in `sync_queue_orphans` (that orphan assertion is the **A-S4**
  coverage) — plus a lost-ack replay proving `ON CONFLICT DO NOTHING` idempotency (no
  second decrement). Updated `record_sale_dispatch_test` (registered v2 sale posts 2
  local wallet legs + 1 envelope, no `p_wallet_amount_kobo`; and a
  register-as-credit v2 sale nets −150000 and is never gated by the RPC),
  `credit_ledger_logic_test` (2 args), `pr_4c_test` (1 arg). `flutter analyze` clean;
  the affected suites (sync/dispatch/wallet/orders/crates/golden/costing) green.
- **Known v2 convergence characteristic (documented, not a defect).** For a
  registered/crate sale created **offline**, the wallet + crate legs FK-reference an
  `orders` row the RPC mints, but the reconnect drain pushes table rows *before*
  domain envelopes — so the legs FK-fail once (23503) and converge on the next
  FK-deferred retry (~15 min). The **online** checkout path front-runs this: it calls
  `flushSale` right after `createOrder`, which pushes the domain envelope (creating
  the order) before the background drain reaches the legs. This matches the existing
  crate-leg behaviour on v2 and is invisible online; a cheap follow-up (teach the
  push to flush a sale's envelope before its child legs) could remove the offline
  lag. Not fixed here (Option ①: no migration; global push-reorder is out of scope).
- **Go-live flip NOT executed (human/ops decision).** The code is correct on both
  flag states; flipping `feature.domain_rpcs_v2.record_sale` is a per-environment,
  production-wide runtime change that activates the dormant v2 path (crate/cost/wallet
  client rows, thin-item flow, the offline FK-defer above) — surfaced in the PR as a
  one-line reversible config step, not applied autonomously in this loop.
- **A-S5 done (idempotency backstops locked).** (a) *No blind insert* is structural:
  the only cloud-write paths are `enqueueUpsert`/`enqueueDelete` (there is no
  `enqueueInsert`) and the transport always `.upsert()`s — client-id minting is pinned
  by the existing dispatch tests; A-S3's lost-ack replay pins the sale envelope's
  push-side idempotency (`ON CONFLICT DO NOTHING`). (b) *Clobber-guard* (a pending
  local row survives an incoming newer cloud row) is pinned by
  `outbox_sacred_restore_test`. (c) NEW `stock_reprocess_idempotency_test.dart` pins
  the PULL side — restoring the till's OWN just-pushed inventory cache + append-only
  stock ledger (and re-restoring it) does not double-decrement; on-hand equals opening
  + SUM(ledger deltas). Events applied exactly once.
- **A-S6 audit — mutable-balance caches (`isCache` tables).** Verdict per table:
  | Cache table | Movement write | Push shape | Backing ledger | Verdict |
  |---|---|---|---|---|
  | `inventory` | relative (pre-check) | absolute LWW | `stock_transactions` | **FIXED** — v2 guarded RPC (`FOR UPDATE`+relative+`>=n` reject) is authoritative |
  | `customer_crate_balances` | relative (`balance+δ`) | absolute LWW | `crate_ledger` (append-only) | mitigated gap → follow-up |
  | `manufacturer_crate_balances` | relative | absolute LWW | `crate_ledger` | mitigated gap → follow-up |
  | `store_crate_balances` | relative (+ intentional `setBalance` absolute override) | absolute LWW | `crate_ledger` | mitigated gap → follow-up |
  | `supplier_crate_balances` | relative | absolute LWW | `supplier_crate_ledger` | mitigated gap → follow-up |
  The 4 crate caches share inventory's push-absolute-LWW shape, so two devices making
  concurrent **offline** crate movements to the same (owner, manufacturer) can drift
  the cache. **Why lower severity than the stock oversell, and not a #100 gap:** the
  truth is the append-only ledger (both movements survive, id-keyed — no data loss),
  the balance is recomputable (`CrateLedgerDao.verifyCrateReconciliation` = SUM of
  ledger deltas), and a crate tally is not a hard-limited sellable resource that
  silently takes money for nothing — it's a deposit tally reconciliation corrects. The
  `setBalance` absolute write is an intentional manual management-dialog override
  (set-to-known), correctly LWW — not a race. **Genuine gap found (deferred):**
  `verifyCrateReconciliation` is **not auto-wired** (no caller), so cache drift is not
  auto-healed. **Follow-up issue (not #100):** either auto-schedule the reconciliation,
  derive crate balances from the ledger on read (wallet-style), or route crate
  movements through a server-guarded relative RPC mirroring `pos_record_sale_v2`. Not
  fixed here — it's a structural change of A1-ledger's magnitude, outside #100's
  "close the silent stock oversell" scope, and the drift is mitigated, not unbounded.
- **OPEN QUESTION (A-S6, human decision — surfaced, not invented).** When the server
  rejects the 2nd offline sale on the **background reconnect** path (not the foreground
  `flushSale` path, which already compensates + surfaces), the envelope orphans
  **visibly** (Sync Issues) but the local device still shows the order (`pending`) +
  the local inventory pre-check decrement. The cashier **recovery flow** — auto-cancel
  the orphaned order? notify the cashier to re-ring / refund / restock? re-price? — is
  **undefined product behaviour**. The mechanism (detect + surface, never silently
  absorb) is complete and is the #100 goal; the recovery UX is a separate product +
  UI decision (a feature-folder change, which the split rules keep out of this
  sync-integrity PR). Logged for the human; NOT invented here.

### Live cross-device sync ("deleted product still sellable") — in progress (2026-07-07)
On-device debugging of "console changes don't reach the app live." Findings + fixes:
- **Pull works; realtime never delivered.** DB soft-delete + guard already correct
  (#87/#88/#89 merged; migrations 0145/0146 deployed). A manual pull-to-refresh
  clears a console-deleted product; only the *live* path was dead.
- **#93 resubscribe race (PR #94, MERGED).** `restartRealtimeSync` tore channels
  down fire-and-forget then synchronously re-created them; the transport's
  `startRealtime` guard bailed on the not-yet-cleared list → **zero** channels every
  session. Fixed: await teardown before re-subscribe + synchronous `_realtimeActive`
  flip; transport `stopRealtime` clears holders synchronously. Regression test.
- **#95 channel fan-out + #97 socket auth (PR #96, OPEN).** After #93, all ~55
  per-table `postgres_changes` channels errored. Collapsed to **one channel, N
  bindings** (#95) and forced `realtime.setAuth` before subscribe (#97). On-device
  diagnostic proved `socketAlreadyHadSessionToken=true` — **the socket IS authed**,
  yet every `postgres_changes` binding still `channelError → timedOut` and **no
  `supabase_realtime` CDC slot streams to the client**. Server checks ruled out:
  slots not exhausted (2/5), all tables in the publication, `authenticated` has
  SELECT + `business_id`, filter-check passes. **postgres_changes root cause still
  OPEN** (server-side realtime authorization/delivery).
- **Key architecture reconciliation.** `architecture.md` defines Realtime as a
  **signal that triggers a pull, "not the transport for the data itself"** (best-
  effort; Goal #2 / SC#6 say "when realtime sync is healthy"). The implementation
  diverged to direct-apply of 55 `postgres_changes` — the failing path. The
  documented **"periodic fallback poll"** (architecture.md §Pull path) is **NOT
  implemented**: the only `Timer.periodic` (30 s) drains the outbox (push) — there
  is no periodic *pull*, so a foregrounded idle till never converges without a
  working realtime or a manual refresh.
- **DECISION (resolved 2026-07-07):** implement the documented periodic fallback
  **pull** → `catchUpPull` for robust near-live convergence (spec-aligned,
  independent of the broken postgres_changes). Chasing server-side
  `postgres_changes` deferred. #96 (one channel + setAuth) stays as a best-effort
  realtime *signal*.
- **#98 periodic fallback pull — SHIPPED (PR #99, MERGED).** Added the documented
  "periodic fallback poll" to the existing 30 s sync tick: foregrounded + online +
  business-bound → silent, debounced `catchUpPull(reason: 'periodic')` (runs before
  and independent of the push drain). A console edit/soft-delete now converges
  within ~one tick with no manual refresh, regardless of realtime health. Timer
  lifecycle reused (starts at sign-in, cancels at logout, suspends when
  backgrounded). test/sync 186 green; analyze clean. On-device: a deleted product
  stops being sellable within ~30 s.
- **#95/#96/#97 — MERGED (PR #96).** One-channel/N-bindings + `setAuth` landed on
  `main` (`eda0b95`) as a best-effort signal; `postgres_changes` still refused
  server-side (root cause deferred, deprecated path).

#### PRD: live-sync signal + offline-first integrity + exactly-once (2026-07-07)
Investigation → proposal, no code this pass. Spec:
`context/specs/brief-live-sync-signal-and-exactly-once.md`. **Root finding:** fast
convergence makes conflicts *visible* faster but does **not** prevent duplicate
application. IDs are already client-`UuidV7` and push is idempotent `upsert(onConflict:
id)` (single-device retry is exactly-once), and money ledgers are already append-
only/derived (immune). **The gap is on-hand stock: a mutable `inventory.quantity`
balance decremented in place (`daos_orders.dart:539-557`) and pushed as an *absolute*
LWW cache (`sync_registry.dart:652-665`)** — two offline tills selling the last unit
both pass the local guard, both push `quantity=0`, LWW keeps one → **silent oversell**.
The oversell-safe path already exists (`pos_record_sale_v2` `FOR UPDATE` + relative
decrement + `ON CONFLICT (id) DO NOTHING`) but **the flag `feature.domain_rpcs_v2.
record_sale` defaults `'false'`** (0011:1368) so mobile runs the unsafe v1 path; web's
`checkout_order` (0135) is already guarded. **Decision — three sequenced, separable
workstreams (correctness before speed):**
- **A (ship first): exactly-once integrity.** Make stock convergence-safe — flip to the
  server RPC relative-decrement path (fast) and/or derive on-hand from `stock_transactions`
  (structural); audit other mutable-balance caches; lock idempotency backstops with tests.
- **B (on A): Broadcast live-signal.** One generic `TG_TABLE_NAME` trigger over
  `kSyncPullOrder`, one topic per store, one RLS policy, minimal `{table,id,op}` payload,
  client single-channel subscribe → `catchUpPull`. **Emitter is a shared-schema DB trigger,
  writer-agnostic → every device's change (mobile/web/console) broadcasts to all
  subscribers; reception is per-client** (mobile→pull, web→refetch). Never writes Drift.
  **Gated on an on-device proof that Broadcast joins where `postgres_changes` is refused.**
- **C: retain the periodic pull** as the safety net / reconnect-replay backstop (already
  shipped); tighten cadence only if B is delayed/fails.
Tracked as three issues: **#100 (A)**, **#101 (B)**, **#102 (C)**. `postgres_changes`
debugging is an explicit non-goal.

### Multi-industry onboarding & app morphing (PRD #76, ADR 0015) — in progress
Slices: **#77** registry foundation → **#79** enable all nine → **#80** Lexicon on
product forms → **#81** Lexicon on POS/inventory/guides; **#78** synced product
photo (independent). Status:
- ✅ **#77 registry foundation — SHIPPED** (PR #82 merged). One `Industry` enum
  is the single source of truth; `industryOf()` total normalizer; `isCrateBusiness`
  a registry shim. Pure prefactor.
- ✅ **#78 synced product photo — SHIPPED** (PR #83 merged). See entry below.
- ✅ **#79 enable all nine — SHIPPED** (PR #84 merged). Added **Phone & Gadgets**
  + **Frozen Foods & Grocery** to the registry and flipped every `comingSoon`
  off. No UI code changed (onboarding + Settings render from `Industry.catalogue`);
  all nine selectable, crate opt-in still Bar/Beverage-only, industry editable
  with data preserved.
- ✅ **#80 Lexicon on product forms — SHIPPED** (PR #85 merged). New `Lexicon`
  module (per-industry item/unit/category nouns + starter presets + hints, generic
  per-slot fallback; Beverage verbatim) + `industryLexiconProvider`. Add/Update
  Product read all industry-sensitive nouns from it; starter categories surfaced.
- ✅ **#81 Lexicon on POS/inventory/guides — IN REVIEW** (branch
  `feat/lexicon-pos-inventory`). Added `Lexicon.itemPlural` and wired the item
  noun into the POS grid empty state + coach tips, the Inventory tab/FAB/search,
  and the Home/first-run/stock-count empty states + Get Started checklist.
  Beverage unchanged; no slot-sprawl (manufacturer/supplier out of scope). 21
  industry tests; analyze clean; boots on emulator. **Completes PRD #76's
  terminology morph.**

**PRD #76 status: all five slices (#77–#81) DONE.** #77/#78/#79/#80 merged to
main; #81 in review (PR pending). Deeper per-industry features (IMEI, expiry,
cold-chain) are the phased follow-ups (one industry per PR), not this PRD.

### IN REVIEW: Optional synced product photo (issue #78, PRD #76 / ADR 0015)
Branch `feat/product-photo-sync` (off main; independent slice of the
multi-industry epic — no blocker). Owners attach an optional product photo on
Add/Update Product; it uploads to the **product-images** Storage bucket, its URL
syncs onto the product (`products.image_url`, Drift v59 + cloud 0143), a local
cache renders it offline, and a reconnect flush uploads photos saved offline.
`ProductImageService` mirrors `BusinessLogoService`; `ProductPhotoField` is the
shared responsive/theme-aware picker. Off the POS grid + receipts; one per
product. analyze clean, seam + migration tests green, boots on emulator
(`onUpgrade v58→v59` clean); cloud column + bucket + RLS verified. Migration
0142 (web-pos #56, unmerged) leaves a gap before 0143 — reconcile order at merge.

### SHIPPED: Standardized daily closing — declutter + opt-in VAT (2026-07-06)
Reworked the Daily Reconciliation detail screen (§25.9) into one standardized
closing and added opt-in VAT. Branch `feat/standardized-daily-close` (off
`feat/closing-report-reconciliation`; web-pos WIP in `git stash@{0}`).
- **Cash reconciliation dropped** (user: all cash is deposited to an account) —
  no counted drawer / float / over-short, no `daily_closings` table; Hard Rule #8
  stands. The close stays fully **derived + period-aggregatable** (existing
  Day/Week/Month/Year grouping + store→business rollup satisfies "per store
  first, then business-wide").
- **Declutter (Phase A, no schema).** 9 duplicative cards → **5** for CEO
  (Sales, P&L, Cash, Stock reconciliation, Position), **3** for Manager. Deleted
  "Net result (flow)"; merged Shrinkage + Stock audit + Stock reconciliation +
  Integrity into one `_stockReconciliationCard`. `recon_data.dart` model kept
  (17 tests unchanged).
- **VAT (Phase C, settings-backed, no migration).** OFF by default; synced
  `settings` keys `vat_enabled` + `vat_rate_bps` (bps, 750 = 7.5%).
  `vat_settings.dart` (pure `computeVatKobo`) + `vatConfigProvider` +
  `ReconData.vatKobo` (derived on gross − discounts; **pass-through, not in the
  P&L profit**). Sales card + CSV show "VAT due (7.5%)" when enabled; Settings →
  Business Info → **Tax** toggle + rate field.
- **Parked (user request):** VAT on cart/receipt at checkout (mobile + web).
- `flutter analyze` clean; recon (19) + `vat_settings_test` (8) + dashboard/
  settings/ban (77) green. On-device walkthrough pending.

### SHIPPED: Closing-report reconciliation (ADR 0014, 2026-07-05)
Enhanced the Daily Reconciliation (§25.9) into a full closing report. Grilled;
design in **ADR 0014**. Two issues off `main`:
- **#70 — P&L discount fix (SHIPPED — PR #71 MERGED to `main`).** Report booked revenue gross and
  ignored `orders.discountKobo`, overstating profit. Added `ReconData.discountsKobo`
  + `netRevenueKobo`; P&L now Revenue → −Discounts → Net revenue → −COGS; margin on
  net revenue. Branch `fix/recon-pl-discounts`.
- **#72 — closing-report enhancement (branch `feat/closing-report-reconciliation`,
  stacked on #70).**
  - ✅ **Slice 1 — cash-flow summary (committed `676c310`).** Business-wide derived
    cash *movement* from tender-tagged flows (no drawer count — Hard Rule #8).
    `OrdersDao.watchAllPaymentTransactions` + `allPaymentTransactionsProvider`;
    CEO-only card + CSV. `payment_transactions` = unified cash ledger; supplier cash
    from supplier_ledger; no double-count.
  - ✅ **Slice 2 — stock flow-equation card (this branch).** CEO-only stock
    reconciliation: Opening + Goods received − COGS − Damages − Expired (± Other)
    = Expected closing → Variance = Physical − Expected. Valued at **current cost
    throughout**; opening/expected-closing reconstructed by **rewinding the
    `stock_transactions` ledger from current on-hand** (ties out by construction,
    handles historical period-end). Expired split from damages via
    `adjustmentId → reason` (`isExpiredReason`). `StockLedgerDao.watchAllTransactions`
    + `allStockTransactionsProvider`; 7 `stock*Kobo` fields + `stockVarianceKobo`
    / `hasStockFlow` getters; `_stockFlowCard` + CSV. 14 recon tests green.
  - ✅ **Slice 3 — integrity flag (this branch).** CEO-only integrity check:
    reconciles reported P&L profit against the physical count with **no new
    persistence** — surfaces the stock-count variance the flows never booked
    (`integrityAdjustedProfitKobo = netProfit + variance`; `hasIntegrityGap`),
    framed as a recording error, not a real loss. `_integrityCard` + CSV row. 17
    recon tests green. **Epic complete → closes #72.**



### PLANNING: Web POS (online-first browser client) — grilled 2026-07-04, ADRs 0007–0012
- **North star:** full parity — the *entire* app replicated for web — reached in
  phases. **Phase 1 = selling loop + inventory management + reports.** Later phases
  add staff/roles, suppliers & ledgers, expenses, crate management, activity logs,
  settings, onboarding (create-business / join-invite, minus PIN).
- **Architecture decisions (see ADRs):**
  - **0007** Web is **online-first**, not offline-first: live PostgREST/Realtime
    reads + RPC writes, no Drift, no outbox. Offline invariants #1/#4 are
    mobile-scoped, not app-wide.
  - **0008** Web write path = **server-authoritative Postgres RPCs** (checkout,
    receive/adjust stock, ledger posting, order#). Shared contract = schema + RPCs.
  - **0009** Same money rules implemented **twice** (Dart offline / SQL online);
    kept identical by a **shared golden-scenario suite** in CI.
  - **0010** Stack = **Next.js/React + supabase-js** (no Flutter Web, no shared
    client code).
  - **0011** Auth = **per-user Supabase session is the operator** (no PIN, no
    "Who's working?" picker); RLS scope from `profiles.business_id`.
  - **0012** **Monorepo** — new `web-pos/` dir beside `supabase/migrations/`;
    deploy on Vercel.
- **PRD + issues published** (`okworemmanuelc/Reebaplus_POS`, all `ready-for-agent`):
  epic **#46** (`docs/prd/web-pos.md`); slices **#47** skeleton → **#43** cash
  checkout keystone → **#44** credit/wallet → **#45** crate → **#49** realtime →
  **#48** inventory add/receive → **#50** stock-adjust approval → **#51** reports.
  Dependency order: #43←#47; #44/#45←#43; #49/#48/#51←#47; #50←#48.
- **Next:** one fresh session per issue → `/implement` (pass PRD #46 + the single
  issue). Phase-1 keystone is #43 (`checkout_order` RPC + golden-scenario suite).
- CONTEXT.md updated: intro now describes two clients; new **Web** glossary section
  (Web POS, RPC Write API, Golden-Scenario Suite, Operator).

### SHIPPED: Web POS Slice 4 — empty-crate ledger at checkout (2026-07-05, issue #45, ADRs 0008/0009)
- **`checkout_order` extended (migration `0137_checkout_order_crate.sql`).** A plain
  CREATE-OR-REPLACE of the 8-arg 0136 function (same signature → no overload, no
  drop) that adds the §13.4 crate dispatch. For a **registered** customer at a
  business where `_is_crate_business(type) AND tracks_empty_crates` (new SQL helper
  mirrors mobile `isCrateBusiness` — case-insensitive Bar / Beer|Beverage
  distributor, NULL→false), it groups the crate-eligible lines (unit `bottle` +
  `track_empties` + a manufacturer) by manufacturer and posts, per manufacturer:
  one `order_crate_lines` row (crates taken + the deposit **rate** snapshot from
  `manufacturers.deposit_amount_kobo`, frozen at sale time + deposit paid 0), one
  `'issued'` `crate_ledger` row (+crates), and a `customer_crate_balances`
  increment (upsert on the unique key). Byte-for-byte the mobile `OrdersDao.create
  Order` + `CrateLedgerDao.recordCrateIssueByCustomer` **crate-track** branch.
- **No double-count (issue AC).** The crate legs are wholly separate from the drink
  cost/stock/wallet legs — they never touch inventory, `cost_batches`, COGS,
  payment_transactions, or the wallet. Walk-ins (no customer), non-crate businesses,
  and empties-OFF all post no crate rows (the combined gate).
- **Scope = crate-track only.** The web collects no deposit money at checkout, so
  every web crate sale is crate-track (`deposit_paid = 0`) and the wallet legs stay
  exactly 0136's. The money-track deposit carve-out (paid deposit → held
  `crate_deposit` wallet leg, mobile Ring 6) needs a deposit-collection surface and
  is deliberately deferred to a later slice; the deposit **value** is still surfaced
  (rate × crates) as the value of the empties owed.
- **Golden-Scenario Suite extended (ADR 0009).** `golden_scenario.dart` gained
  optional crate inputs (`business_type`, `tracks_empty_crates`, `manufacturers`,
  per-product `manufacturer`) and expected crate rows (`crate_lines` /
  `crate_ledger` / `crate_balances`), all defaulting empty so the 8 cash + 4 credit
  fixtures are untouched. New `crate_sale_scenarios.json` (5 scenarios: single line,
  two manufacturers, mixed crate+non-crate cart, two lines summing to one crate
  line, and the gate-OFF no-op). Both runners seed the business type + manufacturers
  + crate-eligible bottles and collect the crate rows; the **Dart DAO tier runs 17/17
  green** every build (offline), the RPC tier is wired + env-gated (Tier-2).
- **Verified live.** Deployed to dev; ran the **full** `checkout_order` through an
  impersonated (JWT-claim `set_config`) transaction that **rolled back** — a
  registered crate sale minted `WEB-…`, drew FIFO COGS (inventory 100→97, cogs
  50000), posted `order_crate_lines` (3 crates, rate 50000, paid 0), a `crate_ledger`
  `issued` +3 to the customer, `customer_crate_balances` = 3, and the net-zero wallet
  legs — matching the Dart golden field-for-field. Nothing persisted.
- **Web UI (hide-don't-block).** New `web-pos/src/lib/crate.ts`
  (`isCrateBusiness`/`businessTracksCrates`/`crateEligible`/`crateSummary`); the
  catalogue now loads `track_empties` + `manufacturer_id` and joins each product's
  per-manufacturer deposit rate; the operator exposes `business.type`. The **Cart**
  and **Receipt** render an "Empties (returnable)" line (N crates · deposit value)
  only when the business tracks crates AND the cart holds deposit-bearing product —
  hidden entirely otherwise. `npm run typecheck` + `npm run build` green.
- **Scope left for later slices:** Realtime (#49) — crate rows propagate to mobile
  via the existing signalled pull; the money-track deposit path (above); inventory
  add/receive (#48); stock-adjust approval (#50); reports (#51).

### SHIPPED: Web POS Slice 3 — registered-customer credit & the wallet ledger (2026-07-05, issue #44, ADRs 0008/0009)
- **`checkout_order` widened (migration `0136_checkout_order_credit.sql`).** Adds
  `p_customer_id` (dropping the old 7-arg overload first, per the overload trap)
  and two credit paths on top of the Slice 2 cash keystone:
  - **Pay-with-Credit** (`p_payment_method='wallet'`) — draw the whole sale from
    the customer's existing balance; `amount_paid=0`, no cash payment row.
  - **Register-as-Credit-Sale** (`'credit'`) — the customer owes the balance; any
    `p_amount_paid_kobo` part-pays it now (0..net).
  A registered Cash/Transfer sale now ALSO posts its wallet legs, so the ledger
  history is complete. **Wallet legs (append-only, invariant #3, mirrors mobile
  `OrdersDao.createOrder`):** Leg 1 = a `debit` of the order **net**
  (`order_payment`); Leg 2 = a `credit` of the cash paid (`topup_cash` /
  `topup_transfer`, skipped when no cash). The customer balance stays **derived** —
  new helper `_customer_wallet_balance()` = `SUM(signed_amount_kobo)` excluding
  the crate-deposit family (byte-identical to `CustomersDao.getBalanceKobo`).
- **Debt limit enforced server-side (defence in depth).** A sale that books NEW
  debt (cash_paid < net) is rejected (`debt_limit_exceeded`) when the projected
  balance would fall below `−customers.wallet_limit_kobo`; a fully-settled sale is
  never gated; `wallet_limit_kobo = 0` means no credit at all — the exact mobile
  `_overDebtLimit` rule. `credit`/`wallet` without a customer → `credit_requires_
  customer`; a customer with no wallet → `customer_wallet_missing`.
- **Golden-Scenario Suite extended.** The shared model (`golden_scenario.dart`)
  now carries an optional `customer` (opening balance + debt limit), expected
  `wallet_legs` (multiset) + `customer_balance_after_kobo`, and a nullable payment
  (a no-cash sale posts none). Four credit fixtures added to
  `cash_sale_scenarios.json` (Pay-with-Credit, credit-sale no-cash, credit-sale
  partial-cash, registered fully-paid). Both runners seed a customer + wallet +
  opening leg and collect the per-order legs + derived balance; the Dart DAO tier
  is **12/12 green** offline, the RPC tier verified end-to-end via an impersonated
  SQL smoke test (identical legs/balances). Guard tests
  (`checkout_order_test.dart`) add debt-limit rejection, no-limit rejection,
  Pay-with-Credit draw-down, partial-cash legs, and the `credit_requires_customer`
  guard. Also fixed a latent Slice 2 test bug: `selling_price_kobo` → the real
  `retailer_price_kobo` column (the Tier-2 seeds would have failed).
- **Web UI.** `CustomerPicker` (searchable, shows each customer's live derived
  balance) + a cart customer bar (attach / change / remove, balance chip) +
  `CheckoutDialog` gains **Pay with Credit** and **Register as Credit Sale** when a
  customer is attached, a live projected-balance readout, and a **debt-limit
  block** (submit disabled + a clear banner) mirroring the server rule. `Receipt`
  shows the customer, "on credit", and the new balance. `useCustomers` refreshes
  the list (with balances) after each sale. `loadCustomers` derives balances
  client-side (read-only, like the catalogue's on-hand sum). `npm run typecheck` +
  `npm run build` green.
- **Scope left for later slices:** crate ledger at checkout (#45, in progress),
  Realtime (#49), inventory add/receive (#48), reports (#51). The credit paths and
  wallet-leg contract are pinned by the golden harness Slice 4 reuses.

### SHIPPED: Web POS Slice 2 — cash-sale checkout keystone + Golden-Scenario Suite (2026-07-05, issue #43, ADRs 0008/0009)
- **`checkout_order` RPC (migration `0135_checkout_order.sql`).** The
  server-authoritative cash/transfer checkout — one `SECURITY DEFINER` atomic
  transaction (no customer credit / no crate; those are Slices 3 & 4): Order at
  `pending` + line items; FIFO `cost_batches` draw-down oldest-first **under a
  `FOR UPDATE` row lock**, reusing the pure `fifo_assign` (0133) so per-unit COGS
  rounding is byte-identical to the recost pass and the mobile draw-down;
  per-line `buying_price_kobo` snapshot; inventory decrement with the
  `quantity >= qty` guard that **rejects at commit on insufficient stock** (two
  tills can't oversell); scalar `buying_price_kobo` cache re-point; one
  `payment_transactions` row; **revenue at Checkout** (`status='pending'`,
  `completed_at` NULL). Idempotent on `p_order_id`.
- **Server order number.** `WEB-NNNNNN-XXXXXX` (running count + 6 hex of the order
  id). The `WEB-` prefix makes collision with the mobile `ORD-…` device-tag scheme
  impossible regardless of the tail.
- **Server-side enforcement (defence in depth).** New reusable helpers
  `caller_has_permission()` (role grants ± user overrides, CEO all-on) and
  `caller_max_discount_percent()` (role_settings, seed CEO 100 / Manager 10 / else
  0) enforce `sales.make` and clamp the discount server-side — mirroring the mobile
  Gate Registry's *decisions*, not its Dart (ADR 0009). The web ALSO hides.
- **Golden-Scenario Suite (ADR 0009).** Shared fixtures
  (`test/golden/fixtures/cash_sale_scenarios.json`, 8 scenarios) + one model
  (`test/golden/golden_scenario.dart`) run against **both** implementations: the
  Dart DAO path (`test/golden/dart_dao_golden_test.dart`, in-memory Drift, offline
  → runs every CI build; **8/8 green**) and the SQL RPC
  (`test/integration/rpcs/checkout_order_golden_test.dart`, Tier-2, env-gated).
  Field-for-field drift fails the build. The order-number *scheme* is deliberately
  divergent, so each runner asserts its own regex, never equality.
  `.github/workflows/golden-scenarios.yml` runs the Dart tier always, the RPC tier
  when the `TEST_SUPABASE_*` secrets exist. Guard tests
  (`test/integration/rpcs/checkout_order_test.dart`) cover oversell rejection, the
  concurrency guard, idempotent replay, `WEB-`/`ORD-` non-collision, discount cap.
- **Web UI.** `CartProvider` (session-persistent cart) + `Cart` (qty stepper,
  remove, role-capped discount, live line/order totals) + `CheckoutDialog`
  (cash/transfer, amount paid, change) + `Receipt` (print via print-only
  stylesheet, Share via Web Share + text-download fallback, "Done — back to POS"
  clears the cart). `PosScreen` = grid-beside-cart on tablet+, sticky bottom bar +
  bottom-sheet on phone (four responsive bands). `loadOperator` now resolves
  `maxDiscountPercent`. The sale reaches mobile via the existing Realtime pull — no
  new sync wiring. `npm run typecheck` + `npm run build` green.
- **Scope left for later slices:** customer-credit / wallet checkout (#44), crate
  ledger at checkout (#45), Realtime (#49), inventory add/receive (#48), reports
  (#51). Slices 3/4/6/7 reuse this golden harness.

### SHIPPED: Web POS Slice 1 — walking skeleton (2026-07-04, issue #47, ADRs 0007–0012)
- **First code of the Web POS.** A new top-level **`web-pos/`** Next.js (App
  Router) + React + TypeScript + `@supabase/supabase-js` app (ADR 0010/0012),
  thin but end-to-end through **auth → live RLS read → render**. Online-first
  (ADR 0007): a single browser Supabase client is the whole data layer — no
  Drift, no outbox. `next build` green; all 5 routes prerender; server smoke-test
  200 on `/` and `/auth/callback`.
- **Auth = Operator (ADR 0011).** Email+OTP (`signInWithOtp`/`verifyOtp`) and
  Google (`signInWithOAuth` → `/auth/callback`, PKCE, `detectSessionInUrl`). The
  session IS the Operator for the tab; `loadOperator()` resolves business scope
  from `profiles.business_id`, role from the active `user_businesses` membership,
  and perms — **no custom JWT claims**. `IdleLock` (15 min inactivity) signs out
  → tab re-locks to the sign-in screen. Every read is RLS-scoped, so the Operator
  only sees their own business.
- **Live catalogue.** `loadCatalogue()` reads `categories` + `products`
  (`retailer_price_kobo` / `wholesaler_price_kobo`) + `inventory` (on-hand summed
  across stores) over PostgREST; the responsive `PosScreen` renders the grid with
  per-tier prices, a live stock indicator (in/low/out), and category chips.
  Out-of-stock tiles render unavailable. Realtime auto-refresh is Slice 5 (#49);
  here a manual **Refresh** re-pulls. Tapping a tile is gated on `sales.make`
  (cart/checkout is Slice 2 / #43).
- **Theming parity.** All five palettes (blue/amber/purple/green/b&w, light+dark)
  ported verbatim from the mobile `colors.dart` into `src/lib/theme/palettes.ts`
  (keys = the `DesignSystem` enum names). `ThemeProvider` applies the active
  palette as CSS custom properties at the document root, read live from the synced
  `business_design_system` setting (mobile's source too) — a change re-paints with
  no redeploy; light/dark follows the browser preference.
- **Permission-read layer.** `resolveEffectivePermissions()` mirrors the mobile
  Gate Registry's *decisions* (ADR 0009 — not its Dart): role grants ± user
  overrides, **CEO all-on**. `Can` / `useCan` drive hide-don't-block (gated nav +
  the sell affordance). Currency via `formatKobo`/`useCurrency` from
  `default_currency` — never hard-coded ₦.
- **Config:** public Supabase URL + anon key baked into
  `src/lib/supabase/config.ts` (mirrors the mobile-intentional public/RLS-gated
  key), overridable via `NEXT_PUBLIC_*`; builds with zero env setup. Vercel root =
  `web-pos/` (ADR 0012); README documents the OAuth redirect-URL config step.
- **Scope left for later slices (per the epic order):** cart/checkout RPC (#43),
  Realtime (#49), inventory add/receive (#48), stock-adjust approval (#50),
  reports (#51), and store-scoped permission overrides (§10.2.1 middle layer).
  No golden-scenario suite yet (arrives with the first money-write RPC, #43).

### SHIPPED: Batch-creation-on-inflow — Add Product + Receive Stock push a Cost Batch (2026-07-04, issue #42, ADR 0005)
- **Epic 2, F6 (FIFO batch costing).** The **producer** for the queue: F1 (#37)
  only seeded opening batches via the migration and F2 (#38) only consumed it, so
  any product created or restocked after the migration (or out of stock at
  migration time) drew from no batch and sold at **0 COGS** until backfilled. Both
  inflow sites now write a `cost_batches` row in the **same transaction** as the
  inventory increment (queue total for a (product, store) can't drift from
  on-hand). Closes the coherence gap flagged in F2.
- **`CostBatchesDao.recordInflowBatch(...)`
  ([daos_costing.dart](lib/core/database/daos_costing.dart)):** inserts ONE fresh
  batch (distinct `UuidV7` id — each inflow is its own FIFO layer, never merged)
  at the entered cost (`0` → a valid **Uncosted** batch, resolved later by #41).
  All synced/defaulted columns set explicitly (no second id minted on push,
  `project_synced_write_explicit_id`), then `enqueueUpsert`. No new sync-registry
  work (reuses F1's entry). No-op on non-positive quantity.
- **Add Product opening stock
  ([daos_catalog.dart](lib/core/database/daos_catalog.dart)):**
  `insertProductWithInitialStock` creates the opening batch on **both** the v1 and
  v2 (`pos_create_product_v2`) paths; on v2 the batch enqueues **after** the create
  envelope so its FK-to-product push resolves once the server mints the product.
- **Receive Stock
  ([receive_stock_service.dart](lib/shared/services/receive_stock_service.dart)):**
  each cart line pushes a new batch at that receipt's buying price, stamped with
  the receipt date (its FIFO key). Existing batches untouched.
- **Tests:** `test/costing/inflow_batch_creation_test.dart` (7) — opening-batch
  shape + queue==on-hand; uncosted-0 resolved in place by #41 (no double-count);
  no-stock→no-batch; push carries local id + all defaulted columns; v2 orders the
  batch after the envelope; Receive adds a layer without mutating the opening one;
  and the **regression** — a post-migration new product AND a restock of a
  previously batchless product both draw NON-ZERO COGS at checkout. Two
  `create_product_dispatch_test` assertions updated for the extra
  `cost_batches:upsert` row. `flutter analyze` clean; costing/receiving/inventory/
  sync/orders/database suites green.

### SHIPPED: Provisional→authoritative COGS correction + rolled-up audit (2026-07-04, issue #40, ADR 0005)
- **Epic 2, F4 (FIFO batch costing).** The **client correction flow**: lands the
  server's authoritative COGS back on the device and audits it. Lives entirely in
  the sync engine — off the sale / app-open path.
- **`SupabaseSyncService`** — a push drain collects the (product, store) pairs
  whose sale lines it delivered to the cloud (v1 `order_items` upserts +
  v2 `pos_record_sale_v2` envelopes; quick-sale null-product lines excluded), then
  `reconcilePushedSaleCosts` calls the server's `pos_recost_pairs` (0133). The
  server-corrected `order_items.buying_price_kobo` flows back down as an **ordinary
  LWW row update** on the following pull — replacing the provisional snapshot with
  no merge conflict. Best-effort: an RPC failure is swallowed and self-heals on the
  next sync of the pair (incl. a peer's late earlier-timestamped sale replaying the
  ledger, F3).
- **One rolled-up Activity Log row per sync batch** — new
  `CostBatchesDao.logRecostReconciliation` (`cost.recosted_on_sync`, "N sales of X
  re-costed on sync — batch-boundary reconciliation"; multi-product batches → "N
  sales across M products"). Written ONLY when `recosted_count > 0` (a single-till
  provisional that already matched writes no row). No per-sale prompt.
- **`flushSale` deliberately not re-cost-triggered** — keeps recost off the
  foreground sale path; the online-flushed sale is already consistent and any drift
  is fixed by the reconnecting offline peer's re-cost.
- **Tests:** `test/costing/recost_correction_flow_test.dart` (8) — provisional
  present → corrected value + exactly one Activity Log row; LWW replaces the
  provisional; count-0 / empty-pairs / RPC-failure all write no row; multi-product
  roll-up; the two pure collectors incl. the quick-sale skip. `flutter analyze`
  clean; costing + sync suites green (210).

### SHIPPED: Pure FIFO draw-down + provisional COGS at checkout (2026-07-04, issue #38, ADR 0005)
- **Epic 2, F2 (FIFO batch costing).** The device-side draw-down: a pure,
  DB-free costing function and its wiring into the sale path. Single-till/online
  happy path; multi-till server reconciliation is #39/#40.
- **Pure function — [fifo_drawdown.dart](lib/core/costing/fifo_drawdown.dart):**
  `fifoDrawDown(List<FifoBatch> oldestFirst, List<int> lineQtys) →
  FifoDrawResult{lineCogsKobo, lineShortfall, batchConsumption}`. Weighted COGS
  across partial-batch splits spanning two+ batches; cost-0 (uncosted) batch →
  0 COGS but still drawn down; queue exhaustion reported as `lineShortfall`;
  consumes the queue sequentially across lines. Widget-free/DB-free. 12 unit
  tests ([fifo_drawdown_test.dart](test/costing/fifo_drawdown_test.dart)).
- **Checkout wiring — `CostBatchesDao.drawDownSale`
  ([daos_costing.dart](lib/core/database/daos_costing.dart)):** new
  `CostBatchesDao` (registered; build_runner regenerated). Inside
  `OrdersDao.createOrder`'s sale transaction (after the inventory guard, on BOTH
  v1/v2 sync paths) it reads each (product, store) queue oldest-first, snapshots
  the **provisional per-unit COGS** onto `OrderItems.buyingPriceKobo`, decrements
  the consumed `cost_batches` + enqueues their upserts. **Per-unit rounding is
  `round(line_total/qty)` (Dart `double.round()` == the server's round-half-away-
  from-zero, migration 0133)** so a provisional line and its authoritative
  correction agree. Selling price (`unitPriceKobo`) is untouched.
- **COGS is exactly the local batch-queue view — no scalar fallback.** Units the
  queue can't cover (a product with no batch, or a partial line) are **uncosted
  (0)**, matching the server's `fifo_assign` (a scalar the server would later
  rewrite to 0 is the "vanishing trust" failure ADR 0005 avoids).
- **Derived scalar cache:** after the draw-down, `Products.buyingPriceKobo` is
  re-pointed at the oldest remaining **costed** batch (across stores), only when
  the value changes. An uncosted (cost-0) oldest batch is **skipped** — the
  scalar is never clobbered to 0 (the 0→real backfill is #41). Existing read
  sites (recon / profit report multiply per-unit × qty) unaffected.
- **⚠️ Coherence gap (flagged, out of #38 scope): batch-creation-on-inflow is
  NOT wired.** Neither Add Product's opening stock nor Receive Stock creates a
  `cost_batches` row yet — the queue only grows via the #37 migration seed. So
  post-migration new / out-of-stock-at-migration / restocked products have **no
  batch → sales are uncosted (0 COGS)** until a batch exists. This is the
  deliberate Epic 2 semantic (uncosted until cost is recorded; #41 backfills),
  but Epic 2 is not usefully costing new stock until inflow→batch is wired.
  Recommend a follow-up issue before Epic 2 is considered done.
- **Tests:** 16 (12 pure + 4 integration:
  [checkout_cogs_drawdown_test.dart](test/costing/checkout_cogs_drawdown_test.dart)
  — boundary-span weighted snapshot + FIFO decrement + scalar recompute + selling
  price untouched + cost_batches push; partial-coverage shortfall; no-batch
  uncosted; uncosted-batch 0-COGS + no-clobber). `flutter analyze` clean project-
  wide; full suite **729 pass / 69 skip / 1 pre-existing unrelated fail**
  (`who_is_working_screen_test`, confirmed failing on stashed HEAD).

### SHIPPED: Server-authoritative batch consumption + replay (2026-07-04, issue #39, ADR 0005)
- **Epic 2, F3 (FIFO batch costing).** The server owns the per-(product, store)
  cost queue and assigns "which batch paid for each sale," ordered by the sale's
  **own recorded timestamp** (`orders.created_at`), re-deriving the authoritative
  per-line COGS. Built as a **separate derivation pass** over the already-
  quantified movement ledger — `pos_record_sale_v2` / `pos_inventory_delta_v2`
  are untouched, so stock-quantity conflict resolution is never reopened.
- **`0133_fifo_batch_consumption.sql`** — three layers: `fifo_assign(batches,
  sales)` (pure IMMUTABLE FIFO draw-down: partial-batch splits, cost-0 uncosted
  units, queue exhaustion; per-unit `round(total/qty)`); `pos_recost_product_
  store(business, product, store)` (loads queue + recognized-sale ledger, replays,
  writes `order_items.buying_price_kobo` + `cost_batches.qty_remaining`; full
  replay ⇒ idempotent, late earlier sale ⇒ re-assigns already-corrected lines);
  `pos_recost_pairs(business, pairs)` (rolls up a sync's touched pairs → one count
  for #40's Activity Log row).
- **Tests:** Tier-2 `pos_recost_batches_test.dart` (RPCs called directly, no
  client). Verified against dev Supabase read-only: `fifo_assign` battery 8/8,
  load queries + jsonb writeback correct.
- **NOT yet on remote via db push** — needs `supabase db push` to record 0133
  (0132 already deployed). Inert until #40 calls it.

### SHIPPED: Cost Batch schema + migration + sync membership (2026-07-04, issue #37, ADR 0005)
- **Epic 2, F1 (FIFO batch costing).** The **Cost Batch** foundation landed
  ahead of any consuming logic (land-the-migration-first). No draw-down /
  server-authoritative consumption yet — that is a later Epic 2 issue.
- **Drift `cost_batches`** (schema **v57 → v58**): per-(product, store) FIFO cost
  queue `{qtyRemaining, qtyOriginal, costKobo, receivedAt, …}`; `costKobo == 0`
  = uncosted. Mutable synced tenant table (drawn down in place — not a ledger,
  not hard-deleted). v58 migration seeds **one opening batch per (product, store)**
  from current stock at the product's scalar `buyingPriceKobo` (zero-cost →
  uncosted; empty stock → no batch), with a **deterministic opening-batch id**
  (`UuidV7.deterministic`, new UUIDv5 helper) so devices converge instead of
  duplicating on sync. One `SyncedTable` registry entry (`Restore.plain`
  resilient); golden pull-order/tenant-set updated.
- **Cloud `0132_cost_batches.sql` (DEPLOYED + verified):** `cost_kobo` **bigint**,
  `current_user_business_ids()` RLS, realtime + `pos_pull_snapshot` membership.
  Safe for live v57 devices (pull iterates the app's own registry → ignores the
  new snapshot key).
- **Incidental fix:** the `@DriftAccessor` on `BusinessesDao` (daos_org.dart) was
  misplaced above a `const _absent` sentinel, so a clean `build_runner` dropped
  `_$BusinessesDaoMixin` and broke compilation (committed generated code was
  stale-but-correct, masking it). Moved the annotation onto the class.
- Migration test drives the real onUpgrade(57→58) + asserts the seed. `flutter
  analyze` clean; full suite 713 pass / 58 skipped / 1 pre-existing unrelated
  failure (`who_is_working_screen_test`, confirmed failing on HEAD).

### SHIPPED: Land on POS after onboarding — auto-push deleted (2026-07-04, issue #35, ADR 0006)
- **Epic 1.** Onboarding now lands the device on **POS** — where the
  persona-aware "Add your first product" CTA (#34) greets the user — instead of
  force-pushing the Add Product form on `MainLayout`'s first frame. The one-shot
  auto-push mechanism is removed entirely, no dead code left:
  - `navigation_service.dart`: deleted `_autoShowAddProductPending` +
    `requestAutoShowAddProductSheet()` / `consumeAutoShowAddProductSheet()`.
  - `main_layout.dart`: removed the first-frame consumer that pushed
    `AddProductScreen`, and its now-unused import.
  - Both former call sites: `success_dashboard_entry_screen.dart` (now a plain
    `StatefulWidget` — reads no provider; Riverpod imports dropped) and
    `ceo_sign_up_screen.dart` (orphaned `nav` local dropped) no longer request
    the auto-push.
- The onboarding → `MainLayout` handoff is otherwise unchanged (1.5 s forward
  from the success screen; 3 s "your business is ready" beat on the CEO path).
  `flutter analyze` clean project-wide. This closes the Seam-2 auto-push item.

### SHIPPED: Persona-aware first-run empty states (Seam 2) on POS + Inventory (2026-07-04, issue #34, ADR 0006)
- **Epic 1.** The POS grid and Inventory Products tab empty states are now
  persona-aware. A fresh CEO on a genuinely empty catalogue gets a primary
  **"Add your first product"** CTA (opens the Fast-Add form, #30); a user
  without `products.add` gets a neutral no-button *"No products yet — a manager
  can add them"* message; and neither ever flashes while the catalogue is still
  streaming in (invariant #11).
- **Seam 2 — `lib/core/providers/first_run_surface_state.dart`:** the pure,
  widget-free `computeFirstRunSurfaceState({hasProducts, firstLoadInProgress,
  canAddProduct}) → {skeleton, addProductCta, neutralEmpty, hasContent}`.
  Precedence: products present → `hasContent`; else still streaming →
  `skeleton`; else settled + zero splits on the gate. Live wiring
  (`firstRunSurfaceStateProvider`) composes `hasLocalProductsProvider`, the
  shared `firstLoadSkeletonActiveProvider`, and `Gates.addProduct` via
  `gateContextProvider` — all overridable, so the derivation is unit-tested in a
  ProviderContainer with no widgets.
- **Shared surface — `lib/shared/widgets/first_run_empty_state.dart`:** one
  `FirstRunEmptyState` consumed by **both** screens (they can't drift). Each
  screen only routes to it when its visible list is empty AND the catalogue is
  genuinely zero (surface `!= hasContent`); a filter/search miss over a
  populated catalogue keeps its own "No products found" copy.
- **Tests:** `test/providers/first_run_surface_state_test.dart` — the pure
  function exhaustive over inputs + precedence; the provider driven through all
  four states via input overrides. `flutter analyze` clean; inventory/receiving/
  pos suites green. On-device CTA/neutral/skeleton walkthrough pending.

### SHIPPED: Speed-dial FAB splits Add Product from Receive Stock (2026-07-04, issue #33, ADR 0006)
- **Epic 1.** The Inventory Products tab's single Receive Stock FAB is replaced
  by a **permission-aware speed dial**: one "+" expands to two labelled options —
  **Add Product** ("Create a product and set what's on your shelf" → Fast-Add
  direct mode, #30) and **Receive Stock** ("Log a delivery from a supplier" →
  the existing flow, untouched). Each option's one-line description doubles as a
  teaching surface (ADR 0006).
- **Seam 2 — `lib/core/widgets/app_speed_dial_fab.dart`:** a reusable,
  permission-agnostic `AppSpeedDialFab` + `AppSpeedDialAction`. Callers gate-
  filter the actions (citing the named registry — ADR 0002 — never a role); the
  widget owns only the **collapse rendering**: zero actions → no FAB, exactly
  one → a direct `AppFAB` (never a menu of one), two+ → the expandable dial
  (Overlay-hosted pills + full-screen scrim, `+`→`×` toggle). Closes itself if
  live revocation drops it below two actions mid-open.
- **`inventory_screen.dart`:** the Products-tab FAB now builds the action list
  from `Gates.addProduct.allows(ref)` / `Gates.receiveStock.allows(ref)`. A
  stock keeper with only `stock.add` still gets a single direct Receive Stock
  FAB; a CEO gets both; nobody with neither gate sees a FAB. `AppFAB` import
  dropped (now reached transitively through the speed dial).
- **Tests:** `test/inventory/speed_dial_fab_test.dart` — 4 widget tests over the
  collapse contract (0/1/2 actions, expand→choose, scrim-dismiss). `flutter
  analyze` clean. On-device dial walkthrough pending.

### SHIPPED: POS "tap a product to add it to the cart" coach tip (2026-07-04, issue #32, ADR 0006)
- **Epic 1.** A joining staff member landing on an **already-stocked** store now
  sees a one-time inline coach tip on POS: **"Tap a product to add it to the
  cart."** No new hint infrastructure — reuses `UiHintService` with a new key.
- **New key `UiHintService.hintPosTapAdd` (`'hint_pos_tap_add'`):** same
  view-count rule (shows < 2 times, dismissible), independent from the existing
  long-press-to-edit key.
- **`pos_home_screen.dart`:** the old `_buildPosHint()` is now the parameterized
  `_buildInlineHint({message, onDismiss})`, shared by both POS banners. The
  tap-to-add banner is gated on `_showPosTapHint && filteredProducts.isNotEmpty`
  (only when the grid actually has products) and renders **above** the
  long-press tip; both can co-exist and are dismissed/counted independently.
- **Tests:** `ui_hint_service_test.dart` gains an independence test (dismissing
  tap-add doesn't consume the long-press count). `flutter analyze` clean.

### SHIPPED: Get-started checklist — derived state (Seam 3) + Home-tab card (2026-07-04, issue #31, ADR 0006)
- **Epic 1.** A first-time CEO's Home tab shows a short **Get started** card
  tracking three milestones (Add a product, Make a sale, Invite your team —
  optional). Steps tick automatically and the card self-hides once done.
- **Completion is derived from data, never stored as flags** → cross-device
  correct for free (a reinstall reflects real progress). Only the manual
  dismissal is persisted, device-local.
- **Seam 3 — `lib/features/dashboard/get_started_checklist.dart`:**
  `computeGetStartedChecklist({isCeo, hasProducts, hasOrders, hasTeam,
  dismissed}) → {visible, steps[]}` (pure, widget-free). `visible = isCeo &&
  !allDone && !dismissed`. Thresholds: products > 0, orders > 0, staff > 1
  (active staff includes the CEO). `getStartedChecklistProvider` wires it to
  `currentUserRoleProvider`, `hasLocalProductsProvider`, the new
  `hasAnyOrderProvider` (`OrdersDao.watchAnyOrderExists()` — distinct COUNT(*)
  bool via `businessScopedStream`), `activeStaffProvider(businessId)`, and the
  device-local `getStartedChecklistDismissedProvider` (SharedPreferences latch,
  mirrors `UiHintService`). Every input overridable → unit-testable.
- **Card — `lib/features/dashboard/widgets/get_started_card.dart`:** Home tab
  ONLY (never POS). Self-hides to zero height; deep-links each unticked step
  (Add product → `AddProductScreen` direct mode; Make a sale → POS tab; Invite
  team → `InviteStaffScreen`); ✕ dismisses. Mounted at the top of the Home list.
- **Tests:** `test/dashboard/get_started_checklist_test.dart` — 14 tests (pure
  role/threshold/dismissal + provider input-override wiring + dismissal
  persisting across a simulated restart). `flutter analyze lib` clean; raw-
  `StreamProvider` ban test still passes. On-device card walkthrough pending.
- **Still out (Seam 2 / separate #29 issues):** post-onboarding auto-push
  removal, speed-dial FAB, first-run empty-state CTAs, coach tip.

### SHIPPED: Fast-Add Product form — pure model (Seam 1) + adaptive screen (2026-07-04, issue #30, ADR 0006)
- **Epic 1, first issue.** The Add Product screen's **direct mode** is now a
  short, adaptive **Fast-Add** form, with the save-time logic extracted into a
  pure, widget-free **Fast-Add form model** (Seam 1).
- **Seam 1 — `lib/features/inventory/models/fast_add_product_model.dart`:**
  `resolveFastAdd(FastAddInput, FastAddContext) → FastAddResult` (sealed
  `FastAddInvalid{field,message}` / `FastAddIntent`). Owns required-field
  validation (Name / Selling Price / Quantity), the business-type-aware unit
  default (`fastAddDefaultUnit(tracksCrates) → Bottle|Pack`), the wholesaler
  mirror-on-save (blank ⇒ selling price, stored not read-time),
  manufacturer-required-for-crate, target-store resolution (single-store silent
  / multi-store required), the Uncosted rule (blank/unauthorized buying ⇒ 0),
  and shaping the write intent (prices→kobo, effective trackEmpties, crate value
  only on bottle, low-stock default 5). Pure — no widgets/DB/`BuildContext`.
  Every `FastAddInvalid.field` names a **visible** field.
- **Screen — `add_product_screen.dart`:** direct-mode new-product `_save`
  delegates to `_saveFastAddNewProduct` → model → `_persistNewProduct` (existing
  `insertProductWithInitialStock` + get-or-create FKs; unchanged write for a
  fully-filled form; duplicate-name guard kept). New adaptive layout: fast
  section (Name+size hint, Selling Price, skippable Buying Price+nudge, optional
  Category+examples, crate-only required Manufacturer, Quantity) + collapsible
  **More details** (Description, Wholesaler, Unit, track-empties+crate value,
  fractional sales, Low Stock, Supplier, Expiry, Store). Store hidden for
  single-store; a Store error auto-expands More details first.
- **Untouched (per ADR 0006):** Receive Stock's mini-form (`receiveMode: true`)
  and the add-stock-to-existing path keep the classic full layout + save path.
- **Out of #30 (separate Epic 1 issues):** delete the post-onboarding auto-push,
  speed-dial FAB, first-run empty-state CTAs (Seam 2), Get-started checklist
  (Seam 3), coach tip.
- **Tests:** `test/inventory/fast_add_product_model_test.dart` — 27 pure unit
  tests per the #29 Testing Decisions. `flutter analyze` clean (whole project).
  On-device Fast-Add walkthrough (layout, collapse, single-store hide) pending.

### Design locked (no code yet): first-run onboarding redesign + FIFO batch costing (2026-07-04, ADRs 0005 + 0006)
- **Grilled end-to-end** (grilling skill, all decisions user-confirmed). Two epics:
- **Epic 1 — first-run onboarding redesign (ADR 0006, ships first, current scalar
  cost model):** Add Product vs Receive Stock split into two named acts (glossary
  in `CONTEXT.md` §Inventory & Costing; labels locked, no rename); speed-dial FAB
  with permission-aware collapse on the Inventory Products tab; adaptive fast-add
  form (required: Name/Selling Price/Qty; Buying Price visible-but-skippable;
  Manufacturer surfaced+required only for crate businesses; Wholesaler mirrors
  selling price on save when blank; Store hidden for single-store); unit default
  business-type-aware (`businessTracksCrates ? Bottle : Pack`); persona-aware
  empty-state CTAs (post-first-pull + `Gates.addProduct` gated); CEO-only Home-only
  derived-state Get-started checklist; post-onboarding auto-push of the full form
  DELETED (land on POS + CTA instead). Receive Stock flow itself untouched.
- **Epic 2 — FIFO batch costing (ADR 0005, after Epic 1):** per-(product,store)
  cost-batch queue drawn down FIFO by **sale timestamp** (not server arrival);
  server-authoritative consumption extending the `pos_inventory_delta_v2` seam
  (provisional local COGS corrected on sync, late-arrival cascade re-assignment,
  rolled-up Activity Log audit rows); scalar `buyingPriceKobo` kept as derived
  cache; migration seeds one opening batch per (product,store); prompted explicit
  cost backfill (0→first-cost, fills gaps only, per-line date preserved). WAC and
  FIFO-with-arrival-order explicitly rejected; selling price stays scalar.
- **NEXT:** /to-prd → /to-issues for Epic 1 (same context window), then fresh
  session per issue with /implement.

### SHIPPED: `daos.dart` split into 11 domain `part` files (2026-07-04, locality refactor)
- **Pure refactor — no behaviour change, seams not moved.** The 9,820-line
  `lib/core/database/daos.dart` (47 DAOs) is now 11 domain-grouped
  `part of 'daos.dart'` files (`daos_catalog.dart` … `daos_org.dart`), matching the
  existing `sync_registry.dart` → `app_database.dart` house pattern. Still **one
  library**: private `_unset`/`_absent` stay visible, the generated `daos.g.dart` is
  unchanged (no `build_runner` rerun), and the 5 importers are untouched. Each DAO's
  interface over its table set is unchanged; only source locality improved. Verified:
  every code line preserved exactly once + `flutter analyze` clean (full project).

### SHIPPED: Order module extraction — facade over command/query surfaces (2026-07-04, ADR 0004)
- **Pure refactor, no behaviour change.** Consolidated everything *order-shaped*
  behind one deep module in `lib/shared/services/orders/`: the `OrderService`
  **facade** (unchanged public API — `orderServiceProvider` and all call sites
  untouched) delegating to two internal surfaces — **`OrderCommands`** (the
  lifecycle writes **Checkout** / **Confirm** / **Cancel** + reject-compensation,
  post-checkout side-effects isolated) and **`OrderQueries`** (read projections).
- **`SaleFlusher` seam** (`sale_flusher.dart`) decouples the checkout
  flush→reject→compensate path from the concrete Sync Engine (`SyncSaleFlusher`
  real / `NoopSaleFlusher` no-sync); `SaleSyncException` stays in core (layering).
- **Sits on top of `OrdersDao`** (unchanged persistence seam), did NOT absorb it.
  Two stray screen reads (`watchOrdersByCustomer`, `getSalesSummaryForProduct`)
  migrated onto the query surface. **Carts** + **delivery receipts** left OUT.
- **Confirm consolidation** — crate-return settlement moved off the UI:
  `CrateReturnModal` now only collects counts (`CrateReturnResult`);
  `OrderCommands.confirm` settles empties **then** flips `pending`→`completed`,
  preserving the old order + transaction shape. `markAsCompleted` gained optional
  `customerId/storeId/crateReturns/refundAsCash` (only caller is the crate path).
- **Verification:** design grilled via `/grill-with-docs` → `CONTEXT.md` glossary
  (Order, Sale, Checkout, Confirm, Cancel, Cart) + ADR 0004. New
  `test/orders/order_module_test.dart` pins payment-type/wallet-debit resolution
  and Confirm settle-then-complete. `flutter analyze` clean; ~657-test suite green
  (sole failure = pre-existing network flake in `who_is_working_screen_test`,
  unrelated).

### SHIPPED: Business-Scoped Stream primitive — factory + full migration (2026-07-03, PRD #23 = issues #24 + #25)
- **Built both slices in one pass.** New `lib/core/providers/business_scoped_stream.dart`:
  the `currentBusinessIdProvider` seam (`authProvider.select(currentUser?.businessId)`)
  plus four guarded factories — `businessScopedStream` /
  `businessScopedStreamFamily` and their `…AutoDispose` twins (Riverpod types
  keep-alive and autoDispose streams distinctly, so preserving each provider's
  lifecycle needs the twin). Each watches the seam, emits a required `whenAbsent`
  while unbound, and hands the closure **`(ref, db, businessId)`** with a
  guaranteed non-null id. `ref` is passed (a small, documented deviation from the
  ADR's `(db, businessId)`) because several tenant feeds must compose
  `lockedStoreProvider` to derive store scope; the guarantee is unchanged.
- **Migration surface was bigger than the "~41" estimate: 62 session-scoped
  declarations** migrated across `stream_providers.dart` (all order/expense/
  transfer/product/category/manufacturer/supplier/role/permission/crate/stock
  feeds, incl. the `allStoresProvider` throw-poison tracer + the
  `storeInventoryCountsProvider` silent-empty custom-SQL tracer) and
  `app_providers.dart` (supplier ledger/crate feeds, customer credit, the
  business-scoped `sync_queue` feeds, `hasLocalProductsProvider`). Each is a
  behaviour-preserving lift — `whenAbsent` equals what it emitted before
  (`[]` / `{}` / `0` / `null` / `kDefaultCurrency` / a `.empty()` stats zero).
  **Consumers untouched.** Prefactor also repointed the FutureProvider
  `firstPullCompletedProvider` onto the seam (no inline `.select` left).
- **Final allowlist = 11 genuinely non-session-scoped streams** (not just the 2
  globals): the permissions catalogue + unscoped roles; 4 explicit-id feeds
  resolved *before* bind (`_userMemberships`, `myUserStores`, `activeStaff`,
  `deviceStaff` — the shared-PIN / Who's-Working pickers); 2 device-local engine
  feeds (`orphanQueueItems`, `orphanQueueCount` — `sync_queue_orphans` has no
  `business_id`); 3 intentionally-unscoped selects (`localBusinesses`,
  `pendingCrateReturns`, `pendingReturnsWithDetails`). Forcing any through the
  factory would break pre-bind resolution or change device-local semantics.
- **Enforcement:** `test/providers/business_scoped_stream_ban_test.dart` bans a
  raw `StreamProvider` declaration anywhere in `lib/` (allowlist = the 11 above,
  shrink-only ratchet) + a companion strictness test (planted raw caught,
  multi-line caught, all four factory forms not flagged). Unit test
  `test/providers/business_scoped_stream_test.dart` drives the factory
  `null → bound → switched → unbound` via the seam override and proves it never
  runs the closure in the null window — no database needed.
- **Verified:** `flutter analyze` clean; full suite 652 passed / 58 skipped /
  1 pre-existing failure (`who_is_working_screen_test.dart` "Carol" — confirmed
  failing identically with these changes stashed, unrelated).

### Design landed (superseded by the SHIPPED entry above): Business-Scoped Stream primitive (2026-07-03, PRD #23 → issues #24, #25)
- **Planning only — no app code shipped this session.** Grilled the design
  (`/grill-with-docs`), wrote the paper trail, and filed the work.
- **Problem:** business-scoped `StreamProvider`s bake the current businessId at
  first build via `requireBusinessId()`; a first subscribe in the create-business
  null window either **throws + sticks errored** (e.g. `allStoresProvider`) or
  **silent-empty-sticks** (custom-SQL providers reading `db.currentBusinessId`)
  for the whole session → empty store pickers until restart. Hand-patched once
  per provider (S153). See `project_business_scoped_provider_build_time_poison`.
- **Decision (ADR 0003, `docs/adr/0003-business-scoped-stream.md`):** a guarded
  factory `businessScopedStream<T>` (+ `businessScopedStreamFamily<T, Arg>`) that
  **owns the declaration** — watches a new `currentBusinessIdProvider` seam,
  emits a required `whenAbsent` value while unbound, hands the closure a non-null
  businessId, rebuilds on bind/switch. Makes the bug unrepresentable by
  construction; a source-scan ban test (modeled on `gate_static_ban_test.dart`)
  keeps new providers on it, with a small non-empty allowlist for genuine globals
  (permissions catalogue, unscoped roles). Glossary terms added to `CONTEXT.md`.
- **Size correction:** the originating "257 providers" was a consumer count; the
  real surface is **~41 declarations in 2 files** (`stream_providers.dart`,
  `app_providers.dart`); consumers untouched.
- **NEXT:** implement in a fresh session per issue — **#24** (factory + seam +
  tracer trio + ban test, CI green) then **#25** (migrate remaining ~38 + shrink
  allowlist to globals). #25 blocked by #24.

### Flip: gate enforcement made permanent — allowlist emptied, bare helpers removed (2026-07-03, issue #22)
- **Goal (epic #16 finish line):** flip the named-gate enforcement from a
  shrinking ratchet to a permanent ban, retire the last cross-cutting permission
  helpers, and close the leak class the way the `SyncedTable` registry (#15)
  retired the sync smear.
- **Last bare `hasPermission(ref, …)` sites migrated (10, verbatim):**
  staff_detail (assign-stores / change-role / suspend / permission-editor),
  staff_permissions (settings.manage), orders (two Pending-tab Refund checks),
  activity_log (screen body-guard). New gates `assignStaffStores`,
  `changeStaffRole`, `suspendStaff`, `refundOrder`; reused `manageSettings` +
  `viewActivityLogs`.
- **Bare helper removed:** `hasPermission(WidgetRef, String)` is **deleted** from
  `stream_providers.dart` — feature code cites `Gates.x.allows(ref)` and the
  single-key primitive (`Gate.key`) now lives only inside the permissions module.
- **Direct feature-level tier checks removed (user-approved scope):** the
  `isManagerOrAbove(ref)` cross-cutting helper is **deleted**; its ~12 sites now
  cite named tier atoms — `seeOrderMoney` (§19.3 order money, orders ×4),
  `seeExtendedDateRanges` (§19.2 date-range breadth: orders + customer_detail,
  supplier_transactions, expenses, home, supplier_detail), and the reports-hub
  manager-up cards `viewApprovals` / `dailyReconciliation` / `crateDepositsReport`.
  Tier now lives **only** in registry atoms. Left as-is (out of the approved
  scope): per-screen `slug=='ceo'` CEO cost-wall money-visibility checks
  (deliberately tier-based per ADR 0002, never in any batch) and the drawer's
  `isBelowCeo` UI-placement split (picks self-service vs CEO settings — not a
  permission gate; no negation atom by design).
- **Static ban flipped strict:** `_allowlist` is now **empty**; any bare
  `hasPermission(ref, …)` anywhere in `lib/` outside `lib/core/permissions/`
  fails the suite. Added a durable scanner self-test; the plant-and-verify
  (temp bare check → suite fails → removed) was run and confirmed. Registry
  membership test stays strict (every one of the 48 gates cited; the 9 new
  gates all cited in production code).
- **Tests updated:** the two settings harnesses (`settings_menu_gating`,
  `sidebar_role_visibility`) drop the deleted helper for a direct
  `currentUserPermissionsProvider.contains(key)` (identical semantics).
- **Verification:** whole-project `flutter analyze` clean; `test/permissions` +
  `test/settings` 80/80; full suite green except the documented pre-existing
  `who_is_working_screen_test` flake (widget-timing + a live Supabase call;
  untouched by this work, uses neither removed helper).

### Batch: Operations named-gate migration — Inventory, Stores, Customers, Expenses (2026-07-03, issue #20)
- **Goal (epic #16):** migrate the operations screens' gates verbatim into named
  registry gates — the mechanical batch (mostly single-key lifts), 26 bare sites
  across 9 files.
- **New algebra atom:** `Gate.tierIn(ranks)` (set membership, fails closed on
  null rank) — needed because Daily Stock Count's legacy role set
  {CEO, Manager, Stock keeper} *skips* Cashier, which no `tierAtLeast` cutoff can
  express. Convention-bound exactly like `tierAtLeast` (ADR 0002).
- **New gates (`gate_registry.dart`, Operations cluster):** `viewInventory`
  (`stock.view`), `dailyStockCount` (tierIn{ceo,mgr,sk} AND `stock.adjust` —
  tier-based legacy, review flag), `manageStores`, `requestStoreTransfer`,
  `dispatchStoreTransfer`, `receiveStoreTransfer`, `editCustomer`,
  `deleteCustomer`, `addCustomerCredit` (`customers.wallet.update`),
  `setDebtLimit`, `refundCustomerWallet` (`customers.wallet.withdraw`),
  `seeWalletTotals` (`customers.wallet.totals.view`, §18.4), `recordCrateReturn`
  (`sales.make` — same key as `makeSale`, distinct action), `viewExpenses`
  (`reports.see_expenses`), `addExpense`, `approveExpenses`. Reused: `addCustomer`
  (Customers FAB), `editProductPrice` (Inventory long-press editor),
  `editBuyingPrice` + `manageSuppliers` (Add Product screen).
- **Screen guards:** Inventory and Expenses hand-rolled denial scaffolds →
  `Guarded.screen` (wait-for-ready, no denial flash). Both are MainLayout tabs,
  so the loading/denied surfaces keep their chrome (SharedScaffold / drawer +
  app-bar) via the `loading`/`denied` params — the POS precedent. Stores' browse
  composite stays inline (its all-stores-viewer leg is a provider, not a key)
  but cites the named gates for each key leg. Write boundaries (`_openEditSheet`,
  EditCustomerSheet save) → `.allowsNow(ref)`, behaviour preserved.
- **Static-ban allowlist** shrunk by exactly the 9 files (customer_detail 8,
  customers 1, edit_customer_sheet 1, expenses 3, add_product 2, inventory 3,
  store_details 1, stores 5, store_transfer_hub 2). `dart analyze` clean;
  permissions suites green for this batch's files (two in-flight failures belong
  to the parallel #21 settings batch: its six gates declared-not-yet-cited + its
  six settings allowlist rows), no behavioural test edits.

### Batch: POS & Checkout named-gate migration (2026-07-03, issue #19)
- **Goal (epic #16):** migrate the POS + Checkout gates verbatim into named
  registry gates, and land the flagship use of the imperative `require` form.
- **New gates (`gate_registry.dart`, POS & Checkout cluster):** `Gates.makeSale`
  (`sales.make`), `Gates.addCustomer` (`customers.add`), `Gates.setCustomPrice`
  (`sales.set_custom_price`) — plain key lifts.
- **Sites migrated (verbatim, behaviour-neutral):** POS home screen's hand-rolled
  perms-ready + `sales.make` denial → the standard `Guarded.screen(gate: makeSale)`
  (waits for readiness = no CEO-lands-on-POS denial flash; keeps the SharedScaffold
  nav chrome via the `loading`/`denied` params since POS is a bottom-nav tab). Cart
  "New customer" → `Gates.addCustomer.allows(ref)`; edit-item Custom Price →
  `Gates.setCustomPrice.allows(ref)`. **Checkout confirm path** now guards its
  write boundary with `Gates.makeSale.require(ref)` at the top of `_confirmPayment`,
  catching `GateDeniedError` into the standard `showGateDenied` feedback and
  returning before any write (the imperative-form flagship). Sale semantics
  untouched — revenue-at-checkout, the discount *cap*, and the unenforced
  discount-give permission all unchanged.
- **Static-ban allowlist** shrunk by exactly the 3 POS sites (pos_home_screen,
  cart_screen, edit_item_modal → removed). `flutter analyze` clean; permissions +
  pos + checkout + settings-gating suites green, no behavioural test edits.

### Batch: Dashboard & Reports named-gate migration (2026-07-03, issue #18)
- **Goal (epic #16):** lift the app's messiest composite gates — the home-screen
  §11.4 money/report tiles (CEO-or-Manager-with-key) and the Reports hub / Profit
  report entries — verbatim into named registry gates, so every tier dependence
  is visible in one file. No key-ification, no cleanup (ADR 0002).
- **New gates (`gate_registry.dart`, Dashboard & Reports cluster — tier-based /
  §19.3-class, render-only via `.allows(ref)`):** `seeSalesMetric`,
  `seeProfitMetric`, `seeExpensesMetric`, `seeStockValueMetric`,
  `seeCreditBalanceMetric`, `seeStaffSales`, `supplierAccountsReport`,
  `profitReportEntry`, `seeReportCostPrices`. `(isManager||isCashier)` →
  `tierAtLeast(cashier)` and `isMgrUp`/`isManagerOrAbove` → `tierAtLeast(manager)`,
  both identical under the CEO disjunct across all ranks + fail-closed null rank.
- **Sites migrated (verbatim, behaviour-neutral):** `home_screen` 5 tile flags +
  Staff Sales → `Gates.*.allows(ref)`; `reports_hub` Supplier Accounts + Profit
  Report entries → the two hub gates; `profit_report` on-screen headline
  (`.allows`) + CSV export (`.allowsNow`, was a raw provider `.contains`) now cite
  the SAME `seeReportCostPrices` gate. Pure-tier `showPending`/`showTotalSkus` and
  the `if (isMgrUp)` cards stay inline (not permission checks / cross-cutting
  helper / `isCashier||isStockKeeper` needs no `tierAtMost` atom).
- **Static-ban allowlist** shrunk by exactly the 3 files (home_screen 5,
  reports_hub 2, profit_report 1 → removed). `flutter analyze` clean;
  `test/permissions/` green (static-ban ratchet + membership + seams), no
  behavioural test edits. This batch removes 8 `hasPermission(ref)` sites.

### Tracer: named-gate registry + `Guarded` (2026-07-02, issue #17)
- **Goal (epic #16):** retire the recurring permission-leak class — enforcement
  hand-typed at ~89 `hasPermission(ref, key)` sites in three comment-equated
  layers — the way the `SyncedTable` registry (#15) retired the sync smear. This
  issue is the **tracer**: the whole module + one gate migrated end-to-end.
- **Module (`lib/core/permissions/`, ADR 0002):** `gate.dart` (pure `Gate`
  algebra over a `GateContext` — atoms `key`/`anyKey`/`allKeys`/`tierAtLeast`/`ceo`
  + `.and`/`.or`, fails closed unresolved, CEO all-on, + `GateDeniedError`);
  `gate_registry.dart` (`NamedGate` + `Gates` single declaration site);
  `guarded.dart` (`gateContextProvider` seam, the `allows`/`allowsNow`/`require`
  extension, the `Guarded` render+`allow`-fire-time widget, and `Guarded.screen`
  body-guard with the no-flash policy + standard no-access scaffold);
  `permissions.dart` barrel.
- **Receive Stock migrated verbatim (12 sites, 5 files):** Inventory FAB + the
  screen guard (`Guarded.screen`) now cite the same `Gates.receiveStock`;
  New Product → `Gates.addProduct`, price edits → `Gates.editProductPrice` (incl.
  the long-press fire-time re-check), buying-price → `Gates.editBuyingPrice`,
  supplier payments → `Gates.manageSuppliers`. Behaviour-neutral. `hasPermission`
  86 → 74; `lib/features/receiving/` bare-check-free.
- **Tests (`test/permissions/`, 26 new):** pure algebra (14), `Guarded`/`.screen`/
  `require` widget seam (10), static-ban scan with a **full 74-site allowlist
  ratchet** (planted-check-fails verified), registry membership. `flutter analyze
  lib` clean; permissions + receiving + inventory + settings suites green, no
  behavioural test edits. **Full-run note:** `test/sync/order_collision_heal_test`
  flaked once in the combined run (passes in isolation and as a group — the
  documented cross-suite flake, unrelated).
- **Next:** batches #18–21 migrate the remaining 74 sites (each shrinks the
  allowlist); #22 empties it, privatizes the bare helper, goes strict.
- **Pending:** emulator walkthrough (stock keeper vs cashier — FAB + screen guard
  reachability + live revocation).

### Refactor: `SyncedTable` registry — one source of truth per synced table (2026-07-01, issue #15)
- **Problem:** a synced table's knowledge was smeared across six constructs (the
  synced-tenant-table list, pull order, push whitelist, `created_at`-scrub set,
  and two hard-delete switches) + a ~50-case restore switch. Wiring five of six
  and forgetting one compiled and worked locally but **silently dropped that
  table's rows on peer devices** — the recurring "wire ALL client apply sites"
  trap in the most safety-critical subsystem.
- **Fix:** one ordered `List<SyncedTable>` in the database layer
  (`lib/core/database/sync_registry.dart`, `part of` app_database.dart — no
  import cycle). Each entry is the whole per-table truth (restore fn, optional
  push columns / hard-delete rule, scrub flag, tenant/cache flags); the six
  constructs now **derive** from it and the literal lists + restore switch are
  deleted. Restore helpers (`Restore.plain/.naturalKey/.dedup/.ledger` + a
  bespoke `users` closure) and a database-layer `SyncRestoreExecutor` (FK-resilient
  helper + ledger restore) keep the registry dependency-free; the two hard-delete
  switches collapsed into one `SyncHardDelete` per entry.
- **Behaviour-neutral:** no schema / cloud / wire-protocol change; the central
  pre-insert guards (LWW, invariant #12, business isolation) are unchanged.
- **Tests:** new golden-equivalence test freezes the six constructs' pre-collapse
  values; the reflection test now asserts registry membership. Behavioural seams
  (outbox-sacred, FK-resilience, hard-delete reconcile, realtime DELETE, dispatch,
  scrub) stayed green unchanged. `test/sync/` + `test/database/` = 233 green,
  `flutter analyze` clean. See BUILD_LOG 2026-07-01.
- **Note:** `test/auth/who_is_working_screen_test.dart` fails **pre-existing**
  (identical with this refactor stashed) — unrelated parallel-work / widget timing.

### Fix: cloud money columns widened to `bigint` (2026-07-01)
- **Symptom:** Sync Issues showed `supplier_ledger_entries:upsert` stuck at 42
  attempts — `PostgrestException 22003 "value 12360040000 out of range for type
  integer"` (₦123.6M in kobo overflows int4's ₦21.5M ceiling), permanently jamming
  the outbox. Local value stored fine (64-bit), so it was un-pushable, not lost.
- **Fix (cloud-only, migration `0130`):** `ALTER TYPE bigint` on all 34 int4 money
  columns (30 `*_kobo` + 4 crate-count `balance`) across 22 tables — none were
  bigint before. Verified 0 remain. No Drift migration (already 64-bit);
  `pos_pull_snapshot` returns jsonb so the pull path is untouched. Stuck row pushes
  on next retry, no data lost.
- **Prevention:** `code-standards.md` now mandates every cloud `*_kobo` column be
  `bigint`. See BUILD_LOG 2026-07-01.

### First-Load "Loading your store" Overlay Redesign (2026-06-30)
- **Change:** the post-login full-pull loader is now a brief (≤ ~2 s) "Setting up
  ‹Business›…" reassurance that hands off to per-tab skeletons + a thin top sync
  line, with a prominent retry path and a faster restore. Spec:
  `context/specs/brief-first-load-store-overlay.md`. Invariants #1/#11 preserved.
- **Single seam:** new `FirstLoadOverlayController`
  ([first_load_overlay_controller.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/sync/controllers/first_load_overlay_controller.dart))
  — a `StateNotifier<FirstLoadOverlayState>` ({hidden, loading, retryNeeded})
  owning all timing (400 ms floor / 2 s cap), the retry counter (2 silent retries
  online → retryNeeded; offline → retryNeeded immediately), and eligibility,
  derived from five injected/overridable input providers. `SyncPullBanner` and the
  tab screens only render it.
- **Marker (§4.2):** wired `FirstLoadMarkerService` — `markPullCompleted` on a
  clean `pullChanges` completion; **`clearAllMarkers()` inside `clearAllData()`**
  (best-effort) so a wiped/re-onboarded device re-shows the overlay (the documented
  highest-risk wipe trap).
- **Restore batching (§4.6):** `pullInitialData` wraps each table's restore in one
  Drift transaction (one commit/table) — per-row FK/unique resilience unchanged.
- **Progress (§4.5):** row-weighted `PullStatus.rowsDone/rowsTotal/rowPercent`
  drives the determinate top line + overlay %; copy "Setting up ‹Business›…".
- **Skeletons (§4.4):** one themed shimmer primitive (no `shimmer` dep) + POS /
  Home / Inventory / Reports skeletons, gated on `firstLoadSkeletonActiveProvider`.
- **Out of scope (unchanged):** the deferred-pull repeated-full-pull loop (§6),
  `syncMinimumLogin` time-boxing, schema/DAO/pull-ordering. The two-pass batch-insert
  fast path was implemented as the safer single-transaction-per-table form.
- **Tests:** Seam A (13, `fake_async`) + Seam B (parity + `rowPercent`). `flutter
  analyze` clean; `test/sync/` (143) + new (21) + inventory/receiving green.
  Pre-existing unrelated baseline failure: `who_is_working_screen_test`. On-device
  emulator walkthrough pending.

### Auth Screen Desktop/Tablet Redesign (2026-06-27)
- **Change:** Redesigned the authentication screen layouts (Welcome, Sign-In, OTP, SignUp, Lock Screen, etc.) to suit tablet and desktop viewports by constraining and centering forms.
- **Details:**
  - Updated [branded_auth_background.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/auth/widgets/branded_auth_background.dart) and [auth_background.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/auth/widgets/auth_background.dart).
  - Wrapped form/content child widgets in a centered container with a maximum width constraint of `480.0` dp on all non-phone viewports (`!context.isPhone`).
  - Dotted grid and gradient background glows continue to cover the full viewport width and height.

### Layout Responsiveness for Tablet and Desktop viewports (2026-06-27)
- **Change:** Re-architected the main application navigation and product grids to adapt to desktop and tablet form factors.
- **Details:**
  - Updated [main_layout.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/shared/widgets/main_layout.dart) to show a persistent, fixed-width (`280.0` dp) `AppDrawer` sidebar on the left and active tab navigator on the right on desktop, while hiding the bottom nav bar.
  - Configured [app_drawer.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/shared/widgets/app_drawer.dart) to render as a flat, shadow-free container on desktop, and route settings/management screens onto the sub-navigator of the active tab (instead of root), keeping the sidebar open at all times.
  - Modified [shared_scaffold.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/shared/widgets/shared_scaffold.dart) to hide the default drawer on desktop.
  - Conditional leading hamburger buttons on root tab/sub-pages to clean up app bar spacing on desktop: [pos_home_screen.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/pos/screens/pos_home_screen.dart), [inventory_screen.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/inventory/screens/inventory_screen.dart), [orders_screen.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/orders/screens/orders_screen.dart), [cart_screen.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/pos/screens/cart_screen.dart), [home_screen.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/dashboard/screens/home_screen.dart), [stores_screen.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/stores/screens/stores_screen.dart), [staff_management_screen.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/staff/screens/staff_management_screen.dart).
  - Updated [view_selector_sheet.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/shared/widgets/view_selector_sheet.dart) to restrict layout options to "Grid View" and "List View" on tablet/desktop.
  - Subtracted the 280dp sidebar width from grid column/aspect ratio calculations on desktop: [product_grid.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/pos/widgets/product_grid.dart), [receive_product_grid.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/receiving/widgets/receive_product_grid.dart).
- **Verification:** `flutter analyze` clean, no issues found. Branch: `feat/desktop-auth-redesign`

### Wallet → Credits Balance / Ledger Entries terminology alignment (2026-06-27)
- **Change:** Aligned all user-facing terminology to refer to "Credits Balance", "Ledger Entries", "Add Credit", and related non-e-money terms, avoiding regulatory/compliance risks of "Wallet" or e-money vocabulary.
- **Details:**
  - Renamed `WalletService` -> `CreditLedgerService` and `wallet_service.dart` -> `credit_ledger_service.dart`.
  - Renamed test files `wallet_logic_test.dart` -> `credit_ledger_logic_test.dart` and `wallet_service_dispatch_test.dart` -> `credit_ledger_service_dispatch_test.dart`.
  - Renamed Riverpod provider `walletBalancesKoboProvider` -> `creditBalancesKoboProvider` in `app_providers.dart`.
  - Renamed view-model/local properties: `supplierWalletBalanceKobo` -> `supplierAccountBalanceKobo` in `recon_data.dart` and `customerWallet` -> `customerCreditBalance` in `cart_screen.dart`.
  - Wording updates on: `customer_detail_screen.dart`, `customers_screen.dart`, `checkout_page.dart`, `cart_screen.dart`, `home_screen.dart`, `orders_screen.dart`, `crate_return_modal.dart`, `receipt_widget.dart`, `receipt_builder.dart`, `daily_reconciliation_detail_screen.dart`, `crate_deposits_report_screen.dart`, `invite_staff_screen.dart`, and permission description strings in `app_database.dart`.
- **Deferred: Tier C — full physical schema/cloud rename of wallet_transactions/customer_wallets, RPCs, RLS, realtime, 'wallet' CHECK enum, permission keys — MUST be done later**
  - **Rationale:** Stored payment type / reference type strings, database table names, SQL migrations, cloud/RPC hooks, and RLS/realtime policies are kept unchanged to avoid breaking historical order records, client-side sync protocols, and tenant isolation policies during this transition. These invisible, non-user-facing items are deferred to Tier C.

### Add/Edit Store — state/LGA autocomplete (2026-06-27)
- **Gap:** Add Store and Edit Store bottom sheets used plain free-text fields for
  "City and State" + "Country", offering no guidance. The onboarding flow already
  uses searchable autocomplete backed by `kCountries`, `kNigerianStates`, and
  `kNigerianLgas`.
- **Fix:** [stores_screen.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/stores/screens/stores_screen.dart)
  — replaced the two plain fields with three structured fields in both `_showAddSheet`
  and `_showEditSheet`:
  1. **Country** — `_AppAutocompleteField` with `kCountries`, default Nigeria.
  2. **State / Region** — `_AppAutocompleteField` with `kNigerianStates` when
     Nigeria is selected; plain `AppInput` otherwise.
  3. **LGA / District (optional)** — `_AppAutocompleteField` keyed on selected
     state (auto-resets on state change) when Nigeria; plain `AppInput` otherwise.
  - State field validates on save (required); LGA is optional.
  - Location string format changed to `street, lga, state, country` (matching
    `OnboardingDraft.locationCombined`). Edit sheet parses both old 3-part and new
    4-part formats for backward compat.
  - New private `_AppAutocompleteField` widget at bottom of file: filled-style
    `Autocomplete<String>` matching `AppInput` visual style.
  - Branch: `fix/store-address-state-dropdown`
- **Verification:** `dart analyze` clean; on-device check pending.

### Post-OTP "Setting up your account…" centered spinner (2026-06-26)
- **Gap:** after the 6-digit code was accepted, the OTP screen showed a static
  "Verified ✓" button while `saveAuthMethod` + `resolvePostVerifyRoute`
  (`fetchSupabaseAccount` RPC, and for returning devices the minimum-login pull +
  `upsertLocalUserFromProfile`) ran with **no indicator** — looked frozen for
  several seconds on poor connections.
- **Fix:** [otp_verification_screen.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/features/auth/screens/otp_verification_screen.dart)
  `_resolving` flag drives a **centered spinner over a faint scrim** ("Setting up
  your account…") during the post-verify resolution; the verified-but-load-failed
  `catch` resets it. The CEO/staff sign-up OTP steps only advance a wizard step
  (`_goTo`) after OTP, so they have no gap and were left untouched.
- **Verification:** `flutter analyze` clean; on-device check pending.

### First-login / fresh-business loading indicator — spinner + % (2026-06-26)
- **Gap (not a bug):** after creating a business or first login, the device drops
  straight into the empty `MainLayout` shell (correct per invariant #11) while the
  background catalogue pull streams in, but the only cue was `SyncPullBanner`'s
  near-invisible 2.5px top bar — users saw a blank screen and didn't know data was
  loading.
- **Fix (UI-only, non-blocking):** [sync_pull_banner.dart](file:///Users/solomonizu/flutter_projects/drinkPosApp/lib/shared/widgets/sync_pull_banner.dart)
  now derives a live `percent` from the already-wired `PullStatus.tablesDone /
  tablesTotal` (advanced per restored table in `pullInitialData`). The top
  progress bar became **determinate**; a new **centered** `_LoadingOverlay`
  (spinner + "Loading your store" + `NN%`) shows during `PullStage.background`,
  wrapped in `IgnorePointer` so it never gates interaction; the existing
  "Synced ✓" / "Sync failed · Retry" pills keep the bottom slot. Suppressed
  during pull-to-refresh. No blocking loader reintroduced (invariant #11
  preserved; `MainLayout` renders underneath and stays tappable throughout).
- **Verification:** `flutter analyze` on the banner clean; no public API change
  (the `main_layout.dart` mount is untouched). On-device emulator check pending.

### Daily Reconciliation — `_statementCard` deconstructed into two cards (2026-06-26)
- **Change:** split the monolithic `_statementCard` (which stacked three cards in
  a Column) into standalone `_netResultCard` and `_businessWorthCard` widgets and
  **deleted** the "Other context flows (informational)" card entirely.
- **New net-result formula:** `_netResultCard` now renders an additive breakdown
  that sums to the bold total — `+ Inventory on hand (at cost)`,
  `+ Goods received`, `− Paid to suppliers`, `− Refunds`, `− Expenses`,
  `− Damages (at cost)`, `− Crate deposit loss` (only when
  `crateDamageDepositKobo > 0`), `− Stock shortages (at cost)`, divider, then
  **Net result for period**. `ReconData.periodNetResultKobo` was redefined to
  this exact formula (was `grossProfit − expenses − damages − crateDeposit −
  shortages`) so the displayed lines reconcile to the total. Gross-margin note
  dropped from this card (still in CSV + P&L).
- **Card order** (CEO cost-wall preserved): `_netResultCard` (CEO) →
  `_salesCard` (all) → `_plCard` (CEO) → `_businessWorthCard` (CEO) →
  `_shrinkageCard` → `_stockCard` → (`_debtsExpensesCard` non-CEO) →
  `_cratesCard` → `_breakdown`.
- **CSV:** `_exportCsv` CEO block regrouped to mirror the three cards (net-result
  lines, then P&L, then business-worth); crate-loss row now gated on
  `crateDamageDepositKobo > 0`. `dart analyze` clean on both touched files.

### Roles & Permissions stuck at "N of 0" after logout→login (2026-06-26)
- **Bug:** logged in as CEO, Roles & Permissions showed "All 0 permissions" /
  "29 of 0" etc. and each role's detail page rendered no toggles. The grant
  counts were right; only the catalogue **denominator** was 0 — the local
  global `permissions` table was empty.
- **Root cause:** the `permissions` catalogue is static config seeded only at
  DB-create + the v13 upgrade and is deliberately never synced. But
  `AppDatabase.clearAllData()` wipes EVERY table (`for table in allTables`) —
  including `permissions` — on logout/business-delete/onboarding reset, and a
  later login re-pulls only the tenant tables, so the catalogue stayed empty
  with no recovery path.
- **Fix:** new idempotent `ensurePermissionsSeeded()` re-seeds when
  `COUNT(*)==0`, called from `beforeOpen` (heals already-broken devices on next
  launch) and the end of `clearAllData()` (same-session logout→login). Bumped
  the stale loading-fallback denominator 30→38. `dart analyze` clean. See
  BUILD_LOG 2026-06-26.

### Fresh-onboarding empty store dropdowns fixed (2026-06-26)
- **Bug:** after creating a new account + business, the Receive-Stock Invoice
  "STOCKING INTO" dropdown and the Request Stock pickers showed zero stores;
  restarting the app fixed it. Root cause was `allStoresProvider` poisoning on a
  `StateError`: `watchActiveStores()` bakes the businessId into its query at
  build time (`requireBusinessId()` throws on null), and the provider only
  depended on the never-changing `databaseProvider`, so a first-subscribe during
  the create-business null-businessId window (`CeoSignUpScreen._commit` pulls +
  3 s delay BEFORE `setCurrentUser`) stuck for the whole session. Same provider
  feeds the stock-transfer pickers.
- **Fix:** `allStoresProvider` now watches `authProvider.select((a) =>
  a.currentUser?.businessId)` and returns an empty stream while null instead of
  throwing — self-heals the instant the business binds. `flutter analyze` clean;
  `test/receiving`+`test/sync`+`test/auth` 178 green. See BUILD_LOG 2026-06-26.

### Create-business: cross-device existing email caught at OTP, not at PIN (2026-06-26)
- **Bug:** "Create a new business" with an email already linked to a business on **another device / the web** (no local row here) passed the whole onboarding wizard and was only rejected at **Create PIN**, where `complete_onboarding` raised P0001 *"already linked to another business"* (dead-end `_pinError`). The post-OTP router's detection (`fetchSupabaseAccount`) read **`profiles.business_id`** over several sequential REST calls; a null/unseeded profile, the profiles-scoped `users` RLS, or a transient failure (caught → null) made it report "no account" → `NoAccountFoundRoute` → `CeoSignUpScreen`. Enforcement (migration 0121) keys off **`users.auth_user_id`**, so detection and enforcement could disagree.
- **Fix:** detection now uses the same authority as enforcement. New `SECURITY DEFINER` RPC [0128_current_user_linked_business_rpc.sql](file:///Users/solomonizu/flutter_projects/drinkPosApp/supabase/migrations/0128_current_user_linked_business_rpc.sql) (`current_user_linked_business()`, mirrors the §9 guard exactly, one round-trip, bypasses profiles-scoped RLS) — **deployed live** via MCP `apply_migration`, file kept for repo. `fetchSupabaseAccount()` falls back to it when the profiles path yields no business and in its outer catch, so a cross-device account → `ExistingAccountRoute` → `ExistingAccountScreen` right after OTP (before any onboarding step); fixes both OTP and Google entry points. Safety-net `_commit()` catch now shows a clear `AppNotification` + `popUntil(isFirst)` instead of trapping the user on the PIN step.
- **By design (not done):** no pre-OTP email-existence oracle — invariant #9 + the `email_entry_screen` comment defer existence disclosure until OTP proves ownership (anti-enumeration), and `sendOtp` uses `shouldCreateUser: true`. Post-OTP detection already blocks before any form field. `flutter analyze` clean; RPC verified live.

### Monthly expense budget now reaches the snapshot pull (2026-06-25)
- **Bug:** the monthly budget (§20.1/§20.3, `expense_budgets` table) saved + pushed fine but never appeared on other devices, and was lost on a fresh install / cold start. The table was wired everywhere on the client (RLS 0075, realtime publication + channel loop, `_pullOrder`, `_restoreTableData`) **except the cloud `pos_pull_snapshot` RPC's `v_tenant_tables` array** — the authoritative load/restore path for every `since=NULL` full pull. `expenses`/`expense_categories` were already in the RPC, so expense records synced; only the budget was missing. (Textbook case of the "register a synced table at the cloud pull RPC too" rule.)
- **Fix:** [0127_add_expense_budgets_to_pull_snapshot.sql](file:///Users/solomonizu/flutter_projects/drinkPosApp/supabase/migrations/0127_add_expense_budgets_to_pull_snapshot.sql) — `CREATE OR REPLACE pos_pull_snapshot` off the **live** body (carries forward 0108/0117 additions), `'expense_budgets'` inserted after `'expense_categories'` (FK-safe). Applied directly to the live DB (idempotent function redeploy) since remote migration history is divergent; file kept in repo for reconciliation. Verified live: snapshot now contains `expense_budgets`, nothing dropped.

### Pull-to-refresh unified on SyncPullBanner; old spinner + SnackBars removed (2026-06-25)
- `AppRefreshWrapper` (`lib/shared/widgets/app_refresh_wrapper.dart`) rewritten: the default `RefreshIndicator` spinner is now invisible, the green/red SnackBars are removed, and the pull fires `pullChanges` fire-and-forget so the only sync animation is `SyncPullBanner` (thin top bar + "Synced ✓" / "Sync failed · Retry"). New optional `onRefresh` runs screen-specific provider-invalidation / local-reload work alongside the sync. Uses `pullChanges` (not `syncAll`) for a guaranteed banner cycle; uploads ride the always-on auto-push.
- All raw `RefreshIndicator`s converted to `AppRefreshWrapper` (orders, activity log ×2, staff ×2, customer detail). Pull-to-refresh added to the Payments and Stores tabs (lists given `AlwaysScrollableScrollPhysics`, empty states made scrollable). `RefreshIndicator` now lives in exactly one file. 13 screens, one consistent pull-to-sync behavior.
- **Verification:** `flutter analyze` on the wrapper + 7 changed screens → clean. On-device pull-gesture check pending.
- **Hotfix (2026-06-25, same day):** a later working-tree change re-broke this by adding a custom branded `_PullOrb` (glassy spinning circle) to `AppRefreshWrapper` *and* awaiting `pullChanges`. On-device that produced TWO animations (orb + the banner's top bar) and dragged the content down (large empty gap). Reverted `AppRefreshWrapper` to the documented lean form: transparent (hidden) `RefreshIndicator`, no orb, `pullChanges` fired **fire-and-forget** (`unawaited`) so the indicator releases instantly and `SyncPullBanner` is again the sole animation. `onRefresh` + forced `AlwaysScrollableScrollPhysics` preserved. `flutter analyze` clean; on-device recheck pending.

### Pull restore hardened against partial pulls + non-blocking sync-status UX (2026-06-25)
- **Crash fixed:** a partial pull (parent slice dropped mid-stream — e.g. `Connection reset by peer`) made `user_businesses`' `role_id` FK fail (SqliteException 787), which aborted the whole `pullChanges` and starved every table after it in `_pullOrder` → **blank MainLayout**. The post-`products` tables already used `_insertResilient` (skip-and-defer + cursor hold), but the **entire pre-`products` bootstrap cluster** used plain `insertOnConflictUpdate`. Wrapped all of them in `_insertResilient`: `stores, roles, role_settings, role_permissions, user_permission_overrides, store_role_permissions, user_businesses, user_stores, invite_codes, crate_size_groups, manufacturers, categories, suppliers`. An orphaned bootstrap row now defers (heals on the next full pull) instead of blanking the app. For the three permission tables the delete-then-insert body is wrapped together (delete is FK-safe).
- **UX:** `SyncPullBanner` (`lib/shared/widgets/sync_pull_banner.dart`, mounted in `main_layout.dart`) gives non-blocking sync feedback — thin top `LinearProgressIndicator` during the background pull, dismissible "Sync failed / Retry" pill on failure (retry calls `pullChanges`), brief "Synced ✓" pill on success. Driven by `pullStatus` (`background`→`completed`/`failed`); never gates entry (offline-first invariant #1 preserved).
- **Verification:** `flutter analyze` on sync service + banner + main_layout + main + auth_service → clean. Network-timing repro pending on-device.

### Offline-first entry: blocking "Syncing Your Store" loader removed (2026-06-24)
- The full-screen post-login loader that gated entry on a network pull is **gone**. `_HomeRouter._resolve` (`lib/main.dart`) no longer shows `FirstSyncScreen` (empty local `businesses`) or `_BackgroundPullLoading` (in-flight full pull, no local products). A logged-in device — fresh or returning, online or offline — now drops **straight into `MainLayout`**; the only pre-`MainLayout` step is the `_BrandedSplash` shown while the **local** `businesses` SQLite query resolves.
- The render-critical 4 tables still pull **inline at the sign-in boundary** (`syncOnLogin` → `syncMinimumLogin`); the full pull (`pullChanges`) still fires non-blocking from `setCurrentUser`, so the catalogue + everything else stream in **live** while `MainLayout` renders an empty-but-functional shell. Fresh sign-in with no business row → subscription gate evaluates as `grace` (not locked) → MainLayout; `currentBusinessProvider` null is handled safely.
- Deleted `first_sync_screen.dart` + `initial_load_animation.dart` (now unused). Updated `architecture.md` (Invariant #11 + onboarding-pull section). `flutter analyze` clean; `test/auth` + `test/sync` → 161 passing. On-device offline-open check pending.

### Crate-aware damages (§17.2) — forfeited crate deposit on the Statement
- Record Damages asks the crate fate for a tracked bottle (`unit=='bottle' && trackEmpties`). **Only two scenarios are tracked** (user-confirmed):
  - **`full` — full crate lost** (drink + its container): drink cost (`damageCostKobo`) AND crate deposit (`crateDamageDepositKobo`) forfeited; held-empties pool **untouched** (that container was never a returned empty). Rides on the `damage:<key>+cratelost` reason suffix; still a product damage (decrements bottle stock).
  - **`empty` — stored empty crate damaged**: a **crate-only loss** — no drink involved, so it removes **no** bottle stock and books **no** drink cost. Debits the empty-crate pool + store balance + a `damaged` crate_ledger row via `InventoryDao.recordEmptyCrateDamage`; quantity validated against the held-empties pool, not stock. Writes **no** stock_adjustment.
  - `none` is the non-crate baseline (just the drink lost).
- Deposit math `crateDamageDepositKobo` = `units * Manufacturers.depositAmountKobo` (1 bottle unit = 1 crate). Source split: full-crate from the `+cratelost` adjustment rows (`damageForfeitsFullCrate`); stored-empty from the `damaged` crate_ledger rows (new `allCrateDamagesProvider` / `InventoryDao.watchAllCrateDamages`). Subtracted in `netProfitKobo` + `periodNetResultKobo`; shown as "Crate deposit loss" in the P&L/Statement cards + CSV. No double-count (flow P&L vs. held-empties stock view).
- Cloud already accepts the `damaged` crate_ledger movement (0011/0047/0070) — no migration. Tests: test/crates/crate_damage_test.dart. `flutter analyze` clean; crates + inventory suites green (50). On-device check pending (verify the empty-crate fate removes no bottle stock + shows "Crate deposit loss").

### Daily Reconciliation Report engine enhancements (Part 1, 2, & 3)
- **ReconData updates (Part 1):** Added `supplierPayableKobo`, `inventoryOnHandKobo`, `uncostedInventoryItems`, `surplusCostKobo`, `topItems`, and `manufacturerEmpties`.
- **Invariants maintained:** `orderCountsAsSale(status)` remains unchanged; ledger filtering for voided entries is strictly followed; money math is exclusively in kobo (`int`).
- **Design decisions explicitly noted:**
  - `productsWithStockProvider(null)` returns aggregated stock since `ProductDataWithStock` does not expose `storeId` on the individual items; as a result, the `inventoryOnHandKobo` property aggregates all available `totalStock` returned by the provider without additional `storeId` filtering.
  - For `businessNetPositionKobo`, customer debt (`totalOwedKobo`) was treated as a positive value (to be flagged as "at risk" in UI later), and empty crates held (`crateDepositKobo`) was updated to be a recoverable asset (`+ crateDepositKobo`) as directed in Part 2.
- **Statement UI Rebuild (Part 2):**
  - Rebuilt `_statementCard` in `daily_reconciliation_detail_screen.dart` into three clear semantic sections: "Net result for this period", "Business worth right now", and "Other context flows".
  - Used `AppSemanticColors.success` and `theme.colorScheme.error` for profitability metrics.
  - Added new fields to CSV export for CEO roles only.
- **Sales & Empty Crates UI (Part 3):**
  - Expanded `_salesCard` to list the top 3 selling items dynamically.
  - Rebuilt `_cratesCard` to show a detailed per-manufacturer breakdown of crates held along with their respective deposit values.
- **Verification:** Ran `flutter analyze` locally, no issues found.

---

## Crate Flow Mapping (Confirmed)
- **Crates TAKEN (at checkout)**: `checkout_page.dart` receives `crateLines` from `cart_screen.dart` (gated by `unit=='bottle' && trackEmpties`). 
  - `_buildCrateDepositSection()` handles per-brand deposit capture when `_depositApplies` is true (registered customer + Cash/Transfer + crate business).
  - A new `_buildReadOnlyCratesSection()` displays a read-only confirmation of empties taken for walk-ins, wallet, or credit sale payment modes.
  - On confirm, `addOrder` logs crates taken + deposit snapshot + deposit paid into `order_crate_lines`, ensuring dual-write symmetry locally and on the cloud.
- **Crates RETURNED**: `crate_return_modal.dart` correctly recognizes crate returns exclusively through the pending-order confirm modal (`CrateReturnModal.show`). The checkout path correctly isolates sale creation without invoking any return or settlement writes.

---

## Call-Site Audit for Receipt Construction
1. **`lib/features/orders/screens/orders_screen.dart:852`** (`_viewReceipt`): Rebuilds `cart` map. Misses `unit`, `trackEmpties`, `manufacturerId`. Misses `manufacturerNames` param.
2. **`lib/features/orders/screens/orders_screen.dart:997`** (`_printReceipt`): Rebuilds `cart` map. Misses `unit`, `trackEmpties`, `manufacturerId`. Misses `manufacturerNames` param (for `ThermalReceiptService`).
3. **`lib/features/customers/screens/customer_detail_screen.dart:987`** (`_showReceipt`): Rebuilds `cart` map. Misses `unit`, `trackEmpties`, `manufacturerId`. Misses `manufacturerNames` param.
4. **`lib/features/customers/screens/customer_detail_screen.dart:1088`** (`_printReceiptFromDetail`): Rebuilds `cart` map. Misses `unit`, `trackEmpties`, `manufacturerId`. Misses `manufacturerNames` param (for `ThermalReceiptService`).
5. **`lib/features/pos/screens/checkout_page.dart:1436`** (`_printReceipt`): Cart map is intact, but `buildReceipt` doesn't currently accept `manufacturerNames`. Will be updated.

**Decisions Recorded:**
- `cratesOwed` and `cratesCredit` will be completely removed from `receipt_widget.dart` and `buildReceipt` params as they are replaced by the new "Empty Crates" section.
- Extract the per-manufacturer grouping into a shared helper in `receipt_widget.dart` to avoid duplicating the manufacturer list. The new always-on "Empty Crates" section owns the manufacturer + count breakdown, and the "Crate Deposit" block will be collapsed to a single financial line.

---

## Current Goal

Fresh-device loading animation + background-pull gate shipped (Session 151).
Google sign-in diagnostics + error split shipped (Session 152, see below).

Pending operator step (REQUIRED before Google sign-in works on release builds):
Register the release signing-certificate SHA-1 in Google Cloud Console:
1. Get debug SHA-1: `keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android`
2. Get release SHA-1: `keytool -list -v -keystore android/app/upload-keystore.jks -alias upload` (passwords from android/key.properties)
3. In Google Cloud Console → APIs & Services → Credentials (same project as client ID 807123945489-...), create an Android OAuth client with package `com.reebaplus.pos` and add both SHA-1 fingerprints.
4. If distributing via Play App Signing: also add the SHA-1 from Play Console → Setup → App integrity.

Other pending: on-device smoke test for fresh-device loading animation (Session 151).

---

## Session 153 — Offline-first hotfix: loading gate no longer blocks app open

**Root cause:** The Session 151 fresh-device gates tied `MainLayout` entry to a
*network* pull. The background-pull gate fired whenever `!hasLocalProducts &&
stage != PullStage.completed`. Offline the full pull never reaches `completed`
(fails → `failed`, or never runs → `idle`), so any logged-in user with an empty
local product table (new business, staff/stock-keeper device, zero-product
business) was permanently stuck on the loader / `_BackgroundPullFailed` retry
screen — the app could not open offline. The minimum-pull gate also treated the
"local businesses query still loading" state (`valueOrNull == null`) as "no
business", flashing `FirstSyncScreen` (which fires a network `syncMinimumLogin`)
for returning offline users.

**Changes (`lib/main.dart`, `_HomeRouter._resolve`):**
- Minimum-pull gate waits for the local query to **resolve**: no value yet →
  `_BrandedSplash` (no network); only `FirstSyncScreen` once resolved & empty.
- Background loader engages **only** while a pull is in flight
  (`stage == PullStage.background`) **and only until a 5 s grace cap**. Offline
  (`idle`/`failed`) always falls through to `MainLayout` immediately, even with
  zero products. On a slow-but-working connection the loader self-dismisses
  after `_initialLoaderMaxWait`: `_BackgroundPullLoading` arms a one-shot timer
  flipping `initialLoaderTimedOutProvider`, the router stops gating, the user
  enters the app, and the pull keeps running in background (products stream in).
- Removed the now-unreachable `_BackgroundPullFailed` screen + its unused
  imports. Pull failures surface via the existing MainLayout sync banner.

**Verification:** `flutter analyze lib/main.dart first_sync_screen.dart` clean.
Offline-first invariant restored: a logged-in device always opens from local
data within a few seconds regardless of connectivity.

---

## Session 152 — Google sign-in diagnostics + cancel/error split

**Root cause:** Native `signIn()` on a release build throws a `PlatformException`
with code `sign_in_failed` and ApiException status 10 (DEVELOPER_ERROR) when the
release signing-certificate SHA-1 is not registered in Google Cloud Console. The
prior monolithic `catch (e)` swallowed this as a quiet null return, so the UI
showed the same "cancelled or failed" banner for a config error and a user dismiss.

**Changes:**
- `lib/shared/services/auth_service.dart`: Added `GoogleSignInException` class.
  Split `signInWithGoogle` catch into `PlatformException` vs generic; user cancel
  (`code == 'sign_in_cancelled'`) returns null silently; all other errors log a
  `auth.google_signin_error` breadcrumb to `error_logs` via `CrashReporter.record`
  and throw `GoogleSignInException(code, message)`. Added imports for
  `flutter/services.dart` and `crash_reporter.dart`.
- `lib/features/auth/screens/email_entry_screen.dart`: Wraps `signInWithGoogle()`
  in a try-catch for `GoogleSignInException`; shows "Google sign-in failed (code)."
  for real errors. User cancel now exits silently (no error banner).

**Verification:** `flutter analyze` clean on both changed files. On-device
confirmation of status code 10 → "Google sign-in failed (sign_in_failed)." message
pending release build test. After SHA-1 registration, native picker should appear
and sign-in should succeed end-to-end.

Previous target: on-device verification of Session 143 pull-side pagination
(throttled/cellular connection), Session 144 onboarding form updates
(business type picker, phone + LGA fields), and permission gating screen.

---

## Session 151 — Fresh-device loading animation + background-pull gate

**Root cause fixed:** After `syncMinimumLogin` pulled 4 tables (profiles,
businesses, stores, users) the businesses gate in `_HomeRouter` flipped and
mounted `MainLayout` immediately — landing the user on a blank POS grid
because products had not arrived yet. The background full-pull was running
invisibly with no indication to the user.

**Changes shipped:**
- `lib/features/sync/widgets/initial_load_animation.dart` (new): looping
  `AnimationController(repeat(reverse:true))` glow + spinner + FadeTransition
  icon. All sizes via `context.getRSize`, colors via `colorScheme.*`,
  background via `AppDecorations.glassyBackground` (opaque). Accepts optional
  `progressLabel`, `done`, `total` for live progress label.
- `lib/features/sync/screens/first_sync_screen.dart` (refactor): uses
  `InitialLoadAnimation` for the loading state; all raw pixel/color values
  replaced with tokens; error/retry panel unchanged in logic but now uses
  `AppButton` + `AppDecorations.glassCard`.
- `lib/core/providers/app_providers.dart`: added `hasLocalProductsProvider`
  — a distinct-filtered `StreamProvider<bool>` watching
  `inventoryDao.watchAllProductDatasWithStock()`. Flips false→true exactly
  once per fresh-device install.
- `lib/main.dart`: extracted routing IIFE into `_HomeRouter` ConsumerWidget
  (all `ref.watch` calls now at top of `build` per standards). Added
  fresh-device gate: if `!hasLocalProducts && stage != completed` show
  `_BackgroundPullLoading` (live progress) or `_BackgroundPullFailed` (retry
  button). Wrapped navigation in `AnimatedSwitcher` with 350 ms
  `FadeTransition` so loading→POS cross-fades smoothly.

**Safety valves:**
- Gate only fires when `!hasLocalProducts` — returning users with local data
  pass straight through; no regression on normal login.
- `PullStage.failed` + no products → `_BackgroundPullFailed` with retry
  (calls `pullChanges` again).
- `PullStage.completed` + no products (edge case) → falls through to
  `MainLayout` rather than looping.

**Verification:** `flutter analyze` clean; 84 tests pass.

---

## Planned — Data Analytics (Reports hub → Analytics hub)

Brief: `context/data-analytics-brief.md` (13 units, two phases). Adds a "Data
Analytics" card to `reports_hub_screen.dart` opening a new store/period-scoped
Analytics hub of read-only insight cards. Phase 1 = product / staff+store /
timing metrics off the existing `recon_data.dart` aggregation patterns (all data
already collected; migrates "Best performing staff" and "Best selling item" into
the hub). Phase 2 = customer, margin/cost, operations, inventory, and manager
metrics. New permission key `reports.see_analytics` (CEO + Manager). No new
tables/columns; revenue uses `orderCountsAsSale`, store-scoped via
`lockedStoreProvider`. **Not started — Unit 1 (permission key + cloud migration)
is the entry point; land it before any UI.**

**Open questions (must resolve before the dependent unit):**
- **Q1 — season definition** (calendar-quarter vs Nigerian wet/dry vs custom);
  recommend wet/dry (Apr–Oct / Nov–Mar), configurable later. Blocks Unit 7.
- **Q2 — worked-hours source** for sales-per-staff-per-hour (no clock-in);
  recommend first→last-order proxy with caveat. Blocks Unit 13.
- **Q3 — [BLOCKED] transaction duration**: no cart-open timestamp captured, so
  "avg time to complete a transaction" / cross-store speed are not derivable
  without new data capture. Out of scope until product decides.
- **Q4 — expiry write-off path**: products carry expiry but no expiry-specific
  write-off event distinct from a damage. Damage-based loss buildable now.
- **Q5 — [BLOCKED] PO placed timestamp**: receipts record receive date but no
  purchase-order placement event, so order→receive lead time has no start point.
- **Q6 — "gone quiet" threshold** for lapsed customers (30/60/90 days).
  Blocks Unit 11.

---

## In Progress — Store-scoped Stock Transfer + empties-by-manufacturer

Brief: `context/stock-transfer-empties-brief.md` (5 units). Redefines stock
transfer to a requester-initiated request → accept/dispatch → receive flow, all
inside a store's details; moves transfer entry points off the all-stores screen;
adds a Manager store-visibility model (full view only for assigned stores, others
read-only to request); and groups empties by manufacturer everywhere.

- **Unit 1 — empties by manufacturer in Receive Stock — DONE (2026-06-22).**
  Receive checkout now collects empties per manufacturer (one input per
  manufacturer, summed full-crates), and `ReceiveStockService.confirmReceipt`
  takes `emptiesReturnedByManufacturer`. UI-/service-layer only — no migration
  (downstream `recordCrateReturnByManufacturer` already aggregated by
  manufacturer). `flutter analyze` clean; receive_stock_test green (10).
- **Unit 2 — permission catalogue (`stores.request_transfer`,
  `stores.dispatch_transfer`) — DONE (2026-06-22).** Requester confirmed the
  two-key model. Both keys seeded locally (schema v56) + cloud (migration 0122,
  pushed); default CEO + Manager. 0122 also granted the existing
  `stores.receive_transfer` to Manager. `stores.manage` stays CEO-only = store
  CRUD. Migration upgrade test green; cloud grants verified (ceo + manager × 4
  businesses for all three keys).
- **Unit 3 — DAO request/dispatch/reject methods + scoped providers — DONE
  (2026-06-22).** `StockTransferDao.requestTransfer/dispatchTransfer/
  rejectRequest` + `watchAllPending`; `allPendingTransfersProvider` +
  `viewerScopedIncomingRequestsProvider` (holder side) +
  `viewerScopedOutgoingRequestsProvider` (requester side). Reuses the unused
  `pending` status — no schema migration. 19/19 DAO tests green.
- **Unit 4 — store-visibility model + relocation — DONE (2026-06-22).** Drawer
  Stores entry opens to any transfer-permission holder; `stores_screen` no longer
  hard-blocks non-CEOs (Add/Edit/Delete still `stores.manage`); app-bar transfer
  icons removed; `StockTransferScreen` + `IncomingTransfersScreen` retired.
- **Unit 5 — store-details transfer hub — DONE (2026-06-22).** New
  `request_stock_sheet.dart` + `store_transfer_hub.dart`; `store_details` branches
  full (CEO/all-stores/assigned → metrics + Request Stock + hub) vs restricted
  (read-only inventory + "Request Stock from this store"). Per-store family
  providers + DAO watches added.

**Feature status:** all 5 units implemented + tested; Unit 2 cloud-deployed
(0122). Whole-project `flutter analyze` clean; affected test suites green.
Remaining: on-device walkthrough on the emulator.

## Completed

### Onboarding role-binding gate — CEO never enters a permission-less shell (2026-06-24)
- QA pass on the onboarding → store → product → checkout loop found H1: the
  post-onboarding pull (which brings the cloud-seeded CEO role binding —
  `user_businesses` + `roles` + `role_permissions`, NOT in completeOnboarding's
  businesses/stores/users local mirror) was a swallowed "non-fatal" try/catch.
  On a flaky link the CEO landed on POS with `currentUserRoleProvider == null`
  → empty permissions → "no access" / empty drawer, no retry.
- Fix: `AuthService.hasLocalRoleBinding(userId, businessId)` verifies the
  membership + role row + ≥1 grant are local (explicit-businessId queries,
  resolver is null at the onboarding boundary). `CeoSignUpScreen._commit` now
  retries the pull up to 3× and verifies the binding before handoff; on failure
  it keeps the draft, returns to the PIN step, and shows a retryable message.
  `draftNotifier.clear()` moved to after verification so the idempotent commit
  can re-run on retry.
- Also fixed M2: `_commit` surfaced the one-email-one-business P0001 rejection
  as a generic "re-enter your PIN" dead-end loop. Now detects "already linked to
  another business" (+ `users_auth_user_id_key` backstop) and shows a clear
  "use a different email" message — mirrors `staff_sign_up_screen`'s P0001 path.
- Also fixed M3: `AddProductScreen` used `resizeToAvoidBottomInset: false`
  (correct only when nested under MainLayout); the post-onboarding auto-show
  pushes it on the ROOT navigator, where the keyboard hid the save button +
  bottom fields. Set to `true` — safe in both placements.
- Also fixed M4: "Create a new business" now short-circuits to sign-in BEFORE
  sending an OTP when the email already has a fully-set-up account on this device
  (createBusinessIntent + real local PIN). No pre-auth cross-device existence
  oracle (kept the post-OTP reveal to prevent email enumeration).
- M1 from the same pass (new product saved with 0 stock) confirmed by design —
  not changed.
- Verification: `flutter analyze` clean; new
  `test/auth/onboarding_role_binding_test.dart` (4 cases) green; `test/auth/` +
  `test/inventory/` + `test/receiving/` green (64). On-device walkthrough pending.

### Receive Stock checkout — explicit store-allocation dropdown (2026-06-24)
- Replaced the read-only "Receiving for: [store]" row on the receive checkout
  with an `AppDropdown<String>` ("STOCKING INTO *") listing
  `selectableStoresProvider` (already access-scoped). `_flowStoreId` defaults to
  `lockedStore ?? firstSelectable` but is now user-mutable — stock can be
  allocated to any accessible store, independent of the active store.
- Dropped the §15.7 active-store-change abort in `_confirm()` (it would block a
  deliberate cross-store receipt now that the destination is explicit); kept a
  "store must be selected" guard and disabled Confirm while `_flowStoreId` is null.
- Verification: `flutter analyze` clean; `flutter test test/receiving/` green (17/17).

### Receive Stock grid on-hand count matches Inventory in All-Stores scope (2026-06-24)
- Bug: each Receive Stock card's "Current: X" diverged from the Inventory tab in
  All-Stores scope. Inventory aggregates across every store
  (`watchAllProductDatasWithStock`); Receive fell back to
  `selectableStoresProvider.firstOrNull` and showed only the first store's stock.
- Fix: `receive_stock_screen.dart` `_initStreams()` now mirrors the Inventory
  tab — locked store → `watchProductDatasWithStockByStore(storeId)`; no lock →
  `watchAllProductDatasWithStock()`. The receive write target is still resolved
  independently at checkout (§15.7) and shown read-only there, so receiving
  semantics are unchanged.
- Verification: `flutter analyze` clean; `flutter test test/receiving/` green (17/17).

### Receive stock tap and hold to update product (2026-06-23)
- Modified `ReceiveCartNotifier` to add `setProductQty(ProductData, int)` for setting/overwriting product quantities exactly in the receive cart.
- Modified `UpdateProductSheet` in `receiveMode` to initialize the quantity field with the product's current quantity in the receive cart (or 0 if not present).
- Changed save logic in `UpdateProductSheet` to use `setProductQty`, overwriting the quantity in the receive cart with the exact value entered instead of adding to it.
- Updated the UI input label from "QUANTITY TO ADD" to "RECEIVE QUANTITY" and changed the helper text to "This will set the quantity of this product in the receive cart." when `receiveMode` is true.
- Added comprehensive unit tests in `test/receiving/receive_stock_test.dart`.
- Verification: `flutter analyze` clean, all receiving tests passed.

### Wipe staff device at cold start when its business is deleted (2026-06-23)
- Implemented the cold-start and app resume deletion gate (`wipeIfActiveBusinessDeleted`) on `AuthService`.
- Added the active business deletion check in `WhoIsWorkingScreen._resolveBusiness()`. If wiped, the screen pushes replacement to `WelcomeScreen`.
- Added `WidgetsBindingObserver` to `WhoIsWorkingScreen` to re-check for deletion when the app resumes (`AppLifecycleState.resumed`).
- Added the async deletion check in `LoginScreen.initState()` and `didChangeAppLifecycleState()` for app resume on the single-staff PIN screen.
- Created `test/auth/cold_start_deletion_gate_test.dart` to verify the deletion check logic under ambiguous, active, and deleted scenarios.
- Verification: `flutter analyze` clean, all `test/auth` tests passed.

### Improve supplier creation in product + receive-stock checkout & optional manufacturer (2026-06-23)
- Converted `SupplierFormSheet` inline creation to return `Future<SupplierData?>` returning the newly created supplier row on save.
- Added an "Add new supplier" `AppButton` on the Add Product screen (gated by `suppliers.manage`) to create and auto-select a new supplier inline.
- Added an "Add Supplier" `AppButton` on the Receive Checkout screen (gated by `suppliers.manage`) to create and auto-select a new supplier inline.
- Made the Manufacturer field optional when empty-crate tracking is off for a product. In both `AddProductScreen` and `UpdateProductSheet`, the Manufacturer label reads `MANUFACTURER (optional)` when tracking is off, and validation only requires it when `_effectiveTrackEmpties` is true.
- Verification: `flutter analyze` clean, all tests passed.

### Fix logout / login / Who's-working flow for shared-till and sole-user devices (2026-06-23)
- **Core concept:** a device-authenticated user = a local `users` row with `pinHash != null` and an active membership. `pinHash` is local-only/never synced, so it is the authoritative signal that this person completed OTP + PIN setup on this device.
- **DAO** (`daos.dart`): added `watchDeviceStaffForBusiness` and `countDeviceStaffForBusiness` (identical to the `Active` variants but add `users.pinHash.isNotNull()`) + `SyncDao.countPending`.
- **Provider** (`stream_providers.dart`): `deviceStaffProvider`.
- **Who Is Working screen**: swapped to `deviceStaffProvider`; simplified tap routing (all visible users have a PIN); shortcuts → WelcomeScreen (empty) or LoginScreen (single).
- **Email Entry screen**: gated the "Already set up?" PIN button behind `countDeviceStaffForBusiness > 0`; redirects to `WhoIsWorkingScreen` instead of `LoginScreen`.
- **Auth Service** (`auth_service.dart`): `LogoutWipeException`; `logOutCurrentUser` now branches:
  - **Sole user (count ≤ 1):** checks `countPending` — if pending > 0 and offline → throws `LogoutWipeException`; if online → `pushPending()` first; then `clearAllData()` + `fullLogout()`.
  - **Multi-user (count ≥ 2):** clears PIN, revokes session, Supabase+Google sign-out, sets `showPickerOnUnlock = true`, stops sync, resets nav, nulls `value`.
- **Main routing** (`main.dart`): `_checkDeviceUser` uses `countDeviceStaffForBusiness` instead of `countActiveStaffForBusiness`.
- **App Drawer** (`app_drawer.dart`): sole-user warning copy in the Log Out dialog; catches `LogoutWipeException` for offline abort.
- **Tests:** `test/staff/who_is_working_dao_test.dart` (3 tests) + `test/auth/shared_till_logout_test.dart` (5 new tests covering multi-user PIN clear, sole-user pending abort, sole-user wipe, device-staff filtering, and stream reactivity).
- `flutter analyze` clean; `flutter test` 552 passed, 58 skipped, 0 failures.

### Business logo upload + show on receipts (2026-06-23)
**Storage decision: Option A (cloud upload + local cache).**
- **Unit 1 — `BusinessLogoService`** (`lib/core/services/business_logo_service.dart`):
  `pickAndProcess()` (gallery picker → resize ≤512×512 PNG), `save({businessId, bytes})`
  (local cache + Supabase Storage upsert → public URL), `ensureCached({businessId, logoUrl})`
  (serve local; download once from Storage if absent), `clear(businessId)` (local + cloud delete).
  All methods return `Result<T, AppError>` — new `lib/core/result.dart` sealed class.
  Provider: `businessLogoServiceProvider`.
- **Unit 2 — Business Info screen** (`lib/core/settings/business_info_screen.dart`):
  `_LogoSection` widget at top of form card (80×80 avatar, Upload/Change + Remove buttons),
  gated on `settings.manage`. `BusinessesDao.updateInfo` extended with optional `logoUrl`
  param (`_absent` sentinel distinguishes "leave unchanged" from "clear").
- **Unit 3 — Provider + image receipt** (`lib/core/providers/app_providers.dart`,
  `lib/shared/widgets/receipt_widget.dart`): `currentBusinessLogoPathProvider`
  (autoDispose FutureProvider, watches `currentBusinessProvider`, calls `ensureCached`).
  `ReceiptWidget` gains nullable `logoPath` — renders `Image.file` above business name;
  falls back to name-only when null. Threaded at `checkout_page.dart` ~1222,
  `orders_screen.dart` ~1052, `customer_detail_screen.dart` ~1018.
- **Unit 4 — Thermal receipt logo** (`lib/features/pos/services/receipt_builder.dart`):
  `logoPath` param; image decoded via `image` package, resized to 200px, grayscale,
  emitted with `generator.image()` before business name. `esc_pos_utils_plus` has native
  raster support — no deferral needed.
- `flutter analyze lib` — clean (zero issues).

**Operator step (required before distributing a build with this feature):**
1. Create a public Storage bucket named `business-logos` in the Supabase dashboard.
2. RLS policies: INSERT/UPDATE — caller must be a `user_businesses` member of the
   `businessId` path prefix; SELECT — public (`true`).
3. No SQL migration needed (`businesses.logo_url` column + push whitelist already exist).

### Replace Google OAuth browser flow with native in-app account picker (2026-06-23)
- Replaced the browser-based Google OAuth redirect flow with the native ID-token flow using the `google_sign_in` SDK.
- Modified `signInWithGoogle` in `lib/shared/services/auth_service.dart` to show the native account picker, acquire the `idToken` and `accessToken`, and exchange them with Supabase using `supabase.auth.signInWithIdToken`.
- Introduced `googleWebClientId` constant in `lib/main.dart` following the hardcoded configuration pattern of the Supabase url/anonKey, and passed it to `AuthService` dynamically through the `authProvider` in `lib/core/providers/app_providers.dart`. Added a default value to the constructor to preserve backward compatibility in unit tests.
- Configured iOS Google Sign-In support in `ios/Runner/Info.plist` by adding the placeholder reversed client ID URL scheme `com.googleusercontent.apps.1093122091494-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`.
- Verified that all existing `GoogleSignIn().signOut()` calls remain functional.
- Confirmed single-active-session kick contract is untouched and functions identically.
- Checked static analysis via `flutter analyze` (clean, zero issues).

### Sync — Phase 2: `pos_pull_snapshot` retired for first/full pulls (2026-06-22)
- Full/first pulls (`since == null`) now ALWAYS use the paginated `_pullViaPostgRest`
  path, regardless of connectivity. The monolithic RPC is used only for incremental
  pulls on a fast link (`!isSlow && since != null`).
- **Change:** `lib/core/services/supabase_sync_service.dart`, method `pullInitialData`
  (~line 2210). `if (!isSlow)` gate replaced with
  `if (SupabaseSyncService.shouldUseSnapshotRpc(isSlow: isSlow, since: since))`.
- **Helper:** new `@visibleForTesting static bool shouldUseSnapshotRpc({required bool
  isSlow, required DateTime? since})` — pure function, no network, directly unit-testable.
- **Log lines:** full pull logs
  `'[SyncService] Full pull (since=null) → paginated PostgREST path (snapshot RPC bypassed).'`;
  slow incremental still logs the existing slow-connection message.
- **`pos_pull_snapshot` RPC / migration untouched** — incremental pulls on fast links
  still use it; no DB migration in this task.
- Everything after the decision (users fetch, businesses/users canaries, `restoreList`,
  hard-delete reconcile, `PartialPullException`, deferred-tables return) is byte-for-byte
  unchanged.
- **Tests:** `test/sync/pull_path_decision_test.dart` (4 new tests, all green):
  fast+full→false, fast+incremental→true, slow+full→false, slow+incremental→false.
- `flutter analyze` zero errors/new warnings; `flutter test test/sync/` green.
- **Remaining:** on-device/emulator check — fresh login → debug log should show
  `'Full pull (since=null) → paginated PostgREST path (snapshot RPC bypassed).'`

### Supplier Transaction History Keyset Pagination — Phase 1 / Unit 4 (2026-06-22)
- Converted `SupplierTransactionsScreen` from full-table `supplierAllHistoryProvider` +
  in-memory `activityDate` window filter + in-memory summary to on-demand, local keyset
  pagination backed by SQL.
- **DAO** (`SupplierLedgerDao`, daos.dart): added `getSupplierHistoryPage` (paged fetch),
  `watchSupplierHistoryPage` (live head), and `watchSupplierHistoryStats` (aggregate).
  New `SupplierLedgerStats` class (`count`, `totalIn`, `totalOut`, `.empty()` factory).
- **Keyset cursor** is a 3-column triple `({DateTime createdAt, int signedAmountKobo, String id})`.
  ORDER BY `created_at DESC, signed_amount_kobo ASC, id DESC` (mixed-direction).
  Cursor predicate:
  `created_at < c.createdAt`
  `OR (created_at = c.createdAt AND signed_amount_kobo > c.signedAmountKobo)`
  `OR (created_at = c.createdAt AND signed_amount_kobo = c.signedAmountKobo AND id < c.id)`.
- **Date window** pushed down on `activity_date >= startDate` (not `created_at`). Resolved
  via `dateRangeForLabel(period)` locally (no business-tz); matches screen semantics.
- **List keeps voided originals + void compensating rows** (no `voidedAt.isNull()` on list
  queries). Stats exclude them with NULL-safe `(reference_type IS NULL OR reference_type <> 'void')`.
- **Providers** (`stream_providers.dart`): `SupplierHistoryPageState`,
  `PaginatedSupplierHistoryNotifier`, `paginatedSupplierHistoryProvider`,
  `supplierHistoryStatsProvider` — all `autoDispose.family` keyed on
  `({String? storeId, String period})`. Live-head + paged-tail with dedup by `id`.
- **Screen**: header count + summary from SQL stats; list from paginated provider;
  scroll trigger at `index >= length - 5`; spinner footer while `isLoadingMore`.
  `watchAllHistory`/`watchHistory`/`watchAllBalancesKobo`/`voidEntry` untouched.
- **Tests** (`test/payments/supplier_history_pagination_test.dart`, 6/6 green):
  mixed-direction boundary, hasMore/partial/exact-multiple, activityDate vs createdAt,
  store+business scope, voided/void visibility, stats semantics (NULL-safe referenceType).
- Phase 3 remote-fallback open question (in Open Questions) applies here too.
- `flutter analyze` clean; new test suite 6/6 green.

### Inventory History Keyset Pagination (2026-06-22)
- Converted the Inventory History tab from a full-table in-memory watch/filter to on-demand, local keyset pagination using the compound cursor `(createdAt, id)` on the joined transactions query.
- Implemented a "live head + paged tail" pagination strategy in `PaginatedStockHistoryNotifier` using `StreamSubscription` to watch the first page of 30 items reactively and append uniquely fetched page rows to a local tail list, filtering out duplicates dynamically.
- Implemented a SQL-based aggregate query `watchTransactionsStats` inside `StockLedgerDao` to calculate the "Stock In" and "Stock Out" summary values over the full filtered set in SQL, instead of summing the paged list in memory.
- Integrated an index-based scroll trigger (`index >= list.length - 5`) with a bottom loading progress footer on the `InventoryHistoryTab` UI.
- Added unit tests in `test/inventory/stock_history_pagination_test.dart` to verify compound keyset cursor sorting at the identical-second boundary, page size hasMore/multiple semantics, filters push-down, business scoping, voided row exclusion, and stats aggregation.
- Verified that the entire project passes static analysis with zero errors/warnings and all unit tests run green.

### Activity Logs Keyset Pagination (2026-06-22)
- Converted the Activity Logs screen from a full-table (limit 100) in-memory watch to on-demand, local keyset pagination using the compound cursor `(createdAt, id)` to prevent duplication/skipping under identical-second timestamps.
- Implemented a "live head + paged tail" pagination strategy in `PaginatedActivityLogsNotifier` using `StreamSubscription` to watch the first page of 30 items reactively and append uniquely fetched page rows to a local tail list, filtering out duplicates dynamically.
- Pushed down the store-scoping filter to Drift/SQL queries to protect low-end devices and prevent database/UI thrashing.
- Verified that the write API of `ActivityLogService` and all its write call-sites remained completely untouched.
- Added comprehensive unit tests in `test/activity/activity_logs_pagination_test.dart` to verify compound keyset cursor sorting at the identical-second boundary, page size hasMore/multiple semantics, SQL store filter heuristic push-down, multi-business scoping, voided row exclusion, and streaming head updates.
- Verified that the entire project passes static analysis with zero errors/warnings and all unit tests run green.

### Orders History Keyset Pagination (2026-06-22)
- Converted Completed and Cancelled tabs on the Orders screen from a full-table in-memory watch/filter to on-demand, local keyset pagination using the compound cursor `(createdAt, id)` to prevent duplication/skipping under identical-second timestamps.
- Implemented a "live head + paged tail" pagination strategy in `PaginatedOrdersNotifier` using `StreamSubscription` to watch the first page of 30 items reactively and append uniquely fetched page rows to a local tail list, filtering out duplicates dynamically.
- Pushed down the date period, store-locking, and search filters entirely to SQLite queries in `OrdersDao` to prevent DB thrashing, including support for matching refunded statuses in the Cancelled tab.
- Integrated a ~300ms debounce in the UI search text field before updating the autoDispose paginated provider key to prevent creating redundant provider/query instances.
- Added `isLoading` state management to handle initial page load gracefully, and integrated an index-based scroll trigger (`index >= list.length - 5`) with a bottom loading progress footer on the `OrdersScreen` UI.
- Added unit tests in `test/orders/orders_pagination_test.dart` to verify compound keyset cursor sorting at the identical-second boundary, page size hasMore/multiple semantics, filters push-down, multi-business scoping, and order-item folding.
- Confirmed that refunded orders must surface in the Cancelled tab, as they are considered reversed sales in `order_status.dart` and are explicitly tracked in the Cancelled tab summary and status badges. Documented this design decision with code comments.
- Verified that the entire project passes static analysis with zero errors/warnings and all unit tests run green.

### Walk-in Customer Visibility on Receipt (2026-06-22)
- Fixed the receipt rendering logic to hide customer name, phone, address, and related spacing/placeholders for Walk-in Customers, leaving them completely blank.
- Modified both the `ReceiptWidget` (for image capture/sharing/in-app display) and `ThermalReceiptService` (for Bluetooth ESC/POS printing).
- Added comprehensive unit tests in `receipt_widget.dart` to verify that `Walk-in Customer` details are not specified and are left blank on the receipt.
- Updated role-permissions test assertions to reflect the correct number of permissions (35 instead of 33) following database changes, resolving existing failures.

### Onboarding opt-in for empty-crate tracking (2026-06-22)
- Decoupled crate tracking from business type with a per-business opt-in (`businesses.tracks_empty_crates`, default true), chosen at onboarding and editable in Settings → Business Info.
- Unit 1 — Drift schema v56 → v57: added `Businesses.tracksEmptyCrates`; guarded onUpgrade addColumn (same `pragma_table_info` guard as v43 so the revert-then-re-upgrade migration tests pass); regenerated `app_database.g.dart`.
- Unit 2 — Cloud: `0123` adds the column + extends `complete_onboarding` with `p_tracks_empty_crates` (DEFAULT true); whitelisted on the businesses push. `0124` drops the stale 10-arg `complete_onboarding` overload `CREATE OR REPLACE` left behind (would make older 10-arg calls ambiguous, PGRST203). Both deployed and verified.
- Unit 3 — Onboarding draft + CEO sign-up switch + `completeOnboarding` RPC param and local mirror.
- Unit 4 — `businessTracksCrates()` combined gate replaces all crate-visibility sites (incl. the `createOrder` write boundary and the stock-count damages crate-fate guard) + Business Info toggle.
- `flutter analyze` clean; migration-upgrade tests green. Two role-permissions test failures are pre-existing (permission-catalogue count from parallel work), unrelated.
- Remaining: on-device walkthrough on the emulator.

### Make Product Details Screen Read-Only (2026-06-22)
- Added `// ignore_for_file: unused_element, unused_field` to suppress analysis warnings for newly-unused private elements on `product_detail_screen.dart`.
- Commented out the Delete button from the `AppBar` actions list to prevent product deletion.
- Replaced the bottom button block (Save Product button for edit mode, Update Stock button for stock keepers) with a permanent, static "VIEW ONLY" notice.
- Verified that `flutter analyze` runs successfully with zero errors or warnings.

### Fix POS Checkout Wallet-vs-Credit payment classification bug (2026-06-22)
- Added a validation guard in `_confirmPayment` on `checkout_page.dart` to steer cash/transfer checkout with positive customer wallet credit to the Wallet payment method.
- Updated `_paymentLabel` in `checkout_page.dart` to return "Wallet Payment" instead of "Credit Sale" under PayMode.credit if the customer's wallet balance fully covers the total.
- Passed `walletBalanceKobo: oldWalletKobo` in the `addOrder` call on `checkout_page.dart`.
- Added a `walletBalanceKobo` named parameter to `addOrder` in `order_service.dart` and forwarded it to `_resolvePaymentType`.
- Updated `_resolvePaymentType` in `order_service.dart` to classify unpaid credit sales fully covered by the customer's wallet balance as `'wallet'` instead of `'credit'`.
- Added new test cases in `pr_4c_test.dart` to verify wallet, credit, mixed, and cash payment classifications end-to-end.
- Verified that both `flutter analyze` and the new test suite run clean.

### Refactor Request Stock Flow to Dedicated Screen (2026-06-22)
- Refactored the "Request Stock" flow from a modal bottom sheet (`RequestStockSheet`) to a dedicated screen (`RequestStockScreen`) utilizing the `GlassyScaffold` wrapper.
- Deleted the now-unused widget `lib/features/stores/widgets/request_stock_sheet.dart`.
- Refactored `store_details_screen.dart` to perform a route push to `RequestStockScreen` instead of showing a modal sheet.
- Enhanced the `AppDropdown` store selectors on the Request Stock screen with premium prefix icons (`FontAwesomeIcons.store`).
- Implemented mutual exclusion logic: selecting a store in one dropdown automatically clears it from the other to prevent conflicts.
- Verified that `flutter analyze` runs successfully with zero errors or warnings.

### Optimize Route Transitions and BackdropFilter Jank (2026-06-22)
- Centralized BackdropFilter bypass logic in a custom `GlassyCard` component to avoid expensive blur rasterization during page slide animations.
- Refactored private `_GlassyCard` widgets in `customer_detail_screen.dart` and `supplier_detail_screen.dart` to delegate to the public `GlassyCard`.
- Replaced custom `BackdropFilter` widgets with `GlassyCard` in `supplier_ledger_entry_tile.dart`, `daily_reconciliation_list_screen.dart`, `supplier_accounts_report_screen.dart`, and `supplier_transactions_screen.dart`.
- Refactored `_RoleSelectionCard` in `invite_staff_screen.dart` to use `GlassyCard`.
- Wrapped static TabBar in `supplier_detail_screen.dart` and dropdown button in `app_dropdown.dart` with `OptimizedBackdropFilter` to temporarily disable Gaussian blur during screen transitions.
- Cleaned up unused/unnecessary imports of `dart:ui` across the codebase to ensure 100% clean static analysis.
- Verified that `flutter analyze` runs successfully with zero warnings or errors.

### Store-scoped Stock Transfer, Empties, and Per-Store History (2026-06-22)
- **Unit A — Empties move with a transfer:** Wired the existing `transferCrates` database paths into the dispatch flow. When dispatching a crate-eligible product (`unit` == `'Bottle'` case-insensitively and `trackEmpties` == `true`), the user can optionally send empty crates alongside the product (capped at the holder store's available empties). This updates the local crate ledger and enqueues the `domain:pos_transfer_crates` sync outbox transaction.
- **Unit B — Per-store transfer history:** Added a read-only "Transfer history" `ExpansionTile` at the bottom of the store details hub, displaying a list of the most recent completed (`received` / `cancelled`) inbound and outbound transfers, detailing product, quantity, direction chip ("In"/"Out"), counterparty, status, and timestamp.
- **Verification:** Both unit tests and static analysis are clean (0 issues, all 24 transfer suite tests passed).

### Supplier screens Total In / Total Out (2026-06-22)
- Added a two-tile summary showing "Total In" (payments) and "Total Out" (invoices) to both `supplier_transactions_screen.dart` and `supplier_detail_screen.dart`.
- The summary respects the period dropdown filter and skips reversed/reversal rows and voided entries.
- Styled to match the glassy/surface aesthetics of the customer `_buildSummaryTile`.

### Add Staff Screen and Role Capabilities Selector (2026-06-22)
- **Invite Staff Screen**: Created `InviteStaffScreen` in `lib/features/staff/screens/invite_staff_screen.dart` using the new global `GlassyScaffold` standard with scroll-reactive AppBars and glassy background gradients.
- **Interactive Role Selector**: Replaced the simple role dropdown selector with premium vertical selection cards. Each card represents a role option and dynamically shows detailed, bulleted capability lists detailing what that specific role can do (and what they are restricted from doing).
- **Refactoring & Deletion**: Re-routed the "Invite new staff" FAB in `StaffManagementScreen` to navigate to the new screen. Retired and deleted `lib/features/staff/widgets/invite_staff_sheet.dart`.
- **Testing**: Updated and renamed the widget test suite to `test/staff/invite_staff_screen_test.dart`, verifying that Manager role selectors correctly restrict invitable roles. All staff tests pass.

### Move Long-press Hint Info Icon to Product Card (2026-06-22)
- **POS Screen:** Removed the info icon from the AppBar actions list in `pos_home_screen.dart` and added `showHint` and `onHintTap` parameters to `ProductGrid` and `_ProductCard`. Rendered a small `circleInfo` icon at the top right of each `_ProductCard` inside its Stack, with a tap handler to trigger the hint notification.
- **Receive Stock Screen:** Applied the same UI layout change for consistency. Removed the info icon from the action bar of `receive_stock_screen.dart`, added `showHint` and `onHintTap` parameters to `ReceiveProductGrid` and `_ReceiveProductCard` in `receive_product_grid.dart`, and imported the font_awesome package.

### Four UI Fixes (2026-06-22)
- **Active Store Subtitles (Task 1):** Configured active store subtitle rendering (or "All Stores" fallback) across Home, Inventory, Orders, Cart, and Stores via `AppBarHeader`. Configured Customers, Payments, Expenses, Activity Log, and Reports Hub to display the live-updating active store subtitle. Standardized `GlassyScaffold` to support subtitles.
- **Staff Management Menu Button & Scaffold (Task 2):** Wrapped main/denied Staff screens in `SharedScaffold` to preserve routes and drawer access. Replaced back buttons with `MenuButton` to toggle the drawer.
- **Smooth Route Transitions (Task 3):** Replaced `CupertinoPageTransitionsBuilder` with a custom `SlideLeftPageTransitionsBuilder` across all 8 theme blocks in `app_theme.dart`. This slides the incoming page without cross-fading or rendering the outgoing page, eliminating BackdropFilter jank. commented out unused edit buttons/methods in `product_detail_screen.dart` to solve dead code warnings.
- **POS Title Bar Truncation (Task 4):** Updated `AppBarHeader` with `truncateTitleWithReveal`. Enabled it on POS screen to truncate the title at 18px font size with "..." and tap-to-reveal via `AppNotification.showInfo`.

### Long-press haptics + first-run "tap-and-hold to edit" hints (2026-06-22)
- Added `HapticFeedback.mediumImpact()` to all product grid long-press interactions (POS grid, Receive grid, Inventory grid) and Cart item taps.
- Implemented `UiHintService` to track and limit UI hint displays via SharedPreferences (stops after 2 views).
- Replaced the auto-toast hint on POS and Inventory screens with consistent tap-to-reveal info icons in the app bar for POS and Receive Stock screens, and an inline dismissible banner for the Cart screen.
- Properly permission-gated the UI hints (`products.edit_price` / `sales.make`).

### Product Detail UI Adjustments (2026-06-22)
- Temporarily hid the "Edit" button from the Product Detail screen for all users per request.

### Add / Update Product Form Enhancements (2026-06-22)
- Replaced the `AppDropdown` Category field with an `AppInput` + search-as-you-type suggestion list (matching the Manufacturer block) to support large category lists and inline creation.
- Made Product Name and Description placeholders dynamic based on the `_isCrateBusiness` status (e.g., 'Eva water 75cl' vs 'e.g. Heineken 60cl').
- Removed the SIZE dropdown entirely from the UI, keeping the underlying data structure intact for backward compatibility.

### POS "no access" flash on login fixed (2026-06-21)
- After login (notably CEO) the POS landing flashed "You don't have access to
  Point of Sale." for ~1s before the grid appeared. Cause: the `sales.make`
  gate reads `currentUserPermissionsProvider`, which returns an empty set both
  while loading and when truly denied; on fresh login the role + grant streams
  emit a frame after POS builds, so the gate flashed the denial then flipped.
- Added `currentUserPermissionsReadyProvider` (true once role row + base grants
  resolve locally). POS now shows a neutral empty scaffold while unresolved and
  only renders the denial once permissions are known absent. See BUILD_LOG.
- Same pattern exists on other full-screen denial gates (Inventory, Staff, etc.)
  but is less visible (navigated to post-resolve); readiness provider is ready
  to reuse there if needed.

### Staff invite redemption — reject cross-business cleanly (2026-06-20)
- Fixed a crash creating a staff PIN: redeeming an invite while the signed-in
  email already belonged to another business raised a raw 23505 on the global
  `users_auth_user_id_key`, then an FK-787 in the client fallback. This was the
  deferred §6.2 "email already linked to another business" case leaking through.
- Migration 0120 (DEPLOYED) adds a one-email-one-business guard to
  `redeem_invite_code` (typed P0001 before the conflicting INSERT) — enforces
  architecture invariant #9; same-business re-onboarding is unaffected. Applies
  to all staff roles (shared RPC).
- Client: `staff_sign_up_screen` surfaces a clear message and skips the
  FK-crashing cloud-hydrate fallback for that case;
  `auth_service.upsertLocalUserFromProfile` returns null (not FK-787) when the
  local business row is missing.
- Migration 0121 (DEPLOYED) adds the same guard to `complete_onboarding` (CEO
  create-business), which previously had only an ownership guard.
- One-off cleanup: removed the duplicate test businesses on
  `okworchimezie5050@gmail.com` (Coldcrate LTD + C C Okwor deleted; Stable Goods
  pending — has append-only rows, needs the operator-run trigger-disable delete).

### Receive Stock Flow (2026-06-20)
- Implemented the POS-style "Receive Stock" flow: a single "Receive Stock" FAB
  on the Inventory tab → product grid → receive cart (Invoice Total =
  buying × qty, no customer/discount) → invoice checkout (searchable supplier
  picker excluding soft-deleted, backdatable receive date, optional note,
  empties-returned capture). The earlier expandable (Receive Stock + Add New
  Product) FAB was replaced by this single button; `expandable_fab.dart` deleted.
- Re-routed product Add/Update through the Receive Stock cart: new products with initial stock and existing-product restocks now add items to the `ReceiveCartNotifier` instead of directly incrementing inventory. A `receiveMode` flag on `AddProductScreen`/`UpdateProductSheet` (default `false`) preserves the direct-write path for onboarding and the inventory-tab detail editor; in `receiveMode` the per-product Supplier + Store fields are hidden (supplier is chosen once at checkout) and the inventory-tab editor shows no quantity field (details-only).
- Added per-line price editing directly in the Receive Cart UI — buying, retail, AND wholesale price for each line before checkout. Each field is permission-gated: buying on `products.edit_buying_price`, retail/wholesale on `products.edit_price`; the edit affordance is hidden when the role has neither, and the write re-checks each permission. Edited prices persist back to the product on confirm via `CatalogDao.updateProductPrices` (full-row enqueue).
- Added supplier payment capture at checkout: users can specify an "Amount Paid Now" (any non-negative amount, overpayment allowed) + payment method (Cash/Transfer/POS) which atomically records a supplier payment alongside the invoice. The payment section is gated on `suppliers.manage` (render-gate + write-boundary re-check).
- Stock-keeper access: the Receive Stock FAB is gated on `stock.add` OR `products.add`, so a stock keeper can open the flow and add quantity of existing products, but the "New Product" card is gated on `products.add` and price edits on the edit-price permissions — so without those toggles a stock keeper can only adjust quantities. Receiving stock writes inventory directly at checkout (the §16.6.1 approval queue applies to inventory-tab adjustments, not the supplier receive flow).
- `ReceiveStockService.confirmReceipt` commits the whole receipt atomically in one
  Drift transaction: supplier invoice (skipped if zero) + per-line stock adjust
  (with `stock_transactions` history) + crate **return** for empties handed back
  (`recordCrateReturnByManufacturer`) + optional supplier payment + one summary `stock.received` activity row.
- **Empty-crate tracking is return-only** here: empties handed back to the supplier
  on the receipt reduce owed crates for the line's manufacturer. The crate-RECEIVE
  leg from the draft (`recordCrateReceiveFromManufacturer`, movement `received`)
  was removed — it violated the `crate_ledger` CHECK and belongs to the §3.13
  supplier-crate subsystem (since merged in from main), which the Receive Stock
  flow deliberately does not use.
- Guards (§14): FAB on `stock.add`/`products.add`, New Product card on
  `products.add`, grid long-press edit on `products.edit_price`, per-line price
  edits on `products.edit_buying_price` (buying) / `products.edit_price`
  (retail+wholesale), supplier payment on `suppliers.manage` — all with a
  write-boundary re-check, not just a render gate. Store-lock revalidation
  (§15.7): flow captures the active store at init and aborts if it changes before
  confirm.
- Legacy cleanup (§17.12): deleted the dead inbound supplier-delivery flow
  (`deliveries_screen`, `receive_delivery_sheet`, `delivery_service`, `delivery`
  model, `deliveryServiceProvider`) and reindexed the nav (Deliveries tab 9 gone;
  Activity Log now 9). The live order-side `DeliveryReceipt`/`DeliveryReceiptService`
  (rider hand-off) is retained.
- Verification: `flutter analyze lib` clean; `flutter test` green incl.
  `test/receiving/receive_stock_test.dart` (atomic commit, zero-invoice payment,
  price persistence) and `test/receiving/receive_flow_mode_test.dart`
  (`receiveMode` hides/renders Store + Supplier and the quantity field).

### Daily Reconciliation UI Modernization & Custom Range (2026-06-19)
- Redesigned `DailyReconciliationListScreen` to follow the glassy UI standard (`AppDecorations.glassyBackground`, `SharedScaffold`).
- Extracted the period dropdown from the title bar into a dedicated, wider row above the list.
- Added a "Custom range" option to the dropdown via `showDateRangePicker`. Selecting a custom range queries the daily aggregation (`ReconGrouping.day`) bounded by the selected start and exclusive end dates.
- Export to CSV reflects the custom period naming and date range in the subject.
- Replaced the simple card container with a glassy `ClipRRect` + `BackdropFilter` card wrapper.
- Uses `NotificationListener<ScrollUpdateNotification>` for scroll-reactive AppBar background transition.

### Empty Crates "Full" counted non-bottle stock — PET tracked (2026-06-19)
- Bug: a Coca-Cola PET product was tracked in the inventory Empty Crates tab —
  `InventoryDao.watchFullCratesByManufacturer` summed ALL of a manufacturer's
  inventory as "Full" crates (only filtered `manufacturerId != null` + not-deleted),
  while the cart and `createOrder` gate crate issuance on
  `unit == 'bottle' && trackEmpties`.
- Fix: added `unit.lower() == 'bottle'` + `trackEmpties = true` to the query so
  Full matches createOrder's basis. A bottle+PET manufacturer counts only the
  bottle stock; empties were already bottle-only. Updated 2 fixtures + new
  regression test (PET not counted). 16/16 crate tests green. See BUILD_LOG.

### Glassy transition ghosting fixed — opaque page backgrounds + tab warm-up (2026-06-19)
- Root cause of "leftover previous screen": the Glassy page background set both
  `BoxDecoration.color` and `gradient`, but `color` is ignored when `gradient`
  is set — and the gradient's tint stops (primary @0.05/0.12) were ~90% transparent,
  so pages were see-through and the screen beneath bled through during route pushes.
- New central helper `AppDecorations.glassyBackground(context)` — same look, every
  stop made opaque via `Color.alphaBlend(tint, scaffoldBg)`. Applied to
  glassy_scaffold, customers, customer_detail, home, supplier_transactions,
  supplier_accounts_report, supplier_detail.
- `MainLayout._warmNextTab()`: mounts tabs offstage one-per-frame after first frame
  so the first bottom-nav tap isn't a cold synchronous build (lag). 200ms tab
  cross-fade kept; route `FadeTransition` removal from slide_route.dart stays.

### Cart + cart/orders badges store-gated to side-bar store §12.1 (2026-06-19)
- Cart storage re-keyed `userId` → `"userId|storeId"`; `CartService` now takes
  `NavigationService` and swaps the live cart/customer on `lockedStoreId` change.
  Switching stores shows that store's own cart; "All Stores" is its own bucket.
- Cart-tab badge follows automatically (ValueListenableBuilder on `cartProvider`).
- Orders-tab badge now filters pending orders by the active store: switched the
  `main_layout` sub to `ordersDao.watchPendingOrders()` (`OrderData` w/ storeId)
  and counts by `lockedStoreProvider` at build. Cart tests + analyze green.
- **Saved carts store-tagged** (§13.5 follow-up): nullable `saved_carts.store_id`
  (Drift v54 → **v55**, cloud `0119_saved_carts_store_id.sql` — pushed). Save
  stamps the active store; the Recall list (`watchSavedCarts(.., storeId:)`) is
  confined to it (null-store legacy rows stay visible everywhere); `loadCart`
  switches the side-bar store to the cart's origin store and restores into that
  bucket so a store-A cart can't leak into B. New
  `test/pos/saved_cart_store_gating_test.dart`.

### Custom price on a cart item §13.4 + `sales.set_custom_price` (2026-06-19)
- New feature: a permitted user can sell a cart line at a price other than its
  designated selling price; the CEO toggles who may do so per role.
- **Permission:** new catalogue key `sales.set_custom_price` ("Set a custom
  price on a cart item", Sales). CEO-only by default; shows as a normal toggle
  on Roles & Permissions (NOT hidden), so it inherits the business/store/user
  override layers. Local: added to `_defaultPermissionRows`; Drift schema
  **v53 → v54** with an idempotent `if (from < 54)` `INSERT OR IGNORE INTO
  permissions` (v48 pattern; no table change). Cloud:
  `0118_add_sales_custom_price_permission.sql` (catalogue + CEO backfill; new
  businesses auto-grant via the CEO dynamic SELECT) — **pushed 2026-06-19**;
  verified 6/6 CEO roles granted, 0 non-CEO grants.
- **Cart model (`cart_service.dart`):** lines gain immutable `catalogPriceKobo`
  + `customPriceKobo` (null = none). `setCustomPrice` overwrites the effective
  `unitPriceKobo`/`price` (so order line + totals + profit math are unchanged)
  and reverts to catalog when cleared; re-clamps any discount. `refreshProduct`
  keeps the custom price but tracks the new catalog ref; `acceptStaleness` bumps
  the catalog ref too.
- **Custom price floor (2026-06-23):** Enforced a floor on custom prices so they may not drop below the role's maximum discount allowance: `floorKobo = round(catalogPriceKobo * (100 - maxPercent) / 100)`. Selected Option A: the floor governs the effective unit price *after* line discount.
  - **Service:** Updated `CartService.setCustomPrice` and `setLineDiscount` to accept `maxPercent`, clamping custom prices and line discounts to enforce the floor at the write boundary.
  - **UI:** Computed `floorKobo` in `EditItemModal`, added auto-snapping of input fields when typed below floor, clamped live math, limited discount to `(effectiveUnitPriceKobo - floorKobo) * qty`, and displayed a styled warning message under the field.
  - **Tests:** Updated `test/pos/cart_custom_price_test.dart` to verify below-floor clamping, 0% max discount behavior, Option A combined back-door block, and above-catalog overrides. All 9 tests pass.
- **UI (`edit_item_modal.dart`):** permission-gated "Custom Price" section above
  discount; discount cap computes off the effective line total; save applies the
  custom price before the discount in both add and edit modes.
- **Checkout/cart:** `_detectCartStaleness` skips custom-priced lines (a hand-set
  price is never reverted); cart screen shows a "Custom price" badge.
- New `test/pos/cart_custom_price_test.dart` (9 green). `roles_v13_seed_test`
  35 → 36. `flutter analyze lib` clean;
  pos/sync/database suites green. See BUILD_LOG 2026-06-19 and 2026-06-23.

### Login routing changed to POS (2026-06-19)
- Changed the default post-login landing screen from Home (Dashboard, index 0) to Point of Sale (index 1) for all roles, including CEO and Manager, matching the user's intent to land them on POS directly after sign in.
- **Exception (2026-06-20):** roles without `sales.make` (e.g. Stock keeper) land on Home, not POS — POS/Cart are hidden from their nav bar + drawer, so MainLayout bounces a POS/Cart landing to Home once permissions resolve.
- Updated `auth_service.dart`, `navigation_service.dart`, and UI strings in `ceo_sign_up_screen.dart` and `success_dashboard_entry_screen.dart` to refer to "Point of Sale" instead of "dashboard".
- Updated `CONTEXT/project-overview.md` to reflect this change in the core flow and success criteria.

### UI Consistency & Layout fixes (2026-06-19)
- Standardized responsive grid and card layout patterns in `ui-context.md` to prevent text overflow when system font scaling and layout scaling differ.
- Fixed a bottom text overflow issue in `product_grid.dart` by refactoring text blocks to use intrinsic height (via standard containers without flex properties) while keeping the visual area flexible.

### Supplier empty-crate tracking §3.13 — full build (2026-06-19)
- Replaced the §3.13 "coming soon" placeholder on Supplier Details with real
  per-supplier empty-crate tracking — the supplier-side mirror of the customer
  crate subsystem. A customer owes US empties; here WE owe the SUPPLIER empties
  for the full crates they deliver, and the deposit value is the outstanding
  crates × the per-manufacturer rate.
- **Schema (Drift v52 → v53):** two new tables, mirroring the customer side.
  `supplier_crate_ledger` (append-only movement log: `received` +, `returned` −,
  `adjusted`; carries `deposit_paid_kobo`, `store_id`) registered in
  `_syncedTenantTables` + `_ledgerTables` (immutable + no-delete triggers).
  `supplier_crate_balances` (per-(supplier, manufacturer) cache, balance =
  SUM(delta); positive = we owe) registered in `kSyncCacheTables` +
  `_naturalKeyPushConflictTargets`. onUpgrade v53 + `_postCreateStatements`
  index/trigger parity so onCreate == upgrade. Cloud migration
  `0117_supplier_crate_tracking.sql` (table+RLS via `current_user_business_ids()`
  +realtime+bump trigger+`pos_pull_snapshot`) — **written, NOT yet pushed**.
- **DAOs:** `SupplierCrateLedgerDao` (recordCrateReceiptFromSupplier /
  recordCrateReturnToSupplier / watchHistory / watchDepositHeldKobo) +
  `SupplierCrateBalancesDao` (watchBySupplier / watchTotalOwed). Mirrors
  `CrateLedgerDao`. Service `SupplierCrateService` adds Activity-Log writes.
- **Sync:** both tables wired into `_pullOrder`, `_restoreTableData`
  (supplier_crate_ledger via `_restoreLedgerTable`, the cache via natural-key
  resilient upsert), `_tablePushPriority`, `_deferrableTables`. The sync
  registration-completeness test passes.
- **UI:** Supplier Details → **Empty Crates** tab now shows the net crate
  balance (owed / credit), the refundable deposit value, per-manufacturer rows,
  and a "Record crate activity" sheet (Received / Returned + manufacturer + count
  + optional deposit), gated on `suppliers.manage` with a write-boundary re-check.
  **Receive Delivery** now records a supplier crate receipt per tracked line
  (the supplier-side analogue of crate-issue-at-sale) so the invoice tracks how
  many crates arrived.
- **Deposit model decision:** the headline "Deposit value (refundable)" is
  COMPUTED as Σ(positive balance × `Manufacturers.depositAmountKobo`) so it stays
  consistent with the crate balance automatically; the record sheet still stores
  the actual `deposit_paid_kobo` per row for the audit trail (and
  `watchDepositHeldKobo` nets paid − refunded for tests/future detail).
- New `test/suppliers/supplier_crate_test.dart` (5 green: receipt/return netting,
  crate credit, per-(supplier,manufacturer) scope, deposit-held netting,
  append-only delete rejection). `flutter analyze lib` clean (only the 3
  pre-existing settings unused-import warnings). Full suite 452 pass / 58 skipped
  / 1 pre-existing unrelated failure (`invite_staff_sheet_test`). build_runner
  regenerated. See BUILD_LOG 2026-06-19.

### Sync Issues — collapse `sessions:upsert` churn (2026-06-18)
- Diagnosed a Sync Issues queue full of pending `sessions:upsert` / a couple
  `user_businesses:upsert` rows (attempts → 15). Errors were network-rooted:
  errno-7 `Failed host lookup` (DNS down, on the auth token-refresh URI) and
  15s `TimeoutException` — device-side outage, not sync logic; Failed/Orphaned
  were 0, so the queue was retrying correctly and drains on reconnect.
- Real fix: `SessionsDao.createSession` minted a fresh id on every re-auth,
  defeating `enqueueUpsert`'s coalescing (keyed on `payload.id`) → one outbox
  row per login. Now it reuses the existing active session for the same
  `device_id`+`user_id` (bumps `expires_at`, re-enqueues same id), so re-auth
  pushes collapse into one coalesced row. Revoked/expired sessions still mint
  fresh. `AuthService._kickOtherDevices` cloud session `insert`→`upsert` so a
  reused id can't 23505. `flutter analyze` clean; on-device pass pending.
  See BUILD_LOG.

### Supplier Accounts §21 — verification-list gaps closed (2026-06-18)
- Closed the four remaining gaps against the 130-check Phase-1 verification list
  (the core ledger was already built & store-scoped):
  - **§4 confirmation gate** (user-confirmed): Invoice Total and Payment now
    confirm (type/supplier/amount/date/method/store + permanence warning) before
    writing — `confirmSupplierActivity` in `record_supplier_activity.dart`.
  - **§10 CEO void/reversal**: ledger rows tappable on Supplier Details
    (`SupplierLedgerEntryTile.onTap`) → action sheet → confirm → compensating
    row keeps original `store_id`. `SupplierLedgerDao.voidEntry` returns `bool`
    (double-void no-op, 10.11); `SupplierAccountService.voidEntry` logs a
    `supplier.void` Activity row (10.12). CEO-only render-gate + write-boundary.
  - **§15 Supplier Accounts Report**: new `SupplierAccountsReportScreen` + Reports
    hub card gated on `suppliers.manage` (CEO default / Manager toggle / hidden
    for Cashier+Stock keeper). Per-supplier balance/paid/received, store-scoped;
    gross excludes voids, balance nets them. No schema/DAO change.
  - **§3.13 Available Empty Crates**: display-only placeholder on Supplier
    Details for crate businesses (real wiring deferred).
- `test/suppliers/supplier_ledger_test.dart` added (4 green). `flutter analyze
  lib` clean for touched files. On-device pass still pending. See BUILD_LOG.

### Release "session has expired" — investigation + diagnostic breadcrumbs (2026-06-18)
- Investigated a release-build report of being signed out with "session has
  expired". Identified two distinct forced-logout paths: the remote *kick*
  (single-active-device → `fullLogout`, "signed in on another device") vs. the
  *session-expired* gate (`main.dart` `_SessionExpiredScreen`, shown when a local
  user is set but `_supabaseHasSession == false`). The latter flips only on a real
  Supabase `signedOut` event (transient refresh failures are swallowed on
  `onError`), so it means the refresh token was genuinely revoked server-side.
- **Google verdict:** Google sign-in cannot end the signing-in device's own
  session — `_kickOtherDevices` uses `signOut(scope: SignOutScope.others)`, which
  always preserves the requesting session. Google and email/OTP funnel through the
  identical `resolvePostVerifyRoute`; the kick fires from one place
  (`biometric_setup_screen.dart:101`) on a *fresh* sign-up by both providers. A
  release device expiring = the single-active-device policy revoking it because
  the same account signed in elsewhere.
- **Added (no behaviour change):** `auth.session_lost` and
  `auth.session_expired_gate` breadcrumbs to the synced `error_logs` table
  (release-visible in the Supabase console; the latter tags the stored auth method
  so reports can be attributed by provider). Documented the previously-undocumented
  "Single active session per identity" policy in `architecture.md`. `flutter
  analyze lib/main.dart` clean. See BUILD_LOG 2026-06-18.
- **Follow-up fix (same day):** the breadcrumbs weren't actually reaching the
  cloud — verified the live `error_logs` table had 34 rows (generic crashes,
  incl. today) but **zero `auth.*`**. Cause: they fire when the JWT is gone, and
  on the kick path *after* `AuthService.value` is nulled, so `ErrorLogDao.logError`
  resolved `bid == null` and kept the row local-only (never enqueued). Fixed by
  threading an explicit `businessId`/`userId` through `CrashReporter.record` →
  `logError` and scoping each breadcrumb to the in-hand local user, so it's
  durably enqueued and flushes on the next authenticated push (the gate's own OTP
  re-auth). Migration 0108 (`error_logs`) confirmed deployed. `flutter test
  test/sync/` 119/119 green. See BUILD_LOG 2026-06-18.

### Cold-start sync warm-up — false `timeout` on first push after login (2026-06-18)
- Symptom: a `user_businesses:upsert` row failed with a 5s `TimeoutException`
  in Sync Issues right after login, then healed on retry.
- Cause: the first push of a session gets a fail-fast 5s budget, but the first
  authenticated request is cold (DNS+TLS+radio wake+session settling) and
  exceeds it; the first-enqueued row (`user_businesses` after login) eats it.
- Fix (`supabase_sync_service.dart`): `_warmUpConnection` fires one cheap
  `businesses` select before the first drain (pays the cold cost on a throwaway
  request), gated by `_didWarmUpThisSession` (reset on sign-in/out); first-drain
  per-chunk timeout floored at 10s as a backstop. Later drains fail fast as
  before. Sync suite green (119); analyzer clean. See BUILD_LOG 2026-06-18.

### Empty Crates tab — per-store accuracy (Phase 2 active, §16.8.1) (2026-06-18)
- **Reverses the locked Phase-1 business-wide decision below.** The inventory
  Empty Crates tab now shows **per-store** empties when a store is locked, and
  the business-wide total only in "All Stores" mode (`lockedStoreId == null`).
- Data layer: `watchFullCratesByManufacturer({storeId})` gained an optional
  store filter (joins `inventory↔products` on `manufacturer_id`, filters
  `inventory.store_id`); `fullCratesByManufacturerProvider` is store-scoped via
  `lockedStoreProvider`. Empties read from `store_crate_balances` (per store) or
  `manufacturers.empty_crate_stock` (All Stores) — the
  `emptyCrateStock = Σ store_crate_balances` invariant holds.
- Attribution: a **manual** crate return from Customer Profile is credited to
  the store the customer's most recent crate-bearing order was created from
  (`OrderCrateLinesDao.resolveStoreForCustomerManufacturer`), falling back to
  the active store. Receive-Delivery already hard-requires a store;
  crate-return modal already passes `order.storeId` — no leak there.
- UI: Crates tab refactored to reactive `ref.watch` (store can change on any
  tab); removed the redundant imperative crate stream subscriptions.
- Tests: per-store filter + resolver coverage added to
  `test/crates/crate_logic_test.dart` (15 tests green). No schema migration
  (0104 `store_crate_balances` already shipped). See BUILD_LOG 2026-06-18.

### Crates tab "Full" always showed zero — ID-vs-name lookup (2026-06-17)
- Bug: in the inventory Empty Crates tab, every manufacturer card's **Full**
  stat read 0. `_manufacturerCrateStats` is keyed by manufacturer **ID** (the
  watch streams emit ID-keyed maps), but `_buildCratesTab` matched
  `s.manufacturer == mfr.name`, so it never matched and fell to `orElse`
  (`totalBottles: 0`).
- Fix: match by `mfr.id` in `inventory_screen.dart`. No data-layer change — Full
  already streams live from `inventory.quantity` joined on `manufacturer_id`, and
  all writes are stream-tracked (`updates:{inventory}` on the sale decrement,
  `updates:{manufacturers}` on `addEmptyCrates`), so Full depletes on sale and
  empties (returns + pending-order-confirmation deliveries) increment live.
- Test: `watchFullCratesByManufacturer is ID-keyed and depletes on sale` added
  to `test/crates/crate_logic_test.dart` (12 tests green). See BUILD_LOG.

### Revenue recognized at checkout, not at Confirm (2026-06-17)
- Locked model: revenue is recognized when **checkout** completes (order written
  `pending` — wallet legs booked, inventory deducted). **Confirm**
  (`markCompleted` → `completed`) is ceremonial: it records receipt of goods and
  returned empty crates; it creates no revenue.
- Bug: every money/sales aggregation filtered on `status == 'completed'`, hiding
  checked-out-but-unconfirmed sales from all revenue figures until confirmation.
- Fix: canonical `orderCountsAsSale` / `orderRevenueStatuses = {'pending',
  'completed'}` in `lib/shared/models/order_status.dart`; routed Daily
  Reconciliation (`recon_data.dart`), dashboard (`home_screen.dart`), Profit
  Report, Profile Sales Volume, staff sales (`staff_detail_screen.dart`), and
  `getSalesSummaryForProduct` through it. Cancelled/refunded stay excluded. No
  schema change. Analyzer clean; order/wallet tests green. See BUILD_LOG.

### Empty crates — live-refresh fix + business-wide Phase 1 (2026-06-17)
- **Bug fixed:** crate return from Customer Profile didn't update the Crates tab.
  Root cause: balance caches were upserted via raw `customStatement`, invisible
  to Drift's stream tracker. Routed all 5 upserts through `customInsert(...,
  updates: {table})` (`recordCrateReturnByCustomer`, `recordCrateIssueByCustomer`,
  `recordCrateReturnByManufacturer`, `StoreCrateBalancesDao.applyDelta`/`setBalance`).
- **Phase scope decision (SUPERSEDED 2026-06-18 — see Phase 2 entry above):**
  ~~Phase 1 empty-crate counts are BUSINESS-WIDE (checklist §8.7), NOT per-store.
  `store_crate_balances` / `storeCrateBalancesProvider` stay as Phase-2
  scaffolding (rows still written) but no Phase-1 UI reads them. Inventory Empty
  Crates tab now always reads `manufacturers.empty_crate_stock`.~~ The tab now
  reads per-store balances when a store is locked.
- Manual crate return writes an Activity Log row (§7.8); an owed-crate sale
  fires a CEO+Manager `customer_crate_debt` notification (§12.1/§12.2) via a
  best-effort post-sale hook in `OrderService._notifyCrateDebt`.
- Cart "Empty Crates" section hidden for walk-in customers (§3.13).
- Tests: 2 watch-stream regression tests + 3 crate-debt notification tests.
  No schema migration needed (existing tables). See BUILD_LOG 2026-06-17.

### Dashboard debt/credit now business-wide, not store-scoped (2026-06-17)
- Fixed multi-store dashboard inaccuracy: a customer's single business-wide
  wallet balance was being attributed to their assigned home store
  (over/under-counting cross-store customers). `totalCredit`/`totalDebt` now
  fold over all customers regardless of the active store; sales/inventory/
  expenses stay store-scoped. Product decision: a wallet is business-wide.
  Analyzer clean. See BUILD_LOG 2026-06-17.
- Investigation: the accompanying `order_items`/`wallet_transactions` 23503 FK
  violations were transient on the v1 per-table push path (parent `orders`
  chunk times out → loop cascades into child pushes that FK-fail → retry +
  orphan auto-recovery self-heal). Cloud verified: no data lost.

### Push cascade guard — abort cycle on degraded link (2026-06-17)
- Fixed the FK-violation storm at the source: `pushPending` now stops the push
  cycle when a group hits a timeout / transient network error (parents likely
  didn't land) instead of cascading into child groups that are guaranteed to
  23503. Per-row FK-deferred / permanent errors keep their own backoff. Domain
  envelopes + the 200-row re-drain are also skipped while degraded. Analyzer
  clean; 119/119 sync tests pass. See BUILD_LOG 2026-06-17.

### Sync retry hardening — backoff cap + auto orphan recovery (2026-06-17)
- §6.8: capped the transient-retry backoff ceiling in `SyncDao.markFailed`
  (5 min normal / 15 min FK-deferred) so a many-times-failed row can no longer
  drift ~4 h into the future and stay stuck on a continuously-online device.
- §6.8.1: automatic orphan recovery. A periodic (30 s drain tick) +
  connectivity-recovery sweep (`autoRecoverDueOrphans`) re-enqueues orphans whose
  cause now self-heals — `fk_deferred_cap_reached*` (parent may have landed) and
  `*created_at is immutable*` (ledger scrub at push, S134). New device-local
  `auto_retry_count` on `sync_queue` + `sync_queue_orphans` (Drift v52) survives
  re-orphaning so the per-orphan cap (3) holds; then the row is parked for manual
  review. Terminal reasons (dup order number, RLS, bad-parameter) stay
  manual-only. Conservative allowlist chosen by product decision. Manual
  `retryOrphan` resets the counter. 4 new tests; full suite + migration test
  green. Local-only schema change — no cloud migration. See BUILD_LOG 2026-06-17.

### Realtime resubscribe on resume / reconnect (2026-06-17)
- Fixed: live (realtime) sync silently dying on a physical device after the app
  is backgrounded or the network switches — `startRealtimeSync` only ran once at
  sign-in and never re-subscribed dead channels. Added
  `SupabaseSyncService.restartRealtimeSync`, called on app-resume
  (`auto_lock_wrapper`) and connectivity recovery. Analyzer clean; awaiting
  on-device confirmation. See BUILD_LOG 2026-06-17.

### Foundation
- Database schema rebuild — Drift schema v13 (Session 2). Now at **v51** after
  142 sessions of incremental migrations.
- Role + permission seeding for new businesses (Session 2). 30 permission keys,
  4 default roles (CEO / Manager / Cashier / Stock keeper) seeded on business
  creation.
- Cloud migrations deployed through **0114** (deleted_businesses tombstone).

### Auth flow
- Welcome screen §4 (Session 6).
- CEO sign-up flow §5 — new-email path (Session 7). Existing-email /
  multi-business branch deferred to Phase 2.
- Staff sign-up via invite code §6 (Session 10).
  - Session 149: 9-step flow with phone (step 4) and address (step 5)
    matching CEO store-details. `AutocompleteField` extracted to
    `auth_form_kit.dart` (shared). Drift schema v51 adds `phone`/`address`
    to `users`; SQL migration 0116 adds cloud columns + recreates
    `redeem_invite_code` with `p_phone`/`p_address`. Sync whitelist updated.
- Login + Forgot PIN §7.1–7.4 (Session 8). Multi-business confirm-PIN
  deferred to Phase 2.
- Who Is Working picker §8.1–8.5 (Session 11). "Active now" dot deferred.

### Core screens
- Staff Management §9 (Session 10).
- CEO Settings §10.1 menu + Business Info / Stores / Security / Activity Logs
  access (Session 14). Roles & Permissions §10.2 (Session 15). Appearance
  (Session 17). §10.3 Phase 2.
- Delete Business & Account §10.3 — staff wipe on owner delete, tombstone,
  three-angle trigger (online / app-open / reconnect) (Session 140).
- Home / Dashboard §11 — role-aware cards, subtitle, store lock, Total SKUs.
- Point of Sale §12 — role guards (Session 19). On-device verified 2026-05-30.
- Cart + Edit Quantity modal §13 — discount + role caps, fractional toggle,
  per-cashier saved carts, Undo (Session 20). On-device verified 2026-05-30.
- Checkout §14 — two-step payment + receiving account (Session 26), wallet-info
  checkbox (Session 30). §14 complete.
- Daily Stock Count §17 — count persistence, shortages snapshot, Record Damages
  form, store-name header, CEO/Manager notifications, Cashier blocked (Session 58).
  Ring 3 Daily Reconciliation integration still open (see In Progress).
- Supplier Accounts §21 — DB-backed per-supplier ledger, Invoice Total /
  Payment via "Record Activity", absorbs former Track Shipments (Session 110).
  Per-store ledger entries §21.11 (Session 127).
- Expenses — per-store scope gating via active-store picker §20.8 (Session 133).
- Daily Reconciliation §25.9 — store-scoped, Day/Week/Month/Year grouping,
  CEO P&L + statement of account, Manager retail shrinkage, drill-down
  (Session 135).
- Business Reports hub §25.1–25.3 — removed Sales Report / Expense Tracker /
  Customer Ledger cards, redesigned period filter to chip row (Session 136).

### Infrastructure / cross-cutting
- Rename pass: Warehouse → Store (Session 3), Dashboard → Home (with §11).
- Realtime two-device sync confirmed on-device (Session 27).
- Per-table push error classification — FK-deferred vs permanent vs transient,
  §6.8 parity (Session 128).
- Legacy order-number collision self-heal — pull-side and push-side (Session 129).
- Voided ledger row `created_at` scrub — never send `created_at` on void
  re-pushes for append-only ledgers (Session 134).
- Sync push chunking — adaptive chunk sizing (Wi-Fi 25 rows, cellular 10,
  floor 5), 15s timeout per chunk, halve on timeout / double after 3 clean
  chunks, skip on no-network (Session 141).
- Pull-side pagination (Session 143): `_fetchOneTable` now fetches in pages
  ordered by `last_updated_at` + `id` asc; page size is connectivity-driven
  (Wi-Fi 500 / cellular 100 / poor 50, floor 10). On cellular/poor the
  monolithic `pos_pull_snapshot` RPC is bypassed entirely; `_pullViaPostgRest`
  fetches tables sequentially (in `_pullOrder` FK-safe order) instead of
  parallel `Future.wait`. Adaptive timeout: a page-level TimeoutException
  halves the page size and retries the same offset; propagates when already
  at the floor. `syncMinimumLogin` also passes connectivity-based page size.
  LWW guard, hard-delete reconciliation, and the deferred-table cursor logic
  are all preserved. `flutter analyze` clean; 115/115 sync tests pass.
- Theme colour system — 5 palettes × light/dark; POS filter chips,
  cart/checkout totals, notifications, activity logs now theme-aware
  (Session 140).
- App icon — Reebaplus logo as launcher icon across all platforms (Session 137).
- iOS build enabled — runs on Simulator and physical iPhone (Session 138).
- Funds Register §23 — **removed entirely** at user request (Session 96).
  §23 is a tombstone. Hard Rule #8. No reintroduction.
- Track Shipments §22 — **removed entirely**, folded into Supplier Accounts
  (Session 110). §22 is a tombstone.
- Onboarding + registration form alignment (Session 144): all 7 business types
  now rendered in CEO sign-up picker (Restaurant/Supermarket/Bar/Pharmacy/
  Building Materials/Boutique greyed-out with "Coming soon" badge; only Beverage
  distributor selectable). Store Details step now collects Store Phone Number
  (digits-only, min 8 digits) and LGA/District (searchable autocomplete,
  populated from kNigerianLgas[state] when country is Nigeria; resets when state
  changes via ValueKey). `OnboardingDraft.lgaDistrict` added; `locationCombined`
  now emits Street → LGA → State → Country. `_submitBusinessType` maps
  'Beverage distributor' → 'Beer distributor' before writing to draft (DB
  canonical preserved). `BusinessInfoScreen._load` maps 'Beer distributor' →
  'Beverage distributor' for dropdown; `_save` maps back. New file:
  `lib/core/data/nigerian_lgas.dart` (36 states + FCT with full LGA lists).
  `kBusinessTypes` updated to 7 entries using 'Beverage distributor' display
  label; `isCrateBusiness` now accepts all three spellings. `flutter analyze`
  clean; 22/22 auth tests pass.
- Codebase cleanup — deleted 7 dead/unused files (CustomerLedgerScreen, ApprovalsScreen, WelcomeVerificationModal, sync_service.dart stub, guarded.dart helper, products_data.dart, filter_bar.dart) and resolved compile error in supabase_sync_service.dart (Session 142).
- Removed dead `last_notification_sent_at` schema + backend remnants (Session 142):
  the "Waiting for Assignment" screen, its main.dart routing guard, and the
  `_handleOnboardingAlerts` escalation system were deleted in a prior session;
  this drops the leftover column. Drift schema **v48 → v49** — `users` column
  removed from the table class, raw `ALTER TABLE users DROP COLUMN
  last_notification_sent_at` onUpgrade step (try/catch idempotent, NOT
  TableMigration — same decoupling rationale as the v12 users rebuild), pull
  restore + push whitelist refs stripped from `supabase_sync_service.dart`,
  Drift code regenerated. Cloud migration
  `0115_drop_last_notification_sent_at.sql` written (NOT yet pushed). `storeId`
  untouched (still used for store-locking). `flutter analyze lib` clean;
  migration/sync/auth/database suites pass.
- Fixed orphaned-tenant re-registration bug (§10.3 follow-up, Session 142):
  re-registering with the same email after "Delete Business & Account" left a
  stale local `users` row (old `businessId`) when the device's wipe never
  ran/completed. `resolvePostVerifyRoute` was routing this case to
  `LoginRoute` with the dead `businessId`, causing `tenant_mismatch` on pull
  and RLS `42501` on push (stale `sync_queue` rows). Now: when the cloud
  confirms no business for the auth identity (`fetchSupabaseAccount() ==
  null`) and a confirmed `deleted_businesses` tombstone matches the stale
  row's `businessId`, `AuthService.wipeOrphanedLocalBusiness` (new —
  `SupabaseSyncService.confirmBusinessDeleted`, a public wrapper of
  `_confirmBusinessDeleted`) wipes the device via `clearAllData()` and the
  email is routed as brand-new (`NoAccountFoundRoute`). Ambiguous results (no
  tombstone / offline) preserve the existing offline PIN-login path —
  never a false-positive wipe. New test:
  `test/auth/post_verify_route_orphan_business_test.dart`.
- Fixed ListTile debug assertion crashes in tests and UI (Session 145): SwitchListTile widgets wrapped inside decorated containers (such as AppDecorations.glassCard) triggered a debug assertion failure on newer Flutter versions ("ListTile background color or ink splashes may be invisible"). Wrapped the inner columns/list-tiles in transparent Material widgets: in `_permissionGroupCard` and `_viewAllStoresCard` in `role_permissions_detail_screen.dart`, and `_permissionGroupCard` in `staff_permissions_screen.dart`. Ran `dart format lib/` to clean formatting, verified `flutter analyze lib` is 100% clean, and ran the entire test suite ensuring 429/429 tests pass.
- New-store stock-figure leak fixed (2026-06-17): a newly created store showed
  another store's "Total Units" / "Products" on the Stores list while its detail
  screen was correctly empty. Cause: `_StoreCard` in `stores_screen.dart` was a
  keyless `ListView.builder` child that subscribed to its store's inventory
  stream only in `initState`; stores order by name, so inserting one shifts
  positions and Flutter recycled the position-matched state, which kept
  streaming the previous store's inventory. Fix: `ValueKey(store.id)` on each
  card + `didUpdateWidget`/`_subscribeInventory()` re-targeting. A new store now
  starts at 0 until inventory is assigned. `flutter analyze` clean.
- Declarative back interception + tab history traversal (Session 146): Migrated `MainLayout` from `WidgetsBindingObserver.didPopRoute` to `PopScope(canPop: false, onPopInvokedWithResult: ...)` — the modern Flutter back-interception API. Removed `WidgetsBindingObserver` mixin, `addObserver`/`removeObserver` calls, and the `didPopRoute` override. Updated `NavigationService.handleBackPress` Step 3: tries `popIndex()` first (returns the user to the previous tab in history), then falls back to navigating to the home tab (Step 3.5). Both files analyze clean.
- Owner role protection (Session 148): Drift schema **v49 → v50** — added
  `ownerId` (nullable TEXT) column to `Businesses` table, mirroring the cloud's
  existing `owner_id` column. Raw `ALTER TABLE businesses ADD COLUMN owner_id
  TEXT` onUpgrade step (try/catch idempotent). `createNewOwner` and
  `completeOnboarding` in `auth_service.dart` now write `ownerId` explicitly in
  the local mirror inserts. `staff_detail_screen.dart`: computes `isTargetOwner`
  (`user.authUserId == business.ownerId`) after the membership null-guard; the
  "Change role" button is hidden (render-gate + outer section guard updated) when
  the target is the owner; `_changeRole` has a defense-in-depth re-check that
  returns early with an error notification ("You cannot change the owner's role.")
  if the gate is somehow bypassed. `currentBusinessProvider` (already in tree)
  supplies the live `ownerId`. `build_runner` regenerated; `flutter analyze`
  clean (no errors).
- Debug-mode audit + Stock Count review sheet (Session 147): Audited all `kDebugMode` and `assert` gates across the codebase. Found two intentional `kDebugMode` uses: `logger.dart` (debug logging only) and `sync_issues_screen.dart:1124` (service-role-key + project-URL fields hidden in release — developer tool, correct by design). Two `assert`-only constructor guards in `create_pin_screen.dart` and `pin_keypad.dart` are silently bypassed in release mode (noted, not changed — valid Flutter pattern). `build.gradle.kts` release build uses debug signing key (TODO comment present; no functional divergence for biometric/secure-storage since both modes share the same keystore). Replaced the simple `AlertDialog` in `StockCountScreen._confirmAndSave()` with a `DraggableScrollableSheet` review panel: summary chips (counted / adjusted / short / over), full itemised list of every product with a diff (product name, system → actual, coloured diff badge), "all matched" empty state with a green check icon, and "Back" + "Confirm & Save Count" action buttons. `flutter analyze` clean — 18 pre-existing `avoid_print` infos in test file only.

---

## In Progress

- **Receipt §15** — QR code removed, wallet-info display wired (Session 30).
  Still open: refund button, Completed-tab specifics.
- **Customers + Customer Profile §18** — soft-delete, Crates-tab gate, required
  phone, `customers.set_debt_limit` permission (Session 31). Still open: Edit
  flow, GPS capture, Add-Funds payment method.
- **Daily Stock Count §17** — Ring 3 Daily Reconciliation data wiring still
  pending. On-device pass also pending.
- **Supplier Accounts §21** — full feature built: ledger, store scope §21.11,
  §4 confirmation gate, §10 CEO void, §14 reconciliation, §15 accounts report,
  §16 payment notifications, §3.13 crates placeholder. On-device verification
  against the 130-check list still pending.
- **Theme consistency** — only four areas swept in Session 140. Other screens
  may carry hardcoded `blueMain` / `blueLight` / raw `Colors.*` values.

---

## Next Up

1. On-device verify Session 143 pull pagination under a throttled / flaky /
   cellular connection.
2. Decide: app-wide colour sweep vs next feature unit.
3. **Inventory + Product Details §16** — not started.
4. **Orders §19** — Phase 1 completed (local keyset pagination for Completed/Cancelled tabs). Remaining phases (remote sync queries and remote fallback) pending.
5. **Expenses + Pending Approval flow §20** — store-scope wired (Session 133);
   full §20 feature pass not started.
6. **Activity Logs §24** — not started.
7. **Notifications §26** — not started.
8. **Sidebar + Bottom Nav final pass §27** — not started.
9. **Cross-cutting cleanup** — role-based guards wired everywhere; loading
   animations replaced with fade-ins; all UUIDs replaced with short codes in
   user-facing text; Cash Register → Funds Register label cleanup (§23 removed,
   label pass only).

---

## Open Questions

- **Orders & Activity History Remote Fallback / Windowed Sync Bypass (Phase 3).** When local database keyset pagination on Completed/Cancelled tabs (Orders) or the Activity Logs screen reaches the end of locally stored Drift records, should the pagination notifier trigger an on-demand remote fetch from Supabase to retrieve older historical entries, or is history strictly limited to the locally synced dataset?

- **Empty crates — walk-in crate semantics (§3.14–3.16).** The checklist says a
  walk-in sale should still adjust empty-crate inventory automatically and that
  walk-ins must return crates equal to receipt at the same time (no deferred
  balance). Current `createOrder` gates the entire crate block on
  `customerId != null`, so walk-ins accrue no crate rows at all. Define the
  intended walk-in crate-inventory behaviour before implementing — do NOT invent.

- **Empty crates — §5/§9/§10/§11/§13 on-device verification pending.** The
  pending-order Crate Return modal, refund flow (`crate_refund`), order
  cancellation reversal, reconciliation crate section, and role-access gating
  are all built; they need on-device (emulator) confirmation against the
  checklist rather than further code changes.

- **Supplier empty crates §3.13 — cloud push + on-device verification pending.**
  The full feature is built and unit-tested (2026-06-19). Outstanding: (1) push
  `0117_supplier_crate_tracking.sql` BEFORE distributing a v53 build; (2) on-device
  confirm receipt/return nets the per-supplier balance, the deposit value tracks,
  and Receive Delivery increments the supplier crate debt; (3) confirm the
  computed-deposit model (balance × manufacturer rate) matches the operator's
  expectation vs. tracking literal deposit cash — revisit if they want the entered
  `deposit_paid_kobo` surfaced as the headline instead.

- **Receipt §15 refund button** — deferred multiple times. Confirm the exact
  UX (who triggers it, from which screen, what it writes to the ledger) before
  picking up §15.

- **Customers §18 GPS capture** — deferred from Session 31. Confirm: still in
  Phase 1 scope or moved to Phase 2, before implementing the Edit flow.

- **`onPrimary` in dark colour schemes** — only the Black & White palette sets
  it explicitly. Dark-mode coloured themes may show black chip text on a medium
  primary. Confirm whether an explicit `onPrimary` pass across all
  `ColorScheme.dark(...)` blocks in `app_theme.dart` is wanted.

- **`CustomerLedgerScreen` dead code** — deleted (Session 142).

- **Free Apple ID provisioning** — real-device cert expires after 7 days.
  Re-run `flutter run` to refresh. Confirm before any iOS release testing.

- **Cloud migrations 0042–0044 row-count verification** — written in Session 2,
  deployed in Session 4. The verification queries in each migration file should
  be run against a real Supabase instance. Status unknown — confirm if done.

---

## Architecture Decisions

Locked decisions. Do not revisit without updating `architecture.md` and logging
the reason here.

- **One email, one business (Phase 1).** Database supports multi-membership from
  day one; the switch-business picker UI is Phase 2. (Session 1 / §1.1.)

- **Funds Register removed entirely (2026-06-04).** §23 is a tombstone. No cash
  account, no Open Day / Close Day, no per-store money accounts. Money tracked
  as recorded sales, expenses, refunds, and supplier payments. Hard Rule #8.
  (Session 96.)

- **Track Shipments folded into Supplier Accounts (2026-06-06).** §22 is a
  tombstone. Supplier Accounts absorbs shipment tracking via "Record Activity"
  ledger. (Session 110.)

- **Append-only ledgers.** The five append-only tables are `payment_transactions`,
  `wallet_transactions`, `supplier_ledger_entries`, `crate_ledger`, and
  `stock_transactions`. The cloud enforces this with append-only triggers.
  Voids are new rows; `created_at` is never sent on void re-pushes.
  (Session 134 / §5 sync contract.)

- **Role identity uses the slug, never the name.** The `roles` table has a
  `slug` column (`ceo`, `manager`, `cashier`, `stock_keeper`). All code that
  branches on role identity uses the slug. `name` is display-only. (Session 1.)

- **`products.add` removed from Stock keeper defaults.** Only CEO and Manager
  can add new products. Stock keepers adjust quantities on existing products
  only. (Session 1 / §16.7.)

- **Default `role_settings.max_expense_approval_kobo` for Manager set to 0.**
  CEO must set this explicitly before a Manager can approve expenses without
  escalation. Safer opening default for fresh businesses. (Session 1.)

- **Three product prices only: Buying, Retailer, Wholesaler.** Four legacy price
  columns dropped in the pivot. (Session 1 / §16.5.)

- **Barcode scanning scoped to Pharmacy and Supermarket only.** Hidden for all
  other business types. `barcode_widget` package stays in pubspec.yaml.
  (Session 1 / §16.11.)

- **Per-store scoping pattern.** Expenses (§20.8), Supplier Accounts (§21.11),
  and Daily Reconciliation (§25.9) all follow the §12.1 active-store picker.
  Concrete store → that store's data; All Stores (CEO / all-stores Manager) →
  aggregate. Recording stamps: `lockedStoreId ?? first-selectable`. (Sessions
  127, 133, 135.)

- **Sales Report, Expense Tracker, Customer Ledger removed from Reports hub.**
  Data lives on individual screens. Hub cards are tombstones. (Session 136 /
  §25.2.)

- **§25.10 merged into Daily Reconciliation §25.9.** One store-scoped report,
  groupable by Day/Week/Month/Year with drill-down. Cash tracking rejected by
  user. §25.10 is a tombstone. (Session 135.)

- **Cashier `reports.see_sales` scope is query-layer only.** The permission
  grants access; "own sales only" is enforced at the query, not the permission.
  Home (§11) and Reports (§25) must both apply this scope filter. (Session 1.)

- **Sync push chunking.** Wi-Fi/ethernet ceiling: 25 rows. Cellular ceiling: 10
  rows. Floor: 5 rows. Timeout: 15s per chunk. Adaptive: halve on timeout,
  double after 3 consecutive clean chunks. Skip if `Connectivity` returns `none`.
  (Session 141.)

- **`deleted_businesses` tombstone (cloud-only).** No FK to `businesses`;
  survives cascade. RLS: any signed-in device may read it; writes are owner-only
  via `delete_business` RPC. Staff devices wipe via three triggers: realtime,
  on next app open, on reconnect. Migration 0114. (Session 140.)

---

## Invite email + Reebaplus-branded auth email (in progress)

Goal: all OTP/auth email comes from the Reebaplus domain, and creating a staff
invite auto-emails the code (Copy / SMS / WhatsApp share unchanged).

**Code landed (not yet deployed):**
- Edge Function `supabase/functions/send-invite-email/index.ts` — branded
  invite email via Resend; invoked server-side by a DB trigger, gated by the
  `x-invite-hook-secret` shared secret; stamps `invite_email_sent_at`.
- Migration `0126_invite_email_trigger.sql` — enables `pg_net`, adds cloud-only
  `invite_codes.invite_email_sent_at`, AFTER INSERT trigger calling the function
  via `net.http_post`. Function URL + hook secret read from Vault (not in repo).
- `invite_staff_screen.dart` success copy now says the code was emailed.

**Pending — operator / dashboard (gates go-live):**
1. Resend domain `reebaplus.com` — **verified** (2026-06-23).
2. OTP track: configure Supabase Auth **Custom SMTP** → Resend, sender
   `no-reply@reebaplus.com` / "Reebaplus"; brand the OTP template. (Makes all
   auth email come from Reebaplus — no code.)
3. Invite track, before deploy:
   - `supabase secrets set RESEND_API_KEY=<full key>`
   - `supabase secrets set INVITE_EMAIL_HOOK_SECRET=<random>`
   - Vault: `select vault.create_secret('https://<ref>.supabase.co','project_url');`
     and `select vault.create_secret('<same random>','invite_email_hook_secret');`
   - Deploy function: `supabase functions deploy send-invite-email --no-verify-jwt`
     (the shared secret is the gate; no user JWT on the trigger path).
   - Then `supabase db push` (function before trigger).

**Verify:** generate a code on-device → row syncs → invitee gets branded email
with correct code → Copy/SMS/WhatsApp still work → re-sync does NOT re-send.

---

## Multi-Device Sessions (2026-06-23)

- **Disabled single-active-session kick.** Enabled multi-device sign-ins by disabling the single active session restriction.
- **Renamed `_kickOtherDevices` to `_registerCloudSession`.** Changed the logic to only register the current device's session on the cloud (`sessions` table upsert) and removed the code revoking other sessions (`revoked_at`) or calling `signOut(scope: SignOutScope.others)`.
- **Added Automated Test.** Verified that multiple concurrent active sessions can coexist for the same user across different devices in `session_created_at_push_test.dart`.

---

## Categories no longer preloaded + cloud test wipe (2026-06-24)

- **Removed default product-category seeding.** Deleted the `if (cats.isEmpty)`
  seed block in `add_product_screen.dart` `_loadData` (was inserting `Alcoholic`,
  `Non-Alcoholic`, `Energy Drinks`, `Wines`, `Spirits` on a fresh business).
  Categories are now created on the fly through the searchable category dropdown
  (`_createNewCategory` / `_getOrCreateCategory`), which already existed.
- **Cloud reset.** Wiped all business/test data on project
  `ewwyofbvfjyqqirrcaou` (`TRUNCATE … CASCADE` every tenant table +
  `DELETE FROM auth.users`) so previously-used test emails can re-onboard.
  Preserved the global `permissions` catalogue and schema/migrations/RPCs.

---

## Checkout payment-label + wallet-display fixes (2026-06-26)

- **Wallet sale mislabeled "Credit Sale" on the receipt (root cause).** The
  receipt/print read `_paymentLabel` live; clearing the cart on success resets
  `_mode` (via `_onCustomerChanged`) so a wallet sale recomputed as a credit
  sale. Now captured into `_receiptPaymentLabel` at confirm and read from there;
  `_onCustomerChanged` no-ops after confirm.
- **`_paymentLabel` rewritten:** wallet→"Wallet Payment", credit→always "Credit
  Sale", registered partial cash→"Cash / Transfer / Wallet"; dropped the
  `paid ≤ 0 → Credit Sale` fallback.
- **Mode validation moved before the async staleness check** (instant
  empty-amount feedback); messages clarified.
- **Auto-switch to Wallet** when Cash/Transfer is chosen with an empty amount and
  wallet credit covers the bill.
- **Removed `(credit)/(debt)` suffixes** from the checkout customer card, payment
  previews, and both receipt builders (sign + colour already differentiate).
- Debt-limit gate on partials and walk-in-only Cash/Transfer verified unchanged.
- `flutter analyze` clean on the touched files.

---

## Sync Data-Safety & Efficiency — Invariant #12 "the outbox is sacred" (2026-06-30)

Spec: `context/specs/brief-sync-data-safety-and-efficiency.md`. Branch
`feat/sync-data-safety-and-efficiency`. Added **Invariant #12** to
`architecture.md`. Full detail in `BUILD_LOG.md` (2026-06-30 entry).

**Shipped — Bucket 1 (data safety):**
- Enforcement primitive `SyncDao.pendingRowIds(table, {businessId})` +
  `countOrphans` + `unsyncedExportRows` / `discardUnsyncedForBusiness`.
- (C) clobber prevention in `_restoreTableData`; (B) reconcile exclusion +
  completeness guard in `_reconcileHardDeletes`; (E) hardened wipe gate in
  `AuthService.logOutCurrentUser` + `LogoutBlockedByUnsyncedDataException` +
  `ResolveUnsyncedDataDialog` + `_recordWipeLoss` breadcrumb at the three
  business-deleted carve-outs; (D) `SupabaseSyncService.pushThenPull` on
  reconnect/refresh/login; (F) `_auditDrainIntegrity` self-count breadcrumb.

**Shipped — Bucket 2 (efficiency):**
- (A1) per-table backfill cursors (`backfill_tables::<id>` pref) so a deferred
  leaf table no longer forces a re-pull of every table; FK-orphans keep the
  conservative full re-pull.
- (A2) `_targetedParentFetchAndRetry` — bounded inline fetch of missing
  supplier/category/manufacturer parents by id + child retry.

**Open follow-ups (logged, not blocking):**
- Proactive "sync blocked — this device's access changed" banner + elevating the
  Sync Issues screen from operator-only to user-visible (brief §3.1 last bullet)
  — the never-trap-logout export/discard flow is shipped; the always-on banner is
  deferred. The wipe-loss breadcrumbs land in SharedPreferences
  (`wipe_data_loss_breadcrumbs`) with no surfacing UI yet.
- `last_updated_at`-bump DAO audit (brief §3.3 "hygiene") — correctness no longer
  depends on it (clobber prevention covers it), so deferred as cleanup.

---

## Session Notes

**2026-07-19 — #150: a Sync Issues entry point for oversell recovery (client
fallback).** Pairs with #149 (which stops the *cloud* phantom); this is the
*client* fallback route. `OrderService.cancelRejectedSale` (full local undo of a
server-rejected v2 sale) was reachable from **one** place — the tappable
`sale_rejected` notification — so a swipe-dismiss stranded the phantom with no
recovery affordance. Added a **second entry point**: a "Cancel this sale" action
on the Sync Issues orphan tile for a `domain:pos_record_sale_v2` row →
`OrderCommands.cancelRejectedSaleFromOrphan({orderId, orphanId, staffId})`, which
runs the **same** reversal (`cancelRejectedSale`, sourcing `p_items` from the
orphan via `SyncDao.rejectedSalePayload`) and **then** `discardOrphan`. **Critical
ordering — reverse BEFORE clear** (the reversal reads the orphan payload, so
discard-first would refund nothing); idempotent. UI: the tile computes
`_rejectedSaleOrderId(item)` (gated on the action type + `p_order_id`) and renders
a `TextButton` → a plain-language confirm dialog mirroring the notification copy →
snackbar; the orphan action row became a `Wrap` so a third button can't overflow;
all `ref` reads precede any `await`. Retry/Discard kept. No schema/migration
(reversal is local-only). Invariants untouched (#12 orphan stays visible until the
deliberate confirmed Cancel; #3 wallet reversed by compensating rows; #1/#4 no
direct cloud read/write). The *"and/or"* order-detail entry point was left out
(explicit alternative to the *preferred* route). TDD:
`test/orders/cancel_rejected_sale_from_orphan_test.dart` (reverse-AND-clear;
reverse-BEFORE-clear proven by inventory 5≠3; idempotent; orphan-gone still cancels
the header). `flutter analyze` clean; `test/orders/`+`test/sync/` 254 green; full
suite green except the pre-existing `who_is_working_screen_test` failure (verified
failing on clean `origin/main`). Branch `feat/sync-issues-cancel-rejected-sale`;
full detail in `BUILD_LOG.md` (2026-07-19).

**2026-07-19 — #149: rejected v2 oversell no longer leaks a phantom `completed`
cloud order.** Hardens Invariant #12 on the order *header*. On the guarded path
(`feature.domain_rpcs_v2.record_sale`), the Confirm-time header push
(`OrdersDao.markCompleted → _enqueueFullOrder`) was a plain LWW `orders` upsert
uncovered by #121's `held_by_order_id`, so a rejected (oversold) sale still left a
cloud order `status='completed'` with zero children (`reverseRejectedSaleLocal` is
local-only, so the cashier's Cancel never reconciled it). Fix: every order-header
push routes through the now envelope-aware `_enqueueFullOrder`, which classifies
the sale via new `SyncDao.saleEnvelopeState` → `{pending, confirmed, rejected}` and
**skips** (rejected) / **holds by order** (pending — reuses #121's release/discard/
`reconcileHeldRows`) / **pushes immediately** (confirmed, incl. v1 with no
envelope). `assignRider` + `renumberForCollisionHeal` inherit the guard, so
`_enqueueFullOrder` is the sole header-push site. Chose Option 1 (hold the header),
not Option 2 — the RPC inserts `ON CONFLICT (id) DO NOTHING` and never updates, so
dropping the push would strand the cloud at `pending`. No schema change. Tests:
`test/sync/rejected_sale_header_hold_test.dart` (12). Branch
`fix/rejected-v2-phantom-cloud-order`; full detail in `BUILD_LOG.md` (2026-07-19).
Follow-up: preventive only — phantoms already in the cloud need a one-off cleanup;
pairs with **#150** (Sync-Issues entry point to the recovery).

**2026-07-03 — Settings & sidebar migrated to named gates (issue #21, epic #16).**
The Settings/nav batch: all 11 `lib/core/settings/` screens, `app_drawer.dart`,
`main_layout.dart`, and the Sync Issues screen guard now cite named registry
gates — no bare `hasPermission` or raw permission-set reads remain in them.
Registry additions (Settings & sidebar/nav cluster): `viewSyncIssues`
(`sync.view` OR CEO — the ONE entry cited by the screen body-guard, the sidebar
item, and the drawer header sync badge/banner pill; the standalone
`canViewSyncIssues` helper in `stream_providers.dart` is RETIRED),
`manageSettings` (`settings.manage` — drawer entry + every settings sub-screen
body-guard and write re-check), `deleteBusiness` (`settings.delete_business` —
Danger Zone entry compound lifted verbatim + delete screen), and render-only
nav gates `viewCustomers`, `manageStaff`, `viewActivityLogs`, `viewStores`
(the four-way stores/transfer any-of). Nav entries whose destination gates
already existed cite those: POS/Cart tabs + drawer → `makeSale`, Stock tab +
drawer → `viewInventory`, Supplier Accounts → `manageSuppliers`, Expenses →
`viewExpenses`; CEO Settings > Stores body-guards on `manageStores`
(`stores.manage`, verbatim). Fire-time write re-checks moved to
`.allowsNow` + the standard `showGateDenied` feedback. Roles & Permissions
editor behaviour (write-time dependency cascade) untouched. Static-ban
allowlist shrank by exactly these 13 files (4 files remain: orders, staff ×2,
activity_log_screen). `flutter analyze` clean; `test/permissions` 45/45; full
suite green except the pre-existing `who_is_working_screen_test` failure
(verified again: fails identically at HEAD in a clean worktree).

**2026-07-02 — Cloud-transport seam SHIPPED (commit 3ec07cb).**
Extracted a `CloudTransport` interface (11 members: `upsertRows`/`deleteRowsById`/
`callRpc`/`fetchTable`/`fetchRowsByIds`/`warmUp`/`businessDeletedTombstoneExists`/
`startRealtime`/`stopRealtime`/`currentAuthUserId`+`authEvents`) out of
`SupabaseSyncService`, with `SupabaseCloudTransport` (real, `lib/core/services/`)
and a fully-featured `InMemoryCloudTransport` (test fake, `test/helpers/`). Design
recorded in [`docs/adr/0001-cloud-transport-seam.md`](../docs/adr/0001-cloud-transport-seam.md)
+ root `CONTEXT.md` (Sync glossary). **Pure behaviour-preserving extraction** — the
engine now holds zero injected-`_supabase` refs on its sync-I/O paths; `pushPending`/
`pullChanges` are testable against the fake, unblocking the sync data-safety brief's
A–F vectors. Settled: seam throws `PostgrestException`/`TimeoutException` verbatim,
leaks `PostgresChangePayload`, neutralizes auth to `TransportAuthEvent`; push
chunk-loop stays engine-side, pull page-loop moved into the adapter; users-supplement
now paginates (accepted delta, see ADR). `flutter analyze` clean; 170 sync + 8 new
characterization tests pass; full suite 613 pass / 1 pre-existing unrelated fail
(`who_is_working_screen_test`, fails identically at HEAD). Two-axis `/code-review`
clean. NEXT: the brief's Bucket 1 (A–F) data-safety fixes, built on this seam.

**To resume in a new session:**
Read this file first, then `CLAUDE.md`, then the master plan section relevant
to the unit being picked up.

**Repository state:**
- Drift client schema: **v54** (v54 = `sales.set_custom_price` permission seed;
  v53 = §3.13 supplier_crate_ledger + supplier_crate_balances).
- Cloud migrations deployed through: **0118** (0117 supplier crate tracking +
  0118 `sales.set_custom_price` pushed 2026-06-19; verified: catalogue row
  present, granted to all CEO roles, 0 non-CEO grants).
- **2026-07-01 — `0129_devices` deployed (device registry for console analytics).**
  Cloud-only `public.devices` table (make/model/os/app_version/is_physical_device/
  last-seen per `(business_id, device_id)`), written by a direct authenticated
  `supabase.upsert` from `DeviceRegistryService` on sign-in / app-open / reconnect
  (no offline sync-queue wiring; no in-app screen). Deps `device_info_plus` +
  `package_info_plus` added. Applied via the Management API (see divergence note).
  ⚠️ **Migration-history divergence:** remote applied 0125/0126/0128 under
  timestamp versions + a remote-only `enable_pg_cron`; **0127 appears un-deployed**.
  A blind `supabase db push` would fail on 0126's `CREATE TRIGGER`. Reconcile with
  `migration repair` + deploy 0127 as follow-up.
- `flutter test test/sync/` — **115 pass** (Session 141 baseline).
- Full suite last confirmed: 452 pass / 58 skipped / 1 pre-existing unrelated
  failure (`invite_staff_sheet_test`) (2026-06-19).
- `flutter analyze lib` — clean. 18 pre-existing `avoid_print` infos in
  `test/database/roles_v13_report.dart` only; not regressions.
- iOS build enabled; free Apple ID cert expires after 7 days — re-run
  `flutter run` to refresh.

**Three things to check before every unit:**
1. `flutter analyze` clean before and after.
2. No raw Supabase call from `lib/features/` or `lib/data/repositories/`.
3. No UPDATE or DELETE on an append-only ledger table — corrections are
   new rows only.
