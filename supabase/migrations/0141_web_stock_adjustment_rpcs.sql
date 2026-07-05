-- 0141_web_stock_adjustment_rpcs.sql
--
-- Reebaplus — Web POS Slice 7 (issue #50). Stock adjustment with the approval
-- gate for the online web client, mirroring the mobile rule (§16.6.1, v34): a
-- stock keeper's Add/Remove is a PENDING request (no inventory change); a
-- manager/CEO's adjustment applies immediately, and a manager/CEO approves or
-- rejects a pending request.
--
-- SERVER DECIDES THE PATH (defence in depth, PRD): request_stock_adjustment
-- branches on the CALLER's role, not on a client flag — a caller who can approve
-- (CEO/Manager) applies straight away; anyone else with stock.adjust files a
-- pending request. approve_stock_adjustment is approver-only. So the web hiding
-- the wrong button is a convenience; the server enforces who gets which path.
--
-- TWO IMPLEMENTATIONS, ONE CONTRACT (ADR 0009): SQL twins of the mobile
-- StockAdjustmentRequestsDao (requestStockAdjustment / approveRequest /
-- rejectRequest) + InventoryDao.adjustStock. The request-vs-apply behaviour is
-- pinned by the golden fixtures (test/golden/stock_adjustment_scenario.dart).
-- An adjustment is a correction, not an inflow, so — like adjustStock — it does
-- NOT create a Cost Batch (only Add Product / Receive Stock do, 0140).
--
-- DEPLOY ORDER: after 0089 (stock_adjustment_requests) and 0135 (the
-- caller_has_permission / _assert_caller_owns_business helpers). Additive.

BEGIN;

-- ─── 1. caller_role_slug — the caller's active role slug for this business ────
--
-- SECURITY DEFINER, constrained to auth.uid() (can only ever answer about the
-- caller — same safe pattern as caller_has_permission, 0135). Used to decide the
-- approval path: 'ceo' / 'manager' can approve, everyone else requests.
CREATE OR REPLACE FUNCTION public.caller_role_slug(p_business_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user_id uuid;
  v_slug    text;
BEGIN
  SELECT id INTO v_user_id FROM public.users WHERE auth_user_id = auth.uid() LIMIT 1;
  IF v_user_id IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT r.slug INTO v_slug
    FROM public.user_businesses ub
    JOIN public.roles r ON r.id = ub.role_id
   WHERE ub.user_id = v_user_id
     AND ub.business_id = p_business_id
     AND ub.status = 'active'
   ORDER BY ub.last_login_at DESC NULLS LAST
   LIMIT 1;
  RETURN v_slug;
END;
$$;

REVOKE ALL ON FUNCTION public.caller_role_slug(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.caller_role_slug(uuid) TO authenticated, service_role;


-- ─── 2. _apply_stock_adjustment — the actual inventory movement ──────────────
--
-- Mirrors InventoryDao.adjustStock's default (non-transfer) path: increment or
-- guarded-decrement inventory, then one stock_adjustments row + one
-- stock_transactions row referencing it (movement_type 'adjustment', the
-- adjustment_id ref that satisfies the exactly-one-of-4-refs CHECK). Returns the
-- on-hand quantity after. A Remove that would take stock negative raises
-- insufficient_stock (rolling back the caller's transaction). No Cost Batch — an
-- adjustment is a correction, not an inflow.
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

  INSERT INTO public.stock_adjustments (
    id, business_id, product_id, store_id, quantity_diff, reason, performed_by,
    created_at, last_updated_at
  )
  VALUES (
    v_adj_id, p_business_id, p_product_id, p_store_id, p_delta,
    COALESCE(p_reason, 'Adjustment'), p_actor_id, v_now, v_now
  );
  INSERT INTO public.stock_transactions (
    id, business_id, product_id, location_id, quantity_delta, movement_type,
    adjustment_id, performed_by, created_at, last_updated_at
  )
  VALUES (
    gen_random_uuid(), p_business_id, p_product_id, p_store_id, p_delta, 'adjustment',
    v_adj_id, p_actor_id, v_now, v_now
  );

  RETURN v_new_qty;
END;
$$;

REVOKE ALL ON FUNCTION public._apply_stock_adjustment(uuid, uuid, uuid, int, text, uuid) FROM public;
-- Internal helper: only the SECURITY DEFINER RPCs below call it; not granted to clients.


-- ─── 3. request_stock_adjustment — stock keeper requests / manager applies ───
--
-- Idempotent on p_request_id.
CREATE OR REPLACE FUNCTION public.request_stock_adjustment(
  p_business_id  uuid,
  p_request_id   uuid,        -- idempotency key (client UUID)
  p_store_id     uuid,
  p_product_id   uuid,
  p_quantity_diff int,
  p_reason       text,
  p_summary      text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now       timestamptz := now();
  v_actor_id  uuid;
  v_slug      text;
  v_existing  text;
  v_summary   text;
  v_new_qty   int;
  v_is_approver boolean;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  IF NOT public.caller_has_permission(p_business_id, 'stock.adjust') THEN
    RAISE EXCEPTION 'permission_denied: stock.adjust'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_request_id IS NULL THEN
    RAISE EXCEPTION 'request_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_store_id IS NULL OR p_product_id IS NULL THEN
    RAISE EXCEPTION 'store_and_product_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF COALESCE(p_quantity_diff, 0) = 0 THEN
    RAISE EXCEPTION 'quantity_diff_must_be_nonzero' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Idempotent replay.
  SELECT status INTO v_existing FROM public.stock_adjustment_requests WHERE id = p_request_id;
  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object('request_id', p_request_id, 'status', v_existing,
                              'applied', v_existing = 'approved', 'replayed', true);
  END IF;

  SELECT id INTO v_actor_id FROM public.users WHERE auth_user_id = auth.uid() LIMIT 1;
  v_slug := public.caller_role_slug(p_business_id);
  v_is_approver := v_slug IN ('ceo', 'manager');
  v_summary := COALESCE(NULLIF(btrim(p_summary), ''),
                        CASE WHEN p_quantity_diff > 0 THEN 'Add ' ELSE 'Remove ' END
                          || abs(p_quantity_diff)::text || ' unit(s)');

  IF v_is_approver THEN
    -- Manager/CEO: apply immediately + record an approved request for the audit.
    v_new_qty := public._apply_stock_adjustment(
      p_business_id, p_product_id, p_store_id, p_quantity_diff, p_reason, v_actor_id);

    INSERT INTO public.stock_adjustment_requests (
      id, business_id, product_id, store_id, quantity_diff, reason, summary,
      requested_by, status, approved_by, approved_at, created_at, last_updated_at
    )
    VALUES (
      p_request_id, p_business_id, p_product_id, p_store_id, p_quantity_diff,
      COALESCE(p_reason, 'Adjustment'), v_summary, v_actor_id, 'approved',
      v_actor_id, v_now, v_now, v_now
    );

    INSERT INTO public.activity_logs (
      id, business_id, user_id, action, description, product_id, store_id,
      entity_type, entity_id, created_at, last_updated_at
    )
    VALUES (
      gen_random_uuid(), p_business_id, v_actor_id, 'stock_adjustment_approved',
      'Applied stock change: ' || v_summary, p_product_id, p_store_id,
      'stock_adjustment_request', p_request_id, v_now, v_now
    );

    RETURN jsonb_build_object('request_id', p_request_id, 'status', 'approved',
                              'applied', true, 'inventory_after', v_new_qty,
                              'replayed', false);
  END IF;

  -- Stock keeper: a pending request; NO inventory change.
  INSERT INTO public.stock_adjustment_requests (
    id, business_id, product_id, store_id, quantity_diff, reason, summary,
    requested_by, status, created_at, last_updated_at
  )
  VALUES (
    p_request_id, p_business_id, p_product_id, p_store_id, p_quantity_diff,
    COALESCE(p_reason, 'Adjustment'), v_summary, v_actor_id, 'pending', v_now, v_now
  );

  INSERT INTO public.activity_logs (
    id, business_id, user_id, action, description, product_id, store_id,
    entity_type, entity_id, created_at, last_updated_at
  )
  VALUES (
    gen_random_uuid(), p_business_id, v_actor_id, 'stock_adjustment_requested',
    'Requested approval: ' || v_summary, p_product_id, p_store_id,
    'stock_adjustment_request', p_request_id, v_now, v_now
  );

  RETURN jsonb_build_object('request_id', p_request_id, 'status', 'pending',
                            'applied', false, 'replayed', false);
END;
$$;

REVOKE ALL ON FUNCTION public.request_stock_adjustment(uuid, uuid, uuid, uuid, int, text, text) FROM public;
GRANT EXECUTE ON FUNCTION public.request_stock_adjustment(uuid, uuid, uuid, uuid, int, text, text)
  TO authenticated, service_role;


-- ─── 4. approve_stock_adjustment — manager/CEO approves or rejects ───────────
--
-- Approve applies the movement (adjustStock semantics) and flips the row to
-- 'approved'; reject flips to 'rejected' with no inventory change. Idempotent:
-- a request that is not 'pending' returns its current status unchanged.
CREATE OR REPLACE FUNCTION public.approve_stock_adjustment(
  p_business_id uuid,
  p_request_id  uuid,
  p_approve     boolean,
  p_reason      text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_now      timestamptz := now();
  v_actor_id uuid;
  v_slug     text;
  v_req      public.stock_adjustment_requests%ROWTYPE;
  v_new_qty  int;
BEGIN
  PERFORM public._assert_caller_owns_business(p_business_id);

  v_slug := public.caller_role_slug(p_business_id);
  IF v_slug NOT IN ('ceo', 'manager') THEN
    RAISE EXCEPTION 'permission_denied: approve_stock_adjustment'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_req FROM public.stock_adjustment_requests
   WHERE id = p_request_id AND business_id = p_business_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'request_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_req.status <> 'pending' THEN
    RETURN jsonb_build_object('request_id', p_request_id, 'status', v_req.status,
                              'replayed', true);
  END IF;

  SELECT id INTO v_actor_id FROM public.users WHERE auth_user_id = auth.uid() LIMIT 1;

  IF p_approve THEN
    v_new_qty := public._apply_stock_adjustment(
      p_business_id, v_req.product_id, v_req.store_id, v_req.quantity_diff,
      v_req.reason, v_req.requested_by);

    UPDATE public.stock_adjustment_requests
       SET status = 'approved', approved_by = v_actor_id, approved_at = v_now,
           last_updated_at = v_now
     WHERE id = p_request_id AND business_id = p_business_id;

    INSERT INTO public.activity_logs (
      id, business_id, user_id, action, description, product_id, store_id,
      entity_type, entity_id, created_at, last_updated_at
    )
    VALUES (
      gen_random_uuid(), p_business_id, v_actor_id, 'stock_adjustment_approved',
      'Approved stock change: ' || v_req.summary, v_req.product_id, v_req.store_id,
      'stock_adjustment_request', p_request_id, v_now, v_now
    );

    RETURN jsonb_build_object('request_id', p_request_id, 'status', 'approved',
                              'inventory_after', v_new_qty, 'replayed', false);
  END IF;

  -- Reject: no inventory change.
  UPDATE public.stock_adjustment_requests
     SET status = 'rejected', approved_by = v_actor_id, approved_at = v_now,
         last_updated_at = v_now
   WHERE id = p_request_id AND business_id = p_business_id;

  INSERT INTO public.activity_logs (
    id, business_id, user_id, action, description, product_id, store_id,
    entity_type, entity_id, created_at, last_updated_at
  )
  VALUES (
    gen_random_uuid(), p_business_id, v_actor_id, 'stock_adjustment_rejected',
    'Rejected stock change: ' || v_req.summary
      || COALESCE(' — ' || NULLIF(btrim(p_reason), ''), ''),
    v_req.product_id, v_req.store_id, 'stock_adjustment_request', p_request_id,
    v_now, v_now
  );

  RETURN jsonb_build_object('request_id', p_request_id, 'status', 'rejected',
                            'replayed', false);
END;
$$;

REVOKE ALL ON FUNCTION public.approve_stock_adjustment(uuid, uuid, boolean, text) FROM public;
GRANT EXECUTE ON FUNCTION public.approve_stock_adjustment(uuid, uuid, boolean, text)
  TO authenticated, service_role;

COMMIT;
