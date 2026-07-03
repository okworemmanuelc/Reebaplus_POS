# Business-scoped stream providers via a guarded factory

**Status:** accepted (2026-07-03)

A `StreamProvider` that calls a `BusinessScopedDao` `watch*()` bakes the
businessId into its Drift query once, at first build, via `requireBusinessId()`
— which **throws** when no business is bound. Because such a provider's only
dependency is the never-changing `databaseProvider`, a first subscribe during
the brief null-businessId window (the create-business handoff, where
`setCurrentUser` binds the id only after the post-onboarding pull) errors and
**sticks for the whole session**: every store picker renders empty until a cold
restart. A quieter sibling reads `db.currentBusinessId` synchronously and
**silent-empty-sticks** the same way. Both were hand-patched one provider at a
time (S153, `allStoresProvider`). We introduce **`businessScopedStream<T>`**
(and **`businessScopedStreamFamily<T, Arg>`**) — a factory that *owns the
provider declaration*: it watches **`currentBusinessIdProvider`**, emits a
required `whenAbsent` value while the id is null, and passes the resolved
**non-null** businessId into the closure. The bug is therefore unrepresentable
in any provider declared through the factory, and a static ban test keeps new
providers on it. The migration surface is ~41 declarations in two provider
files; consumers (`ref.watch(xProvider)`) are untouched.

## Considered Options

- **A body helper called inside `StreamProvider((ref) => …)`** — rejected: it is
  the S153 hand-patch under a nicer name. A future provider can still skip it,
  which re-opens the exact defect we are retiring. Only owning the *declaration*
  delivers "by construction."
- **Per-provider inline guards (status quo)** — rejected: this is the documented
  recurring bug; every new tenant-scoped provider re-opens it, and the
  throw-poison / silent-empty split means half the failures are invisible.
- **A `custom_lint` AST rule** — rejected *for now*: it could tell scoped from
  global streams precisely, but there is no `custom_lint` infra in the repo. A
  source-scan test matches three existing precedents (the gate ban, the
  sync-registry membership test, the sync-registry golden test) and needs no new
  toolchain.
- **Emit `AsyncLoading` while unbound instead of a `whenAbsent` value** —
  rejected as the default: it is a behaviour change (an empty-`[]` flash becomes
  a spinner) and would leave the app-wide currency provider in loading, breaking
  the root currency watch that needs a concrete `kDefaultCurrency` before a
  business binds. Left available as a future opt-in (omit `whenAbsent`).

## Key boundary decisions

- **The closure receives the resolved, non-null businessId.** So
  `requireBusinessId()` can never throw from a factory-built provider, and
  custom-SQL providers (`WHERE business_id = ?`) migrate too — the primitive
  subsumes **both** the throw-poison and the silent-empty families, not just the
  DAO-watch ones.
- **`whenAbsent` is required, never inferred.** The null-window value genuinely
  varies across sites (`[]`, `{}`, `0`, `null`, `kDefaultCurrency`), so there is
  no default to guess. Requiring it forces a conscious choice and keeps the
  migration a behaviour-preserving 1:1 lift.
- **`currentBusinessIdProvider` is the single watchable businessId seam**
  (`= authProvider.select((a) => a.currentUser?.businessId)`); nothing else
  re-derives it. It makes the factory unit-testable by `overrideWith` (flip
  `null → id`, assert `whenAbsent → data`) rather than by faking `AuthService`.
  Non-reactive `db.currentBusinessId` reads are the anti-pattern it replaces.
- **Rebuild-on-switch falls out of watching the seam.** Every factory-built
  provider re-runs for the new tenant on a business switch, pre-solving a
  Phase-2 switcher staleness concern (business-isolation root cause) without
  touching the deliberately-deferred *eviction* decision.
- **Global / unscoped streams stay off the factory.** `permissionsDao.watchAll`
  (the never-synced global catalogue) and `rolesDao.watchAllUnscoped` are not
  tenant-scoped. Unlike the gate ban's empty allowlist, this ban's allowlist is
  **small but non-empty** — it names these globals — with the same shrink-only
  ratchet.
- **Family gets a second factory, not a hand-written carve-out.** Riverpod won't
  let one function emit both plain and family providers, so the `.family` cases
  get `businessScopedStreamFamily`. Leaving them hand-written would re-open the
  hole for the next family provider someone adds; two guarded front doors keep
  the invariant total.

## Consequences

- One gated read path: no business-scoped stream — plain or family — can be
  declared without watching the id and guarding the null window, so the
  build-time-poison class becomes impossible rather than audited.
- The factory is a pure, isolated unit test (flip `currentBusinessIdProvider`,
  assert the emission), instead of the current per-provider integration checks.
- Staged in two independently-grabbable issues: (1) the factories +
  `currentBusinessIdProvider` + tests + a ban test whose allowlist temporarily
  names every current raw provider (CI green); (2) the mechanical migration of
  ~41 sites, shrinking the allowlist to just the globals, plus the companion
  "planted violation is caught / migrated form is not flagged" strictness test.
- The `whenAbsent`-vs-`AsyncLoading` behaviour choice is deferred, not decided:
  revisit if a provider genuinely wants a loading state during the null window.
