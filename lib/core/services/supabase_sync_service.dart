import 'dart:async';
import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:reebaplus_pos/core/services/first_load_marker_service.dart';
import 'package:reebaplus_pos/core/utils/order_number.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// sync-exempt-file: this is the sync engine — `_restoreTableData`,
// `_applyDomainResponse`, `_deleteLocalRowById`, and the backfill path write
// cloud-authoritative state back into the local mirror (CLAUDE.md §5 #1/#2).
// Enqueuing here would push the cloud's own data back to it. The sync-write
// leak scanner (test/sync/sync_raw_write_leak_test.dart) skips this file.

/// Thrown by [SupabaseSyncService.flushSale] when a `domain:pos_record_sale`
/// envelope fails permanently at the server (insufficient_stock, FK / unique
/// violation, tenant mismatch). The local optimistic sale has already
/// committed; the caller is responsible for compensating (cancelling the
/// order, refunding stock, voiding ledgers) and surfacing to the UI.
class SaleSyncException implements Exception {
  final String orderId;
  final String errorMessage;
  const SaleSyncException({required this.orderId, required this.errorMessage});
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
  /// Row-weighted progress: total rows across all non-empty restore tables.
  /// Zero until the snapshot row counts are known (the brief initial-fetch window).
  final int rowsTotal;
  /// Row-weighted progress: rows restored so far. Advances per table (by that
  /// table's row count) as each restore completes.
  final int rowsDone;
  final String? failedReason;

  const PullStatus({
    required this.stage,
    this.tablesDone = 0,
    this.tablesTotal = 0,
    this.rowsTotal = 0,
    this.rowsDone = 0,
    this.failedReason,
  });

  static const idle = PullStatus(stage: PullStage.idle);

  /// Row-weighted percentage [0, 100] or null if rowsTotal is not yet known.
  int? get rowPercent =>
      rowsTotal > 0 ? ((rowsDone / rowsTotal) * 100).clamp(0, 100).round() : null;

