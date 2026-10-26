-- #422: owner-approved, specific-ID deletion fact for former member devices.
-- Rollout requires the RPC client before withdrawing legacy table access.
BEGIN;
CREATE OR REPLACE FUNCTION public.business_deletion_status(p_business_id uuid)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated' USING ERRCODE = '42501';
  END IF;
  RETURN EXISTS (
    SELECT 1 FROM public.deleted_businesses d WHERE d.business_id = p_business_id
  );
END;
$$;
REVOKE ALL ON FUNCTION public.business_deletion_status(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.business_deletion_status(uuid) TO authenticated, service_role;
COMMIT;
