# Brief — First-Load "Loading your store" Overlay Redesign

**Audience:** the developer/agent implementing this feature.
**Status:** PRD / handoff brief — ready for agent. Read top to bottom before writing code.
**Triage:** ready-for-agent (no further triage needed).
**Goal in one sentence:** make the post-login "Loading your store" indicator a brief
(≤ 2 s) reassurance that hands off to background sync + skeletons, instead of a
full-screen loader that overstays for the entire pull.

---

## 0. Read these first (non-negotiable)

This is a mature, spec-driven, local-first codebase. You do **not** invent patterns.
Before touching anything, read, in order:

1. `context/project-overview.md`
2. `context/architecture.md` — stack, storage model, **Invariants**
3. `context/ui-context.md` — the design-token system (your styling bible)
4. `context/code-standards.md`
5. `context/ai-workflow-rules.md`
6. `context/progress-tracker.md` — update it after every unit
7. `CLAUDE.md` at repo root

**House rules that will bite you:**
- This team runs on an **emulator / `flutter run`**, never `flutter build apk`.
- **Never `git checkout` a dirty file** — the repo carries large uncommitted trees.
  To undo, re-edit or stash. Do not run `dart format` globally.
- Styling routes through the token system (`Theme.of(context).colorScheme.*`,
  `AppRadius.*`, `context.getRSize(n)`, `AppDecorations`, `AppSemanticColors`).
  No raw colours / radii / pixel sizes.

---

## 1. Problem Statement

A store owner or staff member who has just signed in (or relaunched a fresh / wiped
device) sees a centered **"Loading your store"** overlay with a spinner and a
percentage. They expect it to flash briefly and get out of the way. Instead it
**overstays — sometimes for many seconds, even on a strong, stable internet
connection** — and the app feels frozen because there is nothing usable behind it.

From the user's perspective: *"My internet is fine, so why am I staring at a loading
screen? Is the app broken?"*

The underlying causes (for the implementer's context, not the user's):
- The overlay's visibility is bound 1:1 to the **entire** background pull
  (`PullStage.background` until `completed`). It only clears when the whole
  `pullChanges` finishes.
- On a full pull the slow part is **not** the network — it's the **sequential local
  restore** of every row into Drift (`_restoreTableData` in FK-safe order). Thousands
  of orders / order-items / ledger rows take seconds-to-tens-of-seconds to write
  regardless of bandwidth.
- The percentage ticks once **per table**, so one large table parks the bar at a
  single number → looks frozen.
- It shows on **every** background pull where the device has no cached data, with no
  upper time bound and no decoupling from completion.

## 2. Solution

From the user's perspective:
- After sign-in the overlay appears **only when the store has no data yet** (a fresh
  or wiped device). A returning device that already has data **never** sees it — its
  content is simply there, with a thin sync line at the top.
- When it does appear, it shows for **at most ~2 seconds** — and disappears sooner the
  moment the first real content for the screen they landed on is ready.
- After it disappears, the user sees **skeleton placeholders** of their actual screens
  (POS, Home, Inventory, Reports) that fill in with real data as it streams in, while
  a **thin top progress line** quietly continues the sync in the background. The app is
  navigable the whole time.
- The progress feels **smooth** (weighted by how much data has actually arrived, not
  jumping per table), and the copy is **warm and specific** — *"Setting up ‹Business
  Name›…"*.
- If the sync genuinely can't reach the server, the app **retries quietly a couple of
  times**, and only then shows a **clear, prominent retry** — never a permanently empty,
  broken-looking screen.

## 3. User Stories

1. As a store owner signing in on a brand-new device, I want a brief loading
   reassurance that names my business, so that I trust the right store is loading.
2. As a store owner on a fast connection, I want that reassurance to disappear within
   about two seconds, so that the app never feels stuck.
3. As a cashier landing on the POS screen during first sync, I want to see a skeleton
   of the product grid immediately, so that I understand products are on the way and
   the screen isn't broken.
4. As a stock keeper landing on the Home/dashboard during first sync, I want a skeleton
   of the dashboard, so that I know my data is loading.
5. As any user during first sync, I want the bottom navigation and drawer to stay
   tappable while data loads, so that I can move around instead of waiting on a blocker.
6. As a user whose store has fully loaded in under a second, I want the overlay not to
   linger artificially, so that I get to work immediately (subject to a small minimum to
   avoid a flicker).
7. As a returning user who already has my store cached on this device, I want to land
   straight on my data with no full-screen loader, so that re-opening the app is instant.
8. As a returning user, I still want a thin, unobtrusive top sync line when a background
   catch-up is running, so that I know the app is staying up to date without it
   interrupting me.
9. As a user watching first sync, I want the progress to advance smoothly in proportion
   to the data actually arriving, so that it never looks frozen on a big table.
10. As a user whose first sync is taking a while, I want the overlay to step aside to
    skeletons after the time cap even if not everything has arrived, so that I can begin
    using whatever is ready.
11. As a user on a flaky connection whose first sync fails, I want the app to retry on
    its own a couple of times while I'm online, so that a momentary blip resolves itself
    without my involvement.
