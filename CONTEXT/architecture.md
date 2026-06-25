# Reebaplus POS — Architecture

## Overview

Reebaplus POS is an offline-first Flutter application backed by Supabase. The device is the source of truth for the active session: every read and write hits a local Drift (SQLite) database first, and a background sync engine reconciles that local state with Postgres on Supabase. The app is built so that a cashier can run the entire selling loop — cart, checkout, receipt, wallet update — with no network at all, and have it converge with every other device in the same business once a connection returns. This document defines the technology stack, the folder-level boundaries, the storage model, the auth and access model, the sync (background task) model, and the invariants the codebase must never violate.

## Stack

| Layer | Technology | Role |
|---|---|---|
| Client app | Flutter (Dart) | Single mobile codebase (Android/iOS) for the entire POS UI and business logic. |
| State management | Riverpod | App-wide state, dependency injection, and reactive rebuilds. All repositories and services are exposed as providers; widgets never construct dependencies directly. |
| Local database | Drift over SQLite | On-device source of truth. Holds all business data (products, orders, customers, suppliers, wallet ledgers, staff, roles, permissions) plus the sync outbox. Every screen reads from Drift, never from the network. |
| Local key–value store | flutter_secure_storage | Device-local secrets and session pointers: the active user's PIN hash, the active business/store IDs, and the auth refresh token. Never synced. |
| Cloud database | Supabase Postgres | Cloud source of truth and the convergence point across devices. Holds the authoritative copy of all business data and enforces Row-Level Security. |
| Cloud auth | Supabase Auth | Identity provider supporting **email + OTP** and **Google OAuth**. Issues the JWT that authorizes all Postgres and RPC access; the resolved email is the canonical identity key. PINs are never part of this layer. All transactional auth email (OTP / login / Forgot PIN) is sent from the Reebaplus domain via Supabase Auth **Custom SMTP** (Resend) — a dashboard configuration, not app code. |
| Server logic | Postgres RPCs (SECURITY DEFINER functions) + one Edge Function | Server-side operations that must not run on the client: `redeem_invite_code` (staff join), `delete_business` (atomic Danger Zone deletion), and the `pos_pull_snapshot` pull RPC. **Edge Function `send-invite-email`** delivers the branded Reebaplus invite-code email; it is invoked **server-side by an AFTER INSERT trigger on `invite_codes` (via `pg_net`)** — never by the client. The app still makes **no client `functions.invoke` call**; `_shared/` holds the function scaffolding. Outbound email uses Resend; the function URL + shared hook secret live in Vault, the Resend key in Edge Function secrets. |
| Realtime | Supabase Realtime | Push channel that notifies a device that peer changes exist for its business, triggering a pull. Used as a signal, not as the transport for the data itself. |
| Background execution | In-process `SupabaseSyncService` (no separate isolate / WorkManager / BGTaskScheduler) | The sync engine runs in the app process, driven by Supabase Realtime signals, connectivity changes, and app-lifecycle events. Heavy report aggregation uses `compute()` where needed (e.g. profit report). |
| Network sensing | connectivity_plus | Detects connection type (WiFi / mobile data / poor or unknown / offline) at the start of each sync cycle. The result drives adaptive batch and page sizing on both the push and pull paths. |
| External admin | Admin Hub (separate web console) | Operator-only tool for managing subscription state. The app reads subscription status; it never writes it. |
| Crash capture | Custom global error handler → `error_logs` table | Catches uncaught errors, shows a calm fallback, and queues an error record through the same sync queue. |

## System Boundaries

The app is organized by responsibility across three top-level folders —
`lib/core/`, `lib/features/`, and `lib/shared/` — plus `main.dart`. UI reads
from Drift through DAOs and writes that must reach the cloud go through the
sync queue; widgets never construct dependencies directly (everything is wired
through Riverpod providers).

> **Note (2026-06-16 audit):** an earlier draft of this section described a
> `lib/data/{local,remote,repositories}` + `lib/sync/` + `lib/auth/` +
> `lib/permissions/` layout. That layering was never adopted. The table below
> documents the **actual** structure.

