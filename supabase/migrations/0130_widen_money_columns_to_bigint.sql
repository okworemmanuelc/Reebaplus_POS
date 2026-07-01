-- migration: 0130_widen_money_columns_to_bigint
--
-- Root cause of a permanently-stuck outbox row (Sync Issues, 42 attempts):
--   supplier_ledger_entries:upsert →
--   PostgrestException 22003 "value \"12360040000\" is out of range for type integer"
--
-- Every monetary column in the cloud is stored in MINOR units (kobo) but was
-- typed `integer` (int4, max 2,147,483,647). int4 therefore silently caps money
-- at ₦21,474,836.47 — any legitimate amount above that (₦123,600,400.00 here)
-- is rejected on push with 22003 and jams the outbox forever. Locally the value
-- stores fine (SQLite INTEGER + Dart int are both 64-bit), so the row sits
-- un-uploadable — an "outbox is sacred" (Invariant #12) row that a schema
-- mismatch, not the client, made un-pushable.
--
-- Fix: widen ALL 34 int4 money columns to `bigint` (int8, max ~9.2e18). Once
-- widened, the stuck row(s) push successfully on the next retry — no data was
-- lost. This is a CLOUD-ONLY change: the Drift schema needs no migration (it is
-- already 64-bit), and `pos_pull_snapshot` returns `jsonb`, so widening is
-- transparent to the pull path.
--
-- Also widened the four crate-COUNT `balance` columns (not money, but int4)
-- for uniformity, so a future "any money-ish int4 left?" audit returns zero.
--
-- Verified before writing: none of these are GENERATED columns, and no view /
-- matview / RPC depends on their int4 type — so plain ALTER TYPE is safe.
-- ALTER TYPE bigint on an already-bigint column is a harmless no-op, so this
-- migration is re-runnable.

-- ── kobo (money, minor units) columns ────────────────────────────────────────
ALTER TABLE public.crate_size_groups   ALTER COLUMN deposit_amount_kobo    TYPE bigint;

ALTER TABLE public.customers           ALTER COLUMN wallet_limit_kobo      TYPE bigint;

ALTER TABLE public.expense_budgets     ALTER COLUMN amount_kobo            TYPE bigint;

ALTER TABLE public.expenses            ALTER COLUMN amount_kobo            TYPE bigint;

ALTER TABLE public.manufacturers       ALTER COLUMN deposit_amount_kobo    TYPE bigint;

ALTER TABLE public.order_crate_lines   ALTER COLUMN deposit_paid_kobo      TYPE bigint;
ALTER TABLE public.order_crate_lines   ALTER COLUMN deposit_rate_kobo      TYPE bigint;

ALTER TABLE public.order_items         ALTER COLUMN buying_price_kobo      TYPE bigint;
ALTER TABLE public.order_items         ALTER COLUMN total_kobo             TYPE bigint;
ALTER TABLE public.order_items         ALTER COLUMN unit_price_kobo        TYPE bigint;

ALTER TABLE public.orders              ALTER COLUMN amount_paid_kobo       TYPE bigint;
ALTER TABLE public.orders              ALTER COLUMN crate_deposit_paid_kobo TYPE bigint;
ALTER TABLE public.orders              ALTER COLUMN discount_kobo          TYPE bigint;
ALTER TABLE public.orders              ALTER COLUMN net_amount_kobo        TYPE bigint;
ALTER TABLE public.orders              ALTER COLUMN total_amount_kobo      TYPE bigint;

ALTER TABLE public.payment_transactions ALTER COLUMN amount_kobo           TYPE bigint;

ALTER TABLE public.price_lists         ALTER COLUMN price_kobo             TYPE bigint;

ALTER TABLE public.products            ALTER COLUMN buying_price_kobo      TYPE bigint;
ALTER TABLE public.products            ALTER COLUMN empty_crate_value_kobo TYPE bigint;
ALTER TABLE public.products            ALTER COLUMN retailer_price_kobo    TYPE bigint;
ALTER TABLE public.products            ALTER COLUMN wholesaler_price_kobo  TYPE bigint;

ALTER TABLE public.purchase_items      ALTER COLUMN total_kobo             TYPE bigint;
ALTER TABLE public.purchase_items      ALTER COLUMN unit_price_kobo        TYPE bigint;

ALTER TABLE public.quick_sale_requests ALTER COLUMN unit_price_kobo        TYPE bigint;

ALTER TABLE public.shipments           ALTER COLUMN total_amount_kobo      TYPE bigint;

ALTER TABLE public.supplier_crate_ledger ALTER COLUMN deposit_paid_kobo    TYPE bigint;

ALTER TABLE public.supplier_ledger_entries ALTER COLUMN amount_kobo        TYPE bigint;
ALTER TABLE public.supplier_ledger_entries ALTER COLUMN signed_amount_kobo TYPE bigint;

ALTER TABLE public.wallet_transactions ALTER COLUMN amount_kobo            TYPE bigint;
ALTER TABLE public.wallet_transactions ALTER COLUMN signed_amount_kobo     TYPE bigint;

-- ── crate-COUNT balances (not money; widened for uniformity) ─────────────────
ALTER TABLE public.customer_crate_balances     ALTER COLUMN balance TYPE bigint;
ALTER TABLE public.manufacturer_crate_balances ALTER COLUMN balance TYPE bigint;
ALTER TABLE public.store_crate_balances        ALTER COLUMN balance TYPE bigint;
ALTER TABLE public.supplier_crate_balances     ALTER COLUMN balance TYPE bigint;
