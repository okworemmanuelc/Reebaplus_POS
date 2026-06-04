# CLAUDE.md — Reebaplus POS Build Guardrails

Behavioral guidelines for Claude Code while building Reebaplus POS. Read this file first, every session, before doing anything else.

These guidelines bias toward caution over speed. For trivial tasks, use judgment.

---

## Mandatory reading at session start

Before writing any code or proposing any approach:

1. Read this file in full.
2. Read `reebaplus_master_plan.md` in full.
3. Read `BUILD_LOG.md` to see what has already been built.
4. Confirm what you've read by listing the master plan sections relevant to today's work.
5. Wait for approval before writing code.

---

## What this project is

A multi-business point of sale app for Nigerian businesses (Bar, Beer Distributor, Restaurant, Supermarket, Pharmacy, Boutique). One business is owned by one CEO. Staff are added by the CEO with one of four roles. The app runs on a shared till device. Architecture is offline-first with cloud sync.

## The four roles (these are the only roles that exist)

- CEO
- Manager
- Cashier
- Stock keeper

Do not invent new roles. Phase 2 will add custom roles — until then, only these four exist.

## Current build phase

**Phase 1.** Phase 2 and Phase 3 features are listed in the master plan but are out of scope. If you find yourself reaching for them, stop.

---

## 0. Echo the Request First

Whenever the user types a prompt, first explain it back to them briefly — one or two sentences — so they can see you've understood what they're asking before you act on it. Then proceed.

## 1. Think Before Coding

Don't assume. Don't hide confusion. Surface tradeoffs.

Before implementing:

- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them.
- If a simpler approach exists, say so.
- If something is unclear, stop. Name what's confusing.

## 2. Simplicity First

Minimum code that solves the problem. Nothing speculative.

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" that wasn't requested.
- No error handling for impossible scenarios.
- If 200 lines could be 50, rewrite it.

## 3. Surgical Changes

Touch only what you must. Clean up only your own mess.

- Don't "improve" adjacent code or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice dead code, mention it — don't delete it.

## 4. Goal-Driven Execution

Define success criteria. Loop until verified.

Transform tasks into verifiable goals:

- "Add validation" → "Write tests, then make them pass."
- "Fix the bug" → "Reproduce it in a test, then fix."
- "Refactor X" → "Ensure tests pass before and after."

## 5. Sync invariants

Every write to a synced table (anything in `_syncedTenantTables` in [lib/core/database/app_database.dart](lib/core/database/app_database.dart)) must reach the cloud. The contract is:

- All writes go through a DAO method that calls `enqueueUpsert` / `enqueueDelete` on `SyncDao` (or enqueues a `domain:<rpc>` envelope for atomic multi-table actions). Writes via `db.into(...)`, `db.update(...)`, `db.delete(...)` *outside* a DAO are leaks — the cloud never sees them.
- Six legitimate exceptions, all narrow. Each writes locally without enqueuing because the cloud already has (or never needed) the data. Before flagging or "fixing" any raw write, check this list:
  1. **`_restoreTableData`** in `lib/core/services/supabase_sync_service.dart` — applies incoming snapshot pulls and realtime events. The cloud is the source; pushing back would loop.
  2. **`_applyDomainResponse`** in `lib/core/services/supabase_sync_service.dart` — writes the cloud's authoritative response after a domain RPC succeeds. The server already has the truth; pushing it back is a no-op round trip.
  3. **`_compensateRejectedSale`** in `lib/shared/services/order_service.dart` — local-only reversal of writes the cloud rejected (e.g. `insufficient_stock` from a concurrent device). The cloud's RPC rolled its own transaction back; nothing local to push. See the explicit doc-comment on the method.
  4. **`setUserPin`** and **`clearUserPin`** in `lib/shared/services/auth_service.dart` — write the `users.pin`, `pinHash`, `pinSalt`, and `pinIterations` columns (set a PIN / reset to setup-required on Log Out, §7.6). PIN columns are local-only by schema design (see the comment at the top of the `Users` table in `app_database.dart`); they are not present in Supabase.
  5. **`upsertLocalUserFromProfile`** in `lib/shared/services/auth_service.dart` — mirrors a `users` row that was just read FROM the cloud (via `_supabase.from('users').select(...)`). Pushing it back is a no-op round trip. Explicit "no enqueueUpsert here" comment in the method.
  6. **`createNewOwner`** and **`completeOnboarding`** in `lib/shared/services/auth_service.dart` — onboarding writes to `users` / `businesses` / `stores`. The cloud `complete_onboarding` RPC has already written canonical state server-side; the local writes are a mirror, not a push. `AuthService` isn't bound yet during onboarding, so any DAO that calls `requireBusinessId()` would throw — direct writes are the only option. Explicit comment in `completeOnboarding`.
  7. **`_commit`** (staff redemption local mirror) in `lib/features/auth/screens/staff_sign_up_screen.dart` — Staff Sign Up writes `users` / `user_businesses` / `user_stores` (and stamps the local `invite_codes` row) after `redeem_invite_code`. The cloud RPC already wrote canonical state server-side; `AuthService` isn't bound during sign-up (resolver returns null → `requireBusinessId()` would throw), so the local writes are a mirror, not a push. Same shape as #6 `completeOnboarding`, with the same `upsertLocalUserFromProfile()` + `pullChanges()` fallback on local-mirror failure.

