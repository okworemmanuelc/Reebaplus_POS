# The cloud accepts one reversal per Order: claim, then release

**Status: accepted** (#550, PRD #337 slice d, stories 52a–52c, 2026-10-26).

Two phones that both reverse the same sale while offline used to upload both
sets of compensating stock, payment and wallet rows, because the v1 Cancel
enqueues them one table at a time and the order header is last-writer-wins. The
local "already cancelled" check only sees one phone's data.

## Decision

Every local reversal of an Order goes through one seam in `OrdersDao`:
`beginGuardedReversal()` → write and enqueue the reversal's rows as usual →
`commitGuardedReversal(...)`, all in one transaction. Commit enqueues a
`domain:pos_claim_order_reversal` envelope carrying a fresh reversal id and
**holds** every outbox row enqueued since begin, keyed by that id (the #121
`held_by_order_id` column, reused; no Drift change).

The cloud RPC `pos_claim_order_reversal` (migration 0227) locks the order and
checks the cloud-only `order_reversals` marker (UNIQUE `order_id`):

- **No claim yet:** it inserts the marker and flips the header to `cancelled`
  in the same transaction. The drain then releases the held rows, which upload
  as ordinary rows (the existing `created_at` scrub keeps retries legal).
- **Same reversal id:** a replay (`{replayed: true}`), so the winner's retry is
  idempotent.
- **A different claim, or the order was already reversed without one** (an
  older build or the flag-held v2 `pos_cancel_order`, detected by the order
  being `cancelled` with a `return` stock row or `refund` payment): it raises
  P0001 `reversal_already_applied` with the cloud header in DETAIL.

The losing phone, before the claim moves to `sync_queue_orphans`, runs
`OrdersDao.undoRejectedReversal`. It removes the held rows' local copies (stock
return rows with their inventory, payment, wallet, crate and cost-layer rows),
writes the cloud header, and discards the held outbox rows. That is the
sanctioned server-rejection path under Invariant #12, because none of them ever
uploaded. It then alerts the CEO and the Managers of the order's store
(`sale_refund_rejected`, warning, linked to the order). The claim stays in Sync
Issues. Append-only local ledgers allow this only through
`AppDatabase.withdrawUnsyncedRows`, which drops and recreates the table's
delete guards inside one transaction.

A trigger on `orders` makes a claimed order's cancellation sticky (status,
`cancelled_at` and reason are forced to the claim's), and a `cancelled` order
can't be flipped back by a late header push (for example phone B's Confirm).

## Why not an all-rows RPC

An RPC that inserts every reversal row atomically would be truer to "one unit",
but it would re-implement the push path's per-table whitelists, `created_at`
scrubs and LWW cache upserts server-side, for six tables. Claim-then-release
keeps the existing push path and gives the same guarantee for the loser: none of
its rows land. The winner's rows still upload per table after the claim, as
every v1 write does.

## Consequences

- `reconcileHeldRows` keeps a reversal's rows held while its claim is queued or
  orphaned for any other reason (the user retries it from Sync Issues). It
  releases them only when the claim is gone from both tables (confirmed).
- An inventory row whose upsert coalesced into an already-pending entry (so it
  was not held) is re-enqueued with the corrected quantity after an undo.
- Older builds still push reversals unguarded. The Return (#551) ships only in
  builds that carry this seam, and 0227 must be on production first.
- Enabling `feature.domain_rpcs_v2.cancel_order` stays gated as before. Its
  "already cancelled → replay" check already makes it a no-op on a claimed
  order.
- Edge: if a later sale drew from a restored cost layer before the undo, that
  layer is still removed. The server recost re-derives COGS.
