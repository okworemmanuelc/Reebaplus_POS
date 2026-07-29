-- 0169_drop_purchase_payment_type.sql
--
-- Reebaplus — #202 dead-code sweep, item 3: drop the never-written `purchase`
-- value from the `payment_transactions.type` CHECK. Parent: PRD #155 ("Further
-- Notes" promised this sweep; it never ran).
--
-- The cloud half of Drift schema v77.
--
-- ── Why this value is dead ──────────────────────────────────────────────────
--
-- `purchase` has been in the type CHECK since 0001 and NOTHING has ever written
-- it:
--   · Dart — every `payment_transactions` insert goes through one of five
--     seams, and each passes a literal: `sale` / `crate_deposit` /
--     `wallet_topup` (daos_orders `_insertCheckoutPaymentRow`), `expense`
--     (daos_expenses), `refund` (daos_orders cancel + CreditLedgerService),
--     `van_remittance` (daos_van_sales). The only parameterised writer,
--     `PaymentsDao.postReversalPayment`, is called with `refund` / `expense` /
--     `wallet_topup`, or copies the ORIGINAL row's type — which can never be
--     `purchase` if nothing ever wrote one.
--   · Cloud — every RPC that inserts a payment row (0006 / 0007 / 0008 / 0009 /
--     0011 / 0014 / 0017 / 0045 / 0073 / 0091 / 0092 / 0135 / 0136 / 0137 /
--     0139 / 0160 / 0163 / 0164) hardcodes `sale`, `expense`, `refund`,
--     `wallet_topup` or `van_remittance`. None writes `purchase`.
--   · The `'purchase'` string does appear elsewhere in this tree, but always as
--     `stock_transactions`' ref-type discriminator for `purchase_id` — a
--     DIFFERENT table's column, unrelated to payment types.
--
-- Both prior CHECK edits (0153's `crate_deposit`, 0163's `van_remittance`) were
-- widenings that copied `purchase` along without questioning it. PRD #155
-- established that every money movement is one of the six real types, and a
-- seventh that no writer produces is a trap: the next reader will reasonably
-- assume goods purchases land here. They don't — a purchase is a SUPPLIER
-- INVOICE (`shipments` + `supplier_ledger_entries`) plus an `expense` /
-- supplier payment. Do not resurrect this value for it.
--
-- ── Ordering rule this migration obeys ──────────────────────────────────────
--
-- This is the FIRST NARROWING of this CHECK, so unlike 0153 / 0163 it can fail
-- on existing data. It cannot in practice (no writer has ever produced such a
-- row), but a money row must never be destroyed to make a constraint fit, so
-- the DO block below SKIPS the narrowing outright if any `purchase` row exists
-- and RAISES A WARNING naming the count. Drift's v77 step makes the same call
-- for the same reason (a failed rebuild would brick the client on open).
--
-- The skip is ONE-SHOT on both sides, so recovery is deliberate, not automatic:
-- this file is recorded in `supabase_migrations.schema_migrations` whether or
-- not it narrowed anything, and the client's `user_version` lands on 77 either
-- way. If the warning ever fires, reclassify the offending rows and then EITHER
-- `supabase migration repair --status reverted 0169` + `db push` to replay this
-- file, OR — better, because it also re-narrows the affected clients — ship the
-- fix as a NEW numbered migration plus its own Drift step. Do not hand-edit
-- this file after it has been applied.
--
-- DEPLOY ORDER: this narrowing is safe to push AHEAD of the v77 client — a v76
-- client still only ever pushes the six live types, so nothing it can produce
-- trips the tightened CHECK. The reverse order is equally safe. There is no
-- outbox-jam window either way.
--
-- MIGRATION-NUMBER LANE: 0169 is #202's. 0168 (#197) precedes it; 0170 is
-- reserved for #201.
--
-- No columns are added or changed, so no *_kobo / BIGINT concern (0130) and no
-- `pos_pull_snapshot` edit (that array only changes for a new TABLE).

BEGIN;

-- ═══ Narrow the type CHECK: drop 'purchase' ═════════════════════════════════
-- The constraint is named `payment_transactions_type_check` (0153 named it;
-- 0163 re-added it under the same name). Look it up by DEFINITION anyway so
-- this also works against a database still carrying 0001's unnamed inline
-- CHECK, then re-add the narrowed form under the stable name.
--
-- Idempotent three ways: a CHECK that no longer mentions `purchase` is left
-- alone; a database with `purchase` rows is left alone (with a warning); and a
-- re-run after a successful narrowing is a no-op.
DO $$
DECLARE
  v_conname text;
  v_def     text;
  v_rows    bigint;
BEGIN
  SELECT c.conname, pg_get_constraintdef(c.oid)
    INTO v_conname, v_def
    FROM pg_constraint c
   WHERE c.conrelid = 'public.payment_transactions'::regclass
     AND c.contype  = 'c'
     AND pg_get_constraintdef(c.oid) ILIKE '%type%'
     AND pg_get_constraintdef(c.oid) ILIKE '%sale%'
   LIMIT 1;

  -- Already narrowed (idempotent re-run) — nothing to do.
  IF v_def IS NOT NULL AND v_def NOT ILIKE '%''purchase''%' THEN
    RETURN;
  END IF;

  -- Refuse to narrow around live data. A payment row is append-only money; it
  -- is never deleted to satisfy a constraint. Leave the wider CHECK in place
  -- and say so loudly instead of aborting the deploy.
  SELECT count(*) INTO v_rows
    FROM public.payment_transactions
   WHERE type = 'purchase';

  IF v_rows > 0 THEN
    RAISE WARNING
      '0169: % payment_transactions row(s) have type = ''purchase''; leaving '
      'the CHECK wide rather than destroying a money row. Reclassify them, '
      'then ship the narrowing as a NEW migration (this one is already '
      'recorded and will not replay on its own).',
      v_rows;
    RETURN;
  END IF;

  IF v_conname IS NOT NULL THEN
    EXECUTE format(
      'ALTER TABLE public.payment_transactions DROP CONSTRAINT %I', v_conname
    );
  END IF;

  ALTER TABLE public.payment_transactions
    ADD CONSTRAINT payment_transactions_type_check
    CHECK (type IN
      ('sale','expense','refund','wallet_topup','crate_deposit',
       'van_remittance'));
END $$;

COMMIT;

-- =========================================================================
-- Verification (manual):
--   SELECT pg_get_constraintdef(oid) FROM pg_constraint
--     WHERE conname = 'payment_transactions_type_check';
--     -- expect: CHECK (type IN ('sale','expense','refund','wallet_topup',
--     --                         'crate_deposit','van_remittance'))
--
--   SELECT count(*) FROM public.payment_transactions WHERE type = 'purchase';
--     -- expect: 0
--
--   INSERT INTO public.payment_transactions (business_id, amount_kobo, method, type)
--     VALUES ('<biz>', 1, 'cash', 'purchase');       -- expect 23514
--
--   -- the six live types still insert (spot-check one):
--   INSERT INTO public.payment_transactions (business_id, amount_kobo, method, type)
--     VALUES ('<biz>', 1, 'cash', 'van_remittance'); -- expect the parent CHECK
--                                                    -- (23514) only, not a type
--                                                    -- violation
-- =========================================================================
