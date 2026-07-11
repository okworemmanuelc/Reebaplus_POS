# Staff offboarding detaches identity, preserves attribution, reuses the wipe-gate

**Status:** accepted (2026-07-11)

The app can *suspend* a staff member (`user_businesses.status = 'suspended'`, a
reversible block) but has no way to **remove** one. The gap has three faces: a
staffer can't resign or delete their own account; an admin can't turn a
suspension into a permanent removal; and — because invariant #9 binds an email
to a business for as long as a `public.users` row carries that identity's
`auth_user_id` — a departed staffer's email stays trapped, unable to create a
new business. The ask is to close all three while keeping every past
transaction that person recorded correctly attributed.

The defining constraints are three existing invariants. #9 (one email = one
identity = one business) is enforced server-side by `complete_onboarding`
(migration 0121) keying **solely** on `public.users.auth_user_id = auth.uid()`.
Attribution runs through `users.id`: every `performed_by` / `recorded_by` /
`staff_id` / `initiated_by` / `approved_by` FK references it. And #12 (the
outbox is sacred) forbids destroying un-pushed local writes silently. A prior
lesson also bounds the design space: `delete_business` **cannot** delete the
`auth.users` login row on managed Supabase (ADR context / migration 0125), so
no design may depend on deleting it.

Decisions locked (grilled 2026-07-11):

- **Offboard is a new terminal operation, distinct from Suspend and from
  `delete_business`.** Suspend stays exactly as-is — reversible, email-preserving,
  the "on leave, back next week" state. Offboard is the exit. They are two
  different verbs; admin removal does **not** require prior suspension.

- **Free the email by nulling `users.auth_user_id`, never by deleting a row.**
  Because #9 keys on `auth_user_id`, setting it NULL frees the email
  immediately. The `users` row is **retained** as an Attribution Stub so
  historical FKs keep resolving. Rejected: hard-deleting the `users` row (breaks
  every attribution FK) and deleting `auth.users` (silently fails on managed
  Supabase — 0125 — and is unnecessary, since the guard never re-checks a nulled
  identity).

- **The stub keeps its PII.** Name/email/phone stay on the stub so past sales
  read "Sold by <name>" and a re-invite to the *same* business can re-link to the
  same historical identity (find-or-create by `(business_id, email)`). Rejected:
  anonymizing to "Former staff" — the right-to-be-forgotten gain was judged
  smaller than the loss of readable history, and can be layered on later.

- **Membership becomes a soft terminal status `removed`, not a hard-delete.**
  The `user_businesses` CHECK widens to `('active','suspended','removed')` on
  both client (Drift `customConstraints`) and cloud. Consistent with the repo's
  soft-delete stance (0145 forbids hard-deletes on soft tables) and with sync.
  Existing staff lists already filter `status = 'active'`, so `removed` is simply
  another excluded state.

- **One operation, three triggers.** Resign and "delete my account" are the same
  staff-initiated Offboard (one button in the staffer's own Profile);
  admin-remove is the same operation with a different actor. The **owner is
  excluded** — an owner's only exit is `delete_business` (mirrors "the owner
  can't be suspended").

- **Cloud-authoritative RPC, sync-exempt like `delete_business`.** A
  `SECURITY DEFINER` RPC performs the null-`auth_user_id` + membership-`removed`
  atomically server-side; it is never enqueued through the outbox. The RPC
  rejects offboarding the business owner.

- **Device reaction reuses the invariant-#12 wipe-gate — nothing new invented.**
  The `SyncDao.pendingRowIds` check plus the "Resolve unsynced data"
  (export → typed-confirm → discard) flow already guards sole-user logout;
  Offboard reuses it verbatim. Self-resign runs the gate inline before detaching
  (retryable un-pushed rows ⇒ "connect and sync first"; orphans ⇒ Resolve flow;
  clean ⇒ proceed). An admin-removed **remote** device detects its own
  membership went `removed` on the next pull/realtime and runs the *same* local
  gate before wiping + logging out — so any un-pushed sale surfaces as a visible,
  exportable orphan, never silently dropped. Rejected: a server-side RLS grace
  window that keeps accepting a removed user's pushes — more complex, and the
  orphan+export path already satisfies #12.

- **Shared-till scope: remove the person, not the data.** On a device where other
  members of the same business remain, Offboard clears only that person (PIN,
  "Who's working?" card). A full local wipe happens **only** when the offboarded
  user was the sole member of that business on the device — identical to today's
  sole-user-logout rule.

- **Permissions.** Admin-remove is gated by a **new `staff.remove`** gate,
  separate from and more destructive than `staff.suspend`. Self-resign is
  **ungated** (a person may always leave). The owner-rejection lives in the RPC,
  not the gate.
