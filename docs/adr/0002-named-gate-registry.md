# Permission enforcement at action initiation via a named-gate registry

**Status:** accepted (2026-07-02)

The three-layer permission gate (render-gate / body-guard / write-boundary
re-check) was hand-typed at ~89 `hasPermission` sites across feature and
settings files; a forgotten layer or a drifted expression was the documented
recurring leak (the Session 81 audit fixed nine, one at a time). We introduce a
**Gate Registry** — every gated action declared once, by name, as a `Gate`
(a small predicate algebra over permission keys and role tier) — plus a
`Guarded` widget that carries all three layers: it render-gates its child,
offers a screen variant for body-guards, and hands the child its action
callback only through an `allow` wrapper that re-checks the live permission
set at fire time. An imperative `gate.require(ref)` (throws `GateDeniedError`)
guards the top of multi-step flows. Call sites cite names (`Gates.receiveStock`);
they never re-derive the rule.

## Considered Options

- **Inline predicate algebra composed at call sites** — rejected: keeps every
  gate expression duplicated across its FAB, its route guard, and its write
  path (today that equivalence is maintained by code comments), and does
  nothing about the wrong-key/drifted-expression bugs that dominated the
  Session 81 leak list.
- **Capability tokens threaded into domain write signatures** (the literal
  "skip a layer and it can't compile") — rejected *for now*: DAOs must stay
  permission-free (see boundary decisions), so tokens would force a
  `Grant.system()` backdoor onto every sync path while guaranteeing nothing.
  Recorded as the intended upgrade once the sale-completion module
  (architecture-review candidate #5) gives user-initiated writes a single seam
  tokens can be threaded through.

## Key boundary decisions

- **DAOs and services are deliberately permission-free.** The sync pull/restore
  path writes rows authored by *other* users, and approved stock adjustments
  apply through the same `adjustStock` the manager flow uses — persistence-layer
  permission checks are wrong by architecture. Enforcement lives at action
  initiation (UI event → domain call). Don't "fix" this by adding checks to DAOs.
- **Denied is never silent.** The `allow` wrapper shows one standard denial
  feedback built from the gate's registry message; an *uncaught*
  `GateDeniedError` lands in the §33 global net → `error_logs`, so a missed
  enforcement layer becomes visible telemetry instead of a silent leak.
- **Role-tier atoms are first-class but convention-bound.** `Gate.tierAtLeast` /
  `Gate.ceo` exist so composite legacy gates (e.g. home-screen
  `isCeo || (isManager && key)` and §19.3 money-visibility, which is
  deliberately tier-based and fails closed) migrate verbatim. Permission keys
  remain the canonical axis (invariant #6); new tier-based gates are a review
  flag, and the registry makes every tier dependence visible in one file.
- **Behaviour-neutral lift.** Migration moves each existing expression into a
  named gate *exactly as written* — no key-ification, no dependency-cascade
  resolution (the "no runtime effective-resolution" rule stands).
  `sales.discount.give` gets **no** registry entry: it is defined-but-unenforced,
  so an entry would be either dead or an unintended behaviour change.
- **Two render forms encode the flash policy** already documented on
  `currentUserPermissionsReadyProvider`: inline `Guarded` hides while loading
  or denied (hide-don't-disable, hard rule #7); `Guarded.screen` waits for
  permission readiness before rendering the standard no-access scaffold, so
  full-screen denials can't flash during grant resolution.
- **The finish line is enforced, not aspirational.** A static test bans
  `hasPermission(` outside `lib/core/permissions/`; once migration completes,
  the bare helper goes private. Until then the ban carries a shrinking
  allowlist.

## Consequences

- One gated action = one name; the FAB, the body-guard, and the write boundary
  cite the same registry entry, so inter-layer drift becomes impossible rather
  than comment-enforced.
- Gate evaluation is a pure function of (permission set, role), unit-testable
  against `resolveEffectivePermissions` fixtures — tests hit the module, not
  ~89 pumped widgets.
- The migration lift doubles as a one-time, permanent Session-81-style audit:
  every gate expression in the app gets read, named, and inventoried once.
- Write-boundary enforcement is runtime, not compile-time, until candidate #5
  lands — accepted trade-off, revisit then.