If you find a raw write outside the six exceptions above, it is a sync leak — fix it by routing through a DAO that enqueues. If you find a new genuine exception that doesn't fit the existing six, propose adding it to this list before merging.
- Soft-delete (`is_deleted=true`) goes through `enqueueUpsert`. Only use `enqueueDelete` for hard tombstones the cloud needs to forget; it also clears any pending upsert for the same row.
- Domain envelopes (`domain:pos_record_sale`, `domain:pos_inventory_delta`, `domain:pos_create_product`) skip enqueue-time coalescing — each is an independent atomic transaction. Their payloads sit at `$.p_<arg>` and are dispatched via `_pushDomainItems`, not the per-table batched upsert path.
- Stream providers for synced tables live in [lib/core/providers/stream_providers.dart](lib/core/providers/stream_providers.dart). When a screen reads a synced table, prefer the existing provider over a one-shot `db.select(...).get()` so realtime events propagate without a manual refresh.

**As we build new tables for the Reebaplus master plan** (roles, permissions, stores, invite_codes, activity_logs, funds_accounts, shipments, etc.), every new synced table follows the same contract. Add it to `_syncedTenantTables`, route writes through a DAO that calls `enqueueUpsert` / `enqueueDelete`, and add a stream provider in `stream_providers.dart`.

### Automated sync safeguard (don't rely on review alone)

The contract above is enforced by three automated layers so a write can't *silently* fail to sync. They all read one co-located source of truth in [app_database.dart](lib/core/database/app_database.dart) — `kSyncedTenantTables` (public alias of `_syncedTenantTables`), `kSyncCacheTables` (the 3 Phase D caches), `kEnqueueableTables` (the union a DAO may enqueue: synced ∪ caches ∪ `businesses`) — so they cannot drift apart. Run them with `flutter test test/sync/`.

- **Layer A — runtime enqueue guard** (`SyncDao.enqueueUpsert` / `enqueueDelete` in [daos.dart](lib/core/database/daos.dart)). Throws `StateError` on a table name outside the legitimate set, so a typo/unregistered target fails fast at the write boundary instead of sticking forever as a `failed` queue row. Mirrors the existing `_ledgerTables` guard. Test: `test/sync/sync_dao_enqueue_guard_test.dart`.
- **Layer B — registration completeness** (`test/sync/sync_table_registration_test.dart`). Reflects over the live schema; any table carrying the sync fingerprint (**both** a `business_id` and a `last_updated_at` column) must be in `kSyncedTenantTables` or `kSyncCacheTables`. Adding a new tenant table and forgetting to register it turns this red. This is the keystone: it makes the most common omission impossible to merge.
- **Layer C — raw-write leak scanner** (`test/sync/sync_raw_write_leak_test.dart`). Source-scans `daos.dart` + `lib/shared` + `lib/features` + `lib/core/services` for a raw Drift write to a synced table whose **enclosing method** contains no enqueue (any `enqueue…(` call, incl. helpers and `domain:` envelopes). Catches the truly silent case — a new screen/service that writes the DB without enqueuing.

**`sync-exempt` marker convention** (the reusable contract for the legitimate §5 exceptions):

- `// sync-exempt: <reason>` inside a method exempts that method from Layer C. The 7 §5 exceptions carry it.
- `// sync-exempt-file: <reason>` at the top of a file exempts the whole file. Only the sync engine ([supabase_sync_service.dart](lib/core/services/supabase_sync_service.dart)) has it — it restores cloud-authoritative state.

When you add a new synced table: add it to `_syncedTenantTables`, route writes through a DAO that enqueues, add the stream provider — then `flutter test test/sync/` is green. If a write is a genuinely new §5 exception, add a `// sync-exempt:` marker **and** propose adding it to the §5 exception list before merging.

## 6. Cautious with Dependencies

Adding a package has a cost beyond installing it: bundle size, security surface, maintenance burden, licensing risk.

- Before adding a new dependency, check whether the standard library or an existing package in `pubspec.yaml` already does what's needed.
- If a new dependency is genuinely required, propose it explicitly with the reason. Wait for approval.
- Prefer small, well-maintained, widely-used packages over niche ones.
- Never add a dependency for something that can be solved in 20 lines of project code.
- Never silently bump major versions of existing dependencies. If a version bump is needed, flag it.

