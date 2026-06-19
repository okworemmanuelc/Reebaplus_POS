# Crate + Receipt Fix — Junior-Agent Prompts (3 units)

Three small, sequential fixes. Do them **one at a time**, in order. Unit 3 is
intentionally **last** — it depends on the goods-receiving / Receive-Stock flow.

> **Investigation already done for you** (paths + current state are below). Much
> of the crate plumbing already exists — your job is mostly to *verify, wire, and
> fill the gap*, **not** rebuild. Re-confirm each claim by reading the file before
> you edit; line numbers drift.

---

## Ground rules for EVERY unit (read before each prompt)

1. **Read context first, every unit** (order from `CLAUDE.md`):
   `CONTEXT/project-overview.md` → `CONTEXT/architecture.md` →
   `CONTEXT/ui-context.md` → `CONTEXT/code-standards.md` →
   `CONTEXT/ai-workflow-rules.md` → `CONTEXT/progress-tracker.md`.
   Re-read `architecture.md` **Invariants** every unit.
2. **One unit at a time.** Don't start the next until the current passes
   `flutter analyze lib` (clean) and `flutter test` (no new failures). The user
   runs on an **Android emulator** — never propose `flutter build apk`; verify
   with `flutter run`. Do **not** run `dart format` (house style is old dartfmt,
   unenforced).
3. **Standards (hard):** `ConsumerWidget` / `ConsumerStatefulWidget`; no
   `dynamic`; no raw hex / px / fontSize — use `Theme.of(context).colorScheme.*`,
   the `AppSemanticColors` theme extension for success/danger, `context.getRSize(n)`,
   `context.getRFontSize(n)`, `AppRadius.*`; icons via `FontAwesomeIcons.*`;
   feedback via `AppNotification` (never raw `SnackBar`); money is **kobo (`int`)**,
   format with `formatCurrency` from `lib/core/utils/number_format.dart`; never
   hardcode `₦`.
4. **Architecture invariants:** offline-first (read Drift, not Supabase);
   **every cloud write goes through a DAO → `sync_queue` outbox** (call the
   existing DAOs/services, never Supabase directly from a feature); **crate /
   wallet / supplier ledgers are append-only** (corrections are new rows, never
   UPDATE/DELETE a ledger row); **permissions are data** — gate with
   `hasPermission(ref, '<key>')` and **hide, don't disable**.
5. **Verify your own output** — run `flutter analyze` and read the real diff;
   don't trust a self-report. A prior agent claimed "analyze clean" when it was
   not.
6. **After each unit:** add a dated `BUILD_LOG.md` entry and update
   `CONTEXT/progress-tracker.md` (and any other context file the unit changed).

---

## UNIT 1 — Make the receipt TOTAL colour theme-aware

**Issue:** the "TOTAL" amount on the checkout receipt is a hardcoded brand amber
and does not follow the app theme's accent colour. Make **only the total
amount** theme-aware.

**File (only one):** `lib/shared/widgets/receipt_widget.dart`

**Current state (read it):**
- Around line 76: `const primary = Color(0xFFF5A623);` — a fixed amber, reused in
  a few places.
- Around lines 350–370: the TOTAL row renders `formatCurrency(total)` with
  `color: primary`. **This is the only thing the user is asking you to change.**
- Around lines 69–73 the whole receipt is *deliberately* fixed black-on-white
  (`const bg = Colors.white; const textCol = Color(0xFF111111); ...`). **Do not
  theme the background, body text, or dividers** — leave them fixed.

**Why this is delicate (do not skip):**
- This widget is captured to an **image** via a `Screenshot` controller and
  shared with customers (`Share.shareXFiles`) from three call sites —
  `checkout_page.dart` (~1203), `orders_screen.dart` (~855),
  `customer_detail_screen.dart` (~991). The capture happens in whatever theme is
  active, on a **white** background. So the colour you pick must stay legible on
  white in **both light and dark themes**.
- There is a **separate monochrome thermal path** (`lib/features/pos/services/receipt_builder.dart`,
  ESC/POS). **Do not touch it** — colour is irrelevant on a thermal printer.

