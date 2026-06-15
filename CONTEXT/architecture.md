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
| Cloud auth | Supabase Auth | Identity provider supporting **email + OTP** and **Google OAuth**. Issues the JWT that authorizes all Postgres and Edge Function access; the resolved email is the canonical identity key. PINs are never part of this layer. |
| Server logic | Supabase Edge Functions (Deno/TypeScript) | Server-side operations that must not run on the client: applying sync batches transactionally, generating invite codes, and the atomic Danger Zone business deletion. |
| Realtime | Supabase Realtime | Push channel that notifies a device that peer changes exist for its business, triggering a pull. Used as a signal, not as the transport for the data itself. |
| Background execution | Dart isolate + WorkManager (Android) / BGTaskScheduler (iOS) | Runs the sync engine off the UI thread and reschedules it when the app is backgrounded or killed. |
| Network sensing | connectivity_plus | Detects connection type (WiFi / mobile data / poor or unknown / offline) at the start of each sync cycle. The result drives adaptive batch and page sizing on both the push and pull paths. |
| External admin | Admin Hub (separate web console) | Operator-only tool for managing subscription state. The app reads subscription status; it never writes it. |
| Crash capture | Custom global error handler → `crash_logs` table | Catches uncaught errors, shows a calm fallback, and queues a crash record through the same sync outbox. |

## System Boundaries

The app is organized into layers by responsibility. Each folder owns one concern and may only depend on the layers below it. UI never reaches past the repository layer; repositories never know about widgets or the network transport directly.

| Folder | Owns | Must not contain |
|---|---|---|
| `lib/features/<feature>/` | One vertical slice per domain area (`pos`, `cart`, `checkout`, `inventory`, `customers`, `orders`, `expenses`, `suppliers`, `staff`, `auth`, `reports`, `settings`). Each holds its own widgets, Riverpod providers, and view models. | Direct SQL, direct HTTP calls, or another feature's internal widgets. Cross-feature data is reached through `data/repositories`. |
| `lib/data/local/` | Drift database definition: table schemas, DAOs, migrations, and the outbox table. The only place that issues SQL. | Network code, UI, or business rules beyond persistence. |
| `lib/data/remote/` | The Supabase client wrapper and Edge Function callers. The only place that talks to the network. | UI, Drift queries, or business rules. |
| `lib/data/repositories/` | The boundary every feature talks to. Reads from Drift, writes to Drift, and enqueues an outbox row for anything that must reach the cloud. Decides local-vs-remote; callers never do. | Widgets, raw `http`, or direct Supabase calls (those go through `data/remote`). |
| `lib/sync/` | The background sync engine: outbox drainer, adaptive push batcher, paginated pull reconciler, cursor management, retry/backoff, conflict resolution, onboarding pull sequencer, sync progress writer, and 413 batch-split recovery. Runs in its own isolate. Communicates all results — including progress and debug state — only by writing to Drift. | Any UI code. Must not import any widget or Riverpod provider. |
| `lib/auth/` | Session lifecycle: sign-in via email+OTP or Google OAuth, JWT/refresh handling, the "Who's working?" picker, PIN set/verify, and auto-lock. | Business/domain data access beyond the current identity. |
| `lib/permissions/` | Loads role and per-staff permission rows from Drift and exposes `can(action)` checks to the UI. Source of all gating decisions. | Hard-coded role logic. Permissions are data, read from tables. |
| `lib/core/` | Cross-cutting primitives: the global crash handler, result/error types, money/currency helpers, IDs (UUIDv7), and constants. | Feature-specific logic. |

## Storage Model

Four storage locations, with a strict rule for what lives where. Business data goes to Drift (and syncs); secrets and pointers go to secure storage (and never sync); sync engine state goes to Drift (and never syncs); operator audit records go to Supabase only (and never reach the client). Nothing durable lives only in memory.