| Folder | Owns | Must not contain |
|---|---|---|
| `lib/features/<feature>/` | One vertical slice per domain area (`pos`, `cart`, `checkout`, `inventory`, `customers`, `orders`, `expenses`, `payments`/suppliers, `staff`, `auth`, `dashboard`/reports, `sync`, `profile`, `deliveries`). Each holds its own screens, widgets, Riverpod providers, and feature services. | Another feature's internal widgets. Cross-feature data is reached through shared/core providers and DAOs. Avoid direct Supabase calls except the sanctioned exceptions below. |
| `lib/core/database/` | Drift database definition: table schemas, DAOs, migrations, the `sync_queue` outbox, and `sync_queue_orphans`. The only place that issues SQL. | Network code, UI, or business rules beyond persistence. |
| `lib/core/services/` | The Supabase client wrapper and the in-process `SupabaseSyncService` (outbox drainer, adaptive push chunker, paginated pull reconciler, cursor management, retry/backoff, LWW conflict resolution, hard-delete reconciliation, onboarding pull sequencer). | UI / widget code. |
| `lib/core/permissions/` | Loads role and per-staff permission rows from Drift and exposes permission checks to the UI. Source of all gating decisions. | Hard-coded role logic. Permissions are data, read from tables. |
| `lib/core/` (`providers`, `theme`, `settings`, `utils`, `widgets`, `data`, `diagnostics`) | Cross-cutting primitives: global providers, the crash handler, theme/palette system, money/currency helpers, ID generation, static data (e.g. `nigerian_lgas.dart`), and shared low-level widgets. | Feature-specific logic. |
| `lib/shared/` | App-shell pieces shared across features: `main_layout.dart`, `navigation_service.dart`, shared models, utils, and widgets. | Feature-specific business logic. |
| `lib/features/auth/` | Session lifecycle: sign-in via email+OTP or Google OAuth, JWT/refresh handling, onboarding, the "Who's working?" picker, PIN set/verify, and auto-lock. `auth_service.dart` is the orchestrator. | Business/domain data access beyond the current identity. |

**Sanctioned direct-Supabase exceptions** (outside the normal Drift→sync-queue
path):
- `redeem_invite_code` RPC — staff sign-up auth bootstrap, must bypass the outbox.
- Sync Issues diagnostic screen — operator tooling.
- **`BusinessLogoService` (`lib/core/services/business_logo_service.dart`)** —
  uploads/downloads/deletes the business logo via Supabase Storage bucket
  `business-logos`. Storage objects are not tenant rows and have no Drift
  equivalent; the resulting public URL is written to `businesses.logoUrl` and
  syncs via the normal outbox. A local file cache at
  `<appDocs>/business_logos/<businessId>.png` ensures receipts render offline.

All ordinary business writes still go to Drift first and drain through the
`sync_queue`.

## Storage Model

Four storage locations, with a strict rule for what lives where. Business data goes to Drift (and syncs); secrets and pointers go to secure storage (and never sync); sync engine state goes to Drift (and never syncs); operator audit records go to Supabase only (and never reach the client). Nothing durable lives only in memory.

