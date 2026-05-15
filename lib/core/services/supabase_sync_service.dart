import 'dart:async';
import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Thrown by [SupabaseSyncService.flushSale] when a `domain:pos_record_sale`
/// envelope fails permanently at the server (insufficient_stock, FK / unique
/// violation, tenant mismatch). The local optimistic sale has already
/// committed; the caller is responsible for compensating (cancelling the
/// order, refunding stock, voiding ledgers) and surfacing to the UI.
class SaleSyncException implements Exception {
  final String orderId;
  final String errorMessage;
  const SaleSyncException({
    required this.orderId,
    required this.errorMessage,
  });
  @override
  String toString() => 'SaleSyncException(orderId=$orderId): $errorMessage';
}

/// Result of decoding the current Supabase session's access token.
/// `businessId` is non-null only when the JWT actually carries a
/// `business_id` claim (top-level or under `app_metadata` /
/// `user_metadata`). Used by the Sync Issues screen to confirm whether
/// JWT-claim-based RLS will see the right tenant.
class JwtClaimSnapshot {
  final bool hasSession;
  final String? businessId;
  final String? source; // 'top-level' | 'app_metadata' | 'user_metadata'
  final String? error;

  const JwtClaimSnapshot({
    required this.hasSession,
    this.businessId,
    this.source,
    this.error,
  });
}

class SupabaseSyncService {
  final AppDatabase _db;
  final SupabaseClient _supabase;
  RealtimeChannel? _realtimeChannel;
  RealtimeChannel? _businessesChannel;
  StreamSubscription<int>? _autoPushSub;
  StreamSubscription<AuthState>? _authStateSub;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _autoPushDebounce;
  Timer? _autoPushPeriodic;
  static const _autoPushPeriodicInterval = Duration(seconds: 30);
  bool _pushing = false;
  bool _loggedJwtClaimsThisSession = false;

  /// Connectivity signal driven by `Connectivity().onConnectivityChanged`.
  /// Surfaced to the UI so the drawer's "Syncing…" badge can flip to
  /// "Offline — N queued" when there's no network. Defaults to true so the
  /// app doesn't render an "offline" badge before the first connectivity
  /// event arrives.
  final ValueNotifier<bool> isOnline = ValueNotifier<bool>(true);

  SupabaseSyncService(this._db, this._supabase);

  /// Wired by AuthService to expose this device's active session id so
  /// the Realtime callback can recognise when its own row was revoked.
  String? Function()? currentSessionIdResolver;

  /// Wired by AuthService. Invoked when the Realtime callback observes
  /// the current session row being revoked by another device.
  VoidCallback? onCurrentSessionRevoked;

  /// Decodes the current access token's payload (no signature check — this is
  /// purely for local introspection) and reports whether `business_id` is
  /// present. Returns a snapshot the UI can render directly.
  static JwtClaimSnapshot inspectJwtClaims() {
    final session = Supabase.instance.client.auth.currentSession;
    if (session == null) {
      return const JwtClaimSnapshot(hasSession: false);
    }
    try {
      final parts = session.accessToken.split('.');
      if (parts.length != 3) {
        return const JwtClaimSnapshot(hasSession: true, error: 'malformed JWT');
      }
      // base64url-decode the payload segment, padding as needed.
      var payload = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      switch (payload.length % 4) {
        case 2:
          payload += '==';
          break;
        case 3:
          payload += '=';
          break;
      }
      final json =
          jsonDecode(utf8.decode(base64.decode(payload)))
              as Map<String, dynamic>;

      String? toStringVal(dynamic v) {
        if (v == null) return null;
        return v.toString();
      }

      final top = toStringVal(json['business_id']);
      if (top != null) {
        return JwtClaimSnapshot(
          hasSession: true,
          businessId: top,
          source: 'top-level',
        );
      }
      final appMeta = json['app_metadata'];
      if (appMeta is Map) {
        final v = toStringVal(appMeta['business_id']);
        if (v != null) {
          return JwtClaimSnapshot(
            hasSession: true,
            businessId: v,
            source: 'app_metadata',
          );
        }
      }
      final userMeta = json['user_metadata'];
      if (userMeta is Map) {
        final v = toStringVal(userMeta['business_id']);
        if (v != null) {
          return JwtClaimSnapshot(
            hasSession: true,
            businessId: v,
            source: 'user_metadata',
          );
        }
      }
      return const JwtClaimSnapshot(hasSession: true);
    } catch (e) {
      return JwtClaimSnapshot(hasSession: true, error: e.toString());
    }
  }

  // Per migration 0001_initial.sql line 12, every synced table uses
  // `last_updated_at` (timestamptz, NOT NULL DEFAULT now()) and the
  // `bump_last_updated_at` trigger fires on every UPDATE. There is no
  // `updated_at` column anywhere in the cloud schema, so we send
  // `last_updated_at` as-is on push and filter by it on pull.

  /// Tables whose rows are referenced by FKs from other tables. They must be
  /// pushed before any child rows in the same batch, otherwise the child push
  /// fails with a 23503 FK violation. Lower number = pushed first.
  static const Map<String, int> _tablePushPriority = {
    'businesses': 0,
    'profiles': 1,
    // users must precede every child that FK-references it: stock_adjustments
    // .performed_by, stock_transactions.performed_by, sessions.user_id, and
    // the children created server-side by domain RPCs (pos_create_product,
    // pos_inventory_delta, pos_record_sale).
    'users': 1,
    'warehouses': 2,
    'manufacturers': 3,
    'crate_groups': 3,
    'categories': 4,
    'suppliers': 5,
    'products': 10,
    'customers': 11,
    'inventory': 12,
    'customer_wallets': 20,
    'orders': 30,
    'order_items': 31,
    'wallet_transactions': 32,
    'crate_ledger': 33,
    'manufacturer_crate_balances': 34,
    'system_config': 50,
  };

  int _priorityFor(String actionType) {
    final table = actionType.split(':').first;
    return _tablePushPriority[table] ?? 100;
  }

  /// Per-table whitelist of cloud-pushable columns. Any payload key NOT
  /// in the table's whitelist is dropped before push. Fail-closed: a new
  /// local-only column added to Drift won't leak to the cloud unless
  /// it's explicitly added here.
  ///
  /// Only tables that diverge from cloud (auth/secret material, local-
  /// only columns) are enumerated. Other synced tables fall through with
  /// no scrubbing — their Drift column set IS the cloud column set, and
  /// enumerating them adds maintenance burden with no leak surface.
  /// Convert incrementally as new divergence appears.
  static const _pushableColumns = <String, Set<String>>{
    'profiles': {
      'id',
      'business_id',
      'role',
      'name',
      'is_active',
      'created_at',
      'last_updated_at',
    },
    'users': {
      'id',
      'business_id',
      'auth_user_id',
      'name',
      'phone',
      'email',
      'role',
      'warehouse_id',
      'status',
      'joined_at',
      'last_notification_sent_at',
      'is_deleted',
      'created_at',
      'last_updated_at',
    },
    'sessions': {
      'id',
      'business_id',
      'user_id',
      'expires_at',
      'revoked_at',
      'created_at',
      'last_updated_at',
      // NOTE: token, ip_address, user_agent intentionally absent —
      // local secret material, never pushed.
    },
    'businesses': {
      'id',
      'name',
      'type',
      'phone',
      'email',
      'logo_url',
      'owner_id',
      'onboarding_complete',
      'created_at',
      'last_updated_at',
      // NOTE: timezone is local-only (cloud schema doesn't have it).
    },
  };

  /// Translates a locally-built payload into the column names the cloud schema
  /// actually exposes. Local Drift uses `lastUpdatedAt`; cloud uses `updated_at`
  /// (or no equivalent). Products store the manufacturer display string in
  /// `manufacturer` locally but the cloud column is `manufacturer_name`.
  Map<String, dynamic> _normalizePayloadForCloud(
    String table,
    Map<String, dynamic> payload,
  ) {
    return scrubForTesting(table, payload);
  }

  /// Same as `_normalizePayloadForCloud`, exposed as a static so unit
  /// tests can exercise the whitelist without standing up a real
  /// Supabase client. The actual scrubbing logic lives here so the
  /// instance method and tests can never drift apart.
  @visibleForTesting
  static Map<String, dynamic> scrubForTesting(
    String table,
    Map<String, dynamic> payload,
  ) {
    final out = Map<String, dynamic>.from(payload);
    final whitelist = _pushableColumns[table];
    if (whitelist != null) {
      out.removeWhere((k, _) => !whitelist.contains(k));
    }
    return out;
  }

