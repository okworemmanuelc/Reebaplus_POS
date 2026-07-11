part of 'daos.dart';

@DriftAccessor(tables: [SyncQueue, SyncQueueOrphans])
class SyncDao extends DatabaseAccessor<AppDatabase>
    with _$SyncDaoMixin, BusinessScopedDao<AppDatabase> {
  SyncDao(super.db);

  Future<List<SyncQueueData>> getPendingItems({
    int limit = 50,
    String? businessId,
  }) {
    // §6.8: rows scheduled for future retry (markFailed sets
    // nextAttemptAt for both regular transient and FK-deferred classes)
    // must be skipped until their window opens. Without this clause the
    // exponential backoff and FK-deferred logic in markFailed are
    // effectively no-ops — every push pass would retry every failed row
    // immediately, hammering the cloud and eating attempts.
    //
    // [businessId] lets callers (push side, sync issues screen) pin the
    // tenant filter explicitly instead of consulting the resolver. Mirrors
    // the bootstrap pattern in [enqueueUpsert] and stays safe across the
    // pre-setCurrentUser window where the resolver returns null.
    final now = DateTime.now();
    final tenantFilter = businessId != null
        ? syncQueue.businessId.equals(businessId)
        : whereBusiness(syncQueue);
    final query = select(syncQueue)
      ..where(
        (t) =>
            t.isSynced.not() &
            t.status.equals('pending') &
            tenantFilter &
            // Oversell recovery: a HELD child row (of an unconfirmed v2 sale)
            // is invisible to the drain until its envelope confirms (release)
            // or is rejected (discard) — so a rejected sale never leaks its
            // cost/crate/wallet rows to the cloud.
            t.heldByOrderId.isNull() &
            (t.nextAttemptAt.isNull() |
                t.nextAttemptAt.isSmallerOrEqualValue(now)),
      )
      ..orderBy([
        (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.asc),
      ])
      ..limit(limit);

    return query.get();
  }

  /// All `sync_queue` row ids for [businessId] (any status). Used by
  /// `createOrder`'s v2 hold path to compute exactly which rows a sale just
  /// enqueued (the set difference before/after the child writes), so they can be
  /// held without threading an order id through every child DAO.
  Future<Set<String>> queueRowIds(String businessId) async {
    final rows = await (selectOnly(syncQueue)
          ..addColumns([syncQueue.id])
          ..where(syncQueue.businessId.equals(businessId)))
        .map((r) => r.read(syncQueue.id)!)
        .get();
    return rows.toSet();
  }

  /// Oversell recovery — mark a set of just-enqueued child rows as HELD by
  /// [orderId] (a v2 sale's cost/crate/wallet rows). Held rows are skipped by
  /// [getPendingItems] until [releaseHeldByOrder] (envelope confirmed) or
  /// [discardHeldByOrder] (envelope rejected). No-op on an empty set.
  Future<void> holdRowsByOrder(List<String> queueIds, String orderId) async {
    if (queueIds.isEmpty) return;
    await (update(syncQueue)..where((t) => t.id.isIn(queueIds))).write(
      SyncQueueCompanion(heldByOrderId: Value(orderId)),
    );
  }

  /// Release the rows held for [orderId] back into the drain — the sale's
  /// `pos_record_sale_v2` envelope CONFIRMED, so its child rows may now push
  /// (the cloud order they reference exists).
  Future<void> releaseHeldByOrder(String orderId) async {
    await (update(syncQueue)..where((t) => t.heldByOrderId.equals(orderId)))
        .write(const SyncQueueCompanion(heldByOrderId: Value(null)));
  }

  /// Discard the rows held for [orderId] — the sale was permanently REJECTED
  /// (oversell), so the cloud has (and will have) no such order; its held child
  /// rows must never push. A deliberate consequence of a rejected sale, so this
  /// removal is sanctioned under Invariant #12 (not a silent destruction: the
  /// rejected envelope itself is visible in `sync_queue_orphans`). Returns the
  /// number of rows discarded.
  Future<int> discardHeldByOrder(String orderId) {
    return (delete(syncQueue)..where((t) => t.heldByOrderId.equals(orderId)))
        .go();
  }

  /// Crash-safe reconciliation of HELD child rows (oversell recovery). For every
  /// order that still has held rows, decide their fate from durable state — so a
  /// crash between an envelope resolving and its release/discard can never
  /// strand rows (silently un-pushed → Invariant #12):
  ///   • the `pos_record_sale_v2` envelope is still in `sync_queue` (any status)
  ///     → keep held (the sale hasn't resolved yet);
  ///   • the envelope sits in `sync_queue_orphans` (REJECTED) → discard;
  ///   • the envelope is gone from both (CONFIRMED — pushed + markDone) → release.
  /// Runs at sign-in, on the periodic tick, and right after the domain drain.
  /// Returns (released, discarded) order counts.
  Future<({int released, int discarded})> reconcileHeldRows(
    String businessId,
  ) async {
    final heldOrders = await customSelect(
      'SELECT DISTINCT held_by_order_id AS oid FROM sync_queue '
      'WHERE held_by_order_id IS NOT NULL AND business_id = ?1',
      variables: [Variable.withString(businessId)],
    ).get();
    var released = 0;
    var discarded = 0;
    for (final row in heldOrders) {
      final orderId = row.read<String>('oid');
      final envelopePending = await customSelect(
        "SELECT 1 FROM sync_queue "
        "WHERE action_type = 'domain:pos_record_sale_v2' "
        "AND json_extract(payload, '\$.p_order_id') = ?1 LIMIT 1",
        variables: [Variable.withString(orderId)],
      ).get();
      if (envelopePending.isNotEmpty) continue; // still in flight
      final envelopeOrphaned = await customSelect(
        "SELECT 1 FROM sync_queue_orphans "
        "WHERE action_type = 'domain:pos_record_sale_v2' "
        "AND json_extract(payload, '\$.p_order_id') = ?1 LIMIT 1",
        variables: [Variable.withString(orderId)],
      ).get();
      if (envelopeOrphaned.isNotEmpty) {
        discarded += await discardHeldByOrder(orderId);
      } else {
        await releaseHeldByOrder(orderId);
        released++;
      }
    }
    return (released: released, discarded: discarded);
  }

  Future<void> markInProgress(String id) async {
    await (update(syncQueue)..where((t) => t.id.equals(id))).write(
      const SyncQueueCompanion(status: Value('syncing')),
    );
  }

  /// Bulk variant for batched push: flips a set of queue rows to 'syncing'
  /// in one statement. Empty input is a no-op.
  Future<void> markInProgressBatch(List<String> ids) async {
    if (ids.isEmpty) return;
    await (update(syncQueue)..where((t) => t.id.isIn(ids))).write(
      const SyncQueueCompanion(status: Value('syncing')),
    );
  }

  Future<void> markDone(String id) async {
    await (update(syncQueue)..where((t) => t.id.equals(id))).write(
      const SyncQueueCompanion(
        isSynced: Value(true),
        status: Value('completed'),
        nextAttemptAt: Value(null),
      ),
    );
  }

  /// Bulk variant for batched push: marks a set of queue rows completed in
  /// one statement. Empty input is a no-op.
  Future<void> markDoneBatch(List<String> ids) async {
    if (ids.isEmpty) return;
    await (update(syncQueue)..where((t) => t.id.isIn(ids))).write(
      const SyncQueueCompanion(
        isSynced: Value(true),
        status: Value('completed'),
        nextAttemptAt: Value(null),
      ),
    );
  }

  /// Number of FK-deferred (23503) retries before a row is promoted to
  /// permanent. After this cap the parent is presumed genuinely absent
  /// (not just lagging) and the row goes to orphans for operator review.
  static const _fkDeferredRetryCap = 3;

  Future<void> markFailed(
    String id,
    String error, {
    bool permanent = false,
    bool fkDeferred = false,
  }) async {
    final now = DateTime.now();
    final existing = await (select(
      syncQueue,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (existing == null) return;
    final attempts = existing.attempts + 1;

    // FK-deferred class (PostgreSQL 23503). Parent likely arrives on
    // the next pull, so wait longer between retries; promote to
    // permanent after the cap so a genuinely orphaned child doesn't
    // ride the queue forever.
    final deferredOverflow = fkDeferred && attempts >= _fkDeferredRetryCap;
    final shouldPersistAsPermanent = permanent || deferredOverflow;

    if (shouldPersistAsPermanent) {
      // §6.8 orphan auto-move: lift the row out of sync_queue, archive
      // to sync_queue_orphans (with the original id preserved), and
      // delete the queue row so it stops counting against pending
      // metrics. Operator-visible surface for genuine permanent
      // failures.
      final reason = deferredOverflow
          ? 'fk_deferred_cap_reached: $error'
          : error;
      debugPrint(
        '[SyncDao] orphan ${existing.actionType} attempts=$attempts '
        'reason=$reason',
      );
      await transaction(() async {
        await into(syncQueueOrphans).insert(
          SyncQueueOrphansCompanion.insert(
            originalId: existing.id,
            actionType: existing.actionType,
            payload: existing.payload,
            reason: reason,
            // Carry the queue row's auto-retry count forward (§6.8.1) so the
            // automatic-recovery cap holds across re-orphan cycles instead of
            // resetting to 0 every time a recovered row fails again.
            autoRetryCount: Value(existing.autoRetryCount),
          ),
        );
        await (delete(syncQueue)..where((t) => t.id.equals(id))).go();
      });
      return;
    }

    // Transient retry. FK-deferred uses a 10-minute base so the next
    // pull (typical cadence: minutes) lands in between attempts;
    // regular transients keep the original 30-second base. The delay is
    // capped at a ceiling (§6.8: 5 min normal / 15 min FK-deferred) so a row
    // that has failed many times can't drift hours into the future — the
    // 1<<(attempts%10) growth otherwise reaches ~4 h before wrapping, leaving
    // a row stuck long after a continuously-online device's transient cause
    // (cloud blip, lagging parent) has cleared.
    final base = fkDeferred ? 600 : 30;
    final ceilingSeconds = fkDeferred ? 900 : 300;
    final rawSeconds = (1 << (attempts % 10)) * base;
    final delay = Duration(seconds: math.min(rawSeconds, ceilingSeconds));
    final next = now.add(delay);

    debugPrint(
      '[SyncDao] retry ${existing.actionType} attempts=$attempts '
      'next=${next.toIso8601String()}',
    );

    await (update(syncQueue)..where((t) => t.id.equals(id))).write(
      SyncQueueCompanion(
        status: const Value('pending'),
        errorMessage: Value(error),
        attempts: Value(attempts),
        nextAttemptAt: Value(next),
      ),
    );
  }

  Stream<int> watchPendingCount() {
    return (selectOnly(syncQueue)
          ..addColumns([syncQueue.id.count()])
          ..where(syncQueue.isSynced.not() & whereBusiness(syncQueue)))
        .watchSingle()
        .map((row) => row.read(syncQueue.id.count()) ?? 0);
  }

  Future<int> countPending({String? businessId}) async {
    final tenantFilter = businessId != null
        ? syncQueue.businessId.equals(businessId)
        : whereBusiness(syncQueue);
    final countExp = syncQueue.id.count();
    final row = await (selectOnly(syncQueue)
          ..addColumns([countExp])
          ..where(syncQueue.isSynced.not() & tenantFilter))
        .getSingle();
    return row.read(countExp) ?? 0;
  }

  /// Invariant #12 (the outbox is sacred) — the enforcement primitive.
  ///
  /// Returns the set of row ids for [table] that still have an *un-uploaded*
  /// `<table>:upsert` entry in EITHER outbox table:
  ///   • `sync_queue` rows the server has not yet confirmed
  ///     (`status != 'completed'`), and
  ///   • every `sync_queue_orphans` row — an orphan is still un-uploaded local
  ///     data the invariant protects (the cloud is rejecting it, not that the
  ///     device already converged).
  ///
  /// No pull, reconcile, or restore-overwrite may delete or overwrite a local
  /// row whose id is in this set, regardless of timestamp. The id is read from
  /// `payload->>'$.id'`, exactly as the dedup index keys it.
  ///
  /// [businessId] scopes the `sync_queue` lookup (and the orphan lookup via the
  /// `business_id` embedded in each orphan payload). Pass null to match across
  /// every business — row ids are globally-unique UUIDv7, so an unscoped match
  /// is still exact; the restore path uses the unscoped form during the
  /// pre-`setCurrentUser` bootstrap window when no tenant is bound yet.
  Future<Set<String>> pendingRowIds(String table, {String? businessId}) async {
    final upsertAction = '$table:upsert';
    final scoped = businessId != null;
    final queueRows = await customSelect(
      "SELECT json_extract(payload, '\$.id') AS rid FROM sync_queue "
      "WHERE action_type = ?1 AND status != 'completed' "
      "  AND json_extract(payload, '\$.id') IS NOT NULL "
      "${scoped ? "AND business_id = ?2" : ""}",
      variables: [
        Variable.withString(upsertAction),
        if (scoped) Variable.withString(businessId),
      ],
      readsFrom: {syncQueue},
    ).get();
    final orphanRows = await customSelect(
      "SELECT json_extract(payload, '\$.id') AS rid FROM sync_queue_orphans "
      "WHERE action_type = ?1 "
      "  AND json_extract(payload, '\$.id') IS NOT NULL "
      "${scoped ? "AND json_extract(payload, '\$.business_id') = ?2" : ""}",
      variables: [
        Variable.withString(upsertAction),
        if (scoped) Variable.withString(businessId),
      ],
      readsFrom: {syncQueueOrphans},
    ).get();
    return <String>{
      for (final r in queueRows) r.read<String>('rid'),
      for (final r in orphanRows) r.read<String>('rid'),
    };
  }

  Future<void> resetStuckInProgress() async {
    // Items stuck in 'syncing' for more than 5 minutes are reset to 'pending'
    // so a later push tick retries them (e.g. after an app kill mid-push).
    //
    // A naive bulk `syncing -> pending` UPDATE can collide with the partial
    // unique index `idx_sync_queue_dedup_pending` (action_type, payload.id
    // WHERE status='pending'): while a row sits in 'syncing', a fresh edit to
    // the same domain row enqueues a NEW pending row (enqueueUpsert's coalesce
    // lookup only sees 'pending' rows, so the in-flight 'syncing' twin is
    // invisible — and we must not coalesce into a row mid-push). Flipping the
    // stale 'syncing' row back to 'pending' then duplicates that key -> 2067.
    //
    // Resolve it deterministically before the flip. These rows are upserts
    // keyed by row id, so collapsing duplicates to the newest payload is
    // exactly what coalescing intends — no data is lost.
    final cutoffSecs =
        DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/
        1000;
    final bid = requireBusinessId();
    await transaction(() async {
      // 1. Drop stuck 'syncing' rows whose key already has a 'pending' twin:
      //    that pending row carries the newer edit and supersedes the stale
      //    in-flight payload.
      await customStatement(
        "DELETE FROM sync_queue "
        "WHERE status = 'syncing' "
        "  AND created_at < ?1 "
        "  AND business_id = ?2 "
        "  AND action_type NOT LIKE 'domain:%' "
        "  AND json_extract(payload, '\$.id') IS NOT NULL "
        "  AND EXISTS ("
        "    SELECT 1 FROM sync_queue p "
        "     WHERE p.status = 'pending' "
        "       AND p.business_id = sync_queue.business_id "
        "       AND p.action_type = sync_queue.action_type "
        "       AND json_extract(p.payload, '\$.id') = "
        "           json_extract(sync_queue.payload, '\$.id'))",
        [cutoffSecs, bid],
      );
      // 2. Collapse any remaining stuck 'syncing' rows that share a key with
      //    each other (two pushes interrupted for the same row): keep only the
      //    newest payload, discard the older stale duplicates.
      await customStatement(
        "DELETE FROM sync_queue "
        "WHERE status = 'syncing' "
        "  AND created_at < ?1 "
        "  AND business_id = ?2 "
        "  AND action_type NOT LIKE 'domain:%' "
        "  AND json_extract(payload, '\$.id') IS NOT NULL "
        "  AND rowid NOT IN ("
        "    SELECT s.rowid FROM sync_queue s "
        "     WHERE s.status = 'syncing' "
        "       AND s.created_at < ?1 "
        "       AND s.business_id = sync_queue.business_id "
        "       AND s.action_type = sync_queue.action_type "
        "       AND json_extract(s.payload, '\$.id') = "
        "           json_extract(sync_queue.payload, '\$.id') "
        "     ORDER BY s.created_at DESC, s.rowid DESC "
        "     LIMIT 1)",
        [cutoffSecs, bid],
      );
      // 3. Flip the survivors. No two share a key now, and none collides with
      //    a pre-existing pending row, so the dedup index is satisfied.
      await customStatement(
        "UPDATE sync_queue SET status = 'pending' "
        "WHERE status = 'syncing' "
        "  AND created_at < ?1 "
        "  AND business_id = ?2",
        [cutoffSecs, bid],
      );
    });
  }

  Future<void> clearFailureBackoff() async {
    await (update(syncQueue)
          ..where((t) => t.status.equals('pending') & whereBusiness(t)))
        .write(const SyncQueueCompanion(nextAttemptAt: Value(null)));
  }

  Future<List<SyncQueueData>> getFailedItems({int limit = 50}) {
    return (select(syncQueue)
          ..where((t) => t.status.equals('failed') & whereBusiness(t))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(limit))
        .get();
  }

  Stream<List<SyncQueueData>> watchFailedItems({int limit = 100}) {
    return (select(syncQueue)
          ..where((t) => t.status.equals('failed') & whereBusiness(t))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(limit))
        .watch();
  }

  /// Every row in transient-retry / never-pushed state, oldest first. The
  /// `markFailed` state machine keeps every transiently-failed row at
  /// `status='pending'` with a future `nextAttemptAt` — `'failed'` itself
  /// is unused by the current code paths. Without this surface, a row
  /// that has retried for hours looks identical to one enqueued a second
  /// ago, and the only signal is the bare "Pending in queue: N" counter.
  Stream<List<SyncQueueData>> watchPendingItems({int limit = 100}) {
    return (select(syncQueue)
          ..where(
            (t) =>
                t.status.equals('pending') &
                t.isSynced.not() &
                whereBusiness(t),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)])
          ..limit(limit))
        .watch();
  }

  Stream<int> watchFailedCount() {
    return (selectOnly(syncQueue)
          ..addColumns([syncQueue.id.count()])
          ..where(syncQueue.status.equals('failed') & whereBusiness(syncQueue)))
        .watchSingle()
        .map((row) => row.read(syncQueue.id.count()) ?? 0);
  }

  Future<void> clearFailureBackoffById(String id) async {
    await (update(syncQueue)..where((t) => t.id.equals(id))).write(
      const SyncQueueCompanion(
        nextAttemptAt: Value(null),
        status: Value('pending'),
      ),
    );
  }

  Future<void> discardQueueItem(String id) async {
    await (delete(syncQueue)..where((t) => t.id.equals(id))).go();
  }

  Future<void> purgeOldDoneItems() async {
    final sevenDaysAgo = DateTime.now().subtract(const Duration(days: 7));
    await (delete(syncQueue)..where(
          (t) =>
              t.isSynced.equals(true) &
              t.createdAt.isSmallerThanValue(sevenDaysAgo),
        ))
        .go();
  }

  Future<void> enqueue(String actionType, String payload) async {
    await into(syncQueue).insert(
      SyncQueueCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: requireBusinessId(),
        actionType: actionType,
        payload: payload,
        // Stamp auth.uid() at enqueue time so dispatch can reject the row
        // after an account switch. Null when the SDK has no session yet
        // (bootstrap) — dispatch treats null as "trust the current user".
        authUserId: Value(db.currentAuthUserId),
      ),
    );
  }

  /// Looks up an existing pending sync_queue row for `(actionType, rowId)`
  /// using the partial unique index `idx_sync_queue_dedup_pending`. Returns
  /// the row id of the match, or null. Domain envelopes (action_type
  /// 'domain:%') are exempt from coalescing — each is an independent
  /// atomic call — so callers must skip this lookup for them.
  Future<String?> _findPendingDuplicateId(
    String actionType,
    String rowId,
  ) async {
    final result = await customSelect(
      "SELECT id FROM sync_queue "
      "WHERE action_type = ?1 AND status = 'pending' "
      "  AND json_extract(payload, '\$.id') = ?2 "
      "LIMIT 1",
      variables: [Variable.withString(actionType), Variable.withString(rowId)],
      readsFrom: {syncQueue},
    ).getSingleOrNull();
    return result?.read<String>('id');
  }

  /// Finds a pending domain envelope by extracting an arbitrary JSON path
  /// from the payload. Used by the checkout flow to locate the freshly
  /// enqueued `domain:pos_record_sale` row matching a specific orderId
  /// (the order id lives at `$.p_order.id`, not at the top-level `id`,
  /// so the dedup lookup above doesn't match).
  Future<SyncQueueData?> findPendingDomainItem(
    String actionType, {
    required String payloadIdPath,
    required String idValue,
  }) async {
    final bid = db.businessIdResolver.call();
    if (bid == null) return null;
    final result = await customSelect(
      "SELECT id FROM sync_queue "
      "WHERE action_type = ?1 AND status = 'pending' "
      "  AND business_id = ?2 "
      "  AND json_extract(payload, ?3) = ?4 "
      "LIMIT 1",
      variables: [
        Variable.withString(actionType),
        Variable.withString(bid),
        Variable.withString(payloadIdPath),
        Variable.withString(idValue),
      ],
      readsFrom: {syncQueue},
    ).getSingleOrNull();
    if (result == null) return null;
    return getQueueItem(result.read<String>('id'));
  }

  Future<SyncQueueData?> getQueueItem(String id) {
    return (select(syncQueue)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Looks up a row in `sync_queue_orphans` by its ORIGINAL queue id —
  /// what callers stored before §6.8's auto-archive moved permanent
  /// failures out of `sync_queue`. Used by `flushSale` to surface a
  /// terminal failure to the foreground checkout flow even though
  /// `getQueueItem` would now return null.
  Future<SyncQueueOrphanData?> findOrphanByOriginalId(String originalId) {
    return (select(
      syncQueueOrphans,
    )..where((t) => t.originalId.equals(originalId))).getSingleOrNull();
  }

  // ── Orphan surfacing & recovery ────────────────────────────────────────────
  // §6.8 auto-moves permanent failures (P0001, FK-deferred cap) out of
  // sync_queue into sync_queue_orphans and deletes from the queue. The result
  // is invisible to the failed-items list and to watchPendingCount, so the
  // user sees a "Push/RLS gap" in the row-count audit with no corresponding
  // row to inspect or retry. The methods below give the Sync Issues screen a
  // way to list, retry, and discard those rows.

  Stream<List<SyncQueueOrphanData>> watchOrphans({int limit = 200}) {
    return (select(syncQueueOrphans)
          ..orderBy([(t) => OrderingTerm.desc(t.movedAt)])
          ..limit(limit))
        .watch();
  }

  Stream<int> watchOrphanCount() {
    return (selectOnly(syncQueueOrphans)
          ..addColumns([syncQueueOrphans.id.count()]))
        .watchSingle()
        .map((row) => row.read(syncQueueOrphans.id.count()) ?? 0);
  }

  /// Count of un-pushable orphan rows. `sync_queue_orphans` carries no
  /// `business_id` column, so a tenant filter scopes via the `business_id`
  /// embedded in each orphan's payload (`p_business_id` for domain envelopes).
  /// Used by the wipe gate (§3.1) to decide the two-tier resolution: a logout
  /// with orphans present routes to the export + typed-discard flow rather than
  /// being trapped, because orphans are the cloud actively rejecting this
  /// device's writes (42501 / P0001 / auth-uid drift).
  Future<int> countOrphans({String? businessId}) async {
    if (businessId == null) {
      final row = await (selectOnly(syncQueueOrphans)
            ..addColumns([syncQueueOrphans.id.count()]))
          .getSingle();
      return row.read(syncQueueOrphans.id.count()) ?? 0;
    }
    final row = await customSelect(
      "SELECT COUNT(*) AS c FROM sync_queue_orphans "
      "WHERE COALESCE("
      "  json_extract(payload, '\$.business_id'), "
      "  json_extract(payload, '\$.p_business_id')) = ?1",
      variables: [Variable.withString(businessId)],
      readsFrom: {syncQueueOrphans},
    ).getSingle();
    return row.read<int>('c');
  }

  /// Re-enqueues an orphan into sync_queue with cleared backoff and removes
  /// it from the orphans table. The original action_type and payload are
  /// preserved verbatim. Caller must ensure the underlying cause has been
  /// addressed — a blind retry of a phantom-conflict on an append-only
  /// ledger will just orphan it again. Manual retry (the Sync Issues screen
  /// button) resets the auto-retry counter to 0: the operator is explicitly
  /// taking ownership, so it should get the full automatic-recovery budget
  /// again if it re-orphans.
  Future<void> retryOrphan(String orphanId) async {
    await transaction(() async {
      final orphan = await (select(
        syncQueueOrphans,
      )..where((t) => t.id.equals(orphanId))).getSingleOrNull();
      if (orphan == null) return;
      await _reenqueueOrphan(orphan, newAutoRetryCount: 0);
    });
  }

  /// Reason-prefix allowlist for [autoRecoverDueOrphans] (§6.8.1). Only causes
  /// that are now known to be self-healing are auto-retried — re-pushing the
  /// row, not editing it, lets the existing push-side heals run again:
  ///   - `fk_deferred_cap_reached…` — the parent row was missing when the cap
  ///     was hit; it may have since arrived via a pull, so the child can now
  ///     insert.
  ///   - `…created_at is immutable…` (P0001) — the push boundary now scrubs
  ///     `created_at` for ledger voids (`_ledgerCreatedAtScrubTables`, S134),
  ///     so a re-push no longer trips the immutable-column trigger.
  /// Everything else (duplicate order number 23505, RLS / insufficient
  /// privilege, invalid_parameter_value) stays manual-only — a blind retry
  /// would just re-orphan and churn the cloud.
  static bool _isAutoRecoverableReason(String reason) {
    return reason.startsWith('fk_deferred_cap_reached') ||
        reason.contains('created_at is immutable');
  }

  /// Per-orphan auto-recovery cap. After this many automatic re-enqueues a
  /// still-failing orphan is parked for manual review so it can't loop on the
  /// sweep forever. Survives re-orphaning via [SyncQueue.autoRetryCount].
  static const autoRecoverCap = 3;

  /// Automatic orphan recovery sweep (§6.8.1). Re-enqueues every orphan whose
  /// cause is on the self-healing allowlist and whose auto-retry budget is not
  /// yet spent. Returns the number re-enqueued so the caller can decide whether
  /// to kick a push. Driven by the periodic drain tick and connectivity
  /// recovery — never blind-retries terminal failures.
  Future<int> autoRecoverDueOrphans({int limit = 50}) async {
    final candidates =
        await (select(syncQueueOrphans)
              ..where((t) => t.autoRetryCount.isSmallerThanValue(autoRecoverCap))
              ..orderBy([(t) => OrderingTerm.asc(t.movedAt)])
              ..limit(limit))
            .get();
    var recovered = 0;
    for (final orphan in candidates) {
      if (!_isAutoRecoverableReason(orphan.reason)) continue;
      try {
        await transaction(() async {
          await _reenqueueOrphan(
            orphan,
            newAutoRetryCount: orphan.autoRetryCount + 1,
          );
        });
        recovered++;
      } catch (e) {
        // A single undecodable/sessionless orphan must not abort the sweep —
        // skip it (it stays for manual review) and continue.
        debugPrint('[SyncDao] auto-recover skipped orphan ${orphan.id}: $e');
      }
    }
    return recovered;
  }

  /// Shared re-enqueue core for [retryOrphan] and [autoRecoverDueOrphans].
  /// MUST be called inside a transaction. Recovers the businessId from the
  /// payload (table upserts carry `business_id`; domain envelopes carry
  /// `p_business_id`), inserts a fresh sync_queue row, and deletes the orphan.
  Future<void> _reenqueueOrphan(
    SyncQueueOrphanData orphan, {
    required int newAutoRetryCount,
  }) async {
    // sync_queue_orphans has no business_id column; recover it from the
    // payload. Fall back to the session resolver only if neither key is
    // present (legacy orphans).
    String? bid;
    try {
      final decoded = jsonDecode(orphan.payload) as Map<String, dynamic>;
      bid =
          decoded['business_id'] as String? ??
          decoded['p_business_id'] as String?;
    } catch (_) {
      // undecodable payload — fall through to resolver
    }
    bid ??= db.businessIdResolver.call();
    if (bid == null) {
      throw StateError(
        'cannot retry orphan ${orphan.id}: no business_id in payload and '
        'no current session',
      );
    }

    await into(syncQueue).insert(
      SyncQueueCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: bid,
        actionType: orphan.actionType,
        payload: orphan.payload,
        // Re-tags to whoever is signed in now. The orphans table does not
        // carry an auth_user_id; the re-push takes ownership under the
        // current session.
        authUserId: Value(db.currentAuthUserId),
        autoRetryCount: Value(newAutoRetryCount),
      ),
    );
    await (delete(
      syncQueueOrphans,
    )..where((t) => t.id.equals(orphan.id))).go();
  }

  Future<void> discardOrphan(String orphanId) async {
    await (delete(syncQueueOrphans)..where((t) => t.id.equals(orphanId))).go();
  }

  Future<void> enqueueUpsert(String tableName, Insertable row) async {
    // Sync safeguard (CLAUDE.md §5): fail fast on an unknown/typo'd table.
    // The pusher dispatches `<table>:upsert` to `_supabase.from(table)` with
    // no whitelist, so a bad name would silently stick as a failed queue row.
    if (!kEnqueueableTables.contains(tableName)) {
      throw StateError(
        'enqueueUpsert("$tableName"): not a registered synced/cache/businesses '
        'table. Add a SyncedTable entry (tenantScoped: true, or isCache: true) '
        'in sync_registry.dart, or fix the table name — CLAUDE.md §5.',
      );
    }
    final payloadMap = serializeInsertable(row);
    // Resolve the queue row's businessId. Prefer the payload's value — it
    // covers the bootstrap case where the very first business/user is being
    // created during onboarding and the session resolver isn't bound yet
    // (the row being enqueued already carries its own tenant). Fall back to
    // the session resolver for normal post-login writes. If neither yields
    // a value there's no tenant context at all; refuse to enqueue rather
    // than insert a poison row that push would later reject.
    final resolvedBid =
        (payloadMap['business_id'] as String?) ?? db.businessIdResolver.call();
    if (resolvedBid == null) {
      throw StateError(
        'enqueueUpsert($tableName): no business_id in payload and no '
        'authenticated session — refusing to enqueue without tenant context.',
      );
    }
    final bid = resolvedBid;
    payloadMap['business_id'] ??= bid;

    final actionType = '$tableName:upsert';
    final payloadJson = jsonEncode(payloadMap);
    final rowId = payloadMap['id'];

    // Without an id we can't coalesce safely — fall back to plain insert.
    if (rowId is! String) {
      await enqueue(actionType, payloadJson);
      return;
    }

    // Coalesce: a burst of writes to the same row only needs the *latest*
    // payload. Earlier pending entries are stale and must not produce
    // separate outbox rows. The partial unique index guarantees at most
    // one pending row per (action_type, payload.id); the transaction here
    // makes the SELECT-then-INSERT atomic against concurrent enqueues from
    // the same isolate (Drift serializes writes on a single connection).
    await transaction(() async {
      final existingId = await _findPendingDuplicateId(actionType, rowId);
      if (existingId != null) {
        // Refresh the auth tag too: a coalesced row carries the new
        // payload's intent, so it should be tagged with whoever is
        // signed in now. If user A enqueued an upsert, logged out, and
        // user B then edits the same row, the coalesced row pushes
        // under user B (the JWT that will sign the request anyway).
        await (update(syncQueue)..where((t) => t.id.equals(existingId))).write(
          SyncQueueCompanion(
            payload: Value(payloadJson),
            createdAt: Value(DateTime.now()),
            attempts: const Value(0),
            nextAttemptAt: const Value(null),
            errorMessage: const Value(null),
            authUserId: Value(db.currentAuthUserId),
          ),
        );
      } else {
        await into(syncQueue).insert(
          SyncQueueCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: bid,
            actionType: actionType,
            payload: payloadJson,
            authUserId: Value(db.currentAuthUserId),
          ),
        );
      }
    });
  }

  /// Append-only ledger tables — the cloud's `forbid_delete` trigger
  /// raises P0001 on DELETE for any of these, and the corresponding row
  /// would be permanently stuck in `failed` status. Voids must go
  /// through the dedicated DAO methods that append a compensating row.
  static const _ledgerTables = {
    'wallet_transactions',
    'stock_transactions',
    'payment_transactions',
    'activity_logs',
    'crate_ledger',
  };

  Future<void> enqueueDelete(String tableName, String rowId) async {
    if (_ledgerTables.contains(tableName)) {
      throw StateError(
        'enqueueDelete is forbidden for append-only ledger table '
        '"$tableName". Append a compensating/void row through the '
        'corresponding DAO instead (e.g. WalletTransactionsDao.voidTransaction).',
      );
    }
    // Sync safeguard (CLAUDE.md §5): delete targets are always synced tables
    // (never caches, which the cloud rebuilds from domain responses). Reject
    // an unknown/typo'd name before it sticks as a failed queue row.
    if (!kSyncedTenantTables.contains(tableName)) {
      throw StateError(
        'enqueueDelete("$tableName"): not a registered synced table — '
        'fix the table name or add a tenantScoped SyncedTable entry in '
        'sync_registry.dart (CLAUDE.md §5).',
      );
    }
    final payloadMap = {
      'id': rowId,
      'is_deleted': true,
      'last_updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    // Mirror enqueueUpsert's resolution: payload first, resolver second,
    // throw if neither. Delete is always for an existing row, so the
    // resolver should normally have a session — but the same defensive
    // ordering keeps the two methods symmetric and supports future
    // bootstrap-time deletes if any arise.
    final resolvedBid = db.businessIdResolver.call();
    if (resolvedBid == null) {
      throw StateError(
        'enqueueDelete($tableName): no authenticated session — refusing '
        'to enqueue without tenant context.',
      );
    }
    final bid = resolvedBid;
    payloadMap['business_id'] = bid;
    final upsertActionType = '$tableName:upsert';
    final deleteActionType = '$tableName:delete';
    final payloadJson = jsonEncode(payloadMap);

    // A delete supersedes any pending upsert for the same row — pushing the
    // upsert first would race against the delete and leave the cloud row
    // in an inconsistent state. Mark any pending upsert as completed (so it
    // doesn't push), then coalesce against an existing pending delete.
    await transaction(() async {
      final pendingUpsertId = await _findPendingDuplicateId(
        upsertActionType,
        rowId,
      );
      if (pendingUpsertId != null) {
        await (update(
          syncQueue,
        )..where((t) => t.id.equals(pendingUpsertId))).write(
          const SyncQueueCompanion(
            isSynced: Value(true),
            status: Value('completed'),
            nextAttemptAt: Value(null),
          ),
        );
      }

      final existingDeleteId = await _findPendingDuplicateId(
        deleteActionType,
        rowId,
      );
      if (existingDeleteId != null) {
        // Coalesced delete retags to current user — same rationale as
        // the upsert coalesce branch above.
        await (update(
          syncQueue,
        )..where((t) => t.id.equals(existingDeleteId))).write(
          SyncQueueCompanion(
            payload: Value(payloadJson),
            createdAt: Value(DateTime.now()),
            attempts: const Value(0),
            nextAttemptAt: const Value(null),
            errorMessage: const Value(null),
            authUserId: Value(db.currentAuthUserId),
          ),
        );
      } else {
        await into(syncQueue).insert(
          SyncQueueCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: bid,
            actionType: deleteActionType,
            payload: payloadJson,
            authUserId: Value(db.currentAuthUserId),
          ),
        );
      }
    });
  }

  /// Deletes pending queue items that have already been attempted at least
  /// once (i.e. items the engine has tried to push and failed on). Untried
  /// items (`attempts == 0`) are preserved so a fresh enqueue racing with
  /// the purge isn't lost. Returns the number of rows deleted.
  ///
  /// Used as a one-shot remediation when a serialization bug bakes a bad
  /// payload into the queue — fixing the bug doesn't repair existing rows
  /// because the payload is frozen at enqueue time.
  Future<int> purgeAttemptedPending() async {
    return (delete(syncQueue)..where(
          (t) => t.status.equals('pending') & t.attempts.isBiggerThanValue(0),
        ))
        .go();
  }

  // ── §3.1 "Resolve unsynced data" — export & discard ────────────────────────
  // Invariant #12 lets un-pushable data leave the device ONLY by a deliberate,
  // confirmed user action, and only after it has been made exportable. The two
  // methods below back that flow: [unsyncedExportRows] renders the outbox to a
  // printable/CSV record (money recoverable on paper), and
  // [discardUnsyncedForBusiness] removes it once the user has typed-confirmed.

  /// Flattens every un-synced outbox row for [businessId] — un-uploaded
  /// `sync_queue` entries (`status != 'completed'`) plus all
  /// `sync_queue_orphans` — into CSV body rows. Columns:
  /// `[source, table, action, row_id, reason, created_at, payload]`.
  /// `source` is `queue` or `orphan`; orphans carry their rejection `reason`.
  /// Newest first so the most recent lost activity is at the top.
  Future<List<List<String>>> unsyncedExportRows(String businessId) async {
    final queueRows =
        await (select(syncQueue)
              ..where(
                (t) => t.businessId.equals(businessId) & t.isSynced.not(),
              )
              ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
            .get();
    final orphanRows = await customSelect(
      "SELECT id, action_type, payload, reason, created_at FROM "
      "sync_queue_orphans WHERE COALESCE("
      "  json_extract(payload, '\$.business_id'), "
      "  json_extract(payload, '\$.p_business_id')) = ?1 "
      "ORDER BY moved_at DESC",
      variables: [Variable.withString(businessId)],
      readsFrom: {syncQueueOrphans},
    ).get();

    String tableOf(String actionType) =>
        actionType.contains(':') ? actionType.split(':').first : actionType;
    String actionOf(String actionType) {
      final parts = actionType.split(':');
      return parts.length > 1 ? parts.sublist(1).join(':') : '';
    }

    final out = <List<String>>[];
    for (final r in queueRows) {
      out.add([
        'queue',
        tableOf(r.actionType),
        actionOf(r.actionType),
        r.id,
        r.errorMessage ?? '',
        r.createdAt.toIso8601String(),
        r.payload,
      ]);
    }
    for (final r in orphanRows) {
      final actionType = r.read<String>('action_type');
      final createdMs = r.read<int>('created_at') * 1000;
      out.add([
        'orphan',
        tableOf(actionType),
        actionOf(actionType),
        r.read<String>('id'),
        r.read<String?>('reason') ?? '',
        DateTime.fromMillisecondsSinceEpoch(createdMs).toIso8601String(),
        r.read<String>('payload'),
      ]);
    }
    return out;
  }

  /// Discards every un-synced outbox row for [businessId] — un-uploaded
  /// `sync_queue` entries and `sync_queue_orphans`. The deliberate, confirmed
  /// user action of Invariant #12: callers MUST have exported the rows and
  /// obtained a typed confirmation first (the "Resolve unsynced data" flow).
  /// Returns the total number of rows discarded.
  Future<int> discardUnsyncedForBusiness(String businessId) async {
    return transaction(() async {
      final queueDeleted =
          await (delete(syncQueue)..where(
                (t) => t.businessId.equals(businessId) & t.isSynced.not(),
              ))
              .go();
      final orphanDeleted = await customUpdate(
        "DELETE FROM sync_queue_orphans WHERE COALESCE("
        "  json_extract(payload, '\$.business_id'), "
        "  json_extract(payload, '\$.p_business_id')) = ?1",
        variables: [Variable.withString(businessId)],
        updates: {syncQueueOrphans},
        updateKind: UpdateKind.delete,
      );
      return queueDeleted + orphanDeleted;
    });
  }
}