| What | Where | Why | Synced to cloud? |
|---|---|---|---|
| Products, categories, stock levels, expiry dates | Drift (SQLite) | Read on every POS interaction; must work fully offline. | Yes |
| Orders, order lines, payment records | Drift (SQLite) | Created offline at the till; converge across devices. | Yes |
| Customer & supplier profiles | Drift (SQLite) | Attached to sales offline; shared business-wide. | Yes |
| Wallet ledger rows (customer & supplier) | Drift (SQLite), **append-only** | Source of truth for balances. Balances are derived, never stored as a single mutable field. | Yes |
| Empty-crate movements (customer & supplier) | Drift (SQLite), **append-only** ledgers (`crate_ledger`, `supplier_crate_ledger`); per-owner balance caches (`customer_crate_balances`, `manufacturer_crate_balances`, `store_crate_balances`, `supplier_crate_balances`) | A customer owes US empties; we owe the SUPPLIER empties for the full crates they delivered (§3.13). The signed balance = SUM(quantity_delta); positive on the supplier side = we owe the supplier. Deposit value = outstanding crates × the per-manufacturer deposit rate. | Yes |
| Empty-crate opt-in flag (`businesses.tracks_empty_crates`) | Drift (SQLite), app-writable column, default `true` | Per-business onboarding opt-in that decouples crate tracking from business type. App-writable (on the businesses push whitelist), set explicitly at onboarding and editable in Settings → Business Info. **Combined gate:** every empty-crate surface is shown only when `businessTracksCrates(business)` — i.e. `isCrateBusiness(type)` (Bar / Beverage distributor) **AND** `tracks_empty_crates`. The type guard short-circuits first, so the `true` default can never leak crate UI into a non-crate type, and pre-migration crate tenants keep their features. | Yes |
| Staff, roles, permission rows, per-staff overrides | Drift (SQLite) | Gating must work offline; CEO edits propagate to all devices. | Yes |
| Expenses, supplier invoices/payments | Drift (SQLite) | Recorded offline; feed reports and ledgers. | Yes |
| Activity logs, error logs | Drift (SQLite); error captures use the `error_logs` table | Captured offline, including during a crash. | Yes (via the sync queue) |
| Sync outbox (pending local changes) | Drift (SQLite), dedicated `sync_queue` table (+ `sync_queue_orphans`) | Durable queue that survives app kill; drained by `SupabaseSyncService`. | No — it *is* the thing being drained |
| `sync_progress` (current sync phase, counts, timestamp) | Drift (SQLite), dedicated table | Written by the sync service after every chunk or pull page. Read by a Riverpod provider to drive progress UI. Never sent to the cloud. | No |
| `sync_meta` (stored pull cursor, last successful RTT, current chunk-size tier) | Drift (SQLite), dedicated table | Durable engine state that survives app kill. Cursor used for resumable pull; RTT used for self-tuning chunk sizing. Never sent to the cloud. | No |
| `sync_debug` (current adaptive chunk-size tier, last RTT ms) | Drift (SQLite), dedicated table | Written by the sync service each cycle for internal diagnostics screens. Never sent to the cloud. | No |
| Active user PIN hash | flutter_secure_storage | Device-local unlock factor. Never leaves the device. | **Never** |
| Auth refresh token / JWT | flutter_secure_storage | Session credential. | **Never** (re-issued by Supabase Auth) |
| Active business ID, active store ID, last-active staff pointer | flutter_secure_storage | Session pointers for cold start and the "Who's working?" picker. | No |
| Subscription status (Trial/Active/Inactive) | Drift (SQLite), read-only mirror | Surfaced in Settings and name badges. Written only by the Admin Hub via sync pull. | Pulled, never pushed |
| In-flight cart, transient UI state | Riverpod (memory) | Ephemeral working state for the current screen. | No |

### Sync ownership

- **Push:** a write the user makes locally → the DAO writes the row to Drift and enqueues a `sync_queue` entry. `SupabaseSyncService` later drains the queue in adaptive **row-count** chunks (WiFi/ethernet 25 / cellular 10 / floor 5 rows) determined by connectivity_plus, pushing each chunk via an authenticated `.upsert(onConflict:)` to PostgREST (not an Edge Function). A chunk is cleared from the queue only after the upsert confirms.
- **Pull:** Supabase Realtime signals that peer changes exist → `SupabaseSyncService` fetches changed rows in cursor-based pages ordered by `last_updated_at` + `id` (WiFi 500 / cellular 100 / poor 50 rows, floor 10), reconciles each page into Drift, advances the cursor only after a page is fully committed, and lets Riverpod providers watching those tables rebuild the UI. **Phase 2 routing rule (2026-06-22):** First/full pulls (`since == null`) always use the paginated per-table PostgREST path, regardless of connectivity — the monolithic `pos_pull_snapshot` RPC has no row cap on a full pull and can time out on large datasets. The RPC is used **only for incremental pulls (`since != null`) on a fast link (Wi-Fi/ethernet)**, where the payload is bounded by what changed since the cursor and one round-trip is cheaper. Slow-link incremental pulls also use paginated PostgREST.
- **Conflict resolution:** last-write-wins by server timestamp for mutable rows (e.g. a product price edited on two devices). **Exception:** wallet and supplier ledgers are append-only and never conflict — both rows survive, and the balance is recomputed from the full ledger.

