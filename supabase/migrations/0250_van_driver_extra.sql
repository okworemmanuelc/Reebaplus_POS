-- 0250_van_driver_extra.sql
--
-- #730 / PRD #139, ADR 0019 — a van driver may charge ABOVE the load price. The
-- extra is recorded APART from shop sales ("record it separately"):
--
--   orders.driver_extra_kobo            what the customer paid above the load
--                                       value on this order. Default 0.
--   order_items.charged_unit_price_kobo the per-unit price actually charged when
--                                       above the load price. NULL = no extra.
--
-- `orders.total_amount_kobo` / `net_amount_kobo` / `amount_paid_kobo` and
-- `order_items.unit_price_kobo` / `total_kobo` KEEP THE LOAD PRICE, so every
-- revenue / profit / closing / Van Sales / driver-balance figure is untouched.
-- The extra is NOT shop revenue and is NOT owed to the shop. NOTHING that sums
-- revenue may read either column (web console: same rule, see the pos-parity
-- issue on this change).
--
-- Mirrors Drift schemaVersion 107. Deploy-ordering: land BEFORE any client on
-- v107 pushes an order row carrying these columns, or the upsert jams the outbox.
-- Money-column rule (0130): *_kobo MUST be bigint. Additive; no data touched.
-- No sync_registry / snapshot change: orders and order_items restore
-- pass-through and the snapshot RPC emits to_jsonb(t).

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS driver_extra_kobo bigint NOT NULL DEFAULT 0;

ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS charged_unit_price_kobo bigint;
