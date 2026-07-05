# Reebaplus Web POS

The **online-first** browser client for Reebaplus POS. Unlike the Flutter mobile
app (offline-first, Drift-backed), the Web POS reads the Supabase cloud live over
RLS-scoped PostgREST and (in later slices) writes money through server RPCs — no
Drift, no outbox, no offline mode. See the decisions in
[`../docs/adr/0007`–`0012`](../docs/adr/) and the PRD
[`../docs/prd/web-pos.md`](../docs/prd/web-pos.md).

## Slice 2 — cash-sale checkout keystone (issue #43)

The selling loop, end to end, on the server-authoritative write path:

- **Grid → cart → checkout → receipt.** Tapping a product adds it to a
  session-persistent cart (`CartProvider`); the cart shows qty steppers, remove, a
  **role-capped discount**, and live line/order totals. Checkout takes
  cash/transfer + the amount paid; the receipt prints (print-only stylesheet) and
  shares/downloads (Web Share with a text-file fallback); "Done — back to POS"
  clears the cart. Grid-beside-cart on tablet+, a sticky bottom bar + sheet on
  phone.
- **`checkout_order` RPC (ADR 0008, migration `0135`).** The web's only
  money-write: one `SECURITY DEFINER` atomic transaction — Order at `pending` +
  items, FIFO cost-batch draw-down under a row lock with per-line COGS snapshot,
  inventory guard that **rejects an oversell at commit**, a collision-proof server
  order number (`WEB-…`, never the mobile `ORD-…`), revenue recognized at
  Checkout, and server-side `sales.make` + discount-cap enforcement. The sale
  reaches the mobile tills through their existing Realtime pull.
- **Golden-Scenario Suite (ADR 0009).** Shared fixtures (`../test/golden/fixtures/`)
  run against both the Dart DAO (mobile) and the SQL RPC (web) in CI
  (`.github/workflows/golden-scenarios.yml`); any drift in the money math fails the
  build.

## Slice 1 — the walking skeleton (issue #47)

Thin but end-to-end through **auth → live read → render**:

- **Auth (ADR 0011).** Email + OTP and Google sign-in. The Supabase session _is_
  the Operator for the tab; business/store scope resolves server-side from
  `profiles.business_id` (`current_user_business_ids()`), no custom JWT claims.
  Idle inactivity re-locks the tab to the sign-in screen.
- **Live catalogue.** RLS-scoped read of categories + per-tier prices
  (Retailer / Wholesaler) + on-hand stock, rendered in the POS grid. Realtime
  hardening is Slice 5 (#49); here a manual **Refresh** re-pulls.
- **Responsive shell** across four bands — phone / tablet / desktop / large.
- **Theming parity.** The five business palettes (blue / amber / purple / green /
  b&w, light + dark) ported from the mobile `AppTheme`, applied at the app root.
  The active palette is the synced `business_design_system` setting, applied live.
- **Permission-read layer.** Reads the same `role_permissions` / override rows the
  mobile Gate Registry reads and applies hide-don't-block (CEO all-on).
- **Currency** is formatted from the business `default_currency` setting, never
  hard-coded.

## Stack

Next.js (App Router) + React + TypeScript + `@supabase/supabase-js`. The whole
data layer is a single browser Supabase client (`src/lib/supabase/`).

## Local development

```bash
npm install
npm run dev        # http://localhost:3000
npm run build      # production build (also runs type-checking)
npm run typecheck  # tsc --noEmit
```

Supabase config (URL + anon key) has public defaults baked into
`src/lib/supabase/config.ts` — the same client-public, RLS-gated values the
mobile app hardcodes — so the app runs with **zero env setup**. To point at a
different Supabase project, set `NEXT_PUBLIC_SUPABASE_URL` and
`NEXT_PUBLIC_SUPABASE_ANON_KEY` in a `.env.local` (git-ignored) or in the Vercel
project's environment variables.

To sign in you need an account already onboarded to a business on the mobile app
(a `profiles` row with a `business_id`).

## Deployment (Vercel)

- **Project root:** `web-pos/` (monorepo subdirectory — ADR 0012). Vercel
  auto-detects Next.js.
- **Env vars:** optional; set `NEXT_PUBLIC_SUPABASE_URL` /
  `NEXT_PUBLIC_SUPABASE_ANON_KEY` to override the baked-in defaults.
- **Supabase Auth config:** add the deployed origin (and
  `https://<domain>/auth/callback`) to the project's **Auth → URL Configuration →
  Redirect URLs** so Google OAuth returns to the app.

## Layout

```
src/
  app/                 App Router: layout, entry page, /auth/callback
  components/
    auth/              LoginForm (email OTP + Google), IdleLock
    providers/         SessionProvider (session + Operator), ThemeProvider
    permissions/       Can / useCan — hide-don't-block gate
    shell/             AppShell — responsive shell + gated nav
    pos/               PosScreen, ProductCard — the live product grid
  hooks/               useIdleTimeout, useCurrency
  lib/
    supabase/          browser client + public config
    theme/palettes.ts  the five palettes (ported from mobile colors.dart)
    operator.ts        loads Operator (business, role, permissions, settings)
    catalogue.ts       loads categories + products + stock
    permissions.ts     resolveEffectivePermissions (mirrors mobile)
    currency.ts        formatCurrency / formatKobo (ported from mobile)
    types.ts           cloud row shapes (snake_case)
```
