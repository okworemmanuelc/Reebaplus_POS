# Onboarding: store creation moves to a guided first-run tutorial

**Status:** draft plan — not yet filed as a PRD, no code written
**Date:** 2026-09-09
**Branch:** none cut yet (main is clean at `685f4ea`)

---

## 1. What the user asked for

Five changes, in their words:

1. **Remove store creation from onboarding.** Move it into a first-time
   tutorial that runs after sign-up.
2. **Block the user from doing anything in the app**, with a notification,
   until the first store exists.
3. **Run a guided tutorial after sign-up**: a modal pointing at the side menu
   ("tap here to open the side menu and create your first store") → auto-scroll
   the drawer to **Stores** → a second modal guiding them through creating the
   store → then continue on to **add a product**, **make a sale**, and
   **invite staff**.
4. **Do not auto-select a country.** Leave it blank.
5. **Country before phone number**, so choosing a country auto-selects the
   dial code; the user then types the **full local number including its
   leading zero** (`08135216317`), and the app stores `+2348135216317`.

Everything below is scoped to exactly that. Nothing else in onboarding changes.

---

## 2. What the code does today (verified, not assumed)

### 2.1 Onboarding is a 9-step wizard that commits once

[ceo_sign_up_screen.dart](lib/features/auth/screens/ceo_sign_up_screen.dart)
fades between nine steps on one screen:

| # | Step | Notes |
|---|---|---|
| 0 | Business name | |
| 1 | Business type (+ crate opt-in) | |
| **2** | **Your first store** | **store name, store phone, street address, country** |
| 3 | Full name | |
| 4 | Email | skipped when the email was verified upstream |
| 5 | OTP | skipped likewise |
| 6 | Create PIN | |
| 7 | Confirm PIN | **the atomic commit fires here** |
| 8 | "Business is ready" | |

Nothing reaches Supabase until Confirm PIN. Every step writes into
[onboarding_draft.dart](lib/features/auth/onboarding/onboarding_draft.dart),
which mints `businessId` / `storeId` / `userId` client-side so retries are
idempotent.

### 2.2 The store is created inside the atomic RPC

