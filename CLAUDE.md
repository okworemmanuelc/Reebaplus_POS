Behavioral guidelines to reduce common LLM coding
mistakes. Merge with project-specific instructions
as needed.

Tradeoff: These guidelines bias toward caution
over speed. For trivial tasks, use judgment.

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
- No “flexibility” that wasn't requested.
- No error handling for impossible scenarios.
- If 200 lines could be 50, rewrite it.

## 3. Surgical Changes
Touch only what you must. Clean up only your own mess.

- Don't “improve” adjacent code or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice dead code, mention it — don't delete it.

## 4. Goal-Driven Execution
Define success criteria. Loop until verified.

Transform tasks into verifiable goals:
- “Add validation” → “Write tests, then make them pass”
- “Fix the bug” → “Reproduce it in a test, then fix”
- “Refactor X” → “Ensure tests pass before and after”

## 5. Sync invariants

Every write to a synced table (anything in `_syncedTenantTables` in
[lib/core/database/app_database.dart](lib/core/database/app_database.dart))
must reach the cloud. The contract is:

- All writes go through a DAO method that calls `enqueueUpsert` /
  `enqueueDelete` on `SyncDao` (or enqueues a `domain:<rpc>` envelope
  for atomic multi-table actions). Writes via `db.into(...)`,
  `db.update(...)`, `db.delete(...)` *outside* a DAO are leaks — the
  cloud never sees them.
- Two legitimate exceptions, both narrow:
  1. `_restoreTableData` in `supabase_sync_service.dart` (incoming pull
     and realtime).
  2. `_applyDomainResponse` in `supabase_sync_service.dart` (server's
     authoritative response after a domain RPC succeeds — the server
     already has the truth; pushing it back would be a no-op round
     trip).
- Soft-delete (`is_deleted=true`) goes through `enqueueUpsert`. Only
  use `enqueueDelete` for hard tombstones the cloud needs to forget;
  it also clears any pending upsert for the same row.
- Domain envelopes (`domain:pos_record_sale`, `domain:pos_inventory_delta`,
  `domain:pos_create_product`) skip enqueue-time coalescing — each is an
  independent atomic transaction. Their payloads sit at `$.p_<arg>` and
  are dispatched via `_pushDomainItems`, not the per-table batched upsert
  path.
- Stream providers for synced tables live in
  [lib/core/providers/stream_providers.dart](lib/core/providers/stream_providers.dart).
  When a screen reads a synced table, prefer the existing provider over a
  one-shot `db.select(...).get()` so realtime events propagate without a
  manual refresh.

## 6. Cautious with Dependencies
