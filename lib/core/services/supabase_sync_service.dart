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

/// Thrown by [SupabaseSyncService.pullInitialData] when one or more
/// tenant-table fetches failed (after retry) during the per-table
/// fallback path. Restoring an incomplete snapshot would silently
/// produce a local DB that looks complete but isn't — children would
/// FK-fail against parents that were never fetched. The caller should
/// surface this as a "check your connection" message and let the user
/// retry.
class PartialPullException implements Exception {
  final Set<String> failedTables;
  const PartialPullException(this.failedTables);
  @override
  String toString() =>
      'PartialPullException: ${failedTables.length} table(s) failed: '
      '${failedTables.join(", ")}';
}

class _FetchOutcome {
  final String table;
  final List<dynamic>? data;
  final Object? error;
  const _FetchOutcome(this.table, this.data, this.error);
}

/// Coarse stage for the data-pull state machine. Drives the MainLayout
/// catch-up banner and is observed by `pullStatusProvider`.
///
/// - [idle]: no pull in flight; local DB is either fresh or last pull
///   completed successfully.
/// - [minimum]: the 4-table fast pull that gates MainLayout render
///   (profiles, businesses, users, stores). Never visible in
///   MainLayout — it only fires before MainLayout mounts.
/// - [background]: the post-login full pull. Banner is visible.
/// - [completed]: the most recent pull (minimum or background)
///   finished cleanly. Banner shows "Caught up." for 2s then transitions
///   to [idle].
/// - [failed]: a pull threw `PartialPullException` or another error.
///   Banner shows graduated copy based on `consecutive_pull_failures`.
enum PullStage { idle, minimum, background, completed, failed }

class PullStatus {
  final PullStage stage;
  final int tablesDone;
  final int tablesTotal;
  final String? failedReason;

  const PullStatus({
    required this.stage,
    this.tablesDone = 0,
    this.tablesTotal = 0,
    this.failedReason,
  });

  static const idle = PullStatus(stage: PullStage.idle);

  PullStatus copyWith({
    PullStage? stage,
    int? tablesDone,
    int? tablesTotal,
    String? failedReason,
  }) =>
      PullStatus(
        stage: stage ?? this.stage,
        tablesDone: tablesDone ?? this.tablesDone,
        tablesTotal: tablesTotal ?? this.tablesTotal,
        failedReason: failedReason ?? this.failedReason,
      );
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

  /// Stage of the data-pull state machine. Drives the MainLayout catch-up
  /// banner via `pullStatusProvider`. Mirrors the `isOnline` pattern — public
  /// field, exposed directly, lifted to Riverpod in app_providers.dart.
  final ValueNotifier<PullStatus> pullStatus =
      ValueNotifier<PullStatus>(PullStatus.idle);

  /// Re-entrancy guard for `pullChanges`. setCurrentUser fires it on every
  /// login boundary; the connectivity-recovery listener may also fire it;
  /// users can tap retry; FirstSyncScreen-on-error retries. Without a guard
  /// these can race and double-restore the same row range.
  bool _fullPullRunning = false;

  /// Last businessId the service is configured for. Used by the
  /// connectivity-recovery listener to know which tenant to retry against.
  /// Set inside `pullChanges` / `syncMinimumLogin` whenever they run for a
  /// given business.
  String? _currentBusinessId;

  /// Persistent failure-count key. Per-business so multi-tenant device
  /// switching doesn't conflate counts.
  static String _consecutiveFailuresKey(String businessId) =>
      'consecutive_pull_failures::$businessId';

  /// Device-wide one-shot flag for the invite_codes backfill (see
  /// [ensureBackfillOnce]). Bumping the suffix re-arms the backfill for a
  /// future table that lands in the pull path after devices have synced.
  static const _backfillCursorResetKey = 'sync_backfill_done::invite_codes_v2';

  /// Prefix of the per-business incremental-pull cursor keys written by
  /// [pullChanges]. Kept as a named constant so [ensureBackfillOnce] and
  /// the cursor read/write below can't drift.
  static const _lastSyncPrefix = 'last_sync_timestamp::';

  /// Tracks the previous value of [isOnline] so the listener can detect
  /// `false → true` transitions. ValueNotifier doesn't surface old values
  /// in listener callbacks, so we keep our own copy.
  bool _wasOnline = true;

  /// Listener fired on every [isOnline] change. On a `false → true`
  /// transition, if the last pull failed and we have a businessId, kicks
  /// off `pullChanges` once. Single shot, not a retry loop — relying on
  /// the OS-provided connectivity signal instead of polling.
  void _onOnlineChanged() {
    final nowOnline = isOnline.value;
    if (!_wasOnline &&
        nowOnline &&
        pullStatus.value.stage == PullStage.failed &&
        _currentBusinessId != null &&
        !_fullPullRunning) {
      debugPrint(
        '[SyncService] Connectivity recovered while pull was failed — '
        'auto-retrying pullChanges($_currentBusinessId)',
      );
      unawaited(pullChanges(_currentBusinessId!));
    }
    _wasOnline = nowOnline;
  }

  SupabaseSyncService(this._db, this._supabase) {
    isOnline.addListener(_onOnlineChanged);
  }

  /// Wired by AuthService to expose this device's active session id so
  /// the Realtime callback can recognise when its own row was revoked.
  String? Function()? currentSessionIdResolver;

  /// Wired by AuthService. Invoked when the Realtime callback observes
  /// the current session row being revoked by another device.
  VoidCallback? onCurrentSessionRevoked;

