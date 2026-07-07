import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/services/cloud_transport.dart';

/// Production [CloudTransport] backed by a live [SupabaseClient] (ADR 0001).
///
/// A large adapter with a thin per-method implementation: it forwards the push
/// verbs, owns the pull pagination loop (moved verbatim from the old
/// `_fetchOneTable`), and owns the realtime channel lifecycle (a single tenant
/// channel with one `postgres_changes` binding per table, the `businesses`-by-`id`
/// filter quirk, subscribe-status logging, and teardown). Error modes are passed
/// through untouched: PostgREST failures throw
/// [PostgrestException]; page/chunk timeouts throw [TimeoutException].
class SupabaseCloudTransport implements CloudTransport {
  final SupabaseClient _client;

  SupabaseCloudTransport(this._client);

  /// Floor for the pull page-size halving on repeated page timeouts. Below this
  /// a timeout is surfaced so the caller can classify the failure.
  static const int _minPullPageSize = 10;

  /// Single realtime channel carrying one `postgres_changes` binding per synced
  /// table — one websocket join for the whole tenant. See [startRealtime].
  RealtimeChannel? _channel;

  // ── PUSH ──────────────────────────────────────────────────────────────────
  @override
  Future<void> upsertRows(
    String table,
    List<Map<String, dynamic>> rows, {
    String? onConflict,
  }) {
    // Null onConflict → PostgREST defaults to the primary key.
    return onConflict != null
        ? _client.from(table).upsert(rows, onConflict: onConflict)
        : _client.from(table).upsert(rows);
  }

  @override
  Future<void> deleteRowsById(String table, List<String> ids) {
    if (ids.isEmpty) return Future.value();
    return _client.from(table).delete().inFilter('id', ids);
  }

  @override
  Future<dynamic> callRpc(String name, Map<String, dynamic> params) =>
      _client.rpc(name, params: params);

  // ── PULL ──────────────────────────────────────────────────────────────────
  /// Single-table PostgREST fetch with cursor-based pagination.
  ///
  /// Fetches rows in pages of [TableQuery.pageSize] rows, ordered by
  /// `last_updated_at` ascending (and `id` ascending as a secondary tie-break for
  /// all tables except `system_config`). This ordering guarantees stable
  /// pagination — no row is skipped or double-counted across page boundaries.
  ///
  /// On a page-level [TimeoutException] the page size is halved (floored at
  /// [_minPullPageSize]) and the same offset is retried once. A second timeout at
  /// the floor propagates so the caller can classify the failure.
  ///
  /// `system_config` is global (no tenant filter, no `id` column, tiny dataset) —
  /// it is fetched in a single unpaginated call.
  @override
  Future<List<dynamic>> fetchTable(TableQuery query) async {
    final table = query.table;
    final businessId = query.businessId;
    final since = query.since;
    final isGlobal = table == 'system_config';
    var q = _client.from(table).select();

    if (!isGlobal) {
      // The cloud `businesses` table has no `business_id` column — its `id`
      // IS the business id. All other tables filter by `business_id`.
      final filterColumn = table == 'businesses' ? 'id' : 'business_id';
      q = q.eq(filterColumn, businessId);
    }

    // The `businesses` row is the FK target for almost everything local.
    // Always fetch it unconditionally so a stale `since` can't produce a
    // sync where children try to insert against a missing parent.
    if (since != null && table != 'businesses') {
      q = q.gt('last_updated_at', since.toIso8601String());
    }

    // system_config: global, tiny, no `id` column — single unpaginated call.
    if (isGlobal) {
      final List<dynamic> data = await q.timeout(const Duration(seconds: 25));
      return data;
    }

    // Stable ordering required for pagination: rows must not shift across page
    // boundaries as new rows arrive mid-pull. `last_updated_at` alone is not
    // unique (multiple rows can share a second boundary); `id` breaks ties
    // deterministically.
    final orderedQuery = q
        .order('last_updated_at', ascending: true)
        .order('id', ascending: true);

    final allRows = <dynamic>[];
    int offset = 0;
    int currentPageSize = query.pageSize;

    while (true) {
      try {
        final List<dynamic> page = await orderedQuery
            .range(offset, offset + currentPageSize - 1)
            .timeout(const Duration(seconds: 15));

        if (page.isEmpty) break;
        allRows.addAll(page);
        offset += page.length;
        if (page.length < currentPageSize) break; // last page
      } on TimeoutException catch (e) {
        final halved = currentPageSize ~/ 2;
        if (halved < _minPullPageSize) {
          // Already at floor — surface so the caller can classify failure.
          debugPrint(
            '[CloudTransport] Pull page timeout at min size for $table '
            '(offset=$offset, size=$currentPageSize): $e',
          );
          rethrow;
        }
        currentPageSize = halved;
        debugPrint(
          '[CloudTransport] Pull page timeout for $table '
          '(offset=$offset) — shrinking page to $currentPageSize and retrying.',
        );
        // Retry the same offset with the smaller page size (offset unchanged).
      }
    }

    return allRows;
  }