**Strategy:**
1. Introduce a local `final totalColor = Theme.of(context).colorScheme.primary;`
   inside `build`. Use it **only** at the TOTAL amount `Text`. Leave the existing
   `const primary` amber in place for the REFUNDED / RESHARED / REPRINTED badges
   (those are status markers, not "theme accent", and the user did not flag them).
2. Build, then **share/capture a receipt in BOTH light and dark mode** and
   confirm the total renders in the app accent and is still readable on white. If
   the dark-scheme primary is too pale on white, fall back to a contrast-safe
   shade (e.g. the light-scheme primary) — note the decision in `BUILD_LOG.md`.

**Done when:** `flutter analyze lib` clean; receipt total shows the theme accent;
badges + black-on-white body unchanged; thermal path untouched. BUILD_LOG entry.

---

## UNIT 2 — Unified "Record Crate Activity" sheet (received **and** returned) on both detail screens

**Goal:** in the empty-crates tab of **both** the customer and supplier detail
screens, the "record activity" entry opens a sheet where you **pick the movement
direction from a dropdown** (received / returned — i.e. both directions),
choose a **manufacturer**, and enter a **quantity**. You must be able to record a
**return with no prior receipt** (returning empties even though nothing was
"received" first).

### 2a — Supplier side is ALREADY built; verify + (cosmetic) dropdown

**File:** `lib/features/inventory/screens/supplier_detail_screen.dart`

`_showRecordCrateSheet(...)` (~line 898) already does everything: a
Received / Returned toggle (two `_crateMovementChip`s, ~line 970), a manufacturer
`AppDropdown`, a qty field, an optional deposit field, and it writes through
`ref.read(supplierCrateServiceProvider)` →
`SupplierCrateService.recordReceipt / recordReturn`
(`lib/shared/services/supplier_crate_service.dart`) →
`SupplierCrateLedgerDao.recordCrateReceiptFromSupplier / recordCrateReturnToSupplier`.
A **return needs no prior receipt** (the DAO just appends a negative ledger row).

**Task (small):**
- **Verify** it compiles and works end-to-end (record a *Returned* against a
  supplier with zero prior receipts → balance goes to a negative "credit" with no
  error; record a *Received* → positive "owed").
- **Cosmetic, to match the requested UX:** replace the two
  `_crateMovementChip`s with a single `AppDropdown<String>`
  ("Received from supplier" / "Returned to supplier") driving the same `isReturn`
  flag. Keep every existing wiring/label/validator. (If you judge the chips
  clearer, you may keep them — but the user explicitly asked for a dropdown, so
  prefer the dropdown.)

### 2b — Customer side: add the second direction (currently returns-only)

**File:** `lib/features/customers/screens/customer_detail_screen.dart`

`_showRecordCrateReturnSheet(...)` (~line 2220) only records **returns**. The
action card (~line 2087, title "Record crate return") and sheet are returns-only.

**Good news — no new DAO work:** both directions already exist on
`db.crateLedgerDao`:
- `recordCrateReturnByCustomer(...)` (daos.dart ~7199) — returned, balance **−**.
- `recordCrateIssueByCustomer(...)` (daos.dart ~7297) — issued / loaned, balance **+**.

**Task:**
1. Turn the sheet into a **"Record Crate Activity"** sheet: add an
   `AppDropdown<String>` at the top to pick the movement —
   **"Returned by customer"** (→ `recordCrateReturnByCustomer`) and
   **"Issued / loaned to customer"** (→ `recordCrateIssueByCustomer`). Keep the
   manufacturer dropdown + qty field. Update the dynamic labels/title the way the
   supplier sheet does for return vs receive.
2. Update the action card (~line 2087): title → "Record crate activity",
   subtitle → something like "Crates issued to / returned by this customer", and
   the comment block above it.
3. **Atomicity gotcha:** `recordCrateIssueByCustomer` has *"No own transaction —
   the caller is already inside one"* (daos.dart ~7291); it runs three sequential
   writes (ledger insert + balance upsert + sync enqueue). When you call it
   standalone from the UI, **wrap the call in `db.transaction(() async { ... })`**
   so it's atomic — mirror how `recordCrateReturnByCustomer` self-transactions.
