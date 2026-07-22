# Empty-Crate Tracking Audit — 2026-07-21

**Method.** A 7-agent parallel audit swept the data model, POS/checkout, the return flows, the inventory/manufacturer screens, the customer/supplier screens, all crate-related GitHub issues/PRs (including the on-hold van-sales set #139–#147), and the design docs — 86 raw findings. Every finding that headlines this report was then re-verified by hand against the current code; the hand-check hit rate on agent claims was 100%. One finding (the Skip-button crash) is static analysis only and is flagged as such.

---

## 1. Executive summary

The crate system has a **sound skeleton** — an append-only `crate_ledger`, per-manufacturer deposit rates snapshotted onto orders at sale time, a wallet "held deposit" family that keeps refundable money out of spendable credit, and crate-aware damages that avoid double-counting. The two-track model (deposit paid = settle in money; no deposit = settle in crates) is genuinely well thought out.

But the flesh around that skeleton is inconsistent, and the inconsistencies are exactly where money leaks:

1. **The physical empties pool has three representations that no single write path keeps in step** — `manufacturers.emptyCrateStock`, `store_crate_balances`, and the ledger. Empties **in** update the business counter; empties **out** (to a supplier) don't. The "All Stores" empties figure inflates forever.
2. **Refunding/cancelling a deposit-carrying sale corrupts the books** — cancel never reverses issued crates (phantom customer debt) and reverses the held deposit into the wrong wallet bucket (deposits-held stays inflated forever, spendable is docked).
3. **The Confirm ceremony — where cash deposit refunds are paid out of the till — is completely ungated, not idempotent, and its part-deposit input defaults to "full refund" when left blank.**
4. **Supplier-side crate tracking is a parallel book nobody reconciles** — Receive Stock and the Supplier "Empty Crates" tab never talk to each other, and supplier deposit cash never reaches any money ledger.
5. **The balance caches are last-write-wins (LWW) rows pushed as absolutes** — two offline devices touching the same customer/brand lose one device's delta permanently, and the reconciliation function that was supposed to catch this has **no caller** and only `print()`s.
6. **The van-sales plan (#139–#147) defers all crate handling with no tracking issue, no schema seam for shells, and a reconciliation formula that is blind to crates** — a driver can lose every shell on the route and still close at balance 0. The spec file all nine issues cite (`docs/design/van-sales-spec.md`) does not exist in the repo, on any branch, or on disk.

None of this requires a rewrite. The single highest-leverage change is to make the **ledger the only source of truth** and treat every balance/counter as derived — the same pattern the wallet already uses.

---

## 2. The model as designed

**Gates.** Crate tracking is live only when *all* of: business type is crate-eligible (`Industry.crateEligible` → bar / beverage distributor, via `isCrateBusiness`), the business opt-in `businesses.tracksEmptyCrates` is on, and the product has `unit=='bottle' && trackEmpties` with a manufacturer linked. The canonical deposit rate is per-manufacturer (`Manufacturers.depositAmountKobo`); `Products.emptyCrateValueKobo` is only a mirror.

**Two tracks, decided per brand at checkout** (`daos_orders.dart:623-707`):
- **Money-track** — the customer pays a deposit for that brand. The deposit is added to the payable (`_totalKobo = goods + deposit`, `checkout_page.dart:333`), carved out of the wallet legs into one held `crate_deposit` credit, excluded from spendable balance, and settled *in money* at Confirm (refund / forfeit / shortfall). **No crate count is ever tracked against the customer.**
- **Crate-track** — deposit left at ₦0. The crates are *issued* as a debt: an `'issued'` `crate_ledger` row plus a `customer_crate_balances` increment; a later return nets it back. CEO+Manager get a "customer owes crates" notification.

Either way, one `order_crate_lines` row per (order, manufacturer) records crates taken, the **deposit-rate snapshot**, and the deposit paid — so later rate edits never rewrite an old settlement.

**Physical pool.** Empties held by the business live in *three* places: `manufacturers.emptyCrateStock` (business-wide counter, what "All Stores" shows), `store_crate_balances` (per store+manufacturer, what a locked store shows), and store-stamped `crate_ledger` rows. Documented invariant: counter = Σ store balances (`daos_inventory.dart:87-90`).

**Supplier side (§3.13).** A separate `supplier_crate_ledger` / `supplier_crate_balances` pair: positive = we owe the supplier empties for full crates delivered; rows can carry `depositPaidKobo` for deposit money moved with the crates.

**Sync.** Ledgers and order lines push append-only through the outbox. The four balance caches (`customer/manufacturer/store/supplier_crate_balances`) push as **absolute-value LWW rows**. A `domain:pos_record_crate_return` delta RPC exists behind `feature.domain_rpcs_v2.record_crate_return`, but the flag-off per-table path is the default (and the sale-envelope flag family is known to be held off).

---

## 3. Lifecycle of an empty crate (as actually built)

1. **Setup** — crate business adds a Bottle product; `trackEmpties` defaults on; manufacturer is required; the crate value autofills from — and writes back to — the manufacturer's deposit rate (`add_product_screen.dart:269-281, 687-691`).
2. **Inflow from supplier** — Receive Stock increments bottle inventory (full crates are just stock). *Optionally and manually*, staff record "Received" on the Supplier Detail → Empty Crates tab (`supplier_crate_ledger 'received'`) — nothing does this automatically.
3. **Sale (registered customer, Cash/Transfer)** — cashier taps each brand row at checkout and enters the deposit actually paid (full / part / zero, `checkout_page.dart:684-885`). Money-track: deposit joins the payable, held `crate_deposit` credit posts. Crate-track (₦0): crates issued as customer debt. Receipt prints an Empty Crates section + a Crate Deposit line; **the printed TOTAL includes the deposit**.
4. **Sale (walk-in / Wallet / Credit modes)** — no deposit can be captured; walk-ins get **no crate records at all** (`daos_orders.dart:651`); Wallet/Credit sales fall back to crate-track by design.
5. **Customer holds crates** — the Customer Detail → Crates tab shows per-manufacturer owed/clear/credit; "Deposit Held" money shows separately from the wallet family.
6. **Return at Confirm** — "Mark as Delivered" opens `CrateReturnModal` (counts only); `OrderCommands.confirm` settles *before* flipping status: physical empties always credit the pool via `addEmptyCrates`; money-track brands settle the held deposit (forfeit kept×rate capped at paid → `crate_deposit_forfeited`; refund remainder → `crate_deposit_refunded` + cash row or `crate_refund` credit; shortfall → `adjustment` debt); crate-track brands net the issued balance (`order_commands.dart:183-273`, `daos_orders.dart:1006-1134`).
7. **Return outside an order** — Customer Detail Crates tab "+" (gated `sales.make`): pool credit to the store resolved from the customer's orders, plus a `'returned'` ledger row. Over-return becomes a crate *credit* (balance < 0).
8. **Pool at the store** — manual absolute set via the Crates tab "Manage" dialog (off-ledger); damages per §17.2 (stored-empty-damaged = pool debit + `'damaged'` ledger row, no stock; full-crate-lost = stock loss + deposit forfeit, pool untouched); empties ride store-to-store transfers **at dispatch time** via a `transferred_out/in` ledger pair + `pos_transfer_crates` envelope.
9. **Outflow to supplier** — Receive Stock's per-manufacturer "empties returned" inputs post `recordCrateReturnByManufacturer` (manufacturer/store caches only), and/or staff manually record "Returned" on the Supplier tab (supplier ledger only). **Neither path decrements `manufacturers.emptyCrateStock`.**
10. **Reporting** — Daily Reconciliation shows "Empty crates (held now)" (point-in-time, business-wide) and counts the crate asset in Business worth; the Crate Deposits report proves Held = Taken − Refunded − Kept per customer; damage deposit losses hit net profit.
11. **Reversals** — a cloud-rejected v2 sale un-issues crates locally with a compensating `'adjusted'` row (correct, and deliberately not enqueued). A *user* cancel/refund does **not** reverse crates at all (bug #A1).

---

## 4. Screen-by-screen inventory

| Surface | What it shows/edits | State |
|---|---|---|
| **Inventory → Empty Crates tab** | Per-manufacturer Full / Empty / Total; per-store when locked, business counter in All Stores; Manage dialog (absolute count set, deposit edit, "CEO: CRATE PRICE" bulk update); Add Manufacturer | Works, but `const isCEO = true`, off-ledger sets, Add-mode no-op, two fields → one column |
| **Add Product / Update sheet** | trackEmpties + crate value, gated bottle+crate-business, manufacturer required, value propagates to manufacturer | Correctly gated; mirror-drift risk on propagate |
| **Product Detail** | trackEmpties switch + crate value + read-only business-wide empties count | Switch **bypasses both gates**; stale mirror can clobber canonical rate |
| **POS Cart / Checkout** | Crate lines per brand, informational deposit card, per-brand deposit capture, paid-covers-deposit validation | Works for registered Cash/Transfer; dead "crate credit" block; ungrouped bottles inflate the card |
| **Orders → Confirm** | CrateReturnModal counts + refund destination (Credit/Cash) | Ungated, not idempotent, blank-field full-refund default, Skip likely crashes |
| **Customer Detail → Crates tab** | Per-brand owed/clear/credit, manual "+" return, Deposit Held tile, refund sheet (deposit drained first, debt-first rule) | Works; manual return not transactional and money-track-blind |
| **Supplier Detail → Empty Crates tab** | Net owed/credit per brand, received/returned totals, "Record crate activity" sheet (gated `suppliers.manage`), derived "Deposit value" | Parallel book; not fed by Receive Stock; recorded deposit money never displayed |
| **Receive Stock checkout** | Per-manufacturer "empties returned to supplier" inputs | Writes manufacturer ledger only; uncapped input can drive store balances negative |
| **Stock count → Record Damages** | §17.2 crate fates | Correct fates; validates against the wrong (business-wide) pool |
| **Store Transfer hub** | "Empty crates to send" at dispatch | Works; cancel strands empties; UI-only cap; skips the business opt-in gate |
| **Reports** | Crate Deposits report (Held/Taken/Refunded/Kept); Recon crates card + Business worth line + crate-loss P&L line | Solid concept; liability/income asymmetries below |

---

## 5. Pitfalls

### A. Money-leak bugs (all hand-verified this session)

**A1 — Cancelling a crate sale leaves phantom debt and corrupts the wallet split.** `markCancelled` (`daos_orders.dart:1155-1308`) reverses stock, voids payments, and reverses *every* wallet leg generically — but (a) never reverses the `'issued'` crate rows or `order_crate_lines`, so a refunded customer permanently shows as owing crates; and (b) reverses the held `crate_deposit` **credit** as a `'void'` **debit**. `'void'` is not in `kCrateDepositReferenceTypes`, so the "deposits held" figure (sum over that family, `daos_customers.dart:396-425`) stays inflated forever while the customer's *spendable* balance is docked by the same amount. Every cancel of a deposit-carrying sale misstates both the customer wallet and the business-wide Crate Deposits report. **Fix:** in `markCancelled`, reverse `crate_deposit` legs with a deposit-family type (e.g. `crate_deposit_refunded`) and append compensating crate-ledger rows (enqueued — this sale did reach the cloud), mirroring `reverseIssuedByCustomerLocal`.

**A2 — Blank part-deposit field silently means "everything came back."** Part-deposit rows are deliberately pre-filled blank so the cashier counts (`crate_return_modal.dart:121-131`), but `_confirm` parses `int.tryParse(text) ?? r.expectedQty` (`:235`) — an untouched blank falls back to **all crates returned**: full remaining-deposit refund + pool credited for crates that never arrived. **Fix:** blank → 0, or block Confirm until every blank field is filled.

**A3 — Confirm is ungated and double-settles.** The Orders tab has no permission gate (only POS/Stock/Cart are gated in `main_layout.dart`), the Confirm button renders for every pending order while Refund next to it checks `Gates.refundOrder` (`orders_screen.dart:747-775`), `markCompleted` writes `status='completed'` with no precondition (`daos_orders.dart:1136-1150`), and `settleCrateDepositReturn` never checks for existing settlement rows. Consequences: any role — including a stock keeper — can run the settlement and choose **Cash**, paying money out of the till; and two devices Confirming the same pending order offline each post their own wallet legs (fresh UUIDs, both sync) → deposit refunded twice and pool credited twice. **Fix:** gate Confirm (at minimum the cash-refund branch) on `sales.make`/`customers.wallet.withdraw`; re-read status inside the Confirm transaction and abort unless `pending`; skip settlement when a `crate_deposit_refunded/forfeited` row already exists for (order, manufacturer).

**A4 — Deposits inflate headline revenue.** `orders.totalAmountKobo` includes the deposit (by design, decision A), and both the dashboard "Total Sales" (`home_screen.dart:279-282`) and the Orders screen "Revenue" stat sum it raw — while recon and the Profit report correctly sum item lines (deposit-exclusive). A busy crate shop's headline sales are overstated by every deposit taken, and the two report families disagree. Reprints also pass `crateDeposit: 0, subtotal: totalAmountKobo` (`orders_screen.dart:1031-1032, 1179-1180`), hiding the deposit and inflating the printed Subtotal. **Fix:** subtract `crateDepositPaidKobo` wherever `totalAmountKobo` is presented as sales (customer_detail already does this correctly), and pass the real split to reprints.

**A5 — Everyone is CEO in the crate Manage dialog, and "Add" doesn't add.** `const isCEO = true` (`inventory_screen.dart:1909`) exposes deposit editing and the "CEO: CRATE PRICE" bulk update to anyone who can view inventory — no Gate anywhere in the dialog. The crate-price "Add" mode is a copy-paste no-op: both branches call `updateManufacturerEmptyCrateValue(mfr.id, inputKobo)` (`:2117-2127`), so "add ₦100" to a ₦1,500 deposit *sets it to ₦100*. And the dialog's two fields ("Deposit Amount", "CEO: CRATE PRICE") both write the same `manufacturers.depositAmountKobo` column — last writer wins. **Fix:** one field, one DAO method, behind a named Gate.

**A6 — One-shot forfeiture with no recovery.** Confirm immediately forfeits kept×rate of a money-track deposit. If the customer brings the rest of the crates tomorrow, the only recording path is the crate-track-only manual return — the forfeited money is unrecoverable in-app, and the button that triggers this is labelled "Mark as Delivered," not "settle deposits now." **Fix:** warn in the modal ("unreturned crates forfeit ₦X of the deposit now"), and/or add a manager-gated late-refund action reversing a forfeit row.

**A7 — Skip likely crashes the return sheet** *(static analysis, confirm on device)*. The sheet is `showModalBottomSheet<CrateReturnResult>` (`crate_return_modal.dart:65`) but Skip does `Navigator.pop(context, false)` (`:455`) — popping a `bool` through a `CrateReturnResult`-typed route trips Dart's covariant-generics check ("type 'bool' is not a subtype…"). Skip is the *only* dismiss affordance on this non-dismissible sheet. **Fix:** `Navigator.pop(context)`.

### B. Structural design flaws

**B1 — Three pool representations, asymmetric writes.** Verified: `addEmptyCrates` (returns in) increments the business counter + store balance; `recordCrateReturnByManufacturer` (empties out via Receive Stock) decrements manufacturer/store caches but **not** the counter; the supplier-tab "Returned" decrements **no pool at all**; manual "Manage" sets are off-ledger; only damage ever decrements the counter. Result: the documented invariant *counter = Σ store balances* breaks on the first receive-stock handback and drifts monotonically — the "All Stores" empties figure becomes fiction while locked-store figures stay plausible, which is the worst kind of wrong (it looks right until you switch views). **Fix:** one pool API (see §7).

**B2 — LWW caches + a dead reconciler.** All four balance caches are local `balance += delta` then a full-row absolute push; last write wins, so two offline devices touching the same (customer, manufacturer) permanently lose one delta — the DAO's own comment admits the cache "WON'T self-heal" (`daos_crates.dart:534-541`). The designed safety net, `verifyCrateReconciliation`, has **zero callers** and only `print()`s — and its manufacturer check would false-alarm on healthy data anyway (it sums pool movements against a cache the pool paths never touch). **Fix:** §7, Alternative 1 or 2.

**B3 — Supplier crates are double-entry bookkeeping done by hand, and the money is invisible.** Receiving a delivery writes no supplier crate 'received' row; the receipt's empties inputs write the *manufacturer* ledger; the Supplier tab writes *its own* ledger. One physical event needs two manual entries on two screens to keep both books right (`receive_stock_service.dart:120-137` vs `daos_suppliers.dart:415-476`; the service's header comment still claims the supplier feature "is not present on this build"). Worse: `deposit_paid_kobo` recorded on supplier rows is real cash that posts to **no** money ledger and is displayed **nowhere** — the tab's "Deposit value (refundable)" is *derived* (owed × current rate) while the actual recorded money (`watchDepositHeldKobo`) is dead code. **Fix:** feed `confirmReceipt` into the supplier crate ledger in the same transaction; post deposit cash as a supplier-ledger/payment leg; surface the recorded figure.

**B4 — Walk-ins are a structural blind spot.** `createOrder`'s entire crate block requires a registered customer; walk-ins take full crates with zero record and only a receipt plea ("Ensure empties are returned"). The docs list §3.14–3.16 ("walk-ins adjust crate inventory with a same-time exchange") as an **unresolved open question**. This matters double because the van-sales terminal is walk-in-only (§6). **Fix:** decide the model — the natural one is a same-time exchange field at checkout ("empties received now") that credits the pool in the sale transaction and, for registered crate-track customers, offsets the issued quantity. That single field also fixes the awkwardness that a swap customer currently gets booked as a debtor until someone runs Confirm.

**B5 — Manual customer return is money-track-blind and not atomic.** The Crates-tab "+" always calls `recordCrateReturnByCustomer`. For a brand whose deposit was paid, no balance was ever issued — the manual return mints a negative "crate credit" while the deposit stays held, and the refund sheet can then also pay the deposit out: double compensation. The pool credit and balance net are also two separate awaits with no transaction, and the activity log stamps the locked store while the pool credit goes to the resolved store (`customer_detail_screen.dart:2352-2386`). **Fix:** route brands with a held deposit to `settleCrateDepositReturn`; wrap the pair in one transaction; log the store you actually credited.

**B6 — Transfers: cancel strands empties; caps are UI-only; opt-out gate skipped.** Empties move at dispatch, but `cancelTransfer` (verified: zero crate references) only restores product stock — a cancelled shipment leaves the destination pool credited with crates that came back on the van. The DAO never re-checks the source balance (`applyDelta`: "caller is responsible"), so stale UI reads or concurrent dispatches can drive pools negative. And the hub's eligibility check omits `businessTracksCrates`, so an opted-out business with legacy products can still ship empties. **Fix:** compensating crate legs on cancel (or block cancel when crate legs exist); re-validate the source balance inside the dispatch transaction; AND in the opt-in gate.

**B7 — Damaged-empty validation checks the wrong pool.** The stored-empty fate validates quantity against the **business-wide** pool but debits the **store's** unclamped balance (`stock_count_screen.dart:679-697` → `recordEmptyCrateDamage(storeId: p.storeId)`): store B with 0 empties passes validation on store A's stock and goes negative, while the business counter clamps at zero — the two views now disagree by construction. **Fix:** validate against the store actually debited.

### C. Reporting distortions

**C1 — Business worth counts the crate asset but not the deposit liability.** `businessNetPositionKobo = inventory + customer debt + crateDeposit − supplierPayable` (`recon_data.dart:503`). The empties-held asset is added; the deposits held for customers — money the Crate Deposits screen itself defines as "still owed back to customers right now" — and the supplier-side crate debt are never subtracted. Net position is systematically overstated. **Fix:** subtract held deposits (the summary already exists) or footnote the exclusion.

**C2 — Deposit income asymmetry.** Forfeited deposits are labelled "(income)" in the Crate Deposits report but never appear in the recon P&L — while crate *losses* (damages) are subtracted. Profit is understated for shops that keep deposits from non-returners. **Fix:** add period `crate_deposit_forfeited` sums as an income line, or stop calling Kept income.

**C3 — Historical restatement.** Damage deposit losses are valued at the **current** manufacturer rate at report time (`recon_data.dart:776-806`), while sales snapshot the rate. Raising a deposit from ₦1,500 to ₦2,000 silently restates every past "Crate deposit loss." (Same class of problem the FIFO epic explicitly rejected for costs.) The refunds figure also includes the deposit slice of refunded orders while revenue never contained it. **Fix:** snapshot the rate onto damage records; exclude `crateDepositPaidKobo` from refund accumulation.

**C4 — Point-in-time, business-wide crate cards inside store-scoped, period-scoped reports.** The recon crates card and Business-worth crate line show *today's business-wide* pool even when a store is locked and a past period is selected. **Fix:** rewind from the ledger to the bucket end (the stock card already does this) or label clearly.

### D. Dead and dangerous code (sweep list)

- **The entire pending-return approval loop is unreachable:** `createPendingReturn` has no production caller, nothing fires `'crate_short_return'`, and the approval screen is reachable only from that notification. If ever revived as-is it would: skip the pool credit, use a stream-invisible `customStatement`, check no permission, and list **other businesses' rows** (`pendingReturnsWithDetailsProvider` has no `whereBusiness` — a ban-test escapee). Wire it properly or delete it (screen, service, DAO methods, provider — the synced table can stay).
- **`recordCrateReceiveFromManufacturer` is a landmine:** writes movement `'received'`, which the `crate_ledger` CHECK (local `app_database.dart:678` and cloud) forbids — first caller gets a constraint crash. Delete it (PR #12 already learned this lesson and removed its caller).
- **`manufacturer_crate_balances` is write-only:** only the receive flow writes it (only negative deltas), nothing reads it (`watchByManufacturer` uncalled) — drifts ever more negative, synced to the cloud. Retire or maintain.
- **`crate_size_groups`** is vestigial since v28 but still synced, FK-referenced, rendered ("Crate Size Group Assets", editable, off-ledger) with no creation path; **`CrateGroup` enum** hardcodes four manufacturers with ₦-double deposits and stamps every legacy-sheet supplier `nbPlc`; **`SupplierService.addSupplier` is a stub** — the Inventory "Add New Supplier" sheet writes nothing to the DB yet logs "Supplier added." Point that sheet at the real `SupplierFormSheet` and delete the trio.
- **Cart's customer crate-credit block** reads `Customer.emptyCratesBalance` which is hardcoded `const {}` (TODO) — always ₦0. If the TODO were naively completed, the sign convention (positive = *owes*) means crate **debtors** would get checkout discounts, keyed fragilely by manufacturer *name*. Delete the block or implement deliberately.
- **`pending_crate_returns` lacks `Restore.monotonicStatus`** (its sibling approval queues got it after issue #115) — pull-order resurrection of resolved approvals remains possible.
- Minor: receipt renderers skip the business-type gate (legacy trackEmpties products print an Empty Crates section for non-crate businesses); fractional bottle quantities truncate between cart (double) and `order_crate_lines` (int); the deposit-entry field has no cap against rate×crates; the cart deposit card counts manufacturer-less bottles that checkout can never track; `Order.crateDeposit`/`subtotal` domain fields are never populated; transfer history shows `lastUpdatedAt` instead of initiated/received dates; a recon comment references a `'+crateempty'` suffix that nothing writes.

---

## 6. Van sales (#139–#147) and crates

**What the plan says.** Van = a `stores` row (`kind='van'`); driver debited the full load-price value on load; sales don't move the balance; returns/payments/write-offs credit it; reconcile at close into unremitted cash / shortage / damage; profit booked at the store on close. **All crate handling is explicitly out of scope** — cargo shells *and* manufacturer deposit settlement — with one forward hook: "leave a crate-tab seam" on the driver profile (#146). The terminal is stripped: cash/walk-in only, no crate UI.

**Credit where due:** the deferral is at least *internally consistent*. Because the terminal is walk-in-only and `createOrder`'s crate block requires a registered customer, van sales can't accrue half-tracked crate rows by accident. Nothing corrupts; it's simply blind.

**The holes (with adjustments):**

1. **Shells leave the warehouse untracked.** Every load of bottle+trackEmpties drinks removes real crate shells from the store's world; every roadside sale may hand one to a customer; every roadside swap collects one. None of it is recorded, so the store's crate books diverge from physical reality for as long as vans run — and the van is a free channel for shell loss with no liability trail. *Adjustment:* record a per-trip **"shells out / shells back" memo count** (count only, no money, one column pair on the trip) even in v1 — it's cheap, it doesn't need the full crate pass, and it preserves the data.
2. **Reconciliation is structurally blind to crates.** `shortage = loaded − sold − good returns − damaged`, all in *drink units*. A driver who remits every naira but returns without 40 shells closes at balance 0 — "zero = settled" (story 23) is false for exactly the businesses this app serves. *Adjustment:* when the crate pass lands, extend the pure `computeVanTripPosition` with shell counts valued at the manufacturer deposit rate; for v1, surface the memo count at close so the manager sees "loaded with 120 shells, 80 came back" before signing off.
3. **The walk-in blind spot becomes load-bearing.** All van customers are walk-ins, so the unresolved §3.14–3.16 walk-in exchange question (B4) is no longer an edge case — it's the *entire van channel*. Resolve it before the crate pass, not after.
4. **Deposit money on the road is off-book both directions.** No deposit can be charged (driver absorbs shell loss or charges informally, like the off-book markup), and a customer who paid a deposit at the store can't return empties to a passing van. *Adjustment:* state the v1 operating rule in the PRD and terminal copy — "van sales are empties-exchange only; no deposit sales on the road" — so drivers and managers share one expectation.
5. **Damaged van returns lose the shell forever.** #143 routes damage through "the existing damage-adjustment pattern," but that pattern's crate-awareness depends on crate records the van doesn't keep — a crate smashed on the road books only the drink loss. *Adjustment:* add a nullable `crate_shells` column to `van_return_events` **now** (write-only, no UI) so the later pass can backfill liability instead of losing history.
6. **The deferral has no backlog anchor.** The only trace of the future crate pass is one sentence in #146; there is no "Van Sales v2: crate cargo + deposits" issue (verified: zero open crate-related issues besides the van set itself). Deferrals without an issue tend to become permanent. *Adjustment:* file it and cross-link from #139 before flipping labels.
7. **Manufacturer deposit settlement is unmodeled app-wide** — the PRD itself concedes it. Customer deposits accumulate as held liabilities with no outflow leg; vans will multiply crates in circulation while the money loop stays open at both ends. *Adjustment:* scope manufacturer settlement as its own small PRD, sequenced before or with the van crate pass. The supplier `depositPaidKobo` pattern is the template — but fix B3 first so there's one supplier book to extend.
8. **The spec everyone cites doesn't exist.** All nine issues and every on-hold comment point to `docs/design/van-sales-spec.md` ("the complete edge-case list") — the file is in no working tree, no commit, no branch. An agent resuming at #140 has no access to the reconciliation math the ACs assume. *Adjustment:* recreate it from PRD #139 + the grilling memory and commit it before any label flips.
9. **Two interface details to decide up front:** (a) #141 reuses the transfer flow for loads — the existing dispatch dialog *offers "Empty crates to send"* for eligible products; decide whether van loads suppress that affordance (v1-consistent) or embrace it as the shells-out memo. (b) #147's rollup should name its fields so a deposits-held column can be added additively later, and the driver profile's "crate-tab seam" needs a defined data source (per-trip shell memos would do).

---

## 7. Alternatives — how to fix the foundation

**Alternative 1 (recommended): ledger-as-truth, wallet-style.** The wallet ledger already proves the pattern in this codebase: append-only rows, balances derived on read, nothing pushed as an absolute. Apply it to crates: keep `crate_ledger` + `supplier_crate_ledger` as the only written truth; make every balance a `SUM(quantity_delta)` view (or a cache rebuilt from the ledger after every pull); make `manufacturers.emptyCrateStock` derived-or-deleted (business total = Σ store balances = Σ store-stamped ledger rows). This dissolves B1 and B2 *by construction* — there is nothing to drift — and makes `verifyCrateReconciliation` unnecessary rather than un-called. Cost: the pool paths must always write ledger rows (they already do when a store is locked; A/B fixes close the null-store and manual-set gaps), plus one rebuild step in the pull path.

**Alternative 2 (smaller): server-authoritative deltas.** Keep the caches but stop pushing absolutes: extend `pos_record_crate_return` to cover issues too, turn the domain-RPC flags on, and let the server apply `balance += delta` idempotently (the RPC already replay-detects on ledger id). Add a post-pull rehydration of caches from ledger sums as the healing pass. Less churn than Alt 1, but keeps two representations alive.

**Alternative 3 (minimum viable honesty):** keep the architecture; fix only the write-path asymmetries (one `CratePoolDao` seam below), schedule `verifyCrateReconciliation` after every pull with auto-heal (cache := ledger sum) and `error_logs` instead of `print`. Least work, least protection.

**Regardless of the alternative, do these:**

- **One pool API.** A single `CratePoolDao` with `credit / debit / setAbsolute / transfer`, each writing *ledger row + store balance + business counter* (or derived total) in one transaction — and route **every** surface through it: `addEmptyCrates`, `recordCrateReturnByManufacturer`, the supplier "Returned" path, `updateManufacturerStock`, damages, transfers. That single seam eliminates B1, the off-ledger manual sets, and the null-store ledger gaps in one move, and gives the future van crate pass one function to call.
- **One supplier story.** Receive Stock posts the supplier crate legs itself (received = bottle-line quantities; returned = the empties inputs) in its existing transaction; the manual sheet remains for out-of-band moves; deposit cash posts a supplier-ledger leg. One physical event, one entry.
- **Idempotent, gated Confirm** (A3) and the **A1 cancel fix** — these are the two active money leaks.
- **Same-time exchange at checkout** (B4) — one "empties received now" field solves walk-ins, swap customers, and pre-answers the van question.
- **Dead-code sweep** (§5D) — most of it is deletion, and each item is a future bug someone will "finish."

---

## 8. What's genuinely solid

Worth saying explicitly, because it should survive any refactor: the **two-track decision** (money settles in money, crates settle in crates — never both, no phantom credits at Confirm); the **rate snapshot** on `order_crate_lines`; the **held-deposit wallet family** with the Held = Taken − Refunded − Kept identity and a report that proves it; **§17.2 damage fates** with a genuinely correct no-double-count argument (P&L flow vs pool stock); the **v2 envelope hold + local-only reversal** of rejected sales (including the sophisticated insight that the LWW cache must be compensated locally, never enqueued); the **bottle+trackEmpties basis** used identically at cart, DAO, and modal; per-store balances with a **guarded transfer RPC**; and the **legacy deposit allocation** fallback so pre-v37 held deposits can still settle to zero. The problem is not the design ideas — it's that half the write paths don't honor them.

## 9. Suggested fix order

| # | Fix | Why first |
|---|---|---|
| 1 | A1 cancel reversal + deposit-family reversal | Active money/books corruption on a common action |
| 2 | A2 blank-field default + A3 gate/idempotent Confirm | Active till-cash leak, fraud vector |
| 3 | A5 `isCEO` gate + Add-mode + single deposit field | Trivial fixes, real fraud surface |
| 4 | B1/B3 via the `CratePoolDao` seam + Receive↔supplier wiring | Stops the monotonic drift everything else sits on |
| 5 | B2 (pick Alternative 1 or 2) + retire dead reconciler | Multi-device correctness |
| 6 | A4/C1–C4 reporting corrections | Owner-facing truth |
| 7 | B4 walk-in exchange decision + checkout field | Unblocks van-sales crate story |
| 8 | §5D dead-code sweep | Hygiene, prevents "finishing" landmines |
| 9 | Van-sales pre-resume checklist (§6: spec recreate, v2 issue, shell memo columns, terminal copy) | Before any label flips to ready-for-agent |
