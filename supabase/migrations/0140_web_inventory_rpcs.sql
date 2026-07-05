-- 0140_web_inventory_rpcs.sql
--
-- Reebaplus — Web POS Slice 6 (issue #48). The server-authoritative inventory
-- write RPCs for the online web client: add_product / update_product (catalogue
-- writes incl. the opening Cost Batch) and receive_stock (a supplier delivery:
-- stock increase + supplier invoice/payment + a receipt-dated Cost Batch).
--
-- WHY RPCs (ADR 0008): the web is online-first and never writes tenant rows via
-- PostgREST — each money-write is one atomic SECURITY DEFINER transaction behind
-- RLS, enforcing the caller's permission server-side (defence in depth; the web
-- also hides the action). Amounts are *_kobo BIGINT end to end (0130).
--
-- TWO IMPLEMENTATIONS, ONE CONTRACT (ADR 0009): these are the SQL twins of the
-- mobile Dart inventory path —
--   * add_product   ↔ CatalogDao add-product + CostBatchesDao.recordInflowBatch
--   * receive_stock ↔ ReceiveStockService.confirmReceipt (InventoryDao.adjustStock
--                     + SupplierAccountService + CostBatchesDao.recordInflowBatch)
-- The Cost Batch producer rule is pinned identical to Dart by the batch-creation
-- Golden-Scenario Suite (test/golden/inventory_scenario.dart), which runs the same
-- fixtures against both. The rule (F1/F6, ADR 0005): one inflow ⇒ one fresh batch
-- {qty_remaining = qty_original = quantity, cost_kobo = GREATEST(cost, 0),
-- received_at}. A batch is NEVER merged with another; cost 0 ⇒ an UNCOSTED batch.
--
-- ADD PRODUCT vs RECEIVE STOCK (ADR 0005/0006): Add Product writes opening stock
-- STRAIGHT to inventory with NO supplier/invoice/payable and creates the opening
-- Cost Batch. Receive Stock logs a delivery — it posts the supplier invoice (a
-- debit), an optional payment (a credit), a stock movement per line, and a
-- receipt-dated Cost Batch at the delivery cost.
--
-- STOCK MOVEMENT PARITY: a receive line mirrors mobile InventoryDao.adjustStock's
-- default path — one stock_adjustments row (reason 'Stock received') + one
-- stock_transactions row referencing it (movement_type 'adjustment', the
-- adjustment_id ref that satisfies the exactly-one-of-4-refs CHECK). Add Product's
-- opening stock is an opening balance, not a movement, so it writes no
-- stock_transactions row (matches the Dart opening-stock path).
--
-- DEPLOY ORDER: after 0132 (cost_batches), 0102 (supplier_ledger_entries) and
-- 0135 (the caller_has_permission / _assert_caller_owns_business helpers this
-- reuses). Additive server logic — inert until called by the web client.

BEGIN;