  PullStatus copyWith({
    PullStage? stage,
    int? tablesDone,
    int? tablesTotal,
    int? rowsTotal,
    int? rowsDone,
    String? failedReason,
  }) => PullStatus(
    stage: stage ?? this.stage,
    tablesDone: tablesDone ?? this.tablesDone,
    tablesTotal: tablesTotal ?? this.tablesTotal,
    rowsTotal: rowsTotal ?? this.rowsTotal,
    rowsDone: rowsDone ?? this.rowsDone,
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
  // Resolves this device's order-number tag for the legacy-collision self-heal
  // (§30.8.1). Optional so existing test constructions keep working; when null,
  // the heal is skipped and the row classifies as a normal permanent failure.
  final SecureStorageService? _secureStorage;
  final List<RealtimeChannel> _tableChannels = [];
  RealtimeChannel? _businessesChannel;
  StreamSubscription<int>? _autoPushSub;
  StreamSubscription<AuthState>? _authStateSub;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _autoPushDebounce;
  Timer? _autoPushPeriodic;
  static const _autoPushPeriodicInterval = Duration(seconds: 30);
  bool _pushing = false;
  bool _loggedJwtClaimsThisSession = false;

  /// One-shot per app session: the first queue drain pays a cold-network tax
  /// (DNS resolution + TLS handshake + idle-radio wake + auth/session settling)
  /// that the tight 5s first-attempt chunk timeout routinely loses to — surfacing
  /// a false `timeout` failure on whatever row drains first (almost always
  /// `user_businesses` right after login). We pay that cost once with a cheap
  /// throwaway warm-up request *before* the first real drain, and floor that
  /// first drain's per-chunk timeout at [_firstDrainTimeoutFloor] as a backstop
  /// (in case the warm-up itself was the request that ate the cold tax). Stays
  /// false until a warm-up succeeds; reset on every sign-in/out so a
  /// logout→re-login warms the new session again.
  bool _didWarmUpThisSession = false;

  /// Per-chunk timeout floor for the first drain of a session. Matches the
  /// attempt-1 budget — i.e. the first cold attempt gets the same patience a
  /// warm retry would, enough to clear the cold-start long tail (weak in-store
  /// Wi-Fi, congested cellular, slow token refresh) without making a genuinely
  /// dead link wait longer than it already does on attempt 1.
  static const Duration _firstDrainTimeoutFloor = Duration(seconds: 10);

  /// Ceiling chunk size for a batched push call on Wi-Fi/ethernet — well
  /// under the ~200-row group max so one round trip stays small enough to
  /// finish (or time out) quickly on a weak link.
  static const int _pushChunkCeilingWifi = 25;

  /// Ceiling chunk size on cellular-only connections. A mobile radio pays a
  /// large per-request "tail" energy cost almost regardless of payload size,
  /// so on a weak mobile link it's cheaper to send fewer rows per attempt
  /// (and retry the remainder on the next tick) than to time out on a bigger
  /// one and resend everything.
  static const int _pushChunkCeilingCellular = 10;

  /// Floor for the adaptive chunk size — a push cycle always attempts at
  /// least this many rows per call even after repeated timeouts.
  static const int _minPushChunkSize = 5;

  // ---------------------------------------------------------------------------
  // Pull-side page size ceilings (symmetric with push chunk ceilings above).
  // Selected at the start of pullInitialData from the live connectivity signal.
  // ---------------------------------------------------------------------------

  /// Rows per page on Wi-Fi / Ethernet. Large datasets (orders, order_items)
  /// still fit comfortably within the Supabase HTTP/2 response window.
  static const int _pullPageSizeWifi = 500;

  /// Rows per page on cellular-only connections. Smaller payload reduces the
  /// chance of timing out mid-download on a weak mobile radio.
  static const int _pullPageSizeCellular = 100;

  /// Rows per page when the connection quality is poor or unknown. Aggressive
  /// floor to maximise the chance each page completes within a 15s timeout.
  static const int _pullPageSizePoor = 50;

  /// Absolute floor: a page-level timeout halves the current page size, but
  /// never below this value. Below 10 rows per page the per-request overhead
  /// dominates and throughput collapses.
  static const int _minPullPageSize = 10;

  /// Per-chunk network timeout, escalating with how many times this row has
  /// already been retried (`SyncQueueData.attempts`). A fresh row gets a
  /// short 5s timeout — enough for a normal REST round trip, but short
  /// enough to fail fast (and stop draining the radio) on a dead
  /// connection. Each backoff-spaced retry gets more patience, capped at
  /// 15s. A chunk mixes attempt counts by taking the highest.
  static Duration _pushChunkTimeoutForAttempts(int attempts) {
    switch (attempts) {
      case 0:
        return const Duration(seconds: 5);
      case 1:
        return const Duration(seconds: 10);
      default:
        return const Duration(seconds: 15);
    }
  }

  /// Returns the pull page-size ceiling for the current [connectivity] signal.
  /// Mirrors the push-side `chunkCeiling` selection pattern.
  static int _pullPageCeilingFor(List<ConnectivityResult> connectivity) {
    if (connectivity.isEmpty ||
        connectivity.every((r) => r == ConnectivityResult.none)) {
      return _pullPageSizePoor;
    }
    if (connectivity.contains(ConnectivityResult.wifi) ||
        connectivity.contains(ConnectivityResult.ethernet)) {
      return _pullPageSizeWifi;
    }
    if (connectivity.contains(ConnectivityResult.mobile)) {
      return _pullPageSizeCellular;
    }
    return _pullPageSizePoor;
  }

  /// Consecutive successful chunks required before the adaptive size grows
  /// back toward the connection-type ceiling.
  static const int _chunkGrowthStreak = 3;

  /// Adaptive push-chunk size for this session. Shrinks (halves, floored at
  /// [_minPushChunkSize]) whenever a chunk times out, and grows back toward
  /// the current connection-type ceiling after [_chunkGrowthStreak]
  /// consecutive clean chunks.
  int _pushChunkSize = _pushChunkCeilingWifi;
  int _chunkSuccessStreak = 0;

  /// Connectivity signal driven by `Connectivity().onConnectivityChanged`.
  /// Surfaced to the UI so the drawer's "Syncing…" badge can flip to
  /// "Offline — N queued" when there's no network. Defaults to true so the
  /// app doesn't render an "offline" badge before the first connectivity
  /// event arrives.
  final ValueNotifier<bool> isOnline = ValueNotifier<bool>(true);

  /// Stage of the data-pull state machine. Drives the MainLayout catch-up
  /// banner via `pullStatusProvider`. Mirrors the `isOnline` pattern — public
  /// field, exposed directly, lifted to Riverpod in app_providers.dart.
  final ValueNotifier<PullStatus> pullStatus = ValueNotifier<PullStatus>(
    PullStatus.idle,
  );

  /// Re-entrancy guard for `pullChanges`. setCurrentUser fires it on every
  /// login boundary; the connectivity-recovery listener may also fire it;
  /// users can tap the catch-up banner retry. Without a guard these can race
  /// and double-restore the same row range.
  bool _fullPullRunning = false;

  /// Last businessId the service is configured for. Used by the
  /// connectivity-recovery listener to know which tenant to retry against.
  /// Set inside `pullChanges` / `syncMinimumLogin` whenever they run for a
  /// given business.
  String? _currentBusinessId;

  /// §3.7 (A2) per-pull collector of FK-orphaned restore rows, keyed by child
  /// table. Non-null ONLY during a `pullInitialData` restore loop;
  /// `_insertResilient` records each skipped row here so the post-restore
  /// targeted-parent fetch can pull just the missing parent by id and retry the
  /// child — instead of forcing a whole full re-pull. Reset per pull; left null
  /// on the realtime / single-row restore paths so they never collect.
  Map<String, List<Map<String, dynamic>>>? _fkOrphanedRows;

  /// §3.7 (A2) allowlist of FK fields whose missing parent can be fetched by id
  /// and back-filled inline — the common "CEO created a supplier / category /
  /// manufacturer on another device and a child references it before its slice
  /// arrived" case. Maps the child row's camelCase FK field to the parent table.
  static const Map<String, String> _targetedParentFkFields = {
    'supplierId': 'suppliers',
    'categoryId': 'categories',
    'manufacturerId': 'manufacturers',
  };

  /// §3.7 (A2) hard cap on targeted parent fetches per pull, so a flaky link or
  /// a genuinely-absent parent can't turn the heal into an unbounded round-trip
  /// storm. Beyond this, the affected children stay skipped and fall back to the
  /// conservative full re-pull (A1's FK-orphan branch).
  static const _maxTargetedParentFetch = 50;

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
      // Fire-and-forget retry. If we're still offline / the link is flaky this
      // throws again; swallow it so it can't escape to the top-level zone as an
      // unhandled error. pullStatus stays `failed` and the next connectivity
      // flip retries (offline-first — a failed background pull is not a crash).
      // §3.4: push the outbox first so a device that was offline uploads its
      // work before re-downloading.
      unawaited(
        pushThenPull(_currentBusinessId!).catchError((Object e) {
          debugPrint('[SyncService] connectivity-retry pull failed: $e');
        }),
      );
    }
    _wasOnline = nowOnline;
  }

  SupabaseSyncService(this._db, this._supabase, [this._secureStorage]) {
    isOnline.addListener(_onOnlineChanged);
  }

  /// Wired by AuthService to expose this device's active session id so
  /// the Realtime callback can recognise when its own row was revoked.
  String? Function()? currentSessionIdResolver;

  /// Wired by AuthService. Invoked when the Realtime callback observes
  /// the current session row being revoked by another device.
  VoidCallback? onCurrentSessionRevoked;

  /// Wired by AuthService. Invoked (after a positive tombstone confirmation)
  /// when the active business has been permanently deleted by its owner
  /// (master plan §10.3). The handler wipes local data + full-logout so a
  /// STAFF device doesn't keep looping on permission-denied pulls against a
  /// business that no longer exists in the cloud.
  Future<void> Function()? onActiveBusinessDeleted;

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
    'store_crate_balances': 35,
    // v53 (§3.13) — supplier crate ledger + balance cache push after their
    // parents (suppliers=5, manufacturers=3) so the FK targets land first.
    'supplier_crate_ledger': 36,
    'supplier_crate_balances': 37,
    'system_config': 50,
  };

  int _priorityFor(String actionType) {
    final table = actionType.split(':').first;
    return _tablePushPriority[table] ?? 100;
  }

  /// Cloud upsert conflict targets for caches identified by a NATURAL key
  /// rather than their surrogate `id`. `store_crate_balances` has two id-minting
  /// authorities for the same (business, store, manufacturer): the client
  /// (UuidV7, via addEmptyCrates / updateManufacturerStock plain-enqueues) and
  /// the cloud domain RPC pos_transfer_crates (gen_random_uuid). A PK-keyed
  /// cloud upsert of a client-minted id would INSERT a duplicate and trip the
  /// cloud UNIQUE(business_id, store_id, manufacturer_id); keying the push on
  /// the natural key merges into the existing row instead. (manufacturer/customer
  /// crate caches don't mix authorities — in domain-RPC mode they're never
  /// plain-enqueued — so they don't need an entry.)
  static const Map<String, String> _naturalKeyPushConflictTargets = {
    'store_crate_balances': 'business_id,store_id,manufacturer_id',
    // v53 (§3.13) — supplier crate balance cache is plain-enqueued by
    // SupplierCrateLedgerDao (no domain RPC), so two devices can independently
    // mint different ids for the same (business, supplier, manufacturer) before
    // syncing. Key the cloud upsert on the natural key so they merge instead of
    // tripping the cloud UNIQUE (2067).
    'supplier_crate_balances': 'business_id,supplier_id,manufacturer_id',
  };

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
      'name',
      'email',
      'phone',
      'address',
      'role',
      'role_tier',
      'avatar_color',
      'biometric_enabled',
      'store_id',
      'created_at',
      'last_updated_at',
      // NOTE: `auth_user_id` is intentionally ABSENT — it is cloud-
      // authoritative (set server-side by `complete_onboarding` and
      // `redeem_invite_code`), and the client never originates it: no
      // Drift write sets `Users.authUserId`, so the local value is ALWAYS
      // null. Including it here pushed `auth_user_id: null` on every users
      // upsert (onboarding mirror, profile edits, biometric toggle…),
      // clobbering the uid the onboarding RPC had just stamped. That null
      // then broke the existing-account screen's role lookup (shown as
      // "Member") and `upsertLocalUserFromProfile`'s canonical-id resolve
      // (both key off cloud `users.auth_user_id`). Omitting it leaves the
      // column out of the upsert SET clause so the cloud value survives;
      // the pull restores the correct uid locally. See BUILD_LOG.
      //
      // `status`, `joined_at`, `is_deleted` were removed — they never
      // existed on cloud users (those live on `business_members`), and
      // `is_deleted` was dropped by migration 0035 in the staff-lifecycle
      // hard-delete refactor. `role_tier` MUST be present: cloud DEFAULT is
      // 1 and the CHECK constraint `role_tier IN (2,3,4,5,6)` rejects 1, so
      // scrubbing it out causes 23514 on every fresh-row insert. PIN
      // material (pin, pin_hash, pin_salt, pin_iterations, password_hash)
      // is intentionally absent — local secret material.
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
      'tracks_empty_crates',
      'created_at',
      'last_updated_at',
      // NOTE: timezone is local-only (cloud schema doesn't have it).
      // NOTE: subscription_status / subscription_plan / trial_ends_at /
      // current_period_end are deliberately OMITTED (§32) — they are cloud-
      // authoritative / app-read-only. The fail-closed scrub drops them so the
      // device can never push them (only the admin console writes them). Do NOT
      // add them here.
    },
  };

  /// Append-only ledger tables whose void path re-pushes the FULL local row to
  /// stamp the void columns (payment_transactions §, wallet_transactions §6.x,
  /// supplier_ledger_entries §21.10). `created_at` is immutable on the cloud
  /// (`DEFAULT now()`, enforced by the BEFORE UPDATE append-only trigger) and
  /// it diverges local↔cloud: the cloud stamps it server-side while Drift
  /// stores the local value truncated to whole seconds. So a re-pushed row can
  /// never byte-match the stored `created_at`, and the trigger rejects the
  /// upsert (P0001, "column created_at is immutable") — the row then orphans.
  /// Dropping `created_at` on EVERY push of these tables (insert AND void) keeps
  /// the column out of all payloads: the cloud owns it, voids carry only the
  /// mutable columns, and a mixed insert/void batch stays homogeneous (no
  /// row gets its `created_at` NULL-ed by PostgREST's key-union). See the scrub
  /// in [scrubForTesting].
  static const _ledgerCreatedAtScrubTables = <String>{
    'payment_transactions',
    'wallet_transactions',
    'supplier_ledger_entries',
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
    // Never push an append-only ledger row's `created_at` — the cloud owns it
    // and the value diverges local↔cloud, so a void's full-row re-push would
    // trip the immutable-column trigger. See [_ledgerCreatedAtScrubTables].
    if (_ledgerCreatedAtScrubTables.contains(table)) {
      out.remove('created_at');
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
  }) => _restoreTableData(table, data, fkSkipped: fkSkipped);

  /// Exposes the realtime DELETE handler to unit tests — same rationale as
  /// [restoreTableDataForTesting]: replay a DELETE payload against `_db`
  /// without a live Supabase client.
  @visibleForTesting
  Future<void> deleteLocalRowByIdForTesting(String table, String id) =>
      _deleteLocalRowById(table, id);

  /// Exposes `_reconcileHardDeletes` to unit tests so the full-snapshot
  /// delete-aware reconcile can be exercised without a SupabaseClient (it only
  /// touches `_db`). The reconcile logic stays in `_reconcileHardDeletes` so the
  /// pull path and tests can't drift; pass a full-snapshot map exactly as
  /// [pullInitialData] builds it.
  @visibleForTesting
  Future<void> reconcileHardDeletesForTesting(
    String businessId,
    Map<String, List<dynamic>> snapshot, {
    Set<String> incompleteTables = const <String>{},
  }) => _reconcileHardDeletes(
    businessId,
    snapshot,
    incompleteTables: incompleteTables,
  );

  /// Applies an incoming realtime DELETE locally. The cloud is the source of
  /// truth for the removal, so this deletes the local row WITHOUT enqueueing
  /// (§5 exception #1 — same contract as [_restoreTableData]; re-pushing would
  /// loop). Only the hard-delete tables (the `enqueueDelete` call sites)
  /// ever emit a true DELETE; soft-deletes arrive as UPDATEs and flow through
  /// [_restoreTableData]. Typed deletes keep Drift stream queries (e.g. the
  /// role-permission toggle) reactive. Unknown tables are logged, not applied.
  Future<void> _deleteLocalRowById(String table, String id) async {
    switch (table) {
      case 'role_permissions':
        await (_db.delete(
          _db.rolePermissions,
        )..where((t) => t.id.equals(id))).go();
        break;
      case 'user_permission_overrides':
        await (_db.delete(
          _db.userPermissionOverrides,
        )..where((t) => t.id.equals(id))).go();
        break;
      case 'store_role_permissions':
        await (_db.delete(
          _db.storeRolePermissions,
        )..where((t) => t.id.equals(id))).go();
        break;
      case 'user_stores':
        await (_db.delete(_db.userStores)..where((t) => t.id.equals(id))).go();
        break;
      case 'saved_carts':
        await (_db.delete(_db.savedCarts)..where((t) => t.id.equals(id))).go();
        break;
      case 'notifications':
        await (_db.delete(
          _db.notifications,
        )..where((t) => t.id.equals(id))).go();
        break;
      default:
        debugPrint(
          '[SyncService] Realtime DELETE on "$table" id=$id not applied '
          'locally (no hard-delete handler for this table)',
        );
    }
  }

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

    // Battery: bail before touching the radio at all if there's definitely
    // no usable network — same "all results are none" check the
    // connectivity listener uses to flip `isOnline`. The periodic timer
    // will call us again; no point waking the modem for a call that can
    // only fail or hang.
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.isEmpty ||
        connectivity.every((r) => r == ConnectivityResult.none)) {
      debugPrint('[SyncService] Skipping push: no connectivity.');
      return;
    }
    // Cellular-only links get a smaller chunk ceiling (see
    // _pushChunkCeilingCellular). If the previous run's adaptive size is
    // already above today's ceiling (e.g. switched from Wi-Fi to mobile
    // data), clamp down immediately rather than waiting for a timeout.
    final chunkCeiling =
        (connectivity.contains(ConnectivityResult.mobile) &&
            !connectivity.contains(ConnectivityResult.wifi) &&
            !connectivity.contains(ConnectivityResult.ethernet))
        ? _pushChunkCeilingCellular
        : _pushChunkCeilingWifi;
    if (_pushChunkSize > chunkCeiling) _pushChunkSize = chunkCeiling;

    // Pass businessId explicitly so getPendingItems doesn't have to consult
    // the resolver. Defense-in-depth — keeps the push path safe even if the
    // resolver becomes null between this guard and the query (it shouldn't,
    // but the cost of the explicit arg is zero).
    final rawItems = await _db.syncDao.getPendingItems(
      limit: 200,
      businessId: sessionBusinessId,
    );
    if (rawItems.isEmpty) return;

    // §3.5 uploader check-up: remember exactly which queue rows this drain set
    // out to handle. After the drain, [_auditDrainIntegrity] confirms each one
    // either stayed in `sync_queue` (uploaded → 'completed', or still pending)
    // or moved to `sync_queue_orphans`. A row in NEITHER vanished silently — the
    // "third path" Invariant #12 forbids — and earns an `error_logs` breadcrumb.
    final intendedIds = rawItems.map((i) => i.id).toList();

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
    // conflict target). One Supabase round-trip per group, batched as an array.
    //
    // CAUTION: an upsert here is `INSERT ... ON CONFLICT DO UPDATE`. The DO
    // UPDATE branch only touches columns present in each payload (so a partial
    // payload won't NULL-out untouched columns on an existing row) — BUT Postgres
    // validates NOT-NULL constraints on the INSERT attempt BEFORE conflict
    // resolution, so a PARTIAL payload that omits a NOT-NULL-no-default column
    // (e.g. `name`) fails with 23502 even when the row already exists. Every
    // enqueued upsert must therefore carry a FULL row, not just the changed
    // columns — see the `_enqueueFull*` helpers / `toCompanion(true)` pattern in
    // daos.dart. (The earlier "partial-row semantics are safe" note was wrong and
    // produced a class of silent sync failures.)
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
        (a, b) => _priorityFor(
          '${a.table}:${a.action}',
        ).compareTo(_priorityFor('${b.table}:${b.action}')),
      );

    debugPrint(
      '[SyncService] Pushing ${pendingItems.length} items in '
      '${orderedGroups.length} batched calls...',
    );

    // Cold-start warm-up (see [_didWarmUpThisSession]). The first drain of a
    // session would otherwise spend its tight 5s first-attempt budget on a cold
    // DNS+TLS+radio round trip and log a false `timeout` on the first row. Pay
    // that cost once with a cheap throwaway request, then drain at normal
    // timeouts so no real row absorbs the cold tax. `isFirstDrain` floors this
    // drain's per-chunk timeout regardless of the ping's outcome — if the link
    // was so cold the warm-up itself timed out, the real rows still need grace.
    final isFirstDrain = !_didWarmUpThisSession;
    if (isFirstDrain) {
      await _warmUpConnection(sessionBusinessId);
    }

    // Cascade guard: groups are ordered parent→child by FK priority. If a group
    // hits a degraded link (timeout / transient network), the parent rows likely
    // didn't land, so attempting the later (child) groups — and the domain
    // envelopes, which FK-reference rows we just tried to push — would just
    // produce a storm of guaranteed 23503 FK violations against parents that
    // aren't in the cloud (the "FK violation storm" on a flaky link). Stop the
    // cycle and let the next trigger retry the whole queue in priority order.
    // Only link-degraded failures abort; per-row FK-deferred / permanent errors
    // keep their own backoff and don't.
    var isLinkDegraded = false;
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
      final validAttempts = <int>[];
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
          validAttempts.add(item.attempts);
        } catch (e) {
          await _db.syncDao.markFailed(item.id, 'decode_error: $e');
        }
      }
      if (mismatchedIds.isNotEmpty) {
        for (final id in mismatchedIds) {
          await _db.syncDao.markFailed(
            id,
            'missing_business_id',
            permanent: true,
          );
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

      // Battery + weak-link reliability: send this group in chunks of at
      // most _pushChunkSize rows instead of one call that could carry the
      // whole (up to 200-row) group. A chunk that times out shrinks the
      // size for the rest of this run; a clean streak grows it back toward
      // chunkCeiling. See the _pushChunkSize field doc.
      for (
        var start = 0;
        start < validPayloads.length;
        start += _pushChunkSize
      ) {
        final end = (start + _pushChunkSize < validPayloads.length)
            ? start + _pushChunkSize
            : validPayloads.length;
        final chunkPayloads = validPayloads.sublist(start, end);
        final chunkIds = validIds.sublist(start, end);
        final chunkAttempts = validAttempts.sublist(start, end);
        var chunkTimeout = _pushChunkTimeoutForAttempts(
          chunkAttempts.fold(0, (max, a) => a > max ? a : max),
        );
        // First-drain backstop: even a fresh (attempt-0) chunk gets the roomier
        // floor on the session's first drain, so the cold-start long tail
        // doesn't log a false timeout if the warm-up didn't fully heat the link.
        if (isFirstDrain && chunkTimeout < _firstDrainTimeoutFloor) {
          chunkTimeout = _firstDrainTimeoutFloor;
        }

        try {
          if (group.action == 'insert' ||
              group.action == 'update' ||
              group.action == 'upsert') {
            // An explicit per-row conflict target (action_type's 3rd segment)
            // wins; otherwise fall back to a per-table natural-key target for
            // caches whose id can diverge from the cloud's (see
            // _naturalKeyPushConflictTargets). Null → PostgREST defaults to PK.
            final conflictTarget =
                group.conflictTarget ??
                _naturalKeyPushConflictTargets[group.table];
            final upsert = conflictTarget != null
                ? _supabase
                      .from(group.table)
                      .upsert(chunkPayloads, onConflict: conflictTarget)
                : _supabase.from(group.table).upsert(chunkPayloads);
            await upsert.timeout(chunkTimeout);
          } else if (group.action == 'delete') {
            // Hard delete only used for tombstones the cloud needs to forget.
            // Soft delete (is_deleted=true) goes through the upsert path above.
            final deleteIds = chunkPayloads
                .map((p) => p['id'] as String?)
                .whereType<String>()
                .toList();
            if (deleteIds.isNotEmpty) {
              await _supabase
                  .from(group.table)
                  .delete()
                  .inFilter('id', deleteIds)
                  .timeout(chunkTimeout);
            }
          }
          await _db.syncDao.markDoneBatch(chunkIds);
          // A clean chunk below the connection's ceiling counts toward
          // growing the adaptive size back up; already-at-ceiling just
          // resets the streak.
          if (_pushChunkSize < chunkCeiling) {
            _chunkSuccessStreak++;
            if (_chunkSuccessStreak >= _chunkGrowthStreak) {
              _chunkSuccessStreak = 0;
              final grown = _pushChunkSize * 2;
              _pushChunkSize = grown < chunkCeiling ? grown : chunkCeiling;
            }
          } else {
            _chunkSuccessStreak = 0;
          }
        } on TimeoutException catch (e) {
          // This size is too big for the current link — halve it (floored
          // at _minPushChunkSize) so the retry, and the rest of this run,
          // waste less radio-on time stalling at the same dead-end size.
          _chunkSuccessStreak = 0;
          final shrunk = _pushChunkSize ~/ 2;
          _pushChunkSize = shrunk < _minPushChunkSize
              ? _minPushChunkSize
              : shrunk;
          debugPrint(
            '[SyncService] Chunk push timed out for '
            '${group.table}:${group.action} (${chunkIds.length} items) — '
            'shrinking chunk size to $_pushChunkSize: $e',
          );
          for (final id in chunkIds) {
            await _db.syncDao.markFailed(id, 'timeout: $e');
          }
          // Degraded link — don't cascade into child groups (see guard above).
          isLinkDegraded = true;
        } catch (e) {
          final code = e is PostgrestException ? (e.code ?? '?') : '?';
          // Legacy order-number collision self-heal (§30.8.1). The cloud already
          // holds one of these orders' numbers under a different id (a pre-device-
          // tag offline dup). Renumber the local copy with THIS device's tag and
          // re-enqueue so it uploads and frees the number for the cloud's order to
          // restore. Per-row so a non-colliding order in the same chunk isn't
          // touched. Handled here → skip the generic classification below.
          if (group.table == 'orders' &&
              group.action == 'upsert' &&
              _isOrderNumberCollision(e)) {
            await _healOrderNumberCollisions(chunkPayloads, chunkIds);
            continue;
          }
          // §6.8 failure classification — parity with the domain-RPC path
          // (_pushDomainItems). Without it a per-table upsert that hits a cloud
          // constraint retried forever (uncapped transient backoff):
          //   - 23503 (foreign_key_violation) → FK-deferred: the parent row may
          //     still arrive on the next pull; long backoff, capped at 3 then
          //     orphaned (e.g. order_items whose order hasn't landed yet).
          //   - other 23xxx / P0001 / privilege / bad-parameter → permanent →
          //     orphan auto-move. A duplicate order_number can never insert under
          //     its own id, so retrying is futile — surface it for operator review.
          //   - everything else (network, 5xx) → transient → standard backoff.
          final isFkViolation = code == '23503';
          final isPermanent =
              !isFkViolation &&
              (code == 'P0001' ||
                  code.startsWith('23') ||
                  code == 'insufficient_privilege' ||
                  code == 'invalid_parameter_value');
          debugPrint(
            '[SyncService] Chunk push failed for ${group.table}:${group.action} '
            '(${chunkIds.length} items, code=$code, permanent=$isPermanent, '
            'fk_deferred=$isFkViolation): $e',
          );
          // On chunk failure, mark every item failed individually so the
          // existing exponential-backoff per-row state machine still applies.
          for (final id in chunkIds) {
            await _db.syncDao.markFailed(
              id,
              e.toString(),
              permanent: isPermanent,
              fkDeferred: isFkViolation,
            );
          }
          // A transient network / 5xx failure (not a per-row FK-deferred or
          // permanent constraint) means the link is degraded — stop cascading
          // into child groups, same as a timeout.
          if (!isFkViolation && !isPermanent) {
            isLinkDegraded = true;
          }
        }
      }

      // Parent group couldn't be delivered over this link — skip the remaining
      // (child) groups this cycle so they don't FK-fail against parents that
      // never landed. The queue is intact; the next trigger retries in order.
      if (isLinkDegraded) {
        debugPrint(
          '[SyncService] Link degraded while pushing ${group.table} — '
          'deferring remaining groups to the next push cycle.',
        );
        break;
      }
    }

    // Now that parent-table rows are in the cloud, drain domain envelopes.
    // Their server-side RPCs FK-reference rows we just pushed (e.g.
    // pos_create_product → stock_adjustments.performed_by → users.id). Skip on a
    // degraded link — the parents may not have landed and the RPC would fail.
    if (domainItems.isNotEmpty && !isLinkDegraded) {
      await _pushDomainItems(domainItems, sessionBusinessId, currentAuthUid);
    }

    // A drain that completed without a degraded link means the connection is
    // now warm regardless of whether the warm-up ping itself succeeded — clear
    // the first-drain grace so subsequent drains fail fast as designed.
    if (!isLinkDegraded) _didWarmUpThisSession = true;

    // §3.5 uploader check-up: every row this drain handled must now be either
    // still in `sync_queue` (uploaded/completed, or pending for retry) or moved
    // to `sync_queue_orphans`. Anything missing from both vanished silently.
    await _auditDrainIntegrity(intendedIds, sessionBusinessId);

    // If the raw select hit the page limit, more is waiting — drain in the
    // next tick rather than recursing (avoids stack growth on huge backlogs).
    // Not while link-degraded: continuing to hammer a bad link just stalls;
    // the next connectivity / periodic trigger resumes the drain.
    if (rawItems.length == 200 && !isLinkDegraded) {
      Future.microtask(pushPending);
    }
  }

  /// §3.5 uploader check-up — the two-ways-only invariant detector. A row may
  /// leave `sync_queue` ONLY by (a) confirmed upload (`markDone`, the row stays
  /// present as `completed`) or (b) moving to `sync_queue_orphans` (visible).
  /// After a drain this re-checks every id the drain set out to push: each must
  /// still be present in `sync_queue` (under any status) OR exist as an orphan
  /// keyed on its original id. An id in NEITHER vanished silently — the third,
  /// silent path the brief warns about (vector F) — so we record an `error_logs`
  /// breadcrumb instead of losing the row without trace.
  ///
  /// Best-effort and fully defensive: the integrity check must never itself
  /// break or block a drain.
  Future<void> _auditDrainIntegrity(
    List<String> intendedIds,
    String businessId,
  ) async {
    if (intendedIds.isEmpty) return;
    try {
      final present = <String>{
        for (final r
            in await (_db.select(
              _db.syncQueue,
            )..where((t) => t.id.isIn(intendedIds))).get())
          r.id,
      };
      final orphaned = <String>{
        for (final r
            in await (_db.select(
              _db.syncQueueOrphans,
            )..where((t) => t.originalId.isIn(intendedIds))).get())
          r.originalId,
      };
      final vanished = intendedIds
          .where((id) => !present.contains(id) && !orphaned.contains(id))
          .toList();
      if (vanished.isEmpty) return;
      debugPrint(
        '[SyncService] OUTBOX INTEGRITY: ${vanished.length} queue row(s) left '
        'the outbox without uploading or orphaning — '
        'ids=${vanished.take(5).join(",")}',
      );
      await _db.errorLogDao.logError(
        errorType: 'sync.outbox_shrinkage',
        message:
            'Invariant #12: ${vanished.length} sync_queue row(s) vanished '
            'during a drain without markDone or an orphan move. '
            'ids=${vanished.join(",")}',
        context: 'pushPending._auditDrainIntegrity',
        businessId: businessId,
      );
    } catch (e) {
      // The integrity check must never itself break a drain. Swallow.
      debugPrint('[SyncService] drain integrity check failed: $e');
    }
  }

  /// Cheap throwaway request that pays the cold-start network cost (DNS + TLS
  /// handshake + idle-radio wake) once, so the first *real* queue chunk rides a
  /// warm connection instead of losing its tight timeout to the handshake. A
  /// scoped `select … limit 1` on the session's own business row — RLS-safe and
  /// tiny. Its own timeout uses the first-drain floor; on success we mark the
  /// session warmed so we don't ping again. Any failure (offline mid-drain, RLS
  /// edge, slow link) is swallowed: the floored real-drain timeout is the
  /// backstop, and the next drain simply warms again.
  Future<void> _warmUpConnection(String sessionBusinessId) async {
    try {
      await _supabase
          .from('businesses')
          .select('id')
          .eq('id', sessionBusinessId)
          .limit(1)
          .timeout(_firstDrainTimeoutFloor);
      _didWarmUpThisSession = true;
      debugPrint('[SyncService] Connection warm-up ok (cold start paid).');
    } catch (e) {
      debugPrint('[SyncService] Connection warm-up skipped/failed: $e');
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
        await _db.syncDao.markFailed(
          item.id,
          'decode_error: $e',
          permanent: true,
        );
        continue;
      }

      // Tenant guard. The RPC also checks server-side, but failing locally
      // saves a round-trip and avoids a misleading 'tenant_mismatch' RPC
      // error in the Sync Issues UI.
      final payloadBiz = payload['p_business_id'];
      if (item.businessId != sessionBusinessId ||
          payloadBiz is! String ||
          payloadBiz != sessionBusinessId) {
        await _db.syncDao.markFailed(
          item.id,
          'missing_business_id',
          permanent: true,
        );
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
        final replayed = response is Map && response['replayed'] == true;
        debugPrint('[SyncService] domain $rpcName ok (replayed=$replayed)');
      } on PostgrestException catch (e) {
        // §6.8 failure classification:
        //   - 23503 (foreign_key_violation) → FK-deferred: parent likely
        //     arrives on the next pull; longer backoff, capped retries.
        //   - P0001 / other 23xxx / insufficient_privilege /
        //     invalid_parameter_value → permanent → orphan auto-move.
        //   - everything else → transient → standard exp backoff.
        final code = e.code ?? '';
        final isFkViolation = code == '23503';
        final isPermanent =
            !isFkViolation &&
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

  /// True for a Postgres duplicate-key error on the orders order-number unique
  /// constraint — the legacy offline collision the self-heal targets (§30.8.1).
  static bool _isOrderNumberCollision(Object e) {
    if (e is! PostgrestException || e.code != '23505') return false;
    final m = e.message.toLowerCase();
    return m.contains('orders_business_id_order_number_key') ||
        m.contains('order_number');
  }

  /// This device's stable order-number tag (§30.8.1), or null when no secure
  /// storage is wired (test constructions) — in which case the heal no-ops and
  /// the collision falls through to a normal permanent failure.
  Future<String?> _resolveDeviceTag() async {
    final storage = _secureStorage;
    if (storage == null) return null;
    return deviceOrderTag(await storage.getOrCreateDeviceId());
  }

  /// Pull-side counterpart to the push heal (§30.8.1). When a cloud order can't
  /// restore because a LOCAL order holds the same `(business_id, order_number)`
  /// under a different id (a legacy pre-tag offline dup), renumber the local
  /// blocker — append this device's tag and re-enqueue — so the number frees up
  /// and the cloud's authoritative order (and its FK-children) can land in this
  /// same pull instead of orphaning forever. Renumber, never delete: the local
  /// order is a real, different sale. Returns true if a blocker was renumbered.
  Future<bool> _healLocalOrderNumberBlocker(OrderData cloudOrder) async {
    final deviceTag = await _resolveDeviceTag();
    if (deviceTag == null) return false;
    final blocker =
        await (_db.select(_db.orders)..where(
              (t) =>
                  t.businessId.equals(cloudOrder.businessId) &
                  t.orderNumber.equals(cloudOrder.orderNumber) &
                  t.id.equals(cloudOrder.id).not(),
            ))
            .getSingleOrNull();
    if (blocker == null) return false;
    final newNumber = await _db.ordersDao.renumberForCollisionHeal(
      blocker.id,
      deviceTag,
    );
    if (newNumber == null) return false;
    debugPrint(
      '[SyncService] freed order number "${cloudOrder.orderNumber}" — '
      'renumbered local blocker ${blocker.id} → $newNumber so cloud order '
      '${cloudOrder.id} can restore.',
    );
    return true;
  }

  /// Heals legacy order-number collisions (§30.8.1) for a failed `orders` upsert
  /// batch. Re-pushes each order individually; an order whose number is already
  /// taken in the cloud (under a different id) is renumbered with this device's
  /// tag and re-enqueued, so it uploads cleanly and frees the old number for the
  /// cloud's colliding order to restore. Non-colliding rows in the batch upload
  /// normally; other errors fall back to the standard classification.
  Future<void> _healOrderNumberCollisions(
    List<Map<String, dynamic>> payloads,
    List<String> queueIds,
  ) async {
    final deviceTag = await _resolveDeviceTag();
    for (var i = 0; i < payloads.length; i++) {
      final payload = payloads[i];
      final queueId = queueIds[i];
      try {
        await _supabase.from('orders').upsert([payload]);
        await _db.syncDao.markDoneBatch([queueId]);
      } catch (e) {
        if (deviceTag != null &&
            _isOrderNumberCollision(e) &&
            payload['id'] is String) {
          final orderId = payload['id'] as String;
          // Retire the failed item BEFORE the heal re-enqueues: coalescing only
          // targets PENDING rows, so marking this 'done' first prevents the
          // fresh upsert from merging back into the row we're abandoning.
          await _db.syncDao.markDoneBatch([queueId]);
          final newNumber = await _db.ordersDao.renumberForCollisionHeal(
            orderId,
            deviceTag,
          );
          debugPrint(
            newNumber != null
                ? '[SyncService] healed legacy order-number collision on order '
                      '$orderId → $newNumber (re-enqueued).'
                : '[SyncService] order $orderId collision unresolved (already '
                      'tagged or gone); left as-is.',
          );
          continue;
        }
        // Not an order-number collision → classify like the batch path.
        final code = e is PostgrestException ? (e.code ?? '?') : '?';
        final isFk = code == '23503';
        final isPerm =
            !isFk &&
            (code == 'P0001' ||
                code.startsWith('23') ||
                code == 'insufficient_privilege' ||
                code == 'invalid_parameter_value');
        await _db.syncDao.markFailed(
          queueId,
          e.toString(),
          permanent: isPerm,
          fkDeferred: isFk,
        );
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

  Future<void> _applyDomainResponse(String rpcName, dynamic response) async {
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
          await (_db.update(_db.inventory)..where(
                (t) =>
                    t.productId.equals(productId) & t.storeId.equals(storeId),
              ))
              .write(
                InventoryCompanion(
                  quantity: Value(quantity),
                  lastUpdatedAt: Value(lua ?? DateTime.now()),
                ),
              );
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
        await _restoreTableData('orders', [
          Map<String, dynamic>.from(orderRow),
        ]);
      }
      // pos_create_product_v2: server returns the canonical product row.
      // Route through _restoreTableData so the cloud's `last_updated_at`
      // (and any server-canonicalised fields) overwrite the local
      // pre-insert. Same pattern as `order` above.
      final productRow = map['product'];
      if (productRow is Map) {
        await _restoreTableData('products', [
          Map<String, dynamic>.from(productRow),
        ]);
      }
      // pos_record_sale_v2: server returns the canonical order_items array.
      // The thin-local DAO doesn't pre-insert items; this is the sole
      // local writer for them.
      final orderItems = map['order_items'];
      if (orderItems is List && orderItems.isNotEmpty) {
        await _restoreTableData('order_items', List<dynamic>.from(orderItems));
      }

      final stockTxns = map['stock_transactions'];
      if (stockTxns is List && stockTxns.isNotEmpty) {
        await _restoreTableData(
          'stock_transactions',
          List<dynamic>.from(stockTxns),
        );
      }
      // pos_inventory_delta_v2 also returns server-minted stock_adjustments
      // for movement_type='adjustment' rows; route through the standard
      // restore path so local matches cloud's gen_random_uuid() ids.
      final stockAdjustments = map['stock_adjustments'];
      if (stockAdjustments is List && stockAdjustments.isNotEmpty) {
        await _restoreTableData(
          'stock_adjustments',
          List<dynamic>.from(stockAdjustments),
        );
      }
      final voidedPayments = map['voided_payments'];
      if (voidedPayments is List && voidedPayments.isNotEmpty) {
        await _restoreTableData(
          'payment_transactions',
          List<dynamic>.from(voidedPayments),
        );
      }
      final refundPayments = map['refund_payments'];
      if (refundPayments is List && refundPayments.isNotEmpty) {
        await _restoreTableData(
          'payment_transactions',
          List<dynamic>.from(refundPayments),
        );
      }
      final walletCompens = map['wallet_compensations'];
      if (walletCompens is List && walletCompens.isNotEmpty) {
        await _restoreTableData(
          'wallet_transactions',
          List<dynamic>.from(walletCompens),
        );
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
            await (_db.update(_db.customers)..where((t) => t.id.equals(cid)))
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
        await _restoreTableData('wallet_transactions', [
          Map<String, dynamic>.from(walletTxn),
        ]);
      }
      final paymentTxn = map['payment_transaction'];
      if (paymentTxn is Map) {
        await _restoreTableData('payment_transactions', [
          Map<String, dynamic>.from(paymentTxn),
        ]);
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
            await (_db.update(
              _db.walletTransactions,
            )..where((t) => t.id.equals(id))).write(
              WalletTransactionsCompanion(lastUpdatedAt: Value(parsed)),
            );
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
            await (_db.update(
              _db.walletTransactions,
            )..where((t) => t.id.equals(id))).write(
              WalletTransactionsCompanion(lastUpdatedAt: Value(parsed)),
            );
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
            await (_db.update(
              _db.pendingCrateReturns,
            )..where((t) => t.id.equals(id))).write(
              PendingCrateReturnsCompanion(lastUpdatedAt: Value(parsed)),
            );
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
            await (_db.update(_db.crateLedger)..where((t) => t.id.equals(id)))
                .write(CrateLedgerCompanion(lastUpdatedAt: Value(parsed)));
          }
        }
      }
      final balanceRow = map['balance_row'];
      if (balanceRow is Map) {
        final balance = balanceRow['balance'];
        final lua = balanceRow['last_updated_at'] as String?;
        final parsed = lua != null ? DateTime.tryParse(lua) : null;
        // v29: crate balances are keyed by manufacturer (§13.4). A customer
        // balance row carries both customer_id and manufacturer_id; a
        // manufacturer-stock row carries only manufacturer_id.
        final manufacturerId = balanceRow['manufacturer_id'] as String?;
        final businessIdStr = balanceRow['business_id'] as String?;
        if (balance is int &&
            parsed != null &&
            manufacturerId != null &&
            businessIdStr != null) {
          final customerId = balanceRow['customer_id'] as String?;
          if (customerId != null) {
            await (_db.update(_db.customerCrateBalances)..where(
                  (t) =>
                      t.businessId.equals(businessIdStr) &
                      t.customerId.equals(customerId) &
                      t.manufacturerId.equals(manufacturerId),
                ))
                .write(
                  CustomerCrateBalancesCompanion(
                    balance: Value(balance),
                    lastUpdatedAt: Value(parsed),
                  ),
                );
          } else {
            await (_db.update(_db.manufacturerCrateBalances)..where(
                  (t) =>
                      t.businessId.equals(businessIdStr) &
                      t.manufacturerId.equals(manufacturerId),
                ))
                .write(
                  ManufacturerCrateBalancesCompanion(
                    balance: Value(balance),
                    lastUpdatedAt: Value(parsed),
                  ),
                );
          }
        }
      }

      // pos_transfer_crates (§16.9 Phase 3): server returns two crate_ledger
      // rows (out_ledger_row / in_ledger_row) and two store_crate_balances
      // rows (src_store_balance / dst_store_balance). Apply server-authoritative
      // values locally so the next incremental pull cursor skips them.
      for (final ledgerKey in const ['out_ledger_row', 'in_ledger_row']) {
        final ledgerRow = map[ledgerKey];
        if (ledgerRow is Map) {
          final id = ledgerRow['id'] as String?;
          final lua = ledgerRow['last_updated_at'] as String?;
          if (id != null && lua != null) {
            final parsed = DateTime.tryParse(lua);
            if (parsed != null) {
              await (_db.update(_db.crateLedger)..where((t) => t.id.equals(id)))
                  .write(CrateLedgerCompanion(lastUpdatedAt: Value(parsed)));
            }
          }
        }
      }
      for (final balKey in const ['src_store_balance', 'dst_store_balance']) {
        final storeBalRow = map[balKey];
        if (storeBalRow is Map) {
          final bizId = storeBalRow['business_id'] as String?;
          final storeId = storeBalRow['store_id'] as String?;
          final mfrId = storeBalRow['manufacturer_id'] as String?;
          final bal = storeBalRow['balance'];
          final lua = storeBalRow['last_updated_at'] as String?;
          if (bizId != null &&
              storeId != null &&
              mfrId != null &&
              bal is int &&
              lua != null) {
            final parsed = DateTime.tryParse(lua);
            if (parsed != null) {
              await (_db.update(_db.storeCrateBalances)..where(
                    (t) =>
                        t.businessId.equals(bizId) &
                        t.storeId.equals(storeId) &
                        t.manufacturerId.equals(mfrId),
                  ))
                  .write(
                    StoreCrateBalancesCompanion(
                      balance: Value(bal),
                      lastUpdatedAt: Value(parsed),
                    ),
                  );
            }
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
        throw SaleSyncException(orderId: orderId, errorMessage: orphan.reason);
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

  /// §3.4 upload-before-download. The reconnect, pull-to-refresh, and login
  /// triggers route through this instead of calling [pullChanges] directly: it
  /// drains the outbox first (best-effort, through the `_pushing`-guarded
  /// [_runPushOnce] so it can't double-run against the auto-push loop) and only
  /// then pulls. A freshly-recovered device uploads its offline work before
  /// downloading, avoiding a wasted pull/restore right where the loss window
  /// used to be widest (vector D).
  ///
  /// [pullChanges] stays callable standalone and safe on its own — the
  /// Invariant #12 guards (3.2/3.3) make this ordering an efficiency choice, not
  /// a safety requirement. The push is best-effort: [_runPushOnce] already
  /// swallows push failures, so a rejected row or a mid-flight disconnect never
  /// blocks the pull.
  Future<void> pushThenPull(String businessId) async {
    await _runPushOnce();
    await pullChanges(businessId);
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
    debugPrint('[SyncService] Minimum-login pull for business $businessId...');
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
    final minConnectivity = await Connectivity().checkConnectivity();
    final minPageSize = _pullPageCeilingFor(minConnectivity);
    const tables = ['profiles', 'businesses', 'stores', 'users'];
    try {
      final fetched = await Future.wait(
        tables.map(
          (t) => _fetchOneTable(t, businessId, null, pageSize: minPageSize),
        ),
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
      // A staff device that relaunches AFTER the owner deleted the business
      // hits this path (the pull fails with permission-denied because the whole
      // tenant — profiles/users/business — is gone). Confirm via the tombstone
      // and wipe + sign out instead of surfacing "check your connection".
      if (await _wipeIfBusinessDeleted(businessId)) {
        pullStatus.value = PullStatus.idle;
        return;
      }
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
  /// setCurrentUser, the connectivity-recovery listener, and a manual
  /// catch-up banner retry all converge on this single entry point and must
  /// not race each other.
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

    // §3.6 per-table backfill cursors: tables that deferred on a PRIOR pull and
    // still owe a full (since=null) catch-up. They are pulled with since=null
    // this run while every other table stays incremental on the global cursor.
    final backfillKey = backfillTablesKey(businessId);
    final backfillStr = prefs.getString(backfillKey);
    final backfillTables = (backfillStr == null || backfillStr.isEmpty)
        ? const <String>{}
        : backfillStr.split(',').toSet();

    try {
      final skipped = await pullInitialData(
        businessId,
        since: since,
        fullPullTables: backfillTables,
      );

      final deferredKey = pendingDeferredTablesKey(businessId);
      if (skipped.isEmpty) {
        // Clean pull — advance the cursor and clear any prior deferred/backfill
        // record so the SyncIssues UI stops surfacing stale "catching up" state.
        await prefs.setString(key, DateTime.now().toUtc().toIso8601String());
        await prefs.remove(deferredKey);
        await prefs.remove(backfillKey);
        // First-load overlay marker: a clean full pull means this business has
        // fully landed on this device. Set the per-business "first full pull
        // completed" marker so the first-load overlay never re-shows for an
        // established-but-empty store on later launches. Lives in
        // SharedPreferences (not Drift) so it survives clearAllData(); it is
        // explicitly cleared there on a wipe/re-onboard. See §4.2.
        await FirstLoadMarkerService.markPullCompleted(businessId);
      } else {
        // §3.6 per-table backfill cursors (vector A1). A deferred pull no longer
        // clears the WHOLE cursor — that forced the next pull to re-download and
        // re-restore EVERY table (orders, order_items, ledgers — thousands of
        // rows) merely because one small table deferred, which is the slow-sync
        // root cause. Instead we split by skip kind:
        //
        //   • FK-orphan skips (a child whose parent slice was absent — table NOT
        //     in `_deferrableTables`) STILL need the conservative full re-pull,
        //     because the missing parent may be an UNCHANGED row sitting below
        //     the cursor that an incremental pull would never re-fetch. Clear the
        //     cursor for those so every current cloud row (parents included) is
        //     re-pulled and the child finally inserts. (A2 heals the common
        //     inline-created-parent case inline so this path is rarely hit.)
        //
        //   • Leaf fetch-failures (tables in `_deferrableTables`: nothing
        //     FK-references them, and their own parents already arrived) just
        //     need THEMSELVES re-fetched. Advance the global cursor so the big
        //     tables stay incremental, and record only the deferred leaf tables
        //     in the backfill set — the next pull runs since=null for exactly
        //     those and stays incremental for the rest.
        final fkOrphanSkips = skipped
            .where((t) => !_deferrableTables.contains(t))
            .toSet();
        if (fkOrphanSkips.isNotEmpty) {
          debugPrint(
            '[SyncService] FK-orphan skip(s) ${fkOrphanSkips.join(", ")} — '
            'clearing cursor to force a full re-pull (parents may be unchanged '
            'and below the cursor).',
          );
          await prefs.remove(key);
          await prefs.remove(backfillKey);
        } else {
          // Only leaf fetch-failures deferred — advance the cursor and backfill
          // just those tables next time. The backfill set is exactly this pull's
          // deferred set: a table that successfully backfilled this run is no
          // longer in `skipped`, so it drops out automatically.
          await prefs.setString(
            key,
            DateTime.now().toUtc().toIso8601String(),
          );
          await prefs.setString(backfillKey, skipped.join(','));
          debugPrint(
            '[SyncService] Per-table backfill: advanced global cursor; '
            '${skipped.length} leaf table(s) flagged for full re-pull next '
            'time: ${skipped.join(", ")}',
          );
        }
        await prefs.setString(deferredKey, skipped.join(','));
      }
      // Clean run — reset consecutive-failure count and signal completion.
      // Deferred-only completion still counts as "caught up" for banner
      // purposes; the deferred set lives in its own pref and the
      // SyncIssues "Catching up" card surfaces it independently.
      await prefs.setInt(_consecutiveFailuresKey(businessId), 0);
      pullStatus.value = pullStatus.value.copyWith(stage: PullStage.completed);
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
    // v33 (§10.2.1) — per-staff permission overrides. References businesses +
    // users (pulled above) and the global permissions catalogue, so FK-safe
    // here. Without this entry the pull/restore/realtime loops never ingest it
    // and an override set on one device never reaches the others.
    'user_permission_overrides',
    // v41 (§10.2.1 Store scope) — per-store role permission overrides.
    // References businesses + stores + roles (all pulled above) and the global
    // permissions catalogue, so FK-safe here. Without this entry the
    // pull/restore/realtime loops never ingest it and a store override set on
    // one device never reaches the others.
    'store_role_permissions',
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
    // §13.4 — per-order, per-brand crate deposit lines. References orders +
    // manufacturers (both pulled above), so FK-safe here.
    'order_crate_lines',
    'shipments',
    'purchase_items',
    'expense_categories',
    'expenses',
    // expense_budgets references businesses + stores (both pulled above), so
    // it's FK-safe here (§20.1/§20.3 monthly budget). Without this entry the
    // pull/restore/realtime loops never ingest it and a budget set on one
    // device never reaches the others.
    'expense_budgets',
    'customer_crate_balances',
    'delivery_receipts',
    'drivers',
    'stock_transfers',
    'stock_adjustments',
    // v34 (§16.6.1) — references products/stores/users, all pulled above.
    'stock_adjustment_requests',
    // v45 (§12.3.1) — cashier Quick Sale approval queue. References stores +
    // users (both pulled above), so FK-safe here. Without this entry the
    // pull/restore/realtime loops never ingest it and an approve/reject flip on
    // the approver's device never reaches the cashier's till.
    'quick_sale_requests',
    'activity_logs',
    // v46 (§33) — crash/error log. References businesses + users (both pulled
    // above), so FK-safe here. A leaf table (nothing FK-references it), so it
    // is also in _deferrableTables below.
    'error_logs',
    'notifications',
    'stock_transactions',
    'customer_wallets',
    'wallet_transactions',
    // v42 (§21.10) — append-only supplier ledger. References suppliers + users
    // (both pulled above), so FK-safe here. Without this entry the
    // pull/restore/realtime loops never ingest it and a supplier invoice/payment
    // recorded on one device never reaches the others.
    'supplier_ledger_entries',
    // v53 (§3.13) — append-only supplier empty-crate ledger. References
    // suppliers + manufacturers + stores + users (all pulled above), so FK-safe
    // here. Without this entry a supplier crate receipt/return on one device
    // never reaches the others.
    'supplier_crate_ledger',
    'saved_carts',
    'pending_crate_returns',
    'manufacturer_crate_balances',
    'store_crate_balances',
    // v53 (§3.13) — per-(supplier, manufacturer) crate balance cache. References
    // suppliers + manufacturers (both pulled above), so FK-safe here.
    'supplier_crate_balances',
    'crate_ledger',
    'system_config',
    'price_lists',
    'payment_transactions',
    // stock_counts references businesses + stores + users (all pulled above),
    // so it's FK-safe here (§17 Daily Stock Count). Added in this pass — it was
    // missing from the ingest loops since Session 58, so saved counts never
    // reached other devices.
    'stock_counts',
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
    // v46 (§33) — crash/error log. Leaf table (no inbound FKs), so deferring a
    // missing slice can't trip restore-time FK violations elsewhere.
    'error_logs',
    'notifications',
    'payment_transactions',
    'crate_ledger',
    // v53 (§3.13) — append-only supplier crate ledger. Leaf table (nothing
    // FK-references it; the balance cache is app-derived, not an FK), so
    // deferring a missing slice can't trip restore-time FK violations.
    'supplier_crate_ledger',
  };

  /// SharedPreferences key (per-business) carrying the last set of tables
  /// that were leaf-deferred on an otherwise-successful pull. SyncIssues
  /// reads this to surface "still catching up" UI. Cleared when a clean
  /// full pull completes.
  static String pendingDeferredTablesKey(String businessId) =>
      'pending_deferred_tables::$businessId';

  /// SharedPreferences key (per-business) for the §3.6 per-table backfill set:
  /// the comma-separated tables that deferred on a prior pull and still owe a
  /// full (`since=null`) catch-up. The global cursor keeps advancing; only these
  /// tables are re-pulled in full on the next pull, so a small table deferring
  /// can no longer force a re-download of the whole dataset (vector A1).
  static String backfillTablesKey(String businessId) =>
      'backfill_tables::$businessId';

  /// Returns `true` when `pullInitialData` should call the monolithic
  /// `pos_pull_snapshot` RPC; `false` when it should use the paginated
  /// `_pullViaPostgRest` path.
  ///
  /// **Phase 2 rule (2026-06-22):** Full/first pulls ([since] == null) NEVER
  /// use the RPC — the unbounded aggregate query can time out on large datasets.
  /// The RPC is used ONLY for incremental pulls ([since] != null) on a fast
  /// link ([isSlow] == false), where the payload is bounded by what changed
  /// since the cursor and one round-trip is the cheaper path.
  ///
  /// Truth table:
  /// | isSlow | since     | result |
  /// |--------|-----------|--------|
  /// | false  | null      | false  | ← full pull on fast link → paginated
  /// | false  | DateTime  | true   | ← incremental on fast link → RPC
  /// | true   | null      | false  | ← full pull on slow link → paginated
  /// | true   | DateTime  | false  | ← incremental on slow link → paginated
  @visibleForTesting
  static bool shouldUseSnapshotRpc({
    required bool isSlow,
    required DateTime? since,
  }) =>
      !isSlow && since != null;

  /// Pulls data for the current business from Supabase and populates the local DB.
  /// If [since] is provided, performs an incremental pull.
  ///
  /// **Pull-path routing (Phase 2):**
  /// - Full/first pulls ([since] == null) ALWAYS use the paginated
  ///   `_pullViaPostgRest` path, regardless of connectivity. The monolithic
  ///   `pos_pull_snapshot` RPC has no row cap on a full pull and can time out
  ///   on large datasets — the paginated keyset path is strictly safer.
  /// - Incremental pulls ([since] != null) on a fast link (Wi-Fi/ethernet)
  ///   still use the `pos_pull_snapshot` RPC for a single round-trip, because
  ///   the payload is bounded by what changed since the cursor.
  /// - Incremental pulls on a slow link (cellular/poor) use the paginated path.
  /// - Decision rule: `!isSlow && since != null` → RPC; everything else →
  ///   paginated PostgREST. See [shouldUseSnapshotRpc].
  ///
  /// Returns the set of tables that were leaf-deferred on this pull (subset
  /// of [_deferrableTables]). When non-empty, the caller (pullChanges) must
  /// NOT advance `last_sync_timestamp::<businessId>` so the next pull is a
  /// fresh full pull that catches up the deferred slices.
  Future<Set<String>> pullInitialData(
    String businessId, {
    DateTime? since,
    Set<String> fullPullTables = const <String>{},
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

    // Determine pull page size from the live connectivity signal. On slow or
    // unknown links, bypass the monolithic `pos_pull_snapshot` RPC entirely —
    // a 60-second aggregate query that would time out mathematically on a weak
    // cellular link — and go straight to the paginated PostgREST path.
    final connectivity = await Connectivity().checkConnectivity();
    final pageSize = _pullPageCeilingFor(connectivity);
    final isSlow = pageSize <= _pullPageSizeCellular;

    Map<String, List<dynamic>>? snapshot;
    Set<String> skipped = const <String>{};

    // §3.6: a non-empty backfill set needs PER-TABLE `since` (null for the
    // backfill tables, the cursor for the rest). The monolithic snapshot RPC
    // takes a single `p_since` for every table, so it can't express that —
    // bypass it and use the paginated path, which fetches each table with its
    // own `since`.
    final hasPerTableBackfill = fullPullTables.isNotEmpty;

    if (!hasPerTableBackfill &&
        SupabaseSyncService.shouldUseSnapshotRpc(
          isSlow: isSlow,
          since: since,
        )) {
      try {
        final result = await _supabase
            .rpc(
              'pos_pull_snapshot',
              params: {
                'p_business_id': businessId,
                'p_since': since?.toIso8601String(),
              },
            )
            .timeout(const Duration(seconds: 60));
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
    } else if (since == null) {
      debugPrint(
        '[SyncService] Full pull (since=null) → paginated PostgREST path '
        '(snapshot RPC bypassed).',
      );
    } else {
      debugPrint(
        '[SyncService] Slow connection (pageSize=$pageSize) — '
        'bypassing monolithic RPC, using paginated PostgREST path.',
      );
    }

    if (snapshot == null) {
      final fallback = await _pullViaPostgRest(
        businessId,
        since,
        pageSize: pageSize,
        fullPullTables: fullPullTables,
      );
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
    // Row-weighted progress: sum all row counts before starting the loop so
    // the overlay percentage advances in proportion to actual data restored,
    // not per table (which parks the bar on large tables).
    var rowsTotal = 0;
    for (final t in restoreList) {
      rowsTotal += snapshot[t]!.length;
    }
    var rowsDone = 0;
    // Only update tablesTotal if we're inside an outer stage (background);
    // the minimum-pull path uses a different stage with a fixed total.
    if (pullStatus.value.stage == PullStage.background) {
      pullStatus.value = pullStatus.value.copyWith(
        tablesTotal: restoreTotal,
        rowsTotal: rowsTotal,
      );
    }
    // Collects tables that skipped one or more orphaned rows (a referenced
    // parent slice was absent from this snapshot). Merged into `skipped`
    // below so the caller holds the sync cursor and the next full pull
    // retries those rows once their parent has arrived.
    final fkSkipped = <String>{};
    // §3.7 (A2): arm the per-pull orphaned-row collector so `_insertResilient`
    // records the rows it skips; the targeted-parent fetch below uses them.
    // Captured + disarmed in the finally so a fatal restore error can't leave
    // the field armed for the realtime path to append into.
    _fkOrphanedRows = <String, List<Map<String, dynamic>>>{};
    Map<String, List<Map<String, dynamic>>>? orphanedRows;
    try {
      for (final table in restoreList) {
        final data = snapshot[table]!;
        debugPrint('[SyncService] Syncing $table: ${data.length} rows');
        // §4.6 restore batching: wrap the whole table's row loop in ONE
        // transaction so SQLite commits once per table instead of once per row.
        // On a full first pull this is the dominant cost — thousands of orders /
        // order-items / ledger rows each autocommitting is what makes the
        // first-load overlay overstay even on a fast link. The per-row
        // resilience is UNCHANGED: `_restoreTableData` still calls
        // `_insertResilient` per row, which CATCHES FK / unique violations (no
        // rethrow), so a skipped orphan does not abort the transaction — the
        // good rows still commit and the cursor-hold/defer semantics are
        // byte-for-byte preserved. Only a genuinely fatal (rethrown) error rolls
        // the table back, which already aborts the pull and forces a full
        // re-pull next time, so no row is lost.
        await _db.transaction(
          () => _restoreTableData(table, data, fkSkipped: fkSkipped),
        );
        restoreDone++;
        rowsDone += data.length;
        if (pullStatus.value.stage == PullStage.background) {
          pullStatus.value = pullStatus.value.copyWith(
            tablesDone: restoreDone,
            rowsDone: rowsDone,
          );
        }
      }
    } finally {
      orphanedRows = _fkOrphanedRows;
      _fkOrphanedRows = null;
    }
    // §3.7 targeted parent fetch (A2): before holding the cursor for a full
    // re-pull, try to heal FK-orphans inline — fetch just the missing
    // supplier/category/manufacturer parents by id and retry the affected
    // children. Bounded round-trips; anything it can't heal stays in fkSkipped
    // and falls back to the conservative full re-pull. Runs only on a network
    // pull (the realtime path leaves `_fkOrphanedRows` null).
    if (fkSkipped.isNotEmpty && orphanedRows != null) {
      final healed = await _targetedParentFetchAndRetry(
        businessId,
        fkSkipped,
        orphanedRows,
        snapshot,
      );
      fkSkipped.removeAll(healed);
    }
    if (fkSkipped.isNotEmpty) {
      debugPrint(
        '[SyncService] Restore skipped orphaned rows in: '
        '${fkSkipped.join(", ")}. Holding cursor for retry.',
      );
      skipped = {...skipped, ...fkSkipped};
    }

    // Delete-aware reconciliation for the hard-delete tables only (the
    // `enqueueDelete` call sites — see _hardDeleteReconcileTables). Realtime
    // delivers DELETEs
    // only to a live-subscribed device — Supabase never replays a missed DELETE
    // — and the restore path above is upsert-only (an incoming row absent
    // locally is kept). So a device that missed a live DELETE (offline,
    // backgrounded, or pre-fix) keeps a phantom row that nothing self-heals:
    // e.g. a revoked role permission that lingers forever. Reconcile removes any
    // local row whose id is not in this snapshot's id set for that table.
    //
    // ONLY valid on a COMPLETE snapshot (since == null): there "absent" means
    // "deleted". An incremental delta (since != null) returns only rows changed
    // after the cursor, where "absent" means "unchanged" — reconciling it would
    // wipe live rows. We therefore gate strictly on `since == null`.
    if (since == null) {
      // §3.2 completeness guard: pass the tables whose slice did NOT fully
      // arrive (fetch-failed/leaf-deferred + FK-orphan skips, merged into
      // `skipped` above) so reconcile never reads a truncated slice as
      // "the rest were deleted".
      await _reconcileHardDeletes(
        businessId,
        snapshot,
        incompleteTables: skipped,
      );
    }
    return skipped;
  }

  /// §3.7 targeted parent fetch (A2). For child rows that FK-orphaned during the
  /// restore, fetch ONLY the specific missing parent rows by id — the common
  /// inline-created supplier / category / manufacturer case — restore them, then
  /// re-run restore for the affected child tables from the [snapshot] already in
  /// hand. Bounded: total parent fetches are capped at [_maxTargetedParentFetch]
  /// so a flaky link or a genuinely-absent parent can't trigger a round-trip
  /// storm; beyond the cap (or on any fetch error) the children are left skipped
  /// and the caller falls back to A1's conservative full re-pull.
  ///
  /// Returns the set of child tables that healed (no longer orphan), so the
  /// caller can drop them from `fkSkipped`.
  Future<Set<String>> _targetedParentFetchAndRetry(
    String businessId,
    Set<String> fkSkipped,
    Map<String, List<Map<String, dynamic>>> orphanedRows,
    Map<String, List<dynamic>> snapshot,
  ) async {
    // 1. Collect candidate missing parents (parentTable → ids) from the
    //    allowlisted FK fields present on the orphaned rows.
    final wantByParent = <String, Set<String>>{};
    for (final rows in orphanedRows.values) {
      for (final r in rows) {
        for (final entry in _targetedParentFkFields.entries) {
          final value = r[entry.key];
          if (value is String && value.isNotEmpty) {
            wantByParent.putIfAbsent(entry.value, () => <String>{}).add(value);
          }
        }
      }
    }
    if (wantByParent.isEmpty) return const <String>{};

    // 2. Keep only ids that aren't already local (only genuinely-missing parents
    //    need a round-trip) and enforce the bound.
    var totalToFetch = 0;
    final missingByParent = <String, List<String>>{};
    for (final entry in wantByParent.entries) {
      final present = await _localExistingIds(entry.key, entry.value);
      final missing = entry.value.difference(present).toList();
      if (missing.isEmpty) continue;
      missingByParent[entry.key] = missing;
      totalToFetch += missing.length;
    }
    if (missingByParent.isEmpty) {
      // Parents are already local — the orphan was a transient ordering blip
      // within this pull. Retry the children straight away.
      return _retryOrphanedChildren(orphanedRows.keys, snapshot);
    }
    if (totalToFetch > _maxTargetedParentFetch) {
      debugPrint(
        '[SyncService] A2 skipped: $totalToFetch missing parents exceeds cap '
        '($_maxTargetedParentFetch) — falling back to full re-pull.',
      );
      return const <String>{};
    }

    // 3. Fetch each parent table's missing rows by id (one batched round-trip
    //    per parent table) and restore them. Any fetch failure aborts A2 so the
    //    caller falls back to the full re-pull.
    for (final entry in missingByParent.entries) {
      try {
        final List<dynamic> rows = await _supabase
            .from(entry.key)
            .select()
            .eq('business_id', businessId)
            .inFilter('id', entry.value)
            .timeout(const Duration(seconds: 15));
        if (rows.isNotEmpty) {
          await _restoreTableData(entry.key, rows);
        }
        debugPrint(
          '[SyncService] A2 fetched ${rows.length}/${entry.value.length} '
          'missing ${entry.key} parent(s) by id.',
        );
      } catch (e) {
        debugPrint('[SyncService] A2 parent fetch failed for ${entry.key}: $e');
        return const <String>{};
      }
    }

    // 4. Retry the affected children from the snapshot now that parents exist.
    return _retryOrphanedChildren(orphanedRows.keys, snapshot);
  }

  /// Re-runs restore for the previously-orphaned child tables from the
  /// [snapshot] already in hand (snake_case rows). Returns the set that healed
  /// cleanly (no second-pass FK skip). `_fkOrphanedRows` is null here, so the
  /// second pass does not re-collect.
  Future<Set<String>> _retryOrphanedChildren(
    Iterable<String> childTables,
    Map<String, List<dynamic>> snapshot,
  ) async {
    final healed = <String>{};
    for (final table in childTables) {
      final data = snapshot[table];
      if (data == null || data.isEmpty) continue;
      final secondPass = <String>{};
      await _db.transaction(
        () => _restoreTableData(table, data, fkSkipped: secondPass),
      );
      if (!secondPass.contains(table)) {
        healed.add(table);
        debugPrint(
          '[SyncService] A2 healed child table $table after parent fetch.',
        );
      }
    }
    return healed;
  }

  /// Returns the subset of [ids] for [table] that already exist locally. Used by
  /// the A2 targeted parent fetch to avoid round-tripping for parents already on
  /// the device. [table] comes from the static [_targetedParentFkFields]
  /// allowlist, so the interpolation carries no injection risk.
  Future<Set<String>> _localExistingIds(String table, Set<String> ids) async {
    if (ids.isEmpty) return const <String>{};
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await _db
        .customSelect(
          'SELECT id FROM $table WHERE id IN ($placeholders)',
          variables: ids.map(Variable.withString).toList(),
        )
        .get();
    return {for (final r in rows) r.read<String>('id')};
  }

  /// Hard-delete tables (the only `enqueueDelete` call sites): a revoke/delete
  /// is a true row removal the cloud forgets, so a delete that a device missed
  /// has no upsert to self-heal it. Restricted to this set — soft-delete tables
  /// carry `is_deleted` and must NEVER be hard-removed by a reconcile.
  static const _hardDeleteReconcileTables = {
    'role_permissions',
    'user_permission_overrides',
    'store_role_permissions',
    'user_stores',
    'saved_carts',
    'notifications',
  };

  /// Delete local rows of the hard-delete tables whose id is absent from a
  /// COMPLETE [snapshot] for [businessId]. LOCAL-ONLY: applies cloud truth, so
  /// it never enqueues anything (§5 exception #1 — same contract as
  /// [_restoreTableData]; pushing the deletes back would loop).
  ///
  /// Caller MUST only invoke this on a full snapshot (`since == null`).
  ///
  /// Edge cases:
  /// - A table KEY present with an empty list legitimately means "the cloud has
  ///   no rows for this business" → delete all local rows for it. We use the
  ///   id-set built from the (possibly empty) slice.
  /// - A table ABSENT from the snapshot payload (e.g. a partial/failed snapshot
  ///   that never included the key) is left alone — we must not wipe data on the
  ///   strength of a slice that simply didn't arrive. Only tables whose key is
  ///   present in [snapshot] are reconciled.
  /// - Every delete is business-scoped (the device may hold more than one
  ///   business's data — see the business-scoping invariant).
  Future<void> _reconcileHardDeletes(
    String businessId,
    Map<String, List<dynamic>> snapshot, {
    Set<String> incompleteTables = const <String>{},
  }) async {
    for (final table in _hardDeleteReconcileTables) {
      // Absent key ⇒ slice didn't arrive ⇒ do not reconcile (no wipe).
      if (!snapshot.containsKey(table)) continue;
      // §3.2 completeness guard: a table whose fetch failed or was leaf-deferred
      // arrives as an empty/short list (`_pullViaPostgRest` stores `[]` for a
      // failed table). Reading that as "every local row was deleted" is the
      // truncation-wipe bug — a server-side cap/timeout must never trigger
      // deletions. Only reconcile a slice known to be complete.
      if (incompleteTables.contains(table)) {
        debugPrint(
          '[SyncService] Reconcile skipped $table — slice incomplete '
          '(deferred/failed fetch); not reading a short slice as deletions.',
        );
        continue;
      }
      final cloudIds = <String>{
        for (final r in snapshot[table]!)
          if (r is Map && r['id'] != null) r['id'].toString(),
      };
      // §3.2 / Invariant #12: a local row that still has an un-uploaded outbox
      // entry is offline-created/edited data the cloud has not seen yet — its
      // absence from the snapshot means "not pushed", NOT "deleted". Protect it
      // by treating its id as present.
      final pendingIds = await _db.syncDao.pendingRowIds(
        table,
        businessId: businessId,
      );
      final protectedIds = pendingIds.isEmpty
          ? cloudIds
          : <String>{...cloudIds, ...pendingIds};
      final removed = await _deleteLocalRowsNotIn(
        table,
        businessId,
        protectedIds,
      );
      if (removed > 0) {
        debugPrint(
          '[SyncService] Reconcile $table: removed $removed local row(s) '
          'absent from the cloud snapshot for $businessId',
        );
      }
    }
  }

  /// Business-scoped hard-delete of [table] rows whose id is not in [cloudIds].
  /// Returns the number of rows removed. Typed deletes (not raw SQL) so Drift
  /// stream queries refresh. LOCAL-ONLY (§5 exception #1 — never enqueues).
  Future<int> _deleteLocalRowsNotIn(
    String table,
    String businessId,
    Set<String> cloudIds,
  ) async {
    // Drift exposes `isIn`; negate with `.not()` for "not in" (same idiom as
    // SavedCartsDao.pruneExcept). An empty `ids` makes `isIn([])` false, so
    // `.not()` is true for every row → all of this business's rows are removed,
    // which is exactly right when the cloud's slice for that table is empty.
    final ids = cloudIds.toList();
    switch (table) {
      case 'role_permissions':
        return (_db.delete(_db.rolePermissions)..where(
              (t) => t.businessId.equals(businessId) & t.id.isIn(ids).not(),
            ))
            .go();
      case 'user_permission_overrides':
        return (_db.delete(_db.userPermissionOverrides)..where(
              (t) => t.businessId.equals(businessId) & t.id.isIn(ids).not(),
            ))
            .go();
      case 'store_role_permissions':
        return (_db.delete(_db.storeRolePermissions)..where(
              (t) => t.businessId.equals(businessId) & t.id.isIn(ids).not(),
            ))
            .go();
      case 'user_stores':
        return (_db.delete(_db.userStores)..where(
              (t) => t.businessId.equals(businessId) & t.id.isIn(ids).not(),
            ))
            .go();
      case 'saved_carts':
        return (_db.delete(_db.savedCarts)..where(
              (t) => t.businessId.equals(businessId) & t.id.isIn(ids).not(),
            ))
            .go();
      case 'notifications':
        return (_db.delete(_db.notifications)..where(
              (t) => t.businessId.equals(businessId) & t.id.isIn(ids).not(),
            ))
            .go();
      default:
        return 0;
    }
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
    DateTime? since, {
    required int pageSize,
    Set<String> fullPullTables = const <String>{},
  }) async {
    final isSlow = pageSize <= _pullPageSizeCellular;

    // §3.6 per-table backfill cursors: a table owed a full catch-up is fetched
    // with `since=null`; every other table stays incremental on the cursor.
    DateTime? sinceFor(String table) =>
        fullPullTables.contains(table) ? null : since;

    if (isSlow) {
      // On cellular / poor connections, fetch tables SEQUENTIALLY in _pullOrder
      // to avoid the parallel burst congesting an already-weak link.
      // FK-safe order is preserved (same as the Wi-Fi path below).
      debugPrint(
        '[SyncService] Sequential paginated pull '
        '(pageSize=$pageSize, ${_pullOrder.length} tables)...',
      );
      final results = <String, List<dynamic>>{};
      final failed = <String>{};
      for (final table in _pullOrder) {
        try {
          final data = await _fetchOneTable(
            table,
            businessId,
            sinceFor(table),
            pageSize: pageSize,
          );
          results[table] = data;
        } catch (e) {
          debugPrint('[SyncService] Sequential fetch failed for $table: $e');
          results[table] = const <dynamic>[];
          failed.add(table);
        }
      }
      if (failed.isEmpty) {
        return (data: results, skipped: const <String>{});
      }
      final critical = failed.difference(_deferrableTables);
      if (critical.isNotEmpty) {
        throw PartialPullException(critical);
      }
      debugPrint(
        '[SyncService] Continuing past deferrable failures (sequential): '
        '${failed.join(", ")}. last_sync_timestamp will not advance; '
        'next pull will be a full pull to catch up.',
      );
      return (data: results, skipped: failed);
    }

    // Wi-Fi / Ethernet path: parallel first pass for speed, sequential retry
    // for any first-pass failures (same logic as before, plus pageSize).
    final firstPass = await Future.wait(
      _pullOrder.map((table) async {
        try {
          return _FetchOutcome(
            table,
            await _fetchOneTable(
              table,
              businessId,
              sinceFor(table),
              pageSize: pageSize,
            ),
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
        final data = await _fetchOneTable(
          outcome.table,
          businessId,
          sinceFor(outcome.table),
          pageSize: pageSize,
        );
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

  /// Single-table PostgREST fetch with cursor-based pagination.
  ///
  /// Fetches rows in pages of [pageSize] rows, ordered by `last_updated_at`
  /// ascending (and `id` ascending as a secondary tie-break for all tables
  /// except `system_config`). This ordering guarantees stable pagination —
  /// no row is skipped or double-counted across page boundaries.
  ///
  /// On a page-level [TimeoutException] the page size is halved (floored at
  /// [_minPullPageSize]) and the same offset is retried once. A second
  /// timeout at the floor propagates so the caller can classify the failure.
  ///
  /// `system_config` is global (no tenant filter, no `id` column, tiny
  /// dataset) — it is fetched in a single unpaginated call.
  Future<List<dynamic>> _fetchOneTable(
    String table,
    String businessId,
    DateTime? since, {
    int pageSize = _pullPageSizeWifi,
  }) async {
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

    // system_config: global, tiny, no `id` column — single unpaginated call.
    if (isGlobal) {
      final List<dynamic> data = await query.timeout(
        const Duration(seconds: 25),
      );
      return data;
    }

    // Stable ordering required for pagination: rows must not shift across
    // page boundaries as new rows arrive mid-pull. `last_updated_at` alone
    // is not unique (multiple rows can share a second boundary); `id` breaks
    // ties deterministically.
    //
    // `.order()` returns PostgrestTransformBuilder, which is a subtype of
    // PostgrestBuilder but NOT PostgrestFilterBuilder — declare a new variable
    // so the type annotation stays correct.
    final orderedQuery = query
        .order('last_updated_at', ascending: true)
        .order('id', ascending: true);

    final allRows = <dynamic>[];
    int offset = 0;
    int currentPageSize = pageSize;

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
            '[SyncService] Pull page timeout at min size for $table '
            '(offset=$offset, size=$currentPageSize): $e',
          );
          rethrow;
        }
        currentPageSize = halved;
        debugPrint(
          '[SyncService] Pull page timeout for $table '
          '(offset=$offset) — shrinking page to $currentPageSize and retrying.',
        );
        // Retry the same offset with the smaller page size (offset unchanged).
      }
    }

    return allRows;
  }

  /// Cheap single-row refresh of the `businesses` row from the cloud, applied
  /// locally through the normal restore path (LWW guard included). Used by the
  /// subscription gate (§32) on app resume / periodic tick / the locked
  /// screen's "Check again", so an admin-console subscription change that this
  /// device missed (it was backgrounded, or a realtime event was dropped) is
  /// reflected without waiting for the next full pull. Best-effort: never
  /// throws — a failed refresh just leaves the last-known local state.
  Future<void> refreshBusinessRow(String businessId) async {
    try {
      final data = await _fetchOneTable('businesses', businessId, null);
      if (data.isNotEmpty) {
        await _restoreTableData('businesses', data);
      }
    } catch (e) {
      debugPrint('[SyncService] refreshBusinessRow failed: $e');
    }
  }

  /// Subscribes to real-time changes from Supabase for this business.
  void startRealtimeSync(String businessId) {
    if (_tableChannels.isNotEmpty) return;

    debugPrint(
      '[SyncService] Starting real-time sync for business $businessId',
    );

    // One channel per synced tenant table, each with an explicit `table:` +
    // `business_id` filter. The previous single `channel('public:*')` set a
    // `business_id` filter but no `table:`; Supabase Realtime cannot honour a
    // filtered postgres_changes binding without a table, so the server↔client
    // binding reconciliation mismatched and the whole channel silently failed —
    // no inbound realtime events for ANY tenant table (changes only ever landed
    // via the snapshot pull). Per-table channels also isolate a bad table (e.g.
    // one not in the `supabase_realtime` publication) to its own channel instead
    // of tearing down every subscription. The permanent subscribe-status
    // callback surfaces SUBSCRIBED / CHANNEL_ERROR / TIMED_OUT — the old
    // `..subscribe()` had none, so the failure was invisible.
    //
    // `businesses` (no `business_id` column — its `id` IS the business id) is
    // handled by the separate channel below; `system_config` is global (no
    // `business_id`), so both are skipped here.
    for (final table in _pullOrder) {
      if (table == 'businesses' || table == 'system_config') continue;
      try {
        final channel =
            _supabase
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
                  callback: (payload) => _applyRealtimeEvent(payload),
                )
              ..subscribe((status, error) {
                if (status == RealtimeSubscribeStatus.channelError ||
                    status == RealtimeSubscribeStatus.timedOut) {
                  debugPrint(
                    '[SyncService] Realtime channel "$table" $status'
                    '${error != null ? ' — $error' : ''}',
                  );
                } else if (status == RealtimeSubscribeStatus.subscribed) {
                  debugPrint('[SyncService] Realtime subscribed: $table');
                }
              });
        _tableChannels.add(channel);
      } catch (e) {
        debugPrint('[SyncService] Realtime subscribe failed for "$table": $e');
      }
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
                  // The owner permanently deleted this business (§10.3). On a
                  // staff device the cascade-DELETE event arrives here: confirm
                  // via the tombstone, then wipe + sign out (instant path; the
                  // login pull + reconnect backstops cover offline devices).
                  if (payload.eventType == PostgresChangeEvent.delete) {
                    final id = payload.oldRecord['id'] as String?;
                    if (id == businessId) {
                      await _wipeIfBusinessDeleted(businessId);
                    }
                    return;
                  }
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

  /// Applies one realtime postgres change to the local DB.
  ///
  /// Wrapped in a catch-all so a single malformed or natural-key-colliding
  /// cloud echo can NEVER escape this stream callback to the top-level zone and
  /// crash a sale in progress (offline-first, master plan §33). The orders /
  /// FK-resilient restore branches already absorb the expected collisions; this
  /// is the belt-and-suspenders boundary for anything else. On failure: log +
  /// record non-fatal and move on — the next full pull reconciles.
  Future<void> _applyRealtimeEvent(PostgresChangePayload payload) async {
    try {
      debugPrint(
        '[SyncService] Realtime Event: ${payload.eventType} on ${payload.table}',
      );

      final eventTable = payload.table;

      // DELETE: the cloud removed a hard-deleted row
      // (role_permissions / saved_carts / notifications — the
      // only `enqueueDelete` tables). Apply the removal locally,
      // else the row lingers and a stale INSERT/UPDATE echo can
      // resurrect it permanently (e.g. revoking a role permission
      // that then re-appears). DELETE payloads carry the row in
      // `oldRecord`, not `newRecord`, so the upsert path below
      // never saw them. Incoming cloud event: delete locally
      // only, never re-enqueue (§5 exception #1, same contract as
      // _restoreTableData — re-pushing would loop).
      if (payload.eventType == PostgresChangeEvent.delete) {
        final id = payload.oldRecord['id'] as String?;
        if (id != null) {
          await _deleteLocalRowById(eventTable, id);
        }
        return;
      }

      final newRecord = payload.newRecord;

      if (newRecord.isNotEmpty) {
        await _restoreTableData(eventTable, [newRecord]);
        // Single-active-device sign-in: when our own session row
        // gets revoked by another device's fresh sign-in, ask
        // AuthService to fullLogout this device.
        if (eventTable == 'sessions' &&
            newRecord['revoked_at'] != null &&
            newRecord['id'] == currentSessionIdResolver?.call()) {
          onCurrentSessionRevoked?.call();
        }
      }
    } catch (e, st) {
      debugPrint(
        '[SyncService] Realtime apply failed for ${payload.table}: $e',
      );
      CrashReporter.record(e, st, context: 'sync.realtime.${payload.table}');
    }
  }

  /// Authoritative, false-positive-proof check for "did the owner delete this
  /// business?" (master plan §10.3 staff propagation). Reads the cloud-only
  /// `deleted_businesses` tombstone, which carries a row ONLY for a genuinely
  /// deleted business — never for a suspended/removed staff member, so a
  /// confirmation here can safely trigger a device wipe.
  ///
  /// Returns true ONLY on a confirmed tombstone row. Any error (offline, RLS
  /// hiccup, transient permission-denied) returns false so an ambiguous failure
  /// can NEVER wipe a staff device. The staff JWT survives the cascade (only the
  /// CEO's auth.users row is deleted), and the tombstone is readable by any
  /// authenticated caller, so this succeeds even after membership is gone.
  Future<bool> _confirmBusinessDeleted(String businessId) async {
    try {
      final rows = await _supabase
          .from('deleted_businesses')
          .select('business_id')
          .eq('business_id', businessId)
          .limit(1);
      return rows.isNotEmpty;
    } catch (e) {
      debugPrint('[SyncService] deleted_businesses check failed: $e');
      return false;
    }
  }

  /// Public wrapper for [_confirmBusinessDeleted] — used by
  /// [AuthService.wipeOrphanedLocalBusiness] to detect a stale local user row
  /// left behind by a previous "Delete Business & Account" (§10.3) on THIS
  /// device, e.g. when the same email re-registers afterwards. Same
  /// false-positive-proof contract: true only on a confirmed tombstone row.
  Future<bool> confirmBusinessDeleted(String businessId) =>
      _confirmBusinessDeleted(businessId);

  /// Confirms via the tombstone and, if positive, hands off to AuthService to
  /// wipe + full-logout this device. Re-entry is guarded inside AuthService.
  Future<bool> _wipeIfBusinessDeleted(String businessId) async {
    if (await _confirmBusinessDeleted(businessId)) {
      debugPrint(
        '[SyncService] Active business $businessId was deleted by its owner — '
        'wiping this device.',
      );
      await onActiveBusinessDeleted?.call();
      return true;
    }
    return false;
  }

  /// Stops listening to real-time changes (e.g., on logout).
  void stopRealtimeSync() {
    debugPrint('[SyncService] Stopping real-time sync.');
    _tearDownRealtimeChannels();
    stopAutoPush();
  }

  /// Removes the active realtime channels without touching auto-push. Shared by
  /// [stopRealtimeSync] (logout) and [restartRealtimeSync] (resubscribe).
  void _tearDownRealtimeChannels() {
    for (final channel in _tableChannels) {
      _supabase.removeChannel(channel);
    }
    _tableChannels.clear();
    if (_businessesChannel != null) {
      _supabase.removeChannel(_businessesChannel!);
      _businessesChannel = null;
    }
  }

  /// Re-establishes the realtime subscriptions after they may have been
  /// silently dropped. `startRealtimeSync` is called only once at sign-in and
  /// no-ops while the channel objects are still held (`_tableChannels` guard),
  /// so a websocket that the OS suspended during Doze / app-background, or that
  /// a WiFi↔mobile handoff tore down, leaves the channels permanently dead with
  /// no path back to live updates — the symptom is "live sync stops" on a
  /// physical device even though the one-shot reconnect pull still catches up.
  /// The SDK's channel rejoin is not guaranteed to fire after a long
  /// suspension, so we drop the stale channels and resubscribe from scratch.
  /// Driven by app-resume and connectivity-recovery. Idempotent and cheap (a
  /// few channels); a no-op when there were no channels to begin with (not yet
  /// signed in) — `startRealtimeSync` itself requires a logged-in business.
  void restartRealtimeSync(String businessId) {
    if (_tableChannels.isEmpty && _businessesChannel == null) return;
    debugPrint('[SyncService] Re-subscribing realtime for $businessId.');
    _tearDownRealtimeChannels();
    startRealtimeSync(businessId);
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
            // Re-warm on every fresh session: a logout→re-login (or token
            // refresh after a long idle) starts from a cold connection again.
            _didWarmUpThisSession = false;
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
            _didWarmUpThisSession = false;
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
      _autoPushPeriodic ??= Timer.periodic(_autoPushPeriodicInterval, (
        _,
      ) async {
        try {
          if (_pushing) return;
          await _db.syncDao.resetStuckInProgress();
          // §6.8.1: re-enqueue any now-healable orphans before draining so a
          // recovered row goes up on this same tick.
          await _recoverDueOrphans();
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

  /// Automatic orphan-recovery sweep (§6.8.1). Re-enqueues self-healing
  /// orphans (FK-deferred parents that may have landed, ledger `created_at`
  /// immutables now scrubbed at push) back into `sync_queue`, capped per orphan
  /// so a still-failing row can't loop forever. Skipped when offline — a
  /// re-enqueue would just sit in the queue with no push attempt — and gated by
  /// `_pushing` is unnecessary (it only moves rows; the caller pushes after).
  /// Returns true if anything was recovered, so the caller can kick a push.
  Future<bool> _recoverDueOrphans() async {
    if (!isOnline.value) return false;
    try {
      final recovered = await _db.syncDao.autoRecoverDueOrphans();
      if (recovered > 0) {
        debugPrint(
          '[SyncService] auto-recovered $recovered orphan(s) into the queue.',
        );
      }
      return recovered > 0;
    } catch (e) {
      debugPrint('[SyncService] orphan auto-recovery failed: $e');
      return false;
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
        await (_db.update(_db.stores)..where((t) => t.id.equals(w.id))).write(
          StoresCompanion(lastUpdatedAt: Value(now)),
        );
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
      // §6.8.1: a better link is the ideal moment to re-attempt self-healing
      // orphans (e.g. an FK parent that landed while we were offline). Move
      // them back into the queue before the push below sweeps it.
      await _recoverDueOrphans();
      _scheduleDebouncedPush();

      final businessId = _db.businessIdResolver.call();
      if (businessId != null) {
        // A network transition (reconnect, or a WiFi↔mobile handoff that fires
        // this listener) can leave the realtime websocket dead with no SDK
        // rejoin — resubscribe so live updates resume, not just the one-shot
        // catch-up pull below.
        restartRealtimeSync(businessId);
        unawaited(() async {
          try {
            // Reconnect backstop for a staff device that was offline when the
            // owner deleted the business (§10.3) and never relaunched: if the
            // tombstone now confirms the deletion, wipe + sign out and skip the
            // pull (it would only fail with permission-denied).
            if (await _wipeIfBusinessDeleted(businessId)) return;
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

      final rows = await (_db.select(
        _db.users,
      )..where((t) => t.businessId.equals(businessId))).get();
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
      // v46 (§33) — crash/error log. Only rows with a business_id are
      // enqueueable; local-only pre-login rows (null business_id) are skipped
      // by _backfillTable's own tenant guard, matching ErrorLogDao.logError.
      await _backfillTable(_db.errorLogs, 'error_logs', (row) => row.id);
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

    final ids = rows.map((r) => r['id']).whereType<String>().toSet().toList();
    if (ids.isEmpty) return rows;

    // Drift stores DateTime as integer Unix seconds; reading the raw
    // column type and comparing in epoch space avoids DateTime parse cost.
    final placeholders = List.filled(ids.length, '?').join(',');
    final localResults = await _db
        .customSelect(
          'SELECT id, last_updated_at FROM $table WHERE id IN ($placeholders)',
          variables: ids.map(Variable.withString).toList(),
        )
        .get();

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

  /// True if [e] is a SQLite UNIQUE constraint violation (extended result code
  /// 2067 / SQLITE_CONSTRAINT_UNIQUE). Matched by message so we don't depend on
  /// the concrete `SqliteException` type.
  ///
  /// This is the cross-device natural-key collision: two devices that were both
  /// offline minted the SAME business-scoped sequence value (e.g. `ORD-000123`
  /// order_number — `generateOrderNumber` is a local count), so the rows share
  /// a UNIQUE key but carry different `id`s. `insertOnConflictUpdate` keys on
  /// `id`, misses the existing local row, and trips the secondary UNIQUE. It is
  /// permanent data (a re-pull can't reconcile it), so the restore skips the
  /// incoming cloud row rather than crashing the pull / realtime apply.
  static bool _isUniqueConstraintViolation(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('unique constraint failed') ||
        s.contains('sqlite_constraint_unique') ||
        s.contains('(2067)');
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
    Future<void> Function() doInsert, {
    Future<bool> Function()? healUniqueCollision,
  }) async {
    try {
      await doInsert();
    } catch (e) {
      // Cross-device natural-key collision (e.g. two offline tills both minted
      // ORD-000123). UNIQUE-skip BEFORE the FK check: this is permanent data, a
      // re-pull can't reconcile it, so — unlike the FK case — we DON'T defer
      // (no `fkSkipped` add, no forced full re-pull). We skip-and-log this one
      // cloud row so the rest of the pull / realtime echo lands and a sale in
      // progress isn't crashed. The row stays visible on its originating device
      // and in the cloud. Root cause is client-side count-based numbering
      // (`generateOrderNumber`) — fixing that is a master-plan change.
      if (_isUniqueConstraintViolation(e)) {
        // §30.8.1 legacy-collision self-heal: a caller (orders) can free the
        // colliding natural key by renumbering the LOCAL blocker, then we retry
        // so the cloud's authoritative row lands in THIS pull instead of
        // orphaning its children forever.
        if (healUniqueCollision != null) {
          try {
            if (await healUniqueCollision()) {
              await doInsert();
              return;
            }
          } catch (e2) {
            debugPrint(
              '[SyncService] unique-collision heal failed for $table '
              '${r['id']}: $e2',
            );
          }
        }
        debugPrint(
          '[SyncService] Skipped $table row ${r['id']} during restore — '
          'natural-key UNIQUE collision (another device minted the same '
          'business-scoped number). Cloud row not mirrored here. $e',
        );
        return;
      }
      if (!_isForeignKeyViolation(e)) rethrow;
      fkSkipped?.add(table);
      // §3.7 (A2): record the orphaned row so the post-restore targeted-parent
      // fetch can pull its missing parent by id and retry it inline. Collector
      // is non-null only during a pullInitialData restore loop.
      _fkOrphanedRows?.putIfAbsent(table, () => []).add(r);
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
  Future<void>
  _restoreLedgerTable<TableT extends Table, RowT extends Insertable<RowT>>(
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

    // §3.3 / Invariant #12 — clobber prevention. A local row that still has an
    // un-uploaded outbox entry (`sync_queue` or `sync_queue_orphans`) is
    // sacred: an incoming cloud row must NEVER overwrite it, regardless of
    // `last_updated_at`. The timestamp-LWW above is therefore demoted to a
    // tiebreaker for NON-pending rows only (same-second cross-device ties stay
    // cloud-wins for those). This makes correctness independent of whether the
    // DAO write bumped `last_updated_at` — the bug that silently clobbered
    // `businesses` edits (vector C). Scoped to the bound business when known;
    // unscoped during the pre-setCurrentUser bootstrap window (row ids are
    // globally-unique UUIDv7, so the unscoped match is still exact).
    final pendingIds = await _db.syncDao.pendingRowIds(
      table,
      businessId: _db.currentBusinessId,
    );
    if (pendingIds.isNotEmpty) {
      final before = rows.length;
      rows.removeWhere((r) {
        final id = r['id'];
        return id is String && pendingIds.contains(id);
      });
      final protected = before - rows.length;
      if (protected > 0) {
        debugPrint(
          '[SyncService] Invariant #12 protected $protected un-pushed '
          '$table row(s) from cloud overwrite',
        );
      }
    }

    // Defense-in-depth business isolation: when a session is bound, never write
    // a row belonging to a DIFFERENT business into the shared local DB (the
    // device can physically hold >1 business's rows). The pull/realtime fetch
    // is already server-scoped (`.eq` filter + RLS), so this only ever rejects
    // rows that should never have arrived — a no-op on the happy path, and a
    // backstop against an upstream filter regression or snapshot over-fetch.
    // `businesses` is id-keyed (no business_id column) and exempt; global tables
    // (system_config / permissions) carry no businessId so they pass the
    // containsKey check untouched. During the syncMinimumLogin bootstrap
    // (currentBusinessId == null, before setCurrentUser binds) the guard is a
    // no-op so the 4 login tables still restore.
    final boundBiz = _db.currentBusinessId;
    if (boundBiz != null && table != 'businesses') {
      final before = rows.length;
      rows.removeWhere(
        (r) => r.containsKey('businessId') && r['businessId'] != boundBiz,
      );
      final droppedBiz = before - rows.length;
      if (droppedBiz > 0) {
        debugPrint(
          '[SyncService] business_id guard dropped $droppedBiz/$before '
          'cross-business rows for $table (bound=$boundBiz)',
        );
      }
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
            // §32: subscriptionStatus is NOT NULL in Drift; a row that predates
            // the cloud column (brief migration window) would cast null→String
            // and throw. The nullable subscription_plan / *_ends_at tolerate
            // absent → null, so they need no default.
            r.putIfAbsent('subscriptionStatus', () => 'trial');
            await _db
                .into(_db.businesses)
                .insertOnConflictUpdate(BusinessData.fromJson(r));
          }
          break;
        case 'stores':
          for (var r in rows) {
            await _insertResilient('stores', r, fkSkipped, () async {
              await _db
                  .into(_db.stores)
                  .insertOnConflictUpdate(StoreData.fromJson(r));
            });
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
          //   createdAt, lastUpdatedAt.
          // Device-local fields intentionally omitted (never overwrite from
          // cloud):
          //   pin, pinHash, pinSalt, pinIterations, passwordHash,
          //   biometricEnabled, avatarColor.
          for (var r in rows) {
            final id = r['id'] as String;
            final existing = await (_db.select(
              _db.users,
            )..where((u) => u.id.equals(id))).getSingleOrNull();

            DateTime parseTs(Object? v, {DateTime? fallback}) {
              if (v is String) return DateTime.parse(v);
              if (v is DateTime) return v;
              return fallback ?? DateTime.now().toUtc();
            }

            final lastUpdatedAt = parseTs(r['lastUpdatedAt']);
            final createdAt = parseTs(r['createdAt'], fallback: lastUpdatedAt);

            if (existing != null) {
              await (_db.update(
                _db.users,
              )..where((u) => u.id.equals(id))).write(
                UsersCompanion(
                  businessId: Value(r['businessId'] as String),
                  authUserId: Value(r['authUserId'] as String?),
                  name: Value(r['name'] as String? ?? ''),
                  email: Value(r['email'] as String?),
                  storeId: Value(r['storeId'] as String?),
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
            await _insertResilient('roles', r, fkSkipped, () async {
              await _db
                  .into(_db.roles)
                  .insertOnConflictUpdate(RoleData.fromJson(r));
            });
          }
          break;
        case 'role_permissions':
          for (var r in rows) {
            final row = RolePermissionData.fromJson(r);
            // `id` is a random per-grant UUID, but the LOGICAL identity is
            // (role_id, permission_key) — enforced by UNIQUE(role_id,
            // permission_key). A grant→revoke→re-grant cycle or two devices
            // granting the same permission mint different ids for the same
            // pair, so upserting on `id` alone trips that unique constraint
            // (SqliteException 2067). Drop any local row with the same logical
            // key but a different id first, so the incoming cloud row applies
            // cleanly and the device converges on the cloud's id. Restore path
            // — local only, never enqueue (§5 exception #1; re-pushing loops).
            // FK-resilient: role_id → roles. A partial pull dropping the roles
            // slice would FK-abort here; skip-and-defer instead. (The delete is
            // FK-safe; on retry the whole body re-runs once roles arrives.)
            await _insertResilient('role_permissions', r, fkSkipped, () async {
              await (_db.delete(_db.rolePermissions)..where(
                    (t) =>
                        t.roleId.equals(row.roleId) &
                        t.permissionKey.equals(row.permissionKey) &
                        t.id.equals(row.id).not(),
                  ))
                  .go();
              await _db.into(_db.rolePermissions).insertOnConflictUpdate(row);
            });
          }
          break;
        case 'user_permission_overrides':
          for (var r in rows) {
            final row = UserPermissionOverrideData.fromJson(r);
            // Same shape as role_permissions: random `id`, logical identity
            // (business_id, user_id, permission_key) enforced by UNIQUE. Two
            // devices overriding the same (user, permission) mint different ids
            // for the same triple, so upserting on `id` alone trips the unique
            // constraint (2067). Drop any local row with the same logical key
            // but a different id first, so the incoming cloud row applies
            // cleanly and the device converges on the cloud's id. Restore path
            // — local only, never enqueue (§5 exception #1; re-pushing loops).
            // FK-resilient: business_id → businesses, user_id → users. A partial
            // pull dropping either parent would FK-abort here; skip-and-defer.
            await _insertResilient(
              'user_permission_overrides',
              r,
              fkSkipped,
              () async {
                await (_db.delete(_db.userPermissionOverrides)..where(
                      (t) =>
                          t.businessId.equals(row.businessId) &
                          t.userId.equals(row.userId) &
                          t.permissionKey.equals(row.permissionKey) &
                          t.id.equals(row.id).not(),
                    ))
                    .go();
                await _db
                    .into(_db.userPermissionOverrides)
                    .insertOnConflictUpdate(row);
              },
            );
          }
          break;
        case 'store_role_permissions':
          for (var r in rows) {
            final row = StoreRolePermissionData.fromJson(r);
            // Same shape as role_permissions/user_permission_overrides: random
            // `id`, logical identity (store_id, role_id, permission_key)
            // enforced by UNIQUE. Two devices overriding the same (store, role,
            // permission) mint different ids for the same triple, so upserting
            // on `id` alone trips the unique constraint (2067). Drop any local
            // row with the same logical key but a different id first, so the
            // incoming cloud row applies cleanly and the device converges on the
            // cloud's id. Restore path — local only, never enqueue (§5 exception
            // #1; re-pushing loops).
            // FK-resilient: store_id → stores, role_id → roles. A partial pull
            // dropping either parent would FK-abort here; skip-and-defer.
            await _insertResilient(
              'store_role_permissions',
              r,
              fkSkipped,
              () async {
                await (_db.delete(_db.storeRolePermissions)..where(
                      (t) =>
                          t.storeId.equals(row.storeId) &
                          t.roleId.equals(row.roleId) &
                          t.permissionKey.equals(row.permissionKey) &
                          t.id.equals(row.id).not(),
                    ))
                    .go();
                await _db
                    .into(_db.storeRolePermissions)
                    .insertOnConflictUpdate(row);
              },
            );
          }
          break;
        case 'role_settings':
          // role_settings.role_id → roles. A partial pull that dropped the
          // roles slice would FK-abort here; skip-and-defer instead.
          for (var r in rows) {
            await _insertResilient('role_settings', r, fkSkipped, () async {
              await _db
                  .into(_db.roleSettings)
                  .insertOnConflictUpdate(RoleSettingData.fromJson(r));
            });
          }
          break;
        case 'user_businesses':
          // user_businesses.role_id → roles (must already be present).
          // user_businesses.user_id  → users (must already be present).
          // If either parent is absent on this device, catch the FK-787 via
          // _insertResilient so the whole pull doesn't crash; the cursor is
          // held and the next full pull retries once the parent arrives.
          for (var r in rows) {
            await _insertResilient('user_businesses', r, fkSkipped, () async {
              await _db
                  .into(_db.userBusinesses)
                  .insertOnConflictUpdate(UserBusinessData.fromJson(r));
            });
          }
          break;
        case 'user_stores':
          // Same partial-pull guard as user_businesses: user_stores.user_id →
          // users and .store_id → stores. If either parent slice dropped
          // mid-stream, skip-and-defer instead of aborting the whole pull.
          for (var r in rows) {
            await _insertResilient('user_stores', r, fkSkipped, () async {
              await _db
                  .into(_db.userStores)
                  .insertOnConflictUpdate(UserStoreData.fromJson(r));
            });
          }
          break;
        // invite_codes (master plan §6/§9.3). Plain synced tenant table — no
        // device-local columns, so the simple fromJson upsert is correct.
        // Restore order is FK-safe via _pullOrder (after businesses/roles/
        // stores/users). Realtime delivery routes here too via the public:*
        // wildcard, so codes also appear live on other devices.
        case 'invite_codes':
          // invite_codes references business/role/store/generated-by-user. A
          // partial pull dropping any of those parents would FK-abort the whole
          // restore; skip-and-defer the orphaned code instead.
          for (var r in rows) {
            await _insertResilient('invite_codes', r, fkSkipped, () async {
              await _db
                  .into(_db.inviteCodes)
                  .insertOnConflictUpdate(InviteCodeData.fromJson(r));
            });
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
            await _insertResilient('crate_size_groups', r, fkSkipped, () async {
              await _db
                  .into(_db.crateSizeGroups)
                  .insertOnConflictUpdate(CrateSizeGroupData.fromJson(r));
            });
          }
          break;
        case 'manufacturers':
          for (var r in rows) {
            await _insertResilient('manufacturers', r, fkSkipped, () async {
              await _db
                  .into(_db.manufacturers)
                  .insertOnConflictUpdate(ManufacturerData.fromJson(r));
            });
          }
          break;
        case 'categories':
          for (var r in rows) {
            await _insertResilient('categories', r, fkSkipped, () async {
              await _db
                  .into(_db.categories)
                  .insertOnConflictUpdate(CategoryData.fromJson(r));
            });
          }
          break;
        case 'inventory':
          for (var r in rows) {
            // Inventory cache keyed by its NATURAL key (business_id, product_id,
            // store_id), not its surrogate `id` — same dual-authority hazard as
            // store_crate_balances. Two id-minting authorities exist for the
            // same (business, product, store): the client (UuidV7, addProduct's
            // initial-stock INSERT) and the cloud RPCs pos_create_product_v2 /
            // pos_record_sale / pos_inventory_delta (gen_random_uuid). The two
            // ids never match, and `_applyDomainResponse` only ever UPDATEs the
            // local row by (product_id, store_id) — it never aligns the id. So a
            // PK-keyed insertOnConflictUpdate misses the existing local row and
            // trips UNIQUE(business_id, product_id, store_id) (2067). The result
            // would be silent: a device that created a product never receives
            // cloud stock updates for it (every echo collides and is skipped),
            // so its stock drifts from reality. Upsert on the natural key and
            // align the local `id` to the cloud's so pushes/pulls converge on
            // one canonical row — same approach as store_crate_balances /
            // settings. FK-resilient: references products + stores.
            await _insertResilient('inventory', r, fkSkipped, () {
              final parsed = InventoryData.fromJson(r);
              return _db
                  .into(_db.inventory)
                  .insert(
                    parsed,
                    onConflict: DoUpdate(
                      (_) => InventoryCompanion(
                        id: Value(parsed.id),
                        quantity: Value(parsed.quantity),
                        lastUpdatedAt: Value(parsed.lastUpdatedAt),
                      ),
                      target: [
                        _db.inventory.businessId,
                        _db.inventory.productId,
                        _db.inventory.storeId,
                      ],
                    ),
                  );
            });
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
            await _insertResilient('suppliers', r, fkSkipped, () async {
              await _db
                  .into(_db.suppliers)
                  .insertOnConflictUpdate(SupplierData.fromJson(r));
            });
          }
          break;
        case 'orders':
          for (var r in rows) {
            // FK-resilient: an order references users(staff_id) /
            // stores(store_id) / customers(customer_id). If a parent slice
            // hasn't arrived yet, skip-and-defer instead of aborting the whole
            // pull (the deferred set forces a full re-pull that catches it up).
            final data = OrderData.fromJson(r);
            await _insertResilient(
              'orders',
              r,
              fkSkipped,
              () => _db.into(_db.orders).insertOnConflictUpdate(data),
              // §30.8.1: a legacy local order may hold this cloud order's number
              // under a different id, blocking it (and orphaning its children)
              // every pull. Renumber the local blocker so the cloud row lands.
              healUniqueCollision: () => _healLocalOrderNumberBlocker(data),
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
        case 'order_crate_lines':
          for (var r in rows) {
            // §13.4 — FK-resilient: references orders(order_id) +
            // manufacturers(manufacturer_id). Skip-and-defer if a parent slice
            // is late (a full re-pull catches it up). No JSON columns.
            final data = OrderCrateLineData.fromJson(r);
            await _insertResilient('order_crate_lines', r, fkSkipped, () async {
              // Cloud is authoritative. Heal any stale local row that holds
              // the same natural key (business_id, order_id, manufacturer_id)
              // under a DIFFERENT id — left behind by the pre-fix insertLine
              // that let local/cloud ids diverge. Without this the cloud row's
              // insert would hit the UNIQUE constraint (2067) forever.
              await (_db.delete(_db.orderCrateLines)..where(
                    (t) =>
                        t.businessId.equals(data.businessId) &
                        t.orderId.equals(data.orderId) &
                        t.manufacturerId.equals(data.manufacturerId) &
                        t.id.equals(data.id).not(),
                  ))
                  .go();
              await _db.into(_db.orderCrateLines).insertOnConflictUpdate(data);
            });
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
        case 'error_logs':
          // v46 (§33) — crash/error log. FK-resilient: references businesses +
          // users (both nullable); skip-on-FK if a parent row isn't here yet.
          for (var r in rows) {
            await _insertResilient(
              'error_logs',
              r,
              fkSkipped,
              () => _db
                  .into(_db.errorLogs)
                  .insertOnConflictUpdate(ErrorLogData.fromJson(r)),
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
        case 'expense_budgets':
          for (var r in rows) {
            // FK-resilient: references businesses / stores.
            await _insertResilient(
              'expense_budgets',
              r,
              fkSkipped,
              () => _db
                  .into(_db.expenseBudgets)
                  .insertOnConflictUpdate(ExpenseBudgetData.fromJson(r)),
            );
          }
          break;
        case 'stock_counts':
          for (var r in rows) {
            // FK-resilient: references businesses / stores / users.
            await _insertResilient(
              'stock_counts',
              r,
              fkSkipped,
              () => _db
                  .into(_db.stockCounts)
                  .insertOnConflictUpdate(StockCountData.fromJson(r)),
            );
          }
          break;
        case 'manufacturer_crate_balances':
          for (var r in rows) {
            // Natural-key cache (same rationale as store_crate_balances above):
            // cloud RPC mints gen_random_uuid() while the client mints UuidV7,
            // so reconcile on UNIQUE(business_id, manufacturer_id) to avoid a
            // 2067 collision when the two ids diverge. FK-resilient: references
            // manufacturers / crate_size_groups.
            await _insertResilient(
              'manufacturer_crate_balances',
              r,
              fkSkipped,
              () {
                final parsed = ManufacturerCrateBalance.fromJson(r);
                return _db
                    .into(_db.manufacturerCrateBalances)
                    .insert(
                      parsed,
                      onConflict: DoUpdate(
                        (_) => ManufacturerCrateBalancesCompanion(
                          id: Value(parsed.id),
                          balance: Value(parsed.balance),
                          lastUpdatedAt: Value(parsed.lastUpdatedAt),
                        ),
                        target: [
                          _db.manufacturerCrateBalances.businessId,
                          _db.manufacturerCrateBalances.manufacturerId,
                        ],
                      ),
                    );
              },
            );
          }
          break;
        case 'store_crate_balances':
          for (var r in rows) {
            // Crate-balance cache keyed by its NATURAL key, not its surrogate
            // `id`. Two id-minting authorities exist for the same
            // (business, store, manufacturer): the client (UuidV7, via
            // addEmptyCrates / updateManufacturerStock) and the cloud domain RPC
            // pos_transfer_crates (gen_random_uuid). The two ids never match (see
            // the note in _applyDomainResponse), so a PK-keyed
            // insertOnConflictUpdate misses the existing local row and trips
            // UNIQUE(business_id, store_id, manufacturer_id) (SqliteException
            // 2067). Upsert on the natural key and align the local `id` to the
            // cloud's so pushes/pulls converge on one canonical row — same
            // approach as the `settings` case below. FK-resilient: references
            // stores + manufacturers.
            await _insertResilient('store_crate_balances', r, fkSkipped, () {
              final parsed = StoreCrateBalanceData.fromJson(r);
              return _db
                  .into(_db.storeCrateBalances)
                  .insert(
                    parsed,
                    onConflict: DoUpdate(
                      (_) => StoreCrateBalancesCompanion(
                        id: Value(parsed.id),
                        balance: Value(parsed.balance),
                        lastUpdatedAt: Value(parsed.lastUpdatedAt),
                      ),
                      target: [
                        _db.storeCrateBalances.businessId,
                        _db.storeCrateBalances.storeId,
                        _db.storeCrateBalances.manufacturerId,
                      ],
                    ),
                  );
            });
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
            // Natural-key cache (same rationale as store_crate_balances above):
            // cloud RPC mints gen_random_uuid() while the client mints UuidV7,
            // so reconcile on UNIQUE(business_id, customer_id, manufacturer_id)
            // to avoid a 2067 collision when the two ids diverge. FK-resilient:
            // references customers / crate_size_groups.
            await _insertResilient('customer_crate_balances', r, fkSkipped, () {
              final parsed = CustomerCrateBalance.fromJson(r);
              return _db
                  .into(_db.customerCrateBalances)
                  .insert(
                    parsed,
                    onConflict: DoUpdate(
                      (_) => CustomerCrateBalancesCompanion(
                        id: Value(parsed.id),
                        balance: Value(parsed.balance),
                        lastUpdatedAt: Value(parsed.lastUpdatedAt),
                      ),
                      target: [
                        _db.customerCrateBalances.businessId,
                        _db.customerCrateBalances.customerId,
                        _db.customerCrateBalances.manufacturerId,
                      ],
                    ),
                  );
            });
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
        case 'stock_adjustment_requests':
          // §16.6.1 approval queue. FK-resilient: references products / stores /
          // users. Plain id-keyed upsert (the client-minted id is preserved
          // cloud-side), so an approve/reject status flip from one device
          // overwrites the pending row on the others.
          for (var r in rows) {
            await _insertResilient(
              'stock_adjustment_requests',
              r,
              fkSkipped,
              () => _db
                  .into(_db.stockAdjustmentRequests)
                  .insertOnConflictUpdate(
                    StockAdjustmentRequestData.fromJson(r),
                  ),
            );
          }
          break;
        case 'quick_sale_requests':
          // §12.3.1 Quick Sale approval queue. FK-resilient: references stores /
          // users. Plain id-keyed upsert (the client-minted id is preserved
          // cloud-side), so an approve/reject status flip from the approver's
          // device overwrites the pending row on the cashier's till — which is
          // exactly what releases the item into (or rejects it from) the cart.
          for (var r in rows) {
            await _insertResilient(
              'quick_sale_requests',
              r,
              fkSkipped,
              () => _db
                  .into(_db.quickSaleRequests)
                  .insertOnConflictUpdate(QuickSaleRequestData.fromJson(r)),
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
            await _db
                .into(_db.settings)
                .insert(
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
        case 'supplier_ledger_entries':
          // v42 (§21.10) — append-only supplier ledger; restore via the ledger
          // path (catch-up insert + targeted void update), like
          // wallet_transactions. References suppliers(supplier_id) +
          // users(performed_by), so FK-resilient.
          await _restoreLedgerTable(
            rows,
            tableName: 'supplier_ledger_entries',
            fkSkipped: fkSkipped,
            table: _db.supplierLedgerEntries,
            fromJson: SupplierLedgerEntryData.fromJson,
            voidedAtOf: (d) => d.voidedAt,
            whereNotYetVoided: (t, d) =>
                t.id.equals(d.id) & t.voidedAt.isNull(),
            buildVoidCompanion: (d) => SupplierLedgerEntriesCompanion(
              voidedAt: Value(d.voidedAt),
              voidedBy: Value(d.voidedBy),
              voidReason: Value(d.voidReason),
              lastUpdatedAt: Value(d.lastUpdatedAt),
            ),
          );
          break;
        case 'supplier_crate_ledger':
          // v53 (§3.13) — append-only supplier empty-crate ledger; restore via
          // the ledger path (catch-up insert + targeted void update), like
          // supplier_ledger_entries. References suppliers(supplier_id) +
          // manufacturers(manufacturer_id) + stores(store_id) +
          // users(performed_by), so FK-resilient.
          await _restoreLedgerTable(
            rows,
            tableName: 'supplier_crate_ledger',
            fkSkipped: fkSkipped,
            table: _db.supplierCrateLedger,
            fromJson: SupplierCrateLedgerEntryData.fromJson,
            voidedAtOf: (d) => d.voidedAt,
            whereNotYetVoided: (t, d) =>
                t.id.equals(d.id) & t.voidedAt.isNull(),
            buildVoidCompanion: (d) => SupplierCrateLedgerCompanion(
              voidedAt: Value(d.voidedAt),
              voidedBy: Value(d.voidedBy),
              voidReason: Value(d.voidReason),
              lastUpdatedAt: Value(d.lastUpdatedAt),
            ),
          );
          break;
        case 'supplier_crate_balances':
          for (var r in rows) {
            // Natural-key cache (same rationale as store_crate_balances above):
            // the client mints UuidV7 while a peer/cloud row may carry a
            // different id, so reconcile on
            // UNIQUE(business_id, supplier_id, manufacturer_id) to avoid a 2067
            // collision when the two ids diverge. FK-resilient: references
            // suppliers + manufacturers.
            await _insertResilient('supplier_crate_balances', r, fkSkipped, () {
              final parsed = SupplierCrateBalanceData.fromJson(r);
              return _db
                  .into(_db.supplierCrateBalances)
                  .insert(
                    parsed,
                    onConflict: DoUpdate(
                      (_) => SupplierCrateBalancesCompanion(
                        id: Value(parsed.id),
                        balance: Value(parsed.balance),
                        lastUpdatedAt: Value(parsed.lastUpdatedAt),
                      ),
                      target: [
                        _db.supplierCrateBalances.businessId,
                        _db.supplierCrateBalances.supplierId,
                        _db.supplierCrateBalances.manufacturerId,
                      ],
                    ),
                  );
            });
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