  /// Pushes all pending local changes to Supabase.
  Future<void> pushPending() async {
    // Without an authenticated session the server sees auth.uid() as NULL,
    // so RLS denies every insert. Skip rather than burn `attempts` and rack
    // up false negatives — startAutoPush retriggers as soon as sign-in lands.
    if (_supabase.auth.currentUser == null) {
      debugPrint('[SyncService] Skipping push: no auth session.');
      return;
    }

    if (!_loggedJwtClaimsThisSession) {
      _loggedJwtClaimsThisSession = true;
      final claims = inspectJwtClaims();
      // Informational only. This project's RLS uses auth.uid() → profiles
      // via get_user_business_id(); JWT claims are not consulted. See
      // supabase/rls_snapshot.md.
      if (claims.businessId != null) {
        debugPrint(
          '[SyncService] JWT business_id=${claims.businessId} '
          '(via ${claims.source}, informational — RLS uses profiles join).',
        );
      } else if (claims.error != null) {
        debugPrint('[SyncService] JWT decode failed: ${claims.error}');
      } else {
        debugPrint(
          '[SyncService] JWT has no business_id claim '
          '(expected — RLS resolves business_id via profiles join).',
        );
      }
    }

    // Filter the queue to the current session's tenant. The v36 schema makes
    // every sync_queue row carry a businessId; the resolver hung off
    // AppDatabase carries the session's businessId after AuthService wires it
    // up at login. If still null here we cannot safely push (would risk
    // pushing another tenant's row), so bail.
    final sessionBusinessId = _db.currentBusinessId;
    if (sessionBusinessId == null) {
      debugPrint('[SyncService] Skipping push: no session businessId.');
      return;
    }

    // Pass businessId explicitly so getPendingItems doesn't have to consult
    // the resolver. Defense-in-depth — keeps the push path safe even if the
    // resolver becomes null between this guard and the query (it shouldn't,
    // but the cost of the explicit arg is zero).
    final rawItems = await _db.syncDao.getPendingItems(
      limit: 200,
      businessId: sessionBusinessId,
    );
    if (rawItems.isEmpty) return;

    // Coalesce duplicates: a burst of writes to the same row (e.g. five
    // inventory adjustments to the same product before the queue drains)
    // only needs the *latest* payload — earlier entries are stale. Keyed by
    // (actionType, payload.id). Earlier rows are immediately marked done
    // since the later payload subsumes them.
    final pendingItems = <SyncQueueData>[];
    final superseded = <String>[];
    final latestByKey = <String, SyncQueueData>{};
    for (final item in rawItems) {
      Map<String, dynamic> payload;
      try {
        payload = jsonDecode(item.payload) as Map<String, dynamic>;
      } catch (_) {
        // Undecodable payloads still need to drain through the failure path.
        pendingItems.add(item);
        continue;
      }
      final rowId = payload['id'];
      if (rowId is! String) {
        pendingItems.add(item);
        continue;
      }
      final key = '${item.actionType}|$rowId';
      final prior = latestByKey[key];
      if (prior == null || item.createdAt.isAfter(prior.createdAt)) {
        if (prior != null) superseded.add(prior.id);
        latestByKey[key] = item;
      } else {
        superseded.add(item.id);
      }
    }
    pendingItems.addAll(latestByKey.values);
    if (superseded.isNotEmpty) {
      await _db.syncDao.markDoneBatch(superseded);
    }
    if (pendingItems.isEmpty) return;

    // Partition off domain envelopes: each `domain:<rpc>` row is an atomic
    // multi-table call routed through Postgres functions (see migration
    // 0006_domain_rpcs.sql). They are not batched against each other — each
    // one is an independent transaction — so they bypass the per-table
    // grouping path entirely. Drained AFTER the table-batch loop so that any
    // freshly enqueued parent rows (most importantly `users`, referenced by
    // stock_adjustments.performed_by) are already in the cloud before the
    // RPC's child inserts run; otherwise the server returns 23503 and
    // `_pushDomainItems` marks the envelope permanently failed.
    final domainItems = <SyncQueueData>[];
    final tableItems = <SyncQueueData>[];
    for (final item in pendingItems) {
      if (item.actionType.startsWith('domain:')) {
        domainItems.add(item);
      } else {
        tableItems.add(item);
      }
    }

    // Group items by their action signature (table + action + optional
    // conflict target). One Supabase round-trip per group, batched as an
    // array. PostgREST's array-upsert preserves partial-row semantics: only
    // columns present in each payload are updated, so partial Drift
    // Companions (e.g. markCompleted writing only {status, completed_at})
    // don't NULL-out untouched columns.
    final groups = <_PushGroup, List<SyncQueueData>>{};
    for (final item in tableItems) {
      final parts = item.actionType.split(':');
      if (parts.length < 2) continue;
      final group = _PushGroup(
        table: parts[0],
        action: parts[1],
        conflictTarget: parts.length > 2 ? parts[2] : null,
      );
      groups.putIfAbsent(group, () => []).add(item);
    }

    // Order groups by FK priority so parent tables (warehouses, businesses,
    // …) are pushed before children. Within a priority bucket, order is
    // arbitrary — children share their parent's priority bucket only if
    // they truly don't depend on each other.
    final orderedGroups = groups.keys.toList()
      ..sort(
        (a, b) => _priorityFor('${a.table}:${a.action}')
            .compareTo(_priorityFor('${b.table}:${b.action}')),
      );

    debugPrint(
      '[SyncService] Pushing ${pendingItems.length} items in '
      '${orderedGroups.length} batched calls...',
    );

    for (final group in orderedGroups) {
      final items = groups[group]!;
      final ids = items.map((i) => i.id).toList();
      await _db.syncDao.markInProgressBatch(ids);

      // Validate every payload's tenant. Any tenant-mismatch in the group
      // is a programming error; hard-fail just those items and continue.
      final validPayloads = <Map<String, dynamic>>[];
      final validIds = <String>[];
      final mismatchedIds = <String>[];
      for (final item in items) {
        try {
          final raw = jsonDecode(item.payload) as Map<String, dynamic>;
          final pid = raw['business_id'];
          if (item.businessId != sessionBusinessId ||
              pid == null ||
              (pid is String && pid != sessionBusinessId)) {
            mismatchedIds.add(item.id);
            continue;
          }
          validPayloads.add(_normalizePayloadForCloud(group.table, raw));
          validIds.add(item.id);
        } catch (e) {
          await _db.syncDao.markFailed(item.id, 'decode_error: $e');
        }
      }
      if (mismatchedIds.isNotEmpty) {
        for (final id in mismatchedIds) {
          await _db.syncDao
              .markFailed(id, 'missing_business_id', permanent: true);
        }
      }
      if (validPayloads.isEmpty) continue;

      debugPrint(
        '[SyncService] push ${group.action} ${group.table}: '
        '${validIds.length} ids=${validIds.take(3).join(",")}'
        '${validIds.length > 3 ? "…" : ""}',
      );

      try {
        if (group.action == 'insert' ||
            group.action == 'update' ||
            group.action == 'upsert') {
          if (group.conflictTarget != null) {
            await _supabase
                .from(group.table)
                .upsert(validPayloads, onConflict: group.conflictTarget!);
          } else {
            await _supabase.from(group.table).upsert(validPayloads);
          }
        } else if (group.action == 'delete') {
          // Hard delete only used for tombstones the cloud needs to forget.
          // Soft delete (is_deleted=true) goes through the upsert path above.
          final deleteIds = validPayloads
              .map((p) => p['id'] as String?)
              .whereType<String>()
              .toList();
          if (deleteIds.isNotEmpty) {
            await _supabase
                .from(group.table)
                .delete()
                .inFilter('id', deleteIds);
          }
        }
        await _db.syncDao.markDoneBatch(validIds);
      } catch (e) {
        final code = e is PostgrestException ? (e.code ?? '?') : '?';
        debugPrint(
          '[SyncService] Batch push failed for ${group.table}:${group.action} '
          '(${validIds.length} items, http=$code): $e',
        );
        // On batch failure, mark every item failed individually so the
        // existing exponential-backoff per-row state machine still applies.
        for (final id in validIds) {
          await _db.syncDao.markFailed(id, e.toString());
        }
      }
    }

    // Now that parent-table rows are in the cloud, drain domain envelopes.
    // Their server-side RPCs FK-reference rows we just pushed (e.g.
    // pos_create_product → stock_adjustments.performed_by → users.id).
    if (domainItems.isNotEmpty) {
      await _pushDomainItems(domainItems, sessionBusinessId);
    }

    // If the raw select hit the page limit, more is waiting — drain in the
    // next tick rather than recursing (avoids stack growth on huge backlogs).
    if (rawItems.length == 200) {
      Future.microtask(pushPending);
    }
  }

  /// Pushes one outbox row per call to a Postgres RPC defined in
  /// 0006_domain_rpcs.sql. Used for atomic multi-table actions
  /// (`domain:pos_record_sale`, `domain:pos_inventory_delta`,
  /// `domain:pos_create_product`) where the server applies the entire
  /// business action in a single transaction. On success, applies the
  /// server's authoritative response to the local cache without
  /// re-enqueueing — this and `_restoreTableData` (for pull/realtime) are
  /// the only legitimate paths that write to a synced table without
  /// going through `enqueueUpsert`.
  Future<void> _pushDomainItems(
    List<SyncQueueData> items,
    String sessionBusinessId,
  ) async {
    for (final item in items) {
      await _db.syncDao.markInProgressBatch([item.id]);

      Map<String, dynamic> payload;
      try {
        payload = jsonDecode(item.payload) as Map<String, dynamic>;
      } catch (e) {
        await _db.syncDao
            .markFailed(item.id, 'decode_error: $e', permanent: true);
        continue;
      }

      // Tenant guard. The RPC also checks server-side, but failing locally
      // saves a round-trip and avoids a misleading 'tenant_mismatch' RPC
      // error in the Sync Issues UI.
      final payloadBiz = payload['p_business_id'];
      if (item.businessId != sessionBusinessId ||
          payloadBiz is! String ||
          payloadBiz != sessionBusinessId) {
        await _db.syncDao
            .markFailed(item.id, 'missing_business_id', permanent: true);
        continue;
      }

      final rpcName = item.actionType.substring('domain:'.length);
      try {
        final response = await _supabase.rpc(rpcName, params: payload);
        await _applyDomainResponse(rpcName, response);
        await _db.syncDao.markDone(item.id);
        final replayed =
            response is Map && response['replayed'] == true;
        debugPrint(
          '[SyncService] domain $rpcName ok (replayed=$replayed)',
        );
      } on PostgrestException catch (e) {
        // §6.8 failure classification:
        //   - 23503 (foreign_key_violation) → FK-deferred: parent likely
        //     arrives on the next pull; longer backoff, capped retries.
        //   - P0001 / other 23xxx / insufficient_privilege /
        //     invalid_parameter_value → permanent → orphan auto-move.
        //   - everything else → transient → standard exp backoff.
        final code = e.code ?? '';
        final isFkViolation = code == '23503';
        final isPermanent = !isFkViolation &&
            (code == 'P0001' ||
                code.startsWith('23') ||
                code == 'insufficient_privilege' ||
                code == 'invalid_parameter_value');
        debugPrint(
          '[SyncService] Domain RPC $rpcName failed '
          '(code=$code, permanent=$isPermanent, fk_deferred=$isFkViolation): '
          '${e.message}',
        );
        await _db.syncDao.markFailed(
          item.id,
          'pg_$code: ${e.message}',
          permanent: isPermanent,
          fkDeferred: isFkViolation,
        );
      } catch (e) {
        debugPrint('[SyncService] Domain RPC $rpcName transient error: $e');
        await _db.syncDao.markFailed(item.id, e.toString());
      }
    }
  }