[auth_service.dart:1729](lib/shared/services/auth_service.dart#L1729)
`completeOnboarding` calls the cloud `complete_onboarding` RPC. The current
definition is
[0123_business_tracks_empty_crates.sql:19](supabase/migrations/0123_business_tracks_empty_crates.sql#L19),
and it does eight things in one transaction:

1. businesses 2. profiles **3. stores** 4. settings 5. users
6. seed default roles 7. bind CEO → role **8. bind CEO → store (`user_stores`)**

It **hard-rejects a null `p_store_id`**:

```sql
IF p_business_id IS NULL OR p_store_id IS NULL THEN
  RAISE EXCEPTION 'complete_onboarding requires non-null p_business_id and p_store_id';
```

`completeOnboarding` then mirrors businesses + stores + users into Drift, and
stamps `users.store_id` with the new store.

**So removing the store step is not a UI-only change** — it reaches the cloud
RPC, the local mirror, and the CEO's `user_stores` binding.

### 2.3 The country / phone defects the user is describing

- [ceo_sign_up_screen.dart:95](lib/features/auth/screens/ceo_sign_up_screen.dart#L95)
  — `String _countryValue = kDefaultCountry;` (Nigeria auto-selected).
- [ceo_sign_up_screen.dart:254](lib/features/auth/screens/ceo_sign_up_screen.dart#L254)
  — `_bootstrap` pre-fills the phone box with `+234`.
- On the step body, **phone renders above country**
  ([:973](lib/features/auth/screens/ceo_sign_up_screen.dart#L973) vs
  [:1004](lib/features/auth/screens/ceo_sign_up_screen.dart#L1004)).
- `formatPhoneNumber`
  ([:157](lib/features/auth/screens/ceo_sign_up_screen.dart#L157)) **already
  strips a leading `0` and prefixes the dial code** — so `08135216317` +
  `+234` already produces `+2348135216317`. The logic is right; what's wrong
  is that the dial code sits *inside the editable box*, so the user is typing
  around a `+234` prefix instead of just typing their number.
- [staff_sign_up_screen.dart](lib/features/auth/screens/staff_sign_up_screen.dart)
  has **all four of the same defects** ([:129](lib/features/auth/screens/staff_sign_up_screen.dart#L129),
  [:153](lib/features/auth/screens/staff_sign_up_screen.dart#L153),
  phone at [:1112](lib/features/auth/screens/staff_sign_up_screen.dart#L1112)
  above country at [:1166](lib/features/auth/screens/staff_sign_up_screen.dart#L1166)).

### 2.4 "Store phone" is not the store's phone

Per the 2026-09-08 audit already recorded in
[progress-tracker.md](context/progress-tracker.md), the field labelled *Store
phone* is written to `draft.businessPhone` → `p_business_phone` →
**`businesses.phone`**. The `stores` table has no phone column. This matters:
it means country + phone are *business* fields that were only ever living on
the store step by accident, and they can stay in onboarding after the store
step is removed.

### 2.5 There is already a "Get started" checklist to build on

[get_started_checklist.dart](lib/features/dashboard/get_started_checklist.dart)
+ [get_started_card.dart](lib/features/dashboard/widgets/get_started_card.dart)
already track **add a product → make a sale → invite the team** — three of the
four tutorial stops the user wants. Its design rule is worth keeping:
**completion is derived from data, never stored as a flag**, so it is
cross-device correct for free and survives a reinstall. Only the manual
dismissal is device-local.

The tutorial should extend this, not run in parallel with it.

### 2.6 The New Store sheet is not safe to put on the critical path

[stores_screen.dart:190](lib/features/stores/screens/stores_screen.dart#L190)
writes via a raw `db.into(db.stores).insert(...)`. It therefore:

- bypasses `StoresDao.createStore`
  ([daos_stores_sessions.dart:36](lib/core/database/daos_stores_sessions.dart#L36))
  and the business-scoping invariant,
- never sets `kind` (so the row is not explicitly a store vs a van),
- logs no activity,
- **never writes the `user_stores` binding**, and
- its `stores.manage` write-boundary check `return`s silently instead of
  calling `showGateDenied`.

This was already flagged as "known, not fixed". Making it the *first* store a
business ever creates promotes it from a background defect to a first-run bug.

### 2.7 No coach-mark package is installed

`pubspec.yaml` has no `tutorial_coach_mark` / showcase package. The spotlight
overlay is either a new dependency or ~200 lines in-repo.

---

## 3. Design decisions

### D1 — Country + phone stay in onboarding; only the *store* leaves

Step 2 stops being "Your first store" and becomes **"How do we reach you?"**:

```
Country      (blank, required — drives dial code AND currency)
Phone number (local digits, e.g. 08135216317)
Currency: NGN   ← derived line, shows a placeholder until a country resolves
```

Store name and street address move to the tutorial. This keeps the wizard at
nine steps, so `_displayTotal` / `_displayStep` dot math is untouched, and it
keeps `businesses.phone` and the currency default collected before commit —
both of which the RPC needs.

### D2 — Phone entry splits the dial code out of the editable box

The dial code becomes a **read-only affix** rendered beside the input, not
text inside it. The user types only local digits. Rules:

- Field is **disabled until a country resolves** to a dial code, with the
  helper text "Choose your country first".
- Input formatter: digits only (drop the current `[0-9+]` allowance — there is
  no `+` to type any more).
- On submit, keep the existing `formatPhoneNumber` logic verbatim: strip a
  leading `0`, prefix the dial code. `08135216317` + `+234` → `+2348135216317`.
  **No behavioural change to the stored value.**
- `_applyDialCode` (the fix that stopped country edits wiping the phone) gets
  *simpler*, not more complex: the box now holds only local digits, so a
  country change swaps the affix and touches the text field not at all.

### D3 — `complete_onboarding` learns to skip the store

New migration **`0178_complete_onboarding_optional_store.sql`**:

- relax the null-check to `p_business_id` only,
- wrap step 3 (stores insert) and step 8 (`user_stores` insert) in
  `IF p_store_id IS NOT NULL THEN … END IF`.

The **parameter list does not change**, so `CREATE OR REPLACE` replaces the
function in place — this does **not** hit the RPC param-add overload trap that
bit us before (a new param would have created a second signature and a
PGRST203). Old clients that still send a `p_store_id` keep working unchanged,
which is what makes the cloud-first deploy safe.

### D4 — The blocking gate reads local Drift, not the network

A new full-screen `FirstStoreRequiredScreen` slots into
[`_HomeRouter._resolve`](lib/main.dart#L677) **after** the subscription gate
and **before** the driver terminal, mirroring how `SubscriptionLockedScreen`
already blocks.

The gate keys on a **business-scoped local count of non-deleted stores**, and:

- while the count is unresolved → render nothing new (fall through to the
  existing branded splash, exactly like `localBusinessesProvider` does today);
- count > 0 → `MainLayout`, unchanged;
- count == 0 **and the user is CEO** → the blocker, with the create form;
- count == 0 **and the user is not CEO** → the blocker, but with "Your CEO
  needs to finish setting up. Nothing to do here yet." and **no form** — a
  Cashier must never be able to mint the business's first store.

This does **not** violate invariant #11 as written: `stores` is one of the four
render-critical tables pulled *inline during sign-in* by `syncMinimumLogin`,
so a zero count at `MainLayout` time is a resolved local fact, not a
still-in-flight pull. It is nonetheless a new class of screen that stands
between a logged-in user and `MainLayout` — see §5, this needs an explicit
invariant amendment before it is built.

### D5 — The tutorial extends the Get-started checklist, it does not fork it

`GetStartedStepId` gains a **first, non-optional, non-dismissible** step:

```dart
enum GetStartedStepId { createStore, addProduct, makeSale, inviteTeam }
```

`createStore.done` derives from the same local store count as D4 — no new
stored flag, consistent with the existing "derive, never store" rule. The one
new persisted bit is a device-local cursor for *which coach mark to show next*,
alongside the existing `get_started_checklist_dismissed_v1` pref.

Dismissal rules change slightly: the card may not be dismissed while
`createStore` is undone (the gate makes dismissal meaningless anyway), and the
three later steps stay dismissible exactly as today.

### D6 — Build the spotlight in-repo, do not add a package

A `CoachOverlay` in `lib/shared/widgets/`: a full-screen scrim with a cut-out
around a target `GlobalKey`'s rect, a caption card, and Next / Skip. Reasons:
the two candidate packages are heavier than the need, `ui-context.md` forbids
raw hex/radius/spacing values so a third-party widget would need wrapping
anyway, and this has to cooperate with the existing drawer `ScrollController`
and `nav.mainScaffoldKey`. Local, animated presentation state is exactly what
`code-standards.md` permits a `ConsumerStatefulWidget` for.

---

## 4. Implementation slices

Sliced to obey `ai-workflow-rules.md`: one boundary per step, migration before
its consumer, UI never in the same step as sync/service code. Each slice is
independently verifiable and independently shippable.

### Slice 0 — cloud: make the store optional in the RPC *(deploy first)*
`supabase/migrations/0178_complete_onboarding_optional_store.sql`

- `CREATE OR REPLACE` with the identical signature; guard steps 3 and 8 on
  `p_store_id IS NOT NULL`; relax the null-check.
- `supabase db push` (pre-authorised). Verify with a null-store call against a
  scratch business, and confirm no PGRST203 overload appeared.
- **Ships alone.** No client change depends on it yet; old clients unaffected.

### Slice 1 — service: onboarding stops creating a store
`onboarding_draft.dart`, `auth_service.dart`

- Draft: drop `storeId`, `locationName`, `streetAddress`, `locationCombined`.
  Keep `country`, `currency`, `businessPhone`.
- `completeOnboarding`: send `p_store_id: null`, `p_location: null`; drop the
  `stores` insert from the local mirror; drop `storeId` from the `users`
  mirror (the column is nullable and is already only a *fallback* behind
  `lockedStoreId` — see [stream_providers.dart:2133](lib/core/providers/stream_providers.dart#L2133),
  [checkout_page.dart:190](lib/features/pos/screens/checkout_page.dart#L190)).
- Delete `test/auth/onboarding_draft_location_test.dart` (it tests
  `locationCombined`, which no longer exists) and replace it with a test
  asserting the RPC payload carries a null store.

### Slice 2 — cloud/DAO: a correct first-store write path
`daos_stores_sessions.dart`, `stores_screen.dart`

Fix §2.6 *before* anything routes a first store through it:

- New `StoresDao.createFirstStore` (or a flag on `createStore`) that, in one
  transaction: creates the store with an explicit `kind`, calls
  `UserStoresDao.assign(currentUserId, storeId)`
  ([daos_stores_sessions.dart:343](lib/core/database/daos_stores_sessions.dart#L343)),
  stamps `users.store_id`, and writes the activity log.
- Repoint the New Store sheet at it; replace the silent `return` with
  `showGateDenied`.

### Slice 3 — UI: the blocking first-store gate
`main.dart`, new `lib/features/stores/screens/first_store_required_screen.dart`

- New `localStoreCountProvider` (business-scoped, `watchActiveStores().length`).
- `_HomeRouter._resolve` branch per D4.
- The screen: brand background, "One more thing — set up your first store",
  the store form (name + street address; country inherited from the business),
  and the non-CEO variant with no form.

### Slice 4 — UI primitive: `CoachOverlay`
`lib/shared/widgets/coach_overlay.dart`

- Scrim + cut-out + caption + Next/Skip, positioned from a target `GlobalKey`.
- Pure widget, no tutorial knowledge. Golden/widget-tested on its own.

### Slice 5 — state: the tutorial cursor
`get_started_checklist.dart`

- Add `createStore` per D5; add the persisted next-stop cursor; keep the pure
  `computeGetStartedChecklist` unit testable with no widget tree.

### Slice 6 — wiring: the guided sequence
`main_layout.dart`, `app_drawer.dart`, `home_screen.dart`

- Drawer: add a `ScrollController` and a `GlobalKey` on the **Stores** item so
  the tutorial can scroll it into view (the drawer is a plain `ListView` at
  [app_drawer.dart:334](lib/shared/widgets/app_drawer.dart#L334) with no
  controller today).
- Sequence, driven by the cursor: point at the menu button → open the drawer
  via `nav.mainScaffoldKey` → animate-scroll to Stores → point at Stores →
  (user creates the store; the gate lifts) → point at Add Product → Make a
  Sale → Invite Staff, each deep-linking the way `GetStartedCard` already does.
- Every stop is skippable; skipping leaves the Get-started card in place.

### Slice 7 — the country/phone changes
`ceo_sign_up_screen.dart`, then `staff_sign_up_screen.dart`, then
`app_decorations.dart`

- `authInputDecoration` gains an optional dial-code affix
  ([app_decorations.dart](lib/core/theme/app_decorations.dart) — it currently
  takes only `label` + `prefixIcon`).
- CEO step 2 → "How do we reach you?" per D1/D2: blank country, country first,
  digits-only local phone, disabled until a country resolves.
- Staff sign-up: identical treatment (§2.3). **Separate commit** — different
  screen, and the staff flow has no store to remove, so it must not be
  entangled with the store work.

### Slice 8 — docs
`architecture.md`, `project-overview.md`, `progress-tracker.md`, new ADR

- **ADR 0026 — "A business with no store cannot open the shell"**: records the
  gate, why the store left the atomic commit, and the invariant amendment.
- `architecture.md` invariant #11 amendment (see §5).
- `project-overview.md` "Core User Flow" steps 2–3 and the Authentication &
  Onboarding feature bullet ("CEO sign-up (9 steps)" and the store-details
  list) both describe the old flow and go stale the moment Slice 1 lands.
- `progress-tracker.md` after each slice.

---

## 5. The one thing that needs your decision before Slice 3

**Invariant #11 says a logged-in device must always reach `MainLayout`
immediately** — "no full-screen loader may hold the user out". The
first-store gate is a full-screen screen that holds the user out.

I believe the gate is *right* and the invariant needs a narrow, explicit
carve-out, because a store-scoped shell over zero stores is not a degraded
experience, it is a broken one: `selectableStoresProvider` returns empty,
`lockedStoreId` never resolves, and POS/Inventory/Orders all render
store-filtered views with no store to filter to. But `ai-workflow-rules.md` is
explicit that the invariants are not mine to edit, so I am surfacing it rather
than writing the amendment myself.

**Proposed wording** to append to invariant #11:

> The single exception is structural, not a loader: a business with **zero
> local stores** renders `FirstStoreRequiredScreen` instead of `MainLayout`.
> This is a resolved *local* condition (`stores` is one of the four tables
> pulled inline at sign-in), never a wait on a network pull, and it clears the
> instant a store row lands from either the local create or the pull.

There is one residual edge case worth naming: a **brand-new device that is
offline at sign-in**. Invariant #11 promises that device "an empty store that
fills the moment a connection returns" — with this gate, a CEO in that state
sees the create form and could mint a duplicate store. Mitigation in Slice 3:
the form is CEO-only and, when the device has never completed a pull for this
business, the screen leads with "We couldn't reach the server — if you already
have a store, connect first" above the form rather than presenting creation as
the only option.

---

## 6. Test plan

| Slice | Coverage |
|---|---|
| 0 | RPC called with null store → business/user/roles seeded, no `stores` row, no `user_stores` row. Called with a store id → unchanged behaviour (regression). |
| 1 | Draft has no store fields; RPC payload asserts `p_store_id == null`; `users.store_id` is null after commit. |
| 2 | First store creates the row **and** the `user_stores` binding **and** stamps `users.store_id`; non-`stores.manage` user gets `showGateDenied`, not a silent no-op. |
| 3 | `_HomeRouter` resolves: 0 stores + CEO → gate with form; 0 stores + Cashier → gate without form; 1 store → `MainLayout`; unresolved → splash. |
| 4 | `CoachOverlay` positions its cut-out over a target key; Skip dismisses. |
| 5 | `computeGetStartedChecklist` with the new 4th step: cursor advances, `createStore` cannot be dismissed. |
| 6 | Drawer scrolls Stores into view; sequence advances on store creation. |
| 7 | Country blank on first paint; phone disabled until a country resolves; `08135216317` + Nigeria → `+2348135216317`; changing country after typing preserves the digits (the regression the 2026-09-08 audit fixed). Both CEO and staff screens. |
| all | `flutter analyze` clean; `flutter test` green; landscape suite (`test/auth/auth_landscape_screens_test.dart`) still passes with the reshaped step 2. |

---

## 7. Open questions

1. **Invariant #11 amendment** — §5. Blocking for Slice 3.
2. **Does the tutorial re-run?** Proposal: no. It is driven by derived data, so
   it naturally reappears if a business somehow ends up with zero products
   again. A "Replay tutorial" entry in Settings is *not* in scope unless asked.
3. **Store phone.** Today's "Store phone" is really `businesses.phone` (§2.4).
   The plan keeps it as a business field labelled "Phone number". If you want a
   genuine per-store phone, that is a new `stores` column + migration — say so
   and it becomes its own slice.
4. **Existing businesses.** Every current tenant has a store, so the gate is
   invisible to them and no backfill is needed. Worth confirming against prod
   before Slice 3 ships.