## Auth & Access Model

Authentication is split deliberately into a **portable identity** and a **device-local unlock factor**, because one physical till is shared by many staff across a shift.

- **Identity (portable):** verified by Supabase Auth via one of two providers — **email + OTP** or **Sign in with Google (OAuth)** — either of which issues the JWT that authorizes all Postgres and RPC access. The provider is an authentication detail only; the resolved **email address is the canonical identity key** in both cases, so the same person signing in by email OTP or by Google with the same address is one identity. Recovery on a new device re-establishes a user through whichever provider their email is registered with.
- **Unlock factor (device-local):** a 6-digit PIN, stored only as a hash in `flutter_secure_storage` on that device. The PIN is never sent to the cloud and never stored in Postgres. It exists to let a staff member re-assert their identity quickly on a shared till without re-running the full provider sign-in (email OTP or Google).
- **Shared-till session:** a cold start shows the "Who's working?" picker. Selecting a card and entering that user's PIN unlocks *only* that identity. After inactivity the till auto-locks back to the picker; Switch User keeps the PIN, Log Out clears the leaving user's PIN and device pointer.

### Active sessions across multiple devices

An identity may hold **multiple active sessions simultaneously across different devices** (the previous single active session constraint has been disabled per product requirements). A *fresh* sign-in (email OTP **or** Google — both funnel through the same `CreatePin → BiometricSetup` path, which calls `setCurrentUser(freshSignIn: true)`) runs `AuthService._registerCloudSession`, which:

1. inserts/upserts this device's row into the cloud `sessions` table (`device_id` is a stable per-install id in `SharedPreferences`, surviving logout) to register the active device session on Supabase.

A device's session remains active until explicit logout, business deletion, or explicit session revocation.

If a session is explicitly revoked remotely:

- **Remote kick (online):** the realtime `UPDATE` on its own `sessions` row (`revoked_at` set, `id == currentSessionId`) calls `onCurrentSessionRevoked → _handleRemoteKick → fullLogout`. Message: *"You've been signed in on another device — signed out."* It lands on Welcome / Email entry.
- **Session-expired (its token was revoked while offline / it missed the event):** its persisted refresh token is rejected on the next auto-refresh, Supabase fires a real `signedOut` event, and `main.dart` flips `_supabaseHasSession = false`. With a local user still set, this renders `_SessionExpiredScreen`, which re-establishes the JWT via a fresh OTP **without** wiping the device (PIN, biometrics, and local data are preserved). `verifyLocalSessionStillActive` (a resume-time safety net) and the 30-day cloud `expires_at` are additional inputs to the same logout paths.

**Invariant of the kick:** `signOut(scope: SignOutScope.others)` is authenticated with the **current** access token and the server always preserves the requesting session, so the kick can **never** revoke the session of the device performing the sign-in. A device only ever expires because a *different* sign-in of the same identity revoked it — the Google provider is not special here; it is symmetric with email OTP. (Investigation 2026-06-18; diagnostic breadcrumbs `auth.session_lost` and `auth.session_expired_gate` are written to the synced `error_logs` table to attribute field reports.)

### Ownership and tenancy