@DriftAccessor(tables: [ErrorLogs])
class ErrorLogDao extends DatabaseAccessor<AppDatabase>
    with _$ErrorLogDaoMixin, BusinessScopedDao<AppDatabase> {
  ErrorLogDao(super.db);

  static const int _maxMessage = 500;
  static const int _maxStack = 4000;

  /// Records a caught/uncaught error to the append-only `error_logs` table
  /// (master plan §33 — Reliability and Crash Handling). This is the crash
  /// safety net, so it is fully defensive: it must NEVER throw — any failure
  /// to record is swallowed (the net can't become the thing that breaks).
  ///
  /// Routes through [SyncDao.enqueueUpsert] ONLY when a business is bound. A
  /// pre-login crash has no tenant to scope to, so that row is kept local-only
  /// — it can't be RLS-scoped cloud-side (§33.3). The enqueue call below keeps
  /// the Layer C raw-write scanner green for this method.
  Future<void> logError({
    required String errorType,
    required String message,
    String? stackTrace,
    String? context,
    String? role,
    bool isFatal = false,
    String? appVersion,
    String? platform,
    String? businessId,
    String? userId,
  }) async {
    try {
      // Prefer an explicitly-supplied tenant/user over the live resolver.
      // Session-teardown diagnostics (the `auth.session_lost` /
      // `auth.session_expired_gate` breadcrumbs) fire at the moment the JWT is
      // gone — and on the kick path AFTER `AuthService.value` is nulled — so the
      // resolver returns null there, which would silently keep the row
      // local-only (no enqueue → never release-visible, the exact failure these
      // breadcrumbs exist to avoid). Passing the in-hand local user's tenant
      // keeps the row scoped and durably queued; it flushes on the next
      // authenticated push (e.g. the OTP re-auth the gate itself performs).
      // Nullable still — null before a business is bound (pre-login crash).
      final bid = businessId ?? currentBusinessId;
      final row = ErrorLogsCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: Value(bid),
        userId: Value(userId ?? currentUserId),
        role: Value(role),
        context: Value(context),
        errorType: errorType,
        message: _truncate(message, _maxMessage),
        stackTrace: Value(
          stackTrace == null ? null : _truncate(stackTrace, _maxStack),
        ),
        isFatal: Value(isFatal),
        appVersion: Value(appVersion),
        platform: Value(platform),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await into(errorLogs).insert(row);
      // sync-exempt: pre-login crashes (bid == null) have no tenant to scope to,
      // so they stay local-only; only tenant-scoped rows are pushed (§33.3).
      if (bid != null) {
        await db.syncDao.enqueueUpsert('error_logs', row);
      }
    } catch (_) {
      // The crash safety net must never itself crash. Swallow deliberately.
    }
  }

  static String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';
}

