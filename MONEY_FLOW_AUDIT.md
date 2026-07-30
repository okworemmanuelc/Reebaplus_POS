# Follow-the-Money Audit — 2026-07-21

**Method.** Five parallel deep audits (daily reconciliation, product/inventory value lifecycle, POS transactional flow, party ledgers, van-sales plan #139–#147 traced as a money trail), synthesized and de-duplicated, with every headline claim re-verified by hand against the current code this session. Builds on — and does not repeat — `CRATE_TRACKING_AUDIT.md` (same date); crate findings are cited as **[CA §…]**. Flags: **V** = verified by reading the full code path; **S** = suspected/latent. All money in integer kobo.

---

## 1. Executive summary

The app's *ledgers* are genuinely well built: the customer wallet is true double-entry inside the sale transaction, the supplier ledger auto-posts from Receive Stock in the same transaction, both are append-only with derived balances, and FIFO batch costing (ADR 0005) is a sound design with a server-authoritative healing pass. **The money is lost at the seams** — in five recurring ways:

1. **Corrections mutate history instead of compensating.** Cancelling a sale voids its payment rows *in place* and retroactively rewrites the original day's cash figures; the cash that physically leaves the drawer on refund day is recorded **nowhere**, and the recon's "Refunds" line reads from a status (`refunded`) that no code ever writes — it is structurally ₦0 forever. Rejected/deleted expenses and voided debt-collections keep counting as cash movements forever because their payment rows are never voided.
2. **The FIFO cost queue only sees two of the ~eight quantity writers.** Sales and the two blessed inflows touch batches; adjustments, damages, stock counts, transfers, the existing-product Add path, and cancel-restocks all move quantity with no cost-layer change — so COGS drifts toward 0-cost sales or phantom coverage in normal operation, and per-store margin is structurally wrong for multi-store businesses (transfers never move cost).
3. **The cash summary cannot tie to the drawer by construction.** Every POS tender — cash *or* bank transfer — is recorded `method: 'cash'`; refundable crate deposits ride inside "Cash sales"; the card is business-wide (`payment_transactions` has no store column); and supplier cash keys on a user-editable backdate while everything else keys on `created_at`.
4. **Nothing is ever closed.** There is no persisted day-close; every past day's report is recomputed live and silently mutates under late syncs, cancels, and backdated entries. Three different "revenue" definitions coexist (Home, Recon, Home-profit) that disagree by deposits and discounts by construction.
5. **Liabilities are second-class citizens.** Deposits held for customers, supplier-side crate money, forfeit income, and (in the planned van channel) unremitted driver cash are each either invisible, mislabeled as income/assets, or counted at the wrong moment.

The van-sales plan (#139–#147) inherits all five: as specified, route sales inject "cash" into the owner's cash card the moment the driver rings them (and the remittance days later is never recorded anywhere the recon reads), cost does not travel with the load, trip profit is booked into no table any report reads, and the plan's spec file and ADR 0019 do not exist anywhere in git. §5 gives the full trail and the adjustments.

None of this needs a rewrite. §8 ranks alternatives; the recommended path is to **finish applying the append-only-ledger discipline the app already proves** (wallet-style) to payments, losses, and the cost queue, and to persist a day-close snapshot.

---

## 2. The money trail, stage by stage

### Stage 0 — Goods and money in (supplier → warehouse)

The good path: `ReceiveStockService.confirmReceipt` (`lib/shared/services/receive_stock_service.dart:42-152`) is one transaction that posts the supplier invoice debit, the optional payment credit, the stock increment, and a fresh FIFO cost batch per line (`recordInflowBatch`). One physical delivery, one atomic set of records. **V**

Where money slips in unrecorded (or unowed):
- **Zero-cost receive lines post no invoice** — `invoiceTotalKobo == 0` skips the ledger while stock still lands (`receive_stock_service.dart:65-75`). Supplier payable understated. **V**
- **Add Product opening stock posts no supplier invoice** — correct by definition for legacy shelf stock (ADR 0006), but it is also an unguarded channel to receive real deliveries invisibly. **V**
- **Add Product's *existing-product* branch adds quantity with no cost batch** — bare `adjustStock(..., 'Stock received')` (`add_product_screen.dart:701-707`); those units eventually sell at 0 COGS. **V** (hand-checked)
- **Supplier payments bypass `payment_transactions`** — they live only in `supplier_ledger_entries` and are bolted onto the cash card separately, keyed on the user-picked `activityDate` (`recon_data.dart:911-921`): a backdated supplier payment retroactively edits an already-reviewed day's cash card — the only user-editable date inside it. **V**
- **Supplier crate-deposit cash posts to no money ledger** and the recorded figure (`watchDepositHeldKobo`) has zero UI consumers; the screen shows a rate-derived estimate instead (`daos_suppliers.dart:488-510`, `supplier_detail_screen.dart:692-694`) [CA §B3]. **V**
- Receive Stock also silently rewrites retail/wholesale selling prices per line with no old/new audit (`receive_stock_service.dart:100-105`). **V**

### Stage 1 — Stock on the shelf (valuation)

`cost_batches` is the FIFO truth; `products.buyingPriceKobo` is a display cache (oldest costed batch). Sales draw down correctly (`drawDownSale`, `daos_costing.dart:158-227`) and the server recost (0133) heals multi-till drift after each sale push. **V**

The structural hole: **`InventoryDao.adjustStock` (`daos_inventory.dart:244-397`) — the central mutator used by approvals, damages, stock counts, transfers, and deletes — never touches `cost_batches` in either direction** (hand-verified; the web RPC 0141 documents the same). Consequences:
- Approved stock *increases* create no cost layer → later 0-COGS sales; approved *decreases* leave batch coverage for goods that are gone → phantom COGS. **V**
- **Store transfers move quantity, not cost** — batches are per (product, store); the destination sells received goods at 0 COGS while the source keeps coverage it no longer holds. Per-store margin is structurally wrong for any multi-store business. In-transit stock is valued nowhere (source decremented at dispatch, destination credited at receive). **V**
- **Cancel restores inventory but not batches** (§ Stage 4). **V**
- Partially-covered sale lines average covered + 0-cost units into one per-unit figure — they *look* costed while understating COGS, and never appear in the "uncosted items" transparency bucket (`daos_costing.dart:190-202`). **V**
- Losses carry **no value at write time**: damages/theft/expiry/shortage are quantity-only rows valued at report time at *current* cost (`recon_data.dart:781-792, 842-847`) — a later cost edit silently restates every past period's loss figure (the exact failure mode ADR 0005 rejected for COGS), and a deleted product's losses fall to ₦0 (deleted-filtered product lookup). **V**
- Soft delete: best-effort stock zeroing (failure doesn't block the delete → invisible stranded stock), open batches never written off, the write-off value booked nowhere (`product_detail_screen.dart:1965-1998`). **V**
- No price/cost history: selling-price and real→real cost edits keep no old/new record (only per-sale snapshots); margin manipulation is undetectable after the fact. **V**

### Stage 2 — The sale

`createOrder` (`daos_orders.dart:516-863`) is one transaction: order header (born `pending` = revenue recognized, ADR-consistent), guarded inventory decrement, FIFO COGS snapshot, crate lines + deposit-held wallet credit, §14.3 wallet double-entry (debit total / credit paid), and — only when `amountPaidKobo > 0` — one `payment_transactions` row. The debt-limit gate blocks over-limit credit sales. This core is sound. **V**

What the recorded money gets wrong at the moment of sale:
- **Every non-wallet tender is `method: 'cash'`.** The checkout hardcodes `paymentSubType` to `'wallet' | 'cash'` (`checkout_page.dart:1136`, hand-verified; the comment says "'cash' covers Cash / Transfer"). Bank transfers and any POS-terminal takings are booked as drawer cash; the schema already supports `'transfer'/'card'/'pos'` — unreachable from the UI. **V**
- **The refundable crate deposit rides inside the `'sale'` payment row** (`amountKobo = amountPaidKobo`, which includes the deposit) → "Cash sales" contains customer liabilities; the engine's own comment claiming deposits are "deliberately excluded" from the cash card is false. **V**
- **Three revenue definitions disagree by construction**: Home "Total Sales" = Σ `orders.totalAmountKobo` (deposit **in**, discount netted); Recon/Profit = Σ item lines gross − explicit discounts (deposit **out**); Home net-profit ignores discounts entirely (`home_screen.dart:279-305` vs `recon_data.dart:584-664`) [extends CA §A4]. **V**
- **Discount governance is a paper control**: `sales.discount.give` exists in the catalogue but is never checked; the real cap is the role slider. Custom-price overrides *replace* `unitPriceKobo` — the concession vs. catalogue is recorded nowhere, and the per-line discount split is discarded (only the order-total `discountKobo` survives). **V**
- **Quick Sales**: money enters the drawer, but the lines are excluded from P&L revenue entirely (not just margin) while the cash card counts them — profit and takings diverge by every quick sale. **V**
- Overpayment by a registered customer records the **full tendered amount** as a `'sale'` payment even though the excess is a wallet-liability top-up. **V**
- Walk-ins must pay exactly the total; their crates are fully untracked [CA §B4]. **V**
- Held carts are `saved_carts` only — no order, no money, no stock reservation (clean, but combined with v1 sync it's an oversell window). **V**

### Stage 3 — Confirm (the ceremony that moves real money)

`pending → completed` is *supposed* to be ceremonial (revenue already recognized). In fact Confirm:
1. **Runs the crate-deposit settlement** — forfeit/refund/shortfall wallet legs and possibly a **cash-out** `refund` payment row (`daos_orders.dart:1023-1134`) — with **no permission gate anywhere** (any user who can see the Pending tab), **no idempotency** (two offline devices double-settle), and a **blank part-deposit field that defaults to "all crates returned" = full refund** [CA §A2/A3]. **V**
2. **Overwrites `orders.staffId` with the confirming user** (`daos_orders.dart:1141`, hand-verified; `orders_screen.dart:812` passes the confirmer) — the seller's revenue is silently re-attributed to whoever taps Confirm; staff-performance and best-staff figures mutate after the money moved. **V**

### Stage 4 — Reversals (cancel / refund / reject)

There is exactly one refund path — full-order cancel (`markCancelled`, `daos_orders.dart:1155-1309`), gated `sales.cancel`; completed orders cannot be refunded at all; there are no partial/line refunds. What it does (hand-verified):
- Compensating stock `return` rows + inventory restore — **but no cost-batch restore and no COGS-snapshot reversal**; healing is conditional on a *future* sale of the same (product, store) triggering the server recost. **V**
- **Payments voided in place — never a compensating cash-out row.** The original day's revenue *and* cash silently shrink retroactively; the day the ₦ physically left the drawer shows nothing. Yesterday's report no longer matches yesterday's bank deposit, and no report anywhere shows refund outflow. **V**
- **`refundsKobo` is dead**: recon sums `status == 'refunded'`, which nothing writes (repo-wide: readers only, hand-verified) — in-app refunds report ₦0 forever, and a term of `periodNetResultKobo` is silently zeroed. **V**
- **Deposit-carrying cancels corrupt the wallet split**: the held `crate_deposit` credit is reversed as a `'void'` debit *outside* the deposit family → phantom spendable debt −D + never-resolving "Deposit held" +D; issued crates are never reversed [CA §A1]. **V**
- Rejected v2 sales (flag currently off): the local reversal is correct and deliberately local-only, but on that path the customer **paid and left with a receipt** while no payment row ever existed and stock is "restored" for goods that physically left — cash-in-hand exceeds every recorded number; the only trace is the orphan + a cancelled header. **V (latent)**
- Expense **reject and soft-delete never void the paired payment row** (`daos_expenses.dart:280-440` touch only `expenses`; the reject dialog even promises "No money moves") → rejected/deleted cash expenses drain the cash card forever, and the sanctioned wrong-amount fix (delete + re-create) double-counts. **V**
- `voidTransaction` for customer wallet entries voids wallet legs but never the linked `wallet_topup` payment row — a voided ₦100k mistyped collection still counts as "Debts collected (cash)" forever. And there is **no UI caller at all** for customer-side voids — mistyped repayments are uncorrectable from the app. **V**

### Stage 5 — Losses and write-offs

Covered in Stage 1 (no value at write time) and [CA §17.2/§C2-C3] for crate fates. One addition: **forfeited deposits are income that never reaches profit** — `crate_deposit_forfeited` exists only in the wallet family and the separate Crate Deposits report; recon P&L subtracts crate *losses* but never adds forfeit income. Profit understated for every kept deposit. **V**

---

## 3. The daily reconciliation — what the mirror shows

Engine: `computeReconData` (`recon_data.dart:537-1008`) — no SQL aggregation, no persistence; Dart folds over full-table streams, recomputed in `build()` on every frame. Buckets are naive device-local calendar days (`DateTime(y,m,d)`, weeks start Sunday), half-open `[start, end)`. Gate: Manager+ (`Gates.dailyReconciliation`); CEO unlock by role slug.

| Card | Audience | Source / basis | Integrity notes |
|---|---|---|---|
| Sales summary | all | Σ `qty × unitPriceKobo` over items of `orderCountsAsSale` orders, on **order `createdAt`** | Gross of discounts and credit sales (Manager over-expects vs takings, corrective cash card is CEO-only); Refunds line dead (₦0); VAT (below) |
| Profit & Loss | CEO | costed lines − discounts − FIFO COGS − approved expenses − damages@current cost − crate loss | Quick-sale takings excluded entirely; forfeit income missing; damages restate under cost edits |
| Cash flow | CEO | cash-method `payment_transactions` (sale/wallet_topup/refund/expense) on **payment `createdAt`** + cash supplier ledger on **`activityDate`** | **Business-wide** (no storeId); cash+transfers conflated; deposits inside "Cash sales"; rejected/deleted expense rows still counted; voided top-ups still counted; cancels rewrite past days; no cash-out on refund day |
| Stock reconciliation | CEO (cost) / Manager (retail) | rewind `stock_transactions` from current on-hand, all at **current** cost | Transfers/deletes/count-fixes land in an unlabeled "Other movements" residual; COGS basis ≠ P&L COGS (accepted, ADR 0014); after a cancel, sale-day and cancel-day stock-COGS split against P&L |
| Business worth | CEO | inventory@cost + crate asset + customer debt − supplier payable | Adds the empties **asset** (business-wide drifting counter [CA §B1] at today's rate) but never subtracts the deposit **liability** [CA §C1] or supplier crate debt; in-transit transfers valued nowhere |
| Debts & expenses | Manager | business-wide point-in-time debt + period expenses | Store lock ignored for debt |
| Empty crates | crate biz | `emptyCrateStock × rate` | Business-wide/point-in-time inside a store-/period-scoped report [CA §C4] |

**Persistence: none.** No closings table; the only "close" artifact is a device-local reviewed marker. Every past day silently mutates under: late-syncing offline devices (rows land in their original `createdAt` buckets), cancels (retroactive void), backdated supplier `activityDate` entries, and — if the v2 flag ever flips — server-minted payment rows stamped at drain time (offline day's cash lands on the sync day). **V**

**Beverage vs. other industries**: the *only* differences are the crate surfaces (gated `businessTracksCrates`) — the crate card, held-crates line, deposit-loss P&L term, and crate asset in Business worth; every other money formula is industry-identical. Non-crate businesses simply have those terms structurally zero, which is correct. The far bigger view split is Manager-vs-CEO (the cost wall: managers see retail-valued shrinkage, never COGS/profit/cash). The Lexicon is not used on recon screens (hard-coded "crates" copy, acceptable because gated). **V**

**VAT** (opt-in, off, report-only): computed as `(gross − discounts) × rate` **on top of** recorded takings. For a shop whose prices are VAT-inclusive (no VAT is added at checkout — the recorded takings are all the money there is), the liability is overstated by factor (1+r): ₦100,000 at 7.5% shows "VAT due ₦7,500" where the inclusive figure is ₦6,977. Needs an inclusive/exclusive basis decision. **V formula / S intent**

**Timezone split**: flows bucket on naive device-local midnight; stock counts bucket on business-timezone `businessDate` — two clock regimes feeding the same variance flag. Latent in single-TZ Nigeria; real for any clock-skewed till. **V**

---

## 4. The party ledgers

### Customers
- Wallet ledger = single truth (no balance column); spendable = Σ signed excluding the deposit family; deposits-held = Σ over the family. Double-entry per sale is inside the sale transaction. Debt limit enforced at checkout. **Sound.** **V**
- Repayments (Add Credit) post wallet credit + `wallet_topup` payment row atomically; repayment is global to the wallet — `orders.amountPaidKobo` is frozen at checkout forever (the wallet is the only receivable; per-order "unpaid balance" is a snapshot, not a live figure). **V**
- **No UI void path** for any customer wallet entry (the DAO method exists, callers: supplier screen only). Mistakes are permanent or fixed by fabricating offsetting entries. **V**
- Statement tiles count voided originals *and* their compensators in "Total In/Out" (suppliers exclude them — same event, two answers). **V**
- Dead-but-dangerous: `CustomerService.addPayment`/`refundToWallet` (no payment row, null performer) and the cart's crate-credit offset (`Customer.emptyCratesBalance` hardcoded `{}` — customers holding crate credit are charged full deposit; if naively wired, crate *debtors* would get discounts [CA §5D]). **V**

### Suppliers
- Wallet semantics correct end-to-end (negative = we owe, red; positive = credit held, green); Receive Stock auto-posts; voids are compensating + CEO-gated + `created_at`-scrubbed. **Sound**, with the Stage-0 gaps (zero-cost lines, Add-Product path, payments outside `payment_transactions`, crate-deposit money island). **V**
- The inverse-convention `supplierPayableKobo` survives as an internal intermediary (recon negates it for display) — correct today, a trap for future readers. **V**
- Store scoping: NULL-store legacy rows appear only under All Stores — a locked-store supplier balance can silently omit legacy debt. **V**

### Manufacturers
- Money here = the canonical deposit rate + the business-wide empties counter (monetized in recon). Product mirror (`emptyCrateValueKobo`) is written *to* the manufacturer on product edits but never fanned back out — the cart's deposit *hint* uses the stale mirror while the *charged* rate uses the manufacturer: displayed deposit ≠ charged deposit after a rate change. Manage-dialog `isCEO=true`, the Add-that-sets bug, and pool-counter drift are [CA §A5/§B1]. **V**

### Expenses
- Approval flow is race-guarded and well-gated; amount/method immutable after creation. **V**
- The payment row is written unconditionally at record time (even while `pending`) and **never voided on reject/soft-delete** — the single worst cash-card polluter (§ Stage 4). P&L (approved-only) vs cash card (all rows) disagree by construction. **V**
- Three date bases coexist (user-picked `expenseDate` on the screen/budget, `createdAt` in recon P&L, payment-row `createdAt` in the cash card) — backdated expenses land in different periods per report. **V**

### Payment tables inventory
`payment_transactions` (no storeId; `purchase` type + `shipment_id`/`delivery_id` never written; voids = metadata-only), `wallet_transactions` (compensating voids, no UI), `supplier_ledger_entries` (compensating voids, CEO UI, no cloud append-only trigger), `supplier_crate_ledger`/`crate_ledger` (**latent void trap: no `scrubCreatedAt` registry flag, and `crate_ledger` is cloud-immutable including `created_at` — the first void feature shipped for either will orphan pushes**). **V / S(latent)**

---

## 5. The van-sales channel (#139–#147, on-hold)

**Documentation state (V):** the spec file all nine issues cite (`docs/design/van-sales-spec.md`) exists in no working tree, branch, or commit; **ADR 0019 was never committed anywhere in git**. The issues are the plan's only record. #121 (oversell-orphan recovery) is MERGED — the go-live flag itself remains off.

**The planned design** (from the issues): van = `stores` row (`kind='van'` — column doesn't exist yet); Driver role; trip open→closed; append-only `driver_ledger_entries` (load/restock **debit the full load-price value**; returns/payments/write-offs credit; **sales never touch the balance**); `van_trip_lots` = load-priced FIFO layers; stripped cash/walk-in terminal; manager-recorded payments; reconcile decomposes the balance into unremitted cash / shortage / damage; **profit booked at the store on close**; #147 adds one aggregated revenue line and excludes van orders from normal reports. Crates/empties wholly deferred (no follow-up issue). The consignment ledger math itself ties out — the worked trip below balances to the kobo. The breaks are at the seams with FIFO, the cash card, and report wiring.

### The money trail, day by day (worked trip)

Star 60cl: warehouse batch 200 @ ₦10,000 cost; load 100 @ ₦11,500 load price Monday; sell 60 Tuesday, restock 40 Wednesday + sell 30; Thursday return 45 good + 3 damaged, remit ₦900,000, close.

| Day | Physical reality | What the store's daily recon shows |
|---|---|---|
| Mon (load) | 100 crates + 100 shells (₦180k deposit value) drive off; driver signs for ₦1.15M | Sales ₦0. Stock card: −₦1M filed under unlabeled "Other movements". Business worth: inventory down ₦1M, the ₦1.15M driver receivable **invisible** (driver ledger is not a recon input). FIFO: warehouse batch still shows 200; van queue empty — **cost did not travel** |
| Tue (route) | Driver pockets ₦720k (₦690k @ load price + ₦30k street markup, off-book by design) | Warehouse-locked view: silent. **All-Stores/CEO view: Revenue +₦690k with COGS 0** (60 lines pollute "uncosted items"), and **"Cash sales" +₦690k — cash that is physically in a pocket on a route**. `payment_transactions` has no storeId, so no store filter can ever exclude it (**V**, hand-checked) |
| Wed | Restock + 30 more sold | Same distortions again |
| Thu (close) | 45 good back, 3 damaged, ₦900k remitted; position ties: balance ₦192,500 = unremitted ₦135k + shortage ₦23k + damage ₦34.5k ✓ | The ₦900k that physically **arrived** appears in no recon figure (driver-ledger credit, unread); the ₦135k never remitted stays inside recorded "cash sales" forever. "Store profit ₦142,500" booked at close goes into **no table any report reads**. Returned 45 crates re-enter the warehouse **with no cost batch** → next 45 sales at 0 COGS. Warehouse batch keeps 95 phantom units forever. 35 shells (₦63k deposit value) unaccounted — trip still closes at "balance 0 = settled" |

Aftermath: the 90 zero-cost van lines are a standing trap for the F5 cost-backfill (`buying_price_kobo == 0` + recognized + product_id is exactly its gather set) — one accepted prompt later restates road sales with per-line COGS and double-counts against close-time profit. A month-straddling trip puts revenue in July and profit in August; ADR 0014's integrity flag stays red every day a trip is open.

### The recon-integration answers

1. **On a van-out day** the warehouse-locked recon is silent except unlabeled stock outflow; the All-Stores view gets revenue-without-COGS *and* pocket-cash-as-cash-sales the same day.
2. **Route sales appear in Sales on ring day** (at load price, 0 COGS) in every CEO surface until #147's exclusions — which ship **last** (a 5-slice corrupted-numbers window).
3. **The cash card sees driver cash at ring time and never sees the remittance** — exactly backwards from custody, and structurally unfixable by store filters (no storeId).
4. **Van COGS lands nowhere, ever, as planned**: 0-cost lines + unpersisted close profit + a revenue-only rollup line.
5. **Close races the driver's outbox**: a late-arriving offline sale changes `sold` after the persisted shortage/cash split was used to assign blame.

### Plan adjustments (ranked; slice each modifies)

1. **Cost travels with the load** — draw down warehouse batches at dispatch; snapshot `cost_kobo` per `van_trip_lots` row; returns re-batch at that snapshot; close sums lot costs (deterministic, two-van-safe). (#141/#143/#145)
2. **Cash-custody rule** — van sales write **no** `payment_transactions`; remittances (#144) **do** (new type `van_remittance`); recon gains a "Cash from drivers" line. Decide before #142 ships. (#142/#144/#147)
3. **Report exclusion moves to the prefactor** — central `isVanStore` predicate wired into `reconStoreFilter`/profit/dashboard in #140; exclusion ACs into #142's definition of done; decide All-Stores treatment of van stock in worth. (#140/#142)
4. **Close artifact + recon input** — persist `cogs/recovered/shortage_writeoff/damage_writeoff/profit/closed_at/source_store_id` on `van_trips`; recon reads closed trips for P&L and prints an open-trip caveat ("₦X van revenue awaiting trip close — profit not yet booked"). (#145+#147, ship adjacent)
5. **Backfill/recost fences** — exclude van-store lines from F5's gather and 0133's replay. (#142)
6. **Close sync-barrier + restatement** — warn/block Confirm-&-close while the driver device has pending sale envelopes; late sale ⇒ auto-post compensating pair + "restated" flag, one audit row. Returns entry = forced physical count, never a system-derived default. (#145/#143)
7. **Crate memo seam now** — write-only `shells_out`/`shells_back` count columns + reconcile-screen display + "swap-only, no deposit sales on the road" terminal copy; file the "Van Sales v2: crates + deposits" issue and the manufacturer-settlement PRD stub [CA §6]. (#141/#143/#145/#146)
8. Trip-open server uniqueness (partial unique index) + dispatch idempotency key; load-below-cost warning (non-revealing, cost wall intact); non-cancellable load legs (or fix CA §B6 first). (#141)
9. Write-off dual valuation: ledger credit at load price, company loss at snapshotted cost — booking load price as loss overstates it by the margin never earned. (#145)
10. Former-driver debt stays visible (badged) + offboard guard on open trip / non-zero balance; stale-open-trip nag. (#146/#145)
11. **Recreate the spec and write ADR 0019 before any label flips** — every AC references math that exists nowhere in the repo.

**Slice ordering is NOT safe as sequenced** (three windows where money is untracked or misreported). Safe order after adjustments: **#140 (incl. exclusion predicate + spec/ADR) → #141 (cost-on-lots) → #144 → #142 (payment-row suppression + backfill fence) → #143 → #145+#147 together → #146.**

---

## 6. Cross-cutting: sync and money integrity

- **v1 inventory is absolute-value LWW with no server guard** (each till pushes its full row; the guarded v2 envelope is merged but flag-held-off): concurrent tills lose decrements; stock — and everything valued from it — is best-effort until the flip. Money rows themselves stay intact. **V**
- **The v2 go-live cluster** (gates the flip): (a) background oversell rejection leaves physically-collected cash with zero records; (b) the server recomputes `total_amount_kobo` as *gross* while local holds *net payable* — a full re-pull (cloud-wins ties) silently inflates historical totals by the discounts; (c) v2 cancel must stay off until the RPC mints the wallet payment-leg reversal (the code says so itself). **V (latent)**
- **Append-only ledgers are the safe core** (wallet, supplier, payments, order lines) — LWW cannot corrupt them; balances recompute. The **crate balance caches** are the exception: absolute-value LWW with a dead, print-only reconciler [CA §B2]. **V**
- The envelope/held-outbox machinery (#121/#149) is genuinely good work: rejected sales can no longer leak phantom cloud orders, and held child rows release/discard atomically. **V**

---

## 7. Criticism — the five root causes

1. **Two bookkeeping philosophies in one app.** Wallets and supplier ledgers are append-only, derived, compensating — real ledger discipline (Invariant #3). Payments, losses, and inventory value are mutate-in-place caches and quantity-only rows. Every Top-10 leak in this audit lives on the second side of that line.
2. **Corrections rewrite history.** Void-in-place payments, reject-without-reversal expenses, cancel-without-cash-out — the report you reviewed yesterday is not the report you get for yesterday today. With no persisted close, there is no tamper evidence and no "changed since review" signal — an honest-mistake amplifier and a fraud surface (delete an expense after review; the cash card mutates silently).
3. **One writer, many bypasses.** `adjustStock` is the blessed quantity seam but knows nothing of cost; the crate pool has three representations and asymmetric writers [CA §B1]; `payment_transactions` is "the unified tender ledger" that supplier payments and remittances bypass. Seams exist — they're just not load-bearing.
4. **Reports re-derive instead of read.** No persisted aggregates, three revenue definitions, two cost bases, three expense date bases, folds over full tables in `build()`. Every new surface re-answers "what counts as money?" slightly differently.
5. **Liabilities and custody are afterthoughts.** Deposits held, supplier crate cash, forfeit income, driver pocket cash — money the business *holds but doesn't own* (or *owns but doesn't hold*) is systematically booked as if custody equals ownership at the moment of first touch.

## 8. Alternatives

**A. Finish the ledger discipline you already prove (recommended — smallest change, biggest fix).** Make `payment_transactions` behave like the wallet: corrections are **compensating rows, never void-in-place** — cancel writes a dated `refund` cash-out; expense reject/delete writes a reversal; top-up void reverses the payment row; overpayment splits sale vs top-up rows. Add `store_id` and start writing real tender (`'transfer'` exists in the schema today) + a deposit-distinct type. This single pattern shift fixes the refund black hole, the retroactive day rewrites, the expense drain, the transfer conflation, the deposit-in-cash-sales, and gives the van channel its custody-correct seam (`van_remittance`). Cost: one DAO pattern + a handful of report predicates; no new architecture.

**B. Persist the day-close** (ADR 0014's explicitly deferred option). One synced `daily_closings` row per (business, day[, store]) written on first review — the computed figures as-of review time. Recon then shows "as reviewed" vs "current" with a delta badge. Gives immutability, tamper evidence, and an audit anchor without touching any flow. Pairs with A; either stands alone.

**C. Batch-hook the central mutator.** `adjustStock` gains cost semantics: decreases draw down batches FIFO and write a **valued loss row** (cost snapshotted at write — the same immutability ADR 0005 demands for COGS); increases take an optional cost (else uncosted batch); transfers move batch slices with the quantity; cancel restores the specific consumed batches; delete writes off open batches explicitly. One seam, mirroring [CA §7]'s "one pool API" for crates. This is the only way per-store margin and the stock card become truthful.

**D. The full double-entry journal (long-term direction, not now).** One append-only money-events journal (event, debit account, credit account, amount, refs) that every flow writes and every report reads; accounts for cash-drawer, bank, receivables, deposit-liability, inventory, COGS, income. It is the textbook answer to §7 and would make "three revenue definitions" impossible — but it's a migration of every flow and report. Adopt A+B+C first; they are convergent steps toward D, not throwaway.

**Rejected:** reintroducing a counted cash drawer (Hard Rule #8 tombstoned it — and A+B deliver the "follow the money" goal inside the recorded-flow world by making recorded flows complete and immutable instead).

## 9. What's genuinely solid (keep through any refactor)

The §14.3 wallet double-entry inside the sale transaction; the supplier invoice auto-posting in the receive transaction; append-only ledgers with derived balances and compensating voids; FIFO with per-line snapshots, server-authoritative replay, and *consented* backfill (ADR 0005's "no silent restatement" stance is exactly right — the report's criticism is that damages/losses don't yet follow it); the envelope hold/release machinery and local-only reversal of rejected sales; collision-proof offline order numbers; the debt-limit gate; the outbox invariants (#12); the recon's flow-equation design and its honest "Other movements" residual (it needs labeling, not removal); and the van plan's consignment ledger math, which balances to the kobo in the worked example.

## 10. Prioritized fix plan

| # | Fix | Why here |
|---|---|---|
| 1 | Gate + idempotent Confirm; blank part-deposit ⇒ 0 [CA §A2/A3] | Active till-cash leak, fraud surface, trivial diffs |
| 2 | Cancel: compensating cash-out row + deposit-family reversal + crate reversal [CA §A1] | Active books corruption on a common action |
| 3 | Expense reject/delete + top-up void ⇒ void/reverse the paired payment row | Compounding cash-card corruption |
| 4 | Tender picker (write `'transfer'`); deposit out of "Cash sales" + Home totals; Refunds line from real rows (retire dead `'refunded'` or write it) | Makes the cash card tie-able to the drawer for the first time |
| 5 | Persisted day-close snapshot + "changed since review" (Alt B) | Stops silent history mutation; cheap once 1–4 land |
| 6 | Batch hooks in `adjustStock` + transfer batch moves + cancel batch restore + valued loss rows (Alt C) | Stock value & per-store margin truth |
| 7 | Recon truth patches: quick-sale takings line, forfeit income, deposit liability in worth, in-transit line, VAT basis toggle, label "Other movements" | Owner-facing accuracy |
| 8 | Confirm stops overwriting `staffId` (add `confirmedBy` instead) | Attribution integrity |
| 9 | Crate foundation [CA §9 items 4-8]: pool API, supplier wiring, LWW cache fix | Pre-van prerequisite |
| 10 | Van pre-resume checklist (§5: spec+ADR recreate, adjustments 1-11, reorder) | Before any label flips |
| 11 | Hygiene: dead code sweep (CustomerService money paths, crate-credit block, `purchase` type), wallet-void UI, date-basis unification, scrub flags for crate ledgers | Prevents "finishing" landmines |
