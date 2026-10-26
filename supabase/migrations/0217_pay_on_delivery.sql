-- 0217_pay_on_delivery.sql
--
-- #432 (Online ordering 11/28, PRD #421): Pay on delivery at Checkout and
-- Mark as paid. Cloud twin of Drift schemaVersion 94 (app_database.dart,
-- `from < 94`). 0216 is reserved for another slice.
--
-- NO NEW TABLE, COLUMN OR STATUS. Pay on delivery is the existing credit sale
-- (orders.payment_type = 'credit'), recognised as such through the existing
-- online_orders.linked_order_id link (#431). Mark as paid posts exactly the
-- rows Record Payment posts — a wallet_transactions credit
-- ('topup_cash' / 'topup_transfer') plus its 'wallet_topup' payment_transactions
-- row — with the EXISTING wallet_transactions.order_id carrying the order it
-- settles. The payment row keeps its single parent (wallet_txn_id).
--
-- WHAT THIS ADDS
--   1. Permission (category 'Online store'):
--        orders.pay_on_delivery.mark_paid   Mark pay-on-delivery orders paid
--      CEO only by default. The seed function is re-issued VERBATIM from 0208
--      (the CEO already receives every catalogue key through its SELECT), and
--      existing CEO roles get a one-off backfill. The key reaches the
--      catalogue BEFORE any grant syncs (role_permissions FK).
--   2. pos_cancel_order re-issued VERBATIM from 0170 with one delta: a Mark as
--      paid collection (a wallet credit carrying the order id AND its own
--      'wallet_topup' payment row) is NOT reversed when the sale is cancelled. It is
--      money the customer really handed over, so it stays as their credit —
--      the SQL twin of the same exclusion in OrdersDao.markCancelled. (This
--      RPC runs only behind the held-off feature.domain_rpcs_v2.cancel_order
--      flag; the signature is unchanged, so no overload.)
--
-- No pos_pull_snapshot change, no new synced table.
--
-- DEPLOY: BEFORE the app build carrying Drift 94 (that build's role editor
-- shows the new key; a CEO grant to a Manager pushes a role_permissions row
-- that needs the catalogue key — FK). Never together with 0193.

-- =========================================================================
-- 1. Permission — catalogue first, then the seed, then the one-off backfill
-- =========================================================================
INSERT INTO public.permissions (key, description, category) VALUES
  ('orders.pay_on_delivery.mark_paid', 'Mark pay-on-delivery orders paid',
   'Online store')
ON CONFLICT (key) DO NOTHING;

-- Verbatim latest seed (0208). orders.pay_on_delivery.mark_paid is CEO only,
-- and the CEO already gets every catalogue key, so the body is unchanged.
CREATE OR REPLACE FUNCTION public.seed_default_roles_for_business(
  p_business_id uuid
)
RETURNS TABLE (
  ceo_role_id          uuid,
  manager_role_id      uuid,
  cashier_role_id      uuid,
  stock_keeper_role_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_ceo  uuid;
  v_mgr  uuid;
  v_cash uuid;
  v_sk   uuid;
  v_drv  uuid;
BEGIN
  INSERT INTO public.roles (id, business_id, name, slug, is_system_default)
    VALUES (gen_random_uuid(), p_business_id, 'CEO',          'ceo',          true)
    ON CONFLICT (business_id, slug) DO UPDATE SET name = EXCLUDED.name
    RETURNING id INTO v_ceo;

  INSERT INTO public.roles (id, business_id, name, slug, is_system_default)
    VALUES (gen_random_uuid(), p_business_id, 'Manager',      'manager',      true)
    ON CONFLICT (business_id, slug) DO UPDATE SET name = EXCLUDED.name
    RETURNING id INTO v_mgr;

  INSERT INTO public.roles (id, business_id, name, slug, is_system_default)
    VALUES (gen_random_uuid(), p_business_id, 'Cashier',      'cashier',      true)
    ON CONFLICT (business_id, slug) DO UPDATE SET name = EXCLUDED.name
    RETURNING id INTO v_cash;

  INSERT INTO public.roles (id, business_id, name, slug, is_system_default)
    VALUES (gen_random_uuid(), p_business_id, 'Stock keeper', 'stock_keeper', true)
    ON CONFLICT (business_id, slug) DO UPDATE SET name = EXCLUDED.name
    RETURNING id INTO v_sk;

  -- #140 — the fifth system role. Last in tier order (CEO → Manager → Cashier
  -- → Stock keeper → Driver), which is how every role list is sorted.
  INSERT INTO public.roles (id, business_id, name, slug, is_system_default)
    VALUES (gen_random_uuid(), p_business_id, 'Driver',       'driver',       true)
    ON CONFLICT (business_id, slug) DO UPDATE SET name = EXCLUDED.name
    RETURNING id INTO v_drv;

  -- CEO: all keys (includes the new van.manage / van.sell via the SELECT).
  INSERT INTO public.role_permissions (business_id, role_id, permission_key)
    SELECT p_business_id, v_ceo, key FROM public.permissions
    ON CONFLICT (role_id, permission_key) DO NOTHING;

  -- Manager: explicit list + van.manage (#140 — a manager sets up vans, loads
  -- them and records remittances; they never sell from one).
  INSERT INTO public.role_permissions (business_id, role_id, permission_key)
  VALUES
    (p_business_id, v_mgr, 'sales.make'),
    (p_business_id, v_mgr, 'sales.cancel'),
    (p_business_id, v_mgr, 'sales.confirm'),
    (p_business_id, v_mgr, 'sales.discount.give'),
    (p_business_id, v_mgr, 'products.add'),
    (p_business_id, v_mgr, 'products.edit_price'),
    (p_business_id, v_mgr, 'products.manage_listing'),
    (p_business_id, v_mgr, 'online_orders.view'),
    (p_business_id, v_mgr, 'online_orders.answer'),
    (p_business_id, v_mgr, 'products.edit_buying_price'),
    (p_business_id, v_mgr, 'products.delete'),
    (p_business_id, v_mgr, 'stock.add'),
    (p_business_id, v_mgr, 'stock.view'),
    (p_business_id, v_mgr, 'stock.adjust'),
    (p_business_id, v_mgr, 'expenses.create'),
    (p_business_id, v_mgr, 'reports.see_sales'),
    (p_business_id, v_mgr, 'reports.see_cost_prices'),
    (p_business_id, v_mgr, 'reports.see_expenses'),
    (p_business_id, v_mgr, 'customers.add'),
    (p_business_id, v_mgr, 'customers.update'),
    (p_business_id, v_mgr, 'customers.delete'),
    (p_business_id, v_mgr, 'customers.wallet.update'),
    (p_business_id, v_mgr, 'customers.set_debt_limit'),
    (p_business_id, v_mgr, 'customers.wallet.totals.view'),
    (p_business_id, v_mgr, 'customers.wallet.withdraw'),
    (p_business_id, v_mgr, 'stores.request_transfer'),
    (p_business_id, v_mgr, 'stores.dispatch_transfer'),
    (p_business_id, v_mgr, 'stores.receive_transfer'),
    (p_business_id, v_mgr, 'staff.invite'),
    (p_business_id, v_mgr, 'staff.suspend'),
    (p_business_id, v_mgr, 'staff.change_role'),
    (p_business_id, v_mgr, 'van.manage'),
    (p_business_id, v_mgr, 'funds.open_day'),
    (p_business_id, v_mgr, 'funds.close_day'),
    (p_business_id, v_mgr, 'funds.view')
  ON CONFLICT (role_id, permission_key) DO NOTHING;

  -- Cashier: + online_orders.view / .answer (#427).
  INSERT INTO public.role_permissions (business_id, role_id, permission_key)
  VALUES
    (p_business_id, v_cash, 'sales.make'),
    (p_business_id, v_cash, 'sales.confirm'),
    (p_business_id, v_cash, 'stock.view'),
    (p_business_id, v_cash, 'reports.see_sales'),
    (p_business_id, v_cash, 'customers.add'),
    (p_business_id, v_cash, 'customers.update'),
    (p_business_id, v_cash, 'customers.wallet.update'),
    (p_business_id, v_cash, 'online_orders.view'),
    (p_business_id, v_cash, 'online_orders.answer')
  ON CONFLICT (role_id, permission_key) DO NOTHING;

  -- Stock keeper: unchanged.
  INSERT INTO public.role_permissions (business_id, role_id, permission_key)
  VALUES
    (p_business_id, v_sk, 'stock.add'),
    (p_business_id, v_sk, 'stock.view'),
    (p_business_id, v_sk, 'stock.adjust')
  ON CONFLICT (role_id, permission_key) DO NOTHING;

  -- Driver: `van.sell` only. Deliberately NOT `sales.make` — a driver sells
  -- through the van terminal (#142), not the store POS — and deliberately NOT
  -- `van.manage`, which is what makes "a driver records their own remittance"
  -- impossible by construction (spec §9.5, edge case 21).
  INSERT INTO public.role_permissions (business_id, role_id, permission_key)
  VALUES
    (p_business_id, v_drv, 'van.sell')
  ON CONFLICT (role_id, permission_key) DO NOTHING;

  INSERT INTO public.role_settings (business_id, role_id, setting_key, setting_value)
  VALUES
    (p_business_id, v_ceo,  'max_discount_percent',        '100'),
    (p_business_id, v_ceo,  'max_expense_approval_kobo',   NULL),
    (p_business_id, v_mgr,  'max_discount_percent',        '10'),
    (p_business_id, v_mgr,  'max_expense_approval_kobo',   '0'),
    (p_business_id, v_cash, 'max_discount_percent',        '0'),
    (p_business_id, v_cash, 'max_expense_approval_kobo',   '0'),
    (p_business_id, v_sk,   'max_discount_percent',        '0'),
    (p_business_id, v_sk,   'max_expense_approval_kobo',   '0'),
    (p_business_id, v_drv,  'max_discount_percent',        '0'),
    (p_business_id, v_drv,  'max_expense_approval_kobo',   '0')
  ON CONFLICT (role_id, setting_key) DO NOTHING;

  RETURN QUERY SELECT v_ceo, v_mgr, v_cash, v_sk;
END;
$function$;

-- Existing businesses receive the new default once (CEO only). Do not rewrite
-- this migration to re-grant an intentionally revoked permission later.
INSERT INTO public.role_permissions (business_id, role_id, permission_key)
SELECT r.business_id, r.id, 'orders.pay_on_delivery.mark_paid'
  FROM public.roles r
 WHERE r.slug = 'ceo'
ON CONFLICT (role_id, permission_key) DO NOTHING;

-- =========================================================================
-- 2. pos_cancel_order — verbatim from 0170, plus the #432 delta
-- =========================================================================
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
  v_correction_note text;                        -- #201 delta
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

  -- #201 delta — the CORRECTION note stamped on every compensating row,
  -- mirroring the client's `reason: 'order_cancelled: $reason'`. Named for what
  -- it is, not for the column it lands in: the destination is `void_reason`, but
  -- nothing here is voided any more — that column is the table's only free-text
  -- audit field and the seam reuses it (`postReversalPayment`'s `reason`). A NULL
  -- reason propagates through the concat and falls back to the bare marker.
  v_correction_note := COALESCE('order_cancelled: ' || p_cancellation_reason,
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
      FROM public.order_items
     WHERE order_id    = p_order_id
       AND business_id = p_business_id                             -- #201 delta
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
      p_order_id, p_actor_id, v_correction_note, v_now, v_now
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
       -- #432 delta — a Mark as paid collection (a wallet credit with its own
       -- 'wallet_topup' payment row) stays as the customer's credit. A sale's
       -- own legs never have one (their payment row's parent is the order).
       AND NOT EXISTS (
         SELECT 1 FROM public.payment_transactions pt
          WHERE pt.wallet_txn_id = wallet_transactions.id
            AND pt.type = 'wallet_topup')
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