@DriftAccessor(tables: [ActivityLogs])
class ActivityLogDao extends DatabaseAccessor<AppDatabase>
    with _$ActivityLogDaoMixin, BusinessScopedDao<AppDatabase> {
  ActivityLogDao(super.db);

  /// Canonical activity-log write (Ring 0 #2, §24.4). Stores a generic
  /// (entityType, entityId) reference plus optional before/after JSON snapshots
  /// for the detail view. Routes through enqueueUpsert (synced append-only
  /// ledger). New features should call this directly.
  Future<void> logActivity({
    required String action,
    required String description,
    String? staffId,
    String? storeId,
    String? entityType,
    String? entityId,
    Map<String, dynamic>? before,
    Map<String, dynamic>? after,
  }) async {
    final row = ActivityLogsCompanion.insert(
      id: Value(UuidV7.generate()),
      businessId: requireBusinessId(),
      userId: Value(staffId),
      action: action,
      description: description,
      entityType: Value(entityType),
      entityId: Value(entityId),
      beforeJson: Value(before == null ? null : jsonEncode(before)),
      afterJson: Value(after == null ? null : jsonEncode(after)),
      storeId: Value(storeId),
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(activityLogs).insert(row);
    await db.syncDao.enqueueUpsert('activity_logs', row);
  }

  /// Back-compat convenience over [logActivity]: the legacy per-entity params
  /// fold onto the generic (entityType, entityId) pair (the old "<=1 set" CHECK
  /// guaranteed at most one was set). Existing callers and [ActivityLogService]
  /// keep working unchanged; new code should prefer [logActivity] so it can
  /// carry before/after snapshots.
  Future<void> log({
    required String action,
    required String description,
    String? staffId,
    String? storeId,
    String? orderId,
    String? productId,
    String? customerId,
    String? expenseId,
    String? deliveryId,
    String? walletTxnId,
  }) async {
    String? entityType;
    String? entityId;
    if (orderId != null) {
      entityType = 'order';
      entityId = orderId;
    } else if (productId != null) {
      entityType = 'product';
      entityId = productId;
    } else if (customerId != null) {
      entityType = 'customer';
      entityId = customerId;
    } else if (expenseId != null) {
      entityType = 'expense';
      entityId = expenseId;
    } else if (deliveryId != null) {
      entityType = 'delivery';
      entityId = deliveryId;
    } else if (walletTxnId != null) {
      entityType = 'wallet_transaction';
      entityId = walletTxnId;
    }
    await logActivity(
      action: action,
      description: description,
      staffId: staffId,
      storeId: storeId,
      entityType: entityType,
      entityId: entityId,
    );
  }

  Stream<List<ActivityLogData>> watchRecent({int limit = 100}) {
    return (select(activityLogs)
          ..where((t) => whereBusiness(t) & t.voidedAt.isNull())
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ])
          ..limit(limit))
        .watch();
  }

  Future<List<ActivityLogData>> getActivityLogsPage({
    String? storeId,
    ({DateTime createdAt, String id})? cursor,
    int limit = 30,
  }) async {
    var predicate = whereBusiness(activityLogs) & activityLogs.voidedAt.isNull();

    if (storeId != null) {
      final isStoreScoped = activityLogs.storeId.isNotNull() |
          (activityLogs.entityType.isNotNull() & activityLogs.entityType.isIn(const ['product', 'order', 'delivery'])) |
          activityLogs.action.lower().like('%inventory%') |
          activityLogs.action.lower().like('%stock%') |
          activityLogs.action.lower().like('%delivery%');
      predicate = predicate & (activityLogs.storeId.equals(storeId) | isStoreScoped.not());
    }

    if (cursor != null) {
      predicate = predicate & (
        activityLogs.createdAt.isSmallerThanValue(cursor.createdAt) |
        (activityLogs.createdAt.equals(cursor.createdAt) & activityLogs.id.isSmallerThanValue(cursor.id))
      );
    }

    final query = select(activityLogs)
      ..where((t) => predicate)
      ..orderBy([
        (t) => OrderingTerm.desc(t.createdAt),
        (t) => OrderingTerm.desc(t.id),
      ])
      ..limit(limit);

    return query.get();
  }

  Stream<List<ActivityLogData>> watchActivityLogsPage({
    String? storeId,
    int limit = 30,
  }) {
    var predicate = whereBusiness(activityLogs) & activityLogs.voidedAt.isNull();

    if (storeId != null) {
      final isStoreScoped = activityLogs.storeId.isNotNull() |
          (activityLogs.entityType.isNotNull() & activityLogs.entityType.isIn(const ['product', 'order', 'delivery'])) |
          activityLogs.action.lower().like('%inventory%') |
          activityLogs.action.lower().like('%stock%') |
          activityLogs.action.lower().like('%delivery%');
      predicate = predicate & (activityLogs.storeId.equals(storeId) | isStoreScoped.not());
    }

    final query = select(activityLogs)
      ..where((t) => predicate)
      ..orderBy([
        (t) => OrderingTerm.desc(t.createdAt),
        (t) => OrderingTerm.desc(t.id),
      ])
      ..limit(limit);

    return query.watch();
  }

  Future<List<ActivityLogData>> getForOrder(String orderId) {
    return (select(activityLogs)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.entityType.equals('order') &
                t.entityId.equals(orderId) &
                t.voidedAt.isNull(),
          )
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ]))
        .get();
  }

  Future<List<ActivityLogData>> getForProduct(String productId) {
    return (select(activityLogs)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.entityType.equals('product') &
                t.entityId.equals(productId) &
                t.voidedAt.isNull(),
          )
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ]))
        .get();
  }

  Future<List<ActivityLogData>> getForCustomer(String customerId) {
    return (select(activityLogs)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.entityType.equals('customer') &
                t.entityId.equals(customerId) &
                t.voidedAt.isNull(),
          )
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ]))
        .get();
  }

  Future<List<ActivityLogData>> getForExpense(String expenseId) {
    return (select(activityLogs)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.entityType.equals('expense') &
                t.entityId.equals(expenseId) &
                t.voidedAt.isNull(),
          )
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ]))
        .get();
  }

  Future<List<ActivityLogData>> getForDelivery(String deliveryId) {
    return (select(activityLogs)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.entityType.equals('delivery') &
                t.entityId.equals(deliveryId) &
                t.voidedAt.isNull(),
          )
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ]))
        .get();
  }

  Future<List<ActivityLogData>> getForWalletTxn(String walletTxnId) {
    return (select(activityLogs)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.entityType.equals('wallet_transaction') &
                t.entityId.equals(walletTxnId) &
                t.voidedAt.isNull(),
          )
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ]))
        .get();
  }

  Future<List<ActivityLogData>> getStockCountLogs() {
    return (select(activityLogs)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.action.equals('stock_count') &
                t.voidedAt.isNull(),
          )
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ]))
        .get();
  }
}

