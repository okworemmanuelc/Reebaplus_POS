# BUILD_LOG.md — Reebaplus POS Build History

This file is the running memory between Claude Code sessions. Every session ends with a new entry here. Plain English only — no jargon.

---

## How to use this file

**At the start of every session**, Claude reads this file to know what's already been built and what's still open.

**At the end of every session**, Claude (or the user) adds a new entry using the template below.

**When the master plan changes mid-session**, note it under the current session entry so the change isn't lost.

---

## Entry template (copy this for each new session)

```
## Session [number] — [YYYY-MM-DD]

**Built today:**
- (Plain English description of what was built. One bullet per thing.)

**Files touched:**
- (List of new or changed files. Just paths.)

**Database changes:**
- (Any new tables, columns, or migrations. Plain English.)

**Master plan sections covered:**
- Section X.Y — [brief description]

**Plan updates made during session:**
- (If the master plan was changed today, note what changed and why. Otherwise write "None.")

**Tested:**
- (What was tested and confirmed working.)

**Known issues / left open:**
- (Anything broken, half-done, or deferred to a later session.)

**Next session should:**
- (Suggested starting point for the next session.)
```

---

## Build status overview

Keep this section updated at the top so it's easy to see what's done at a glance.

### Phase 1 — In progress

**Foundation:**
- [x] Database schema rebuild (section 2 of master plan) *(done in Session 2 — schema v13)*
- [x] Role + permission seeding for new businesses *(done in Session 2)*

**Auth flow:**
- [x] Welcome screen (section 4) *(done in Session 6)*
- [x] CEO Sign Up flow (section 5) *(done in Session 7 — new-email path; §5.2 existing-email branch deferred)*
- [x] Staff Sign Up flow (section 6) *(done in Session 10)*
- [x] Login flow + Forgot PIN (section 7) *(done in Session 8 — §7.1–7.4; §5.2/§7.2 multi-business confirm-PIN deferred to Phase 2)*
- [x] Who Is Working picker (section 8) *(done in Session 11 — §8.1–8.5; "active now" dot deferred)*

**Core screens:**
- [x] Staff Management (section 9) *(done in Session 10)*
- [x] CEO Settings (section 10) *(§10.1 menu + Business Info / Stores / Security / Activity Logs access done in Session 14; §10.2 Roles & Permissions done in Session 15; Appearance added to §10.1 in Session 17; §10.3 is Phase 2)*
- [x] Home / Dashboard (section 11) *(role-aware cards, subtitle, store lock, Total SKUs — commit 8307314)*
- [ ] Point of Sale (section 12)
- [ ] Cart + Edit Quantity modal (section 13)
- [ ] Checkout (section 14)
- [ ] Receipt (section 15)
- [ ] Inventory + Product Details (section 16)
- [ ] Daily Stock Count (section 17)
- [ ] Customers + Customer Profile (section 18)
- [ ] Orders (section 19)
- [ ] Expenses + Pending Approval flow (section 20)
- [ ] Supplier Accounts (section 21)
- [ ] Track Shipments (section 22)
- [ ] Funds Register (section 23)
- [ ] Activity Logs (section 24)
- [ ] Reports (section 25)
- [ ] Notifications (section 26)
- [ ] Sidebar + Bottom Nav final pass (section 27)

**Cross-cutting:**
- [ ] Role-based guards wired everywhere
- [~] Rename pass: Warehouse → Store *(done in Session 3)*, Dashboard → Home *(done with §11)*; Cash Register → Funds Register pending (section 23)
- [ ] Loading animations replaced with fade-ins
- [ ] All UUIDs replaced with short codes in user-facing text

Mark each item with `[x]` as it's completed. Add notes under any item if needed.

---

## Session entries

(New entries go below this line. Most recent at the top.)

---

## Session 19 — 2026-05-30 — Point of Sale, guarded by role (§12, pivot step 12)

**Built today:**
- Made the Point of Sale screen role-aware. Most of the §12 UI already existed (price tier dropdown, store picker, out-of-stock greying, Quick Sale modal); this session added the role gates around it.
- POS now blocks anyone without "make a sale" permission. The Stock keeper was already hidden from the sidebar; now if they reach POS by any other route they see a plain "You don't have access" message instead of the till.
- The store-switcher icon in the top bar is now CEO-only. Managers and Cashiers just see the current store name; only the CEO can switch which store they're selling from.
- The Retailer/Wholesaler price dropdown is now locked for Cashiers — they stay on Retailer. CEO and Manager can still switch freely. (If a registered wholesaler customer is added to the cart, the price still switches automatically for everyone, as before.)
- Quick Sale now needs a manager. A CEO or Manager opens it straight away; a Cashier must type a CEO or Manager PIN first, and their own PIN is rejected.
- Replaced the spinning loaders on the POS screen with a gentle fade-in, matching the rest of the app.

**Files touched:**
- lib/features/pos/screens/pos_home_screen.dart

**Database changes:**
- None. Every change is read-only display/gating — no synced-table writes, no schema change.

**Master plan sections covered:**
- §12 — Point of Sale (role-based access, store selector CEO-only, price tier defaults, Quick Sale PIN gate, fade-in loading).

**Plan updates made during session:**
- Ticked the §3 build-order box for "Point of Sale, guarded by role" and marked pivot step 12 done.

**Tested:**
- `flutter analyze` on the POS screen — clean, no issues.
- Manual role walk-through still to do on the emulator (switch user across CEO / Manager / Cashier / Stock keeper).

**Known issues / left open:**
- Barcode scan for Pharmacy/Supermarket (§12.6) — deferred to pivot step 40 (needs a camera package).
- Block-POS-until-Open-Day (hard rule #10 / §12) — depends on the Funds Register Open Day feature, which doesn't exist yet (pivot step 16).
- Role-based discount caps — they live in the Cart screen, pivot step 13.
- The realtime inbound-sync bug (flagged 2026-05-30, §2.6 / pivot §7) was parked until POS landed — now eligible to fix.

**Next session should:**
- Pivot step 13: Cart + Edit Quantity modal + role-based discount caps (and the `allowFractionalSales` column). Or take the now-unblocked realtime inbound-sync fix first.

---

## Session 18 — 2026-05-30 — Sidebar role guards + profile role tag (§27, pivot step 10)

**Built today:**
- The sidebar used to show every item to everyone. Now each role only sees what it's allowed to. A Stock keeper no longer sees Point of Sale, Customers, Supplier Accounts, Expenses, Stores, Activity Logs, Staff Management, or CEO Settings — just Home, Inventory, and Orders. A Cashier additionally sees POS and Customers. A Manager sees those plus Expenses and Staff Management. The CEO sees everything.
- Visibility is decided by the same permission a role already has (e.g. a role only sees "Expenses" if it can create expenses), so it stays correct if the CEO later changes a role's permissions. Supplier Accounts and Activity Logs show for a Manager only if the CEO has granted those — matching "Manager if toggled" in the plan.
- Removed three sidebar items: Deliveries (a Phase 3 feature), Cart (it lives in the bottom bar only now), and Pro Tips. The "View Pro Tips" welcome card on Home was removed too, so Pro Tips isn't shown anywhere in Phase 1 (the tips screen stays in the code for Phase 2).
- The sidebar profile area now shows the person's role as a coloured tag (CEO yellow, Manager blue, Cashier green, Stock keeper grey), and the header tint matches.

**Files touched:**
- lib/shared/widgets/app_drawer.dart
- lib/features/dashboard/screens/home_screen.dart
- test/settings/sidebar_role_visibility_test.dart

**Database changes:**
- None.

**Master plan sections covered:**
- Section 27 (27.1 profile role tag, 27.3 visibility-by-role, 27.5 removed items) — sidebar role guards. Decisions Q7 (drop Pro Tips) and Q9 (hide CEO Settings for non-CEO — the CEO Settings gate was already in place; this pass extends the same gating to the rest).

**Plan updates made during session:**
- None. This implements the existing §27 spec.

**Tested:**
- New `sidebar_role_visibility_test` seeds all four roles with the default-grant matrix (migration 0043) and asserts each role sees exactly its §27.3 set. `flutter analyze` clean on the changed files; `flutter test test/settings/` green.

**Known issues / left open:**
- Sync Issues sidebar item was left to the concurrent CEO Settings → Devices relocation work-stream (not touched here).
- Bottom-nav POS guard for Stock keeper (so the POS tab itself is unreachable) belongs to pivot step 12 (POS role guards), not this pass.

---

## Session 17 — 2026-05-30 — Business appearance: CEO picks the colour, device keeps light/dark (§10.1)

**Built today:**
- The CEO can now choose the app's **colour for the whole business** (Amber, Blue, Purple, Green) from a new **CEO Settings → Appearance** page. The choice is synced, so every device in the business shows that colour. Default stays amber.
- **Light/dark/system mode stays a personal, per-device choice** — it did NOT move into CEO settings. The old drawer "Appearance" entry is now **"Display"** and only controls light/dark/system for the device you're on. (So a night-shift cashier can still use dark mode even if the CEO picked a light-ish colour.)
- Under the hood: the business colour lives in a synced setting (`business_design_system`). A small bridge in the app's root applies it to the running theme on every device, so a CEO's change propagates to other devices automatically. Picking a colour is CEO-only and is written to the activity log.

**Plan decision made this session (with the user):**
- Appearance wasn't in the master plan and the plan implied a fixed dark+amber brand. The user chose: **CEO picks the business colour (synced); each device keeps its own light/dark for comfort.** The master plan was updated first (§10.1 + the §4.3 note) before building.

**Files touched:**
- reebaplus_master_plan.md (§10.1 Appearance section + §4.3 accent note)
- lib/core/settings/appearance_settings_screen.dart (new — CEO colour picker, synced)
- lib/core/providers/stream_providers.dart (new `businessDesignSystemProvider` + `kBusinessDesignSystemKey`, guarded against pre-login)
- lib/main.dart (app-root bridge: synced colour → themeController)
- lib/core/settings/settings_screen.dart (new "Appearance" menu row)
- lib/core/theme/theme_settings_screen.dart (trimmed to light/dark only; titled "Display")
- lib/shared/widgets/app_drawer.dart (drawer tile relabelled "Appearance" → "Display")
- test/settings/appearance_settings_screen_test.dart (new)

**Database changes:**
- None. No migration, no schema/version bump. The colour is a synced `settings` key (`business_design_system`), set via the existing `SettingsDao.set` (which already enqueues). Light/dark stays in SharedPreferences.

**Master plan sections covered:**
- §10.1 — Appearance added (CEO business colour, synced; light/dark per-device).

**Plan updates made during session:**
- Added the Appearance section to §10.1 and a note to §4.3 (the accent is CEO-selectable, default amber; light/dark per-device).

**Tested:**
- New test: CEO picks a colour → the synced `business_design_system` setting is written ('green') + a sync upsert is enqueued + the live theme updates; a non-CEO viewer sees the no-access body (no colour cards).
- Full suite green: `flutter analyze` clean for all touched files; `flutter test --exclude-tags=integration` → all passed (186, 2 env-gated skips).

**Known issues / left open:**
- The light/dark "Display" screen and the colour "Appearance" screen are now two separate entries (drawer vs CEO Settings) by design.
- Pre-login the device shows its cached colour (or amber) until the business setting syncs in — then the bridge applies the business colour.

**Next session should:**
- Continue §11 Home (in progress) or the next core screen.

---

## Session 16 — 2026-05-30 — Home screen made role-aware (§11)

**Built today:**
- The Home screen used to show every card to everyone. Now it follows the master plan: each person only sees the cards meant for their role. A CEO sees everything (Total Sales, Net Profit, Pending Orders, Expenses, Stock Value, Customer Wallet, Staff Sales). A Manager sees the same minus Net Profit. A Cashier sees only their own sales total, Pending Orders, Customer Wallet, and a new "Total SKUs" card. A Stock keeper sees just Pending Orders and the Total SKUs card.
- The header subtitle now changes by role: CEO/Manager see "Business Overview", a Cashier sees "Today's Sales", a Stock keeper sees "Stock Overview".
- New "Total SKUs" card (for Cashier and Stock keeper) — tap it to expand a breakdown of how many products each manufacturer has.
- The store filter at the top is now locked for everyone except the CEO. A Cashier or Stock keeper is pinned to their own store. A Manager is pinned to their store too — unless the CEO turns on a new switch.
- New CEO switch: in CEO Settings → Roles & Permissions → Manager, there's now an "Allow viewing other stores" toggle. When on, a Manager can switch stores on Home to check another store's stock and request restock when running low. Off by default.

**Files touched:**
- lib/features/dashboard/screens/home_screen.dart
- lib/core/settings/role_permissions_detail_screen.dart
- lib/core/providers/stream_providers.dart
- reebaplus_MASTER_PLAN.md
- test/settings/role_permissions_detail_test.dart

**Database changes:**
- None. The new Manager toggle is stored in the existing `role_settings` table (key `manager_view_all_stores`), the same place the max-discount and max-expense limits already live. Writes route through the existing DAO, so it syncs to the cloud like the other role settings.

**Master plan sections covered:**
- Section 11 (11.1 subtitle, 11.2 store-filter lock, 11.4 cards by role, 11.5 Total SKUs) — Home made role-aware.

**Plan updates made during session:**
- §11.2 and §10.2 were refined to spell out the Manager "Allow viewing other stores" toggle: that it's built in Phase 1, lives in Roles & Permissions → Manager, defaults off, and unlocks the Home store picker (rationale: a Manager checking another store's stock to request restock). The toggle was already named in §11.2; this pins down its exact behaviour and where it lives, per the no-verbal-only-changes rule.

