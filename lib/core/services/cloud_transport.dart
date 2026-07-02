import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart'
    show PostgresChangePayload, PostgrestException;

/// A neutral auth-lifecycle signal.
///
/// The sync engine reacts only to the *category* of an auth change — re-warm and
/// push on a fresh/refreshed/initial session, reset per-session flags on sign-out
/// — never to the session or user payload. So this four-value enum is a complete,
/// not lossy, representation of everything the engine consumes from the auth
/// stream. Contrast with [PostgrestException]/[PostgresChangePayload], whose
/// payloads are load-bearing and are therefore leaked through the seam. See
/// ADR 0001.
enum TransportAuthEvent { signedIn, tokenRefreshed, initialSession, signedOut }

/// A single-table pull request.
///
/// Fetch [table]'s rows for [businessId] changed since [since] (`null` = full
/// pull). [pageSize] is the initial page size; the adapter owns the
/// paginate/halve-on-timeout loop and returns the whole slice. The
/// per-table filter quirks (`businesses` filters by `id`; `system_config` is
/// global and unpaginated; `businesses` ignores `since`) live inside the adapter.
class TableQuery {
  final String table;
  final String businessId;
  final DateTime? since;
  final int pageSize;

  const TableQuery(
    this.table,
    this.businessId,
    this.since, {
    required this.pageSize,
  });
}

/// The seam between the sync engine and the cloud backend (ADR 0001).
///
/// Everything the engine needs from the cloud, in the engine's own vocabulary:
/// push (`upsertRows` / `deleteRowsById` / `callRpc`), pull (`fetchTable` /
/// `fetchRowsByIds`), a cold-start `warmUp`, a `deleted_businesses` tombstone
/// check, realtime (`startRealtime` / `stopRealtime`), and identity
/// (`currentAuthUserId` / `authEvents`). A deep module: PostgREST specifics,
/// pagination, per-call timeouts on the pull loop, and realtime channel lifecycle
/// all hide behind these members.
///
/// **Ownership.** The push chunk-loop, outbox bookkeeping, and §6.8 retry
/// classification stay in the engine — the seam does one wire round-trip per push
/// call and knows nothing of `sync_queue`. The pull page-loop lives in the
/// adapter.
///
/// **Error contract (part of the interface).** Push/pull methods throw
/// [PostgrestException] (carrying `.code`) and [TimeoutException] verbatim — the
/// engine's retry policy is keyed on the Postgres codes (`23503` FK-deferred,
/// `P0001`/`23xxx` permanent, `23505` order-number collision). Both the real and
/// the in-memory adapter MUST preserve this.
abstract interface class CloudTransport {
  // ── PUSH ──────────────────────────────────────────────────────────────────
  /// Upsert [rows] into [table]; [onConflict] names the conflict target
  /// (null → PostgREST defaults to the primary key). One wire round-trip.
  Future<void> upsertRows(
    String table,
    List<Map<String, dynamic>> rows, {
    String? onConflict,
  });

  /// Hard-delete rows of [table] whose `id` is in [ids] (tombstone cleanup).
  Future<void> deleteRowsById(String table, List<String> ids);

  /// Invoke a Postgres RPC ([name]) with [params] and return its raw response.
  /// Used for domain-push envelopes and the `pos_pull_snapshot` pull.
  Future<dynamic> callRpc(String name, Map<String, dynamic> params);

  // ── PULL ──────────────────────────────────────────────────────────────────
  /// Fetch a whole table slice per [query] (pagination hidden inside).
  Future<List<dynamic>> fetchTable(TableQuery query);

  /// Fetch specific rows of [table] for [businessId] by their [ids] in one
  /// round-trip (the A2 targeted-parent-fetch path).
  Future<List<dynamic>> fetchRowsByIds(
    String table,
    String businessId,
    List<String> ids,
  );

  // ── CONNECTION / EXISTENCE ─────────────────────────────────────────────────
  /// Pay the cold-network cost with a trivial round-trip (a `businesses` row
  /// probe) before the first real drain.
  Future<void> warmUp(String businessId);

  /// True iff a `deleted_businesses` tombstone exists for [businessId] — the
  /// false-positive-proof "did the owner delete this business?" check (§10.3).
  Future<bool> businessDeletedTombstoneExists(String businessId);

  // ── REALTIME ───────────────────────────────────────────────────────────────
  /// Subscribe to postgres changes for [tables] (one channel each; `businesses`
  /// filtered by `id`, the rest by `business_id`) and invoke [onChange] per
  /// event. Idempotent while a subscription is live.
  void startRealtime(
    Iterable<String> tables,
    String businessId, {
    required void Function(PostgresChangePayload) onChange,
  });

  /// Tear down all realtime channels.
  Future<void> stopRealtime();

  // ── IDENTITY ───────────────────────────────────────────────────────────────
  /// The signed-in user's id, or null when there is no session.
  String? get currentAuthUserId;

  /// Neutralised auth-lifecycle events (see [TransportAuthEvent]).
  Stream<TransportAuthEvent> get authEvents;
}