  /// Wired by AuthService to expose the current device user's local id
  /// (`users.id`, not auth.uid). Retained as a generic identity hook for
  /// future sync paths; no current consumer.
  String? Function()? currentUserIdResolver;

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
    'stores': 2,
    'manufacturers': 3,
    'crate_size_groups': 3,
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
      'role_tier',
      'name',
      'created_at',
      'last_updated_at',
      // NOTE: `is_active` was removed — never existed on cloud profiles.
      // No local Drift `Profiles` table enqueues profiles today, but if
      // one ever does, dropping role_tier would trigger CHECK
      // constraint 23514 (role_tier IN (2,3,4,5,6); cloud DEFAULT 1).
    },
    'users': {
      'id',
      'business_id',
      'auth_user_id',
      'name',
      'email',
      'role',
      'role_tier',
      'avatar_color',
      'biometric_enabled',
      'store_id',
      'last_notification_sent_at',
      'created_at',
      'last_updated_at',
      // NOTE: `phone`, `status`, `joined_at`, `is_deleted` were removed
      // — `phone`/`status`/`joined_at` never existed on cloud users
      // (those live on `business_members`), and `is_deleted` was
      // dropped by migration 0035 in the staff-lifecycle hard-delete
      // refactor. `role_tier` MUST be present: cloud DEFAULT is 1 and
      // the CHECK constraint `role_tier IN (2,3,4,5,6)` rejects 1,
      // so scrubbing it out causes 23514 on every fresh-row insert.
      // PIN material (pin, pin_hash, pin_salt, pin_iterations,
      // password_hash) is intentionally absent — local secret material.
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

  /// Exposes `_restoreTableData` to unit tests so a snapshot/realtime payload
  /// can be replayed against an in-memory DB without standing up a real
  /// Supabase client (the restore path only touches `_db`). The actual logic
  /// stays in `_restoreTableData` so the instance path and tests can't drift.
  @visibleForTesting
  Future<void> restoreTableDataForTesting(
    String table,
    List<dynamic> data, {
    Set<String>? fkSkipped,
  }) =>
      _restoreTableData(table, data, fkSkipped: fkSkipped);

  /// Pushes all pending local changes to Supabase.
  Future<void> pushPending() async {
    // Without an authenticated session the server sees auth.uid() as NULL,
    // so RLS denies every insert. Skip rather than burn `attempts` and rack
    // up false negatives — startAutoPush retriggers as soon as sign-in lands.
    final currentAuthUid = _supabase.auth.currentUser?.id;
    if (currentAuthUid == null) {
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

    // Order groups by FK priority so parent tables (stores, businesses,
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
      // Also reject rows whose stamped auth_user_id (L5) does not match
      // the current session — those were queued by a different signed-in
      // user on this device and would push under the wrong JWT.
      final validPayloads = <Map<String, dynamic>>[];
      final validIds = <String>[];
      final mismatchedIds = <String>[];
      final authMismatched = <SyncQueueData>[];
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
          // auth_user_id is nullable: pre-v10 rows and bootstrap-window
          // enqueues both store null and are trusted to the current user.
          // Only a NON-null tag that disagrees with the current auth.uid()
          // is a mismatch.
          if (item.authUserId != null && item.authUserId != currentAuthUid) {
            authMismatched.add(item);
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
      if (authMismatched.isNotEmpty) {
        for (final item in authMismatched) {
          await _db.syncDao.markFailed(
            item.id,
            'auth_user_mismatch: queued by ${item.authUserId}, '
                'current is $currentAuthUid',
            permanent: true,
          );
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
      await _pushDomainItems(domainItems, sessionBusinessId, currentAuthUid);
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
    String currentAuthUid,
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

      // L5: auth_user_id mismatch — row was queued by a different signed-in
      // user on this device. Pushing under the current JWT would attribute
      // the sale / inventory delta / product creation to the wrong staff.
      // Null tag (pre-v10 / bootstrap) is trusted to the current user.
      if (item.authUserId != null && item.authUserId != currentAuthUid) {
        await _db.syncDao.markFailed(
          item.id,
          'auth_user_mismatch: queued by ${item.authUserId}, '
              'current is $currentAuthUid',
          permanent: true,
        );
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
      // an `inventory_after` array of {product_id, store_id, quantity,
      // last_updated_at}. The Drift `bump_inventory_last_updated_at` trigger
      // only fires when OLD.last_updated_at IS NEW.last_updated_at; we
      // explicitly write the server's value, so the trigger is a no-op and
      // the local row matches the cloud exactly.
      final invAfter = map['inventory_after'];
      if (invAfter is List) {
        for (final raw in invAfter) {
          if (raw is! Map) continue;
          final productId = raw['product_id'] as String?;
          final storeId = raw['store_id'] as String?;
          final quantity = raw['quantity'];
          final luaStr = raw['last_updated_at'] as String?;
          if (productId == null || storeId == null || quantity is! int) {
            continue;
          }
          final lua = luaStr != null ? DateTime.tryParse(luaStr) : null;
          await (_db.update(_db.inventory)
                ..where((t) =>
                    t.productId.equals(productId) &
                    t.storeId.equals(storeId)))
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
        final crateSizeGroupId = balanceRow['crate_size_group_id'] as String?;
        final businessIdStr = balanceRow['business_id'] as String?;
        if (balance is int &&
            parsed != null &&
            crateSizeGroupId != null &&
            businessIdStr != null) {
          final customerId = balanceRow['customer_id'] as String?;
          final manufacturerId = balanceRow['manufacturer_id'] as String?;
          if (customerId != null) {
            await (_db.update(_db.customerCrateBalances)
                  ..where((t) =>
                      t.businessId.equals(businessIdStr) &
                      t.customerId.equals(customerId) &
                      t.crateSizeGroupId.equals(crateSizeGroupId)))
                .write(CustomerCrateBalancesCompanion(
              balance: Value(balance),
              lastUpdatedAt: Value(parsed),
            ));
          } else if (manufacturerId != null) {
            await (_db.update(_db.manufacturerCrateBalances)
                  ..where((t) =>
                      t.businessId.equals(businessIdStr) &
                      t.manufacturerId.equals(manufacturerId) &
                      t.crateSizeGroupId.equals(crateSizeGroupId)))
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
    final currentAuthUid = _supabase.auth.currentUser?.id;
    if (currentAuthUid == null) return;
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

    await _pushDomainItems([item], sessionBusinessId, currentAuthUid);

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

  /// Minimum-login pull: fetches only the tables required for `MainLayout`
  /// to render. Designed to complete in ~1-6 seconds depending on link
  /// speed (math in the plan file). Throws [PartialPullException] on
  /// any failure so the calling screen surfaces "check your connection".
  ///
  /// Tables (FK-safe order for restore):
  ///   profiles → businesses → users → stores
  ///
  /// Parallel fetch via `Future.wait` of `_fetchOneTable` calls (HTTP/2
  /// multiplexes the connection; on bandwidth-bound 3G the wins are
  /// modest, on latency-bound 4G they're substantial). Does NOT advance
  /// `last_sync_timestamp::<businessId>` — that's the full-pull's job.
  Future<void> syncMinimumLogin(String businessId) async {
    _currentBusinessId = businessId;
    debugPrint(
      '[SyncService] Minimum-login pull for business $businessId...',
    );
    pullStatus.value = const PullStatus(
      stage: PullStage.minimum,
      tablesTotal: 4,
    );
    // FK-safe restore order:
    //   businesses  → no inbound deps among this set
    //   stores  → references businesses
    //   users       → references businesses AND stores
    //   profiles    → cloud-only; no local Drift table so _restoreTableData
    //                 is a no-op. Kept in the fetch set so the 4-call
    //                 round-trip count matches the plan; safe to drop later
    //                 if we want one fewer request on the critical path.
    // The download is parallel via Future.wait — list ordering only
    // controls the sequential restore below.
    const tables = ['profiles', 'businesses', 'stores', 'users'];
    try {
      final fetched = await Future.wait(
        tables.map((t) => _fetchOneTable(t, businessId, null)),
      );
      for (var i = 0; i < tables.length; i++) {
        final t = tables[i];
        final data = fetched[i];
        if (data.isEmpty) continue;
        debugPrint(
          '[SyncService] Minimum-login restore $t: ${data.length} rows',
        );
        await _restoreTableData(t, data);
        pullStatus.value = pullStatus.value.copyWith(tablesDone: i + 1);
      }
      // Don't set `completed` here — minimum fires before MainLayout
      // mounts, so the user never sees the banner. Leaving stage as
      // `minimum` until the caller transitions on to the background
      // pull keeps the state machine clean.
      pullStatus.value = PullStatus.idle;
    } catch (e, st) {
      debugPrint('[SyncService] Minimum-login pull failed: $e\n$st');
      pullStatus.value = PullStatus(
        stage: PullStage.failed,
        failedReason: e.toString(),
      );
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
  ///
  /// Re-entrant calls are no-ops (early-return via `_fullPullRunning`).
  /// setCurrentUser, the connectivity-recovery listener, a manual banner
  /// retry, and a FirstSyncScreen retry all converge on this single entry
  /// point and must not race each other.
  ///
  /// One-time, device-wide backfill for tables that were added to the pull
  /// path AFTER devices had already advanced their per-business
  /// `last_sync_timestamp::<businessId>` cursor. Incremental pulls only return
  /// rows with `last_updated_at > cursor`, so rows that already existed when
  /// the table joined the snapshot (e.g. invite_codes created before 0053)
  /// sit below the cursor and never arrive on an already-synced device.
  ///
  /// Clearing every `last_sync_timestamp::*` key forces the next
  /// [pullChanges] on each tenant to run full (`since = null`) and re-pull all
  /// tables, including the newly-pullable one, exactly once. Guarded by a
  /// device-wide SharedPreferences flag so it runs a single time.
  ///
  /// No data loss: a full pull restores via `insertOnConflictUpdate`, and the
  /// `sync_queue` (pending local writes) is untouched. New rows already arrive
  /// via incremental pull + realtime; this only recovers the historical ones.
  Future<void> ensureBackfillOnce() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_backfillCursorResetKey) ?? false) return;

    final cursorKeys = prefs
        .getKeys()
        .where((k) => k.startsWith(_lastSyncPrefix))
        .toList();
    for (final k in cursorKeys) {
      await prefs.remove(k);
    }
    await prefs.setBool(_backfillCursorResetKey, true);
    debugPrint(
      '[SyncService] invite_codes backfill: cleared ${cursorKeys.length} '
      'sync cursor(s) — next pull(s) run full to backfill the table.',
    );
  }

  Future<void> pullChanges(String businessId) async {
    if (_fullPullRunning) {
      debugPrint(
        '[SyncService] pullChanges already in flight for $businessId — skipping',
      );
      return;
    }
    _fullPullRunning = true;
    _currentBusinessId = businessId;
    pullStatus.value = const PullStatus(stage: PullStage.background);

    // One-shot backfill: clear stale cursors BEFORE reading this tenant's, so
    // the read below sees null and this pull runs full. Runs once per device.
    await ensureBackfillOnce();

    final prefs = await SharedPreferences.getInstance();
    // Per-business key: a wiped DB or a device that has switched businesses
    // must not inherit the timestamp from a different tenant, otherwise
    // incremental pulls skip rows that haven't been touched in the cloud
    // since the unrelated last sync.
    final key = '$_lastSyncPrefix$businessId';
    final lastSyncStr = prefs.getString(key);
    DateTime? since;
    if (lastSyncStr != null) {
      since = DateTime.tryParse(lastSyncStr);
    }

    try {
      final skipped = await pullInitialData(businessId, since: since);

      final deferredKey = pendingDeferredTablesKey(businessId);
      if (skipped.isEmpty) {
        // Clean pull — advance the cursor and clear any prior deferred-tables
        // record so the SyncIssues UI stops surfacing stale "catching up" state.
        await prefs.setString(key, DateTime.now().toUtc().toIso8601String());
        await prefs.remove(deferredKey);
      } else {
        // Deferred pull (leaf-deferred and/or FK-orphan skips). CLEAR the
        // incremental cursor so the NEXT pull is a true full pull
        // (`since == null`). A held non-null cursor would keep the next pull
        // incremental and only re-send rows changed after it — so a parent
        // created before the cursor (e.g. an unchanged categories /
        // crate_size_groups row) is never re-fetched, and an FK-orphaned
        // child (a product referencing it) could never catch up no matter how
        // many times the user taps Retry. A full pull re-fetches every current
        // cloud row, including those parents, after which the skipped child
        // inserts cleanly. Persist the deferred set so SyncIssues can show
        // what's still pending.
        debugPrint(
          '[SyncService] Forcing full re-pull (cleared cursor); '
          '${skipped.length} deferred table(s): ${skipped.join(", ")}',
        );
        await prefs.remove(key);
        await prefs.setString(deferredKey, skipped.join(','));
      }
      // Clean run — reset consecutive-failure count and signal completion.
      // Deferred-only completion still counts as "caught up" for banner
      // purposes; the deferred set lives in its own pref and the
      // SyncIssues "Catching up" card surfaces it independently.
      await prefs.setInt(_consecutiveFailuresKey(businessId), 0);
      pullStatus.value = pullStatus.value.copyWith(
        stage: PullStage.completed,
      );
    } catch (e, st) {
      debugPrint('[SyncService] pullChanges failed: $e\n$st');
      final fails =
          (prefs.getInt(_consecutiveFailuresKey(businessId)) ?? 0) + 1;
      await prefs.setInt(_consecutiveFailuresKey(businessId), fails);
      pullStatus.value = PullStatus(
        stage: PullStage.failed,
        failedReason: e.toString(),
      );
      rethrow;
    } finally {
      _fullPullRunning = false;
    }
  }

  /// Tables fed into `_restoreTableData` after a pull, in FK-safe order.
  /// `crates` removed — cloud schema has only `crate_size_groups`.
  static const _pullOrder = [
    'businesses',
    'crate_size_groups',
    'manufacturers',
    'stores',
    'users',
    // Roles + membership (master plan §2.4). FK-safe order: roles before its
    // dependents; user_businesses/user_stores after users + stores (above).
    // `permissions` is global (seeded by migration on both sides, not pulled).
    'roles',
    'role_settings',
    'role_permissions',
    'user_businesses',
    'user_stores',
    // invite_codes references business/role/store/generated-by-user — all
    // pulled above — so it's FK-safe here. Pulled so the Staff Management
    // Invites tab (§9.3, CEO+Manager) shows codes created on any device in
    // the business, not just the creator's device.
    'invite_codes',
    'profiles',
    'categories',
    'suppliers',
    'products',
    'inventory',
    'customers',
    'orders',
    'order_items',
    'shipments',
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
    'manufacturer_crate_balances',
    'crate_ledger',
    'system_config',
    'price_lists',
    'payment_transactions',
    // Funds Register (§23). fund_transactions references funds_accounts +
    // orders + payment_transactions, so it follows all three.
    'funds_accounts',
    'fund_days',
    'fund_transactions',
    'sessions',
    'settings',
  ];

  /// Tables we treat as "deferrable" on first-pull: leaf tables that nothing
  /// FK-references, so a missing slice can't trip restore-time FK violations
  /// in any other table. If only these fail after retry in the per-table
  /// fallback, the pull proceeds with what arrived and `pullChanges`
  /// intentionally does NOT advance `last_sync_timestamp::<businessId>`
  /// so the next pull is another full pull and catches up the deferred
  /// slices on a (hopefully) better connection.
  ///
  /// Adding a table here is a load-bearing safety claim. Before adding,
  /// confirm there are no inbound FK references with BOTH:
  ///   grep -nE "\.references\(<TableName>," lib/core/database/app_database.dart
  ///   grep -nE "REFERENCES public\.<table_name>\b" supabase/migrations/*.sql
  /// Both must return zero matches. If anything FK-references the table,
  /// deferring it would break the dependent restore.
  static const Set<String> _deferrableTables = {
    'stock_transactions',
    'sessions',
    'activity_logs',
    'notifications',
    'payment_transactions',
    'crate_ledger',
  };

  /// SharedPreferences key (per-business) carrying the last set of tables
  /// that were leaf-deferred on an otherwise-successful pull. SyncIssues
  /// reads this to surface "still catching up" UI. Cleared when a clean
  /// full pull completes.
  static String pendingDeferredTablesKey(String businessId) =>
      'pending_deferred_tables::$businessId';

  /// Pulls data for the current business from Supabase and populates the local DB.
  /// If [since] is provided, performs an incremental pull.
  ///
  /// Fast path: a single `pos_pull_snapshot` RPC returns every table's rows
  /// in one round-trip. Falls back to the per-table PostgREST path if the
  /// RPC isn't deployed yet (the migration in 0005_sync_rpcs.sql may not be
  /// applied to every environment).
  ///
  /// Returns the set of tables that were leaf-deferred on this pull (subset
  /// of [_deferrableTables]). When non-empty, the caller (pullChanges) must
  /// NOT advance `last_sync_timestamp::<businessId>` so the next pull is a
  /// fresh full pull that catches up the deferred slices.
  Future<Set<String>> pullInitialData(
    String businessId, {
    DateTime? since,
  }) async {
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
    Set<String> skipped = const <String>{};
    try {
      final result = await _supabase.rpc(
        'pos_pull_snapshot',
        params: {
          'p_business_id': businessId,
          'p_since': since?.toIso8601String(),
        },
      ).timeout(const Duration(seconds: 60));
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

    if (snapshot == null) {
      final fallback = await _pullViaPostgRest(businessId, since);
      snapshot = fallback.data;
      skipped = fallback.skipped;
    }

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
        // Same loud-fail contract as the per-table fallback: an empty
        // users slice would FK-fail every restore that references
        // staff_id. Refuse to proceed rather than silently corrupt
        // the local DB.
        throw const PartialPullException({'users'});
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

    // Tables that actually have rows to restore — drives the banner's
    // "$done / $total" counter. Tables with empty slices are skipped so
    // the progress bar reflects real work, not iteration over the
    // full _pullOrder.
    final restoreList = [
      for (final t in _pullOrder)
        if ((snapshot[t]?.isNotEmpty ?? false)) t,
    ];
    final restoreTotal = restoreList.length;
    var restoreDone = 0;
    // Only update tablesTotal if we're inside an outer stage (background);
    // the minimum-pull path uses a different stage with a fixed total.
    if (pullStatus.value.stage == PullStage.background) {
      pullStatus.value = pullStatus.value.copyWith(tablesTotal: restoreTotal);
    }
    // Collects tables that skipped one or more orphaned rows (a referenced
    // parent slice was absent from this snapshot). Merged into `skipped`
    // below so the caller holds the sync cursor and the next full pull
    // retries those rows once their parent has arrived.
    final fkSkipped = <String>{};
    for (final table in restoreList) {
      final data = snapshot[table]!;
      debugPrint('[SyncService] Syncing $table: ${data.length} rows');
      await _restoreTableData(table, data, fkSkipped: fkSkipped);
      restoreDone++;
      if (pullStatus.value.stage == PullStage.background) {
        pullStatus.value = pullStatus.value.copyWith(tablesDone: restoreDone);
      }
    }
    if (fkSkipped.isNotEmpty) {
      debugPrint(
        '[SyncService] Restore skipped orphaned rows in: '
        '${fkSkipped.join(", ")}. Holding cursor for retry.',
      );
      skipped = {...skipped, ...fkSkipped};
    }
    return skipped;
  }

  /// Per-table parallel fetch — the original pull path. Used as a fallback
  /// when the snapshot RPC is unavailable.
  ///
  /// Two-pass design:
  /// 1. **Parallel first pass.** Fetch every table concurrently for speed.
  /// 2. **Sequential retry pass.** For any first-pass failure, wait a
  ///    short backoff then retry once. Sequential not parallel: the
  ///    first-pass failures are typically timeouts on a congested
  ///    connection, and a parallel burst tends to reproduce the same
  ///    condition.
  ///
  /// If retries leave **critical** tables failed, throws
  /// [PartialPullException]. If only [_deferrableTables] are still
  /// failed, returns them in the record's `skipped` field; the caller
  /// is responsible for not advancing the per-business sync cursor so
  /// the next pull catches them up.
  Future<({Map<String, List<dynamic>> data, Set<String> skipped})>
      _pullViaPostgRest(
    String businessId,
    DateTime? since,
  ) async {
    final firstPass = await Future.wait(
      _pullOrder.map((table) async {
        try {
          return _FetchOutcome(
            table,
            await _fetchOneTable(table, businessId, since),
            null,
          );
        } catch (e) {
          return _FetchOutcome(table, null, e);
        }
      }),
    );

    final results = <String, List<dynamic>>{};
    final firstPassFailures = <_FetchOutcome>[];
    for (final outcome in firstPass) {
      if (outcome.error == null) {
        results[outcome.table] = outcome.data!;
      } else {
        firstPassFailures.add(outcome);
      }
    }

    if (firstPassFailures.isEmpty) {
      return (data: results, skipped: const <String>{});
    }

    // Backoff before the sequential retry. Instant retry on a congested
    // connection tends to fail for the same reason as the first attempt.
    await Future.delayed(const Duration(milliseconds: 1500));

    final failed = <String>{};
    for (final outcome in firstPassFailures) {
      debugPrint(
        '[SyncService] First-pass fetch failed for ${outcome.table}: '
        '${outcome.error}. Retrying after backoff...',
      );
      try {
        final data = await _fetchOneTable(outcome.table, businessId, since);
        results[outcome.table] = data;
        debugPrint(
          '[SyncService] Retry succeeded for ${outcome.table}: '
          '${data.length} rows',
        );
      } catch (e) {
        debugPrint('[SyncService] Retry failed for ${outcome.table}: $e');
        results[outcome.table] = const <dynamic>[];
        failed.add(outcome.table);
      }
    }

    if (failed.isEmpty) {
      return (data: results, skipped: const <String>{});
    }

    // Partition: anything outside the leaf allowlist is a critical
    // failure that would corrupt the restore. Only-leaf failures are
    // recoverable (next full pull catches them up) so we return them
    // for the caller to track and surface.
    final critical = failed.difference(_deferrableTables);
    if (critical.isNotEmpty) {
      throw PartialPullException(critical);
    }
    debugPrint(
      '[SyncService] Continuing past deferrable failures: '
      '${failed.join(", ")}. last_sync_timestamp will not advance; '
      'next pull will be a full pull to catch up.',
    );
    return (data: results, skipped: failed);
  }

  /// Single-table PostgREST fetch. Extracted so the parallel first pass
  /// and the sequential retry pass share one source of truth for the
  /// query shape + timeout.
  ///
  /// 25s client timeout (vs the previous 15s) absorbs response-download
  /// time on slow cellular without exceeding the Supabase gateway
  /// window. The harder ceiling is the server-side `statement_timeout`
  /// for the `authenticated` role (8s on Supabase platform default),
  /// but that bounds query execution, not the network leg.
  Future<List<dynamic>> _fetchOneTable(
    String table,
    String businessId,
    DateTime? since,
  ) async {
    final isGlobal = table == 'system_config';
    var query = _supabase.from(table).select();

    if (!isGlobal) {
      // The cloud `businesses` table has no `business_id` column — its `id`
      // IS the business id. All other tables filter by `business_id`.
      final filterColumn = table == 'businesses' ? 'id' : 'business_id';
      query = query.eq(filterColumn, businessId);
    }

    // The `businesses` row is the FK target for almost everything local.
    // Always fetch it unconditionally so a stale `since` can't produce a
    // sync where children try to insert against a missing parent.
    if (since != null && table != 'businesses') {
      query = query.gt('last_updated_at', since.toIso8601String());
    }

    final List<dynamic> data =
        await query.timeout(const Duration(seconds: 25));
    return data;
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
  /// queue before the store backfill INSERT had committed, so the
  /// store was missing and the customer/wallet FK-failed against a
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
            // Supabase fires signedIn before AuthService.setCurrentUser
            // restores the Drift _currentBusinessId, so clearFailureBackoff
            // (whereBusiness → requireBusinessId) would throw on a
            // logout → re-login. _scheduleDebouncedPush is safe — pushPending
            // self-guards on session businessId.
            if (_db.currentBusinessId != null) {
              await _db.syncDao.clearFailureBackoff();
            }
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

  /// Enqueues an upsert for any store that has never been synced
  /// (`lastUpdatedAt IS NULL`). Onboarding originally inserted stores
  /// without going through the sync queue, leaving customer/product FKs
  /// dangling in the cloud. Idempotent: marking `lastUpdatedAt` after
  /// enqueueing prevents re-queueing on subsequent startups.
  Future<void> _backfillUnsyncedStores() async {
    try {
      final whs = await (_db.select(
        _db.stores,
      )..where((t) => t.lastUpdatedAt.isNull())).get();
      if (whs.isEmpty) return;

      final now = DateTime.now();
      var enqueued = 0;
      for (final w in whs) {
        final businessId = w.businessId;
        await _db.syncDao.enqueue(
          'stores:upsert',
          jsonEncode({
            'id': w.id,
            'business_id': businessId,
            'name': w.name,
            'location': w.location,
            'last_updated_at': now.toIso8601String(),
            'is_deleted': w.isDeleted,
          }),
        );
        await (_db.update(_db.stores)..where((t) => t.id.equals(w.id)))
            .write(StoresCompanion(lastUpdatedAt: Value(now)));
        enqueued++;
      }

      if (enqueued > 0) {
        debugPrint('[SyncService] Store backfill: enqueued=$enqueued');
      }
    } catch (e) {
      debugPrint('[SyncService] Store backfill failed: $e');
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
      // Same guard as the auth-state listener: a connectivity flip can land
      // before AuthService.setCurrentUser has restored the businessId on
      // app start, and clearFailureBackoff would throw via requireBusinessId.
      if (_db.currentBusinessId != null) {
        await _db.syncDao.clearFailureBackoff();
      }
      _scheduleDebouncedPush();

      final businessId = _db.businessIdResolver.call();
      if (businessId != null) {
        unawaited(() async {
          try {
            final prefs = await SharedPreferences.getInstance();
            final key = '$_lastSyncPrefix$businessId';
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
        // Post-0039 (unified identity alignment), fresh CEO onboarding
        // and invite redemption both produce local `users.id` values
        // that already match the cloud's. So this backfill should be
        // a no-op for any device that onboarded after 0039 landed.
        // If we DO enqueue rows, one of these is true:
        //   * The device is a pre-0039 install with legacy local rows
        //     whose ids never matched cloud (one-shot legitimate use).
        //   * A new code path is creating local users rows without
        //     going through the aligned RPC — i.e. the third-id source
        //     has crept back in. Investigate immediately.
        // The flag is per-business, so this fires at most once per
        // (device, business) and the log is sticky enough to catch.
        debugPrint(
          '[SyncService] Users backfill: NOTE post-0039 this routine '
          'should be a no-op for freshly-onboarded devices. If you see '
          'this on a fresh install, the local↔cloud id alignment has '
          'regressed — investigate. See DEFERRED.md "Three-id mismatch '
          'on fresh CEO onboarding".',
        );
      }
    } catch (e) {
      debugPrint('[SyncService] Users backfill failed: $e');
    }
  }

  Future<void> _backfillAllUnsyncedTables() async {
    try {
      await _backfillUnsyncedStores();
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

  /// True if [e] is a SQLite FOREIGN KEY constraint violation (extended
  /// result code 787 / SQLITE_CONSTRAINT_FOREIGNKEY). Matched by message so
  /// we don't depend on the concrete `SqliteException` type, which drift
  /// surfaces differently across executors.
  static bool _isForeignKeyViolation(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('foreign key constraint failed') ||
        s.contains('sqlite_constraint_foreignkey') ||
        s.contains('(787)');
  }

  /// Inserts one restore row, isolating FOREIGN KEY violations so a single
  /// orphaned child can't abort the whole restore transaction and crash the
  /// pull. An FK violation here means the referenced parent slice is
  /// genuinely absent from THIS snapshot — a supplier/manufacturer/category
  /// the CEO created inline that this device's pull didn't carry, or a parent
  /// still pending push. A second in-pull pass wouldn't help: parents restore
  /// before their children in [_pullOrder], so the parent isn't arriving in
  /// this pull at all. We skip-and-log the row and record its table in
  /// [fkSkipped]; the caller (pullChanges) holds the sync cursor so the next
  /// full pull retries it once the parent has arrived, and SyncIssues surfaces
  /// it in the "Catching up" card. Non-FK errors rethrow unchanged.
  /// See CLAUDE.md §5 — restore is sync-exception #1, so no enqueue concerns.
  Future<void> _insertResilient(
    String table,
    Map<String, dynamic> r,
    Set<String>? fkSkipped,
    Future<void> Function() doInsert,
  ) async {
    try {
      await doInsert();
    } catch (e) {
      if (!_isForeignKeyViolation(e)) rethrow;
      fkSkipped?.add(table);
      // Surface the row's FK references (every camelCase key ending in `Id`,
      // minus the row's own `id`) so triage can see which parent is missing
      // without re-deriving it from logs. SQLite's FK error doesn't name the
      // offending column, so this is the closest we get to "which parent".
      final fkRefs = r.entries
          .where((e) => e.key != 'id' && e.key.endsWith('Id'))
          .map((e) => '${e.key}=${e.value}')
          .join(', ');
      debugPrint(
        '[SyncService] Skipped orphaned $table row ${r['id']} during restore '
        '— a referenced parent is absent locally [$fkRefs]. Cleared cursor; '
        'the next pull is a full re-pull to fetch the missing parent. $e',
      );
    }
  }

  /// Restore rows into an append-only ledger table (`_ledgerTables` in
  /// app_database.dart). Pull is catch-up only: a full upsert would trip the
  /// BEFORE UPDATE trigger because domain RPCs stamp `created_at` server-side,
  /// so the cloud row always disagrees with the locally-written row on an
  /// immutable column. Void columns (`voidedAt/voidedBy/voidReason` plus
  /// `lastUpdatedAt`) are explicitly mutable, so they ride in a separate
  /// targeted update gated by `t.voidedAt.isNull()` — a local-then-newer void
  /// isn't clobbered by a stale cloud snapshot.
  Future<void> _restoreLedgerTable<TableT extends Table,
      RowT extends Insertable<RowT>>(
    List<dynamic> rows, {
    required String tableName,
    required TableInfo<TableT, RowT> table,
    required RowT Function(Map<String, dynamic>) fromJson,
    required DateTime? Function(RowT data) voidedAtOf,
    required Expression<bool> Function(TableT t, RowT data) whereNotYetVoided,
    required UpdateCompanion<RowT> Function(RowT data) buildVoidCompanion,
    Set<String>? fkSkipped,
  }) async {
    for (var r in rows) {
      final map = r as Map<String, dynamic>;
      final data = fromJson(map);
      // INSERT OR IGNORE absorbs PK/UNIQUE conflicts but NOT foreign-key
      // violations (SQLite's conflict algorithm never applies to FKs), so a
      // ledger row referencing an absent parent (e.g. a stock_transaction for
      // a product whose supplier slice didn't arrive) would still abort the
      // pull. Wrap it in the same skip-and-log resilience as the upsert path.
      await _insertResilient(tableName, map, fkSkipped, () async {
        await _db.into(table).insert(data, mode: InsertMode.insertOrIgnore);
        if (voidedAtOf(data) != null) {
          await (_db.update(table)..where((t) => whereNotYetVoided(t, data)))
              .write(buildVoidCompanion(data));
        }
      });
    }
  }

  Future<void> _restoreTableData(
    String table,
    List<dynamic> data, {
    Set<String>? fkSkipped,
  }) async {
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
        case 'stores':
          for (var r in rows) {
            await _db
                .into(_db.stores)
                .insertOnConflictUpdate(StoreData.fromJson(r));
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
          //   businessId, authUserId, name, email, storeId,
          //   createdAt, lastNotificationSentAt, lastUpdatedAt.
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

            if (existing != null) {
              await (_db.update(_db.users)
                ..where((u) => u.id.equals(id))).write(
                UsersCompanion(
                  businessId: Value(r['businessId'] as String),
                  authUserId: Value(r['authUserId'] as String?),
                  name: Value(r['name'] as String? ?? ''),
                  email: Value(r['email'] as String?),
                  storeId: Value(r['storeId'] as String?),
                  lastNotificationSentAt: Value(lastNotificationSentAt),
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
                      storeId: Value(r['storeId'] as String?),
                      createdAt: Value(createdAt),
                      lastNotificationSentAt: Value(lastNotificationSentAt),
                      lastUpdatedAt: Value(lastUpdatedAt),
                    ),
                  );
            }
          }
          break;
        // Roles + membership (master plan §2.4). Plain synced tenant tables —
        // no device-local columns to protect, so the simple fromJson upsert
        // (like stores) is correct. Restore order is FK-safe via _pullOrder:
        // roles → role_settings/role_permissions → user_businesses/user_stores,
        // all after businesses/users/stores.
        case 'roles':
          for (var r in rows) {
            await _db
                .into(_db.roles)
                .insertOnConflictUpdate(RoleData.fromJson(r));
          }
          break;
        case 'role_permissions':
          for (var r in rows) {
            await _db
                .into(_db.rolePermissions)
                .insertOnConflictUpdate(RolePermissionData.fromJson(r));
          }
          break;
        case 'role_settings':
          for (var r in rows) {
            await _db
                .into(_db.roleSettings)
                .insertOnConflictUpdate(RoleSettingData.fromJson(r));
          }
          break;
        case 'user_businesses':
          for (var r in rows) {
            await _db
                .into(_db.userBusinesses)
                .insertOnConflictUpdate(UserBusinessData.fromJson(r));
          }
          break;
        case 'user_stores':
          for (var r in rows) {
            await _db
                .into(_db.userStores)
                .insertOnConflictUpdate(UserStoreData.fromJson(r));
          }
          break;
        // invite_codes (master plan §6/§9.3). Plain synced tenant table — no
        // device-local columns, so the simple fromJson upsert is correct.
        // Restore order is FK-safe via _pullOrder (after businesses/roles/
        // stores/users). Realtime delivery routes here too via the public:*
        // wildcard, so codes also appear live on other devices.
        case 'invite_codes':
          for (var r in rows) {
            await _db
                .into(_db.inviteCodes)
                .insertOnConflictUpdate(InviteCodeData.fromJson(r));
          }
          break;
        case 'products':
          for (var r in rows) {
            await _insertResilient(
              'products',
              r,
              fkSkipped,
              () => _db
                  .into(_db.products)
                  .insertOnConflictUpdate(ProductData.fromJson(r)),
            );
          }
          break;
        case 'crate_size_groups':
          for (var r in rows) {
            await _db
                .into(_db.crateSizeGroups)
                .insertOnConflictUpdate(CrateSizeGroupData.fromJson(r));
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
            await _insertResilient(
              'inventory',
              r,
              fkSkipped,
              () => _db
                  .into(_db.inventory)
                  .insertOnConflictUpdate(InventoryData.fromJson(r)),
            );
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
            // FK-resilient: an order references users(staff_id) /
            // stores(store_id) / customers(customer_id). If a parent slice
            // hasn't arrived yet, skip-and-defer instead of aborting the whole
            // pull (the deferred set forces a full re-pull that catches it up).
            await _insertResilient(
              'orders',
              r,
              fkSkipped,
              () => _db
                  .into(_db.orders)
                  .insertOnConflictUpdate(OrderData.fromJson(r)),
            );
          }
          break;
        case 'order_items':
          for (var r in rows) {
            r['priceSnapshot'] = _stringifyJsonb(r['priceSnapshot']);
            await _insertResilient(
              'order_items',
              r,
              fkSkipped,
              () => _db
                  .into(_db.orderItems)
                  .insertOnConflictUpdate(OrderItemData.fromJson(r)),
            );
          }
          break;
        case 'expenses':
          for (var r in rows) {
            // FK-resilient: expenses reference users / stores / categories.
            await _insertResilient(
              'expenses',
              r,
              fkSkipped,
              () => _db
                  .into(_db.expenses)
                  .insertOnConflictUpdate(ExpenseData.fromJson(r)),
            );
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
            // FK-resilient: references manufacturers / crate_size_groups.
            await _insertResilient(
              'manufacturer_crate_balances',
              r,
              fkSkipped,
              () => _db
                  .into(_db.manufacturerCrateBalances)
                  .insertOnConflictUpdate(ManufacturerCrateBalance.fromJson(r)),
            );
          }
          break;
        case 'crate_ledger':
          await _restoreLedgerTable(
            rows,
            tableName: 'crate_ledger',
            fkSkipped: fkSkipped,
            table: _db.crateLedger,
            fromJson: CrateLedgerData.fromJson,
            voidedAtOf: (d) => d.voidedAt,
            whereNotYetVoided: (t, d) =>
                t.id.equals(d.id) & t.voidedAt.isNull(),
            buildVoidCompanion: (d) => CrateLedgerCompanion(
              voidedAt: Value(d.voidedAt),
              voidedBy: Value(d.voidedBy),
              voidReason: Value(d.voidReason),
              lastUpdatedAt: Value(d.lastUpdatedAt),
            ),
          );
          break;
        case 'system_config':
          for (var r in rows) {
            r['value'] = _stringifyJsonb(r['value']);
            await _db
                .into(_db.systemConfig)
                .insertOnConflictUpdate(SystemConfigData.fromJson(r));
          }
          break;
        case 'shipments':
          for (var r in rows) {
            await _db
                .into(_db.shipments)
                .insertOnConflictUpdate(ShipmentData.fromJson(r));
          }
          break;
        case 'purchase_items':
          for (var r in rows) {
            await _insertResilient(
              'purchase_items',
              r,
              fkSkipped,
              () => _db
                  .into(_db.purchaseItems)
                  .insertOnConflictUpdate(PurchaseItemData.fromJson(r)),
            );
          }
          break;
        case 'customer_crate_balances':
          for (var r in rows) {
            // FK-resilient: references customers / crate_size_groups.
            await _insertResilient(
              'customer_crate_balances',
              r,
              fkSkipped,
              () => _db
                  .into(_db.customerCrateBalances)
                  .insertOnConflictUpdate(CustomerCrateBalance.fromJson(r)),
            );
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
            await _insertResilient(
              'price_lists',
              r,
              fkSkipped,
              () => _db
                  .into(_db.priceLists)
                  .insertOnConflictUpdate(PriceListData.fromJson(r)),
            );
          }
          break;
        case 'payment_transactions':
          await _restoreLedgerTable(
            rows,
            tableName: 'payment_transactions',
            fkSkipped: fkSkipped,
            table: _db.paymentTransactions,
            fromJson: PaymentTransactionData.fromJson,
            voidedAtOf: (d) => d.voidedAt,
            whereNotYetVoided: (t, d) =>
                t.id.equals(d.id) & t.voidedAt.isNull(),
            buildVoidCompanion: (d) => PaymentTransactionsCompanion(
              voidedAt: Value(d.voidedAt),
              voidedBy: Value(d.voidedBy),
              voidReason: Value(d.voidReason),
              lastUpdatedAt: Value(d.lastUpdatedAt),
            ),
          );
          break;
        case 'stock_transfers':
          for (var r in rows) {
            await _insertResilient(
              'stock_transfers',
              r,
              fkSkipped,
              () => _db
                  .into(_db.stockTransfers)
                  .insertOnConflictUpdate(StockTransferData.fromJson(r)),
            );
          }
          break;
        case 'stock_adjustments':
          for (var r in rows) {
            await _insertResilient(
              'stock_adjustments',
              r,
              fkSkipped,
              () => _db
                  .into(_db.stockAdjustments)
                  .insertOnConflictUpdate(StockAdjustmentData.fromJson(r)),
            );
          }
          break;
        case 'activity_logs':
          await _restoreLedgerTable(
            rows,
            tableName: 'activity_logs',
            fkSkipped: fkSkipped,
            table: _db.activityLogs,
            fromJson: ActivityLogData.fromJson,
            voidedAtOf: (d) => d.voidedAt,
            whereNotYetVoided: (t, d) =>
                t.id.equals(d.id) & t.voidedAt.isNull(),
            buildVoidCompanion: (d) => ActivityLogsCompanion(
              voidedAt: Value(d.voidedAt),
              voidedBy: Value(d.voidedBy),
              voidReason: Value(d.voidReason),
              lastUpdatedAt: Value(d.lastUpdatedAt),
            ),
          );
          break;
        case 'notifications':
          for (var r in rows) {
            await _db
                .into(_db.notifications)
                .insertOnConflictUpdate(NotificationData.fromJson(r));
          }
          break;
        case 'settings':
          // Settings rows are semantically keyed by (business_id, key),
          // not by id. The cloud's `complete_onboarding` RPC mints its
          // own gen_random_uuid() ids, and any flow that ever creates a
          // local settings row with a different id (legacy local
          // mirror, hypothetical future code) would collide here on the
          // UNIQUE(business_id, key) constraint if we used the default
          // PK-keyed ON CONFLICT.
          //
          // Upsert by (business_id, key): on conflict, also align the
          // local row's `id` to the cloud's id so subsequent pushes and
          // pulls converge on a single canonical row. Safe to overwrite
          // `id` because nothing else FK-references settings.id.
          for (var r in rows) {
            final parsed = SettingData.fromJson(r);
            await _db.into(_db.settings).insert(
                  parsed,
                  onConflict: DoUpdate(
                    (_) => SettingsCompanion(
                      id: Value(parsed.id),
                      value: Value(parsed.value),
                      lastUpdatedAt: Value(parsed.lastUpdatedAt),
                    ),
                    target: [_db.settings.businessId, _db.settings.key],
                  ),
                );
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
          await _restoreLedgerTable(
            rows,
            tableName: 'stock_transactions',
            fkSkipped: fkSkipped,
            table: _db.stockTransactions,
            fromJson: StockTransactionData.fromJson,
            voidedAtOf: (d) => d.voidedAt,
            whereNotYetVoided: (t, d) =>
                t.id.equals(d.id) & t.voidedAt.isNull(),
            buildVoidCompanion: (d) => StockTransactionsCompanion(
              voidedAt: Value(d.voidedAt),
              voidedBy: Value(d.voidedBy),
              voidReason: Value(d.voidReason),
              lastUpdatedAt: Value(d.lastUpdatedAt),
            ),
          );
          break;
        case 'customer_wallets':
          for (var r in rows) {
            // FK-resilient: references customers.
            await _insertResilient(
              'customer_wallets',
              r,
              fkSkipped,
              () => _db
                  .into(_db.customerWallets)
                  .insertOnConflictUpdate(CustomerWalletData.fromJson(r)),
            );
          }
          break;
        case 'wallet_transactions':
          await _restoreLedgerTable(
            rows,
            tableName: 'wallet_transactions',
            fkSkipped: fkSkipped,
            table: _db.walletTransactions,
            fromJson: WalletTransactionData.fromJson,
            voidedAtOf: (d) => d.voidedAt,
            whereNotYetVoided: (t, d) =>
                t.id.equals(d.id) & t.voidedAt.isNull(),
            buildVoidCompanion: (d) => WalletTransactionsCompanion(
              voidedAt: Value(d.voidedAt),
              voidedBy: Value(d.voidedBy),
              voidReason: Value(d.voidReason),
              lastUpdatedAt: Value(d.lastUpdatedAt),
            ),
          );
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
            await _insertResilient(
              'pending_crate_returns',
              r,
              fkSkipped,
              () => _db
                  .into(_db.pendingCrateReturns)
                  .insertOnConflictUpdate(PendingCrateReturnData.fromJson(r)),
            );
          }
          break;
        // ── Funds Register (§23) ──────────────────────────────────────────
        case 'funds_accounts':
          for (var r in rows) {
            await _insertResilient(
              'funds_accounts',
              r,
              fkSkipped,
              () => _db
                  .into(_db.fundsAccounts)
                  .insertOnConflictUpdate(FundsAccountData.fromJson(r)),
            );
          }
          break;
        case 'fund_days':
          for (var r in rows) {
            await _insertResilient(
              'fund_days',
              r,
              fkSkipped,
              () => _db
                  .into(_db.fundDays)
                  .insertOnConflictUpdate(FundDayData.fromJson(r)),
            );
          }
          break;
        case 'fund_transactions':
          // Append-only ledger — insert-or-ignore (an UPDATE would trip the
          // immutability trigger); void columns ride a targeted update.
          await _restoreLedgerTable(
            rows,
            tableName: 'fund_transactions',
            fkSkipped: fkSkipped,
            table: _db.fundTransactions,
            fromJson: FundTransactionData.fromJson,
            voidedAtOf: (d) => d.voidedAt,
            whereNotYetVoided: (t, d) =>
                t.id.equals(d.id) & t.voidedAt.isNull(),
            buildVoidCompanion: (d) => FundTransactionsCompanion(
              voidedAt: Value(d.voidedAt),
              voidedBy: Value(d.voidedBy),
              voidReason: Value(d.voidReason),
              lastUpdatedAt: Value(d.lastUpdatedAt),
            ),
          );
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