  /// Reconciles the local cache with the server's authoritative response
  /// from a domain RPC. Bypasses `enqueueUpsert` because the server already
  /// has the truth — pushing it back would be a no-op round trip.
  /// Public entry into the same canonical-row application logic the queue
  /// dispatch uses. Lets in-band Edge Function flows (notably redeem-invite,
  /// which returns {user, membership, invite}) seed local Drift without
  /// waiting for a snapshot pull. The rpcName is passed through unchanged
  /// so future routing logic can branch per RPC if needed.
  Future<void> applyServerResponse(String rpcName, dynamic response) =>
      _applyDomainResponse(rpcName, response);

  Future<void> _applyDomainResponse(
    String rpcName,
    dynamic response,
  ) async {
    if (response is! Map) return;
    final map = Map<String, dynamic>.from(response);

    await _db.transaction(() async {
      // Inventory cache: pos_record_sale and pos_inventory_delta both return
      // an `inventory_after` array of {product_id, warehouse_id, quantity,
      // last_updated_at}. The Drift `bump_inventory_last_updated_at` trigger
      // only fires when OLD.last_updated_at IS NEW.last_updated_at; we
      // explicitly write the server's value, so the trigger is a no-op and
      // the local row matches the cloud exactly.
      final invAfter = map['inventory_after'];
      if (invAfter is List) {
        for (final raw in invAfter) {
          if (raw is! Map) continue;
          final productId = raw['product_id'] as String?;
          final warehouseId = raw['warehouse_id'] as String?;
          final quantity = raw['quantity'];
          final luaStr = raw['last_updated_at'] as String?;
          if (productId == null || warehouseId == null || quantity is! int) {
            continue;
          }
          final lua = luaStr != null ? DateTime.tryParse(luaStr) : null;
          await (_db.update(_db.inventory)
                ..where((t) =>
                    t.productId.equals(productId) &
                    t.warehouseId.equals(warehouseId)))
              .write(InventoryCompanion(
            quantity: Value(quantity),
            lastUpdatedAt: Value(lua ?? DateTime.now()),
          ));
        }
      }

      // pos_record_sale: bump the local order's last_updated_at to the
      // server's value so the next pull's incremental cursor doesn't re-fetch
      // it on every sync.
      final orderId = map['order_id'] as String?;
      final orderLua = map['order_last_updated_at'] as String?;
      if (orderId != null && orderLua != null) {
        final parsed = DateTime.tryParse(orderLua);
        if (parsed != null) {
          await (_db.update(_db.orders)..where((t) => t.id.equals(orderId)))
              .write(OrdersCompanion(lastUpdatedAt: Value(parsed)));
        }
      }

      // pos_create_product: same for products.
      final productId = map['product_id'] as String?;
      final productLua = map['product_last_updated_at'] as String?;
      if (productId != null && productLua != null) {
        final parsed = DateTime.tryParse(productLua);
        if (parsed != null) {
          await (_db.update(_db.products)..where((t) => t.id.equals(productId)))
              .write(ProductsCompanion(lastUpdatedAt: Value(parsed)));
        }
      }

      // pos_cancel_order (v2): server is the sole writer of compensating
      // ledger rows (their ids are gen_random_uuid() server-side), so the
      // client did NOT mirror them locally on cancel. The response carries
      // the full canonical rows; route each array through _restoreTableData
      // so local catches up immediately. The `order` Map handler covers
      // the cancel header (v2 shape: full row, vs v1 sale's flat
      // `order_id`/`order_last_updated_at`).
      final orderRow = map['order'];
      if (orderRow is Map) {
        await _restoreTableData('orders', [Map<String, dynamic>.from(orderRow)]);
      }
      // pos_create_product_v2: server returns the canonical product row.
      // Route through _restoreTableData so the cloud's `last_updated_at`
      // (and any server-canonicalised fields) overwrite the local
      // pre-insert. Same pattern as `order` above.
      final productRow = map['product'];
      if (productRow is Map) {
        await _restoreTableData(
            'products', [Map<String, dynamic>.from(productRow)]);
      }
      // pos_record_sale_v2: server returns the canonical order_items array.
      // The thin-local DAO doesn't pre-insert items; this is the sole
      // local writer for them.
      final orderItems = map['order_items'];
      if (orderItems is List && orderItems.isNotEmpty) {
        await _restoreTableData(
            'order_items', List<dynamic>.from(orderItems));
      }

      final stockTxns = map['stock_transactions'];
      if (stockTxns is List && stockTxns.isNotEmpty) {
        await _restoreTableData(
            'stock_transactions', List<dynamic>.from(stockTxns));
      }
      // pos_inventory_delta_v2 also returns server-minted stock_adjustments
      // for movement_type='adjustment' rows; route through the standard
      // restore path so local matches cloud's gen_random_uuid() ids.
      final stockAdjustments = map['stock_adjustments'];
      if (stockAdjustments is List && stockAdjustments.isNotEmpty) {
        await _restoreTableData(
            'stock_adjustments', List<dynamic>.from(stockAdjustments));
      }
      final voidedPayments = map['voided_payments'];
      if (voidedPayments is List && voidedPayments.isNotEmpty) {
        await _restoreTableData(
            'payment_transactions', List<dynamic>.from(voidedPayments));
      }
      final refundPayments = map['refund_payments'];
      if (refundPayments is List && refundPayments.isNotEmpty) {
        await _restoreTableData(
            'payment_transactions', List<dynamic>.from(refundPayments));
      }
      final walletCompens = map['wallet_compensations'];
      if (walletCompens is List && walletCompens.isNotEmpty) {
        await _restoreTableData(
            'wallet_transactions', List<dynamic>.from(walletCompens));
      }

      // accept_invite (staff onboarding §1): server returns {user, membership,
      // invite} — three canonical rows the client seeds locally so the freshly
      // onboarded staff member sees correct state without waiting for a pull.
      final userRow = map['user'];
      if (userRow is Map) {
        await _restoreTableData(
            'users', [Map<String, dynamic>.from(userRow)]);
      }
      final membershipRow = map['membership'];
      if (membershipRow is Map) {
        await _restoreTableData(
            'business_members', [Map<String, dynamic>.from(membershipRow)]);
      }
      final inviteRow = map['invite'];
      if (inviteRow is Map) {
        await _restoreTableData(
            'invites', [Map<String, dynamic>.from(inviteRow)]);
      }

      // pos_create_customer (v2): server returns the canonical customer +
      // customer_wallet rows. Mirror their last_updated_at locally so the
      // next pull's incremental cursor doesn't re-fetch them.
      final customer = map['customer'];
      if (customer is Map) {
        final cid = customer['id'] as String?;
        final lua = customer['last_updated_at'] as String?;
        if (cid != null && lua != null) {
          final parsed = DateTime.tryParse(lua);
          if (parsed != null) {
            await (_db.update(_db.customers)
                  ..where((t) => t.id.equals(cid)))
                .write(CustomersCompanion(lastUpdatedAt: Value(parsed)));
          }
        }
      }
      final wallet = map['customer_wallet'];
      if (wallet is Map) {
        final wid = wallet['id'] as String?;
        final lua = wallet['last_updated_at'] as String?;
        if (wid != null && lua != null) {
          final parsed = DateTime.tryParse(lua);
          if (parsed != null) {
            await (_db.update(_db.customerWallets)
                  ..where((t) => t.id.equals(wid)))
                .write(CustomerWalletsCompanion(lastUpdatedAt: Value(parsed)));
          }
        }
      }

      // pos_wallet_topup / pos_record_sale_v2: server returns the
      // canonical wallet_transactions and payment_transactions rows.
      // Route through _restoreTableData so the row lands locally even
      // when the client didn't pre-insert it (sale v2 is thin-local —
      // server mints the ids); for batches that DID pre-insert (topup),
      // the upsert overwrites with the cloud's authoritative row, which
      // is the right behaviour anyway.
      final walletTxn = map['wallet_transaction'];
      if (walletTxn is Map) {
        await _restoreTableData(
            'wallet_transactions', [Map<String, dynamic>.from(walletTxn)]);
      }
      final paymentTxn = map['payment_transaction'];
      if (paymentTxn is Map) {
        await _restoreTableData(
            'payment_transactions', [Map<String, dynamic>.from(paymentTxn)]);
      }

      // pos_record_expense (v2): server returns canonical expense and
      // activity_log rows (the payment_transaction key is handled by the
      // wallet_topup branch above — same shape).
      final expense = map['expense'];
      if (expense is Map) {
        final id = expense['id'] as String?;
        final lua = expense['last_updated_at'] as String?;
        if (id != null && lua != null) {
          final parsed = DateTime.tryParse(lua);
          if (parsed != null) {
            await (_db.update(_db.expenses)..where((t) => t.id.equals(id)))
                .write(ExpensesCompanion(lastUpdatedAt: Value(parsed)));
          }
        }
      }
      final activityLog = map['activity_log'];
      if (activityLog is Map) {
        final id = activityLog['id'] as String?;
        final lua = activityLog['last_updated_at'] as String?;
        if (id != null && lua != null) {
          final parsed = DateTime.tryParse(lua);
          if (parsed != null) {
            await (_db.update(_db.activityLogs)..where((t) => t.id.equals(id)))
                .write(ActivityLogsCompanion(lastUpdatedAt: Value(parsed)));
          }
        }
      }

      // pos_void_wallet_txn (v2): server returns the now-voided original
      // and the new compensating wallet_transactions row. Mirror their
      // last_updated_at locally so the next pull's cursor doesn't re-fetch.
      final voidedTxn = map['voided_transaction'];
      if (voidedTxn is Map) {
        final id = voidedTxn['id'] as String?;
        final lua = voidedTxn['last_updated_at'] as String?;
        if (id != null && lua != null) {
          final parsed = DateTime.tryParse(lua);
          if (parsed != null) {
            await (_db.update(_db.walletTransactions)
                  ..where((t) => t.id.equals(id)))
                .write(WalletTransactionsCompanion(
              lastUpdatedAt: Value(parsed),
            ));
          }
        }
      }
      final compensatingTxn = map['compensating_transaction'];
      if (compensatingTxn is Map) {
        final id = compensatingTxn['id'] as String?;
        final lua = compensatingTxn['last_updated_at'] as String?;
        if (id != null && lua != null) {
          final parsed = DateTime.tryParse(lua);
          if (parsed != null) {
            await (_db.update(_db.walletTransactions)
                  ..where((t) => t.id.equals(id)))
                .write(WalletTransactionsCompanion(
              lastUpdatedAt: Value(parsed),
            ));
          }
        }
      }

      // pos_approve_crate_return (v2): server returns the now-approved
      // pending_crate_returns row. (crate_ledger_row + balance_row handlers
      // below are shared with pos_record_crate_return.)
      final pendingReturn = map['pending_return'];
      if (pendingReturn is Map) {
        final id = pendingReturn['id'] as String?;
        final lua = pendingReturn['last_updated_at'] as String?;
        if (id != null && lua != null) {
          final parsed = DateTime.tryParse(lua);
          if (parsed != null) {
            await (_db.update(_db.pendingCrateReturns)
                  ..where((t) => t.id.equals(id)))
                .write(PendingCrateReturnsCompanion(
              lastUpdatedAt: Value(parsed),
            ));
          }
        }
      }

      // pos_record_crate_return (v2): server returns the canonical
      // crate_ledger row plus the cache balance row (customer or
      // manufacturer side, distinguished by which owner_id is set). The
      // cache row is looked up by composite — local uses its own UuidV7
      // for the cache id while the server uses gen_random_uuid(), so the
      // two ids never match.
      final crateLedgerRow = map['crate_ledger_row'];
      if (crateLedgerRow is Map) {
        final id = crateLedgerRow['id'] as String?;
        final lua = crateLedgerRow['last_updated_at'] as String?;
        if (id != null && lua != null) {
          final parsed = DateTime.tryParse(lua);
          if (parsed != null) {
            await (_db.update(_db.crateLedger)
                  ..where((t) => t.id.equals(id)))
                .write(CrateLedgerCompanion(lastUpdatedAt: Value(parsed)));
          }
        }
      }
      final balanceRow = map['balance_row'];
      if (balanceRow is Map) {
        final balance = balanceRow['balance'];
        final lua = balanceRow['last_updated_at'] as String?;
        final parsed = lua != null ? DateTime.tryParse(lua) : null;
        final crateGroupId = balanceRow['crate_group_id'] as String?;
        final businessIdStr = balanceRow['business_id'] as String?;
        if (balance is int &&
            parsed != null &&
            crateGroupId != null &&
            businessIdStr != null) {
          final customerId = balanceRow['customer_id'] as String?;
          final manufacturerId = balanceRow['manufacturer_id'] as String?;
          if (customerId != null) {
            await (_db.update(_db.customerCrateBalances)
                  ..where((t) =>
                      t.businessId.equals(businessIdStr) &
                      t.customerId.equals(customerId) &
                      t.crateGroupId.equals(crateGroupId)))
                .write(CustomerCrateBalancesCompanion(
              balance: Value(balance),
              lastUpdatedAt: Value(parsed),
            ));
          } else if (manufacturerId != null) {
            await (_db.update(_db.manufacturerCrateBalances)
                  ..where((t) =>
                      t.businessId.equals(businessIdStr) &
                      t.manufacturerId.equals(manufacturerId) &
                      t.crateGroupId.equals(crateGroupId)))
                .write(ManufacturerCrateBalancesCompanion(
              balance: Value(balance),
              lastUpdatedAt: Value(parsed),
            ));
          }
        }
      }
    });
  }