12. As a user whose retries are exhausted, I want a clear, prominent "couldn't reach
    your store — retry" control, so that I can act, rather than facing an empty screen
    with only a tiny notice.
13. As a user who is offline at first launch, I want to be told plainly that there's no
    connection and offered retry, so that I'm not left watching a spinner that can never
    finish.
14. As a user whose store genuinely has no products yet (an established but empty store),
    I want to see my normal empty state — not a perpetual "loading" — so that the app
    reflects reality.
15. As a user who was signed out / wiped and is re-onboarding, I want the first-load
    overlay to correctly reappear, so that I'm not dropped onto an empty screen with no
    indication data is being restored.
16. As a multi-business user, I want first-load behaviour tracked per business, so that
    loading one business for the first time behaves correctly regardless of others
    already loaded on the device.
17. As a user pulling-to-refresh, I want the existing refresh animation to remain the
    sole indicator, so that I don't see two competing sync animations at once.
18. As a user who navigates between tabs during first sync, I want each tab to show its
    own skeleton until its data arrives, so that every screen feels consistent.
19. As a user, I want a brief "Synced ✓" confirmation when the catch-up finishes, so
    that I know the store is fully up to date.
20. As a user on a large store, I want the restore step to be fast, so that "loading"
    reflects real progress and ends promptly rather than dragging.
21. As a low-vision user, I want the loading text, progress, and retry control to honour
    the app's typography and contrast tokens, so that they're legible.

## 4. Implementation Decisions

Use the existing sync vocabulary throughout: `PullStage` / `PullStatus`,
`pullChanges`, `syncMinimumLogin`, `_restoreTableData`, the `MainLayout` shell, the
`SyncPullBanner`, `AppRefreshWrapper`, the per-business `last_sync_timestamp` cursor,
and `clearAllData`. Respect the **Invariants** in `architecture.md` (local-first,
offline-first entry gate — never block app open on a network pull).

**4.1 A single first-load overlay controller (the one seam).**
Introduce one Riverpod-managed controller that is the *sole* source of truth for the
overlay. It exposes a small state — conceptually:

```
enum FirstLoadOverlayState { hidden, loading, retryNeeded }
```

It derives that state from inputs it watches (it owns no UI):
- the pull state machine (`PullStatus` — stage plus new row-weighted counters),
- connectivity (online / offline),
- whether the local store is empty (live core-table row counts via business-scoped
  DAO reads — never raw `db.select` of business-owned tables),
- a per-business "first full pull completed" marker,
- a role-aware "landing screen data ready" signal.

`SyncPullBanner` and the tab screens **render** this state; they do not re-derive it.
All timers, the retry counter, and eligibility live in the controller so the behaviour
is testable in isolation and survives widget rebuilds.

**4.2 Eligibility — when `loading` may show.**
`loading` is eligible only when the background pull is running **and** the local store
is empty **and** the business has **no** "first full pull completed" marker. Live row
counts are the primary truth (self-healing after a wipe); the per-business marker is the
*only* thing that distinguishes "empty because this is first load" from "empty because
the store genuinely has no products yet," so an established-but-empty store is **not**
shown a loader on every launch. The marker is set on a clean `pullChanges` completion
and **must be cleared inside `clearAllData()`** alongside the tenant wipe — otherwise a
re-onboarded device wrongly suppresses the overlay. (See the documented `clearAllData`
wipe traps in architecture/progress notes — static/marker state that isn't cleared on
wipe is a recurring class of bug here.)

**4.3 Dismiss timing.**
The overlay shows for a **minimum ~400 ms** (anti-flicker) and a **maximum ~2 s**.
Within that window it dismisses as soon as **the landing screen's data is ready** or the
pull completes. The landing-ready signal is role-aware: the POS landing is ready when
products are present locally; the Home/dashboard landing is ready when its stats
resolve, defaulting to products-present as a universal fallback. After dismiss, the
thin top sync line continues until the pull completes.

**4.4 Skeletons.**
There is **no** shimmer/skeleton primitive today and **no** `shimmer` dependency. Build
**one** reusable themed shimmer primitive (e.g. a skeleton box / line driven by an
animation, coloured via the token system + glassy decorations), then compose lightweight
skeletons for the four bottom-nav destinations: **POS** (product grid), **Home**
(dashboard cards), **Inventory** (list), **Reports** (cards). Each tab renders its
skeleton while first-load is active and that tab's own data is still empty, and resolves
to real content as data streams in. Skeletons are non-blocking.

**4.5 Row-weighted progress.**
Replace the per-table percentage with a **row-weighted** one. Before the restore loop,
compute the total row count across the tables that have rows in the snapshot; advance a
"rows done" counter as each table restores (per-batch when batching lands). Surface
`rowsDone` / `rowsTotal` on `PullStatus`; the overlay percentage and the thin top line
both read from it. The overlay copy is *"Setting up ‹Business Name›…"* (business name is
already available pre-`MainLayout` because `syncMinimumLogin` fetches `businesses`),
falling back to *"Setting up your store…"* if the name is missing.