**Tested:**
- `flutter analyze` clean (no new issues). Full `flutter test` suite green: 184 passed, 0 failed.
- New tests: the Manager toggle defaults off, persists to `role_settings` as `'true'`, and enqueues a sync upsert; the toggle is hidden for CEO and Cashier roles; and the `managerCanViewAllStoresProvider` reads false by default and flips true once the CEO enables it.

**Known issues / left open:**
- The Reports button badge is still a hardcoded "3" placeholder — its real alert count depends on the §21 Reports work, deferred by decision.
- Per-card visibility toggles per role remain Phase-2-deferred (§11.4, §28).
- End-to-end check on the emulator (logging in as each role) not yet done this session — recommended before merge.

---

## Session 15 — 2026-05-29 — Roles & Permissions sub-page (§10.2)

**Built today:**
- The last piece of CEO Settings. The "Roles & Permissions" menu row no longer opens a "coming soon" placeholder — it now opens a real screen listing the four roles (CEO, Manager, Cashier, Stock keeper) as colour-coded cards, each showing how many of the 30 permissions it has. Tap a role to open its detail page.
- The role detail page shows every permission as an on/off switch, grouped by category (Sales, Products, Stock, Expenses, Reports, Customers, Suppliers, Staff, System, Funds — in that master-plan order). Flipping a switch grants or removes that permission for the role and syncs to the cloud.
- The CEO role is locked: all its switches are on and greyed-out, and its limits read "unlimited" — the CEO's access can never be accidentally removed.
- Below the switches are the two role limits: a **maximum discount %** slider (0–100) and a **maximum expense approval** amount (in naira). Both save when you finish adjusting them and sync to the cloud. For the CEO they show "100% (unlimited)" and "Unlimited".
- "Can change product prices" is simply the existing **Edit product prices** permission toggle in the Products group (it already had the right default: Manager on, others off) — so there's no duplicate control and no database change was needed.

**Plan decisions made this session (with the user):**
- "Can change product prices" is represented by the existing `products.edit_price` permission toggle, not a separate new setting — avoids a duplicate control and a migration.

**Files touched:**
- lib/core/settings/roles_permissions_screen.dart (new — the four role cards)
- lib/core/settings/role_permissions_detail_screen.dart (new — grouped toggles + the two limits, CEO locked)
- lib/core/settings/settings_screen.dart (route Roles & Permissions to the new screen; dropped the Coming Soon placeholder)
- test/settings/role_permissions_detail_test.dart (new)
- test/settings/roles_permissions_screen_test.dart (new)

**Database changes:**
- None. No migration, no schema/version bump. Permissions use the existing role_permissions grant/revoke; limits use the existing role_settings `set` (both already sync). The 30-permission catalog and the seeded limit defaults were already in place.

**Master plan sections covered:**
- §10.2 — Roles & Permissions per-role page (permission toggles by category + max discount % and max expense approval limits; CEO locked).
- §10.3 (custom roles, custom permission groups, more limits) remains Phase 2.

**Plan updates made during session:**
- None.

**Tested:**
- 2 new test files (7 tests), all green: CEO detail shows all 30 toggles locked-on with read-only limits; toggling a Cashier permission on grants it (sync upsert) and off revokes it (sync delete); editing the expense limit stores the right kobo value and syncs; dragging the discount slider stores a new percent and syncs; the role list renders four cards with correct counts and navigates to the detail on tap.
- Full suite green: `flutter analyze` clean for all touched files; `flutter test --exclude-tags=integration` → all passed (180, 2 env-gated skips).

**Known issues / left open:**
- Section 10 (CEO Settings) is now fully done for Phase 1. The role limits (max discount, max expense approval, edit-price permission) are stored + synced but not yet *enforced* anywhere — the screens that would honour them (POS discount, Expenses approval, Product price editing) are later sections.

**Next session should:**
- Move on to the next core screen (Home / Dashboard, §11) or another pending section.

---

## Session 14 — 2026-05-29 — CEO Settings menu + sub-pages (§10.1)

**Built today:**
- Turned the old flat "CEO Settings" screen into the proper menu from the master plan. It now lists five sections — Business Info, Stores, Security, Roles & Permissions, Activity Logs access — and each opens its own page. The old Profile card was removed (your profile is still reached by tapping your avatar in the side menu).
- **Business Info** page: edit the business name, type (the six business types), and currency, then Save. The save reaches the cloud and is written to the activity log.
- **Stores** page: read-only for now — shows your store's name and address. Adding more stores is a later (Phase 2) feature, noted on the page.
- **Security** page: auto-lock is now a row of preset chips — 1, 3, 5, 10, 15, 30 minutes. The biometric login switch was moved here and **fixed**: before, the switch saved to a place the login screen never read (so it did nothing and also leaked across devices). It now saves on the device itself, the same place login checks.
- **Activity Logs access** page: a per-role on/off switch for who can view activity logs. The CEO row is locked on and can't be turned off; other roles default off.
- **Roles & Permissions** (the detailed per-role toggles, §10.2) is **deferred** to a follow-up — its row opens a "coming soon" placeholder for now.
- The "CEO Settings" item in the side menu is now **hidden** for anyone who isn't the CEO (it was showing for everyone before).