  /// Synchronously pushes the pending `domain:pos_record_sale` envelope for
  /// the given order. Used by the checkout flow when `isOnline = true` to
  /// surface server-side errors (insufficient_stock, FK/unique violations)
  /// to the user *before* the receipt prints.
  ///
  /// Throws [SaleSyncException] on permanent failure (P0001 / 23xxx).
  /// Returns silently when:
  ///   - the queue row is absent (already pushed by background drain), OR
  ///   - the device is offline (the row stays pending and will drain later), OR
  ///   - the RPC fails with a transient error (queued for backoff retry).
  Future<void> flushSale(String orderId) async {
    if (_supabase.auth.currentUser == null) return;
    if (!isOnline.value) return;
    final sessionBusinessId = _db.currentBusinessId;
    if (sessionBusinessId == null) return;

    // The v2 dispatch (`feature.domain_rpcs_v2.record_sale`) emits
    // `domain:pos_record_sale_v2` with a flat `p_order_id`. The v1
    // dispatch emitted `domain:pos_record_sale` with nested
    // `$.p_order.id`. Both shapes coexist during the per-business
    // rollout — try v2 first, fall back to v1 so flushSale stays
    // correct on either path.
    SyncQueueData? item = await _db.syncDao.findPendingDomainItem(
      'domain:pos_record_sale_v2',
      payloadIdPath: r'$.p_order_id',
      idValue: orderId,
    );
    item ??= await _db.syncDao.findPendingDomainItem(
      'domain:pos_record_sale',
      payloadIdPath: r'$.p_order.id',
      idValue: orderId,
    );
    if (item == null) return;

    await _pushDomainItems([item], sessionBusinessId);

    // §6.8 auto-archive moves permanent failures (P0001 / 23xxx) into
    // `sync_queue_orphans` and deletes them from `sync_queue`. Check
    // both surfaces so a terminal failure on the foreground sale path
    // surfaces to the user instead of silently printing a receipt for
    // a sale the cloud rejected.
    final updated = await _db.syncDao.getQueueItem(item.id);
    if (updated?.status == 'failed') {
      throw SaleSyncException(
        orderId: orderId,
        errorMessage: updated?.errorMessage ?? 'unknown error',
      );
    }
    if (updated == null) {
      final orphan = await _db.syncDao.findOrphanByOriginalId(item.id);
      if (orphan != null) {
        throw SaleSyncException(
          orderId: orderId,
          errorMessage: orphan.reason,
        );
      }
    }
  }

  /// Orchestrates a two-way sync: push local changes, then pull cloud updates.
  Future<void> syncAll(String businessId) async {
    debugPrint(
      '[SyncService] Starting two-way sync for business $businessId...',
    );
    try {
      await pushPending();
      await pullChanges(businessId);
      debugPrint('[SyncService] Two-way sync completed successfully.');
    } catch (e) {
      debugPrint('[SyncService] Sync failed: $e');
      rethrow;
    }
  }

  /// Pull-only half of [syncAll]: incremental pull anchored on the per-
  /// business `last_sync_timestamp::<businessId>` cursor in SharedPreferences.
  ///
  /// Safe to call before a session is fully bound (i.e. before
  /// [AuthService.setCurrentUser] has flipped `value`), because every code
  /// path it touches accepts `businessId` as an explicit argument or routes
  /// through `_restoreTableData` (the §5-exempt restoration path). That makes
  /// it the right entry point for [AuthService.syncOnLogin], which runs at
  /// login boundaries where the resolver still returns null.
  Future<void> pullChanges(String businessId) async {
    final prefs = await SharedPreferences.getInstance();
    // Per-business key: a wiped DB or a device that has switched businesses
    // must not inherit the timestamp from a different tenant, otherwise
    // incremental pulls skip rows that haven't been touched in the cloud
    // since the unrelated last sync.
    final key = 'last_sync_timestamp::$businessId';
    final lastSyncStr = prefs.getString(key);
    DateTime? since;
    if (lastSyncStr != null) {
      since = DateTime.tryParse(lastSyncStr);
    }

    await pullInitialData(businessId, since: since);

    await prefs.setString(key, DateTime.now().toUtc().toIso8601String());
  }

  /// Tables fed into `_restoreTableData` after a pull, in FK-safe order.
  /// `crates` removed — cloud schema has only `crate_groups`.
  static const _pullOrder = [
    'businesses',
    'crate_groups',
    'manufacturers',
    'warehouses',
    'users',
    'profiles',
    'categories',
    'suppliers',
    'products',
    'inventory',
    'customers',
    'orders',
    'order_items',
    'purchases',
    'purchase_items',
    'expense_categories',
    'expenses',
    'customer_crate_balances',
    'delivery_receipts',
    'drivers',
    'stock_transfers',
    'stock_adjustments',
    'activity_logs',
    'notifications',
    'stock_transactions',
    'customer_wallets',
    'wallet_transactions',
    'saved_carts',
    'pending_crate_returns',
    'invites',
    'manufacturer_crate_balances',
    'crate_ledger',
    'system_config',
    'price_lists',
    'payment_transactions',
    'sessions',
    'settings',
  ];

