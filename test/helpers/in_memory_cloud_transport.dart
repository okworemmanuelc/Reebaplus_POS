import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart'
    show PostgresChangePayload, PostgresChangeEvent, PostgrestException;

import 'package:reebaplus_pos/core/services/cloud_transport.dart';

/// A fully-featured in-memory [CloudTransport] for tests (ADR 0001).
///
/// Fidelity contract — the reason this is a *real* second adapter, not a stub:
///
/// * **Store.** `{table -> {id -> row}}`, seeded via [seed] and mutated by
///   [upsertRows] / [deleteRowsById].
/// * **`fetchTable` filtering** mirrors the real adapter: `business_id` filter
///   (or `id` for `businesses`), `since` `> last_updated_at` (with `businesses`
///   exempt), stable `(last_updated_at, id)` ordering, whole-slice return;
///   `system_config` is global/unfiltered.
/// * **Recording (spies).** [upsertedRows] / [deletedIds] / [rpcCalls] expose
///   what crossed the wire.
/// * **Fault injection.** [failNext] / [failRpc] make a call throw a
///   [PostgrestException] / [TimeoutException] on demand.
/// * **Identity.** [setAuthUserId] and [emitAuthEvent] drive the identity seam.
/// * **RPC stub.** [stubRpc] returns a canned response for a named RPC.
/// * **Realtime.** [startRealtime] captures the callback; [emitUpsert] /
///   [emitDelete] pump events synchronously.
class InMemoryCloudTransport implements CloudTransport {
  InMemoryCloudTransport({String? authUserId}) : _authUserId = authUserId;

  // ── STORE ──────────────────────────────────────────────────────────────────
  final Map<String, Map<String, Map<String, dynamic>>> _store = {};

  /// Seed cloud rows for [table] as if already present. Rows are keyed by `id`,
  /// falling back to `key` for the keyless global `system_config` table, then to
  /// a positional key so any shape can be stored.
  void seed(String table, List<Map<String, dynamic>> rows) {
    final t = _store.putIfAbsent(table, () => {});
    for (final row in rows) {
      final key = (row['id'] ?? row['key'] ?? '_${t.length}').toString();
      t[key] = Map<String, dynamic>.from(row);
    }
  }

  /// All currently-stored rows for [table].
  List<Map<String, dynamic>> rowsOf(String table) =>
      (_store[table]?.values.toList() ?? const [])
          .map((r) => Map<String, dynamic>.from(r))
          .toList();

  // ── RECORDING ────────────────────────────────────────────────────────────
  final List<({String table, List<Map<String, dynamic>> rows})> _upserts = [];
  final List<({String table, List<String> ids})> _deletes = [];
  final List<({String name, Map<String, dynamic> params})> _rpcCalls = [];

  /// Every [fetchTable] query, in call order (spy for pull-wiring assertions).
  final List<TableQuery> fetchQueries = [];

  /// Every [fetchRowsByIds] call, in order (spy for the A2 parent-fetch path).
  final List<({String table, List<String> ids})> fetchByIdsCalls = [];

  /// Rows upserted to [table] across all calls, flattened.
  List<Map<String, dynamic>> upsertedRows(String table) => [
    for (final u in _upserts)
      if (u.table == table) ...u.rows,
  ];

  /// Ids deleted from [table] across all calls, flattened.
  List<String> deletedIds(String table) => [
    for (final d in _deletes)
      if (d.table == table) ...d.ids,
  ];

  List<({String name, Map<String, dynamic> params})> get rpcCalls =>
      List.unmodifiable(_rpcCalls);

  // ── FAULT INJECTION ────────────────────────────────────────────────────────
  final Map<String, List<Object>> _tableFaults = {};
  final Map<String, Object> _rpcFaults = {};

  /// Make the next [count] push/pull calls that touch [table] throw [error]
  /// (a [PostgrestException] or [TimeoutException]).
  void failNext(String table, Object error, {int count = 1}) {
    _tableFaults.putIfAbsent(table, () => []).addAll(List.filled(count, error));
  }

  /// Make the next [callRpc] of [name] throw [error].
  void failRpc(String name, Object error) => _rpcFaults[name] = error;

  void _maybeThrowForTable(String table) {
    final q = _tableFaults[table];
    if (q != null && q.isNotEmpty) throw q.removeAt(0);
  }

  // ── RPC STUB ───────────────────────────────────────────────────────────────
  final Map<String, dynamic Function(Map<String, dynamic> params)> _rpcStubs =
      {};

  /// Register the response [handler] for RPC [name].
  void stubRpc(
    String name,
    dynamic Function(Map<String, dynamic> params) handler,
  ) => _rpcStubs[name] = handler;

  // ── PUSH ────────────────────────────────────────────────────────────────────
  @override
  Future<void> upsertRows(
    String table,
    List<Map<String, dynamic>> rows, {
    String? onConflict,
  }) async {
    _maybeThrowForTable(table);
    _upserts.add((
      table: table,
      rows: rows.map((r) => Map<String, dynamic>.from(r)).toList(),
    ));
    seed(table, rows);
  }