**Plan decisions made this session (with the user):**
- **Auto-lock now defaults to 5 minutes and is always on**, matching the master plan (§10.1/§8.5). Before, the code defaulted to "Never." The new preset chips have **no "Never" option** — auto-lock can't be switched off entirely anymore, only its interval changed. (This was a deliberate plan-vs-code choice the user confirmed; the master plan already said 5 min, so no plan edit was needed.)
- **Biometric toggle kept** on the Security page (the plan's Security section only mentions auto-lock, but biometrics is an existing shipped feature, so it stays) and switched to device-local storage.

**Files touched:**
- lib/core/database/daos.dart (new `BusinessesDao.updateInfo` — edits name/type, enqueues to cloud)
- lib/core/database/app_database.dart (registered `BusinessesDao`)
- lib/core/data/business_types.dart (new — shared list of the six business types)
- lib/core/settings/settings_screen.dart (rewritten into the menu)
- lib/core/settings/settings_widgets.dart (new — shared section title / tile / fade-in / no-access widgets)
- lib/core/settings/business_info_screen.dart (new)
- lib/core/settings/stores_settings_screen.dart (new)
- lib/core/settings/security_settings_screen.dart (new)
- lib/core/settings/activity_logs_access_screen.dart (new)
- lib/shared/widgets/app_drawer.dart (hide "CEO Settings" unless the user has settings.manage)
- lib/shared/widgets/auto_lock_wrapper.dart (default interval 0/Never → 300s/5min)
- test/sync/dispatch/businesses_dao_dispatch_test.dart (new)
- test/settings/settings_menu_gating_test.dart (new)
- test/settings/activity_logs_access_toggle_test.dart (new)

**Database changes:**
- None. No migration, no schema/version bump. Business name/type write to the existing `businesses` row; currency is the existing synced `default_currency` setting; activity-log access uses the existing role-permissions.

**Master plan sections covered:**
- §10.1 — CEO Settings menu + Business Info, Stores, Security, Activity Logs access sub-pages.
- §10.2 — Roles & Permissions: deferred (placeholder route).

**Plan updates made during session:**
- None. (The auto-lock default already matched the plan once we chose "follow the plan.")

**Tested:**
- 3 new tests, all green: BusinessesDao.updateInfo enqueues a `businesses:upsert` (and coalesces repeats); the drawer "CEO Settings" gate shows for CEO and hides for Cashier; the Activity Logs toggle locks CEO on, grants (upsert) and revokes (delete tombstone) for other roles.
- Full suite green: `flutter analyze` clean for all touched files; `flutter test --exclude-tags=integration` → all passed (173, 2 env-gated skips).

**Known issues / left open:**
- Roles & Permissions detail page (§10.2) still to build.
- Stores page is view-only; the `stores` table stores address as one combined `location` string (no separate state/country columns), so the page shows name + that one line.
- Minor/benign: editing the business row triggers a realtime echo that runs `putIfAbsent('timezone','UTC')` on restore — harmless here because the real timezone lives in `settings`, not the `businesses.timezone` column. Noted, not fixed.

**Next session should:**
- Build the §10.2 Roles & Permissions sub-page (per-role permission toggles grouped by category, CEO locked on, plus the role limits: max discount %, max expense approval, can-change-prices).

---

## Session 13 — 2026-05-29 — Staff full name at sign-up (§6) + view-only own staff card (§9.5)

**Built today:**
- Staff Sign Up now asks for the new staff member's full name. Before this, sign-up never collected a name, so the cloud defaulted each user's name to their email — which is why Staff Management cards and the Who's Working picker showed email addresses instead of names. The name is captured on a new step (after the email code, before creating the PIN) and sent to the cloud at redemption. Fixing it at the source fixes every screen that shows a user's name, automatically.
- Tapping your own card in Staff Management now opens your staff detail in view-only mode. Before, your own card did nothing when tapped. View-only means you can see your details but there are no "Change role" or "Suspend" buttons — you still can't manage yourself. The greyed-out rows a Manager sees for the CEO / other Managers stay non-tappable as before.
- Also in this session (separate fix, same screen file): Staff Management no longer crashes on open. It was firing a background data refresh during the widget build, which is illegal; the refresh now waits until after the first frame. (Roster still refreshes on open and on pull-to-refresh.)

**Files touched:**
- lib/features/auth/screens/staff_sign_up_screen.dart (new full-name step; renumbered the later steps 6→7; sends the name to redeem_invite_code)
- lib/features/staff/screens/staff_detail_screen.dart (new `readOnly` flag hides the manage actions)
- lib/features/staff/screens/staff_management_screen.dart (own card opens view-only detail; chevron shown on own card; + the post-frame crash fix)
- test/auth/staff_sign_up_screen_test.dart (added: renders 7 step dots)
- test/staff/staff_detail_screen_test.dart (new: view-only hides actions; manageable shows them)

**Database changes:**
- None. No migration, no schema/version bump. The cloud `redeem_invite_code` RPC already accepted a name parameter (we were sending null); we now send the entered name. The RPC still falls back to the email only when the name is blank.

**Master plan sections covered:**
- §6 (Staff Sign Up) — full-name step.
- §9.5 (Staff detail) — own card opens view-only.

**Plan updates made during session:**
- Master plan §6 was updated by the planner (before this code): added the Full name step after OTP, bumped "6 steps → 7 steps", and noted in §6.2 that the name step is skipped for an already-linked email (Phase 2). The master plan was already edited — this session only implemented it.

**Tested:**
- `flutter analyze lib/ test/` — clean apart from the 18 pre-existing `avoid_print` infos in test/database/roles_v13_report.dart. No new issues.
- `flutter test` — full suite green: 161 passed / 58 skipped / 0 failures.
- Note on test coverage: the new step-count test guards the 6→7 renumbering. Driving the sign-up flow all the way to the name step / redemption in a widget test needs Supabase + OTP test doubles the harness doesn't have, so the `p_name` send is verified by reading the RPC (uses the name when non-blank) rather than an end-to-end test.

**Known issues / left open:**
- Staff who already signed up keep email-as-name until they're re-created (re-invite / re-sign-up on test devices). No backfill.
- Emulator pass still to do: a brand-new staff sign-up shows a real name in Staff Management + the Who's Working picker; tapping your own card opens a view-only detail.

**Next session should:**
- Continue the pivot plan (next unbuilt step), or run the emulator checks above before committing.

---

## Session 12 — 2026-05-29 — Invite codes now sync to every device (pull-path completion)

**Built today:**
- Fixed a one-sided sync bug: staff invite codes were saved to the cloud but never sent back down to other devices. A code generated on one device showed up in the Staff Management → Invites tab only on that device; every other CEO/Manager login (and the shared till) saw an empty tab. Now a code created anywhere in the business appears in the Invites tab on all devices within a sync tick (and live via realtime).
- No new feature, table, or column — this just finishes the round-trip for an existing table (invite_codes). It was deliberately left out of the pull when the only consumer was Staff Sign Up redemption (which doesn't need local rows); the Invites tab was missed.
- One-time backfill for devices that had already synced before this change: the pull is incremental (only fetches rows changed since the device's last sync), so invites that already existed would never come down. Added a one-shot, device-wide reset that clears the sync cursors once so the next pull is a full pull and backfills the existing invites. New invites already arrive normally; this only recovers the historical ones. No data loss — a full pull just re-reads and overwrites, and nothing waiting to be uploaded is touched.

**Files touched:**
- lib/core/services/supabase_sync_service.dart (added invite_codes to the pull order + a restore case; updated the stale "deferred to Staff Sign Up" comment; added `ensureBackfillOnce()` one-shot cursor reset, called at the top of `pullChanges`)
- test/sync/sync_backfill_once_test.dart (new — backfill guard: clears cursors once, keeps unrelated keys, idempotent)
- supabase/migrations/0053_pull_invite_codes.sql (new — adds invite_codes to pos_pull_snapshot)
- supabase/scripts/rollback/0053_rollback.sql (new — reverses 0053)
- test/database/invite_codes_pull_restore_test.dart (new)

**Database changes:**
- Cloud migration 0053: adds `invite_codes` to the `pos_pull_snapshot` function's table list so a pull returns the business's invite codes. No schema change — the table already existed (0042) and already pushed. Deploy 0053 before/with shipping the client change.
- No client schema change (no Drift version bump). invite_codes was already a synced table.

**Master plan sections covered:**
- §6 / §9.3 (Staff Management → Invites tab, CEO + Manager). The tab query (InviteCodesDao.watchActive) was already business-scoped; it just had no rows from other devices to show.

**Plan updates made during session:**
- None.

**Tested:**
- `flutter analyze lib/ test/` — (see session output; expected 18 pre-existing avoid_print infos, no new issues).
- `flutter test` — full suite + 3 new restore tests (row lands locally; used/revoked/expired/deleted codes filtered out of watchActive while the full set still pulls; restore is idempotent).
- RLS confirmed unchanged: `invite_codes_tenant_rw` (0050/0051, profiles-based) already lets a tenant's CEO/Manager SELECT their codes; pos_pull_snapshot is SECURITY DEFINER with its own tenant guard.

**Known issues / left open:**
- None for this fix. Emulator check (cross-device): generate an invite on device A → it appears in the Invites tab on device B within a pull/realtime tick.

**Next session should:**
- Continue the pivot plan (drawer rebuild §27.3, or the next unbuilt step).

---

## Session 11 — 2026-05-29 — Who Is Working picker (master plan §8, pivot step 7)

**Built today:**
- The shared-till "Who's working?" picker. It's the screen staff see all day when they switch shifts or come back after the screen auto-locks — different from the Login screen, which is only for a fresh device or a full logout.
- The picker shows the business name and today's date, the title "Who's working?", and one tappable card per active staff member (avatar initials, name, role colour tag). Suspended staff are hidden. If there's only one staff member (or none), it skips straight to the PIN screen.
- Tapping a card opens the PIN screen already pointed at that person. If that person hasn't set a PIN yet, it emails them a one-time code instead.
- A manual lock, the "Switch User" button, and the silent auto-lock now all return to this picker. A cold start (first launch of the day) still goes straight to the PIN screen as before.
- The sidebar's lock button is now a "Switch User" button (switch icon + tooltip); it behaves exactly as before, just better named for the shared-till use.
- Reused the Login screen for PIN entry by letting callers hand it a specific staff member. This also fixed a small bug where a different staff member's PIN screen could show the device-owner's email carried over from setup — the email field is now locked to whoever was picked, which keeps the PIN check pointed at the right person when two staff share a PIN.

**Files touched:**
- lib/core/database/daos.dart (new `WhoIsWorkingEntry` + `UserBusinessesDao.watchActiveStaffForBusiness`; added Users/Roles to the accessor)
- lib/core/database/daos.g.dart, lib/core/database/app_database.g.dart (regenerated)
- lib/core/providers/stream_providers.dart (new `activeStaffProvider`)
- lib/shared/services/auth_service.dart (`showPickerOnUnlock` flag)
- lib/features/auth/screens/login_screen.dart (`presetUser` param + read-only email when identified)
- lib/features/auth/screens/who_is_working_screen.dart (new)
- lib/main.dart (route to picker on unlock)
- lib/shared/widgets/app_drawer.dart (lock → Switch User control)
- lib/features/staff/screens/staff_management_screen.dart (removed leftover FAB debug print)
- test/staff/who_is_working_dao_test.dart (new)
- test/auth/pin_email_scoping_test.dart (new)
- test/auth/who_is_working_screen_test.dart (new)

**Database changes:**
- None. No new tables or columns. The picker reads existing tables (user_businesses + users + roles) through a new read-only DAO query. Nothing new is written or synced.

**Master plan sections covered:**
- §8 (Who Is Working picker) — §8.1 layout, §8.2 cards, §8.3 rules (suspended hidden, single-staff skip), §8.4 tap-to-PIN, §8.5 Switch User / auto-lock routing.
- §30.7 (no spinners) — branded fade while resolving.
- Deferred from §8.2: the "active now" dot (needs multi-till presence; not in this step's scope).

**Plan updates made during session:**
- None.

**Tested:**
- `flutter analyze lib/ test/` — 18 issues, all the pre-existing `avoid_print` infos in test/database/roles_v13_report.dart. No new issues.
- `flutter test` — 155 passed, 58 skipped (baseline 150/58 + 5 new). New tests: DAO returns only active staff of the right business with role joined; getUsersByPin scopes by email when two users share a PIN; picker shows N cards with suspended hidden and tap routes to the PIN screen.

**Known issues / left open:**
- The "active now" dot (§8.2) is deferred until multi-till presence tracking exists.
- The picker resolves the business from the device user, with a single-local-business fallback. Multi-business on one device is Phase 2, so this is fine for now.
- The full labelled "Switch User" button in the redesigned drawer (§27.3 / master plan §27 line 1287) is part of the later drawer-rebuild step; this step only renamed the existing lock control.

**Next session should:**
- Continue the pivot plan (next unbuilt step after the picker). The drawer rebuild (§27.3) will replace the icon-only Switch User control with the full labelled button and the grouped sidebar items.

---

## Session 10 — 2026-05-29 — Staff Management + Invite Codes + Staff Sign Up (pivot step 8)

**Built today:**

The whole staff onboarding + management feature. Step 8 was pulled ahead of the Who-Is-Working picker (step 7): the picker has nothing to show until staff exist, so building staff first gives it real data.

- **Staff Management screen** (§9; CEO + Manager only — hidden entirely for Cashier/Stock keeper). Two tabs (Staff, Invites) with search and an "Invite new staff" button. Staff cards show avatar, name, role colour tag, and last login; suspended staff drop to a greyed section. A Manager sees the CEO and other Managers as faded read-only rows, and sees themselves as a normal card marked "You".
- **Invite a staff member** modal — pick a role and store, enter the person's email, generate an 8-character one-use code (7-day expiry), and share it by Copy / SMS / WhatsApp. A Manager can only invite Cashiers and Stock keepers, and only to their own store. Pending invites can be revoked.
- **Staff detail screen** — change role and suspend/reactivate (each behind a confirm dialog), plus total sales and last login. You can't open or manage your own card.
- **Staff Sign Up flow** (§6) — a new single screen with 6 fading steps (invite code → email → OTP → create PIN → confirm PIN → "Welcome to {business}"). The invited person enters the code, the app shows the business + role and pre-fills their email, they verify by OTP and set a device PIN, then land on Home as the right role with the right store. The Welcome and "No account found" screens' "Join with invite code" buttons now open this (they previously showed a "coming soon" placeholder).
- **Role / permission checks** — new providers for "the current user's role" and "what they're allowed to do", used to hide Staff Management from staff who can't invite and to restrict a Manager's invite options.
- **Smaller fixes:** the store dropdown no longer lists a store twice (it had been including soft-deleted / other-business stores); "last login" is now actually recorded on sign-in (it always read "Never" before); and the staff list refreshes when opened (and pull-to-refresh) so a CEO sees newly-joined staff without re-logging in.

**Decisions / scope:**
- Redemption runs server-side and the device mirrors the result locally, exactly like CEO onboarding — added as the 7th documented direct-write exception in CLAUDE.md §5.
- The "active now" dot (staff logged in on another till) is deferred — there is no presence data yet.
- "Last login" is a single timestamp; a richer "last 5 logins" history is deferred (no data source yet).
- The login email auto-fill / "this PIN belongs to multiple accounts, pick one" issue is deferred to the Who-Is-Working / login work (step 7). Logout deliberately keeps device data (shared-till model).

**Files touched:**
- New: lib/features/auth/screens/staff_sign_up_screen.dart, lib/features/staff/screens/staff_management_screen.dart, lib/features/staff/screens/staff_detail_screen.dart, lib/features/staff/widgets/invite_staff_sheet.dart
- lib/core/database/daos.dart (InviteCodesDao.revoke; UserBusinessesDao.setStatus/setRole/touchLastLogin; StoresDao.watchActiveStores)
- lib/core/providers/stream_providers.dart (currentUserRoleProvider, currentUserPermissionsProvider, hasPermission, usersByBusinessProvider; allStoresProvider now active-only)
- lib/shared/services/auth_service.dart (stamp last login on sign-in)
- lib/shared/widgets/app_drawer.dart (permission-gated Staff Management item)
- lib/features/auth/screens/welcome_screen.dart, no_account_found_screen.dart ("Join with invite code" → Staff Sign Up)
- CLAUDE.md (§5 exception #7)
- Tests: test/auth/staff_sign_up_screen_test.dart, test/staff/invite_staff_sheet_test.dart, test/sync/dispatch/staff_dao_dispatch_test.dart, plus route updates in test/auth/no_account_found_screen_test.dart and welcome_screen_test.dart

**Database changes:**
- No local schema change (still Drift v16) — the membership / invite tables already existed from v13.
- Four cloud migrations, all deployed (each with a rollback script): 0049 (lookup_invite_code + redeem_invite_code RPCs), 0050 (fix infinite-recursion in the user_businesses RLS policy — 42P17), 0051 (resolve the membership tables' RLS via profiles, matching the rest of the app — fixes the 42501 rejections), 0052 (fix an ambiguous "email" column reference in the redeem RPC — 42702). 0050–0052 were latent issues surfaced because Step 8 is the first feature to read/write these tables from the authenticated client rather than via SECURITY DEFINER RPCs.

**Master plan sections covered:**
- §6 Staff Sign Up — built.
- §9 Staff Management — built (§9.1–9.7).

**Plan updates made during session:**
- No master-plan change. CLAUDE.md §5 gained a 7th sync-exception entry (staff-redemption local mirror).

**Tested:**
- `flutter analyze lib/ test/` — clean (only the 18 pre-existing `avoid_print` infos in roles_v13_report.dart).
- `flutter test` — 150 pass, 58 skipped, 0 failures (new: invite-sheet Manager role-filter, staff DAO sync-leak, staff sign-up code step).
- On device: full invite → redeem → join loop confirmed working after the four cloud fixes; cross-role checks (Manager invite restrictions, hide-don't-grey) confirmed.

**Known issues / left open:**
- FAB can still sit behind the system nav bar on the physical device — an inset-fix attempt plus temporary debug logging are in staff_management_screen.dart, awaiting on-device inset values to finish.
- Login email auto-fill / "pick an account" picker — deferred to step 7.
- §6.2 "email already linked to another business → confirm existing PIN" — deferred to Phase 2.
- Redeem-failure message is generic ("Something went wrong, re-enter your PIN") — could be made specific later.

**Next session should:**
- Confirm the FAB on the physical device, decide the login email-fill fix (now vs step 7), then continue the pivot — Who Is Working picker (step 7) and/or CEO Settings Roles & Permissions (step 9).

---

## Session 9 — 2026-05-28 — Auth visual unification (branded look across all auth screens)

**Built today:**

Purely visual pass — no behaviour changed. Brought the older auth screens onto the same branded dark/amber look as CEO Sign Up, Welcome, and No-account-found, and pulled the shared styling into one place.

- **Two new shared widget files (single source of truth):**
  - `pin_keypad.dart` — `PinDots` (6 amber dots), `PinKey` (one 64×64 glass key), and `PinKeypad` (the full numpad, with a `leadingKey` slot for Login's biometric button).
  - `auth_form_kit.dart` — `authTitleStyle` / `authSubtitleStyle`, `AuthFormShell` (title/subtitle scroll shell), `AuthInputCard` (glass field wrapper), `AuthErrorText` (fixed-height inline error).
- **CEO Sign Up now consumes those shared widgets** (its inline `_PinDots`/`_PinPad`/`_formShell`/`_inputCard`/`_errorText` were removed). This kills the duplicate PIN-pad that used to live in both ceo_sign_up and create_pin.
- **Restyled five screens** to the branded look (`BrandedAuthBackground` + the form kit / shared PIN widgets / `AppButton`), preserving every routing branch, timer, lockout, biometric path, and the "capture providers before await" pattern:
  - **email_entry** — branded form shell, glass email field, Google + "Login with PIN" preserved.
  - **otp_verification** — matches the CEO OTP step (title, `OtpBoxRow`, verify/"Verified ✓"/resend). Expiry copy aligned to "5 minutes" (consistent with the rest of auth / master plan §7.1).
  - **existing_account** — branded business card + the real role badge (color tag).
  - **create_pin** — branded background + shared `PinDots`/`PinKeypad`, shared `ShakeWidget` (its private copy removed).
  - **login** — branded background + shared `PinDots`/`PinKeypad`, biometric button passed via `leadingKey`; success overlay + user-picker (with role tags) preserved.
- **Folded in the pending fix:** `fetchSupabaseAccount` resolves the app `users.id` from `auth_user_id` first, then queries `user_businesses` by that id (the column holds the app id, not the auth uid).

**Decisions / scope:**
- The legacy `auth_background.dart` (blurred-photo look) is intentionally **kept** — still used by the deferred screens (biometric setup, store assignment, access-granted, success-dashboard, welcome-verification) and main.dart. Expect a small visual seam at the biometric/success tail of the existing-account path; acceptable since biometric is deferred to CEO Settings.
- No logic/flow change anywhere.

**Files touched:**
- New: lib/features/auth/widgets/pin_keypad.dart, lib/features/auth/widgets/auth_form_kit.dart
- Refactored to consume shared widgets: lib/features/auth/screens/ceo_sign_up_screen.dart
- Restyled: email_entry_screen.dart, otp_verification_screen.dart, existing_account_screen.dart, create_pin_screen.dart, login_screen.dart
- Fix: lib/shared/services/auth_service.dart (fetchSupabaseAccount role lookup)

**Database changes:**
- None.

**Master plan sections covered:**
- §4.3 branded visual style (now applied across the whole auth surface). No plan change.

**Plan updates made during session:**
- None.

**Tested:**
- `flutter analyze lib/ test/` — clean except the 18 pre-existing `avoid_print` infos in roles_v13_report.dart.
- `flutter test` — 144 pass, 58 skipped, 0 failures (no finder tests broke from the extraction).
- Emulator: not yet run this session — see below.

**Known issues / left open:**
- **Emulator regression gate not yet run** (auth is hard to unit-test): returning-device PIN + biometric unlock; 5-wrong → forced Forgot-PIN; existing-email fresh-device → branded email → OTP → existing-account (real role) → create-PIN → Home; brand-new email → OTP → No-account-found → Create → CEO Sign Up (visually continuous); multi-user PIN sheet with role tags; CEO Sign Up still end-to-end (now consumes the extracted widgets).
- The `_UserPickerSheet` modal keeps theme-surface colors (not rebranded) — preserved per scope.

**Next session should:**
- Run the emulator regression gate above, then continue the pivot: Staff Sign Up (§6) / Who Is Working picker (§8).

---

## Session 8 — 2026-05-28 — §7 Login + Forgot PIN (pivot step 6)

**Built today:**

Targeted changes to the Login flow — most of §7 already existed (PIN entry, biometrics, attempt counter, a wired Forgot-PIN link), so this session fixed the gaps.

- **No account found (§7.1).** A brand-new email that signs in through the Login flow now lands on a proper "No account found" screen (Create a new business / Join with invite code) instead of being silently dropped into sign-up. New `no_account_found_screen.dart` (dark theme, shared branded background). The OTP screen's brand-new branch and the email screen's Google brand-new branch both route here now.
- **Double-OTP wart fixed.** "Create a new business" on the No-account-found screen hands the already-verified email to CEO Sign Up via a new `verifiedEmail` argument. When set, the sign-up flow skips its own email + OTP steps (business name → type → store → full name → create PIN → confirm PIN → ready; 7 steps, dots adjust). The Welcome path (no verified email) keeps the full 9 steps.
- **5 wrong PINs → forced Forgot-PIN (§7.1).** Dropped the old 15-minute device lockout entirely. The fifth wrong PIN now sends an email OTP and routes into the existing reset flow (OTP → create new PIN → biometric setup → signed in). The 3rd/4th wrong attempt still warns "N attempts remaining" — reworded from "before lockout" to "before PIN reset".
- **"Owner" hardcode → real role (§8.2).** Built a reactive role-badge resolver (`userRoleProvider`) that resolves a user's role by id (works before login binds a business, e.g. the shared-PIN picker). Replaced the literal "Owner" in five places: the login user-picker, the existing-account card, and three spots in the profile screen (two app-bar subtitles + the role tag). Each shows the real role name with the master-plan color tag (CEO amber, Manager blue, Cashier green, Stock keeper grey). The existing-account screen is reached before any local pull, so it reads the role from the cloud (added to `SupabaseAccountInfo`).

**Decisions / scope (told to the user up front):**
- §5.2 "one PIN across businesses" and the §7.2 multi-business picker stay **Phase 2** (they depend on multi-business membership + cross-device PIN). Phase 1's existing "email already linked to X — sign out & use a different email" handling stays.
- **PINs stay local-only** (device unlock; email/OTP = portable identity). The Phase-2 "PIN portability" goal is met by local re-establishment after OTP, not by cloud-storing a brute-forceable 6-digit hash. Documented in the master plan (§7.4 + §28); no schema or CLAUDE.md change — those already state PINs are local-only.

**Files touched:**
- lib/features/auth/screens/no_account_found_screen.dart (new)
- lib/features/auth/screens/login_screen.dart (removed 15-min lockout + lockout UI; 5-wrong forces Forgot-PIN; user-picker role badge; robust `_forgotPin` email)
- lib/features/auth/screens/ceo_sign_up_screen.dart (`verifiedEmail` arg + email/OTP step skip + dot mapping)
- lib/features/auth/screens/otp_verification_screen.dart, email_entry_screen.dart (brand-new branch → No-account-found)
- lib/features/auth/screens/existing_account_screen.dart (real role tag from cloud)
- lib/features/profile/screens/profile_screen.dart (real role in 3 spots)
- lib/shared/services/auth_service.dart (`SupabaseAccountInfo` carries roleName/roleSlug; fetch from cloud)
- lib/shared/utils/role_display.dart (new — `roleTagColor` by slug)
- lib/core/providers/stream_providers.dart (`userRoleProvider` + two private non-scoped helpers)
- lib/core/database/daos.dart (`RolesDao.watchAllUnscoped`, `UserBusinessesDao.watchForUser`)
- test/auth/no_account_found_screen_test.dart (new — 2 tests)
- reebaplus_master_plan.md (§7.3 forced-path note, new §7.4 PIN local-only, §28 PIN-portability entry)

**Database changes:**
- None. No schema change (still v16), no cloud migration.

**Master plan sections covered:**
- §7 Login Flow (§7.1 no-account-found + 5-wrong-force, §7.3 forgot-PIN verified, new §7.4 PIN storage/recovery).
- §8.2 role color tags (CEO/Manager/Cashier/Stock keeper).
- §28 Phase 2 — PIN portability entry.

**Plan updates made during session:**
- Master plan only: added §7.3 forced-path bullet, new §7.4 (PIN local-only intent), and a §28 Phase-2 PIN-portability entry. No behavioural plan change.

**Tested:**
- `flutter analyze lib/ test/` — clean except the 18 pre-existing `avoid_print` infos in roles_v13_report.dart.
- `flutter test` — 144 pass (142 prior + 2 new No-account-found tests), 58 skipped, 0 failures.
- Emulator: not yet run this session — see below.

**Known issues / left open:**
- **Emulator smoke not yet run** for: returning-device PIN → role badge; fresh-device existing account → OTP → set device PIN; brand-new email → OTP → No-account-found → Create (7-step, email/OTP skipped); 5 wrong PINs → forced reset.
- Shared PIN-pad widget duplication (create_pin_screen + ceo_sign_up_screen) — tracked tech-debt, not done.
- §5.2 / §7.2 multi-business confirm-PIN + picker — Phase 2.

**Next session should:**
- Run the emulator smoke list above, then continue the pivot: Staff Sign Up (§6) / Who Is Working picker (§8).



**Built today:**

Two pieces, done in order.

- **Task A — roles reach the local DB on pull.** The 5 role/membership tables (`roles`, `role_permissions`, `role_settings`, `user_businesses`, `user_stores`) were seeded cloud-side by `complete_onboarding` and already pushed from the client, but the *pull* path never listed them — so a fresh device's role tables stayed empty. Added them to the pull in three places: the cloud snapshot function (`pos_pull_snapshot`), the client's pull order, and the restore handlers. Now a sign-up pulls the 4 default roles (+ their permissions/settings + the CEO's membership/store link) down to the device. New test proves a role-bearing snapshot restores locally.

- **Task B — one CEO Sign Up screen, nine fading steps (master plan §5).** Replaced the old 8-screen onboarding chain (which ran email-first and in a different order) with a single screen that fades between the 9 steps in the master-plan order: business name → business type → store details → full name → email → OTP → create PIN → confirm PIN → "your business is ready". A small dots indicator sits at the top. Business name first; email/OTP mid-flow; explicit confirm-PIN; store details has searchable State + Country (default Nigeria) with currency auto-filling from the country. The "business is ready" step auto-continues to Home after 3 seconds, and the Add-Product sheet auto-opens on the first Home frame (behaviour kept from the old success screen).
- The six business types are the master-plan set (Restaurant, Supermarket, Bar, Beer distributor, Pharmacy, Boutique) — not the old 8-item list.
- Dropped from the flow (not in §5): business phone, business email, timezone, tax-reg-number. The commit feeds safe defaults (business email = CEO email, phone = '', timezone = Africa/Lagos, tax-reg = none); currency comes from the country.
- Biometric setup is no longer part of the CEO flow (it'll be wired into CEO Settings › Security later). The biometric screen file stays (the PIN-reset / staff path still uses it).
- The Welcome "Create a new business" button now opens the new screen. The Welcome background (dark + amber glow + dot grid) was extracted into a shared widget so both screens match.

**Decisions / conflicts resolved (told to the user up front):**
- OTP resend cooldown is **30s** (master plan §5.1) — the old login OTP screen used 60s.
- OTP step shows "expires in 5 minutes" (master plan) — actual expiry is whatever Supabase is configured for (server-side, unchanged).
- Progress indicator is plain dots (master plan says "small dots") rather than the old labelled 7-step indicator, which doesn't fit 9 steps.
- **New-email login fallthrough repointed.** The kept login screens (`email_entry`, `otp_verification`) used to route a brand-new email into the old chain. They now route to the new CEO Sign Up screen (which re-collects email/OTP). This is a known double-OTP wart for the rare "Sign in → brand-new email" path; the proper "No account found" handling (§7.1) lands with the login restructure (PIVOT_PLAN step 6).

**Files touched:**
- supabase/migrations/0048_pull_roles_tables.sql (new — DEPLOYED 2026-05-28; 0047 was already remote)
- supabase/scripts/rollback/0048_rollback.sql (new)
- lib/core/services/supabase_sync_service.dart (`_pullOrder` + 5 restore cases + `restoreTableDataForTesting` seam)
- lib/features/auth/screens/ceo_sign_up_screen.dart (new — the single-screen flow; PIN-step crash fix: split create/confirm shake keys so the shared GlobalKey isn't duplicated during the AnimatedSwitcher cross-fade)
- lib/features/auth/widgets/branded_auth_background.dart (new — extracted Welcome background)
- lib/features/auth/onboarding/onboarding_draft.dart (email mutable, set at step 5; stale doc comments updated)
- lib/features/auth/screens/welcome_screen.dart (CTA → CeoSignUpScreen; uses shared background)
- lib/features/auth/screens/email_entry_screen.dart, otp_verification_screen.dart (new-email branch → CeoSignUpScreen)
- lib/core/data/countries.dart, currencies.dart, nigerian_states.dart (new — Autocomplete data, no new packages)
- test/database/roles_pull_restore_test.dart (new — 2 tests)
- DELETED: business_type_selection_screen.dart, new_owner_name_screen.dart, business_details_screen.dart, location_details_screen.dart, business_settings_screen.dart

**Database changes:**
- No local schema change (still v16).
- Cloud 0048 DEPLOYED 2026-05-28 (`supabase db push`). Correction: the remote was already at 0047 — the earlier "cloud through 0046 / 0047 undeployed" notes (Sessions 4/5 and this entry's first draft) were stale. Remote is now at 0048.

**Master plan sections covered:**
- §5 (CEO Sign Up) — built, new-email path. §5.2 existing-email branch deferred.
- Touches §4 (Welcome CTA repoint), §2.4 (roles now pulled), §30.6 (currency auto-fill / Nigeria default).

**Plan updates made during session:**
- None to the master plan. PIVOT_PLAN step 5 is the work; no scope change.

**Tested:**
- `flutter analyze lib/ test/` — clean except the 18 pre-existing `avoid_print` infos in roles_v13_report.dart.
- `flutter test` — 142 pass (140 prior + 2 new restore tests), 58 skipped, 0 failures.
- Emulator smoke (user-run): full 9-step §5 sign-up, the PIN-step crash fix, and `complete_onboarding` all work end-to-end. The §5 "4 roles in the local DB" role-check is deferred to staff onboarding (now unblocked since cloud 0048 is deployed).

**Known issues / left open:**
- **§5 role-check not yet confirmed on-device.** Cloud 0048 is deployed, so a fresh sign-up's post-onboarding pull should now land 4 roles + their permissions/settings + 1 user_businesses + 1 user_stores locally — to be verified during staff onboarding (§6).
- **Double-OTP** on the "Sign in → brand-new email" path (see decisions above) — cleaned up in step 6.
- §5.2 existing-email → confirm-existing-PIN branch deferred.
- `auth_service.createNewOwner` is still dead (no callers) and its internal comment still names a deleted screen — left untouched (out of scope; surgical).

**Next session should:**
- Run the emulator smoke + DB checkpoint above. Then continue PIVOT_PLAN: Staff Sign Up (§6) / Login restructure (§7, incl. "No account found" + "Owner" hardcode removal), per the recommended order.

**Session 7 follow-ups (same session):**
- Store-name field placeholder set to "Abuja Branch".
- Fixed a duplicate-GlobalKey crash in the PIN step: the create (step 6) and confirm (step 7) bodies both came from `_buildPinStep()` sharing one `ShakeWidget` GlobalKey, and the AnimatedSwitcher kept both mounted during the cross-fade. Split into `_createPinShakeKey` / `_confirmPinShakeKey` (mismatch path shakes the create key via a post-frame callback since step 6 isn't mounted yet at that synchronous point).

---

## Session 6 — 2026-05-28 — Welcome screen (master plan §4)

**Built today:**
- The new Welcome screen — the first screen on a fresh install and after a full logout (master plan §4). Branded entry, centred: logo (with an "RP" rounded-square fallback per §4.1), "Reebaplus", the tagline, an amber **Create a new business** button, an outlined **Join with invite code** button, an "Already have an account? Sign in" link, and the Terms/Privacy small print.
- §4.3 visuals: dark base (`adBg`) with a faint dotted grid (CustomPaint), a soft amber glow from the top-right corner (RadialGradient), and a gentle fade + slide entrance driven by an AnimationController — no spinner (§30.7).
- `ComingSoonScreen` — one reusable dark placeholder, used for Join / Terms / Privacy.
- **Scope split (decided with the user):** this session built the Welcome screen ONLY. The §5 CEO sign-up restructure is the next step and will be **faithful to §5** (one screen, 9 fading steps + dots, business-name first, email/OTP mid-flow).
- **Routing:** `main.dart` fresh-device branch now returns `WelcomeScreen` (was `EmailEntryScreen`); returning-device → `LoginScreen` unchanged; a full logout re-renders this branch → Welcome (verified the `fullLogout` path nulls the device-user notifier; updated its stale comment).
- **CTA destinations (today's entry points):** Create a new business / Sign in → `EmailEntryScreen` (it branches new-vs-existing by email); Join with invite code → the placeholder. The §5 restructure will later repoint "Create a new business" to the business-name step; the real invite-code entry is step 8.
- Reused `AppButton` (amber primary + outline), `SmoothRoute`, and the `colors.dart` tokens — no new theming or button widgets.

**Files touched:**
- lib/features/auth/screens/welcome_screen.dart (new)
- lib/features/auth/screens/coming_soon_screen.dart (new)
- lib/main.dart (fresh-device branch → WelcomeScreen; dropped the now-unused EmailEntryScreen import)
- lib/shared/services/auth_service.dart (comment-only: fullLogout now routes to WelcomeScreen)
- test/auth/welcome_screen_test.dart (new — 2 widget tests: renders logo/name/tagline + 3 CTAs; Join routes to the placeholder)

**Database changes:**
- None. UI only — no schema, cloud, or migration change; nothing to deploy.

**Master plan sections covered:**
- §4 (Welcome screen) — built. §4.2 CTA routing wired to current entry points (final §5/§8 destinations come in later steps).

**Plan updates made during session:**
- None.

**Tested:**
- `flutter analyze lib/ test/` — clean (only the 18 pre-existing `avoid_print` infos in roles_v13_report).
- `flutter test` — 140 passing / 58 skipped, 0 failures (2 new Welcome widget tests).
- Emulator smoke (run by the user): fresh install → Welcome; CTAs route correctly; after full logout → returns to Welcome; a returning device user still goes to `LoginScreen`. Confirmed clean.

**Known issues / left open:**
- "Join with invite code" is a placeholder until step 8 (manual invite-code entry / staff sign-up). "Create a new business" and "Sign in" both currently land on `EmailEntryScreen` — differentiation arrives with the §5 restructure.
- The "Owner" hardcode (existing_account_screen.dart, profile_screen.dart) is untouched — that's step 6.

**Next session should:**
- Begin the §5 CEO Sign Up restructure, faithful to §5: one screen with content fading between the 9 steps + dots indicator, reordered to business-name first with email/OTP at steps 5–6, store details with searchable state/country + currency auto-fill, explicit Confirm-PIN, and the "business is ready" screen. Biometric setup moves out of the flow (PIVOT_PLAN §10). Role seeding already works server-side via `complete_onboarding` — no backend change needed for the checkpoint.

---

## Session 5 — 2026-05-28 — Crate Size Groups (schema v16 + cloud 0047)

**Built today:**
- The deferred crate rename from Step 4 (PIVOT_PLAN decision Q8), as its own focused session. `crate_groups` → `crate_size_groups` everywhere, and the crate "size" stopped being a bottle-count number and became a word category: **Big / Medium / Small**.
- **Scope change (recorded in PIVOT_PLAN before coding, per CLAUDE.md):** Q8 originally said "rename + relax `size IN (12,20,24)` to `size > 0`". The user revised this to "drop the number, make it a Big/Medium/Small category". The master plan needed no change (it never specifies crate size values). PIVOT_PLAN Q8 updated in three places + the §1.3 block.
- **Local (Drift v16).** Renamed table `crate_groups`→`crate_size_groups`, classes `CrateGroups`→`CrateSizeGroups` / `CrateGroupData`→`CrateSizeGroupData`, DAO `CrateGroupsDao`→`CrateSizeGroupsDao` (+ result classes). Cascaded `crateGroupId`→`crateSizeGroupId` / `crate_group_id`→`crate_size_group_id` on the 6 FK tables (suppliers, products, customer_crate_balances + its UNIQUE, manufacturer_crate_balances + its UNIQUE, crate_ledger, pending_crate_returns). Converted the `size` IntColumn → `crateSizeLabel` TextColumn (CHECK `IN ('big','medium','small')`, default `'medium'`). Updated `_syncedTenantTables`, `_softDeletableTables`, the crate_ledger immutability list, and `idx_crate_ledger_owner_group`.
- **v16 migration block** — the codebase's first table-rebuild migration. Renames the table, renames the 6 FK columns, then rebuilds crate_size_groups via `m.alterTable(TableMigration(...))` with a `columnTransformer` mapping `size` → `crate_size_label` (`12→small, 20→medium, 24→big`, else `medium`); recreates the two indexes + bump trigger the rebuild drops. Forwards pending `sync_queue` rows: `crate_groups:*`→`crate_size_groups:*` action types, and `crate_group_id`→`crate_size_group_id` / `p_crate_group_id`→`p_crate_size_group_id` payload keys.
- **The rename was scoped to the DB FK chain only.** A legacy client-side brand enum `CrateGroup { nbPlc, guinness, cocaCola, premium }` (in `crate_group.dart`) is unrelated to the DB table and was left untouched — verified the rename tokens (`CrateGroups`, `crateGroupId`, `crate_group_id`, …) never collide with the brand tokens (`CrateGroup`, `crateGroup`, `crateGroupName`, `CrateGroupLabel`). Applied via scoped `sed` across lib + test (Session-3 precedent), then hand-fixed the two `.size` display sites and the "Crate Group Assets" label.
- **UI:** the two `${grp.size} bottles` sites now show the capitalised category (e.g. "Medium"); "Crate Group Assets" → "Crate Size Group Assets".
- **Cloud `0047_crate_size_groups.sql` (+ rollback)** — written, NOT deployed. Renames table + indexes, renames the 6 FK columns, converts `size int → crate_size_label text` (same CHECK + mapping as local), and rebuilds the 4 affected RPCs from their latest bodies: `pos_pull_snapshot` (array entry), `pos_create_product_v2` (param `p_crate_group_id`→`p_crate_size_group_id`, DROP+recreate), `pos_record_crate_return` (param + columns, DROP+recreate), `pos_approve_crate_return` (column refs, CREATE OR REPLACE).

**IMPORTANT correction made this session (cloud schema reality):**
- The task brief AND a prior memory note both claimed the cloud `crate_groups` "already had `crate_size_label` text and lacked `size`/`empty_crate_stock`/`deposit_amount_kobo`." **This was false.** Reading the cloud migration history directly: `0001_initial.sql` created crate_groups with `size int CHECK (size IN (12,20,24))` + `empty_crate_stock` + `deposit_amount_kobo`, and **no migration ever altered it** — `crate_size_label` exists nowhere cloud-side. So cloud was identical to local pre-v16, there was **no divergence**, and 0047 must convert `size→crate_size_label` cloud-side too (not just rename). Surfaced this to the user before writing 0047; the user confirmed the cloud crate table has **zero rows** and wants it stored as words. The stale `project_crate_cloud_divergence.md` memory was corrected.
- Mapping direction (`12→small` vs the 0001 comment's `12=big`): user said "just save as words" (no records to migrate), so kept the brief's `12→small, 20→medium, 24→big` consistently on both sides.

**Files touched:**
- lib/core/database/app_database.dart (schemaVersion 15→16, v16 migration block, CrateSizeGroups table + crateSizeLabel + CHECK, 6 FK column renames, @DriftDatabase tables/daos lists, _syncedTenantTables, _softDeletableTables, crate_ledger immutability list, idx_crate_ledger_owner_group)
- lib/core/database/app_database.g.dart, daos.g.dart (regenerated — build_runner, 268 outputs)
- lib/core/database/daos.dart + ~11 other lib files (sed rename: providers, sync service, sync_diagnostic, supplier_service, inventory_screen, crate_return_modal, receive_delivery_sheet, cart_service, crate_return_approval_service, receipt_widget)
- lib/features/inventory/screens/inventory_screen.dart (label + category display), lib/features/deliveries/widgets/receive_delivery_sheet.dart (category display)
- test/ (sed rename across crate-touching tests + hand-fixed `size: 12`→`crateSizeLabel: Value('small')` in 3 local tests and `'size': 12`→`'crate_size_label': 'small'` in 3 cloud integration tests)
- test/database/crate_size_groups_v16_payload_rewrite_test.dart (new, 8 tests)
- test/database/crate_size_groups_v16_migration_test.dart (new, 5 tests — target shape + size→label mapping)
- supabase/migrations/0047_crate_size_groups.sql (new, write-only)
- supabase/scripts/rollback/0047_rollback.sql (new)
- PIVOT_PLAN.md (Q8 revision in 3 places + §1.3 block + cloud-reality correction + step-4 deferral marked done)
- BUILD_LOG.md (this entry)

**Database changes:**
- Drift v16: `crate_groups`→`crate_size_groups`; `crate_group_id`→`crate_size_group_id` on 6 tables; `size int`→`crate_size_label text` (CHECK big/medium/small, default medium).
- Cloud 0047 WRITTEN, NOT deployed. 0045+0046 are already deployed (0046 pushed this session), so 0047 only waits on the v16 client shipping — deploy right after.

**Master plan sections covered:**
- §2 rename (Crate Size Groups). Decision Q8 (revised). No master plan edit needed (never specified crate size values; empty-crate flow in §13.4/§16.10 unaffected — `emptyCrateStock`/`depositAmountKobo` untouched).

**Plan updates made during session:**
- Q8 revised: numeric `size` dropped in favour of a Big/Medium/Small `crate_size_label`. Recorded in PIVOT_PLAN before coding.
- Corrected the false "cloud has crate_size_label / lacks the two columns" premise (see the IMPORTANT correction above).

**Tested:**
- `flutter analyze lib/ test/` — 0 errors (only the 18 pre-existing `avoid_print` infos).
- `flutter test` — **135 pass** (122 prior + 8 payload-rewrite + 5 migration), 0 failures.
- Grep checkpoint: zero DB-identifier stragglers in lib (outside the v16 migration block, which intentionally holds the old strings for the ALTERs); the legacy `CrateGroup` brand enum remains intact (1 enum). The only old-token hits are the intentional pre-migration keys inside the two new rewrite/migration tests.

**Known issues / left open:**
- **Cloud 0047 not deployed.** 0045+0046 are deployed (0046 pushed this session), so 0047 only waits on the v16 client — deploy with/right after it ships. Until then, v16 clients pushing `crate_size_group_id` / `crate_size_groups:*` / `p_crate_size_group_id` to the un-migrated cloud will 42703 and queue (no data loss; the v16 block also forwards pre-v16 queued rows).
- **NOT verified on the emulator.** The two `.size`→category display sites and the inventory label change were not exercised on a running app this session — recommend a `flutter run` smoke (fresh install + a v15→v16 upgrade) to confirm the inventory crate cards show the category label and nothing crashes.
- **v15→v16 onUpgrade not driven end-to-end by an automated test.** Consistent with the standing v11→v15 schema-fixture gap (still deferred). The new migration test mirrors the rebuild's `size→label` CASE mapping + asserts the v16 target shape, but the real `TableMigration` rebuild path on a populated v15 DB is covered only by reasoning (FK enforcement OFF during onUpgrade; column set otherwise unchanged). Build the schema-fixture harness before a real-device release — now doubly worth it given v16 is the first table-rebuild migration.

**Next session should:**
- Deploy cloud 0047 once the v16 client ships (0046 was already deployed this session), then resume PIVOT_PLAN at step 5 (Welcome + CEO Sign Up flow).

---

## Session 4 — 2026-05-28 — Pivot step 4 (small renames, partial) + cloud 0042–0045 deploy

**Built today:**
- Deployed cloud migrations 0042–0045 to the linked Supabase project (`supabase db push`). All four applied cleanly and now show as remote in `supabase migration list`. This closes the v14 cut-over window — v14 clients' queued writes drain on next push.
- Started PIVOT_PLAN step 4 ("small renames"). Step 4 turned out to be four independent schema mutations, not one, so it was done as vertical slices (schema → codegen → references → analyzer-green per slice), smallest first. Two slices landed; two were deferred (see Plan updates).
- **Slice (a) Customer Group → Price Tier.** Drift column `customers.customer_group` → `price_tier`. Dart enum `CustomerGroup` → `PriceTier`, field `customerGroup` → `priceTier`. DAO `getPriceForCustomerGroup` → `getPriceForTier`. `pos_create_customer` domain envelope key `p_customer_group` → `p_price_tier`. UI label "Customer Group" → "Price Tier".
- **Slice (a) close-out — CHECK tighten + data migration (the part that was incomplete).** Master plan §16/§21 says Price Tier is Retailer / Wholesaler only, so the CHECK was narrowed from the 4-value legacy set (`retailer,wholesaler,distributor,walk_in`) to `('retailer','wholesaler')`. Local v15 block now: migrates data (`distributor`→`wholesaler`, `walk_in`→`retailer`) then rebuilds the customers table via `m.alterTable(TableMigration(customers))` (SQLite can't ALTER a CHECK) and recreates its three indexes (`idx_customers_business_lua`, `_business_deleted`, `_business_phone`) + `bump_customers_last_updated_at` trigger. Cloud 0046 does the data `UPDATE` then `DROP CONSTRAINT customers_customer_group_check` / `ADD CONSTRAINT customers_price_tier_check`. 0046_rollback reverses (restores the 4-value CHECK; the data migration itself is one-way). Fresh-install CHECK enforcement covered by new `test/database/price_tier_check_test.dart` (5/5).
- **Slice (b) Purchases → Shipments.** Drift table `purchases` → `shipments`, class `Purchases` → `Shipments`, data class `DeliveryData` → `ShipmentData`, `DeliveriesDao` → `ShipmentsDao` (+ `getLastDeliveryForProduct` → `getLastShipmentForProduct`, `LastDeliveryInfo` → `LastShipmentInfo`). The permanent ledger FK columns `stock_transactions.purchase_id` and `payment_transactions.purchase_id` → `shipment_id` (their exactly-one-FK CHECK constraints and the `_ledgerTables` immutability lists updated to match). `purchase_items` KEEPS its `purchase_id` column (table is deferred-for-drop). Synced-table lists + sync restore case updated.
- **Dashboard → Home (Option A, settled at close-out).** Drawer label "Dashboard" → "Home". Class `DashboardScreen` → `HomeScreen`, file `dashboard_screen.dart` → `home_screen.dart` (git mv; `main_layout` import + usage updated). Internal nav route key kept at the original stable `'dashboard'` (an earlier pass had flipped it to `'home'`; reverted across all 7 usages — navigation_service index map, drawer, home/reports_hub/approvals screens). Net: user-facing = Home, code class = HomeScreen, internal route key = 'dashboard'. `lib/features/dashboard/` folder kept.
- **Settings → CEO Settings.** Drawer label + the two SettingsScreen AppBar titles. (Role-based hiding deferred — see Plan updates.)
- Drift schema bumped 14 → 15. Single `if (from < 15)` migration block covers slices (a) + (b): the column/table renames plus pending-`sync_queue` payload rewrites (`customer_group`→`price_tier`, `p_customer_group`→`p_price_tier`, and `purchase_id`→`shipment_id` scoped to `stock_transactions`/`payment_transactions` upserts only, plus `purchases:*`→`shipments:*` action-type forwarding).
- Cloud migration `supabase/migrations/0046_pivot_small_renames.sql` (write-only, NOT deployed). Renames the two cloud columns + the table, and rewrites every live function that referenced the old names — authoritative list pulled from `pg_proc` on the live DB: `pos_create_customer` (→ `p_price_tier`/`price_tier`), `pos_inventory_delta_v2` (→ `shipment_id`), `pos_pull_snapshot` (array `'purchases'`→`'shipments'`), and DROP of the dead v1 `pos_inventory_delta` (already broken since 0045 renamed `inventory.warehouse_id`; client only calls `_v2`). Rollback `supabase/scripts/rollback/0046_rollback.sql` mirrors the reverse (restores all four functions incl. v1, reverses the renames).

**Files touched:**
- lib/core/database/app_database.dart (schemaVersion 14→15, v15 migration block, Customers/StockTransactions/PaymentTransactions/PurchaseItems table defs, Shipments class + DataClassName, ledger CHECK + immutability lists, @DriftDatabase tables/daos lists, `_syncedTenantTables`)
- lib/core/database/app_database.g.dart, daos.g.dart (regenerated)
- lib/core/database/daos.dart (ShipmentsDao, getPriceForTier, pos_create_customer envelope key, stock-transaction referenceId)
- lib/core/services/supabase_sync_service.dart (synced list + restore case `purchases`→`shipments`/`ShipmentData`)
- lib/features/customers/data/models/customer.dart, data/services/customer_service.dart, screens/customers_screen.dart, screens/customer_detail_screen.dart, widgets/add_customer_sheet.dart (PriceTier)
- lib/features/pos/controllers/pos_controller.dart, screens/pos_home_screen.dart, widgets/product_grid.dart (PriceTier)
- lib/features/inventory/screens/product_detail_screen.dart (ShipmentsDao / LastShipmentInfo)
- lib/shared/widgets/app_drawer.dart (Home + CEO Settings labels, route key), lib/shared/services/navigation_service.dart (route key), lib/features/dashboard/screens/{dashboard,reports_hub,approvals}_screen.dart (route key)
- lib/core/settings/settings_screen.dart (AppBar titles)
- test/integration/rpcs/pos_create_customer_test.dart (p_price_tier contract — skipped integration test)
- supabase/migrations/0046_pivot_small_renames.sql (new, write-only; + CHECK tighten at close-out)
- supabase/scripts/rollback/0046_rollback.sql (new; + CHECK restore)
- lib/features/dashboard/screens/home_screen.dart (renamed from dashboard_screen.dart, class HomeScreen)
- lib/shared/widgets/main_layout.dart (HomeScreen import + usage)
- test/database/price_tier_check_test.dart (new, fresh-install CHECK enforcement, 5/5)
- test/database/renames_v15_payload_rewrite_test.dart (new, payload rewrites, 9/9 — written alongside this work)
- PIVOT_PLAN.md (step 4 status + deferrals)

**Database changes:**
- Drift v15: `customers.customer_group`→`price_tier`; `purchases`→`shipments`; `stock_transactions.purchase_id`/`payment_transactions.purchase_id`→`shipment_id`. `purchase_items` unchanged.
- Cloud 0042–0045 DEPLOYED. Cloud 0046 WRITTEN but NOT deployed (gated).

**Master plan sections covered:**
- §2 renames (Price Tier, Home, Shipments, CEO Settings). Decisions Q5/Q8/Q9 touched (see deferrals).

**Plan updates made during session (recorded in PIVOT_PLAN.md step 4):**
- **Drop `purchase_items` (Q5) deferred to step 25** — it still backs the product-detail "Last Delivery" card via `ShipmentsDao.getLastShipmentForProduct`; dropping now orphans the feature with no replacement.
- **Crate Groups → Crate Size Groups (Q8) deferred to its own session** — ≈196 refs / 22 files + cloud RPC rewrites; v14-scale, not "small". (User chose "its own focused session".)
- **Hide CEO Settings for non-CEO (Q9) deferred to step 10** ("Sidebar role guards") — no role-resolution infra exists yet (only a hardcoded `isCEO=true` placeholder in inventory). Step 4 did the label only.

**Tested:**
- `flutter analyze` clean (only pre-existing `avoid_print` infos in `test/database/roles_v13_report.dart`). `flutter test` → **all 122 pass** (108 prior + 9 `renames_v15_payload_rewrite_test` + 5 `price_tier_check_test`), 0 failures.
- One bootstrap failure surfaced mid-slice-(b) and was fixed: the two ledger tables' CHECK constraints and `_ledgerTables` immutability lists still referenced `purchase_id` after the getter rename; updated to `shipment_id` + regenerated.

**Known issues / left open:**
- Cloud 0046 not deployed — deploy after this lands, right after the v15 client ships (re-read 0046 header's deploy-ordering note). Until then, v15 clients pushing `price_tier`/`shipment_id` keys to the un-migrated cloud will 42703 and queue (no data loss).
- "Zero stragglers" checkpoint only partial: `purchase_items`/`PurchaseItems` and `crate_group(s)` deliberately remain pending their deferred steps.
- The v11→v14 (now v15) upgrade schema-fixture test gap from Session 3 still stands. Specifically untested: the v15 customers table-rebuild path (`m.alterTable(TableMigration(customers))` + index/trigger recreation). Reasoning gives confidence (FK enforcement is OFF during onUpgrade — proven by the v12 incident where `DROP TABLE` reached the copy stage; column set is unchanged post-rename so the copy is 1:1; indexes/trigger recreated to match onCreate exactly) and fresh-install CHECK is tested, but the actual 14→15 upgrade is not exercised. Build the schema-fixture before any real-device release.

**Next session should:**
- Deploy cloud 0046 (after confirming the deploy-ordering note), then do slice (d): Crate Groups → Crate Size Groups as a dedicated v14-scale rename session (schema v16 + cloud 0047). Then resume the plan at step 5 (Welcome + CEO Sign Up flow).

---

## Session 3 — 2026-05-27 — Schema v14 (warehouses → stores rename pass)

**Built today:**
- Schema v14 bump. The `warehouses` table is now `stores`. Every `warehouse_id` foreign-key column on the ten dependent tables (users, customers, inventory, stock_adjustments, orders, order_items, expenses, activity_logs, plus the two v13 placeholders invite_codes and user_stores) is now `store_id`. `stock_transfers.from_location_id` / `to_location_id` and `stock_transactions.location_id` kept their generic names — only their FK target changed.
- Drift v14 migration block in `app_database.dart` that runs the rename in place using SQLite's `ALTER TABLE ... RENAME TO` and `ALTER TABLE ... RENAME COLUMN` (auto-updates FK references, trigger bodies, and index column refs on SQLite ≥ 3.25). Index names that embedded "warehouse" (`idx_warehouses_business_lua`, `idx_warehouses_business_deleted`, `idx_inventory_business_pw`) and the `bump_warehouses_last_updated_at` trigger were dropped + recreated with `stores` / `store_id` in the new names. Pending `sync_queue` rows with `action_type = 'warehouses:upsert'` or `'warehouses:delete'` are forwarded to `stores:upsert` / `stores:delete`.
- All Drift Dart classes renamed: `Warehouses` → `Stores`, `WarehouseData` → `StoreData`, `WarehousesDao` → `StoresDao`. The `_syncedTenantTables` and `_softDeletableTables` lists updated. The `activity_logs` immutability trigger's column list updated from `warehouse_id` → `store_id`.
- Codegen regenerated (`build_runner build --delete-conflicting-outputs`).
- Stream providers renamed: `allWarehousesProvider` → `allStoresProvider`, `warehouseByIdProvider` → `storeByIdProvider`, `productsByWarehouseProvider` → `productsByStoreProvider`.
- `NavigationService` renames: `warehouseLocked`/`lockedWarehouseId`/`selectedWarehouseId`/`customersInitialWarehouseId` → `store*` equivalents; `applyUserWarehouseLock`/`clearWarehouseLock`/`setLockedWarehouse` → `*Store*`; route map `7: 'warehouse'` → `7: 'stores'`. `app_providers.lockedWarehouseProvider` → `lockedStoreProvider`.
- Folder move: `lib/features/warehouse/` → `lib/features/stores/`. `warehouse_screen.dart` → `stores_screen.dart` (plural to match sidebar label). `warehouse_details_screen.dart` → `store_details_screen.dart`. `data/models/warehouse.dart` → `data/models/store.dart`. The list-screen class became `StoresScreen` for plural/file alignment.
- Auth onboarding file `warehouse_assignment_screen.dart` → `store_assignment_screen.dart`. `onboarding_draft.warehouseId/Name` → `storeId/Name`.
- Sidebar label `'Warehouse'` → `'Stores'` (master plan §27.2 plural). Active-route key updated to `'stores'`.
- Bulk sed pass across 62 remaining Dart files (excluding `app_database.dart` and `*.g.dart`) for identifier/string consistency, plus a follow-up pass for uppercase `WAREHOUSE` in inventory and delivery sheet section labels. Broken import paths after sed (sed produced `features/store/...`; real folder is `features/stores/...`) were corrected.
- Cloud migration `supabase/migrations/0045_rename_warehouses_to_stores.sql` (1376 lines) — single transaction: table rename, ten column renames, three constraint renames (one explicit FK, two anonymous UNIQUEs), two v13 FK constraint renames (`invite_codes_warehouse_id_fkey`, `user_stores_warehouse_id_fkey`), three index renames, then CREATE OR REPLACE for seven RPCs with surgical `warehouse_id` → `store_id` and `warehouses` → `stores` substitutions (`pos_pull_snapshot`, `pos_record_sale_v2`, `pos_inventory_delta_v2`, `pos_create_product_v2`, `pos_cancel_order`, `pos_record_expense`, `pos_create_customer`), plus a signature change on `complete_onboarding` (parameter renamed `p_warehouse_id` → `p_store_id` via DROP + recreate). Three RPCs that had `p_warehouse_id` in their parameter list (`pos_record_sale_v2`, `pos_record_expense`, `pos_create_customer`) also got DROP + parameter-rename treatment to match the Dart client's `p_store_id` payload key. Four RPCs whose bodies don't reference warehouses (`pos_approve_crate_return`, `pos_wallet_topup`, `pos_void_wallet_txn`, `pos_record_crate_return`) were left alone — Postgres auto-updates their references to the renamed table. Trailing verification queries appended.
- Rollback `supabase/scripts/rollback/0045_rollback.sql` (1324 lines) — mirror reverse: `complete_onboarding` restored first (verbatim from 0044 to keep mid-rollback clients working), then all seven RPCs restored from their pre-rename source bodies (0020 / 0017 / 0011), then indexes / constraints / columns / table reversed in opposite order.
- Master plan updates: §1.1 now explicitly says "One business is owned by one CEO, and one CEO can own multiple businesses" and adds "so a single CEO email can map to many businesses" to the database-multi-membership paragraph. §2.2 now explicitly says "Every business has at least one store, and one business can have many stores." Both restatements requested by the user to make the architecture's direction explicit; the data model already supported both.

**Files touched:**
- reebaplus_master_plan.md (§1.1, §2.2 directionality)
- lib/core/database/app_database.dart (schema rename, schemaVersion 13 → 14, v14 migration block, _syncedTenantTables, _softDeletableTables, ledger immutability list, _postCreateStatements index)
- lib/core/database/app_database.g.dart (regenerated)
- lib/core/database/daos.dart (DAO + method renames + SQL strings)
- lib/core/database/daos.g.dart (regenerated)
- lib/core/providers/stream_providers.dart (3 provider renames)
- lib/core/providers/app_providers.dart (lockedWarehouseProvider → lockedStoreProvider)
- lib/shared/services/navigation_service.dart (six identifier renames + route map)
- lib/features/stores/ (new, from git mv of lib/features/warehouse/; 4 screens/models with internal sed)
- lib/features/auth/screens/store_assignment_screen.dart (renamed from warehouse_assignment_screen.dart, sed)
- lib/features/auth/onboarding/onboarding_draft.dart (field rename)
- lib/shared/widgets/app_drawer.dart (sidebar label "Stores", route "stores")
- lib/shared/widgets/main_layout.dart (StoresScreen class binding + import path)
- lib/shared/widgets/receipt_widget.dart, activity_log_screen.dart (sed)
- lib/shared/services/auth_service.dart, order_service.dart, cart_service.dart, activity_log_service.dart (sed)
- lib/shared/models/activity_log.dart (sed)
- lib/features/customers/{screens,widgets,data}/ (sed across 5 files)
- lib/features/auth/screens/{login_screen,access_granted_screen,create_pin_screen}.dart (sed)
- lib/features/pos/{screens,widgets,controllers}/ (sed across 5 files)
- lib/features/inventory/{screens,widgets,data}/ (sed across 9 files; uppercase WAREHOUSE labels fixed)
- lib/features/expenses/widgets/add_expense_sheet.dart (sed)
- lib/features/dashboard/screens/{dashboard_screen,stock_audit_screen}.dart (sed)
- lib/features/orders/screens/orders_screen.dart (sed)
- lib/features/profile/screens/profile_screen.dart (sed)
- lib/features/deliveries/widgets/receive_delivery_sheet.dart (sed; uppercase fix)
- lib/features/sync/screens/first_sync_screen.dart (sed)
- lib/core/widgets/app_fab.dart, lib/core/diagnostics/sync_diagnostic.dart, lib/core/services/supabase_sync_service.dart (sed)
- lib/main.dart (sed; import path corrected)
- supabase/migrations/0045_rename_warehouses_to_stores.sql (new, 1376 lines)
- supabase/scripts/rollback/0045_rollback.sql (new, 1324 lines)
- BUILD_LOG.md (this entry; checklist row updated)

**Database changes:**
- Drift schema bumped to v14.
- Table `warehouses` renamed to `stores` locally.
- Ten `warehouse_id` columns renamed to `store_id`.
- Indexes `idx_warehouses_business_lua`, `idx_warehouses_business_deleted`, `idx_inventory_business_pw` renamed to their `_stores_` / `_ps` equivalents.
- Trigger `bump_warehouses_last_updated_at` renamed to `bump_stores_last_updated_at`.
- `_syncedTenantTables`: `'warehouses'` → `'stores'`.
- `_softDeletableTables`: `'warehouses'` → `'stores'`.
- `_LedgerImmutability('activity_logs', ...)`: `'warehouse_id'` → `'store_id'` (the column rename auto-updates the trigger body; the list mirrors the new shape for fresh installs).
- Pending `sync_queue` rows with table-level `warehouses:*` action_types are forwarded to `stores:*`.
- Cloud side: migration 0045 + rollback ready; deploy as one commit with the Dart client to avoid a `p_warehouse_id`/`p_store_id` parameter-name mismatch on `complete_onboarding` and the three v2 RPCs whose parameter names also changed.

**Master plan sections covered:**
- §1.1 (multi-membership directionality made explicit).
- §2.2 (multi-store directionality made explicit; Warehouse → Store rename source-of-truth).
- §27.2 (sidebar item is "Stores", plural).
- §27.5 (Warehouse sidebar item replaced).
- Touches every section that mentions the renamed word, but they were already correct in the plan (the doc never said "Warehouse" outside §27.5).

**Plan updates made during session:**
- Two restatements in §1.1 and §2.2 making "one CEO → many businesses" and "one business → many stores" directionality explicit. Requested by the user; no architectural change.

**Tested:**
- `flutter analyze lib/ test/` — clean of errors. 18 pre-existing `avoid_print` infos remain in `test/database/roles_v13_report.dart` (intentional debug output from Session 2; out of scope).
- `flutter test test/database/roles_v13_seed_test.dart` — 7/7 passing. Asserts row counts (30 / 63 / 8 / 1 / 1 — the trailing `user_stores` count survives the v13 → v14 column rename invisibly because the test queries via Drift's typed API).
- `flutter test` (full suite) — 101 passed, 58 skipped, zero failures.
- `flutter pub run build_runner build --delete-conflicting-outputs` — succeeded; 238 outputs. Only the pre-existing `manager` API duplicate-orderings warnings (Session 2) remain.
- Final grep: zero `warehouse` references in `lib/` or `test/` Dart files outside the v14 migration block in `app_database.dart` (the migration block intentionally contains the old strings to execute the rename).

**Known issues / left open:**
- Cloud migration 0045 + rollback 0045 are written but NOT yet deployed. The user will handle deploy timing. **Deploy the SQL and ship the new Dart build in the same commit / rollout** — the `complete_onboarding` signature changes parameter name `p_warehouse_id` → `p_store_id`, and `pos_record_sale_v2` / `pos_record_expense` / `pos_create_customer` similarly. Any client + server mismatch on parameter names will fail the RPC.
- `pos_pull_snapshot` (last in 0020) still references the dropped `business_members` and `invites` tables in its `v_tenant_tables` array. 0045 only substitutes `'warehouses'` → `'stores'` — it does NOT fix the stale references because that's a separate concern noted in `project_role_refactor.md`. The snapshot has presumably been broken since 0041; if so, that needs its own session.
- No upgrade-path test asserts v13 → v14 migration runs without errors on a real device. Session 2's test suite uses `onCreate` (fresh v14 schema) only. The migration was reasoned about against SQLite's documented behavior (≥ 3.25 auto-updates FK refs / trigger bodies on RENAME); a real v12/v13 device upgrading should be smoke-tested before relying on it in production.
- v11 → v14 cumulative upgrade path is not exercised by automated tests. The v12 raw DROP COLUMN fix (commit `b9ae0b8`) is reasoned about — SQLite 3.35+ semantics, bundled SQLite is recent enough via `sqlite3_flutter_libs ^0.5.15` — but not directly verified. Before any release goes to a real device that was last installed at v11 or earlier, add a Drift schema-fixture test: `drift_dev schema dump` for v11/v12/v13, then a `verifySelf()` walk through each upgrade block. Roughly a one-session investment; worth doing once because it pays for itself on every subsequent schema change.

**Next session should:**
- Begin step 4 of PIVOT_PLAN.md §8: the small renames pass (Customer Group → Price Tier, Dashboard → Home, Purchases → Shipments, Crate Groups → Crate Size Groups, Settings → CEO Settings; drop `purchase_items`). This is another schema bump (v15) plus cloud-side rename mirror.

**Code-review fixes applied 2026-05-27 (same session, after the initial pass):**

User reviewed the Step 3 output and surfaced three findings. All fixed before closing out the session.

- **P0 — sync_queue payload rewrite.** v14 originally rewrote only the `action_type` for `warehouses:*` rows; payloads of writes to tables that reference the renamed table (users, customers, inventory, orders, …) still carried `'warehouse_id': '...'` keys. After cloud 0045 deploys, those keys would either get silently stripped by the push-time column whitelist (users) or hard-fail with PostgREST 42703 (every other table). Same problem on domain envelopes with top-level `p_warehouse_id`. Fix: two extra `customStatement` UPDATEs at the bottom of the v14 block that use `json_set` + `json_remove` to rewrite top-level `$.warehouse_id` → `$.store_id` and `$.p_warehouse_id` → `$.p_store_id` on every pending sync_queue row. Documented in-block that nested keys (e.g. `warehouse_id` inside `p_movements` arrays for `pos_record_sale_v2`) are NOT rewritten — SQLite's `json_set` can't recurse and the nested shape is RPC-specific. Practical risk is low because domain envelopes drain quickly. New test file `test/database/stores_v14_payload_rewrite_test.dart` (7 cases) asserts: top-level rewrite on `users:upsert`; cross-table rewrite on 9 affected tables; domain `p_warehouse_id` rewrite; payloads without the key are untouched; non-pending rows skipped; idempotent on repeat runs; mixed (both keys present) payloads handled.
- **P1 — `pos_pull_snapshot` had a stale array.** The original rewrite in 0045 propagated `'business_members'` and `'invites'` from 0020 into the new array, but those tables were dropped by 0041 and the function has been broken since. Removed both strings from the array in 0045 and in the rollback (the rollback intentionally does NOT restore the broken 0020 shape — it restores a 0020-shape with the fix preserved, so a rollback does not re-introduce the snapshot bug). Added explanatory comments. The function should now actually work after 0045 deploys.
- **P2 — CLAUDE.md §5 exception #6.** One-word fix: "writes to `users` / `businesses` / `warehouses`" → "writes to `users` / `businesses` / `stores`". Hard rule #15 and coding rule #2 were already correct from the earlier sweep.

**Re-verification:**
- `flutter analyze lib/ test/` → still 0 errors; only the 18 pre-existing `avoid_print` infos.
- `flutter test` → 108 passing (was 101), 58 skipped, 0 failures. The 7-case payload-rewrite test passes.

---

## Session 2 — 2026-05-26 — Schema v13 (roles, permissions, membership)

**Built today:**
- Schema v13 bump. Seven new tables: `permissions` (global static config), `roles`, `role_permissions`, `role_settings`, `user_businesses`, `invite_codes`, `user_stores`. Six are synced tenant tables; `permissions` is global.
- Drift v13 migration that creates the new tables, adds the matching `(business_id, last_updated_at)` and soft-delete indexes, adds bump triggers, and seeds the 30-row global `permissions` table from a hardcoded list.
- `_postCreateStatements` updated to do the same for fresh installs (v13 schema on a brand-new device).
- Seven new DAOs in `daos.dart`: `PermissionsDao` (read-only), `RolesDao`, `RolePermissionsDao`, `RoleSettingsDao`, `UserBusinessesDao`, `InviteCodesDao`, `UserStoresDao`. All tenant DAOs route writes through `enqueueUpsert` / `enqueueDelete` per CLAUDE.md §5.
- Seven new stream providers in `stream_providers.dart`: `allRolesProvider`, `allPermissionsProvider`, `rolePermissionsProvider`, `roleSettingsProvider`, `userBusinessesProvider`, `myUserStoresProvider`, `activeInviteCodesProvider`.
- Three Supabase migrations: `0042` (schema + RLS + realtime + bump triggers), `0043` (permissions seed + per-business backfill via `seed_default_roles_for_business` helper function), `0044` (extends `complete_onboarding` RPC to seed roles + bind CEO).
- Verification test `test/database/roles_v13_seed_test.dart` — 7 tests, all green. Companion report at `test/database/roles_v13_report.dart` that prints actual DB contents for spot-check.

**Files touched:**
- lib/core/database/app_database.dart
- lib/core/database/app_database.g.dart (regenerated)
- lib/core/database/daos.dart
- lib/core/database/daos.g.dart (regenerated)
- lib/core/providers/stream_providers.dart
- supabase/migrations/0042_create_roles_permissions_tables.sql (new)
- supabase/migrations/0043_seed_permissions_and_backfill_businesses.sql (new)
- supabase/migrations/0044_complete_onboarding_seeds_roles.sql (new)
- test/database/roles_v13_seed_test.dart (new)
- test/database/roles_v13_report.dart (new)
- BUILD_LOG.md (this entry)

**Database changes:**
- Drift schema bumped to v13.
- Seven new tables added (see "Built today").
- `_syncedTenantTables` extended with: roles, role_permissions, role_settings, user_businesses, invite_codes, user_stores.
- `_softDeletableTables` extended with: roles, invite_codes.
- `_LedgerImmutability` and existing ledger tables unchanged.
- Cloud side: three new migrations 0042/0043/0044, plus a new SQL helper `seed_default_roles_for_business(uuid)`. Not yet deployed — user to deploy when convenient.

**Master plan sections covered:**
- §2.1 (Data-driven roles) — schema scaffolded; runtime use in later sessions.
- §2.4 (Database tables) — six of the listed tables built; `stores` and `activity_logs` extensions deferred to later steps per PIVOT_PLAN.md.
- §2.5 (Permission keys) — all 30 starter keys seeded.

**Plan updates made during session:**
- None. (All plan changes from this session were captured in Session 1 ahead of code work.)

**Tested:**
- `flutter test test/database/roles_v13_seed_test.dart` — 7 / 7 passing. Asserts row counts (30/63/8/1/1), slugs (ceo/manager/cashier/stock_keeper), per-role permission counts (30/24/6/3), default setting values, and the corrected Stock-keeper-no-products.add invariant.
- `flutter analyze` on the three changed lib files — no issues.
- `flutter pub run build_runner build` — succeeded; warnings about duplicate `manager` API reference names are pre-existing and don't affect runtime.

**Known issues / left open:**
- Cloud migrations 0042/0043/0044 have been written but not deployed (no local Supabase instance was configured for this session). When deployed, run the verification queries at the bottom of each migration file against a real Supabase instance to confirm the row counts match.
- The `manager` API duplicate-orderings warnings from build_runner are pre-existing; the master plan rebuild has no `manager`-API usage, so they're cosmetic. Add `@ReferenceName()` annotations as a cleanup pass later if needed.
- Local backfill for v12 → v13 upgraders is intentionally NOT done in the Drift migration — the cloud is authoritative and the next sync pull populates the tenant tables. This means a v12 device upgrading offline will have empty role tables until it reconnects. Document this in the upgrade notes when shipping.

**Next session should:**
- Begin step 3 of PIVOT_PLAN.md §8: rename pass for warehouses → stores (Drift v14 + cloud-side migration). Touches the new `invite_codes.warehouse_id` and `user_stores.warehouse_id` columns along with everything else.

---

## Session 1 — 2026-05-26 — Pivot Planning

**Built today:**
- No code written. Read-only investigation session to produce PIVOT_PLAN.md.
- Read all planning docs and inventoried the existing codebase end-to-end.
- Surfaced 10 open questions; user answered all 10.
- Wrote PIVOT_PLAN.md in the repo root.

**Files touched:**
- PIVOT_PLAN.md (created, then revised after user decisions)
- reebaplus_master_plan.md (updated — see "Plan updates" below)
- BUILD_LOG.md (this entry)

**Database changes:**
- None.

**Master plan sections covered:**
- Full read of reebaplus_master_plan.md to map gaps against the current codebase.

**Plan updates made during session:**

The user reviewed PIVOT_PLAN.md's 10 open questions and approved the following changes to reebaplus_master_plan.md:

- **§2.3 rewritten.** Was: "drop users_role_tier_check constraint". Now: "Starting from a clean schema — the old staff/role system was wiped in commit 38ea06b / migration 0041; all §2.4 tables build fresh."
- **§1.1 rewritten.** Was: "one email can belong to more than one business" (no caveat). Now: "Phase 1: each user belongs to one business at a time. The database supports multi-membership from day one; the switch-business picker UI is Phase 2."
- **§7.1 updated.** Removed the "If user belongs to multiple businesses, show business picker" line. Replaced with: "Straight to Home for the user's single business. Multi-business picker is Phase 2."
- **§16.5 updated.** Added explicit note that the four legacy product price columns (retail / bulk breaker / distributor / selling) are dropped during the pivot. Products now hold exactly three prices: Buying Price, Retailer Price, Wholesaler Price.
- **§16.5 + new §16.11 added.** Barcode scanning is in scope for Phase 1, but only for Pharmacy and Supermarket business types. Hidden for Bar, Beer Distributor, Restaurant, Boutique. The `barcode_widget` package stays in pubspec.yaml. The QR code on the receipt remains removed (§15.3).

Other decisions that did not change the master plan but are recorded in PIVOT_PLAN.md:
- Funds Register movements live as a new `funds_account_id` column on `payment_transactions` (no new `funds_movements` table).
- `users.businessId` stays as a "primary business" pointer; `user_businesses` is built alongside it.
- `purchase_items` is dropped along with the `purchases` → `shipments` rename.
- `activity_logs` migrates to the generic `entity_type` / `entity_id` / `before` / `after` shape; old per-entity FK columns dropped after data copy.
- "Pro Tips" sidebar item removed (moves to Settings > Help in Phase 2).
- `crate_groups` → `crate_size_groups`; relaxed to allow any positive integer.
- "Settings" sidebar item renamed to "CEO Settings", hidden for non-CEO.

**Tested:**
- N/A — planning only.

**Known issues / left open:**
- The Q4 product price column drop will lose existing price data on test devices. User confirmed: "no data migration from the old columns — fresh start. User will manually re-enter prices after the migration." Confirm again before running the migration.

**CLAUDE.md updates made this session:**
- §5 (Sync invariants) expanded from 2 documented exceptions to 6. The four additions: `_compensateRejectedSale` (order_service.dart), `setUserPin` (auth_service.dart, PIN columns local-only by schema), `upsertLocalUserFromProfile` (auth_service.dart, mirrors a cloud read), and `createNewOwner` / `completeOnboarding` (auth_service.dart, cloud RPC already wrote canonical state and resolver isn't bound). All four were already justified in code with explicit comments; the documentation was just out of date. Update done out-of-band ahead of the main pivot order so future sessions don't accidentally "fix" legitimate code.

**Additional plan updates made this session (during step 2 blueprint review):**
- Master plan §16.7 updated: "Add product" for Stock keeper changed from "Yes" to "No". User clarified the planning decision: only CEO and Manager can add new products. Stock keepers can add stock and adjust quantities on existing products only. This drops `products.add` from the Stock keeper default permission set.
- Default `role_settings.max_expense_approval_kobo` for Manager set to 0 (was tentatively ₦50,000 in the first blueprint). CEO must set this explicitly in CEO Settings before any Manager can approve expenses without escalation. Safer opening default for fresh businesses. (Master plan §10.2 was already non-prescriptive; no master plan edit needed.)
- `roles` table gains a `slug` column (lowercase identifier: `ceo`, `manager`, `cashier`, `stock_keeper`). All code that branches on role identity uses the slug, never the name. `name` stays for display + future localisation. UNIQUE (business_id, slug). The four default seeds carry these slugs.

**Notes for later sessions (not actioned this session):**
- The Cashier `reports.see_sales` permission grants the bare ability to see a sales report, but the "own sales only" scope is NOT enforced by the permission itself — it must be enforced at the query layer. Make sure step 11 (Home role-aware cards) and step 26 (Reports) both apply this scope filter when the current user is a Cashier. The same scoping discipline applies anywhere a role has "own store only" or "own sales only" access per master plan tables — permissions answer "can they see the report?", queries answer "what data is in it?".

**Next session should:**
- Begin with step 1 of PIVOT_PLAN.md section 8: master plan reconciliation review with the user (already done in this session — can skip to step 2).
- Then step 2: build the schema v13 migration with the new tables (`roles`, `permissions`, `role_permissions`, `role_settings`, `user_businesses`, `invite_codes`, `user_stores`). Their DAOs and stream providers. Mirror cloud-side. Add to `_syncedTenantTables`. Seed 4 default roles + permission rows on business creation.

---

## Session 0 — Setup (template entry — replace with first real session)

**Built today:**
- This is a placeholder entry. Delete it after the first real session is logged.

**Files touched:**
- MASTER_PLAN.md
- CLAUDE.md
- BUILD_LOG.md

**Database changes:**
- None.

**Master plan sections covered:**
- All sections (initial setup of planning files).

**Plan updates made during session:**
- None.

**Tested:**
- N/A — setup only.

**Known issues / left open:**
- Everything in the build status overview is still open.

**Next session should:**
- Begin with Phase 1 foundation work — the database schema rebuild (section 2 of master plan). Drop the brittle role check constraint on the users table. Set up the new tables: roles, permissions, role_permissions, role_settings, stores, user_stores, user_businesses, invite_codes, activity_logs.
