import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/services/cloud_transport.dart';

/// Production [CloudTransport] backed by a live [SupabaseClient] (ADR 0001).
///
/// A large adapter with a thin per-method implementation: it forwards the push
/// verbs, owns the pull pagination loop (moved verbatim from the old
/// `_fetchOneTable`), and owns the realtime channel lifecycle (one channel per
/// table, the `businesses`-by-`id` filter quirk, subscribe-status logging, and
/// teardown). Error modes are passed through untouched: PostgREST failures throw
/// [PostgrestException]; page/chunk timeouts throw [TimeoutException].
class SupabaseCloudTransport implements CloudTransport {
  final SupabaseClient _client;

  SupabaseCloudTransport(this._client);

  /// Floor for the pull page-size halving on repeated page timeouts. Below this
  /// a timeout is surfaced so the caller can classify the failure.
  static const int _minPullPageSize = 10;

  final List<RealtimeChannel> _tableChannels = [];
  RealtimeChannel? _businessesChannel;

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
    if (_tableChannels.isNotEmpty || _businessesChannel != null) return;

    // One channel per synced tenant table, each with an explicit `table:` +
    // `business_id` filter. A single `channel('public:*')` with a `business_id`
    // filter but no `table:` cannot honour a filtered postgres_changes binding,
    // so the whole channel silently fails — no inbound events for ANY table.
    // Per-table channels also isolate a bad table to its own channel instead of
    // tearing down every subscription. The permanent subscribe-status callback
    // surfaces SUBSCRIBED / CHANNEL_ERROR / TIMED_OUT.
    //
    // `businesses` (no `business_id` column — its `id` IS the business id) is
    // handled by the separate channel below; `system_config` is global.
    for (final table in tables) {
      if (table == 'businesses' || table == 'system_config') continue;
      try {
        final channel =
            _client
                .channel('public:$table')
                .onPostgresChanges(
                  event: PostgresChangeEvent.all,
                  schema: 'public',
                  table: table,
                  filter: PostgresChangeFilter(
                    type: PostgresChangeFilterType.eq,
                    column: 'business_id',
                    value: businessId,
                  ),
                  callback: onChange,
                )
              ..subscribe((status, error) {
                if (status == RealtimeSubscribeStatus.channelError ||
                    status == RealtimeSubscribeStatus.timedOut) {
                  debugPrint(
                    '[CloudTransport] Realtime channel "$table" $status'
                    '${error != null ? ' — $error' : ''}',
                  );
                } else if (status == RealtimeSubscribeStatus.subscribed) {
                  debugPrint('[CloudTransport] Realtime subscribed: $table');
                }
              });
        _tableChannels.add(channel);
      } catch (e) {
        debugPrint('[CloudTransport] Realtime subscribe failed for "$table": $e');
      }
    }

    // Separate channel for `businesses` filtered by `id` (no business_id column).
    if (tables.contains('businesses')) {
      try {
        _businessesChannel =
            _client
                .channel('public:businesses')
                .onPostgresChanges(
                  event: PostgresChangeEvent.all,
                  schema: 'public',
                  table: 'businesses',
                  filter: PostgresChangeFilter(
                    type: PostgresChangeFilterType.eq,
                    column: 'id',
                    value: businessId,
                  ),
                  callback: onChange,
                )
              ..subscribe();
      } catch (e) {
        debugPrint('[CloudTransport] Businesses realtime subscribe failed: $e');
      }
    }
  }

  @override
  Future<void> stopRealtime() async {
    // Snapshot + clear the channel holders *synchronously* before the first
    // await, so `startRealtime`'s `isNotEmpty` guard reflects reality the moment
    // this yields control: a fire-and-forget stop immediately followed by a start
    // must not see the not-yet-removed channels and bail (the #93 resubscribe
    // race, where recreating mid-teardown created zero channels).
    final channels = List<RealtimeChannel>.from(_tableChannels);
    _tableChannels.clear();
    final businessesChannel = _businessesChannel;
    _businessesChannel = null;
    for (final channel in channels) {
      await _client.removeChannel(channel);
    }
    if (businessesChannel != null) {
      await _client.removeChannel(businessesChannel);
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