-- ─── 1. add_product — create a product + opening stock + opening Cost Batch ───
--
-- Idempotent on p_product_id (the client-minted UUID): a replay returns the
-- existing product without re-applying inventory / the opening batch.
CREATE OR REPLACE FUNCTION public.add_product(
  p_business_id           uuid,
  p_product_id            uuid,        -- idempotency key (client UUID)
  p_store_id              uuid,
  p_name                  text,
  p_category_id           uuid    DEFAULT NULL,
  p_unit                  text    DEFAULT 'Piece',
  p_size                  text    DEFAULT NULL,
  p_retailer_price_kobo   bigint  DEFAULT 0,
  p_wholesaler_price_kobo bigint  DEFAULT 0,
  p_buying_price_kobo     bigint  DEFAULT 0,   -- opening batch cost (0 ⇒ uncosted)
  p_opening_stock         int     DEFAULT 0,
  p_track_empties         boolean DEFAULT false,
  p_manufacturer_id       uuid    DEFAULT NULL,
  p_low_stock_threshold   int     DEFAULT 5
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now        timestamptz := now();
  v_actor_id   uuid;
  v_existing   boolean;
  v_product    jsonb;
  v_inv_id     uuid;
  v_batch_id   uuid;
  v_cost       bigint := GREATEST(COALESCE(p_buying_price_kobo, 0), 0);
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  IF NOT public.caller_has_permission(p_business_id, 'products.add') THEN
    RAISE EXCEPTION 'permission_denied: products.add'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_product_id IS NULL THEN
    RAISE EXCEPTION 'product_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'store_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_name IS NULL OR btrim(p_name) = '' THEN
    RAISE EXCEPTION 'name_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF COALESCE(p_opening_stock, 0) < 0 THEN
    RAISE EXCEPTION 'opening_stock_must_be_non_negative'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Idempotent replay (tenant-scoped: never short-circuit on a foreign row).
  SELECT true INTO v_existing
    FROM public.products WHERE id = p_product_id AND business_id = p_business_id;
  IF v_existing THEN
    SELECT to_jsonb(p.*) INTO v_product
      FROM public.products p WHERE p.id = p_product_id AND p.business_id = p_business_id;
    RETURN jsonb_build_object('product', v_product, 'replayed', true);
  END IF;

  SELECT id INTO v_actor_id FROM public.users WHERE auth_user_id = auth.uid() LIMIT 1;

  INSERT INTO public.products (
    id, business_id, category_id, manufacturer_id, name, unit, size,
    retailer_price_kobo, wholesaler_price_kobo, buying_price_kobo,
    track_empties, low_stock_threshold, is_available, is_deleted,
    created_at, last_updated_at
  )
  VALUES (
    p_product_id, p_business_id, p_category_id, p_manufacturer_id, btrim(p_name),
    COALESCE(p_unit, 'Piece'), p_size,
    COALESCE(p_retailer_price_kobo, 0), COALESCE(p_wholesaler_price_kobo, 0), v_cost,
    COALESCE(p_track_empties, false), COALESCE(p_low_stock_threshold, 5), true, false,
    v_now, v_now
  );

  -- Opening stock → straight to inventory (an opening balance, not a movement:
  -- no supplier/invoice, no stock_transactions row) + the opening Cost Batch.
  IF COALESCE(p_opening_stock, 0) > 0 THEN
    v_inv_id := gen_random_uuid();
    INSERT INTO public.inventory (
      id, business_id, product_id, store_id, quantity, created_at, last_updated_at
    )
    VALUES (
      v_inv_id, p_business_id, p_product_id, p_store_id, p_opening_stock, v_now, v_now
    );

    v_batch_id := gen_random_uuid();
    INSERT INTO public.cost_batches (
      id, business_id, product_id, store_id,
      qty_remaining, qty_original, cost_kobo, received_at, created_at, last_updated_at
    )
    VALUES (
      v_batch_id, p_business_id, p_product_id, p_store_id,
      p_opening_stock, p_opening_stock, v_cost, v_now, v_now, v_now
    );
  END IF;

  INSERT INTO public.activity_logs (
    id, business_id, user_id, action, description, product_id, store_id,
    entity_type, entity_id, created_at, last_updated_at
  )
  VALUES (
    gen_random_uuid(), p_business_id, v_actor_id, 'product.created',
    'Added product ' || btrim(p_name)
      || CASE WHEN COALESCE(p_opening_stock, 0) > 0
              THEN ' with opening stock ' || p_opening_stock::text ELSE '' END,
    p_product_id, p_store_id, 'product', p_product_id, v_now, v_now
  );

  SELECT to_jsonb(p.*) INTO v_product FROM public.products p WHERE p.id = p_product_id;
  RETURN jsonb_build_object(
    'product',    v_product,
    'batch_id',   v_batch_id,
    'replayed',   false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.add_product(uuid, uuid, uuid, text, uuid, text, text, bigint, bigint, bigint, int, boolean, uuid, int) FROM public;
GRANT EXECUTE ON FUNCTION public.add_product(uuid, uuid, uuid, text, uuid, text, text, bigint, bigint, bigint, int, boolean, uuid, int)
  TO authenticated, service_role;


-- ─── 2. update_product — edit catalogue details / prices ─────────────────────
--
-- Edits the product's mutable fields only. Editing buying_price_kobo updates the
-- scalar display cost; it does NOT retroactively re-cost historical batches (that
-- is the recost family 0133) — a new cost applies to future inflows. Inventory
-- and Cost Batches are untouched (an edit is not a stock movement).
CREATE OR REPLACE FUNCTION public.update_product(
  p_business_id           uuid,
  p_product_id            uuid,
  p_name                  text    DEFAULT NULL,
  p_category_id           uuid    DEFAULT NULL,
  p_unit                  text    DEFAULT NULL,
  p_size                  text    DEFAULT NULL,
  p_retailer_price_kobo   bigint  DEFAULT NULL,
  p_wholesaler_price_kobo bigint  DEFAULT NULL,
  p_buying_price_kobo     bigint  DEFAULT NULL,
  p_track_empties         boolean DEFAULT NULL,
  p_manufacturer_id       uuid    DEFAULT NULL,
  p_low_stock_threshold   int     DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now      timestamptz := now();
  v_actor_id uuid;
  v_product  jsonb;
  v_found    boolean;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  IF NOT public.caller_has_permission(p_business_id, 'products.add') THEN
    RAISE EXCEPTION 'permission_denied: products.add'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_product_id IS NULL THEN
    RAISE EXCEPTION 'product_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT true INTO v_found
    FROM public.products
   WHERE id = p_product_id AND business_id = p_business_id;
  IF NOT v_found THEN
    RAISE EXCEPTION 'product_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT id INTO v_actor_id FROM public.users WHERE auth_user_id = auth.uid() LIMIT 1;

  -- COALESCE keeps a column unchanged when its param is NULL (partial update).
  UPDATE public.products
     SET name                  = COALESCE(NULLIF(btrim(p_name), ''), name),
         category_id           = COALESCE(p_category_id, category_id),
         unit                  = COALESCE(p_unit, unit),
         size                  = COALESCE(p_size, size),
         retailer_price_kobo   = COALESCE(p_retailer_price_kobo, retailer_price_kobo),
         wholesaler_price_kobo = COALESCE(p_wholesaler_price_kobo, wholesaler_price_kobo),
         buying_price_kobo     = COALESCE(p_buying_price_kobo, buying_price_kobo),
         track_empties         = COALESCE(p_track_empties, track_empties),
         manufacturer_id       = COALESCE(p_manufacturer_id, manufacturer_id),
         low_stock_threshold   = COALESCE(p_low_stock_threshold, low_stock_threshold),
         last_updated_at       = v_now
   WHERE id = p_product_id AND business_id = p_business_id;

  INSERT INTO public.activity_logs (
    id, business_id, user_id, action, description, product_id,
    entity_type, entity_id, created_at, last_updated_at
  )
  VALUES (
    gen_random_uuid(), p_business_id, v_actor_id, 'product.updated',
    'Updated product details', p_product_id, 'product', p_product_id, v_now, v_now
  );

  SELECT to_jsonb(p.*) INTO v_product FROM public.products p WHERE p.id = p_product_id;
  RETURN jsonb_build_object('product', v_product);
END;
$$;

REVOKE ALL ON FUNCTION public.update_product(uuid, uuid, text, uuid, text, text, bigint, bigint, bigint, boolean, uuid, int) FROM public;
GRANT EXECUTE ON FUNCTION public.update_product(uuid, uuid, text, uuid, text, text, bigint, bigint, bigint, boolean, uuid, int)
  TO authenticated, service_role;


-- ─── 3. receive_stock — log a supplier delivery ──────────────────────────────
--
-- p_lines : [{ "product_id": <uuid>, "quantity": <int>, "buying_price_kobo": <bigint>,
--              "retailer_price_kobo": <bigint?>, "wholesaler_price_kobo": <bigint?> }, ...]
--
-- One receipt = one supplier, all-or-nothing. Posts: the supplier invoice (debit),
-- an optional payment (credit), and per line — inventory increase, updated prices,
-- a stock movement (adjustment), and a receipt-dated Cost Batch at the line cost.
--
-- Idempotent on p_receipt_id: the summary activity_logs row is written with
-- id = p_receipt_id, so a replay short-circuits before any side effect.
CREATE OR REPLACE FUNCTION public.receive_stock(
  p_business_id      uuid,
  p_receipt_id       uuid,          -- idempotency key (client UUID)
  p_supplier_id      uuid,
  p_store_id         uuid,
  p_lines            jsonb,
  p_received_at      timestamptz DEFAULT now(),
  p_amount_paid_kobo bigint      DEFAULT 0,
  p_payment_method   text        DEFAULT 'cash',
  p_note             text        DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now         timestamptz := now();
  v_received_at timestamptz := COALESCE(p_received_at, v_now);
  v_actor_id    uuid;
  v_existing    boolean;
  v_invoice_tot bigint;
  v_units       int;
  v_line        jsonb;
  v_product_id  uuid;
  v_qty         int;
  v_buy         bigint;
  v_retail      bigint;
  v_wholesale   bigint;
  v_adj_id      uuid;
  v_inv_id      uuid;
  v_batch_id    uuid;
  v_new_qty     int;
  v_pay         bigint := GREATEST(COALESCE(p_amount_paid_kobo, 0), 0);
  v_method      text   := COALESCE(p_payment_method, 'cash');
  v_inv_after   jsonb  := '[]'::jsonb;
  v_batch_ids   jsonb  := '[]'::jsonb;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  -- Receive is granted to the stock-add / receive roles (a stock keeper adds qty
  -- directly on this flow, by design) as well as anyone who can add products.
  IF NOT (public.caller_has_permission(p_business_id, 'stock.received')
       OR public.caller_has_permission(p_business_id, 'stock.add')
       OR public.caller_has_permission(p_business_id, 'products.add')) THEN
    RAISE EXCEPTION 'permission_denied: stock.received'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_receipt_id IS NULL THEN
    RAISE EXCEPTION 'receipt_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_supplier_id IS NULL THEN
    RAISE EXCEPTION 'supplier_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'store_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'lines_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF v_method NOT IN ('cash', 'transfer', 'pos', 'other') THEN
    RAISE EXCEPTION 'payment_method_invalid' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Idempotent replay (the summary log row IS the receipt marker).
  SELECT true INTO v_existing FROM public.activity_logs WHERE id = p_receipt_id;
  IF v_existing THEN
    RETURN jsonb_build_object('replayed', true);
  END IF;

  SELECT id INTO v_actor_id FROM public.users WHERE auth_user_id = auth.uid() LIMIT 1;

  SELECT
    COALESCE(SUM((l->>'quantity')::int * GREATEST((l->>'buying_price_kobo')::bigint, 0)), 0),
    COALESCE(SUM((l->>'quantity')::int), 0)
  INTO v_invoice_tot, v_units
  FROM jsonb_array_elements(p_lines) AS l;

  -- 1. Supplier invoice — a debit (goods received; we now owe the supplier).
  --    Skip a zero-value invoice (stock/batches still post).
  IF v_invoice_tot > 0 THEN
    INSERT INTO public.supplier_ledger_entries (
      id, business_id, supplier_id, store_id, type, amount_kobo, signed_amount_kobo,
      reference_type, activity_date, reference_note, performed_by, created_at, last_updated_at
    )
    VALUES (
      gen_random_uuid(), p_business_id, p_supplier_id, p_store_id, 'debit',
      v_invoice_tot, -v_invoice_tot, 'invoice', v_received_at, p_note, v_actor_id, v_now, v_now
    );
  END IF;

  -- 2. Optional payment — a credit (money paid to the supplier).
  IF v_pay > 0 THEN
    INSERT INTO public.supplier_ledger_entries (
      id, business_id, supplier_id, store_id, type, amount_kobo, signed_amount_kobo,
      reference_type, payment_method, activity_date, reference_note, performed_by,
      created_at, last_updated_at
    )
    VALUES (
      gen_random_uuid(), p_business_id, p_supplier_id, p_store_id, 'credit',
      v_pay, v_pay, 'payment_' || v_method, v_method, v_received_at,
      COALESCE(p_note, 'Payment for received stock'), v_actor_id, v_now, v_now
    );
  END IF;

  -- 3. Per line: inventory increase + prices + stock movement + Cost Batch.
  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    v_product_id := (v_line->>'product_id')::uuid;
    v_qty        := (v_line->>'quantity')::int;
    v_buy        := GREATEST(COALESCE((v_line->>'buying_price_kobo')::bigint, 0), 0);
    v_retail     := NULLIF(v_line->>'retailer_price_kobo', '')::bigint;
    v_wholesale  := NULLIF(v_line->>'wholesaler_price_kobo', '')::bigint;

    IF v_product_id IS NULL THEN
      RAISE EXCEPTION 'product_id_required_per_line' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION 'line_quantity_must_be_positive' USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Inventory upsert (create the row or add to it) — mirrors adjustStock's
    -- ON CONFLICT increment.
    INSERT INTO public.inventory (
      id, business_id, product_id, store_id, quantity, created_at, last_updated_at
    )
    VALUES (
      gen_random_uuid(), p_business_id, v_product_id, p_store_id, v_qty, v_now, v_now
    )
    ON CONFLICT (business_id, product_id, store_id)
      DO UPDATE SET quantity = public.inventory.quantity + EXCLUDED.quantity,
                    last_updated_at = v_now
    RETURNING quantity INTO v_new_qty;

    -- Persist the delivery's prices onto the product (mirrors updateProductPrices):
    -- a costed line updates the scalar buying price; a 0-cost (uncosted) line must
    -- NOT clobber the existing scalar cost (mirrors the mobile "oldest COSTED batch,
    -- no-clobber" rule). Retail/wholesale only when sent.
    UPDATE public.products
       SET buying_price_kobo     = CASE WHEN v_buy > 0 THEN v_buy ELSE buying_price_kobo END,
           retailer_price_kobo   = COALESCE(v_retail, retailer_price_kobo),
           wholesaler_price_kobo = COALESCE(v_wholesale, wholesaler_price_kobo),
           last_updated_at       = v_now
     WHERE id = v_product_id AND business_id = p_business_id;

    -- Stock movement (adjustment): the stock_adjustments row + the
    -- stock_transactions row referencing it (satisfies the one-ref CHECK).
    v_adj_id := gen_random_uuid();
    INSERT INTO public.stock_adjustments (
      id, business_id, product_id, store_id, quantity_diff, reason, performed_by,
      created_at, last_updated_at
    )
    VALUES (
      v_adj_id, p_business_id, v_product_id, p_store_id, v_qty, 'Stock received',
      v_actor_id, v_now, v_now
    );
    INSERT INTO public.stock_transactions (
      id, business_id, product_id, location_id, quantity_delta, movement_type,
      adjustment_id, performed_by, created_at, last_updated_at
    )
    VALUES (
      gen_random_uuid(), p_business_id, v_product_id, p_store_id, v_qty, 'adjustment',
      v_adj_id, v_actor_id, v_now, v_now
    );

    -- Receipt-dated Cost Batch at the line's buying price (0 ⇒ uncosted). One
    -- inflow ⇒ one fresh batch, never merged (F6 / ADR 0005).
    v_batch_id := gen_random_uuid();
    INSERT INTO public.cost_batches (
      id, business_id, product_id, store_id,
      qty_remaining, qty_original, cost_kobo, received_at, created_at, last_updated_at
    )
    VALUES (
      v_batch_id, p_business_id, v_product_id, p_store_id,
      v_qty, v_qty, v_buy, v_received_at, v_now, v_now
    );

    v_inv_after := v_inv_after || jsonb_build_object(
      'product_id', v_product_id, 'store_id', p_store_id, 'quantity', v_new_qty);
    v_batch_ids := v_batch_ids || to_jsonb(v_batch_id);
  END LOOP;

  -- 4. Summary activity log — id = p_receipt_id is the idempotency marker.
  INSERT INTO public.activity_logs (
    id, business_id, user_id, action, description, store_id,
    entity_type, entity_id, created_at, last_updated_at
  )
  VALUES (
    p_receipt_id, p_business_id, v_actor_id, 'stock.received',
    'Received ' || jsonb_array_length(p_lines)::text || ' product(s), '
      || v_units::text || ' unit(s)',
    p_store_id, 'supplier', p_supplier_id, v_now, v_now
  );

  RETURN jsonb_build_object(
    'receipt_id',       p_receipt_id,
    'invoice_total_kobo', v_invoice_tot,
    'amount_paid_kobo', v_pay,
    'units',            v_units,
    'inventory_after',  v_inv_after,
    'batch_ids',        v_batch_ids,
    'replayed',         false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.receive_stock(uuid, uuid, uuid, uuid, jsonb, timestamptz, bigint, text, text) FROM public;
GRANT EXECUTE ON FUNCTION public.receive_stock(uuid, uuid, uuid, uuid, jsonb, timestamptz, bigint, text, text)
  TO authenticated, service_role;

COMMIT;

-- =============================================================================
-- Verification (paste into the SQL editor while authenticated as a business user):
--
--   1. Functions exist:
--        SELECT proname FROM pg_proc
--         WHERE pronamespace = 'public'::regnamespace
--           AND proname IN ('add_product','update_product','receive_stock')
--         ORDER BY proname;   -- expect 3 rows
--
--   2. Tenant guard fires for another business:
--        SELECT public.add_product('<other-biz>', gen_random_uuid(), '<store>', 'X');
--        -- expect ERROR: tenant_mismatch
--
--   3. add_product with opening stock 10 @ 500 creates products + inventory(10)
--      + one cost_batches row {qty_remaining 10, qty_original 10, cost_kobo 500}.
--
--   4. receive_stock posts a supplier invoice (debit), increments inventory, and
--      pushes one receipt-dated cost_batches row per line at the delivery cost.
--
--   5. Idempotent replay: a second add_product / receive_stock with the same id
--      returns replayed=true and applies nothing new.
-- =============================================================================
