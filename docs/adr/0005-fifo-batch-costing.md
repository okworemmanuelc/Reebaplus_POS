# FIFO batch costing: per-batch cost, server-authoritative consumption by sale timestamp

**Status:** accepted (2026-07-04) — implementation is its own epic, sequenced
after the first-run onboarding redesign (ADR 0006). Nothing in this ADR ships
with the onboarding work; the design is recorded now because the decisions were
made now.

Profit accuracy across price changes cannot be delivered by a single mutable
`Products.buyingPriceKobo`: when two batches at different costs sit on the
shelf at once, the next sale is costed at replacement cost, not at the cost of
the units actually leaving. We adopt **true FIFO batch costing**. Cost becomes
a queue of **Cost Batches** per (product, store) — `{qty, costKobo,
receivedAt}` — pushed by Receive Stock (and by Add Product's opening stock),
drawn down oldest-first as sales happen. Each sale line's COGS snapshot
(`OrderItems.buyingPriceKobo`, which already locks sold history — that part of
the model is unchanged) is the weighted cost of whichever batch(es) FIFO says
the units came from, including partial-batch splits spanning two or more
batches. **Selling price is untouched**: one current value per product,
applied to every sale regardless of batch — margin shifts automatically as
FIFO crosses a batch boundary, with no decision at the point of sale and no
change to the sale screens. The product's scalar `buyingPriceKobo` is kept as
a **derived display cache** (cost of the oldest remaining batch) because of
its many read sites; the batch queue is the source of truth. **Migration:**
every existing product's current stock becomes one opening batch per
(product, store) at its existing scalar cost — zero-cost stock becomes an
*uncosted* batch.

**Sync model — server-authoritative consumption.** Multi-till offline sales
are the flagship scenario, and device-local FIFO drifts permanently there
(both tills consume the same "oldest batch" from their local queue copy). So
the server owns the batch queue, extending the existing server-minted
`domain:pos_inventory_delta_v2` seam — quantity conflicts are **already
resolved** by that seam; this epic only adds *"which batch paid for it"* to
movements that are already ordered and quantified, and must not reopen
stock-conflict resolution. Rules:

- **Ordering key is the sale's own recorded timestamp, not server arrival.**
  Arrival order is a function of network timing; a till offline longer than
  another would otherwise lose its rightful claim to the cheaper batch. The
  timestamp is the same field period attribution already preserves. True ties
  are a non-issue — either order is defensible.
- **Offline devices snapshot a provisional COGS** from their local queue view;
  on sync the server re-derives the authoritative consumption and corrects the
  line's snapshot, flowing down as an ordinary LWW row update. Profit is
  provisional until synced.
- **Late arrivals cascade.** An earlier-timestamped sale arriving late has
  first claim, so the server must be able to **replay** a (product, store)'s
  consumption from the timestamp-ordered movement ledger and re-assign
  already-corrected lines. Batch consumption is derived, recomputable state;
  assignments are stable only until an earlier-timestamped sale arrives.
- **Machine corrections are audited, not prompted:** one rolled-up Activity
  Log row per sync batch ("3 sales of Star 60cl re-costed on sync
  (batch-boundary reconciliation)"). Silent rewrites of committed profit
  numbers are the "vanishing trust" failure; prompting on every multi-till
  sync would be noise. Log, quietly, always.
- **Drift is bounded, not "small":** the bound scales with offline duration ×
  batch-cost spread. Small is the common case, not a guarantee.
- **Device clock skew is accepted risk** — the same trust baseline as the
  app's existing LWW conflict resolution and UUIDv7 ids; FIFO adds no new
  clock exposure.

**Cost backfill (prompted, explicit).** A batch with cost 0 is an *uncosted*
batch; sales drawing from it snapshot 0 and are transparently excluded from
COGS (existing "uncosted items" reporting). When a product/batch's cost
transitions **0 → first real value**, an explicit prompt offers to backfill
the specific lines that drew from that batch ("You sold 37 units before
recording a cost. Apply ₦500 to those past sales?"). Rules: fills gaps only
(never overwrites a non-zero snapshot); each line keeps its own sale date
(restated profit lands in the original period); fires once per batch; writes
an Activity Log row. Quick Sale lines (no product) stay uncosted. A
migration-era fallback applies the same prompt to pre-FIFO uncosted order
lines, which drew from no batch.

## Considered Options

- **Keep snapshot-only (status quo)** — rejected: sold history is already
  immutable (order-line snapshots), but concurrent batches at different costs
  mis-cost every sale until the scalar is manually updated, and a stale scalar
  (user defers the update) overstates or understates profit for the whole
  window with no remedy.
- **Weighted Average Cost (WAC)** — rejected after initially being
  recommended: one blended scalar, trivial to build, LWW-safe — but the owner
  wants to *watch* margin change as a cheaper batch runs out, and WAC can
  never attribute a sale to a batch. Superseded by FIFO once its sync model
  was settled.
- **Device-local FIFO, accept drift** — rejected: permanently wrong COGS and
  queue state on multi-till businesses, which is the product's core promise.
- **Server arrival order as the FIFO key** — rejected: makes cost assignment
  a function of connectivity; the till that phones home first steals the
  cheaper batch from a chronologically earlier offline sale. Default behavior,
  not an edge case, in patchy-connectivity businesses.
- **A date-bounded manual "restate this window" tool** (for stale-but-nonzero
  cost windows) — rejected: without batch ground truth it manufactures false
  precision and rewrites genuine snapshots; FIFO removes the need by making
  receive-time cost entry the single habit that matters.
- **Silent live fallback at report time** (value uncosted lines at current
  cost, no write) — rejected: restates history with a moving number, no
  consent, no audit; the "uncosted" indicator would vanish without the user
  ever deciding anything.