  /// Pulls data for the current business from Supabase and populates the local DB.
  /// If [since] is provided, performs an incremental pull.
  ///
  /// Fast path: a single `pos_pull_snapshot` RPC returns every table's rows
  /// in one round-trip. Falls back to the per-table PostgREST path if the
  /// RPC isn't deployed yet (the migration in 0005_sync_rpcs.sql may not be
  /// applied to every environment).
  Future<void> pullInitialData(String businessId, {DateTime? since}) async {
    // Force a full sync if the business is not found locally.
    final localBusiness = await (_db.select(
      _db.businesses,
    )..where((t) => t.id.equals(businessId))).getSingleOrNull();
    if (localBusiness == null) {
      debugPrint(
        '[SyncService] Business $businessId not found in local database. Forcing full sync.',
      );
      since = null;
    }

    debugPrint(
      '[SyncService] Pulling data for business $businessId (since: ${since?.toIso8601String() ?? "beginning"})...',
    );

    Map<String, List<dynamic>>? snapshot;
    try {
      final result = await _supabase.rpc(
        'pos_pull_snapshot',
        params: {
          'p_business_id': businessId,
          'p_since': since?.toIso8601String(),
        },
      ).timeout(const Duration(seconds: 30));
      if (result is Map) {
        snapshot = <String, List<dynamic>>{
          for (final entry in result.entries)
            if (entry.value is List)
              entry.key.toString(): List<dynamic>.from(entry.value as List),
        };
        debugPrint(
          '[SyncService] Snapshot RPC returned '
          '${snapshot.values.fold<int>(0, (a, l) => a + l.length)} rows '
          'across ${snapshot.length} tables.',
        );
      }
    } catch (e) {
      debugPrint(
        '[SyncService] Snapshot RPC unavailable, falling back to per-table fetch: $e',
      );
    }

    snapshot ??= await _pullViaPostgRest(businessId, since);

    // `pos_pull_snapshot` predates the `users` restore path (see 0005_sync_rpcs
    // v_tenant_tables) and omits the `users` table. Without a backfill,
    // `orders.staff_id` and other FK-to-users tables would explode at restore
    // time on a fresh device. Supplementary fetch is no-op when the postgrest
    // fallback already populated `users`, or when an updated RPC eventually
    // returns it inline.
    if (snapshot['users'] == null || snapshot['users']!.isEmpty) {
      try {
        var q = _supabase.from('users').select().eq('business_id', businessId);
        if (since != null) {
          q = q.gt('last_updated_at', since.toIso8601String());
        }
        final List<dynamic> users = await q.timeout(
          const Duration(seconds: 15),
        );
        snapshot['users'] = users;
        // Loud canary: matches the businesses canary below. A full pull that
        // returns 0 users for a known business almost certainly means the
        // FK-to-users tables (orders.staff_id, stock_*.performed_by, etc.)
        // will explode at restore time. Better to see it in the log now than
        // to chase a generic "couldn't load your business" toast.
        if (since == null && users.isEmpty) {
          debugPrint(
            '[SyncService] WARN supplementary users fetch returned 0 rows '
            'for $businessId — FK-to-users tables will fail restore. RLS '
            'denial or empty cloud users? auth.uid()='
            '${_supabase.auth.currentUser?.id}',
          );
        }
      } catch (e) {
        debugPrint('[SyncService] Supplementary users fetch failed: $e');
        snapshot.putIfAbsent('users', () => const <dynamic>[]);
      }
    }

    // Silent-RLS-denial canary: an authenticated pull for a known business
    // MUST return that business's row. Zero rows here means
    // public.business_id() returned NULL on the server (caller has no
    // profiles row, or the profile points to a different business), and
    // every tenant_select policy filtered the rest of the snapshot out
    // too. Warn loudly so a wipe-then-relogin race doesn't look like a
    // legitimate "no data yet" pull. Only fires on full pulls (`since`
    // null) — incremental pulls returning 0 rows is normal.
    if (since == null) {
      final businessesSlice = snapshot['businesses'];
      if (businessesSlice == null || businessesSlice.isEmpty) {
        debugPrint(
          '[SyncService] WARN pull returned 0 businesses rows for '
          '$businessId — likely RLS denial (missing profiles row for '
          'auth.uid()=${_supabase.auth.currentUser?.id}). Subsequent '
          'tenant tables will also be empty.',
        );
      }
    }

    for (final table in _pullOrder) {
      final data = snapshot[table];
      if (data != null && data.isNotEmpty) {
        debugPrint('[SyncService] Syncing $table: ${data.length} rows');
        await _restoreTableData(table, data);
      }
    }
  }

  /// Per-table parallel fetch — the original pull path. Used as a fallback
  /// when the snapshot RPC is unavailable.
  Future<Map<String, List<dynamic>>> _pullViaPostgRest(
    String businessId,
    DateTime? since,
  ) async {
    final fetchResults = await Future.wait(
      _pullOrder.map((table) async {
        try {
          final isGlobal = table == 'system_config';
          var query = _supabase.from(table).select();

          if (!isGlobal) {
            // The cloud `businesses` table has no `business_id` column — its `id`
            // IS the business id. All other tables filter by `business_id`.
            final filterColumn = table == 'businesses' ? 'id' : 'business_id';
            query = query.eq(filterColumn, businessId);
          }

          // The `businesses` row is the FK target for almost everything
          // local. Always fetch it unconditionally so a stale `since` can't
          // produce a sync where children try to insert against a missing
          // parent.
          if (since != null && table != 'businesses') {
            query = query.gt('last_updated_at', since.toIso8601String());
          }

          final List<dynamic> data = await query.timeout(
            const Duration(seconds: 15),
          );
          return MapEntry(table, data);
        } catch (e) {
          debugPrint('[SyncService] Error pulling table $table: $e');
          return MapEntry(table, const <dynamic>[]);
        }
      }),
    );
    return Map.fromEntries(fetchResults);
  }

