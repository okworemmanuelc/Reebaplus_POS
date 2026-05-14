# Sync Push Diagnostic — Findings

> Fill this in after running the diagnostics in [rls_snapshot.md](rls_snapshot.md)
> and the in-app **Sync Issues** screen against the live system.

## 1. RLS approach per table

Confirmed 2026-04-27 from [rls_snapshot.md](rls_snapshot.md): every tenant
table routes through `get_user_business_id()`, which is

```sql
SELECT business_id FROM profiles WHERE id = auth.uid();
```

i.e. a pure `auth.uid()` → `profiles` join. **JWT claims play no role.**
Coverage is complete (SELECT/INSERT/UPDATE/DELETE present on every tenant
table). Specials: `businesses` allows anyone to INSERT (onboarding);
`profiles` is keyed on `auth.uid() = id`.

**Implication:** silent insert failures reduce to "the affected user has
no `profiles` row, or that row's `business_id` is NULL". Confirm with the
two probes in [rls_snapshot.md](rls_snapshot.md#probes-run-while-signed-in-as-the-affected-user).

## 2. JWT `business_id` claim

Not used by RLS — see §1. The in-app decoder is informational only.

## 3. Per-table row counts

(From the Sync Issues → Row-count audit panel. Diagnosis column in the app.)

| Table | Local | Authed | Service | Diagnosis |
|---|---|---|---|---|
| customers |  |  |  |  |
| orders |  |  |  |  |
| products |  |  |  |  |
| inventory |  |  |  |  |
| expenses |  |  |  |  |
| warehouses |  |  |  |  |
| customer_wallets |  |  |  |  |

## 4. Top error patterns from the failed queue

(From Sync Issues → Failed items, classifier label.)

- `RLS rejection`: count, example payload, suspected policy
- `Missing business_id`: count, which local writer enqueued without it
- `Duplicate key`: count, ID-collision area
- `FK violation`: count, parent table that wasn't pushed first
- `Network`: count

## 5. Recommended remediation

- Server-side (RLS / auth hook): …
- App-side (writer that enqueues without business_id, FK ordering, etc.): …
- Operational (re-push from Sync Issues vs. clear queue): …