---

## Hard rules — never break these

1. **Never** add features that are not in `reebaplus_master_plan.md`. If something seems missing, ask before adding.
2. **Never** add Phase 2 or Phase 3 features. Refuse politely and point to the master plan.
3. **Never** invent a fifth role.
4. **Never** show raw UUIDs in user-facing text. Use the short codes specified in the master plan (ORD-000001, INV-K7M2QX, REC-0912, etc.).
5. **Never** add a button, menu item, tab, or screen that the master plan does not specify.
6. **Never** drop role-based permission checks. Every screen, button, and action checks permissions before rendering or running.
7. **Never** show greyed-out menu items the user has no permission for. Hide them entirely. (Exception: suspended staff in Staff Management — that's intentional.)
8. **Never** reintroduce removed features:
   - QR code on the Receipt (removed).
   - Deliveries sidebar item (deferred to Phase 3).
   - Cash Register sidebar item (replaced by Funds Register).
   - Cart sidebar item (it's bottom nav only now).
9. **Never** hard-delete records. Customers, suppliers, payments, expenses, and staff use soft delete only (`is_deleted=true` via `enqueueUpsert`).
10. **Never** allow sales to be made until Opening Cash is set for the day. Block POS with the role-appropriate message.
11. **Never** allow a new day to start until the previous day is properly closed.
12. **Never** block sales because of missing buying price — buying price is required at product creation, so this case shouldn't happen.
13. **Never** show empty crate features for non-Bar and non-Beer-distributor businesses.
14. **Never** route money through a customer wallet for walk-in customers. Walk-ins go straight to the chosen account.
15. **Never** rename "Store" back to "Warehouse" anywhere in the UI. The rename is global.
16. **Never** write directly to a synced table outside a DAO. See section 5.

---

## Decision-making rules — when in doubt

- **When unsure about a feature detail:** check the master plan first. If still unclear, ask the user. Never invent.
- **When the user requests something not in the plan:** ask whether the master plan should be updated. Do not silently add.
- **When two parts of the plan seem to conflict:** stop and flag it. Do not pick one and proceed.
- **When you would add a new database column or table:** check section 2.4 of the master plan first. If the schema needs to grow, propose the addition explicitly. Remember section 5 — new synced tables need to be added to `_syncedTenantTables` and routed through a DAO.
- **When a session is going long:** suggest pausing and updating `BUILD_LOG.md` before continuing.

---

## Coding rules

1. Every new screen has the role-based access guard wired up from day one. Do not "add permissions later."
2. Every user-facing string uses the rename rules: "Store" not "Warehouse," "Home" not "Dashboard," etc.
3. Every action that writes to the database also writes to `activity_logs` (except routine sales, which are tracked in Orders).
4. Every money movement for a registered customer flows through their wallet. Wallet history is the source of truth.
5. Every money movement for any customer affects the relevant Funds Register account (Cash Till, POS machine, or Bank account).
6. Every loading state uses fade-in transitions. No rotating spinners.
7. Every synced-table write goes through a DAO. See section 5.
8. Every screen respects the bottom system-navigation inset. The app runs edge-to-edge (Android 15 / `targetSdk 35`), so any widget pinned to the bottom that ignores the inset paints **under** the nav bar or the gesture pill. See "Safe-area / system-navigation insets" below. This is permanent — every new screen follows it from day one, the same way permission guards do.

### Safe-area / system-navigation insets

This convention does not change. New screens, modals, and bottom sheets must follow it.

**Why:** The app is edge-to-edge on Android 15 (`targetSdk 35`); the OS reserves no space for the bottom system nav. Bottom-anchored content that ignores the inset is drawn beneath the 3-button nav bar, the gesture pill, or the iPhone home indicator.

**The trap that makes the obvious fix fail (proven on-device — do not relearn it):** A `Scaffold` strips `padding.bottom` from its **entire body** whenever it has a `bottomNavigationBar` — even a zero-height one (`scaffold.dart`: `removeBottomPadding: widget.bottomNavigationBar != null`, plus `removeViewInsets`). `MainLayout`'s app nav bar is **never null** — when hidden it renders `SizedBox.shrink()`. So **everything under `MainLayout`** (every screen, pushed route, and modal on a tab Navigator) sees `MediaQuery.padding.bottom == 0` **and** `viewInsets.bottom == 0`. That means all of these silently read **0** there: `MediaQuery.padding.bottom`, `context.bottomInset`, and `SafeArea(top: false)` / `SafeArea(bottom: true)`. Content paints under the nav bar even when "fixed" with them.

**The reliable inset:** **`context.deviceBottomInset`** (in [responsive.dart](lib/core/utils/responsive.dart)). It recomputes from the raw `FlutterView` (`MediaQueryData.fromView(View.of(context))`), which **no `Scaffold` can zero out**, and already includes the keyboard inset. Correct on 3-button nav (large), gesture nav (thin pill), and iOS.

**The decision rule — ask: "when this widget is on screen, does it reach the PHYSICAL screen bottom?"**

- **YES → use `context.deviceBottomInset`.** Covers: anything inside `showModalBottomSheet` / `showDialog` / `DraggableScrollableSheet` (modals always hide the bar); pushed detail screens (footers, scrollable bottoms); and drawer-accessed tab roots where the bottom nav bar is hidden — Customers, Payments, Expenses, Stores, Deliveries, Activity Log, Funds Register.
- **NO → leave it (0 is correct).** This is **only** the body of the five bottom-nav tab roots rendered above the visible bar — **Home, POS, Inventory, Orders (list), Cart**. The bar already insets them; adding `deviceBottomInset` makes a **gap above the bar**. Their existing `context.bottomInset` reads 0 there, which is correct — do **not** convert it. (But modals opened *from* these files still use `deviceBottomInset`.)
- **Floating action buttons (`AppFAB`):** same YES/NO split — but the Scaffold's `floatingActionButton` slot does **not** add the system-nav inset on edge-to-edge (only a ~16px margin), so on a **3-button nav** the bar paints over the FAB (the gap is ~invisible on gesture nav, which is why this was missed at first). `AppFAB` lifts itself via `reserveBottomInset` (default **true**, using nav-only `context.deviceBottomPadding` so the keyboard isn't double-counted when a form FAB shows with the keyboard up). Set `reserveBottomInset: false` only on the visible-bar tab roots (POS, Stock), exactly like the NO rule above. Never wrap an `AppFAB` in your own bottom inset.
- **Auth / onboarding screens** (`lib/features/auth/**`) run **before** `MainLayout`, so their `padding.bottom` / `context.bottomInset` already works — leave them.

**`showModalBottomSheet` — the `useSafeArea` trap (also a real bug):** `useSafeArea: true` wraps the sheet in `SafeArea(bottom: false)` — it protects top/left/right only and **does NOT inset the bottom**. Combined with the trap above (even a nested `SafeArea(bottom)` reads 0 under `MainLayout`), the bottom is **always** your job — put `context.deviceBottomInset` on the footer padding.

**Never:**

- Use `MediaQuery.padding.bottom`, `context.bottomInset`, or a bottom `SafeArea` for bottom-anchored content under `MainLayout` — they read **0**. Use `context.deviceBottomInset`.
- Add `deviceBottomInset` to the **body** of one of the five bottom-nav tab roots (Home / POS / Inventory / Orders / Cart) — it creates a gap above the bar. (Their modals are fine.)
- Assume `showModalBottomSheet(useSafeArea: true)` insets the bottom — it doesn't (`SafeArea(bottom: false)`).
- Double-pad: don't add an inset to content already in a Scaffold's `bottomNavigationBar` / `persistentFooterButtons` / `bottomSheet` slot, and don't stack `deviceBottomInset` with a separate `viewInsets.bottom` on the same edge (`deviceBottomInset` already includes the keyboard). (`floatingActionButton` is deliberately NOT in this list — the Scaffold does not inset it for the system nav on edge-to-edge; `AppFAB` owns that inset itself via `reserveBottomInset`, see the decision rule above.)
- Run the raw inset through the size scaler (`getRSize(deviceBottomInset + …)`). Apply the raw inset and scale only the fixed gap: `context.deviceBottomInset + context.getRSize(16)`.

---

## Checkpoint questions to expect

The user will periodically pause and ask you to recite what the master plan says about something, from memory. This is a drift check. Answer honestly. If you have lost track, say so and re-read the relevant section.

---

## Session end ritual

Before ending a session:

1. Run any tests, fix any failures.
2. Write a short entry in `BUILD_LOG.md` (see the template in that file). Plain English. No jargon.
3. Summarise what was built and what's still open.

---

## Plan updates

If the user changes the plan mid-build:

1. Stop coding.
2. Update `reebaplus_master_plan.md` to reflect the change.
3. Note the change in `BUILD_LOG.md` under the current session entry.
4. Resume coding only after the plan is updated.

Never accept a verbal-only change to the plan. Verbal changes are forgotten within 20 messages.

---

## How to refuse a bad request gracefully

If asked to do something against these rules, respond like this:

> "That would conflict with [specific rule]. The master plan says [what it says]. Do you want to update the master plan, or should I stick to the original?"

Do not silently comply. Do not lecture. Just flag it and ask.

---

## What the user wants from you

Speed without drift. Small, focused sessions. Honest checkpoints. Clean code that matches the plan exactly. Plain English explanations when the user reviews your work.
