# Ubiquitous Language

Canonical vocabulary used across the codebase. When in doubt about a
term, this file is the source of truth.

## Roles and tiers (v9, current)

Five canonical roles. The `role` string is the human-readable identifier;
the `role_tier` integer is what permission gates compare against.

| Role          | `role` value     | `role_tier` |
|---------------|------------------|-------------|
| CEO           | `ceo`            | 6           |
| Manager       | `manager`        | 5           |
| Stock Keeper  | `stock_keeper`   | 4           |
| Cashier       | `cashier`        | 3           |
| Rider         | `rider`          | 2           |

Constraints (cloud + Drift) reject anything outside `role IN
('ceo','manager','stock_keeper','cashier','rider')` and `role_tier IN
(2,3,4,5,6)`. Both sets are enforced in:

- Cloud: `supabase/migrations/0030_role_vocabulary_expansion.sql`
  (rewrites the CHECK constraints on `profiles`, `users`,
  `business_members`, `invites`)
- Drift: `customConstraints` on `Users`, `BusinessMembers`, and
  `Invites` in [lib/core/database/app_database.dart](lib/core/database/app_database.dart)

Drift `roleTier` column default is `3` (cashier) — the "lowest general
employee" tier, mirroring the v8-era default of `1` (staff).

## Removed / renamed terms

| Old term  | New term       | Notes |
|-----------|----------------|-------|
| `admin`   | `ceo`          | All v8 admins migrate up to CEO in 0030. |
| `staff`   | `cashier`      | "Staff" was a misnomer — everyone in the app is staff in the general sense. |
| `cleaner` | _(dropped)_    | Was in the UI picker but never landed in the schema. Edge-fn `VALID_GRANULAR_ROLES` no longer accepts it. |

Stock Keeper and Rider existed in the UI picker pre-v9 but were not in
the DB schema. v9 promotes both to first-class roles.

## Invite permission rules

Who may invite whom:

| Inviter       | May invite                                  |
|---------------|---------------------------------------------|
| CEO           | manager, stock_keeper, cashier, rider       |
| Manager       | stock_keeper, cashier, rider                |
| Stock Keeper  | _(none)_                                    |
| Cashier       | _(none)_                                    |
| Rider         | _(none)_                                    |

Enforced at three layers:

1. UI: `RoleGuard(minTier: 5)` on the Add-Staff FAB
   ([staff_screen.dart](lib/features/staff/screens/staff_screen.dart))
   hides the entry point for anyone below manager.
2. Modal: `_initInviteRoles` in
   [invite_modal.dart](lib/features/invite/widgets/invite_modal.dart)
   filters the role dropdown by inviter role at `initState` and
   renders a "no permission" card when `_canInvite` is false.
3. Server: `send-invite`, `revoke-invite`, `check-invite-email` edge
   functions reject `caller_tier < 5`.

## Gate vocabulary cheat-sheet

Read tier comparisons as ranges, not equalities. The conventions in
this codebase:

| Gate expression       | Semantic meaning                       |
|-----------------------|----------------------------------------|
| `roleTier >= 6`       | CEO only (owner-level config).         |
| `roleTier >= 5`       | Manager and above (default management gate). |
| `roleTier >= 4`       | _Reserved._ Future stock-approval gates (crate returns, stock transfers, etc.). No retrofits — stock keepers do NOT inherit manager-level reads. |
| `roleTier >= 3`       | Cashier and above (any in-store employee with a PIN). |
| `roleTier >= 2`       | Any authenticated user. |
| `roleTier < N`        | Inverse — typically "lock this user to their own warehouse" or "show the locked variant of this card". |

Prefer `RoleGuard(minTier: N)` over inline `if (tier >= N)` for any
permission gate that controls a widget's presence. Inline tier
comparisons remain appropriate for *data scoping* (e.g., "below
manager: filter to own warehouse"), where the value branches data
rather than UI visibility.

[RoleGuard](lib/shared/widgets/role_guard.dart) reads
`authProvider.currentUser.roleTier`, falls closed on
`currentUser == null` (treats it as tier 0), and re-evaluates on every
auth-state tick.