  /// Subscribes to real-time changes from Supabase for this business.
  void startRealtimeSync(String businessId) {
    if (_realtimeChannel != null) return;

    debugPrint(
      '[SyncService] Starting real-time sync for business $businessId',
    );

    // Wildcard subscription for all tables with a `business_id` column.
    // The `businesses` table has no `business_id` and is handled separately.
    // Per-table refactor deferred — wrap in try/catch so a single bad table
    // doesn't kill the whole channel.
    try {
      _realtimeChannel =
          _supabase
              .channel('public:*')
              .onPostgresChanges(
                event: PostgresChangeEvent.all,
                schema: 'public',
                filter: PostgresChangeFilter(
                  type: PostgresChangeFilterType.eq,
                  column: 'business_id',
                  value: businessId,
                ),
                callback: (payload) async {
                  debugPrint(
                    '[SyncService] Realtime Event: ${payload.eventType} on ${payload.table}',
                  );

                  final table = payload.table;
                  final newRecord = payload.newRecord;

                  if (newRecord.isNotEmpty) {
                    await _restoreTableData(table, [newRecord]);
                    // Single-active-device sign-in: when our own session row
                    // gets revoked by another device's fresh sign-in, ask
                    // AuthService to fullLogout this device.
                    if (table == 'sessions' &&
                        newRecord['revoked_at'] != null &&
                        newRecord['id'] == currentSessionIdResolver?.call()) {
                      onCurrentSessionRevoked?.call();
                    }
                  } else if (payload.eventType == PostgresChangeEvent.delete &&
                      payload.oldRecord.isNotEmpty) {
                    final id = payload.oldRecord['id'];
                    if (id != null) {
                      // For now, soft deletes are handled as updates.
                    }
                  }
                },
              )
            ..subscribe();
    } catch (e) {
      debugPrint('[SyncService] Wildcard realtime subscribe failed: $e');
    }

    // Separate channel for `businesses` filtered by `id` (no business_id column).
    try {
      _businessesChannel =
          _supabase
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
                callback: (payload) async {
                  debugPrint(
                    '[SyncService] Realtime Event: ${payload.eventType} on businesses',
                  );
                  final newRecord = payload.newRecord;
                  if (newRecord.isNotEmpty) {
                    await _restoreTableData('businesses', [newRecord]);
                  }
                },
              )
            ..subscribe();
    } catch (e) {
      debugPrint('[SyncService] Businesses realtime subscribe failed: $e');
    }
  }

  /// Stops listening to real-time changes (e.g., on logout).
  void stopRealtimeSync() {
    debugPrint('[SyncService] Stopping real-time sync.');
    if (_realtimeChannel != null) {
      _supabase.removeChannel(_realtimeChannel!);
      _realtimeChannel = null;
    }
    if (_businessesChannel != null) {
      _supabase.removeChannel(_businessesChannel!);
      _businessesChannel = null;
    }
    stopAutoPush();
  }

  /// Watches the local sync queue and pushes pending items to Supabase
  /// shortly after they are enqueued. Idempotent — safe to call repeatedly.
  bool _autoPushStarting = false;

  void startAutoPush() {
    if (_autoPushSub != null || _autoPushStarting) return;
    _autoPushStarting = true;
    unawaited(_initAutoPush());
  }

  /// Sequential initialization. The previous implementation fired the
  /// backfill, backoff-clear and listener subscription in parallel as
  /// `unawaited` futures, which raced: the first push tick could load the
  /// queue before the warehouse backfill INSERT had committed, so the
  /// warehouse was missing and the customer/wallet FK-failed against a
  /// cloud row that didn't exist yet. Awaiting the prep work in order
  /// guarantees the queue is in its final state before we subscribe.
  Future<void> _initAutoPush() async {
    try {
      await _db.syncDao.resetStuckInProgress();
      // One-shot recovery: re-enqueue rows that were inserted before
      // their owning DAO method was wired to call `enqueueUpsert` (i.e.
      // pre-redesign leaks). Drift's NOT-NULL DEFAULT on `last_updated_at`
      // means new writes are always tagged, so there's nothing to find on
      // the second-and-beyond app launches. The flag prevents this scan
      // from running per-launch.
      final prefs = await SharedPreferences.getInstance();
      const oneShotKey = 'global_unsynced_backfill_v2_2026Q2';
      if (prefs.getBool(oneShotKey) != true) {
        await _backfillAllUnsyncedTables();
        await prefs.setBool(oneShotKey, true);
      }
      // Users backfill ships after the global gate above, so devices that
      // already passed it still pick up the per-business one-shot below.
      await _backfillUnsyncedUsers();

      // One-shot remediation for the millis-timestamp serialization bug
      // (sync_helpers.dart pre-fix produced int payloads that Postgres
      // rejected with 22008). Drops any pending queue rows that have
      // already been attempted; untried items survive so concurrent fresh
      // writes aren't dropped. Future writes use the corrected serializer.
      const purgeFlag = 'pending_queue_purge_after_timestamp_fix_v1';
      if (prefs.getBool(purgeFlag) != true) {
        final purged = await _db.syncDao.purgeAttemptedPending();
        if (purged > 0) {
          debugPrint(
            '[SyncService] Purged $purged stale queue items with bad '
            'integer-millis timestamps (one-shot remediation).',
          );
        }
        await prefs.setBool(purgeFlag, true);
      }

      if (_supabase.auth.currentUser != null) {
        await _db.syncDao.clearFailureBackoff();
      }

      var lastCount = 0;
      _autoPushSub = _db.syncDao.watchPendingCount().listen((count) {
        final prev = lastCount;
        lastCount = count;
        if (count == 0) return;
        // 0→N transition: skip the coalesce window so the first write of
        // an idle period goes up immediately. Subsequent enqueues during
        // an in-flight push are still coalesced into the next cycle.
        if (prev == 0) {
          _schedulePushImmediate();
        } else {
          _scheduleDebouncedPush();
        }
      });

      _authStateSub ??= _supabase.auth.onAuthStateChange.listen(
        (state) async {
          if (state.event == AuthChangeEvent.signedIn ||
              state.event == AuthChangeEvent.tokenRefreshed ||
              state.event == AuthChangeEvent.initialSession) {
            _loggedJwtClaimsThisSession = false;
            await _db.syncDao.clearFailureBackoff();
            _scheduleDebouncedPush();
          } else if (state.event == AuthChangeEvent.signedOut) {
            _loggedJwtClaimsThisSession = false;
          }
        },
        // Token-refresh failures (offline, DNS lookup errors) surface on
        // this stream as AuthRetryableFetchException. Swallow them — the
        // SDK retries on reconnect; without onError they bubble up as
        // uncaught exceptions.
        onError: (e) => debugPrint('[SupabaseSync] auth stream error: $e'),
      );

      _connectivitySub ??= Connectivity().onConnectivityChanged.listen(
        _handleConnectivityTransition,
      );

      // Periodic safety net. The watcher only fires when the queue *count*
      // changes, which leaves rows in exponential-backoff (status='pending'
      // with future nextAttemptAt) and 'syncing' zombies invisible until the
      // user makes another mutation, signs in, or reconnects. The tick re-
      // evaluates eligibility — getPendingItems naturally filters by
      // nextAttemptAt, so the cost is one indexed select per tick when
      // nothing is due.
      _autoPushPeriodic ??= Timer.periodic(_autoPushPeriodicInterval, (_) async {
        try {
          if (_pushing) return;
          await _db.syncDao.resetStuckInProgress();
          await _runPushOnce();
        } catch (e) {
          debugPrint('[SyncService] periodic drain tick failed: $e');
        }
      });
    } finally {
      _autoPushStarting = false;
    }
  }

  /// Coalesce-window for bursty writes. Long enough to merge the 5–8
  /// enqueues of a single createOrder transaction (they happen within
  /// ~10ms of each other inside one Drift txn) but short enough that an
  /// isolated write doesn't feel laggy. Was 500ms — measured to add half a
  /// second to every send.
  static const _pushDebounce = Duration(milliseconds: 60);

  void _scheduleDebouncedPush() {
    _autoPushDebounce?.cancel();
    _autoPushDebounce = Timer(_pushDebounce, _runPushOnce);
  }

  /// Bypasses the debounce window. Used when the queue transitions 0→N: the
  /// first write should not wait the coalesce window before going up.
  void _schedulePushImmediate() {
    _autoPushDebounce?.cancel();
    Future.microtask(_runPushOnce);
  }

  Future<void> _runPushOnce() async {
    if (_pushing) return;
    _pushing = true;
    try {
      await pushPending();
    } catch (e) {
      debugPrint('[SyncService] auto-push failed: $e');
    } finally {
      _pushing = false;
    }
  }

  /// Enqueues an upsert for any warehouse that has never been synced
  /// (`lastUpdatedAt IS NULL`). Onboarding originally inserted warehouses
  /// without going through the sync queue, leaving customer/product FKs
  /// dangling in the cloud. Idempotent: marking `lastUpdatedAt` after
  /// enqueueing prevents re-queueing on subsequent startups.
  Future<void> _backfillUnsyncedWarehouses() async {
    try {
      final whs = await (_db.select(
        _db.warehouses,
      )..where((t) => t.lastUpdatedAt.isNull())).get();
      if (whs.isEmpty) return;

      final now = DateTime.now();
      var enqueued = 0;
      for (final w in whs) {
        final businessId = w.businessId;
        await _db.syncDao.enqueue(
          'warehouses:upsert',
          jsonEncode({
            'id': w.id,
            'business_id': businessId,
            'name': w.name,
            'location': w.location,
            'last_updated_at': now.toIso8601String(),
            'is_deleted': w.isDeleted,
          }),
        );
        await (_db.update(_db.warehouses)..where((t) => t.id.equals(w.id)))
            .write(WarehousesCompanion(lastUpdatedAt: Value(now)));
        enqueued++;
      }

      if (enqueued > 0) {
        debugPrint('[SyncService] Warehouse backfill: enqueued=$enqueued');
      }
    } catch (e) {
      debugPrint('[SyncService] Warehouse backfill failed: $e');
    }
  }

  Future<void> _handleConnectivityTransition(
    List<ConnectivityResult> results,
  ) async {
    final hasNetwork =
        !(results.isEmpty ||
            results.every((r) => r == ConnectivityResult.none));
    isOnline.value = hasNetwork;
    if (hasNetwork) {
      debugPrint(
        '[SyncService] Usable network connected, flushing and pulling...',
      );
      await _db.syncDao.clearFailureBackoff();
      _scheduleDebouncedPush();

      final businessId = _db.businessIdResolver.call();
      if (businessId != null) {
        unawaited(() async {
          try {
            final prefs = await SharedPreferences.getInstance();
            final key = 'last_sync_timestamp::$businessId';
            final lastSyncStr = prefs.getString(key);
            DateTime? since;
            if (lastSyncStr != null) {
              since = DateTime.tryParse(lastSyncStr);
            }
            await pullInitialData(businessId, since: since);
          } catch (e) {
            debugPrint('[SyncService] Connectivity pull failed: $e');
          }
        }());
      }
    }
  }

  Future<void> _backfillTable<T extends Table, D extends DataClass>(
    TableInfo<T, D> table,
    String tableName,
    String Function(D) getId,
  ) async {
    try {
      final column = table.columnsByName['last_updated_at'];
      if (column == null) return;

      final query = _db.select(table)
        ..where((t) {
          final lastUpdatedField =
              table.columnsByName['last_updated_at'] as Expression<DateTime>;
          return lastUpdatedField.isNull();
        });
      final rows = await query.get();
      if (rows.isEmpty) return;

      final now = DateTime.now();
      for (final row in rows) {
        final id = getId(row);
        await _db.syncDao.enqueueUpsert(tableName, row as Insertable);

        final updateQuery = _db.update(table)
          ..where((t) {
            final idField = table.columnsByName['id'] as Expression<String>;
            return idField.equals(id);
          });

        await updateQuery.write(
          RawValuesInsertable({'last_updated_at': Variable(now)}),
        );
      }
      debugPrint('[SyncService] Backfilled ${rows.length} rows for $tableName');
    } catch (e) {
      debugPrint('[SyncService] Backfill for $tableName failed: $e');
    }
  }

  /// One-shot recovery for categories created before the
  /// CatalogDao.insertCategory wiring landed. Earlier builds wrote default
  /// categories straight into Drift without ever enqueueing them, so cloud
  /// `categories` stayed empty and every product/inventory/stock_* push
  /// FK-failed against it. Re-enqueue every local category once; the server's
  /// ON CONFLICT (id) DO UPDATE makes this idempotent. Gated by a one-shot
  /// SharedPreferences flag so subsequent launches don't re-flood the queue.
  Future<void> _backfillUnsyncedCategories() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      const flagKey = 'categories_backfill_v1';
      if (prefs.getBool(flagKey) == true) return;

      final cats = await _db.select(_db.categories).get();
      if (cats.isEmpty) {
        await prefs.setBool(flagKey, true);
        return;
      }

      var enqueued = 0;
      for (final c in cats) {
        await _db.syncDao.enqueueUpsert('categories', c);
        enqueued++;
      }
      await prefs.setBool(flagKey, true);
      if (enqueued > 0) {
        debugPrint('[SyncService] Categories backfill: enqueued=$enqueued');
      }
    } catch (e) {
      debugPrint('[SyncService] Categories backfill failed: $e');
    }
  }

  /// One-shot recovery for users created before auth_service.createNewOwner /
  /// upsertLocalUserFromProfile started enqueueing. Earlier builds inserted
  /// the local users row via `db.into(_db.users)` without a sync enqueue, so
  /// cloud `public.users` never received it. Subsequent sales reference
  /// `staff_id = users.id`, which the cloud rejects with
  /// `pg_23503 orders_staff_id_fkey`. Re-enqueue every local user once for
  /// the current business; the cloud's `ON CONFLICT (id) DO NOTHING` makes
  /// this safe to repeat. Gated by a SharedPreferences flag.
  Future<void> _backfillUnsyncedUsers() async {
    try {
      final businessId = _db.currentBusinessId;
      if (businessId == null) return;

      final prefs = await SharedPreferences.getInstance();
      final flagKey = 'users_backfill_v1::$businessId';
      if (prefs.getBool(flagKey) == true) return;

      final rows = await (_db.select(_db.users)
            ..where((t) => t.businessId.equals(businessId)))
          .get();
      if (rows.isEmpty) {
        await prefs.setBool(flagKey, true);
        return;
      }

      var enqueued = 0;
      for (final u in rows) {
        await _db.syncDao.enqueueUpsert('users', u);
        enqueued++;
      }
      await prefs.setBool(flagKey, true);
      if (enqueued > 0) {
        debugPrint('[SyncService] Users backfill: enqueued=$enqueued');
      }
    } catch (e) {
      debugPrint('[SyncService] Users backfill failed: $e');
    }
  }

  Future<void> _backfillAllUnsyncedTables() async {
    try {
      await _backfillUnsyncedWarehouses();
      await _backfillUnsyncedUsers();
      await _backfillUnsyncedCategories();
      await _backfillTable(_db.products, 'products', (row) => row.id);
      await _backfillTable(_db.customers, 'customers', (row) => row.id);
      await _backfillTable(_db.suppliers, 'suppliers', (row) => row.id);
      await _backfillTable(_db.orders, 'orders', (row) => row.id);
      await _backfillTable(_db.orderItems, 'order_items', (row) => row.id);
      await _backfillTable(_db.expenses, 'expenses', (row) => row.id);
      await _backfillTable(
        _db.expenseCategories,
        'expense_categories',
        (row) => row.id,
      );
      await _backfillTable(
        _db.customerCrateBalances,
        'customer_crate_balances',
        (row) => row.id,
      );
      await _backfillTable(
        _db.deliveryReceipts,
        'delivery_receipts',
        (row) => row.id,
      );
      await _backfillTable(_db.drivers, 'drivers', (row) => row.id);
      await _backfillTable(
        _db.stockTransfers,
        'stock_transfers',
        (row) => row.id,
      );
      await _backfillTable(
        _db.stockAdjustments,
        'stock_adjustments',
        (row) => row.id,
      );
      await _backfillTable(
        _db.customerWallets,
        'customer_wallets',
        (row) => row.id,
      );
      await _backfillTable(
        _db.walletTransactions,
        'wallet_transactions',
        (row) => row.id,
      );
      await _backfillTable(_db.savedCarts, 'saved_carts', (row) => row.id);
      await _backfillTable(
        _db.pendingCrateReturns,
        'pending_crate_returns',
        (row) => row.id,
      );
    } catch (e) {
      debugPrint('[SyncService] General backfill failed: $e');
    }
  }

  void stopAutoPush() {
    _autoPushDebounce?.cancel();
    _autoPushDebounce = null;
    _autoPushPeriodic?.cancel();
    _autoPushPeriodic = null;
    _autoPushSub?.cancel();
    _autoPushSub = null;
    _authStateSub?.cancel();
    _authStateSub = null;
    _connectivitySub?.cancel();
    _connectivitySub = null;
  }

  /// Cloud `jsonb` columns arrive as Map/List, but Drift stores them as TEXT.
  /// Stringify so DataClass.fromJson<String?> can cast without throwing.
  static dynamic _stringifyJsonb(dynamic v) {
    // Cloud `jsonb` columns can hold any JSON shape, including primitives.
    // Drift mirrors these as `text` (String?), so anything non-string must
    // be JSON-encoded. Booleans in particular bite system_config flag rows
    // (e.g. `feature.domain_rpcs_v2.* = true` as a jsonb boolean lands as
    // Dart `bool` and crashes the `String?` cast in fromJson).
    if (v == null || v is String) return v;
    return jsonEncode(v);
  }

  /// Converts snake_case Supabase JSON keys to camelCase for Drift's fromJson.
  Map<String, dynamic> _snakeToCamel(Map<String, dynamic> m) {
    return m.map((key, value) {
      final camel = key.replaceAllMapped(
        RegExp(r'_([a-z])'),
        (match) => match.group(1)!.toUpperCase(),
      );
      return MapEntry(camel, value);
    });
  }

  /// Maps Supabase table names to Drift insertion logic.
  /// Uses DataClass.fromJson() which is always generated by Drift,
  /// then inserts the DataClass directly since it implements Insertable.
  /// Returns the subset of [rows] that should overwrite the local mirror
  /// per the §6.7 last-write-wins guard:
  ///   * incoming row absent locally → keep
  ///   * local `last_updated_at` is NULL (legacy) → keep
  ///   * incoming `last_updated_at` >= local → keep
  ///   * incoming `last_updated_at` <  local → drop
  ///
  /// Tables without an `id`/`last_updated_at` column (only `system_config`
  /// in practice — keyed by `key`, no LUA) pass through unfiltered.
  Future<List<Map<String, dynamic>>> _filterByLwwGuard(
    String table,
    List<Map<String, dynamic>> rows,
  ) async {
    if (rows.isEmpty) return rows;
    if (table == 'system_config') return rows;

    final ids =
        rows.map((r) => r['id']).whereType<String>().toSet().toList();
    if (ids.isEmpty) return rows;

    // Drift stores DateTime as integer Unix seconds; reading the raw
    // column type and comparing in epoch space avoids DateTime parse cost.
    final placeholders = List.filled(ids.length, '?').join(',');
    final localResults = await _db.customSelect(
      'SELECT id, last_updated_at FROM $table WHERE id IN ($placeholders)',
      variables: ids.map(Variable.withString).toList(),
    ).get();

    final localEpoch = <String, int?>{};
    for (final row in localResults) {
      final id = row.read<String>('id');
      // Read as int? — Drift's default datetime mapping is integer epoch.
      // Older rows may have NULL last_updated_at (treated as -∞).
      localEpoch[id] = row.data['last_updated_at'] as int?;
    }

    return rows.where((r) {
      final id = r['id'];
      if (id is! String) return true; // unkeyable; pass through
      if (!localEpoch.containsKey(id)) return true; // not present locally
      final local = localEpoch[id];
      if (local == null) return true; // legacy NULL; incoming wins

      final incomingRaw = r['lastUpdatedAt'];
      int? incoming;
      if (incomingRaw is int) {
        incoming = incomingRaw;
      } else if (incomingRaw is String) {
        final dt = DateTime.tryParse(incomingRaw);
        if (dt != null) incoming = dt.millisecondsSinceEpoch ~/ 1000;
      }
      if (incoming == null) return true; // can't compare; let it through
      return incoming >= local;
    }).toList();
  }

  Future<void> _restoreTableData(String table, List<dynamic> data) async {
    // `profiles` has no local mirror — the current user's row is upserted by
    // AuthService.upsertLocalUserFromProfile during auth. Bail before the LWW
    // guard tries to read from a table that doesn't exist locally.
    if (table == 'profiles') {
      debugPrint(
        '[SyncService] Skipping bulk profiles restore (${data.length} rows) — handled by auth flow.',
      );
      return;
    }
    final allRows = data
        .map((e) => _snakeToCamel(e as Map<String, dynamic>))
        .toList();
    // §6.7 LWW guard: drop incoming rows whose `last_updated_at` is older
    // than the existing local row. Out-of-order realtime delivery would
    // otherwise clobber a fresher local row with a stale snapshot. NULL
    // local LUA (legacy backfill) loses to anything; incoming rows the
    // local DB doesn't yet have always pass.
    final rows = await _filterByLwwGuard(table, allRows);
    final filtered = allRows.length - rows.length;
    if (filtered > 0) {
      debugPrint(
        '[SyncService] LWW filtered $filtered/${allRows.length} rows for $table',
      );
    }
    if (rows.isEmpty) return;
    debugPrint('[SyncService] restored $table: ${rows.length} rows');

    await _db.transaction(() async {
      switch (table) {
        case 'businesses':
          for (var r in rows) {
            // Cloud `businesses` lacks `timezone` (local-only column with
            // default 'UTC'). Without this, fromJson casts null → String and
            // throws on every restore.
            r.putIfAbsent('timezone', () => 'UTC');
            r.putIfAbsent('onboardingComplete', () => false);
            await _db
                .into(_db.businesses)
                .insertOnConflictUpdate(BusinessData.fromJson(r));
          }
          break;
        case 'warehouses':
          for (var r in rows) {
            await _db
                .into(_db.warehouses)
                .insertOnConflictUpdate(WarehouseData.fromJson(r));
          }
          break;
        case 'users':
          // Manual upsert: cloud doesn't carry device-local auth material
          // (pin, pinHash, pinSalt, pinIterations, passwordHash) or per-device
          // UI/biometric state (biometricEnabled, avatarColor). On existing
          // rows touch only cloud-owned fields so a fresh pull never clobbers
          // a PIN already set on this device; on new rows insert with the
          // setup-required sentinel so the row exists for FK targets like
          // orders.staff_id, and the OTP flow can later route the user into
          // PIN setup if they sign in here.
          //
          // Cloud-owned fields mirrored here (keep in sync with app_database
          // `Users` table and `0001_initial.sql public.users`):
          //   businessId, authUserId, name, email, role, roleTier,
          //   warehouseId, isDeleted, createdAt, lastNotificationSentAt,
          //   lastUpdatedAt.
          // Device-local fields intentionally omitted (never overwrite from
          // cloud):
          //   pin, pinHash, pinSalt, pinIterations, passwordHash,
          //   biometricEnabled, avatarColor.
          for (var r in rows) {
            final id = r['id'] as String;
            final existing =
                await (_db.select(_db.users)
                  ..where((u) => u.id.equals(id))).getSingleOrNull();

            DateTime parseTs(Object? v, {DateTime? fallback}) {
              if (v is String) return DateTime.parse(v);
              if (v is DateTime) return v;
              return fallback ?? DateTime.now().toUtc();
            }

            final lastUpdatedAt = parseTs(r['lastUpdatedAt']);
            final createdAt = parseTs(
              r['createdAt'],
              fallback: lastUpdatedAt,
            );
            final lastNotificationSentAt = r['lastNotificationSentAt'] == null
                ? null
                : parseTs(r['lastNotificationSentAt']);

            // CHECK-constraint guard: local Users has
            //   role IN ('ceo','manager','stock_keeper','cashier','rider')
            //   role_tier IN (2,3,4,5,6)
            // (v9 granular vocabulary — see migration 0030 / Drift v8→v9.)
            // A cloud row outside these sets would crash the whole pull at
            // insert time. We log loudly and SKIP the row entirely. Silent
            // coercion (the pre-v9 policy) masked data anomalies AND could
            // demote a legit user — never again.
            const allowedRoles = {
              'ceo',
              'manager',
              'stock_keeper',
              'cashier',
              'rider',
            };
            const allowedRoleTiers = {2, 3, 4, 5, 6};
            final rawRole = r['role'] as String?;
            final rawTier = (r['roleTier'] as num?)?.toInt();
            if (rawRole == null ||
                !allowedRoles.contains(rawRole) ||
                rawTier == null ||
                !allowedRoleTiers.contains(rawTier)) {
              debugPrint(
                '[SyncService] users restore: dropping row id=$id '
                'due to invalid role=${rawRole ?? "<null>"}/'
                'tier=${rawTier ?? "<null>"}',
              );
              continue;
            }
            final role = rawRole;
            final roleTier = rawTier;

            if (existing != null) {
              await (_db.update(_db.users)
                ..where((u) => u.id.equals(id))).write(
                UsersCompanion(
                  businessId: Value(r['businessId'] as String),
                  authUserId: Value(r['authUserId'] as String?),
                  name: Value(r['name'] as String? ?? ''),
                  email: Value(r['email'] as String?),
                  role: Value(role),
                  roleTier: Value(roleTier),
                  warehouseId: Value(r['warehouseId'] as String?),
                  lastNotificationSentAt: Value(lastNotificationSentAt),
                  isDeleted: Value(r['isDeleted'] as bool? ?? false),
                  lastUpdatedAt: Value(lastUpdatedAt),
                ),
              );
            } else {
              await _db
                  .into(_db.users)
                  .insert(
                    UsersCompanion.insert(
                      id: Value(id),
                      businessId: r['businessId'] as String,
                      authUserId: Value(r['authUserId'] as String?),
                      name: r['name'] as String? ?? '',
                      email: Value(r['email'] as String?),
                      pin: kSetupRequiredPin,
                      role: role,
                      roleTier: Value(roleTier),
                      warehouseId: Value(r['warehouseId'] as String?),
                      createdAt: Value(createdAt),
                      lastNotificationSentAt: Value(lastNotificationSentAt),
                      isDeleted: Value(r['isDeleted'] as bool? ?? false),
                      lastUpdatedAt: Value(lastUpdatedAt),
                    ),
                  );
            }
          }
          break;
        case 'business_members':
          // PIN columns (pin_hash, pin_salt, pin_iterations) sync normally
          // per the staff-onboarding plan §2 — no device-local preservation.
          //
          // Role / tier guard (v9 granular vocabulary): local Drift has
          //   CHECK (role IN ('ceo','manager','stock_keeper','cashier','rider'))
          //   CHECK (role_tier IN (2,3,4,5,6))
          // A cloud row outside these sets would crash the whole pull at
          // insert time. We log loudly and SKIP the row entirely — never
          // silently coerce, which would mask data anomalies and could
          // demote a legit user. Status / verification_status coercion
          // below stays in the coerce-to-default form: those aren't
          // permission-bearing and a stale/bogus value there is benign.
          const allowedRoles = {
            'ceo',
            'manager',
            'stock_keeper',
            'cashier',
            'rider',
          };
          const allowedRoleTiers = {2, 3, 4, 5, 6};
          const allowedStatuses = {'active', 'suspended', 'removed'};
          const allowedVerificationStatuses = {
            'not_started',
            'pending_review',
            'approved',
            'rejected',
          };
          for (var r in rows) {
            final id = r['id'] as String?;
            final rawRole = r['role'] as String?;
            final rawTier = (r['roleTier'] as num?)?.toInt();
            if (rawRole == null ||
                !allowedRoles.contains(rawRole) ||
                rawTier == null ||
                !allowedRoleTiers.contains(rawTier)) {
              debugPrint(
                '[SyncService] business_members restore: dropping row id=$id '
                'due to invalid role=${rawRole ?? "<null>"}/'
                'tier=${rawTier ?? "<null>"}',
              );
              continue;
            }
            final rawStatus = r['status'] as String?;
            if (rawStatus != null &&
                !allowedStatuses.contains(rawStatus)) {
              debugPrint(
                '[SyncService] business_members restore: coerced invalid '
                'status "$rawStatus" to "active" for id=$id',
              );
              r['status'] = 'active';
            }
            final rawVerif = r['verificationStatus'] as String?;
            if (rawVerif != null &&
                !allowedVerificationStatuses.contains(rawVerif)) {
              debugPrint(
                '[SyncService] business_members restore: coerced invalid '
                'verification_status "$rawVerif" to "not_started" for id=$id',
              );
              r['verificationStatus'] = 'not_started';
            }
            await _db
                .into(_db.businessMembers)
                .insertOnConflictUpdate(BusinessMemberData.fromJson(r));
          }
          break;
        case 'products':
          for (var r in rows) {
            await _db
                .into(_db.products)
                .insertOnConflictUpdate(ProductData.fromJson(r));
          }
          break;
        case 'crate_groups':
          for (var r in rows) {
            await _db
                .into(_db.crateGroups)
                .insertOnConflictUpdate(CrateGroupData.fromJson(r));
          }
          break;
        case 'manufacturers':
          for (var r in rows) {
            await _db
                .into(_db.manufacturers)
                .insertOnConflictUpdate(ManufacturerData.fromJson(r));
          }
          break;
        case 'categories':
          for (var r in rows) {
            await _db
                .into(_db.categories)
                .insertOnConflictUpdate(CategoryData.fromJson(r));
          }
          break;
        case 'inventory':
          for (var r in rows) {
            await _db
                .into(_db.inventory)
                .insertOnConflictUpdate(InventoryData.fromJson(r));
          }
          break;
        case 'customers':
          for (var r in rows) {
            await _db
                .into(_db.customers)
                .insertOnConflictUpdate(CustomerData.fromJson(r));
          }
          break;
        case 'suppliers':
          for (var r in rows) {
            await _db
                .into(_db.suppliers)
                .insertOnConflictUpdate(SupplierData.fromJson(r));
          }
          break;
        case 'orders':
          for (var r in rows) {
            await _db
                .into(_db.orders)
                .insertOnConflictUpdate(OrderData.fromJson(r));
          }
          break;
        case 'order_items':
          for (var r in rows) {
            r['priceSnapshot'] = _stringifyJsonb(r['priceSnapshot']);
            await _db
                .into(_db.orderItems)
                .insertOnConflictUpdate(OrderItemData.fromJson(r));
          }
          break;
        case 'expenses':
          for (var r in rows) {
            await _db
                .into(_db.expenses)
                .insertOnConflictUpdate(ExpenseData.fromJson(r));
          }
          break;
        case 'expense_categories':
          for (var r in rows) {
            await _db
                .into(_db.expenseCategories)
                .insertOnConflictUpdate(ExpenseCategoryData.fromJson(r));
          }
          break;
        case 'manufacturer_crate_balances':
          for (var r in rows) {
            await _db
                .into(_db.manufacturerCrateBalances)
                .insertOnConflictUpdate(ManufacturerCrateBalance.fromJson(r));
          }
          break;
        case 'crate_ledger':
          for (var r in rows) {
            await _db
                .into(_db.crateLedger)
                .insertOnConflictUpdate(CrateLedgerData.fromJson(r));
          }
          break;
        case 'system_config':
          for (var r in rows) {
            r['value'] = _stringifyJsonb(r['value']);
            await _db
                .into(_db.systemConfig)
                .insertOnConflictUpdate(SystemConfigData.fromJson(r));
          }
          break;
        case 'purchases':
          for (var r in rows) {
            await _db
                .into(_db.purchases)
                .insertOnConflictUpdate(DeliveryData.fromJson(r));
          }
          break;
        case 'purchase_items':
          for (var r in rows) {
            await _db
                .into(_db.purchaseItems)
                .insertOnConflictUpdate(PurchaseItemData.fromJson(r));
          }
          break;
        case 'customer_crate_balances':
          for (var r in rows) {
            await _db
                .into(_db.customerCrateBalances)
                .insertOnConflictUpdate(CustomerCrateBalance.fromJson(r));
          }
          break;
        case 'delivery_receipts':
          for (var r in rows) {
            await _db
                .into(_db.deliveryReceipts)
                .insertOnConflictUpdate(DeliveryReceiptData.fromJson(r));
          }
          break;
        case 'drivers':
          for (var r in rows) {
            await _db
                .into(_db.drivers)
                .insertOnConflictUpdate(DriverData.fromJson(r));
          }
          break;
        case 'price_lists':
          for (var r in rows) {
            await _db
                .into(_db.priceLists)
                .insertOnConflictUpdate(PriceListData.fromJson(r));
          }
          break;
        case 'payment_transactions':
          for (var r in rows) {
            await _db
                .into(_db.paymentTransactions)
                .insertOnConflictUpdate(PaymentTransactionData.fromJson(r));
          }
          break;
        case 'stock_transfers':
          for (var r in rows) {
            await _db
                .into(_db.stockTransfers)
                .insertOnConflictUpdate(StockTransferData.fromJson(r));
          }
          break;
        case 'stock_adjustments':
          for (var r in rows) {
            await _db
                .into(_db.stockAdjustments)
                .insertOnConflictUpdate(StockAdjustmentData.fromJson(r));
          }
          break;
        case 'activity_logs':
          for (var r in rows) {
            await _db
                .into(_db.activityLogs)
                .insertOnConflictUpdate(ActivityLogData.fromJson(r));
          }
          break;
        case 'notifications':
          for (var r in rows) {
            await _db
                .into(_db.notifications)
                .insertOnConflictUpdate(NotificationData.fromJson(r));
          }
          break;
        case 'settings':
          for (var r in rows) {
            await _db
                .into(_db.settings)
                .insertOnConflictUpdate(SettingData.fromJson(r));
          }
          break;
        case 'sessions':
          for (var r in rows) {
            await _db
                .into(_db.sessions)
                .insertOnConflictUpdate(SessionData.fromJson(r));
          }
          break;
        case 'stock_transactions':
          for (var r in rows) {
            await _db
                .into(_db.stockTransactions)
                .insertOnConflictUpdate(StockTransactionData.fromJson(r));
          }
          break;
        case 'customer_wallets':
          for (var r in rows) {
            await _db
                .into(_db.customerWallets)
                .insertOnConflictUpdate(CustomerWalletData.fromJson(r));
          }
          break;
        case 'wallet_transactions':
          for (var r in rows) {
            await _db
                .into(_db.walletTransactions)
                .insertOnConflictUpdate(WalletTransactionData.fromJson(r));
          }
          break;
        case 'saved_carts':
          for (var r in rows) {
            r['cartData'] = _stringifyJsonb(r['cartData']);
            await _db
                .into(_db.savedCarts)
                .insertOnConflictUpdate(SavedCartData.fromJson(r));
          }
          break;
        case 'pending_crate_returns':
          for (var r in rows) {
            await _db
                .into(_db.pendingCrateReturns)
                .insertOnConflictUpdate(PendingCrateReturnData.fromJson(r));
          }
          break;
        case 'invites':
          for (var r in rows) {
            await _db
                .into(_db.invites)
                .insertOnConflictUpdate(InviteData.fromJson(r));
          }
          break;
        default:
          debugPrint('[SyncService] Restore logic not implemented for $table');
      }
    });
  }
}

/// Group key for batched pushes: items sharing (table, action, conflictTarget)
/// can be sent in a single Supabase array-upsert / array-delete call.
class _PushGroup {
  final String table;
  final String action;
  final String? conflictTarget;
  const _PushGroup({
    required this.table,
    required this.action,
    this.conflictTarget,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _PushGroup &&
          table == other.table &&
          action == other.action &&
          conflictTarget == other.conflictTarget;

  @override
  int get hashCode => Object.hash(table, action, conflictTarget);
}