4. **Permission:** keep the existing `sales.make` gate (`canRecord`, ~line 2055)
   for **both** directions — hide the card if absent.
5. **Stock side-effect — investigate, don't invent:** `recordCrateIssueByCustomer`
   does **not** move physical empty stock (verified — it only touches the ledger +
   `customer_crate_balances`). This matches the checkout issue path
   (`OrdersDao.createOrder`). So the manual "issued" path should **also not** move
   stock. If you find the *return* submit handler (~line 2343) separately adjusts
   empty stock, do **not** add a mirror decrement for issue without flagging it —
   note any asymmetry in `BUILD_LOG.md` for the user to confirm.

**Standards for both sheets:** `AppDropdown` / `AppInput` / `AppButton`, design
tokens, `AppNotification` on success/failure, kobo for any deposit, digits-only
qty validator (`> 0`).

**Cloud/sync check (both 2a & 2b):** the supplier crate tables ship in migration
`supabase/migrations/0117_supplier_crate_tracking.sql`. Confirm it is **deployed**
(`supabase db push` is pre-authorized) and that `supplier_crate_ledger` /
`supplier_crate_balances` are registered at **every** per-table apply site in
`lib/core/services/supabase_sync_service.dart` (pull RPC, `_restoreTableData`,
hard-delete) — otherwise other devices silently drop the rows. The customer crate
tables (`crate_ledger`, `customer_crate_balances`) are already wired.

**Done when:** `flutter analyze lib` clean; `flutter test test/crates test/suppliers`
green; manual check — customer *issue* raises the owed balance, customer *return*
lowers it / makes a credit; supplier *received* raises owed, *returned* lowers it
with no prior receipt; sync rows enqueue. BUILD_LOG + progress-tracker updated.

---

## UNIT 3 — (LAST) Auto-record empties RETURNED to the supplier during goods-receiving / delivery

**Do this only after Units 1–2 and after the Receive-Stock flow exists.** This
closes the loop: when a delivery arrives you usually hand the driver the empties
back at the same time — that return should be recorded automatically, not as a
separate manual entry.

**Current state (read it):**
- `lib/features/deliveries/widgets/receive_delivery_sheet.dart` `_submit` (~line
  143) already auto-records the **receipt** half: for each
  `unit == 'bottle' && trackEmpties` line it calls
  `db.supplierCrateLedgerDao.recordCrateReceiptFromSupplier(...)` (~line 227) —
  full crates in → we owe the supplier more empties. It does **not** capture the
  empties handed **back**.
- The new **Receive-Stock** feature (`RECEIVE_STOCK_AGENT_PROMPTS.md`) already
  specs this exact extra requirement (the highlighted "empty crates returned to
  supplier" block). **Coordinate** — implement it in whichever receiving flow is
  the live one, and make sure the two flows don't double-record.

**Task:**
1. On the receiving screen, for **each line where `unit == 'bottle' &&
   trackEmpties == true`**, add an **optional** numeric field: *"Empty crates
   returned to supplier"*.
2. On confirm, for each such line with a value `> 0`, call
   `recordCrateReturnToSupplier(...)` /
   `ref.read(supplierCrateServiceProvider).recordReturn(...)` — **reduces** what
   we owe — **in addition to** the existing `recordCrateReceiptFromSupplier`
   call. Use `line.selectedProduct!.manufacturerId` and the same `storeId` /
   `staffId` the receipt path uses.
3. **Skip zero:** do not write a ledger row when the field is empty or `0` (the
   DAO throws on `quantity <= 0`).
4. Deposit refund on the return is **out of scope** — the user only asked for the
   empties count. Keep it to the count.

**Done when:** `flutter analyze` clean, `flutter test` green; a receive-delivery
with "empties returned" > 0 drops the supplier's owed balance by that amount while
the receipt half still raises it; lines without the field are unaffected; no
double-recording with the Receive-Stock flow. BUILD_LOG + progress-tracker
updated.
