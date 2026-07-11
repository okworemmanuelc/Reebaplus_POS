# Industry is a configuration profile over one shared model, resolved by a normalizer

**Status:** accepted (2026-07-06); rollout amended 2026-07-11 (see Amendment)

> **Amendment (2026-07-11) — narrow the *offered* set to three, keep the registry
> whole.** The "unlock all nine now" rollout below is superseded for the current
> phase: onboarding and the Settings → Business Info picker offer **only three**
> industries — **Beverage distributor, Pharmacy, Frozen Foods & Grocery** — chosen
> as the focus verticals "for now." The other six are **retained in the registry
> and *removed from the pickers*** (rendered nowhere, not greyed "coming soon"),
> gated by a `selectable` flag on the `Industry` entry. Crucially this is a
> *picker* filter only: `industryOf()` still iterates the full registry, so any
> tenant already onboarded on a now-hidden type keeps normalizing correctly and
> keeps its lexicon + crate gate (no `generic` fallback, no data migration). The
> per-industry Lexicons for all nine stay in place for the same reason. The
> reduction is a deliberately reversible flag flip, not a deletion. Everything
> else in this ADR (config-over-one-model, the normalizer, the lexicon, the
> product photo) stands unchanged.

The app ships built for a Beverage distributor: onboarding shows seven industries
but only Beverage distributor is selectable (`business_types.dart` +
`ceo_sign_up_screen.dart` `_businessTypes`), and the interior speaks beverage —
"crate", "bottle", "empties" — because those nouns are hardcoded across ~23
feature files. The ask is to (1) unlock every industry and add two new ones
(**Phone & Gadgets**, **Frozen Foods & Grocery** → nine total), (2) make the
app's language, guidance, presets, form fields, and feature surfaces adapt to the
chosen industry, and (3) add an optional product photo to the Add/Update Product
forms for all industries. The deep per-industry tailoring is explicitly phased —
"one industry after another" — so this ADR records the *foundation* those later
slices build on, not each industry's flow.

The defining constraint is the offline sync architecture: one Drift source of
truth, one sync registry, one outbox, RLS keyed on `business_id`. Any design that
multiplies the data model or screen set per industry multiplies migrations, RLS
policies, and sync failure modes. The existing crate feature is the proof point:
industry-conditioned behaviour already ships as a `bool` flag
(`tracks_empty_crates`) + a string normalizer (`isCrateBusiness`) gate over the
shared model — not a separate app. This ADR generalises that one pattern.

Decisions locked (grilled 2026-07-06):

- **Architecture = configuration over one shared model.** An industry is a
  *profile* layered on the single products/POS/inventory/orders model, never a
  per-industry data model or plugin runtime. Industry-specific tracking (crates,
  expiry, IMEI/serial, cold-chain) is optional fields/flags gated by the profile.
  A truly alien flow (restaurant table-service, pharmacy dispensing) becomes an
  individually-flagged sub-flow inside the shared shell, not a fork.

- **Identity = a total normalizer over `businesses.type`, no new column, no
  migration.** `businesses.type` is unconstrained `text` on both client (Drift
  `text().nullable()`) and cloud (plain `text`; the crate gate in migration `0137`
  already normalizes `lower(trim(type)) IN (...)`). A single `Industry` enum is
  keyed by `industryOf(String? type)`, mapping known display strings → a stable
  slug and **anything unknown/null → a safe `generic` profile** (never a crash,
  never a blank app). The two duplicated industry lists collapse into one
  registry that carries display label + icon + profile. Rejected: a stable
  `businesses.industry_id` column — it buys only cloud-side filterability at the
  cost of a synced schema change + backfill, against the house rule (the reason
  `isCrateBusiness` normalizes instead of migrating).

- **Terminology = swap the key nouns only, app-shipped, generic fallback.** Only
  the domain nouns that read wrong cross-industry change (item name, unit,
  category; beverage-only nouns like crate/empties stay scoped to the beverage
  profile so they cannot leak). Neutral words (Save/Price/Stock/Search) are left
  literal. The words are compile-time constants in the registry — **not**
  CEO-editable and **not** synced; the CEO picks an *industry*, not individual
  words. Owner word-customization and broad per-industry copy (screen titles,
  help text, receipts) are rejected for now as large surface for small gain;
  either can be added later. Implementation must audit which hardcoded nouns are
  genuinely industry-sensitive to avoid slot-sprawl.

- **Feature morph = industry decides, with a few owner switches.** Each profile
  lists its relevant extras; most turn on automatically, a small number stay an
  owner opt-in where behaviour genuinely varies within an industry (mirroring the
  `tracks_empty_crates` switch). Rejected: a long list of manual per-feature
  toggles at setup.

- **Rollout = unlock all nine now, tailor extras later.** Every industry becomes
  selectable immediately on the shared feature set + its words + basic starter
  categories/units; per-industry extras (IMEI capture, expiry alerts, cold-chain,
  etc.) land afterwards, one industry per PR, and availability is never blocked on
  them. Deferred out of this body of work: barcode/IMEI **scanning**, the deep
  per-industry flows, and any price-tier redesign (tiers keep today's
  Retailer/Wholesaler structure; only their *labels* change via the lexicon).

- **Industry is editable after onboarding, data preserved.** Switching (already
  possible via Settings → Business Info) changes the words and which optional
  features show/hide; existing products and history are untouched — a hidden
  industry-specific field keeps its data and simply stops rendering. Consistent
  with the editable crate switch; rejected locking it (rigid, and extra work to
  remove editability that exists today).

- **Product photo = one per product, cloud-synced, on the detail/edit screen.**
  Optional image on both Add and Update Product. It uploads to Supabase Storage
  and shows on every device (surviving reinstall), reusing the `BusinessLogoService`
  pattern (instant local-cache render + offline upload queue). Scoped to the
  product detail/edit screen for now — **not** the POS grid and **not** receipts
  (both easy to add later). Rejected: local-only images (useless on a shared
  multi-device till) and a multi-photo gallery (a larger separate feature).
