# Brief: Live-sync signal, offline-first integrity, and exactly-once writes

**Status:** proposal (investigation complete 2026-07-07) — investigate → document →
propose. No production code in this pass.
**Author context:** follows `brief-sync-data-safety-and-efficiency.md` and the
2026-07-07 "deleted product still sellable" realtime investigation (see
`progress-tracker.md` → Live cross-device sync).

---

## 1. Problem statement

Two cashiers run the same store on two devices against the same stock. When a change
is made on one till (a sale, a price edit, a stock adjustment, a soft-delete from the
web console), the other till does not learn about it live — `postgres_changes` realtime
never delivers (root cause deferred, §3). PR #98/#99 wired the documented periodic
fallback pull onto the 30 s sync tick, so an **online, foregrounded** till now converges
within one poll interval. But 30 s is too slow for a shared-stock business, and — the
load-bearing point — **fast convergence only makes a conflict _visible_ sooner; it does
not _prevent_ a duplicate.**

The concrete failure the business feels:

> Stock of a product is **1**. Till A and Till B both sell it while briefly out of sync.
> Each device runs its **local** stock guard (`inventory.quantity >= qty`), both pass,
> both decrement to 0, both push the **absolute** `inventory.quantity = 0` row. Last-
> write-wins keeps one; the cloud reads **0** on hand, yet **2 units were sold from 1**.
> No error is raised anywhere. The oversell is silent.

The same shape — "false double-application of an operation already committed elsewhere" —
applies to any write that reads-modifies-writes a **mutable balance**: on-hand stock is
the exposed one today. (Money ledgers are already immune; see §2.) A staleness window
turns into lost money and lost stock accountability, not just a late refresh.

**What "solved" means:** a duplicated or concurrent application of an already-committed
economic operation cannot silently corrupt a balance. Where prevention is physically
impossible (two devices offline at once), the conflict must be **detected and surfaced**,
never silently absorbed.

---

## 2. Current architecture (as-found)