@DriftAccessor(tables: [Notifications])
class NotificationsDao extends DatabaseAccessor<AppDatabase>
    with _$NotificationsDaoMixin, BusinessScopedDao<AppDatabase> {
  NotificationsDao(super.db);

  /// Recipient-scope filter: a row is visible to the current user when
  /// `recipient_user_id` is NULL (broadcast) OR equals the current user's
  /// id. If no user is resolved (logged out), only broadcasts surface —
  /// safer default than leaking targeted rows.
  Expression<bool> _whereForCurrentUser($NotificationsTable t) {
    final uid = currentUserId;
    if (uid == null) return t.recipientUserId.isNull();
    return t.recipientUserId.isNull() | t.recipientUserId.equals(uid);
  }

  Future<void> create(
    String type,
    String message, {
    String? linkedRecordId,
    String? recipientUserId,
  }) async {
    final id = UuidV7.generate();
    final row = NotificationsCompanion.insert(
      id: Value(id),
      businessId: requireBusinessId(),
      type: type,
      message: message,
      linkedRecordId: Value(linkedRecordId),
      recipientUserId: Value(recipientUserId),
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(notifications).insert(row);
    await db.syncDao.enqueueUpsert('notifications', row);
  }

  /// Canonical notification write (Ring 0 #2, §26.2/§26.4). Sets [severity]
  /// (info/warning/alert) for the card colour; [recipientUserId] null =
  /// broadcast to every member. Routes through enqueueUpsert (synced). New
  /// features fire their §26.4 events through this helper.
  Future<void> fireNotification({
    required String type,
    required String message,
    String severity = 'info',
    String? linkedRecordId,
    String? recipientUserId,
  }) async {
    final row = NotificationsCompanion.insert(
      id: Value(UuidV7.generate()),
      businessId: requireBusinessId(),
      type: type,
      message: message,
      severity: Value(severity),
      linkedRecordId: Value(linkedRecordId),
      recipientUserId: Value(recipientUserId),
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(notifications).insert(row);
    await db.syncDao.enqueueUpsert('notifications', row);
  }

  Stream<List<NotificationData>> watchAll() {
    return (select(notifications)
          ..where((t) => whereBusiness(t) & _whereForCurrentUser(t))
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  Stream<int> watchUnreadCount() {
    final count = notifications.id.count();
    return (selectOnly(notifications)
          ..addColumns([count])
          ..where(
            whereBusiness(notifications) &
                _whereForCurrentUser(notifications) &
                notifications.isRead.equals(false),
          ))
        .watchSingle()
        .map((row) => row.read(count) ?? 0);
  }

  Future<void> markRead(String id) async {
    final now = DateTime.now();
    final comp = NotificationsCompanion(
      id: Value(id),
      isRead: const Value(true),
      lastUpdatedAt: Value(now),
    );
    // Recipient guard prevents marking-read on another user's targeted row
    // (e.g. a staff dismissing a notification scoped to the CEO).
    await (update(notifications)..where(
          (t) => t.id.equals(id) & whereBusiness(t) & _whereForCurrentUser(t),
        ))
        .write(comp);
    // Full-row enqueue: a partial notifications upsert omits NOT NULL type/message.
    final row = await (select(
      notifications,
    )..where((t) => t.id.equals(id) & whereBusiness(t))).getSingleOrNull();
    if (row != null) {
      await db.syncDao.enqueueUpsert('notifications', row.toCompanion(true));
    }
  }

  Future<void> markAllRead() async {
    final now = DateTime.now();
    final unread =
        await (select(notifications)..where(
              (t) =>
                  whereBusiness(t) &
                  _whereForCurrentUser(t) &
                  t.isRead.equals(false),
            ))
            .get();
    if (unread.isEmpty) return;

    await (update(
      notifications,
    )..where((t) => whereBusiness(t) & _whereForCurrentUser(t))).write(
      NotificationsCompanion(
        isRead: const Value(true),
        lastUpdatedAt: Value(now),
      ),
    );

    for (final notif in unread) {
      // Full row (with the read flag applied) so the cloud upsert's INSERT has
      // the NOT NULL type/message columns; a partial upsert would 23502.
      await db.syncDao.enqueueUpsert(
        'notifications',
        notif
            .toCompanion(true)
            .copyWith(isRead: const Value(true), lastUpdatedAt: Value(now)),
      );
    }
  }

  Future<void> deleteSingle(String id) async {
    await (delete(notifications)..where(
          (t) => t.id.equals(id) & whereBusiness(t) & _whereForCurrentUser(t),
        ))
        .go();
    await db.syncDao.enqueueDelete('notifications', id);
  }

  Future<void> clearAll() async {
    final allNotifs = await (select(
      notifications,
    )..where((t) => whereBusiness(t) & _whereForCurrentUser(t))).get();
    await (delete(
      notifications,
    )..where((t) => whereBusiness(t) & _whereForCurrentUser(t))).go();
    for (final n in allNotifs) {
      await db.syncDao.enqueueDelete('notifications', n.id);
    }
  }
}
