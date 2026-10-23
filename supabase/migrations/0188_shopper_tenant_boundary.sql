-- #422: close membership-less access through writable profile pointers and
-- internal SECURITY DEFINER helpers. 0187 is reserved by the web checkout
-- handoff (reebaplus-web/docs/pos-handoff/0187_*); do not reuse that number.
-- No signature, table shape, status or money rule changes. Not deployed here.
-- #467 (Storage listing) and #468 (anon grants) remain separate prerequisites.
BEGIN;

-- business_id() and current_user_business_ids() currently trust profiles.
-- Self-only policies on profiles are insufficient: setting one's own pointer
-- to another tenant otherwise grants that tenant's rows. Keep self reads and
-- deletes unchanged. A direct insert/update may bind only the caller's existing
-- users link or a business they own. Bootstrap definer RPCs bypass RLS and
-- continue to establish the first profile atomically.
DROP POLICY IF EXISTS profiles_self_insert ON public.profiles;
CREATE POLICY profiles_self_insert ON public.profiles
  FOR INSERT TO authenticated
  WITH CHECK (
    id = auth.uid()
    AND (
      business_id IN (
        SELECT linked.business_id FROM public.current_user_linked_business() linked
      )
      OR business_id IN (SELECT b.id FROM public.businesses b WHERE b.owner_id = auth.uid())
    )
  );

DROP POLICY IF EXISTS profiles_self_update ON public.profiles;
CREATE POLICY profiles_self_update ON public.profiles
  FOR UPDATE TO authenticated
  USING (id = auth.uid())
  WITH CHECK (
    id = auth.uid()
    AND (
      business_id IN (
        SELECT linked.business_id FROM public.current_user_linked_business() linked
      )
      OR business_id IN (SELECT b.id FROM public.businesses b WHERE b.owner_id = auth.uid())
    )
  );

-- These are implementation details called by trusted definer entry points,
-- not client RPCs. Checked both mobile and web callers: only SQL calls them.
-- Revoking EXECUTE does not affect nested execution as the definer owner.
REVOKE EXECUTE ON FUNCTION public._checkout_draw_fifo(uuid, uuid, uuid, jsonb, timestamptz)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._checkout_insert_lines(uuid, uuid, uuid, jsonb, uuid, timestamptz)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._checkout_mint_order_number(uuid, uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._customer_wallet_balance(uuid, uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.seed_default_roles_for_business(uuid)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public._checkout_draw_fifo(uuid, uuid, uuid, jsonb, timestamptz)
  TO service_role;
GRANT EXECUTE ON FUNCTION public._checkout_insert_lines(uuid, uuid, uuid, jsonb, uuid, timestamptz)
  TO service_role;
GRANT EXECUTE ON FUNCTION public._checkout_mint_order_number(uuid, uuid)
  TO service_role;
GRANT EXECUTE ON FUNCTION public._customer_wallet_balance(uuid, uuid)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.seed_default_roles_for_business(uuid)
  TO service_role;

-- Present in the shared live schema/web baseline, absent in the mobile-only
-- migration chain. No mobile or web application caller was found. It probes
-- arbitrary email ownership as a definer, so keep it server-only when present.
-- Conditional ACL change also permits clean mobile-only database installs.
DO $$
BEGIN
  IF to_regprocedure('public.is_other_business_owner(text,uuid)') IS NOT NULL THEN
    EXECUTE 'REVOKE EXECUTE ON FUNCTION public.is_other_business_owner(text,uuid) '
      || 'FROM PUBLIC, anon, authenticated';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.is_other_business_owner(text,uuid) TO service_role';
  END IF;
END $$;

COMMIT;