**4.6 Restore batching (performance).**
The restore loop is the real cause of "stays too long." Convert per-row inserts to a
**single batched transaction per table** where FK-resilience is not required. For the
FK-resilient tables (currently row-by-row by design to catch FK failures), use a
**two-pass** approach: attempt a batch insert, and fall back to the existing per-row
resilient path only on failure. This must not change restore *correctness* — the
FK-deferral / orphan-skip / hold-cursor semantics are preserved exactly; only the write
mechanics get faster.

**4.7 Failure & retry.**
On a first-load pull failure: if online, the controller schedules up to **2 silent
retries** (≈2 s then ≈5 s) before surfacing anything; after both fail it enters
`retryNeeded`. If offline, it enters `retryNeeded` immediately (no pointless spinning).
The `loading` element stays non-interactive (taps pass through to nav). The `retryNeeded`
element is a **prominent, interactive centered card** with a real Retry action — not the
small bottom pill — whenever the store is still empty. The existing compact error pill
and "Synced ✓" pill behaviour for already-populated devices is unchanged.

**4.8 Invariants preserved.**
Offline-first entry gate (app open is never gated on a network pull); `AppRefreshWrapper`
remains the only `RefreshIndicator` and the sole pull-to-refresh animation; a manual
pull still suppresses the banner's top line; all store-scoped reads go through
business-scoped DAO methods; active store remains `lockedStoreProvider`.

## 5. Testing Decisions

Prefer the **highest, fewest** seams — ideally the two below; do not scatter assertions
across widgets.

**Seam A — the first-load overlay controller (primary, highest seam).**
Drive the controller in a `ProviderContainer` with overridden inputs (a fake
`PullStatus` notifier, fake connectivity, fake core-table emptiness, fake landing-ready
signal) — following the existing `ProviderContainer` / `overrideWith` prior art in the
settings and auth tests. Assert the full state machine without any widget tree:
- empty + first-load + background ⇒ `loading`; populated device ⇒ stays `hidden`.
- dismiss at the ready signal before the cap; dismiss at the cap when not ready; respect
  the minimum-display floor (no flicker when the pull completes immediately).
- established-empty store (marker set, DB empty) ⇒ `hidden`, not a perpetual loader.
- wipe path: clearing the marker re-enables `loading`.
- failure escalation: online ⇒ N silent retries then `retryNeeded`; offline ⇒
  `retryNeeded` immediately.

**Seam B — the restore path (existing `@visibleForTesting` seam).**
Reuse the established `_restoreTableData` test seam exercised by
`*_pull_restore_test.dart` / `restore_fk_resilience_test.dart` (in-memory Drift, bare
unauthenticated Supabase client, snake_case "cloud" payloads). Assert:
- batched restore lands the same rows as the per-row path (parity), and the FK-resilient
  fallback still skips orphans and holds the cursor exactly as before
  (`restore_fk_resilience_test` must stay green).
- the row-weighted counters (`rowsDone` / `rowsTotal` on `PullStatus`) advance correctly
  as tables restore.

Good tests here assert **behaviour at these two seams**, not pixel layout of the
skeletons. A light widget test may confirm `SyncPullBanner` renders `loading` vs
`retryNeeded` from a given controller state, but the logic lives — and is tested — in
the controller.

## 6. Out of Scope

- **The deferred-pull repeated-full-pull loop.** When a pull defers / FK-skips, the
  per-business cursor is cleared so the *next* pull runs full again — which is likely why
  some businesses re-pull fully on *every* launch and overstay *every* time. Fixing the
  cursor/deferral correctness is a deeper change into core sync with real blast radius
  and is **tracked separately**, not part of this brief.
- **Time-boxing `syncMinimumLogin`.** The pre-`MainLayout` blocking 4-table fetch
  ("Setting up your account…" on the auth screen) is left as-is.
- **Changing the Drift schema, migrations, DAOs' business logic, or the sync engine's
  pull ordering / RLS.** Only the restore *write mechanics*, the `PullStatus` progress
  fields, and the overlay/skeleton presentation change.
- **Reworking the pull-to-refresh path** (`AppRefreshWrapper`) or the success/error pill
  behaviour for already-populated devices.

## 7. Further Notes

- Confirm the exact `clearAllData()` call site clears the per-business "first full pull
  completed" marker before relying on it — a stale marker after a wipe is the single
  highest-risk regression in this brief.
- The landing route is role-derived (cashier/owner → POS, stock keeper → Home); the
  landing-ready signal must follow whatever route `MainLayout` actually lands on, with
  products-present as the safe default.
- "Stable internet but still slow" is expected to be **mostly** explained by restore cost
  (§4.6) and **partly** by the out-of-scope repeated-full-pull loop (§6). Implementers
  should set expectations accordingly: this brief makes the *experience* smooth and
  bounded; the repeated-full-pull fix is what makes the *underlying* work smaller.
- Update `context/progress-tracker.md` and add a dated `BUILD_LOG.md` entry once landed.