- The unit of tenancy is the **business**. Every business-scoped row carries a `business_id`.
- **One email, one business.** An email maps to exactly one business in this phase, **regardless of how that email signs in** (email OTP or Google resolve to the same identity). Because a staff member's email is already bound to the business that invited them, that same email cannot create a new business — "Create a new business" with an already-registered email is rejected. A person who is staff at one business and wants to own another must use a different email; an email is freed to create a business only after it is no longer attached to one (the staff account is removed, or the business is deleted).
- A staff member belongs to one business and is assigned to one or more stores within it.
- **Authorization is enforced server-side by Postgres Row-Level Security**, keyed on the `business_id` (and store assignment) embedded in the JWT claims. The client cannot widen its own access by tampering with local data; RLS rejects any row outside the caller's business.
- **Permissions are data, not code.** Role rows and per-staff override rows live in tables. The `lib/core/permissions/` layer reads them and exposes the permission checks. UI uses hide-don't-block: an action the user lacks permission for does not render. The CEO tunes a role with a toggle in Settings, which is just a row edit that syncs — no code release.
- **Danger Zone:** permanent deletion of a business runs as a single atomic Postgres RPC, `delete_business` (two-gate: business name + PIN; cascade via `DELETE FROM businesses`). It deletes the business, all its staff accounts, and all business-scoped rows, and instructs every device to wipe local data and log out.

## Background Task Model

There is no AI or LLM component in this application. **Sync is the only background work**, and it is the most safety-critical subsystem, so it is specified tightly.

- **Where it runs:** in-process, inside `SupabaseSyncService` (no dedicated
  isolate, WorkManager, or BGTaskScheduler). It is driven by Supabase Realtime
  signals, `connectivity_plus` changes, and app-lifecycle events, and
  communicates all results — progress, debug state, and reconciled data — by
  writing to Drift so Riverpod providers can rebuild the UI.

### Push path — adaptive chunk sizing

At the start of every push the service reads the current connection type from `connectivity_plus` and selects a **row-count** chunk ceiling:

| Connection | Chunk ceiling |
|---|---|
| WiFi / ethernet | 25 rows |
| Cellular | 10 rows |
| Floor (any connection) | 5 rows |
| Offline | Skip dispatch; retry on next trigger |

Each chunk has a 15 s timeout. On a timeout the chunk size is halved; after 3 consecutive clean chunks it is doubled back toward the ceiling, so the engine self-tunes. `SupabaseSyncService` drains `sync_queue` one chunk at a time via `.upsert(onConflict:)`; a chunk is cleared only after the upsert confirms, and failures stay queued for retry with backoff.

> **Retry backoff is capped (§6.8).** A transient failure's next-attempt delay
> grows exponentially but is clamped to a ceiling (5 min normal / 15 min for an
> FK-deferred parent-not-yet-arrived case) so a row that has failed many times
> cannot drift hours into the future and stay stuck after a continuously-online
> device's transient cause has cleared. The 30 s periodic drain tick, a
> connectivity-recovery transition, and sign-in each re-evaluate eligibility.
>
> **Permanent failures auto-archive, and self-healing ones auto-recover
> (§6.8.1).** A genuinely permanent push failure (duplicate order number, RLS
> denial, bad parameter) is moved out of `sync_queue` into `sync_queue_orphans`
> for operator review on the Sync Issues screen. A periodic + connectivity-driven
> sweep re-enqueues only orphans whose cause is now known to self-heal — an
> FK-deferred parent that may have since arrived via a pull, and a ledger
> `created_at`-immutable conflict now scrubbed at the push boundary
> (`_ledgerCreatedAtScrubTables`). Each orphan carries an `auto_retry_count`
> (device-local, on both outbox tables) that survives re-orphaning, so a
> still-failing row is auto-retried a bounded number of times (3) and then parked
> for manual review rather than looping on the cloud. Terminal reasons are never
> auto-retried.

> **Append-only ledger rule:** for `payment_transactions`, `wallet_transactions`,
> and `supplier_ledger_entries`, void re-pushes drop `created_at` at the push
> boundary (`_ledgerCreatedAtScrubTables`) because the cloud owns it and treats
> it as immutable. See `[[project_ledger_void_created_at_scrub]]`.