  @override
  Future<List<dynamic>> fetchRowsByIds(
    String table,
    String businessId,
    List<String> ids,
  ) async {
    final List<dynamic> rows = await _client
        .from(table)
        .select()
        .eq('business_id', businessId)
        .inFilter('id', ids)
        .timeout(const Duration(seconds: 15));
    return rows;
  }

  // ── CONNECTION / EXISTENCE ─────────────────────────────────────────────────
  @override
  Future<void> warmUp(String businessId) async {
    // Tenant-scoped `select … limit 1` on the session's own business row —
    // RLS-safe and tiny. The caller applies the first-drain timeout.
    await _client
        .from('businesses')
        .select('id')
        .eq('id', businessId)
        .limit(1);
  }

  @override
  Future<bool> businessDeletedTombstoneExists(String businessId) async {
    final rows = await _client
        .from('deleted_businesses')
        .select('business_id')
        .eq('business_id', businessId)
        .limit(1);
    return rows.isNotEmpty;
  }

  // ── REALTIME ───────────────────────────────────────────────────────────────
  @override
  void startRealtime(
    Iterable<String> tables,
    String businessId, {
    required void Function(PostgresChangePayload) onChange,
  }) {
    if (_channel != null) return;

    // ONE channel carrying a `postgres_changes` binding per synced table — a
    // single websocket join for the whole tenant — instead of one channel per
    // table. Signing in fans out ~55 tables; one-channel-per-table fired ~55
    // near-simultaneous `phx_join`s on the socket, blew past the realtime
    // per-client channel/join ceiling, and every channel came back
    // CHANNEL_ERROR → TIMED_OUT with no CDC subscription ever established (#95).
    // Multiple bindings on a single channel is the supported many-table pattern
    // (realtime_client 2.x) and needs just one join.
    //
    // All bindings share `onChange`; the engine dispatches by `payload.table`
    // (there is exactly one binding per table, so no event is delivered twice).
    // `businesses` has no `business_id` column — its `id` IS the business id, so
    // it filters on `id`. `system_config` is global and skipped.
    var channel = _client.channel('public:tenant:$businessId');
    for (final table in tables) {
      if (table == 'system_config') continue;
      final isBusinesses = table == 'businesses';
      channel = channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: isBusinesses ? 'id' : 'business_id',
          value: businessId,
        ),
        callback: onChange,
      );
    }

    // `postgres_changes` is RLS-gated: the channel join must carry the user's
    // JWT or the realtime server rejects EVERY binding (channelError, no CDC —
    // #97). A channel only reads `socket.accessToken` into its join payload at
    // subscribe time; supabase_flutter's auto-setAuth runs on auth events, but
    // nothing guarantees the socket holds the *user* token (vs the anon key) at
    // this exact moment. Force it now — synchronous for a non-null token, so the
    // subscribe below carries the JWT. The diagnostic reveals whether the socket
    // was already authed (true → auth was fine, look elsewhere) or on the anon
    // key (false → this is the fix).
    final sessionToken = _client.auth.currentSession?.accessToken;
    final socketAlreadyHadSessionToken =
        _client.realtime.accessToken == sessionToken;
    unawaited(_client.realtime.setAuth(sessionToken));
    debugPrint(
      '[CloudTransport] Realtime auth: session=${sessionToken != null} '
      'socketAlreadyHadSessionToken=$socketAlreadyHadSessionToken',
    );

    // One subscribe-status callback for the whole tenant channel — surfaces
    // SUBSCRIBED once (live) or CHANNEL_ERROR / TIMED_OUT once (dead).
    channel.subscribe((status, error) {
      if (status == RealtimeSubscribeStatus.channelError ||
          status == RealtimeSubscribeStatus.timedOut) {
        debugPrint(
          '[CloudTransport] Realtime tenant channel $status'
          '${error != null ? ' — $error' : ''}',
        );
      } else if (status == RealtimeSubscribeStatus.subscribed) {
        debugPrint('[CloudTransport] Realtime subscribed (tenant channel)');
      }
    });
    _channel = channel;
  }

  @override
  Future<void> stopRealtime() async {
    // Clear the holder *synchronously* before the await so `startRealtime`'s
    // guard reflects reality the moment this yields control — a fire-and-forget
    // stop immediately followed by a start must not see the not-yet-removed
    // channel and bail (the #93 resubscribe race).
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      await _client.removeChannel(channel);
    }
  }

  // ── IDENTITY ───────────────────────────────────────────────────────────────
  @override
  String? get currentAuthUserId => _client.auth.currentUser?.id;

  @override
  Stream<TransportAuthEvent> get authEvents =>
      _client.auth.onAuthStateChange.expand((state) {
        switch (state.event) {
          case AuthChangeEvent.signedIn:
            return const [TransportAuthEvent.signedIn];
          case AuthChangeEvent.tokenRefreshed:
            return const [TransportAuthEvent.tokenRefreshed];
          case AuthChangeEvent.initialSession:
            return const [TransportAuthEvent.initialSession];
          case AuthChangeEvent.signedOut:
            return const [TransportAuthEvent.signedOut];
          default:
            return const <TransportAuthEvent>[];
        }
      });
}
