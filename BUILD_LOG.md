# Build Log

---

## 2026-06-16 — Session 148: Owner role protection

**Files changed:**
- `lib/core/database/app_database.dart` — added `ownerId` nullable TEXT column
  to `Businesses` table; schema v49 → v50; `from < 50` migration adds the column
  with try/catch for idempotency.
- `lib/shared/services/auth_service.dart` — `createNewOwner` and
  `completeOnboarding` both set `ownerId: Value(authUserId)` in the local Drift
  business insert so new and onboarding owners have the field populated before
  the first cloud pull.
- `lib/features/staff/screens/staff_detail_screen.dart` — render-gate hides
  "Change role" button when `isTargetOwner` (target's `authUserId` matches
  `business.ownerId`); outer action section guard updated to avoid orphan
  spacer; `_changeRole` re-checks the owner condition at the write boundary and
  shows error "You cannot change the owner's role." on bypass.
- `lib/core/database/app_database.g.dart` — regenerated via `build_runner`.

**Verification:** `flutter analyze` on all three source files → No errors.
The `ownerId` field appears in `BusinessData`, `BusinessesCompanion`, and the
`$BusinessesTable` column list in the generated file.

**Sync notes:** `owner_id` is already in `_pushableColumns['businesses']` and
`_restoreTableData` uses `BusinessData.fromJson(r)` for cloud pulls — the new
column is picked up automatically on the next pull for existing businesses.
Existing local rows get `ownerId = null` after migration and are backfilled from
the cloud on the next sync.