> **Not implemented:** there is currently no push Edge Function, no server-side
> `413 Payload Too Large` cap, and no `sync_audit_rejected` operator table. An
> earlier draft specified a 200 KB cap with client-side batch-splitting on 413;
> that path was never built — oversized payloads are avoided up front by the
> small row-count chunk ceilings above.

### Pull path — paginated cursor-based pull (Fix 2)

The pull path is triggered by a Supabase Realtime signal (or a periodic fallback poll). Rather than fetching all rows changed since the cursor in one query, the sync service fetches in pages, using the same connectivity_plus tier for page size:

| Connection | Page size |
|---|---|
| WiFi | 500 rows |
| Mobile data | 100 rows |
| Poor signal / unknown | 50 rows |

The cursor stored in `sync_meta` advances **only after a page is fully reconciled into Drift**. If reconciliation fails mid-page the sync service retries that page before moving forward. The cursor never skips ahead past an uncommitted page. This makes push and pull symmetrical in their resilience to poor connectivity and large changesets.

### Sync progress and UI feedback (Fix 4)

After every push batch or pull page is processed, the sync service writes a row to `sync_progress` in Drift containing:

- total outbox entries pending
- entries dispatched so far
- current phase: `pushing` / `pulling` / `idle` / `error`
- current table group being pulled (used during onboarding — see below)
- timestamp

A Riverpod provider watches the `sync_progress` table and exposes this state to the UI. Any screen that triggers a bulk operation — inventory import, first launch, post-offline catch-up — must display a progress indicator driven by this provider showing actual counts (e.g. "Syncing 340 of 1,200 changes…"), not a static spinner. On completion the indicator must resolve to an explicit success or error state; it must not silently disappear.

### Initial onboarding pull — new device (Fix 5)

A new device joining a mature store has no stored cursor. The absence of a cursor in `sync_meta` is the onboarding condition. The sync service handles this as a paginated onboarding pull sequence with the following rules:

**Resumability:** onboarding is a sequence of cursor-advancing pages, identical in mechanism to Fix 2. If the app is killed mid-onboarding, the next launch detects the partial cursor and resumes from the last successfully committed page — it does not restart from scratch.

**No blocking onboarding gate (offline-first, 2026-06-24).** Onboarding entry is **never** gated behind a full-screen loading screen — that would contradict invariant #1. A fresh sign-in resolves its 4 render-critical tables (`profiles`, `businesses`, `stores`, `users`) **inline during the sign-in flow** via `syncMinimumLogin` (awaited on the sign-in/existing-account screen, behind that screen's own small inline spinner — not a post-login modal), so the user's business, stores, and role are known before PIN setup. After `setCurrentUser`, the device drops **straight into `MainLayout`** and the full pull (`pullChanges`) streams the catalogue and everything else in **live** — products, customers, suppliers, history appear reactively as their pages commit. The earlier blocking `FirstSyncScreen` / `_BackgroundPullLoading` ("Syncing Your Store") loaders were **removed**; a logged-in device — fresh or returning, online or offline — always reaches `MainLayout` immediately. Sync progress and failures surface **non-blockingly** (the online indicator and the Sync Issues screen), never as a screen that holds the user out.

**Table group order:** the sync service pulls in priority order: (1) roles and permissions, (2) staff, (3) products and categories, (4) active customer profiles, (5) suppliers and wallets, (6) historical orders and expenses, (7) activity logs. Progress is written to `sync_progress` per group and reflected by the non-blocking sync indicators (it no longer drives a blocking onboarding screen).

### Ordering, idempotency, and crash capture

- **Ordering & idempotency:** outbox entries are ordered and carry client-generated UUIDv7 IDs so replays are idempotent — re-sending a batch after a dropped connection can never double-apply a sale.
- **Crash capture as background work:** the global error handler writes an `error_logs` row through the same `sync_queue`, so an error report syncs by the same mechanism as a sale, without ever interrupting the till.