  @override
  Future<void> deleteRowsById(String table, List<String> ids) async {
    _maybeThrowForTable(table);
    _deletes.add((table: table, ids: List<String>.from(ids)));
    final t = _store[table];
    if (t != null) {
      for (final id in ids) {
        t.remove(id);
      }
    }
  }

  @override
  Future<dynamic> callRpc(String name, Map<String, dynamic> params) async {
    final fault = _rpcFaults.remove(name);
    if (fault != null) throw fault;
    _rpcCalls.add((name: name, params: Map<String, dynamic>.from(params)));
    final stub = _rpcStubs[name];
    return stub != null ? stub(params) : <String, dynamic>{};
  }

  // ── PULL ────────────────────────────────────────────────────────────────────
  @override
  Future<List<dynamic>> fetchTable(TableQuery query) async {
    fetchQueries.add(query);
    _maybeThrowForTable(query.table);
    final rows = _store[query.table]?.values.toList() ?? const [];
    final isGlobal = query.table == 'system_config';
    final isBusinesses = query.table == 'businesses';

    bool matches(Map<String, dynamic> row) {
      if (isGlobal) return true;
      final ownerColumn = isBusinesses ? 'id' : 'business_id';
      if (row[ownerColumn] != query.businessId) return false;
      // `businesses` is always fetched unconditionally (ignores `since`).
      if (query.since != null && !isBusinesses) {
        final lua = _parseTs(row['last_updated_at']);
        if (lua == null || !lua.isAfter(query.since!)) return false;
      }
      return true;
    }

    final result = rows
        .where(matches)
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
    if (!isGlobal) {
      result.sort((a, b) {
        final byTs = (_parseTs(a['last_updated_at']) ?? DateTime(0)).compareTo(
          _parseTs(b['last_updated_at']) ?? DateTime(0),
        );
        if (byTs != 0) return byTs;
        return '${a['id']}'.compareTo('${b['id']}');
      });
    }
    return result;
  }

  @override
  Future<List<dynamic>> fetchRowsByIds(
    String table,
    String businessId,
    List<String> ids,
  ) async {
    fetchByIdsCalls.add((table: table, ids: List<String>.from(ids)));
    _maybeThrowForTable(table);
    final t = _store[table];
    if (t == null) return const [];
    return [
      for (final id in ids)
        if (t[id] != null && t[id]!['business_id'] == businessId)
          Map<String, dynamic>.from(t[id]!),
    ];
  }

  // ── CONNECTION / EXISTENCE ─────────────────────────────────────────────────
  final Set<String> _deletedBusinesses = {};

  /// Mark [businessId] as having a `deleted_businesses` tombstone.
  void markBusinessDeleted(String businessId) =>
      _deletedBusinesses.add(businessId);

  @override
  Future<void> warmUp(String businessId) async {
    _maybeThrowForTable('businesses');
  }

  @override
  Future<bool> businessDeletedTombstoneExists(String businessId) async =>
      _deletedBusinesses.contains(businessId);

  // ── REALTIME ────────────────────────────────────────────────────────────────
  void Function(PostgresChangePayload)? _onChange;
  final List<String> subscribedTables = [];

  @override
  void startRealtime(
    Iterable<String> tables,
    String businessId, {
    required void Function(PostgresChangePayload) onChange,
  }) {
    _onChange = onChange;
    subscribedTables
      ..clear()
      ..addAll(tables);
  }

  @override
  Future<void> stopRealtime() async {
    _onChange = null;
    subscribedTables.clear();
  }

  /// Pump an upsert realtime event for [table]/[row] to the registered handler.
  void emitUpsert(String table, Map<String, dynamic> row) => _onChange?.call(
    PostgresChangePayload(
      schema: 'public',
      table: table,
      commitTimestamp: DateTime.now(),
      eventType: PostgresChangeEvent.update,
      newRecord: Map<String, dynamic>.from(row),
      oldRecord: const {},
      errors: null,
    ),
  );

  /// Pump a delete realtime event for [table]/[id] to the registered handler.
  void emitDelete(String table, String id) => _onChange?.call(
    PostgresChangePayload(
      schema: 'public',
      table: table,
      commitTimestamp: DateTime.now(),
      eventType: PostgresChangeEvent.delete,
      newRecord: const {},
      oldRecord: {'id': id},
      errors: null,
    ),
  );

  // ── IDENTITY ────────────────────────────────────────────────────────────────
  String? _authUserId;
  final StreamController<TransportAuthEvent> _authEvents =
      StreamController<TransportAuthEvent>.broadcast();

  void setAuthUserId(String? id) => _authUserId = id;

  /// Pump an auth-lifecycle event to [authEvents] listeners.
  void emitAuthEvent(TransportAuthEvent event) => _authEvents.add(event);

  @override
  String? get currentAuthUserId => _authUserId;

  @override
  Stream<TransportAuthEvent> get authEvents => _authEvents.stream;

  /// Close the auth controller (call in tearDown if a listener was attached).
  Future<void> dispose() => _authEvents.close();

  static DateTime? _parseTs(dynamic v) =>
      v is String ? DateTime.tryParse(v) : (v is DateTime ? v : null);
}
