-- 0169_flag_gated_rpc_money_parity.sql
--
-- #201 / PRD #155 close-out — BRING THE FLAG-GATED SERVER WRITE PATHS TO #155
-- PARITY. Three server-side money writers still implemented the PRE-#155 rules.
-- All three are currently unreachable (two behind held-off feature flags, one on
-- the web arm), so the divergence is LATENT — which is exactly why it is
-- dangerous: flipping a flag would silently revert rules #155 had just fixed,
-- with no code change to review.
--
-- Precedent for fixing ahead of the flag: 0091, 0160 and 0164 each patched
-- `pos_record_sale_v2` while its flag was off, "a latent landmine otherwise".
-- This migration finishes that job for the money rules themselves. The companion
-- PR also adds the "do not enable until …" notes at the two flag checks
-- (`lib/core/database/daos_orders.dart`) — comments AND parity, not comments
-- instead of parity.
--
-- ── WHAT GATES WHAT (read before enabling anything) ─────────────────────────
--   1. `pos_record_sale_v2`      ← flag `feature.domain_rpcs_v2.record_sale`
--   2. `pos_cancel_order`        ← flag `feature.domain_rpcs_v2.cancel_order`
--   3. `_apply_stock_adjustment` ← no flag: reached by the WEB RPCs
--      `request_stock_adjustment` / `approve_stock_adjustment` (0141) whenever
--      the web client calls them. Not flag-gated at all — the only one of the
--      three that a deploy makes live immediately.
-- Both v2 flags remain HELD OFF, gated on issue #121 (the oversell-orphan
-- go-live gate). This migration does not change that; it makes the flip SAFE
-- rather than silently destructive.
--
-- ── 1. pos_record_sale_v2 — the #175 three-way tender split + #169 store_id ──
--
-- BEFORE: one bundled `sale` payment row for the whole `p_amount_paid_kobo`,
-- with no `store_id`. On the v2 path the client writes NO local payment row at
-- all (`OrdersDao.createOrder` returns right after enqueueing the envelope), so
-- that cloud row is the only one — meaning a flag flip would have re-bundled
-- crate deposits and overpayments back into "Cash sales" (undoing #175) and
-- dropped the tender's store (undoing #169 US 36).
--
-- AFTER: the SQL twin of the shipped client rule (`OrdersDao.createOrder`, the
-- `_insertCheckoutPaymentRow` block). Up to THREE rows, every one carrying the
-- chosen method and the sale-level store:
--   • `sale`          = GOODS actually paid (paid − deposit, capped at the goods
--                       payable) — the only row "Cash sales" / "Total Sales" count;
--   • `crate_deposit` = the refundable deposit HELD — its own money type,
--                       excluded from Cash sales and shown as a held line;
--   • `wallet_topup`  = any OVERPAYMENT beyond goods + deposit — the customer's
--                       credit, counted as debts collected, not as a sale.
-- The three always sum to `p_amount_paid_kobo` (no cash created or destroyed),
-- and a zero leg writes no row — so a plain goods-only sale still produces
-- exactly ONE `sale` row, byte-identical to the pre-#201 behaviour.
--
-- Mapping the client's arithmetic onto the RPC's server-computed figures: the
-- client's `totalAmountKobo` is the payable INCLUDING the deposit
-- (`checkout_page._totalKobo = goods + deposit`), and this RPC's `v_net_amount`
-- (gross − discount + deposit) is the same quantity, so `goodsGrand` here is
-- `v_net_amount − depositHeld`. The RPC stays server-authoritative on totals —
-- that is its entire purpose — so the split is computed from ITS figures, not
-- from a client-sent breakdown, and it is therefore always internally consistent
-- with the `orders` row this same call writes.
--
-- ONE PRE-EXISTING DIVERGENCE, stated plainly rather than papered over. The
-- cart's goods total is `sub − discountTotal − customerCrateCredit`
-- (`cart_screen.dart`), but the envelope forwards only the per-line discount sum
-- as `p_discount_kobo` — the customer's empty-crate CREDIT is not forwarded at
-- all. So on a sale that applies a crate credit, `v_net_amount` exceeds the
-- client's payable by exactly that credit, and this split will book up to
-- `credit` more of the tender as goods `sale` and correspondingly less as
-- `wallet_topup` than the v1 path would.
--
-- That gap is NOT introduced here and is not this issue's to close: the same
-- un-forwarded credit already makes the RPC write `orders.total_amount_kobo` /
-- `net_amount_kobo` higher than the v1 mirror on such a sale (and the response
-- overwrites the local mirror with it), which is a v1/v2 envelope gap that
-- predates #175. The split follows the header it is paired with, which is the
-- only self-consistent choice available without a signature change. FILED AS A
-- FOLLOW-UP: forward the crate credit on the v2 envelope — that fixes the header
-- and this split together, in one place. Until then, treat a crate-credit sale as
-- a known v1/v2 difference on the flag-flip checklist.
--
-- The van suppression (#142/ADR 0019 decision 2, "cash follows custody") is
-- preserved and now covers all three legs: a ROAD sale writes NO payment row of
-- any type. Its money enters the books only via the manager-recorded remittance.
--
-- RESPONSE SHAPE: `payment_transaction` (singular) is retained and now carries
-- the GOODS `sale` row — so the shipped `_applyDomainResponse` handler and the
-- Tier-2 contract test keep working unchanged. A new `payment_transactions`
-- (plural) array carries ALL rows written (0..3); the companion client PR routes
-- it through `_restoreTableData` so the deposit/top-up rows land locally at once
-- instead of waiting for the next pull.
--
-- ── 2. pos_cancel_order — compensating rows, not in-place voids ─────────────
--
-- BEFORE (0011 → 0045): the cancel VOIDED each original payment row IN PLACE and
-- posted a full-amount `refund` for every one of them. Under #175's split that is
-- a DOUBLE reversal — the sale day shrinks (the void rewrites a day the owner may
-- already have reviewed and banked against) AND a cancel-day refund is posted —
-- and it mis-types a deposit collection and a top-up as `refund`, so "Cash
-- refunds" moves for money that never entered "Cash sales".
--
-- AFTER: the SQL twin of `OrdersDao.markCancelled` (#172/#175 rules; the
-- `PaymentTransactionsDao.postReversalPayment` seam):
--   • every ORIGINAL row is LEFT UNTOUCHED — no in-place void, no edit. Cash
--     reporting counts each row on its own `created_at` day, so the sale stays on
--     the sale day and the reversal lands on the CANCEL day.
--   • `sale`          → a POSITIVE `refund` cash-out for the same amount;
--   • `crate_deposit` → a NEGATIVE `crate_deposit` row, so the held-deposit line
--     nets to zero. NOT a `refund`: that would land in Cash refunds while the
--     collection was never in Cash sales, breaking the symmetry;
--   • `wallet_topup`  → a NEGATIVE `wallet_topup` row, so "Debts collected" nets
--     to zero (mirrors the top-up VOID pattern in `CreditLedgerService`).
--   • a row already of another type (a prior cancel's `refund`, a
--     `van_remittance`) is never re-reversed, and each reversal copies the
--     original's method + store so a cash tender yields a cash reversal.
-- THE RULE, stated for the golden fixtures (#206): a cancel APPENDS one
-- compensating row per reversible original, dated on the cancel day, and mutates
-- nothing. Row count after a cancel = originals + one per reversible original.
--
-- The WALLET arm gets the same treatment, which closes the R2 hold recorded at
-- the client's flag check ("until pos_cancel_order mints the wallet payment-leg
-- reversal, don't enable"): instead of compensating only the DEBIT legs (and
-- voiding them in place), every original sale leg is now reversed by an appended
-- opposite leg — the goods debit becomes a `refund` credit, the payment credit
-- becomes a `void` debit, and a held `crate_deposit` credit is released with a
-- DEPOSIT-FAMILY `crate_deposit_refunded` debit (NOT the generic `void`, which
-- lands in the SPENDABLE bucket and would both dock spendable and leave
-- "deposits held" inflated — #162). Legs that are THEMSELVES a reversal or a
-- settlement are skipped, so a cancel never reverses a compensation.
--
-- On the v2 path the client authors NONE of this (it enqueues the envelope and
-- returns), so the server is the sole writer of every compensating family and
-- `_applyDomainResponse` mirrors them from the response.
--
-- The COST QUEUE is restored here too — and that is a consequence of #187
-- landing while this issue was open. The cancel appends one fresh FIFO layer per
-- sale line at the per-unit COGS the sale snapshotted
-- (`order_items.buying_price_kobo`), the twin of the client's #170 #7c restore.
-- Before #187 the v2 path could arguably skip it: `pos_recost_product_store`
-- rebuilt `qty_remaining` from `qty_original` over the sale ledger, and a
-- cancelled order dropped out of that ledger, so the drawn units "came back" on
-- the next recost. Migration 0167 removed that write-back precisely because it
-- resurrected non-sale draws (a DOUBLE restore against the client's layer), and
-- it settled that `qty_remaining` belongs to the INCREMENTAL drawers that see
-- every outflow class. With the replay no longer restoring anything, a v2 cancel
-- that appends no layer leaves the goods back on the shelf with their cost
-- permanently drawn — phantom 0-cost stock, understated Business worth, the exact
-- defect #170 #7c fixed on the client. Exactly ONE authority restores in every
-- flag combination, because the flag picks the authority: flag OFF ⇒ the client
-- restores locally and pushes; flag ON ⇒ the client returns early and this does
-- it. Quick-sale lines (no product) are skipped — they were never batched.
--
-- ── 3. _apply_stock_adjustment — the web arm stops losing cost ──────────────
--
-- BEFORE: the web adjustment helper inserted `stock_adjustments` with NO
-- `value_kobo` / `unit_cost_kobo` and touched NO `cost_batches`, while 0140
-- already created batches for add-product / receive-stock. So a web-approved
-- Remove wrote an unvalued loss (COGS drifting to zero-cost) and a web-approved
-- Add created phantom cost-free stock that later sold at 0 COGS.
--
-- AFTER: the SQL twin of `InventoryDao.adjustStock`'s #170 #7a cost semantics,
-- for plain `adjustment` movements (which is all this helper ever performs):
--   • an INCREASE creates one fresh FIFO layer — the same rule 0140 uses
--     ({qty_remaining = qty_original = delta, cost_kobo, received_at}, never
--     merged). This helper is handed NO cost, and #189 settled what an
--     omitted-cost inflow is worth: the product's recorded scalar
--     `buying_price_kobo` (`InventoryDao._recordedUnitCostKobo`, ADR 0005), and
--     an UNCOSTED (0) layer only when the product carries no cost at all.
--     Batching an increase at 0 while a price is on file sold those units at
--     0 COGS FOREVER — #41's backfill fires only on a `0 → positive` cost edit, a
--     transition a product that already has a price can never make again.
--   • a DECREASE draws the queue down oldest-first and SNAPSHOTS what it drew
--     onto the adjustment row (`value_kobo` total, `unit_cost_kobo` =
--     round(value / |delta|)), so a later cost edit cannot restate a past loss.
--     Uncovered / uncosted units contribute 0 — "uncosted", not "free".
-- The draw-down reuses `public.fifo_assign` (0133), the SAME pure function the
-- authoritative recost replays through and the twin of the client's
-- `fifoDrawDown` — so there is one FIFO algorithm on the server, not two.
--
-- THIS ARM IS AN INCREMENTAL DRAWER, which is what makes it legal under #187 /
-- 0167: it reads `qty_remaining` (never `qty_original`), decrements exactly what
-- this one movement consumed, and replays nothing — so it can neither resurrect
-- another outflow's draw nor be resurrected by the recost pass. 0167's header
-- lists the two authorities that existed when it was written (the client DAO and
-- `_checkout_draw_fifo`, 0139); this migration adds two more of the SAME SHAPE —
-- this draw-down, and the cancel's restore in part 2 — so 0167's ownership RULE
-- ("written only by drawers that draw incrementally and see every outflow")
-- holds unchanged even though its count of them is now out of date.
--
-- Both call sites (`request_stock_adjustment` :206 manager-applies-immediately,
-- `approve_stock_adjustment` :309 approve) inherit the fix by calling this
-- helper; neither needed a change, so neither is re-declared here.
--
-- NOT mirrored: `CostBatchesDao._recomputeScalarCost` (re-pointing
-- `products.buying_price_kobo` at the oldest remaining COSTED batch after a
-- draw-down). No cloud path has ever mirrored that display cache — not the sale
-- draw-down, not the recost replay — and adding it in this one arm would create a
-- NEW asymmetry inside the cloud instead of removing one. The scalar is a cache
-- with a no-clobber rule; the mobile client re-points it on its next draw-down.
--
-- ── SIGNATURES / THE OVERLOAD TRAP ─────────────────────────────────────────
-- All three functions keep their EXACT current signatures, so each is a plain
-- CREATE OR REPLACE with no DROP and no possibility of an overload
-- (`CREATE OR REPLACE` + a new parameter would leave two candidates and
-- PostgREST answers PGRST203 — see 0164's header). Concretely:
--   • pos_record_sale_v2(uuid, uuid, uuid, text, uuid, text, jsonb, text, uuid,
--       int, int, int, text, text, text, int, bool, uuid)   — 18 args, from 0164
--   • pos_cancel_order(uuid, uuid, uuid, text)              — 4 args, from 0045
--   • _apply_stock_adjustment(uuid, uuid, uuid, int, text, uuid) — from 0141
-- The `int` money PARAMETERS on pos_record_sale_v2 are inherited from 0011 and
-- left alone here (widening them is a signature change). Every money COLUMN
-- written below is bigint, per 0130; the new locals are bigint too.
--
-- No RLS is touched. No schema change, no data rewrite — three function bodies.
--
-- DEPLOY ORDER: after 0164 (the current pos_record_sale_v2), 0163 (the widened
-- payment type CHECK that admits `crate_deposit`), 0155 (the stock_adjustments
-- cost columns), 0141 (the helper being replaced), 0133 (fifo_assign) and — for
-- the cost-queue reasoning above to hold — 0167 (#187, the recost write-back
-- removal). Nothing here depends on 0167 mechanically; the ORDER matters only
-- because deploying this cancel restore while the old replay still resurrected
-- remainders would double-restore, which is the very defect 0167 removed.
-- MIGRATION-NUMBER LANE: 0169 is #201's; 0166/0167/0168/0170 belong to siblings.

BEGIN;

-- ═══ 1. pos_record_sale_v2 — split the tender, stamp the store ══════════════
--
-- Body copied VERBATIM from 0164 (the current definition); every change is
-- marked `-- #201 delta`. No totals math, stock guard, FIFO, wallet leg, crate
-- leg, idempotency, order-numbering, catalogue-price or van-suppression
-- behaviour changes.
CREATE OR REPLACE FUNCTION public.pos_record_sale_v2(
  p_business_id             uuid,
  p_actor_id                uuid,
  p_order_id                uuid,           -- idempotency key
  p_order_number            text,
  p_store_id                uuid,
  p_payment_type            text,
  p_items                   jsonb,          -- [{product_id, quantity, unit_price_kobo, buying_price_kobo?, price_snapshot?, catalogue_price_kobo?}]
  p_status                  text DEFAULT 'completed',
  p_customer_id             uuid DEFAULT NULL,
  p_discount_kobo           int  DEFAULT 0,
  p_amount_paid_kobo        int  DEFAULT 0,
  p_crate_deposit_paid_kobo int  DEFAULT 0,
  p_rider_name              text DEFAULT 'Pick-up Order',
  p_barcode                 text DEFAULT NULL,
  p_payment_method          text DEFAULT NULL,   -- required if amount_paid > 0
  p_wallet_amount_kobo      int  DEFAULT 0,      -- portion of amount_paid drawn from wallet
  p_customer_verified       bool DEFAULT false,
  p_van_trip_id             uuid DEFAULT NULL    -- #142: the trip tag
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_total_amount       int;
  v_net_amount         int;
  v_now                timestamptz := now();
  v_inserted           bool := false;
  v_order_lua          timestamptz;
  v_order_row          jsonb;
  v_item               jsonb;
  v_item_id            uuid;
  v_total_kobo         int;
  v_existing_qty       int;
  v_new_qty            int;
  v_stx_id             uuid;
  v_inv_after          jsonb := '[]'::jsonb;
  v_order_items        jsonb := '[]'::jsonb;
  v_stock_txns         jsonb := '[]'::jsonb;
  v_payment_id         uuid;
  v_payment_row        jsonb;
  v_wallet_id          uuid;
  v_wallet_balance     int;
  v_wallet_txn_id      uuid;
  v_wallet_txn_row     jsonb;
  v_is_van_sale        bool := false;   -- #142
  v_deposit_held_kobo  bigint;                  -- #201 delta
  v_goods_grand_kobo   bigint;                  -- #201 delta
  v_goods_paid_kobo    bigint;                  -- #201 delta
  v_topup_kobo         bigint;                  -- #201 delta
  v_leg                record;                  -- #201 delta
  v_payment_rows       jsonb := '[]'::jsonb;    -- #201 delta
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  IF p_order_id IS NULL THEN
    RAISE EXCEPTION 'order_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'items_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_amount_paid_kobo > 0 AND p_payment_method IS NULL THEN
    RAISE EXCEPTION 'payment_method_required_when_paid' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_wallet_amount_kobo > 0 AND p_customer_id IS NULL THEN
    RAISE EXCEPTION 'wallet_payment_requires_customer' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- #142 — is this a ROAD sale? (ADR 0019 decision 2, spec §5.3.)
  -- Two independent signals, either of which is enough:
  --   · the STORE is a van — the physical fact, and the same thing the Flutter
  --     client keys its own suppression on (`VanTripsDao.saleContextForStore`);
  --   · the order carries a TRIP TAG — bookkeeping, forwarded by the envelope.
  -- Suppression must fail SAFE, so a sale that has either signal is stripped: a
  -- road sale that somehow lost its tag must still not write cash the business
  -- does not hold.
  v_is_van_sale := p_van_trip_id IS NOT NULL
    OR EXISTS (
      SELECT 1 FROM public.stores s
       WHERE s.id = p_store_id AND s.kind = 'van'
    );

  -- Server-computed totals.
  SELECT COALESCE(SUM((it->>'quantity')::int * (it->>'unit_price_kobo')::int), 0)
    INTO v_total_amount
    FROM jsonb_array_elements(p_items) AS it;

  v_net_amount := v_total_amount - p_discount_kobo + p_crate_deposit_paid_kobo;

  -- Idempotent order insert.
  WITH ins AS (
    INSERT INTO public.orders (
      id, business_id, order_number, customer_id,
      total_amount_kobo, discount_kobo, net_amount_kobo, amount_paid_kobo,
      payment_type, status, rider_name, barcode,
      staff_id, store_id, crate_deposit_paid_kobo,
      van_trip_id,                                                 -- #142
      completed_at, cancelled_at, created_at, last_updated_at
    )
    VALUES (
      p_order_id, p_business_id, p_order_number, p_customer_id,
      v_total_amount, p_discount_kobo, v_net_amount, p_amount_paid_kobo,
      p_payment_type, p_status, p_rider_name, p_barcode,
      p_actor_id, p_store_id, p_crate_deposit_paid_kobo,
      p_van_trip_id,                                               -- #142
      CASE WHEN p_status = 'completed' THEN v_now ELSE NULL END,
      NULL, v_now, v_now
    )
    ON CONFLICT (id) DO NOTHING
    RETURNING 1
  )
  SELECT EXISTS(SELECT 1 FROM ins) INTO v_inserted;

  IF NOT v_inserted THEN
    -- Replay path. Compose the response from existing state.
    SELECT to_jsonb(o.*), o.last_updated_at INTO v_order_row, v_order_lua
      FROM public.orders o WHERE o.id = p_order_id;

    SELECT COALESCE(jsonb_agg(to_jsonb(oi.*)), '[]'::jsonb) INTO v_order_items
      FROM public.order_items oi WHERE oi.order_id = p_order_id;

    SELECT COALESCE(jsonb_agg(to_jsonb(stx.*)), '[]'::jsonb) INTO v_stock_txns
      FROM public.stock_transactions stx WHERE stx.order_id = p_order_id;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'product_id',      i.product_id,
             'store_id',        i.store_id,
             'quantity',        i.quantity,
             'last_updated_at', i.last_updated_at)), '[]'::jsonb)
      INTO v_inv_after
      FROM public.inventory i
      WHERE i.business_id = p_business_id
        AND i.store_id    = p_store_id
        AND i.product_id IN (
          SELECT (it->>'product_id')::uuid FROM jsonb_array_elements(p_items) it
        );

    -- #201 delta — the singular key now resolves to the GOODS row (the sale may
    -- have written up to three), keeping the shipped client handler and the
    -- Tier-2 contract stable; the plural key carries the whole tender. The type
    -- ordering is the INSERT order of the fresh path below, so a replay answers
    -- with the same row the original call did — including for a deposit-only
    -- tender, which has no `sale` leg at all.
    --
    -- Both reads are `business_id`-scoped. This function is SECURITY DEFINER, so
    -- RLS is off inside it and the predicate is the only tenant boundary
    -- (architecture.md invariant #5); the pre-#201 lookup filtered on
    -- `order_id` alone, and the plural key would have widened that to every
    -- payment row on a foreign order.
    SELECT to_jsonb(pt.*) INTO v_payment_row
      FROM public.payment_transactions pt
      WHERE pt.order_id    = p_order_id
        AND pt.business_id = p_business_id
        AND pt.voided_at IS NULL
      ORDER BY CASE pt.type WHEN 'sale'          THEN 0
                            WHEN 'crate_deposit' THEN 1
                            WHEN 'wallet_topup'  THEN 2
                            ELSE 3 END,
               pt.created_at, pt.id
      LIMIT 1;

    SELECT COALESCE(jsonb_agg(to_jsonb(pt.*) ORDER BY pt.created_at, pt.id),
                    '[]'::jsonb)                                   -- #201 delta
      INTO v_payment_rows
      FROM public.payment_transactions pt
      WHERE pt.order_id    = p_order_id
        AND pt.business_id = p_business_id
        AND pt.voided_at IS NULL;

    SELECT to_jsonb(wt.*) INTO v_wallet_txn_row
      FROM public.wallet_transactions wt
      WHERE wt.order_id = p_order_id AND wt.voided_at IS NULL
      ORDER BY wt.created_at LIMIT 1;

    RETURN jsonb_build_object(
      'order',                v_order_row,
      'order_items',          v_order_items,
      'stock_transactions',   v_stock_txns,
      'payment_transaction',  v_payment_row,
      'payment_transactions', v_payment_rows,                      -- #201 delta
      'wallet_transaction',   v_wallet_txn_row,
      'inventory_after',      v_inv_after,
      'replayed',             true
    );
  END IF;

  -- Items + inventory deltas + stock_transactions.
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    IF (v_item->>'quantity')::int <= 0 THEN
      RAISE EXCEPTION 'item_quantity_must_be_positive' USING ERRCODE = 'invalid_parameter_value';
    END IF;

    v_item_id    := gen_random_uuid();
    v_total_kobo := (v_item->>'quantity')::int * (v_item->>'unit_price_kobo')::int;

    INSERT INTO public.order_items (
      id, business_id, order_id, product_id, store_id,
      quantity, unit_price_kobo, buying_price_kobo, total_kobo, price_snapshot,
      catalogue_price_kobo,                                        -- #183
      created_at, last_updated_at
    )
    VALUES (
      v_item_id, p_business_id, p_order_id,
      (v_item->>'product_id')::uuid, p_store_id,
      (v_item->>'quantity')::int,
      (v_item->>'unit_price_kobo')::int,
      COALESCE((v_item->>'buying_price_kobo')::int, 0),
      v_total_kobo,
      CASE WHEN v_item ? 'price_snapshot' THEN v_item->'price_snapshot' ELSE NULL END,
      public._catalogue_price_snapshot(                             -- #183
        (v_item->>'catalogue_price_kobo')::bigint,
        (v_item->>'unit_price_kobo')::bigint),
      v_now, v_now
    );

    v_order_items := v_order_items || to_jsonb((SELECT oi FROM public.order_items oi WHERE oi.id = v_item_id));

    -- §12.3/§26.4: a Quick Sale line has no product_id → it bypasses inventory
    -- entirely (no lock/check/deduction, no stock_transactions row).
    CONTINUE WHEN (v_item->>'product_id') IS NULL;

    -- Lock the inventory row so we can distinguish "no row exists" from
    -- "row exists but qty too low". FOR UPDATE matches the wallet pattern
    -- in 0014; concurrent sales for the same product+store serialize
    -- here.
    SELECT quantity INTO v_existing_qty
      FROM public.inventory
     WHERE business_id = p_business_id
       AND product_id  = (v_item->>'product_id')::uuid
       AND store_id    = p_store_id
     FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'inventory_row_missing'
        USING ERRCODE = 'P0001',
              HINT = jsonb_build_object(
                'product_id', v_item->>'product_id',
                'store_id',   p_store_id
              )::text;
    END IF;

    IF v_existing_qty < (v_item->>'quantity')::int THEN
      RAISE EXCEPTION 'insufficient_stock'
        USING ERRCODE = 'P0001',
              HINT = jsonb_build_object(
                'product_id',    v_item->>'product_id',
                'store_id',      p_store_id,
                'requested_qty', (v_item->>'quantity')::int,
                'available_qty', v_existing_qty
              )::text;
    END IF;

    UPDATE public.inventory
       SET quantity = quantity - (v_item->>'quantity')::int
     WHERE business_id = p_business_id
       AND product_id  = (v_item->>'product_id')::uuid
       AND store_id    = p_store_id
    RETURNING quantity INTO v_new_qty;

    v_inv_after := v_inv_after || jsonb_build_object(
      'product_id',      (v_item->>'product_id')::uuid,
      'store_id',        p_store_id,
      'quantity',        v_new_qty,
      'last_updated_at', v_now
    );

    -- Ledger row.
    v_stx_id := gen_random_uuid();
    INSERT INTO public.stock_transactions (
      id, business_id, product_id, location_id, quantity_delta, movement_type,
      order_id, performed_by, created_at, last_updated_at
    )
    VALUES (
      v_stx_id, p_business_id, (v_item->>'product_id')::uuid, p_store_id,
      -(v_item->>'quantity')::int, 'sale',
      p_order_id, p_actor_id, v_now, v_now
    );

    v_stock_txns := v_stock_txns || to_jsonb((SELECT stx FROM public.stock_transactions stx WHERE stx.id = v_stx_id));
  END LOOP;

  -- Payment (optional).
  -- #142 — NOT on the road. A van sale writes no payment row on EITHER sync
  -- path: the Flutter client skips its own three-way tender split
  -- (`OrdersDao.createOrder`) and the server skips this one. The order still
  -- records `amount_paid_kobo` — the driver really was paid — but the money is in
  -- their custody, not the business's, so it must not reach the cash books until
  -- a manager records the remittance (#144, type 'van_remittance').
  --
  -- #201 delta — the tender is SPLIT BY MONEY TYPE and store-stamped, the SQL
  -- twin of the client's `_insertCheckoutPaymentRow` block (#175 + #169 US 36):
  --   sale          = goods actually paid  (paid − deposit, capped at goods payable)
  --   crate_deposit = the refundable deposit HELD (excluded from Cash sales)
  --   wallet_topup  = the OVERPAYMENT beyond goods + deposit (debts collected)
  -- `v_net_amount` is the payable INCLUDING the deposit — the same quantity the
  -- client calls `totalAmountKobo` — so the goods payable is `v_net_amount −
  -- depositHeld`. The legs always sum to `p_amount_paid_kobo`; a zero leg writes
  -- no row, so a goods-only sale still writes exactly one `sale` row. The
  -- checkout guards paid ≥ deposit, so `depositHeld ≤ paid`; clamp anyway.
  IF p_amount_paid_kobo > 0 AND NOT v_is_van_sale THEN
    v_deposit_held_kobo := LEAST(
      GREATEST(COALESCE(p_crate_deposit_paid_kobo, 0)::bigint, 0),
      p_amount_paid_kobo::bigint
    );
    v_goods_grand_kobo  := GREATEST(v_net_amount::bigint - v_deposit_held_kobo, 0);
    v_goods_paid_kobo   := LEAST(
      GREATEST(p_amount_paid_kobo::bigint - v_deposit_held_kobo, 0),
      v_goods_grand_kobo
    );
    v_topup_kobo        := p_amount_paid_kobo::bigint
                             - v_deposit_held_kobo - v_goods_paid_kobo;

    FOR v_leg IN
      SELECT * FROM (VALUES
        (v_goods_paid_kobo,   'sale'::text),
        (v_deposit_held_kobo, 'crate_deposit'::text),
        (v_topup_kobo,        'wallet_topup'::text)
      ) AS legs(amount_kobo, pay_type)
    LOOP
      CONTINUE WHEN v_leg.amount_kobo <= 0;

      v_payment_id := gen_random_uuid();
      INSERT INTO public.payment_transactions (
        id, business_id, store_id, amount_kobo, method, type,
        order_id, performed_by, created_at, last_updated_at
      )
      VALUES (
        v_payment_id, p_business_id, p_store_id, v_leg.amount_kobo,
        p_payment_method, v_leg.pay_type,
        p_order_id, p_actor_id, v_now, v_now
      );

      v_payment_rows := v_payment_rows || to_jsonb(
        (SELECT pt FROM public.payment_transactions pt WHERE pt.id = v_payment_id));

      -- The singular response key stays the GOODS row (the shipped client
      -- handler and the Tier-2 contract both read it).
      IF v_leg.pay_type = 'sale' THEN
        SELECT to_jsonb(pt.*) INTO v_payment_row
          FROM public.payment_transactions pt WHERE pt.id = v_payment_id;
      END IF;
    END LOOP;

    -- A tender with NO goods leg (a deposit-only order, whose overpayment then
    -- becomes a top-up) would leave the singular key NULL while the replay path
    -- above answers with its first row. Fall back to the same row the replay
    -- picks — the array is built in the loop's insert order, which is exactly
    -- that ordering — so one sale never has two answers.
    IF v_payment_row IS NULL AND jsonb_array_length(v_payment_rows) > 0 THEN
      v_payment_row := v_payment_rows->0;
    END IF;
  END IF;

  -- Wallet portion (optional). FOR UPDATE serializes concurrent debits;
  -- see 0014 for the rationale.
  IF p_wallet_amount_kobo > 0 THEN
    SELECT id INTO v_wallet_id
      FROM public.customer_wallets
      WHERE business_id = p_business_id AND customer_id = p_customer_id
      LIMIT 1
      FOR UPDATE;

    IF v_wallet_id IS NULL THEN
      RAISE EXCEPTION 'customer_wallet_missing' USING ERRCODE = 'P0001';
    END IF;

    SELECT COALESCE(SUM(signed_amount_kobo), 0) INTO v_wallet_balance
      FROM public.wallet_transactions
      WHERE wallet_id = v_wallet_id;
    IF v_wallet_balance < p_wallet_amount_kobo THEN
      RAISE EXCEPTION 'insufficient_wallet_balance'
        USING ERRCODE = 'P0001',
              HINT = jsonb_build_object(
                'wallet_id',      v_wallet_id,
                'available_kobo', v_wallet_balance,
                'requested_kobo', p_wallet_amount_kobo
              )::text;
    END IF;

    v_wallet_txn_id := gen_random_uuid();
    INSERT INTO public.wallet_transactions (
      id, business_id, wallet_id, customer_id, type,
      amount_kobo, signed_amount_kobo, reference_type, order_id,
      performed_by, customer_verified, created_at, last_updated_at
    )
    VALUES (
      v_wallet_txn_id, p_business_id, v_wallet_id, p_customer_id, 'debit',
      p_wallet_amount_kobo, -p_wallet_amount_kobo, 'order_payment', p_order_id,
      p_actor_id, p_customer_verified, v_now, v_now
    );
    SELECT to_jsonb(wt.*) INTO v_wallet_txn_row
      FROM public.wallet_transactions wt WHERE wt.id = v_wallet_txn_id;
  END IF;

  SELECT to_jsonb(o.*), o.last_updated_at INTO v_order_row, v_order_lua
    FROM public.orders o WHERE o.id = p_order_id;

  RETURN jsonb_build_object(
    'order',                v_order_row,
    'order_items',          v_order_items,
    'stock_transactions',   v_stock_txns,
    'payment_transaction',  v_payment_row,
    'payment_transactions', v_payment_rows,                        -- #201 delta
    'wallet_transaction',   v_wallet_txn_row,
    'inventory_after',      v_inv_after,
    'replayed',             false
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.pos_record_sale_v2(
  uuid, uuid, uuid, text, uuid, text, jsonb, text, uuid, int, int, int, text,
  text, text, int, bool, uuid
) TO authenticated, service_role;


-- ═══ 2. pos_cancel_order — compensating rows, nothing mutated ═══════════════
--
-- Body copied VERBATIM from 0045 (the current definition); every change is
-- marked `-- #201 delta`. The order header flip, the inventory restore, the
-- `return` stock rows, the tenant/status guards, the replay short-circuit and
-- the response keys are all unchanged.
CREATE OR REPLACE FUNCTION public.pos_cancel_order(
  p_business_id          uuid,
  p_actor_id             uuid,
  p_order_id             uuid,
  p_cancellation_reason  text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now            timestamptz := now();
  v_existing       record;
  v_oi             record;
  v_pt             record;
  v_wt             record;
  v_stx_id         uuid;
  v_refund_id      uuid;
  v_compensate_id  uuid;
  v_new_qty        int;
  v_order_row      jsonb;
  v_stock_txns     jsonb := '[]'::jsonb;
  v_inv_after      jsonb := '[]'::jsonb;
  v_refund_payments jsonb := '[]'::jsonb;
  v_wallet_compens  jsonb := '[]'::jsonb;
  v_to_credit       bool;                        -- #201 delta
  v_void_note       text;                        -- #201 delta
  v_batch_id        uuid;                        -- #201 delta
  v_cost_batches    jsonb := '[]'::jsonb;        -- #201 delta
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  -- Lock and read existing.
  SELECT * INTO v_existing FROM public.orders
   WHERE id = p_order_id AND business_id = p_business_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'order_not_found' USING ERRCODE = 'P0001';
  END IF;

  -- Replay: already cancelled, return existing state.
  IF v_existing.status = 'cancelled' THEN
    SELECT to_jsonb(o.*) INTO v_order_row FROM public.orders o WHERE o.id = p_order_id;
    RETURN jsonb_build_object(
      'order',                v_order_row,
      'stock_transactions',   '[]'::jsonb,
      'inventory_after',      '[]'::jsonb,
      'voided_payments',      '[]'::jsonb,
      'refund_payments',      '[]'::jsonb,
      'wallet_compensations', '[]'::jsonb,
      'cost_batches',         '[]'::jsonb,                         -- #201 delta
      'replayed',             true
    );
  END IF;

  IF v_existing.status NOT IN ('pending','completed') THEN
    RAISE EXCEPTION 'cannot_cancel_status_%', v_existing.status USING ERRCODE = 'P0001';
  END IF;

  -- #201 delta — the audit note stamped on every compensating row, mirroring the
  -- client's `reason: 'order_cancelled: $reason'`. A NULL reason propagates
  -- through the concat and falls back to the bare marker.
  v_void_note := COALESCE('order_cancelled: ' || p_cancellation_reason,
                          'order_cancelled');

  -- Update order header.
  UPDATE public.orders
     SET status              = 'cancelled',
         cancelled_at        = v_now,
         cancellation_reason = p_cancellation_reason
   WHERE id = p_order_id;

  -- Restore inventory + stock_transactions(return) per item, and — #201 delta —
  -- restore the cost LAYER each line drew (see the header: since 0167 nothing
  -- else restores it).
  FOR v_oi IN
    SELECT id, product_id, store_id, quantity,
           buying_price_kobo                                       -- #201 delta
      FROM public.order_items WHERE order_id = p_order_id
  LOOP
    -- #201 delta — a Quick Sale line (§26.4, nullable product_id since 0091)
    -- bypassed inventory, the stock ledger and the cost queue on the way OUT, so
    -- it must bypass all three on the way back. Without this guard the inventory
    -- INSERT below raised 23502 on its NOT NULL product_id and failed the whole
    -- cancel — the v1 client path never hit it because its loop reads
    -- `stock_transactions`, which a quick-sale line never gets.
    CONTINUE WHEN v_oi.product_id IS NULL;

    INSERT INTO public.inventory (id, business_id, product_id, store_id, quantity, created_at, last_updated_at)
    VALUES (gen_random_uuid(), p_business_id, v_oi.product_id, v_oi.store_id, v_oi.quantity, v_now, v_now)
    ON CONFLICT (business_id, product_id, store_id)
      DO UPDATE SET quantity = public.inventory.quantity + EXCLUDED.quantity
    RETURNING quantity INTO v_new_qty;

    v_inv_after := v_inv_after || jsonb_build_object(
      'product_id',      v_oi.product_id,
      'store_id',        v_oi.store_id,
      'quantity',        v_new_qty,
      'last_updated_at', v_now
    );

    v_stx_id := gen_random_uuid();
    INSERT INTO public.stock_transactions (
      id, business_id, product_id, location_id, quantity_delta, movement_type,
      order_id, performed_by, created_at, last_updated_at
    )
    VALUES (
      v_stx_id, p_business_id, v_oi.product_id, v_oi.store_id,
      v_oi.quantity, 'return', p_order_id, p_actor_id, v_now, v_now
    );
    v_stock_txns := v_stock_txns || to_jsonb(
      (SELECT stx FROM public.stock_transactions stx WHERE stx.id = v_stx_id));

    -- #201 delta — the cost layer comes back with the goods, at the per-unit COGS
    -- the SALE snapshotted, so the FIFO queue and the shelf stay in step (#170
    -- #7c, the twin of `CostBatchesDao.recordInflowBatch` in the client's cancel).
    -- One restore ⇒ one fresh layer, never merged (ADR 0005). A line the queue
    -- could not cover snapshotted 0 and comes back Uncosted — the same units,
    -- the same (absent) cost, no invention. `received_at = v_now` puts the
    -- returned units at the BACK of the queue, exactly where the client puts
    -- them: they are physically the newest arrivals on the shelf.
    IF v_oi.quantity > 0 THEN
      v_batch_id := gen_random_uuid();
      INSERT INTO public.cost_batches (
        id, business_id, product_id, store_id,
        qty_remaining, qty_original, cost_kobo, received_at,
        created_at, last_updated_at
      )
      VALUES (
        v_batch_id, p_business_id, v_oi.product_id, v_oi.store_id,
        v_oi.quantity, v_oi.quantity,
        GREATEST(COALESCE(v_oi.buying_price_kobo, 0), 0), v_now,
        v_now, v_now
      );
      v_cost_batches := v_cost_batches || to_jsonb(
        (SELECT cb FROM public.cost_batches cb WHERE cb.id = v_batch_id));
    END IF;
  END LOOP;

  -- #201 delta — PAYMENTS: post DATED COMPENSATING rows; every ORIGINAL row is
  -- LEFT UNTOUCHED (the pre-#155 body voided them in place AND posted a
  -- full-amount `refund` for each — a double reversal that also shrank the
  -- already-reviewed sale day). The SQL twin of `OrdersDao.markCancelled` /
  -- `PaymentTransactionsDao.postReversalPayment`:
  --   `sale`          → a POSITIVE `refund` cash-out, same amount;
  --   `crate_deposit` → a NEGATIVE `crate_deposit` (the held line nets to zero;
  --                     NOT a `refund` — that would move Cash refunds for money
  --                     that was never in Cash sales);
  --   `wallet_topup`  → a NEGATIVE `wallet_topup` ("Debts collected" nets to 0).
  -- The reversal copies the original's METHOD and STORE (a cash tender yields a
  -- cash reversal; #169 keeps the figure on the right store) and its `order_id`
  -- parent — the only parent these rows can have, since the filter is on
  -- `order_id`, so the exactly-one-parent CHECK holds. Rows of any other type (a
  -- prior cancel's `refund`, a `van_remittance`) and non-positive rows are never
  -- re-reversed. `created_at = v_now` lands the movement on the CANCEL day (#172).
  FOR v_pt IN
    SELECT * FROM public.payment_transactions
     WHERE order_id    = p_order_id
       AND business_id = p_business_id
       AND voided_at IS NULL
       AND type IN ('sale', 'crate_deposit', 'wallet_topup')
       AND amount_kobo > 0
     ORDER BY created_at, id
  LOOP
    v_refund_id := gen_random_uuid();
    INSERT INTO public.payment_transactions (
      id, business_id, store_id, amount_kobo, method, type,
      order_id, performed_by, void_reason, created_at, last_updated_at
    )
    VALUES (
      v_refund_id, p_business_id, v_pt.store_id,
      CASE WHEN v_pt.type = 'sale' THEN v_pt.amount_kobo
           ELSE -v_pt.amount_kobo END,
      v_pt.method,
      CASE WHEN v_pt.type = 'sale' THEN 'refund' ELSE v_pt.type END,
      p_order_id, p_actor_id, v_void_note, v_now, v_now
    );
    v_refund_payments := v_refund_payments || to_jsonb(
      (SELECT pt FROM public.payment_transactions pt WHERE pt.id = v_refund_id));
  END LOOP;

  -- #201 delta — WALLET: reverse the sale's legs with APPENDED opposite legs
  -- (invariant #3 — a ledger is never mutated), closing the "R2" hold recorded at
  -- the client's flag check. The pre-#155 body compensated only the DEBIT legs
  -- and voided them in place, so the payment credit leg survived a cancel and the
  -- customer's balance never returned to its pre-sale position.
  -- The SQL twin of `markCancelled`'s wallet block:
  --   goods debit (`order_payment`)      → a `refund` CREDIT;
  --   payment credit (`topup_*`)         → a `void` DEBIT;
  --   held deposit (`crate_deposit`)     → a `crate_deposit_refunded` DEBIT — the
  --     DEPOSIT-FAMILY release, not the generic `void`, which lands in the
  --     SPENDABLE bucket and would both dock spendable and leave "deposits held"
  --     inflated (#162).
  -- Legs that are themselves a reversal or a settlement are skipped, so a cancel
  -- never reverses a compensation. `voided_at IS NULL` is retained from the
  -- pre-#155 body as a belt: under the append-only discipline no new row is ever
  -- voided, and a legacy voided row was already reversed once.
  FOR v_wt IN
    SELECT * FROM public.wallet_transactions
     WHERE order_id    = p_order_id
       AND business_id = p_business_id
       AND voided_at IS NULL
       AND reference_type NOT IN ('refund', 'void', 'crate_deposit_refunded',
                                  'crate_deposit_forfeited', 'crate_refund')
     ORDER BY created_at, id
  LOOP
    v_to_credit := (v_wt.type = 'debit');
    v_compensate_id := gen_random_uuid();
    INSERT INTO public.wallet_transactions (
      id, business_id, wallet_id, customer_id, type,
      amount_kobo, signed_amount_kobo, reference_type, order_id,
      performed_by, customer_verified, created_at, last_updated_at
    )
    VALUES (
      v_compensate_id, p_business_id, v_wt.wallet_id, v_wt.customer_id,
      CASE WHEN v_to_credit THEN 'credit' ELSE 'debit' END,
      v_wt.amount_kobo,
      CASE WHEN v_to_credit THEN v_wt.amount_kobo ELSE -v_wt.amount_kobo END,
      CASE WHEN v_wt.reference_type = 'crate_deposit'
             THEN 'crate_deposit_refunded'
           WHEN v_to_credit THEN 'refund'
           ELSE 'void' END,
      p_order_id, p_actor_id, false, v_now, v_now
    );
    v_wallet_compens := v_wallet_compens || to_jsonb(
      (SELECT wt FROM public.wallet_transactions wt WHERE wt.id = v_compensate_id));
  END LOOP;

  SELECT to_jsonb(o.*) INTO v_order_row FROM public.orders o WHERE o.id = p_order_id;

  RETURN jsonb_build_object(
    'order',                v_order_row,
    'stock_transactions',   v_stock_txns,
    'inventory_after',      v_inv_after,
    -- #201 delta — nothing is voided in place any more, so this is always empty.
    -- The key is RETAINED so the envelope stays wire-compatible with the shipped
    -- `_applyDomainResponse` (which restores whatever array it finds).
    'voided_payments',      '[]'::jsonb,
    'refund_payments',      v_refund_payments,
    'wallet_compensations', v_wallet_compens,
    'cost_batches',         v_cost_batches,                        -- #201 delta
    'replayed',             false
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.pos_cancel_order(uuid, uuid, uuid, text)
  TO authenticated, service_role;


-- ═══ 3. _apply_stock_adjustment — carry cost with the quantity ══════════════
--
-- Body copied VERBATIM from 0141; every change is marked `-- #201 delta`. The
-- inventory increment / guarded decrement, the insufficient_stock raise, the
-- stock_adjustments + stock_transactions pair and the return value are unchanged,
-- so `request_stock_adjustment` / `approve_stock_adjustment` need no edit and are
-- not re-declared.
--
-- An adjustment is a CORRECTION, not a supplier inflow — it books no invoice and
-- no payable. But it does move goods, and #170 #7a settled that quantity must
-- never move without its value: otherwise a Remove writes an unvalued loss (and
-- the remaining COGS drifts to zero-cost) and an Add creates phantom cost-free
-- stock that later sells at 0 COGS.
CREATE OR REPLACE FUNCTION public._apply_stock_adjustment(
  p_business_id uuid,
  p_product_id  uuid,
  p_store_id    uuid,
  p_delta       int,
  p_reason      text,
  p_actor_id    uuid
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now     timestamptz := now();
  v_new_qty int;
  v_adj_id  uuid := gen_random_uuid();
  v_batches       jsonb;                         -- #201 delta
  v_batch_ids     uuid[];                        -- #201 delta
  v_assigned      jsonb;                         -- #201 delta
  v_rem           jsonb;                         -- #201 delta
  v_drawn_kobo    bigint;                        -- #201 delta
  v_unit_cost_kobo bigint;                       -- #201 delta
  v_value_kobo    bigint;                        -- #201 delta
  v_inflow_cost_kobo bigint;                     -- #201 delta
  v_i             int;                           -- #201 delta
BEGIN
  IF p_delta = 0 THEN
    SELECT quantity INTO v_new_qty FROM public.inventory
     WHERE business_id = p_business_id AND product_id = p_product_id AND store_id = p_store_id;
    RETURN COALESCE(v_new_qty, 0);
  END IF;

  IF p_delta > 0 THEN
    INSERT INTO public.inventory (
      id, business_id, product_id, store_id, quantity, created_at, last_updated_at
    )
    VALUES (
      gen_random_uuid(), p_business_id, p_product_id, p_store_id, p_delta, v_now, v_now
    )
    ON CONFLICT (business_id, product_id, store_id)
      DO UPDATE SET quantity = public.inventory.quantity + EXCLUDED.quantity,
                    last_updated_at = v_now
    RETURNING quantity INTO v_new_qty;
  ELSE
    UPDATE public.inventory
       SET quantity = quantity + p_delta, last_updated_at = v_now
     WHERE business_id = p_business_id AND product_id = p_product_id
       AND store_id = p_store_id AND quantity >= -p_delta
    RETURNING quantity INTO v_new_qty;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'insufficient_stock'
        USING ERRCODE = 'P0001',
              HINT = jsonb_build_object('product_id', p_product_id,
                                        'store_id', p_store_id,
                                        'requested_delta', p_delta)::text;
    END IF;
  END IF;

  -- #201 delta — a DECREASE draws the FIFO queue down oldest-first and snapshots
  -- what it drew, the twin of `CostBatchesDao.drawDownOutflow` (#170 #7a). Runs
  -- only after the guarded decrement above succeeded (a rejected decrement
  -- raised), so a refused Remove never touches the cost queue. The draw-down
  -- itself is `public.fifo_assign` (0133) — the SAME pure function the
  -- authoritative recost replays through, and the twin of the client's
  -- `fifoDrawDown` — fed a single one-line "sale" of |delta| units. Uncosted
  -- (cost-0) batches and units the queue cannot cover contribute 0: that is
  -- "uncosted", NOT "free". No lock is taken on the queue, matching 0133 and the
  -- client; the UPDATE below is the serialization point.
  IF p_delta < 0 THEN
    SELECT
      COALESCE(jsonb_agg(jsonb_build_object('cost_kobo', cb.cost_kobo,
                                           'qty',       cb.qty_remaining)
                         ORDER BY cb.received_at, cb.id), '[]'::jsonb),
      COALESCE(array_agg(cb.id ORDER BY cb.received_at, cb.id), ARRAY[]::uuid[])
    INTO v_batches, v_batch_ids
    FROM public.cost_batches cb
    WHERE cb.business_id   = p_business_id
      AND cb.product_id    = p_product_id
      AND cb.store_id      = p_store_id
      AND cb.qty_remaining > 0;

    v_assigned := public.fifo_assign(
      v_batches,
      jsonb_build_array(jsonb_build_object('line_id',  'outflow',
                                           'quantity', -p_delta))
    );
    v_drawn_kobo := COALESCE(
      ((v_assigned->'lines')->0->>'cogs_total_kobo')::bigint, 0);
    v_rem := v_assigned->'batches_remaining';

    -- Write back the derived remainders (only where changed; the 0132 bump
    -- trigger stamps last_updated_at so peers pull the decrement).
    FOR v_i IN 1 .. COALESCE(array_length(v_batch_ids, 1), 0) LOOP
      UPDATE public.cost_batches
         SET qty_remaining = (v_rem->>(v_i - 1))::int
       WHERE id = v_batch_ids[v_i]
         AND qty_remaining IS DISTINCT FROM (v_rem->>(v_i - 1))::int;
    END LOOP;

    v_value_kobo     := v_drawn_kobo;
    v_unit_cost_kobo := round(v_drawn_kobo::numeric / (-p_delta))::bigint;
  END IF;

  INSERT INTO public.stock_adjustments (
    id, business_id, product_id, store_id, quantity_diff, reason, performed_by,
    unit_cost_kobo, value_kobo,                                    -- #201 delta
    created_at, last_updated_at
  )
  VALUES (
    v_adj_id, p_business_id, p_product_id, p_store_id, p_delta,
    COALESCE(p_reason, 'Adjustment'), p_actor_id,
    v_unit_cost_kobo, v_value_kobo,                                -- #201 delta
    v_now, v_now
  );
  INSERT INTO public.stock_transactions (
    id, business_id, product_id, location_id, quantity_delta, movement_type,
    adjustment_id, performed_by, created_at, last_updated_at
  )
  VALUES (
    gen_random_uuid(), p_business_id, p_product_id, p_store_id, p_delta, 'adjustment',
    v_adj_id, p_actor_id, v_now, v_now
  );

  -- #201 delta — an INCREASE pushes one fresh FIFO layer, the twin of
  -- `CostBatchesDao.recordInflowBatch` and the identical rule 0140 applies to
  -- add-product / receive-stock: one inflow ⇒ one fresh batch, NEVER merged
  -- ({qty_remaining = qty_original = delta, received_at}).
  --
  -- THE COST OF AN OMITTED-COST INFLOW (#189, ADR 0005): this helper is handed no
  -- cost — the adjustment carries a quantity and a reason, nothing more — so the
  -- layer takes the product's recorded scalar `buying_price_kobo`, exactly what
  -- `InventoryDao._recordedUnitCostKobo` supplies on the mobile approval path.
  -- It is UNCOSTED (0) only when the product carries no cost at all. Batching at
  -- 0 with a price on file would sell those units at 0 COGS forever: #41's
  -- backfill fires only on a `0 → positive` cost edit, which a product that
  -- already has a price can never make again, and `_recomputeScalarCost` ignores
  -- cost-0 batches, so nothing could ever reach the layer. The scalar is not a
  -- guess — it is the derived display cache over this very queue.
  -- (#197 will capture a real cost ON the request; when it lands, pass it here
  -- and fall back to this scalar, exactly as the client composes it.)
  IF p_delta > 0 THEN
    SELECT GREATEST(COALESCE(p.buying_price_kobo, 0), 0)
      INTO v_inflow_cost_kobo
      FROM public.products p
     WHERE p.id = p_product_id AND p.business_id = p_business_id;

    INSERT INTO public.cost_batches (
      id, business_id, product_id, store_id,
      qty_remaining, qty_original, cost_kobo, received_at, created_at, last_updated_at
    )
    VALUES (
      gen_random_uuid(), p_business_id, p_product_id, p_store_id,
      p_delta, p_delta, COALESCE(v_inflow_cost_kobo, 0), v_now, v_now, v_now
    );
  END IF;

  RETURN v_new_qty;
END;
$$;

REVOKE ALL ON FUNCTION public._apply_stock_adjustment(uuid, uuid, uuid, int, text, uuid) FROM public;
-- Internal helper: only the SECURITY DEFINER RPCs in 0141 call it; not granted to clients.

COMMIT;

-- =============================================================================
-- Verification (paste into the SQL editor while authenticated as a business user):
--
--   0. NO OVERLOADS — the check that matters most. Each name must resolve to
--      exactly ONE function, with the argument count this migration declared:
--        SELECT proname, pronargs FROM pg_proc
--         WHERE pronamespace = 'public'::regnamespace
--           AND proname IN ('pos_record_sale_v2','pos_cancel_order',
--                           '_apply_stock_adjustment')
--         ORDER BY proname;
--        -- expect 3 rows: _apply_stock_adjustment 6, pos_cancel_order 4,
--        --                pos_record_sale_v2 18.  Two rows for one name ⇒ PGRST203.
--
--   1. THE TENDER SPLIT. A sale paying 250000 on goods of 200000 with a 30000
--      deposit must write THREE store-stamped rows summing to what was paid:
--        SELECT type, amount_kobo, store_id, method
--          FROM public.payment_transactions WHERE order_id = '<that order>'
--         ORDER BY type;
--        -- expect crate_deposit 30000, sale 200000, wallet_topup 20000, each
--        --        with the sale's store_id and the tendered method
--        SELECT SUM(amount_kobo) FROM public.payment_transactions
--         WHERE order_id = '<that order>';                    -- expect 250000
--      A goods-only sale still writes exactly one `sale` row:
--        -- expect 1 row, type 'sale', amount = amount paid
--      A ROAD sale (van store or a trip tag) still writes NONE:
--        -- expect 0 rows
--
--   2. THE CANCEL RULE (what #206's fixture should pin). After cancelling the
--      3-row sale above:
--        SELECT type, amount_kobo, voided_at, created_at::date
--          FROM public.payment_transactions WHERE order_id = '<that order>'
--         ORDER BY created_at, type;
--        -- expect the 3 ORIGINALS unchanged (voided_at IS NULL, sale-day
--        --   created_at) PLUS 3 compensating rows dated the cancel day:
--        --     refund        +200000
--        --     crate_deposit  -30000
--        --     wallet_topup   -20000
--        SELECT SUM(amount_kobo) FROM public.payment_transactions
--         WHERE order_id = '<that order>' AND type <> 'refund';
--        -- the deposit and top-up families each net to 0
--        SELECT count(*) FROM public.payment_transactions
--         WHERE order_id = '<that order>' AND voided_at IS NOT NULL;  -- expect 0
--      Wallet side, for a registered customer:
--        SELECT reference_type, type, signed_amount_kobo
--          FROM public.wallet_transactions WHERE order_id = '<that order>'
--         ORDER BY created_at, id;
--        -- expect each original leg plus its opposite: order_payment debit +
--        --   refund credit; topup_* credit + void debit; crate_deposit credit +
--        --   crate_deposit_refunded debit. SUM(signed_amount_kobo) = 0, and no
--        --   original carries voided_at.
--      Cost queue — the drawn layer comes back (#170 #7c / 0167):
--        SELECT qty_remaining, qty_original, cost_kobo, received_at
--          FROM public.cost_batches
--         WHERE product_id = '<the sold product>' AND store_id = '<store>'
--         ORDER BY received_at DESC LIMIT 1;
--        -- expect one NEW layer of the cancelled quantity at the line's
--        --   buying_price_kobo, and Σ qty_remaining back to the pre-sale total
--      Quick-sale cancel (a line with product_id NULL) succeeds and touches no
--      inventory / stock ledger / cost batch for that line.
--      Replay: a second cancel returns replayed=true and appends nothing.
--
--   3. THE ADJUSTMENT COST ARMS.
--      Decrease — seed one batch of 20 @ 15000 and approve a Remove of 8:
--        SELECT quantity_diff, unit_cost_kobo, value_kobo
--          FROM public.stock_adjustments WHERE id = '<the new adjustment>';
--        -- expect -8, 15000, 120000  (the golden fixture's figures)
--        SELECT qty_remaining FROM public.cost_batches WHERE id = '<that batch>';
--        -- expect 12
--      Increase, product WITH a recorded cost (#189) — approve an Add of 10 on a
--      product whose buying_price_kobo is 15000:
--        SELECT qty_remaining, qty_original, cost_kobo FROM public.cost_batches
--         WHERE product_id = '<product>' AND store_id = '<store>'
--         ORDER BY received_at DESC LIMIT 1;
--        -- expect 10, 10, 15000  (the product's recorded cost, NOT 0)
--        SELECT unit_cost_kobo, value_kobo FROM public.stock_adjustments
--         WHERE id = '<the new adjustment>';        -- expect NULL, NULL
--      Increase, product with NO cost on file — same query on a product whose
--      buying_price_kobo is 0:
--        -- expect 10, 10, 0  (a genuinely UNCOSTED layer)
--      A Remove that would take stock negative still raises insufficient_stock
--      and leaves both the queue and the adjustment row untouched.
--
--   4. AFTER THIS DEPLOYS, the three cost scenarios in
--      test/golden/fixtures/stock_adjustment_scenarios.json (the #189 recorded-cost
--      increase, the Uncosted increase, and the #7a snapshotted decrease) can drop
--      their `dart_arm_only` flag: the web RPC arm now implements the same rule, so
--      the two arms can be pinned together. They are left flagged in this PR
--      because the RPC arm runs against live Supabase and would fail until this
--      migration is applied — and the RPC arm's tearDown needs a
--      `del('cost_batches', 'product_id', …)` before it deletes the product, since
--      the RPC now creates batch rows (the FK would otherwise silently block the
--      product delete: its 23503 is swallowed).
-- =============================================================================