| What | Where | Why | Synced to cloud? |
|---|---|---|---|
| Products, categories, stock levels, expiry dates | Drift (SQLite) | Read on every POS interaction; must work fully offline. | Yes |
| Orders, order lines, payment records | Drift (SQLite) | Created offline at the till; converge across devices. | Yes |
| Customer & supplier profiles | Drift (SQLite) | Attached to sales offline; shared business-wide. | Yes |
| Wallet ledger rows (customer & supplier) | Drift (SQLite), **append-only** | Source of truth for balances. Balances are derived, never stored as a single mutable field. | Yes |
| Staff, roles, permission rows, per-staff overrides | Drift (SQLite) | Gating must work offline; CEO edits propagate to all devices. | Yes |
| Expenses, supplier invoices/payments | Drift (SQLite) | Recorded offline; feed reports and ledgers. | Yes |
| Activity logs, crash logs | Drift (SQLite) | Captured offline, including during a crash. | Yes (via outbox) |
| Sync outbox (pending local changes) | Drift (SQLite), dedicated `sync_outbox` table | Durable queue that survives app kill; drained by the sync isolate. | No — it *is* the thing being drained |
| `sync_progress` (current sync phase, counts, timestamp) | Drift (SQLite), dedicated table | Written by the sync isolate after every batch or pull page. Read by a Riverpod provider to drive progress UI. Never sent to the cloud. | No |
| `sync_meta` (stored pull cursor, last successful batch RTT, current batch-size tier) | Drift (SQLite), dedicated table | Durable engine state that survives app kill. Cursor used for resumable pull; RTT used for self-tuning batch sizing. Never sent to the cloud. | No |
| `sync_debug` (current adaptive batch-size tier, last RTT ms) | Drift (SQLite), dedicated table | Written by the sync isolate each cycle for internal diagnostics screens. Never sent to the cloud. | No |
| Rejected-payload audit log (oversized batch size, `business_id`, timestamp) | Supabase Postgres only, `sync_audit_rejected` table | Operator-visible record of 413-rejected pushes. Lives in Supabase exclusively — never mirrored to Drift and never added to the client outbox. | Server-side only |
| Active user PIN hash | flutter_secure_storage | Device-local unlock factor. Never leaves the device. | **Never** |
| Auth refresh token / JWT | flutter_secure_storage | Session credential. | **Never** (re-issued by Supabase Auth) |
| Active business ID, active store ID, last-active staff pointer | flutter_secure_storage | Session pointers for cold start and the "Who's working?" picker. | No |
| Subscription status (Trial/Active/Inactive) | Drift (SQLite), read-only mirror | Surfaced in Settings and name badges. Written only by the Admin Hub via sync pull. | Pulled, never pushed |
| In-flight cart, transient UI state | Riverpod (memory) | Ephemeral working state for the current screen. | No |

### Sync ownership

- **Push:** a write the user makes locally → repository writes the row to Drift → repository enqueues an outbox entry. The sync isolate later drains the outbox in adaptive-sized batches (WiFi 150 KB / mobile data 25 KB / poor or unknown 10 KB) determined by connectivity_plus at the start of each cycle.
- **Pull:** Supabase Realtime signals that peer changes exist → the sync isolate fetches changed rows in cursor-based pages (WiFi 500 rows / mobile data 100 rows / poor or unknown 50 rows), reconciles each page into Drift, advances the cursor only after a page is fully committed, and lets Riverpod providers watching those tables rebuild the UI.
- **Conflict resolution:** last-write-wins by server timestamp for mutable rows (e.g. a product price edited on two devices). **Exception:** wallet and supplier ledgers are append-only and never conflict — both rows survive, and the balance is recomputed from the full ledger.

## Auth & Access Model

Authentication is split deliberately into a **portable identity** and a **device-local unlock factor**, because one physical till is shared by many staff across a shift.

- **Identity (portable):** verified by Supabase Auth via one of two providers — **email + OTP** or **Sign in with Google (OAuth)** — either of which issues the JWT that authorizes all Postgres and Edge Function access. The provider is an authentication detail only; the resolved **email address is the canonical identity key** in both cases, so the same person signing in by email OTP or by Google with the same address is one identity. Recovery on a new device re-establishes a user through whichever provider their email is registered with.
- **Unlock factor (device-local):** a 6-digit PIN, stored only as a hash in `flutter_secure_storage` on that device. The PIN is never sent to the cloud and never stored in Postgres. It exists to let a staff member re-assert their identity quickly on a shared till without re-running the full provider sign-in (email OTP or Google).
- **Shared-till session:** a cold start shows the "Who's working?" picker. Selecting a card and entering that user's PIN unlocks *only* that identity. After inactivity the till auto-locks back to the picker; Switch User keeps the PIN, Log Out clears the leaving user's PIN and device pointer.

### Ownership and tenancy