## Invariants

These are rules, not guidelines. Code that breaks one of these is wrong even if it compiles and the feature appears to work.

1. **The local database is the source of truth for the running app.** Every screen reads from Drift and every user write commits to Drift first. No widget, view model, or repository method may block the UI on a network call or read live data directly from Supabase to render a screen.

2. **PINs never leave the device.** A PIN (or its hash) is written only to `flutter_secure_storage`. It must never be placed in Drift, in an outbox row, in a network request, in a log line, or in Postgres. Identity and recovery run only through Supabase Auth (email + OTP or Google OAuth) — never through the PIN.

3. **Wallet and supplier ledgers are append-only.** A balance is always derived by summing ledger rows, never stored as a single mutable number and never edited in place. Corrections are new compensating rows. This is what makes "the wallet is the source of truth" true and conflict-free under sync.

4. **Every cloud write goes through the outbox.** A repository that needs to change cloud state writes to Drift and enqueues an outbox entry; it must not call Supabase directly. This guarantees offline durability, ordered delivery, idempotent retries, and adaptive batching through one and only one write path.

5. **Cross-business data access is impossible, and is enforced on the server.** Every business-scoped row carries a `business_id`, and Postgres Row-Level Security is the authority — the client is never trusted to scope its own queries. No code path may read or write a row outside the caller's `business_id`.

6. **Permissions are read from data, never hard-coded.** Gating decisions come exclusively from role and override rows via `lib/core/permissions/`. No feature may branch on a hard-coded role name (e.g. `if (role == 'Cashier')`); it must ask `can(action)`.

7. **A caught error never destroys in-progress work or shows a raw error screen.** The global handler shows a calm fallback, preserves the current cart and any uncommitted local state, and queues a crash log. A red/blank framework error screen reaching the user is a defect.

8. **Layer dependencies point one direction only.** `lib/features/<feature>` depends on `lib/core/` (database/DAOs, services, permissions, providers) and `lib/shared/`, never the reverse. Features must not reach into another feature's internal widgets; cross-feature data flows through core/shared providers and DAOs. `lib/core/services/` (the sync service) must not import widget/UI code. Ordinary business writes go through Drift DAOs and the `sync_queue`, not direct Supabase calls — the only sanctioned exceptions are the `redeem_invite_code` RPC (auth bootstrap) and the Sync Issues diagnostic screen. A cycle or an upward import is an architecture violation.

9. **One email is one identity is one business.** The resolved email — not the auth provider — is the identity key: signing in by email OTP or by Google with the same address must map to the same user, never create a second account. An email is bound to exactly one business; "Create a new business" with an already-registered email (including any staff member's email) must be rejected, not silently allowed to create a duplicate or orphan tenant.

10. **The pull cursor never advances past an uncommitted page.** The cursor stored in `sync_meta` is updated only after a pull page is fully reconciled into Drift and the transaction commits successfully. A failed or partial reconciliation must retry that page before the cursor moves. This rule is what makes both regular pulls and onboarding pulls resumable after an app kill.

11. **Entry is never blocked on a network pull — the catalogue streams in live (supersedes the old "gate the POS until the dataset is local" rule, 2026-06-24).** A logged-in device must always reach `MainLayout` immediately, whether fresh, returning, online, or offline — no full-screen "Syncing Your Store" loader may hold the user out (that would violate invariant #1). The 4 render-critical tables (`profiles`, `businesses`, `stores`, `users`) are pulled **inline during the sign-in flow** so the user's business/role is known before PIN setup; everything else (products, customers, suppliers, history) streams in **live via the background pull** while `MainLayout` is already rendering its empty-but-functional shell. A brand-new device that is offline at sign-in simply shows an empty store that fills the moment a connection returns — it is never trapped on a loader. Render-critical UI must therefore tolerate a not-yet-populated business/catalogue (null business ⇒ render an empty shell, never crash).