Grounded in `architecture.md` and verified against the code. **Offline-first invariant
(architecture.md #1, #4, #12):** Drift is the source of truth for the running app; every
cloud write goes through the `sync_queue` outbox; a row with an unconfirmed outbox entry
is inviolable. Any change below must preserve all three.

### 2.1 IDs and push idempotency — already correct
- Every synced row carries a **client-generated `UuidV7`** minted at creation
  (`UuidV7.generate()` across `lib/core/database/daos_*.dart`; e.g. `daos_orders.dart:512`
  mints the order id and comments "The id is the server's idempotency key").
- Push is **`upsert(onConflict: <PK|natural key>)`** (`supabase_cloud_transport.dart:32-41`;
  engine `supabase_sync_service.dart:946-955`). Null `onConflict` → PostgREST defaults to
  the primary key. **A row is cleared from the outbox only after the upsert confirms**
  (`markDoneBatch`, `supabase_sync_service.dart:969`).
- ⇒ **Single-device retry is already exactly-once.** A lost ack (server committed, network
  dropped before reply) re-pushes the *same UUID* → `ON CONFLICT (id) DO UPDATE` → no
  duplicate row. Architecture §"Ordering & idempotency" holds.

### 2.2 The gap: on-hand stock is a mutable balance, LWW-merged
- Checkout decrements **in place**: `UPDATE inventory SET quantity = quantity - ?
  WHERE … AND quantity >= ?` with a **local-only** guard (`daos_orders.dart:539-557`).
- It then enqueues the **absolute** inventory row for push:
  `enqueueUpsert('inventory', invRow)` (`daos_orders.dart:912-926`, and `:1180`,
  `daos_inventory.dart:395`, `daos_catalog.dart:269`).
- `inventory` restore is **`Restore.naturalKey`** on `(business_id, product_id, store_id)`
  with `isCache: true` (`sync_registry.dart:652-665`, flag doc `:127`), i.e. an
  **LWW balance cache**, not a value derived from a ledger.
- A parallel append-only ledger **does** exist — `stock_transactions.quantity_delta`
  (`daos_orders.dart:759-766`) — but the *authoritative on-hand* is the mutable cache,
  **not** `SUM(quantity_delta)`. So the ledger records the truth while the cache silently
  loses one of two concurrent decrements.

### 2.3 Money ledgers are already immune (the model to copy)
- `architecture.md` #3: wallet & supplier ledgers are **append-only**; balances are
  **derived by summing rows**, never stored mutable. `CONTEXT.md` "Outbox"/"Sale" confirm.
- Two concurrent wallet legs both survive (append-only, id-keyed `Restore.dedup`/`.ledger`)
  and the balance recomputes correctly. **Inventory is the one economic quantity that did
  not get this treatment.**

### 2.4 A server-authoritative, oversell-safe path already exists — but is off/late
- `pos_record_sale_v2` (migrations `0011_domain_rpcs_v2.sql`, `0014`, `0017`) does it right:
  order insert `ON CONFLICT (id) DO NOTHING` (idempotency key `p_order_id`,
  `0011:162`); stock via `SELECT … FOR UPDATE` then **relative** `UPDATE inventory SET
  quantity = quantity - n WHERE … AND quantity >= n RETURNING quantity`, raising
  `insufficient_stock` / `inventory_row_missing` on shortfall (`0011:241-254`, `0017`).
- **But the feature flag `feature.domain_rpcs_v2.record_sale` defaults to `'false'`**
  (`0011:1368`; `0091` comment "RPC is currently OFF"; checkout reads it at
  `daos_orders.dart:514-517`). ⇒ **The live mobile path is v1: client-direct absolute-
  `quantity` LWW upsert with no server atomicity.**
- Even with the flag ON, the RPC runs at **push time** (an enqueued `domain:` intent),
  not at checkout — so for two *offline* tills it can only *reject* the second sale when
  its push lands, not prevent it at the till.
- The **web** client's `checkout_order` RPC (`0135_checkout_order.sql:370-381,414-435`)
  already uses the same `FOR UPDATE` + relative-decrement + `quantity >= qty` guard, so
  web-vs-web and web-vs-online-mobile are already serialized correctly. The exposure is
  **offline mobile ↔ offline mobile**, and **mobile v1 ↔ anything**.

### 2.5 Live-signal layer (as-found)
- Realtime is **one channel, one `postgres_changes` binding per synced table**, filtered
  on `business_id` (`id` for `businesses`), with a forced `realtime.setAuth` before
  subscribe (`supabase_cloud_transport.dart:177-247`, PRs #95/#96/#97, now on `main`).
- The join is **rejected server-side with no CDC delivered** even though the socket is
  authed (`socketAlreadyHadSessionToken=true`), all tables are in the publication, grants
  and the filter-check pass, and slots are not exhausted. Errors surface as
  `channelError → timedOut` in the subscribe callback (`:235-245`). **Root cause open;
  deprecated path (§3 non-goal).**
- Pull transport: cursor-paginated PostgREST ordered by `(last_updated_at, id)`
  (`supabase_cloud_transport.dart:67-137`); cursor advances only after a page commits
  (architecture #10).
- Convergence today rides on `catchUpPull` (`supabase_sync_service.dart:1990-2007`):
  silent, 20 s-debounced, guarded on business-bound + online + not-mid-full-pull, does
  `pushThenPull`. Triggered by reconnect (`:363`), app-resume (`auto_lock_wrapper`), and
  the **30 s periodic tick** (`_autoPushPeriodicInterval`, `:151`; tick `:3317-3344`).
  Duplicate/overlapping pulls are safe: the debounce + `_fullPullRunning` guard + idempotent
  upserts + cursor-never-skips make a re-pull a no-op.

---

## 3. Goals / non-goals

**Goals**
1. A concurrent or duplicated application of an already-committed operation **cannot
   silently corrupt a balance** — above all, cannot silently oversell stock.
2. Where prevention is impossible (both tills offline), the conflict is **detected and
   surfaced** (an orphan/notification), never absorbed silently.
3. Reduce the live-convergence window from ~30 s toward near-instant **without** making
   realtime the data transport (architecture #1 / Realtime = signal).
4. Preserve offline-first behaviour **identically**: Drift stays the source of truth; the
   selling loop still works fully offline; the live layer never writes to Drift.

**Non-goals**
- **Debugging `postgres_changes`.** It is the deprecated path; we route around it. If it
  starts working it is a bonus signal, not a dependency.
- Replacing the periodic pull (it stays as the safety net, Workstream C).
- Changing the money-ledger model (already append-only/derived and correct).
- Any offline guarantee of *prevention* for two simultaneously-offline tills — physically
  impossible; scope is detect-and-surface.
- Web client changes (its `checkout_order` guard is already correct).

---

## 4. Proposed design — three separable, sequenced workstreams

> Keep these as **three distinct issues / branches / PRs** (git-issue-workflow, "no
> entanglement"). Each ships and is reviewed independently. Sequencing in §5.
> Tracked as **#100 (A — integrity)**, **#101 (B — Broadcast)**, **#102 (C — periodic pull)**.

### Workstream A — Exactly-once integrity (foundation; ship FIRST)

The load-bearing work. Independent of the live-signal layer.

**A1. Make on-hand stock convergence-safe (the core fix).** Choose ONE of:
- **A1-flag (fast, low-risk, recommended first step):** flip
  `feature.domain_rpcs_v2.record_sale` to `'true'` so mobile checkout routes through
  `pos_record_sale_v2` — server-side `FOR UPDATE` + **relative** decrement + `quantity
  >= n` guard + `ON CONFLICT (id) DO NOTHING`. This converts a silent LWW overwrite into
  a **serialized relative decrement with a hard rejection** at push time. Requires: verify
  the RPC against current schema, verify `_applyDomainResponse` writes back authoritative
  `inventory_after`, and confirm the rejection path orphans visibly (Sync Issues) rather
  than vanishing. *This is the single highest-value change and may be nearly all of A1.*
- **A1-ledger (structural, larger):** stop pushing the absolute `inventory` cache; make
  on-hand **derived** from `stock_transactions` (append-only, id-keyed) the way wallets
  derive from their ledger — cloud computes `quantity` from `SUM(quantity_delta)` (trigger
  or view + snapshot), and the client cache becomes a pure local read-model. Removes the
  mutable-balance race at the root and matches invariant #3's spirit, at the cost of a
  larger migration and a read-performance/snapshot question (§6, §8).

  *Recommendation:* ship **A1-flag** first (it closes the silent-oversell hole with an
  existing, tested RPC), then evaluate A1-ledger as a follow-up hardening once measured.

**A2. Audit every other mutable-balance push for the same shape.** The crate balance
caches (`*_crate_balances`, also `isCache`) and any other read-modify-write of a pushed
absolute value. Confirm each is either (a) already ledger-derived, or (b) protected by a
server-side relative/guarded write. Document the verdict per table; fix only genuine gaps.

**A3. Confirm and lock the idempotency backstops (mostly assertion, not new code).**
- Every synced write already mints a client UUID and pushes `upsert(onConflict: id)` — add
  a test that asserts this holds for all `SyncedTable` entries (no blind `insert`).
- Pull merge already matches on stable id / natural key (`Restore.plain`/`.naturalKey`);
  add a test that no restore path blind-inserts a row the device authored (Invariant #12
  clobber-guard already enforces the pending case).
- Events vs. derived state: assert the append-only ledgers (`stock_transactions`,
  `wallet_transactions`, `supplier_ledger_entries`, crate ledgers) are the truth and the
  balances (`inventory`, `*_crate_balances`) are caches — so reprocessing an event (retry,
  pull, broadcast) is a no-op, never a second decrement.

**Deliverable of A:** oversell is impossible-to-silently-absorb; a genuinely concurrent
offline oversell surfaces as a visible orphan/notification. No dependency on B.

### Workstream B — Broadcast live-signal layer (built ON A)

Replace the failing `postgres_changes` signal with Supabase **Broadcast**. Broadcast never
carries the data and never writes Drift — it only nudges the sync engine to pull.

- **B1. One generic trigger function** referencing `TG_TABLE_NAME`, attached to every
  Drift-synced table (`kSyncPullOrder`) via a **migration loop**, calling `realtime.send()`
  / `realtime.broadcast_changes()` with a **minimal payload**: `{table, id, op}`. No row
  data — the client's response to any message is the same (pull + reconcile).
- **B2. One topic per store/tenant** (`topic:store_<id>` or `tenant_<business_id>`), not
  one per table. Target: 55 subscriptions → **1 channel per store**.
- **B3. One RLS authorization policy** on `realtime.messages` scoped per tenant (Broadcast
  requires Realtime Authorization / private channels).
- **B4. Client:** subscribe to the single tenant channel; **any** message → debounced
  `catchUpPull(reason: 'broadcast')` (reuse the existing 20 s debounce so a burst collapses
  to one pull). Add `startBroadcast`/`stopBroadcast` to the `CloudTransport` seam (ADR 0001)
  with an `InMemoryCloudTransport` fake, mirroring the realtime lifecycle already there.
- **B5. Verify the hypothesis:** Broadcast uses a different auth/delivery path than
  `postgres_changes` (it does not go through the CDC/`subscription_check_filters`
  authorization that is currently refusing the join). **This MUST be proven on-device
  before committing** — a spike that subscribes to a tenant topic and confirms a
  trigger-emitted message arrives. If it also fails, fall back to Workstream C tuning.

- **B6. Cross-client / all-devices reach.** The emitter is a **Postgres trigger in the
  shared schema** (`CONTEXT.md`: the two clients share "one database schema and one RPC
  write-contract"). It is **writer-agnostic** — it fires on the row write regardless of
  whether the change came from the mobile outbox push (PostgREST upsert), the web
  `checkout_order`/RPC path, or the console. So **every device's change emits one
  broadcast to the tenant topic, and every subscriber on that topic receives it** —
  mobile ↔ mobile, web ↔ mobile, console → both. Emission is universal because it lives in
  the DB. **Reception is per-client**, and the two clients react differently to the *same*
  message: the **mobile** app treats it as a signal → `catchUpPull` (reconcile into Drift);
  the **web** app (online-first, no Drift) treats it as a signal → refetch/invalidate its
  live query. This B builds the shared trigger + the mobile subscriber; wiring the web
  client's subscribe to the same topic is a **separate web-scoped slice** (it may keep or
  replace its current `postgres_changes` usage) — same topic, same payload, different
  reaction. Nothing about B is mobile-only on the emit side.

**Non-negotiable (restated):** Broadcast is ephemeral, no replay. A device offline / asleep /
backgrounded during a change simply misses the message; **the pull-on-reconnect and the
periodic pull (C) recover it.** Both facts must hold in the design and the tests. (The web
client, being online-first, has no offline-replay concern — a missed message is recovered
by its next query, not a pull.)

### Workstream C — Retain periodic pull as the safety net

Already shipped (#98/#99) — keep it, and treat it as the reconnect-replay backstop that
makes B's "no replay" acceptable. The only open decision is **cadence** (§6 trade-off):
leave at 30 s once B lands (B gives near-instant, C just backstops), or tighten toward
10 s if B is delayed or fails verification. C must never be removed while B is the primary
signal.

---

## 5. Why this order

**Correctness before speed.** Broadcast without idempotency just spreads duplicates
faster: a near-instant signal that fans a stale read into two concurrent mutable-balance
writes makes oversell *more* likely, not less. A must land first so that when B compresses
the convergence window, every write it accelerates is already safe to reprocess. C already
exists and de-risks B's no-replay property, so B can be built and verified without fear of
missed messages. Hence **A → (C stays) → B**, with B gated on the §B5 on-device proof.

---

## 6. Trade-offs

| Decision | Option chosen | Alternative | Why |
|---|---|---|---|
| Live signal | **Broadcast** (1 topic/store, generic trigger, RLS) | Tighten poll to ~10 s | Broadcast is near-instant and 55→1 subscriptions, but adds triggers + RLS + migration maintenance and an **unproven** rejection-sidestep. Polling is zero new infra and always works, but never instant and 3× the idle pull traffic. Broadcast is the target **because §B5 can be proven cheaply**; if it fails, 10 s poll is the honest fallback. |
| Stock model | **A1-flag first** (server RPC relative decrement) | A1-ledger (derive on-hand from `stock_transactions`) | Flag reuses an existing, tested, oversell-safe RPC and closes the silent hole in one migration+verify. Ledger-derived is structurally immune (matches invariant #3) but is a bigger migration with a read-performance/snapshot question — do it as measured follow-up, not the first move. |
| Offline oversell | **Detect-and-surface** (server rejection → visible orphan) | Attempt prevention | Two simultaneously-offline tills cannot be prevented from both selling the last unit; pretending otherwise is dishonest. Surfacing beats silently absorbing. |

---

## 7. Migration plan (table-by-table, reversible where possible, no big-bang)

- **A1-flag:** one config change (`feature.domain_rpcs_v2.record_sale` → `'true'`), fully
  reversible (flip back). Verify `pos_record_sale_v2` against the current schema *before*
  flipping; roll out behind the existing flag so it is per-environment. No schema change.
- **A1-ledger (if pursued):** additive migration — cloud trigger/view deriving
  `inventory.quantity` from `stock_transactions`; keep the cache column, stop *pushing* it
  from the client (registry change removing `inventory` from the pushed set) only after the
  derive path is verified. Land the derive migration first, verify, then change the client
  push — never both in one step (ai-workflow-rules "split work").
- **B (broadcast):** additive and reversible per table — the generic trigger + RLS policy
  ship in one migration; attaching it via a loop over `kSyncPullOrder` means adding a
  synced table stays "one registry entry" (architecture §SyncedTable registry). Client
  broadcast subscribe ships behind a flag so it can be disabled without a migration
  rollback. Dropping the triggers restores the pre-B state.
- **Migration numbering:** next free is **0147+** (highest committed is `0146`). Allocate
  per-PR at merge time to avoid cross-branch collision (git-issue-workflow §4).

---

## 8. Risks & open questions

1. **Does Broadcast actually join where `postgres_changes` was refused?** (§B5). The whole
   of B rests on this. **Must be proven on-device before committing** — if Broadcast shares
   the same refused authorization path, B is dead and C-tuning is the answer.
2. **A1-flag readiness of `pos_record_sale_v2`.** The RPC has been off since it was written;
   verify it against schema drift (columns, `location_id` vs `store_id`/`warehouse_id`
   naming seen in 0011 vs current), and that `_applyDomainResponse` correctly writes back
   `inventory_after` and mints no local duplicates. Open: does flipping the flag change any
   *other* behaviour (crate/wallet legs already run on both paths per `daos_orders.dart`
   comments — confirm).
3. **Event-log read performance at scale (A1-ledger).** Deriving on-hand from
   `SUM(quantity_delta)` needs snapshotting/materialization for large histories — an open
   design question, and a reason to prefer A1-flag first.
4. **Orphan UX for a surfaced oversell.** When the server rejects the second offline sale,
   what does the cashier see and what's the recovery (re-price? refund? restock)? Needs a
   product decision — the mechanism (visible orphan) exists; the human flow does not.
5. **Broadcast trigger write-amplification.** A generic AFTER trigger on every synced table
   fires on every write including sync-applied pulls — ensure it does not echo (e.g. skip
   when the writer is the sync path) to avoid pull→broadcast→pull loops.
6. **RLS on `realtime.messages`** must be exactly per-tenant or a tenant could receive
   another business's nudges (harmless payload, but a cross-tenant signal leak and an
   invariant #5 smell). One policy, tested.

---

## 9. Test plan

Covers the four named scenarios plus the invariants each workstream must not break.

- **Lost-ack retry (A, exists-mostly):** server commits the sale, ack is dropped before
  reply; the row re-pushes the same UUID → `ON CONFLICT (id) DO NOTHING/UPDATE` → exactly
  one row, correct balance. Assert no duplicate `orders`/`order_items`/`stock_transactions`.
- **Offline-then-reconnect reconciliation (A + C):** till goes offline, sells, reconnects;
  `catchUpPull` pushes then pulls; balances converge; no double-decrement on the pull that
  reflects the till's own just-pushed sale (event reprocessing is a no-op).
- **Two devices race the last unit (A, the headline):**
  - *v2/server path:* both offline sales sync; the second `pos_record_sale_v2` raises
    `insufficient_stock`; that row **orphans visibly**; on-hand never goes below 0 silently;
    the ledger shows exactly the movements that were accepted.
  - *regression guard:* a test that the v1 absolute-LWW path (if still reachable) is either
    removed from the sell path or explicitly flagged, so the silent-oversell case cannot
    regress unnoticed.
- **Duplicate pulls from a broadcast burst (B + C):** N broadcast messages in a tick →
  exactly one debounced `catchUpPull`; the pull is idempotent; the cursor never skips;
  Drift ends identical to a single-pull run.
- **Broadcast never writes Drift (B):** assert the broadcast callback's only effect is to
  schedule a pull — no direct row write — so offline-first behaviour is byte-identical with
  broadcast on or off.
- **Offline/asleep misses a message, pull recovers it (B + C):** deliver a change while the
  device is "backgrounded" (no broadcast received); the next periodic/reconnect pull
  converges it — proving no dependency on broadcast replay.

---

## Appendix — investigation source map (file:line)

- IDs client-minted: `daos_orders.dart:512`; `UuidV7.generate()` throughout `daos_*.dart`.
- Push idempotent upsert: `supabase_cloud_transport.dart:32-47`; engine `:946-969`.
- Stock mutable-balance decrement + local guard: `daos_orders.dart:539-557`.
- Inventory pushed as absolute cache: `daos_orders.dart:912-926,1180`;
  `daos_inventory.dart:395`; `daos_catalog.dart:269`.
- Inventory LWW natural-key cache: `sync_registry.dart:127,652-665`.
- Append-only stock ledger: `daos_orders.dart:759-766` (`stock_transactions.quantity_delta`).
- Server-authoritative oversell-safe sale RPC (flag-off): `0011_domain_rpcs_v2.sql:162,241-254`;
  `0017_distinguish_missing_inventory_from_insufficient.sql`; flag default `'false'`
  `0011:1368`; read `daos_orders.dart:514-517`.
- Web guard (live): `0135_checkout_order.sql:370-381,414-435`.
- Realtime one-channel/N-bindings + setAuth + open root cause:
  `supabase_cloud_transport.dart:177-247`.
- Pull path + cursor: `supabase_cloud_transport.dart:67-137`; `catchUpPull`
  `supabase_sync_service.dart:1990-2007`; periodic tick `:3317-3344`; interval `:151`.
- No Broadcast infra yet: no `realtime.send`/`broadcast_changes` in `supabase/migrations/`.
</content>