- The unit of tenancy is the **business**. Every business-scoped row carries a `business_id`.
- **One email, one business.** An email maps to exactly one business in this phase, **regardless of how that email signs in** (email OTP or Google resolve to the same identity). Because a staff member's email is already bound to the business that invited them, that same email cannot create a new business — "Create a new business" with an already-registered email is rejected. A person who is staff at one business and wants to own another must use a different email; an email is freed to create a business only after it is no longer attached to one (the staff account is removed, or the business is deleted).
- A staff member belongs to one business and is assigned to one or more stores within it.
- **Authorization is enforced server-side by Postgres Row-Level Security**, keyed on the `business_id` (and store assignment) embedded in the JWT claims. The client cannot widen its own access by tampering with local data; RLS rejects any row outside the caller's business.
- **Permissions are data, not code.** Role rows and per-staff override rows live in tables. The `lib/permissions/` layer reads them and exposes `can(action)`. UI uses hide-don't-block: an action the user lacks permission for does not render. The CEO tunes a role with a toggle in Settings, which is just a row edit that syncs — no code release.
- **Danger Zone:** permanent deletion of a business runs as a single atomic Edge Function (two-gate: business name + PIN). It deletes the business, all its staff accounts, and all business-scoped rows, and instructs every device to wipe local data and log out.

## Background Task Model

There is no AI or LLM component in this application. **Sync is the only background work**, and it is the most safety-critical subsystem, so it is specified tightly.

- **Where it runs:** a dedicated Dart isolate, scheduled by WorkManager on Android and BGTaskScheduler on iOS, so it survives backgrounding and app kill and never blocks the UI thread. The isolate must not import any UI code; it communicates all results — progress, debug state, and reconciled data — only by writing to Drift.

### Push path — adaptive batch sizing (Fix 1)

At the start of every sync cycle the isolate reads the current connection type from `connectivity_plus` and selects a batch size tier:

| Connection | Batch size |
|---|---|
| WiFi | 150 KB |
| Mobile data | 25 KB |
| Poor signal / unknown | 10 KB |
| Offline | Skip dispatch; schedule exponential-backoff retry |

Within the active tier, the isolate optionally nudges the batch size up or down based on the round-trip time of the last successful batch stored in `sync_meta`, so the engine self-tunes without manual intervention. After each cycle the current tier and last RTT are written to `sync_debug` for internal diagnostics screens.

The isolate drains the `sync_outbox` table one batch at a time, sending each to the push Edge Function transactionally. A batch is removed from the outbox only after the server confirms it. Failed batches stay in the outbox and retry with exponential backoff.

### Push path — Edge Function validation (Fix 3)

The push Edge Function enforces a hard server-side payload cap regardless of the client tier in effect:

- Any incoming batch whose raw body exceeds **200 KB** is rejected immediately with a `413 Payload Too Large` response. The payload is not processed at all.
- The Edge Function logs the rejected payload size and the calling `business_id` to `sync_audit_rejected` in Supabase Postgres. This table is operator-visible only; it is never mirrored to the client and must never be added to the outbox.
- On receiving a 413, the client isolate treats it as a permanent split signal: it divides the offending batch in half, re-enqueues both halves at the front of the `sync_outbox`, and retries from the smallest half first. This prevents a single oversized batch from permanently blocking the outbox.

### Pull path — paginated cursor-based pull (Fix 2)

The pull path is triggered by a Supabase Realtime signal (or a periodic fallback poll). Rather than fetching all rows changed since the cursor in one query, the isolate fetches in pages, using the same connectivity_plus tier for page size:

| Connection | Page size |
|---|---|
| WiFi | 500 rows |
| Mobile data | 100 rows |
| Poor signal / unknown | 50 rows |

The cursor stored in `sync_meta` advances **only after a page is fully reconciled into Drift**. If reconciliation fails mid-page the isolate retries that page before moving forward. The cursor never skips ahead past an uncommitted page. This makes push and pull symmetrical in their resilience to poor connectivity and large changesets.

### Sync progress and UI feedback (Fix 4)

After every push batch or pull page is processed, the isolate writes a row to `sync_progress` in Drift containing:

- total outbox entries pending
- entries dispatched so far
- current phase: `pushing` / `pulling` / `idle` / `error`
- current table group being pulled (used during onboarding — see below)
- timestamp

A Riverpod provider watches the `sync_progress` table and exposes this state to the UI. Any screen that triggers a bulk operation — inventory import, first launch, post-offline catch-up — must display a progress indicator driven by this provider showing actual counts (e.g. "Syncing 340 of 1,200 changes…"), not a static spinner. On completion the indicator must resolve to an explicit success or error state; it must not silently disappear.

### Initial onboarding pull — new device (Fix 5)

A new device joining a mature store has no stored cursor. The absence of a cursor in `sync_meta` is the onboarding condition. The isolate handles this as a special paginated pull sequence with the following rules:

**Resumability:** onboarding is a sequence of cursor-advancing pages, identical in mechanism to Fix 2. If the app is killed mid-onboarding, the next launch detects the partial cursor and resumes from the last successfully committed page — it does not restart from scratch.

**Minimum viable dataset gate:** the POS UI is blocked behind an onboarding gate until at minimum these table groups are fully pulled and committed to Drift: products, staff, roles, permissions, and active customer profiles. The gate lifts the moment this minimum set is available. Non-critical tables — historical orders, expenses, activity logs — continue pulling in the background after the gate is lifted.

**Table group order:** the isolate pulls in priority order: (1) roles and permissions, (2) staff, (3) products and categories, (4) active customer profiles, (5) suppliers and wallets, (6) historical orders and expenses, (7) activity logs. Progress is written to `sync_progress` per group so the onboarding screen can show what is being downloaded.

**Onboarding screen:** a dedicated onboarding progress screen — not a generic loading spinner — is shown until the gate lifts. It displays the current table group being pulled (e.g. "Downloading products…"), the page count within that group, and overall percentage complete. It uses the same `sync_progress` Riverpod provider as Fix 4.

### Ordering, idempotency, and crash capture

- **Ordering & idempotency:** outbox entries are ordered and carry client-generated UUIDv7 IDs so replays are idempotent — re-sending a batch after a dropped connection can never double-apply a sale.
- **Crash capture as background work:** the global error handler writes a `crash_logs` row through the same outbox, so a crash report syncs by the same mechanism as a sale, without ever interrupting the till.

## Invariants

These are rules, not guidelines. Code that breaks one of these is wrong even if it compiles and the feature appears to work.

1. **The local database is the source of truth for the running app.** Every screen reads from Drift and every user write commits to Drift first. No widget, view model, or repository method may block the UI on a network call or read live data directly from Supabase to render a screen.

2. **PINs never leave the device.** A PIN (or its hash) is written only to `flutter_secure_storage`. It must never be placed in Drift, in an outbox row, in a network request, in a log line, or in Postgres. Identity and recovery run only through Supabase Auth (email + OTP or Google OAuth) — never through the PIN.

3. **Wallet and supplier ledgers are append-only.** A balance is always derived by summing ledger rows, never stored as a single mutable number and never edited in place. Corrections are new compensating rows. This is what makes "the wallet is the source of truth" true and conflict-free under sync.

4. **Every cloud write goes through the outbox.** A repository that needs to change cloud state writes to Drift and enqueues an outbox entry; it must not call Supabase directly. This guarantees offline durability, ordered delivery, idempotent retries, and adaptive batching through one and only one write path.

5. **Cross-business data access is impossible, and is enforced on the server.** Every business-scoped row carries a `business_id`, and Postgres Row-Level Security is the authority — the client is never trusted to scope its own queries. No code path may read or write a row outside the caller's `business_id`.

6. **Permissions are read from data, never hard-coded.** Gating decisions come exclusively from role and override rows via `lib/permissions/`. No feature may branch on a hard-coded role name (e.g. `if (role == 'Cashier')`); it must ask `can(action)`.

7. **A caught error never destroys in-progress work or shows a raw error screen.** The global handler shows a calm fallback, preserves the current cart and any uncommitted local state, and queues a crash log. A red/blank framework error screen reaching the user is a defect.

8. **Layer dependencies point one direction only.** `features → repositories → (local | remote)`, with `sync`, `auth`, `permissions`, and `core` as shared lower layers. UI must not import `data/local` or `data/remote` directly, and the sync isolate must not import any UI. A cycle or an upward import is an architecture violation.

9. **One email is one identity is one business.** The resolved email — not the auth provider — is the identity key: signing in by email OTP or by Google with the same address must map to the same user, never create a second account. An email is bound to exactly one business; "Create a new business" with an already-registered email (including any staff member's email) must be rejected, not silently allowed to create a duplicate or orphan tenant.

10. **The pull cursor never advances past an uncommitted page.** The cursor stored in `sync_meta` is updated only after a pull page is fully reconciled into Drift and the transaction commits successfully. A failed or partial reconciliation must retry that page before the cursor moves. This rule is what makes both regular pulls and onboarding pulls resumable after an app kill.

11. **The POS UI is gated until the minimum viable dataset is local.** On a device with no cursor, the main POS screen must not be accessible until at minimum products, staff, roles, permissions, and active customer profiles have been fully committed to Drift. The gate exists to prevent a cashier from operating on an empty or partial dataset. Non-critical historical data may continue pulling in the background after the gate lifts.
