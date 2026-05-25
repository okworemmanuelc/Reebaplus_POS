import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:drift/drift.dart';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/auth/onboarding/onboarding_draft.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/shared/services/pin_hasher.dart';

/// Route to show after login instead of the default MainLayout.
enum PostLoginRoute { none, successDashboard, accessGranted }

/// Outcome of a silent JWT refresh attempt.
///
/// Callers use this to decide whether to proceed (refreshed/alreadyValid/
/// offline) or fall back to OTP (failedAuth). Offline is deliberately
/// tolerated — the SDK auto-retries on reconnect and sync push already
/// gates on auth, so cloud writes queue safely until the JWT is back.
enum SessionRefreshResult { refreshed, alreadyValid, offline, failedAuth }

/// Holds the currently logged-in user.
/// `value` is null when nobody is logged in.
class AuthService extends ValueNotifier<UserData?> {
  final AppDatabase _db;
  final NavigationService _nav;
  final SecureStorageService _secure;
  final SupabaseSyncService _sync;
  final SupabaseClient _supabase;

  AuthService(this._db, this._nav, this._secure, this._sync, this._supabase)
      : super(null) {
    // Hand the database a thin closure over `value` so DAOs that mix in
    // BusinessScopedDao always read the current session's businessId
    // (auto-tracks login/logout through the ValueNotifier).
    _db.businessIdResolver = () => value?.businessId;
    _db.userIdResolver = () => value?.id;

    // Tag every enqueued sync_queue row with the Supabase auth.uid() that
    // was active when the row was created. Read straight from the SDK
    // (not `value.authUserId`) because Supabase's auth state hydrates
    // independently of our Drift `users` row — currentUser is the source
    // of truth for what auth.uid() the server will see. The dispatch path
    // refuses to push rows whose tag does not match the current uid, so
    // an account switch on this device cannot flush the previous user's
    // queued writes under the new user's JWT.
    _db.authUserIdResolver = () => _supabase.auth.currentUser?.id;

    // Wire single-active-device sign-in: SyncService notifies us when the
    // sessions row matching our currentSessionId has its revoked_at flipped
    // by another device, so we can fullLogout in response.
    _sync.currentSessionIdResolver = () => currentSessionId;
    _sync.onCurrentSessionRevoked = _handleRemoteKick;

    _sync.currentUserIdResolver = () => value?.id;
  }

  /// Notifies listeners whenever the device-level user ID changes.
  final ValueNotifier<String?> deviceUserIdNotifier = ValueNotifier<String?>(
    null,
  );

  /// Id of the active row in `Sessions` for the currently logged-in user.
  /// Set by [setCurrentUser] and cleared on logout.
  String? currentSessionId;

  /// Set before calling [setCurrentUser] to route to a special post-login screen.
  PostLoginRoute pendingPostLoginRoute = PostLoginRoute.none;
  UserData? pendingPostLoginUser;

  /// The currently logged-in user, or null if nobody is logged in.
  UserData? get currentUser => value;

  /// Whether Supabase currently has an active auth session. Reading this is
  /// cheap and does not force a network refresh — supabase-flutter refreshes
  /// the JWT lazily on the next cloud call. A `false` result means there is
  /// no persisted session at all (signed out, refresh-token rotation gave up,
  /// SDK storage wiped, or this device never authenticated). PIN unlock and
  /// the post-auth shell must gate on this so we never mount tenant-scoped UI
  /// without a JWT — every cloud write would otherwise pile up in the queue
  /// with `pushPending` skipping on "no auth session".
  bool get hasSupabaseSession => _supabase.auth.currentUser != null;

  /// Returns every user whose stored PBKDF2 hash matches [pin]. Sentinel /
  /// placeholder rows (no hash yet) never match — they must go through
  /// [setUserPin] first.
  Future<List<UserData>> getUsersByPin(String pin, {String? email}) async {
    final query = _db.select(_db.users);
    if (email != null && email.isNotEmpty) {
      query.where((u) => u.email.equals(email));
    }
    final candidates = await query.get();
    return candidates.where((u) {
      final hash = u.pinHash;
      final salt = u.pinSalt;
      final iterations = u.pinIterations;
      if (hash == null || salt == null || iterations == null) {
        return false;
      }
      final computed = PinHasher.hashBase64(pin, salt, iterations);
      return PinHasher.constantTimeEquals(hash, computed);
    }).toList();
  }

  /// Hashes [plaintext] with a fresh per-user salt and writes the PIN to
  /// the users table. PIN unlock is device-local; the hashed PIN columns
  /// (pin_hash / pin_salt / pin_iterations) live on the users row.
  Future<void> setUserPin(String userId, String plaintext) async {
    debugPrint('[AuthService] setUserPin: userId=$userId');
    final salt = PinHasher.generateSaltBase64();
    final hash = PinHasher.hashBase64(
      plaintext,
      salt,
      PinHasher.defaultIterations,
    );
    const iterations = PinHasher.defaultIterations;

    final usersUpdated = await (_db.update(_db.users)
          ..where((u) => u.id.equals(userId)))
        .write(
      UsersCompanion(
        pin: const Value('__HASHED__'),
        pinHash: Value(hash),
        pinSalt: Value(salt),
        pinIterations: const Value(iterations),
      ),
    );
    debugPrint(
      '[AuthService] setUserPin: users.pin* updated '
      '(rows affected: $usersUpdated)',
    );
    if (usersUpdated == 0) {
      debugPrint(
        '[AuthService] setUserPin: WARNING no local users row for '
        'id=$userId — PIN write landed on zero rows. Caller likely passed '
        'a userId that was never inserted locally (e.g. complete_onboarding '
        'local mirror failed silently or was skipped).',
      );
    }
  }

  // ── Device persistence (encrypted) ──────────────────────────────────────

  /// Returns the locally-persisted user ID, or null if no user has ever
  /// logged in on this device.
  Future<String?> getDeviceUserId() => _secure.getDeviceUserId();

  /// Returns the last successfully logged-in email.
  Future<String?> getLastLoggedInEmail() => _secure.getLastLoggedInEmail();

  /// Persists [userId] so the next app launch goes straight to PIN screen.
  Future<void> saveDeviceUserId(String userId) async {
    await _secure.saveDeviceUserId(userId);
    deviceUserIdNotifier.value = userId;
  }

  /// Persists [email] as the last logged-in user.
  Future<void> saveLastLoggedInEmail(String email) =>
      _secure.saveLastLoggedInEmail(email);

  /// Clears the persisted device session (call on explicit logout).
  Future<void> clearDeviceUserId() async {
    await _secure.clearDeviceUserId();
    deviceUserIdNotifier.value = null;
  }

  // ── Auth method tracking ────────────────────────────────────────────────

  /// Saves the authentication method ("google" or "email") for this session.
  Future<void> saveAuthMethod(String method) => _secure.saveAuthMethod(method);

  /// Returns the stored auth method, or null if not set.
  Future<String?> getAuthMethod() => _secure.getAuthMethod();

  // ── Supabase Sync ─────────────────────────────────────────────────────────

  /// Sentinel PIN written to a local user row when it's been seeded from a
  /// cloud profile but the device hasn't set up a PIN yet. The OTP flow
  /// detects this and routes the user into PIN setup.
  ///
  /// Canonical definition is [kSetupRequiredPin] in `app_database.dart` —
  /// kept there so the sync layer can write it during restore without a
  /// circular import. This static alias preserves the existing public API
  /// (`AuthService.setupRequiredPin`) used by the OTP/email-entry screens.
  static const String setupRequiredPin = kSetupRequiredPin;

  /// Reads the current auth user's cloud profile and the linked business
  /// metadata. Returns null when no profile / business exists, when no user
  /// is signed in, or on network error.
  Future<SupabaseAccountInfo?> fetchSupabaseAccount() async {
    final authUser = _supabase.auth.currentUser;
    if (authUser == null) return null;
    try {
      final profile = await _supabase
          .from('profiles')
          .select('business_id')
          .eq('id', authUser.id)
          .maybeSingle();
      final businessId = profile?['business_id'] as String?;
      if (profile == null || businessId == null) return null;

      final business = await _supabase
          .from('businesses')
          .select('name')
          .eq('id', businessId)
          .maybeSingle();
      final businessName = business?['name'] as String?;
      if (businessName == null) return null;

      return SupabaseAccountInfo(
        businessId: businessId,
        businessName: businessName,
      );
    } catch (e) {
      debugPrint('[AuthService] fetchSupabaseAccount error: $e');
      return null;
    }
  }

  /// Fast-path pull at login boundaries. Pulls only the 4 tables required
  /// for `MainLayout` to render (profiles / businesses / users / warehouses)
  /// and starts realtime. The heavy full pull fires non-blocking from
  /// [setCurrentUser] after MainLayout has mounted.
  Future<void> syncOnLogin(String businessId) async {
    // Minimum pull only — 4 tables (profiles, businesses, users, warehouses)
    // sufficient to render MainLayout. The whole-tenant snapshot pulled
    // here previously moved to the background fire-and-forget from
    // setCurrentUser, cutting blocking sign-in latency from 30-60s to
    // ~1-6s. See plan file (sign-in split).
    //
    // syncOnLogin still runs BEFORE setCurrentUser at the login boundary,
    // so AppDatabase.currentBusinessId is null. syncMinimumLogin takes
    // businessId by argument and only touches `_restoreTableData`
    // (§5-exempt restoration path), so the resolver isn't consulted.
    await _sync.syncMinimumLogin(businessId);
    _sync.startRealtimeSync(businessId);
  }

  /// Reads the current user's cloud profile (by `auth.uid()`) and reflects it
  /// into the local `users` table. On a fresh device this recreates the row
  /// so the existing PIN-entry / device-session flow can pick up.
  ///
  /// Only profile-owned fields (name, businessId) are written.
  /// Device-local fields (pin, passwordHash, biometricEnabled, avatarColor,
  /// warehouseId) are never overwritten on existing rows.
  ///
  /// If no local row exists yet, one is inserted with [setupRequiredPin] as a
  /// placeholder so the caller can route to PIN setup.
  ///
  /// Identity contract (post-0039): when the local row has to be created
  /// from cloud, the inserted `users.id` MUST be the cloud's canonical
  /// `users.id` for this `auth_user_id`, not a fresh client-minted UUIDv7.
  /// The historical fresh-UuidV7 path was the source of the "third id"
  /// problem documented in DEFERRED.md "Three-id mismatch on fresh CEO
  /// onboarding" — `complete_onboarding` mints one id, the local mirror
  /// uses the draft id, and a fresh UuidV7 here on a recovery path would
  /// add yet another. We now query cloud `public.users` for the
  /// canonical id and reuse it locally.
  Future<UserData?> upsertLocalUserFromProfile() async {
    final authUser = _supabase.auth.currentUser;
    if (authUser == null || authUser.email == null) return null;

    Map<String, dynamic>? profile;
    try {
      profile = await _supabase
          .from('profiles')
          .select('name, business_id')
          .eq('id', authUser.id)
          .maybeSingle();
    } catch (e) {
      debugPrint('[AuthService] upsertLocalUserFromProfile fetch error: $e');
      return null;
    }
    if (profile == null) return null;

    final name = profile['name'] as String? ?? '';
    final businessId = profile['business_id'] as String?;
    final email = authUser.email!;

    if (businessId == null) return null;
    final existing = await getUserByEmail(email);
    if (existing != null) {
      await (_db.update(
        _db.users,
      )..where((u) => u.id.equals(existing.id))).write(
        UsersCompanion(
          name: Value(name),
          businessId: Value(businessId),
        ),
      );
      return (_db.select(
        _db.users,
      )..where((u) => u.id.equals(existing.id))).getSingle();
    }

    // No local row. Look up the cloud's canonical users.id for this
    // auth_user_id in this business so the local insert uses the SAME
    // id — never mint a fresh UUIDv7 here (would be the third id).
    String? canonicalId;
    try {
      final cloudUser = await _supabase
          .from('users')
          .select('id')
          .eq('auth_user_id', authUser.id)
          .eq('business_id', businessId)
          .maybeSingle()
          .timeout(const Duration(seconds: 8));
      canonicalId = cloudUser?['id'] as String?;
    } catch (e) {
      debugPrint(
        '[AuthService] upsertLocalUserFromProfile: cloud users.id lookup '
        'failed: $e',
      );
    }

    if (canonicalId == null) {
      // Cloud has a profiles row but no users row — inconsistent. Refuse
      // to synthesise an id locally because we'd diverge from whatever
      // the cloud eventually writes. The caller (login flow / completeOnboarding
      // fallback) should retry on a later sync pull when the cloud
      // catches up. Loud log so the underlying inconsistency is visible.
      debugPrint(
        '[AuthService] upsertLocalUserFromProfile: cloud has profile but '
        'no users row for auth_user_id=${authUser.id} in business=$businessId. '
        'Refusing to mint a third id locally — caller must retry after '
        'cloud catches up. See DEFERRED.md "Three-id mismatch on fresh '
        'CEO onboarding".',
      );
      return null;
    }

    final now = DateTime.now();
    final newComp = UsersCompanion.insert(
      id: Value(canonicalId),
      name: name,
      email: Value(email),
      pin: setupRequiredPin,
      businessId: businessId,
      lastUpdatedAt: Value(now),
    );
    final inserted = await _db.into(_db.users).insertReturning(newComp);
    // No enqueueUpsert here — the cloud already has this users row (we
    // just read its id from there). Pushing it back is a no-op round-trip.
    return inserted;
  }

  // ── Supabase OTP ───────────────────────────────────────────────────────────

  /// Sends a one-time password to [email] via Supabase.
  /// Returns null on success, or an error string on failure.
  Future<String?> sendOtp(String email) async {
    debugPrint('[AuthService] Attempting to send OTP to $email...');
    try {
      await _supabase.auth
          .signInWithOtp(email: email, shouldCreateUser: true)
          .timeout(const Duration(seconds: 25));
      debugPrint('[AuthService] OTP send command success.');
      return null;
    } on TimeoutException {
      debugPrint('[AuthService] OTP send: server did not respond in 25s.');
      return 'The OTP server is slow right now. Please try again in a moment.';
    } on AuthException catch (e) {
      debugPrint('[AuthService] Supabase AuthException: ${e.message}');
      return e.message;
    } catch (e) {
      debugPrint('[AuthService] OTP send generic error: $e');
      if (e.toString().toLowerCase().contains('socketexception') ||
          e.toString().toLowerCase().contains('failed host lookup') ||
          e.toString().toLowerCase().contains('clientexception')) {
        return 'No Internet Connection. Reebaplus POS requires an active connection.';
      }
      return 'Failed to send OTP. Please try again.';
    }
  }

  /// Attempts a one-shot JWT refresh without bouncing the user to OTP.
  ///
  /// Used by PIN unlock to recover an expired access token silently when
  /// the refresh token is still valid (typical case: device was idle long
  /// enough for the access token to expire but the refresh token hasn't).
  Future<SessionRefreshResult> tryRefreshSupabaseSession() async {
    if (_supabase.auth.currentSession != null) {
      return SessionRefreshResult.alreadyValid;
    }
    try {
      final response = await _supabase.auth
          .refreshSession()
          .timeout(const Duration(seconds: 8));
      return response.session != null
          ? SessionRefreshResult.refreshed
          : SessionRefreshResult.failedAuth;
    } on AuthRetryableFetchException catch (e) {
      debugPrint('[AuthService] refreshSession offline: $e');
      return SessionRefreshResult.offline;
    } on TimeoutException catch (_) {
      return SessionRefreshResult.offline;
    } on AuthException catch (e) {
      // "No current session" / refresh-token rejected — genuine auth fail.
      debugPrint('[AuthService] refreshSession auth failure: $e');
      return SessionRefreshResult.failedAuth;
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('socketexception') ||
          msg.contains('failed host lookup') ||
          msg.contains('clientexception')) {
        return SessionRefreshResult.offline;
      }
      debugPrint('[AuthService] refreshSession unknown error: $e');
      return SessionRefreshResult.failedAuth;
    }
  }

  /// Verifies the [otp] code for [email].
  /// Returns null on success, or an error string on failure.
  Future<String?> verifyOtp(String email, String otp) async {
    try {
      await _supabase.auth.verifyOTP(
        email: email,
        token: otp,
        type: OtpType.email,
      );
      return null;
    } on AuthException catch (e) {
      return e.message;
    } catch (e) {
      if (e.toString().toLowerCase().contains('socketexception') ||
          e.toString().toLowerCase().contains('failed host lookup') ||
          e.toString().toLowerCase().contains('clientexception')) {
        return 'No Internet Connection. Reebaplus POS requires an active connection.';
      }
      return 'Verification failed. Please try again.';
    }
  }

  /// Looks up a user in the local database by email.
  Future<UserData?> getUserByEmail(String email) {
    debugPrint('[AuthService] Querying local user for $email...');
    return _db.warehousesDao.getUserByEmail(email).then((u) {
      debugPrint('[AuthService] Query done for $email. Found: ${u != null}');
      return u;
    });
  }

  // ── Session management ─────────────────────────────────────────────────────

  /// Marks [user] as the active logged-in user and applies warehouse lock.
  ///
  /// Onboarding contract: `value` stays null until this call. _onAuthChanged in
  /// main.dart regenerates the navigator key on every value change, which
  /// would tear down the in-progress onboarding stack — so onboarding screens
  /// pass UserData/businessId by widget args instead of reading from `value`.
  void setCurrentUser(UserData user, {bool freshSignIn = false}) {
    try {
      // Side-effects first — navigationService fully ready before any rebuild
      _nav.applyUserWarehouseLock(user.warehouseId);
      _nav.setIndex(0);
      saveDeviceUserId(user.id);
      if (user.email != null) saveLastLoggedInEmail(user.email!);

      // Set synchronously so VLB listener fires before any route pop cleans up
      value = user;

      _sync.startRealtimeSync(user.businessId);
      _sync.startAutoPush();

      // Background full pull. Sign-in split: syncOnLogin already fetched
      // the 4 minimum tables; everything else streams in here while
      // MainLayout is already rendering. Re-entrancy guarded inside
      // pullChanges so this can't race the connectivity-recovery
      // listener or a manual banner retry.
      unawaited(_sync.pullChanges(user.businessId));

      if (user.warehouseId == null) {
        scheduleMicrotask(() => _handleOnboardingAlerts(user));
      }

      // Record a session row for this login. Fire-and-forget — local DB write
      // shouldn't block the post-login UI; failures are logged.
      scheduleMicrotask(() async {
        try {
          final deviceId = await _secure.getOrCreateDeviceId();
          final sessionId = await _db.sessionsDao.createSession(
            userId: user.id,
            ttl: const Duration(days: 30),
            deviceId: deviceId,
          );
          currentSessionId = sessionId;
          if (freshSignIn) {
            await _kickOtherDevices(
              user: user,
              sessionId: sessionId,
              deviceId: deviceId,
            );
          }
        } catch (e) {
          debugPrint('[AuthService] createSession error: $e');
        }
      });
    } catch (e, stack) {
      debugPrint('[AuthService] CRITICAL ERROR in setCurrentUser: $e\n$stack');
    }
  }

  /// Pushes this device's new session to the cloud, revokes every other
  /// active session for this user, and invalidates other Supabase auth
  /// refresh tokens. Called only on fresh OTP/Google sign-ins so that
  /// re-entering the PIN on the same device does not kick other devices.
  ///
  /// Each step is wrapped independently — a network blip on one shouldn't
  /// abort the others. Logs only; the post-login UI must not block on this.
  Future<void> _kickOtherDevices({
    required UserData user,
    required String sessionId,
    required String deviceId,
  }) async {
    final supabase = _supabase;
    final now = DateTime.now().toUtc().toIso8601String();
    final expiresAt = DateTime.now()
        .toUtc()
        .add(const Duration(days: 30))
        .toIso8601String();

    try {
      await supabase.from('sessions').insert({
        'id': sessionId,
        'business_id': user.businessId,
        'user_id': user.id,
        'device_id': deviceId,
        'expires_at': expiresAt,
        'last_updated_at': now,
      });
    } catch (e) {
      debugPrint('[AuthService] kick: cloud session insert error: $e');
    }

    try {
      await supabase
          .from('sessions')
          .update({'revoked_at': now, 'last_updated_at': now})
          .eq('user_id', user.id)
          .neq('device_id', deviceId)
          .filter('revoked_at', 'is', null);
    } catch (e) {
      debugPrint('[AuthService] kick: revoke other sessions error: $e');
    }

    try {
      await supabase.auth.signOut(scope: SignOutScope.others);
    } catch (e) {
      debugPrint('[AuthService] kick: signOut(others) error: $e');
    }
  }

  /// Re-entry guard for the remote-kick path so the snackbar flag isn't
  /// flipped twice when a Realtime event races the resume safety-net check.
  bool _handlingRemoteKick = false;

  /// One-shot flag: set to true when this device was kicked by a remote
  /// sign-in. Consumed by [EmailEntryScreen] to show a snackbar, then reset.
  bool kickedByRemoteSignIn = false;

  /// Called by SyncService when our session row's revoked_at flips, or by
  /// [verifyLocalSessionStillActive] when the local row is missing/expired.
  Future<void> _handleRemoteKick() async {
    if (_handlingRemoteKick) return;
    _handlingRemoteKick = true;
    try {
      kickedByRemoteSignIn = true;
      await fullLogout();
    } finally {
      _handlingRemoteKick = false;
    }
  }

  /// Safety net for devices that were offline when the kick happened, or
  /// for any other reason missed the realtime UPDATE. Triggers fullLogout
  /// if the local session row is no longer active.
  Future<void> verifyLocalSessionStillActive() async {
    final sid = currentSessionId;
    if (value == null || sid == null) return;
    try {
      final active = await _db.sessionsDao.findActiveSession(sid);
      if (active == null) {
        await _handleRemoteKick();
      }
    } catch (e) {
      debugPrint('[AuthService] verifyLocalSessionStillActive error: $e');
    }
  }

  /// Single entry point for all initialization/notification logic for new/unassigned staff.
  Future<void> _handleOnboardingAlerts(UserData user) async {
    try {
      final now = DateTime.now();
      UserData currentUser = user;

      final joinDate = currentUser.createdAt;
      final hoursSinceJoin = now.difference(joinDate).inHours;
      final deadline = joinDate.add(const Duration(hours: 48));
      final deadlineStr =
          '${deadline.hour.toString().padLeft(2, '0')}:${deadline.minute.toString().padLeft(2, '0')} on ${deadline.day}/${deadline.month}';

      // 2. Initial notification to CEO
      if (currentUser.lastNotificationSentAt == null) {
        await _db.notificationsDao.create(
          'warning',
          'Assignment Required: ${currentUser.name} has joined. Please assign a warehouse before the 48h deadline ($deadlineStr).',
          linkedRecordId: currentUser.id.toString(),
        );

        // Bump must reach the cloud so a second device doesn't re-fire
        // the same warning. Companion carries the id so enqueueUpsert
        // can coalesce on (action_type, payload.id).
        final notifBump = UsersCompanion(
          id: Value(currentUser.id),
          lastNotificationSentAt: Value(now),
        );
        await (_db.update(_db.users)..where((u) => u.id.equals(currentUser.id)))
            .write(notifBump);
        await _db.syncDao.enqueueUpsert('users', notifBump);
      }

      // 3. Escalation notification (if 48h passed)
      if (hoursSinceJoin >= 48) {
        final lastSent = currentUser.lastNotificationSentAt;
        if (lastSent != null && now.difference(lastSent).inHours >= 24) {
          await _db.notificationsDao.create(
            'danger',
            'URGENT: 48h Countdown expired for ${currentUser.name} (Deadline: $deadlineStr). Warehouse assignment remains pending.',
            linkedRecordId: currentUser.id.toString(),
          );

          final escalationBump = UsersCompanion(
            id: Value(currentUser.id),
            lastNotificationSentAt: Value(now),
          );
          await (_db.update(_db.users)
                ..where((u) => u.id.equals(currentUser.id)))
              .write(escalationBump);
          await _db.syncDao.enqueueUpsert('users', escalationBump);
        }
      }

      // Refresh final state once after all updates (if any)
      final finalUser = await (_db.select(
        _db.users,
      )..where((u) => u.id.equals(currentUser.id))).getSingle();
      if (finalUser != value) {
        value = finalUser;
      }
    } catch (e, stack) {
      debugPrint('[AuthService] Error in onboarding alerts: $e\n$stack');
    }
  }

  /// If true, the LoginScreen will skip automatically prompting for Biometrics
  /// so that users who explicitly pressed "Log Out" aren't immediately logged back in.
  bool bypassNextBiometric = false;

  /// Clears the active user, removes the warehouse lock, but retains the
  /// device-level session so the next launch shows the personalized PIN screen.
  ///
  /// The Supabase refresh token for THIS device is revoked
  /// ([SignOutScope.local]) so the on-device JWT cannot be silently
  /// re-issued after logout. The user's tokens on other devices stay alive —
  /// use [fullLogout] for an account-wide sign-out.
  void logout() {
    final sid = currentSessionId;
    if (sid != null) {
      scheduleMicrotask(() async {
        try {
          await _db.sessionsDao.revokeSession(sid);
        } catch (e) {
          debugPrint('[AuthService] revokeSession error: $e');
        }
      });
      currentSessionId = null;
    }
    // Clear nav state BEFORE nulling value. lockedWarehouseId listeners
    // (e.g. PosController._subscribeToProducts) fire synchronously; if
    // value is already null, requireBusinessId throws.
    _nav.clearWarehouseLock();
    _nav.resetNavigation();
    _supabase.auth
        .signOut(scope: SignOutScope.local)
        .catchError(
          (e) => debugPrint('[AuthService] Supabase signOut(local) error: $e'),
        );
    value = null;
    bypassNextBiometric = true;
  }

  /// UI-only lock: drops the in-memory user so the PIN screen takes over,
  /// but does NOT revoke the sessions row or sign out of Supabase. The
  /// same device session continues across the lock — keeps RLS happy and
  /// avoids verifyLocalSessionStillActive treating us as a remote kick
  /// on the next resume (it early-returns when value == null).
  void lockApp() {
    // See logout() — same ordering rule.
    _nav.clearWarehouseLock();
    _nav.resetNavigation();
    value = null;
    bypassNextBiometric = true;
  }

  /// Completely wipes the session, reverting the device to a fresh state.
  /// Next launch will demand Email + OTP.
  Future<void> fullLogout() async {
    // 1. Wipe all encrypted auth data so the notifier fires and _hasDeviceUser
    //    becomes false before the ValueListenableBuilder rebuilds.
    await _secure.clearAll();
    deviceUserIdNotifier.value = null;

    // 2. Revoke THIS device's Supabase refresh token (fire-and-forget —
    //    network failures should not prevent local logout). Scoped local
    //    so the user's tokens on other devices stay alive; a deliberate
    //    "Sign out of all devices" CTA can pass SignOutScope.global later.
    _supabase.auth
        .signOut(scope: SignOutScope.local)
        .catchError(
          (e) => debugPrint('[AuthService] Supabase signOut error: $e'),
        );

    // 3. Sign out of Google if applicable (fire-and-forget).
    try {
      await GoogleSignIn().signOut();
    } catch (e) {
      debugPrint('[AuthService] Google signOut error: $e');
    }

    // 4. Clear local state — triggers the ValueListenableBuilder to rebuild.
    //    At this point _hasDeviceUser is already false → routes to EmailEntryScreen.
    //    Order matters: clear nav first so warehouse-listeners fire while
    //    the businessId resolver still returns a valid id (see logout()).
    _nav.clearWarehouseLock();
    _nav.resetNavigation();
    value = null;
  }

  /// Returns true if [pin] matches at least one local user. The lone
  /// owner is the only user post-staff-removal, so this collapses to a
  /// simple PIN-belongs-to-anyone check. Callers that historically passed
  /// a `minimumTier` argument can drop it.
  Future<bool> verifyPinForTier(String pin, int minimumTier) async {
    final matches = await getUsersByPin(pin);
    return matches.isNotEmpty;
  }

  /// Creates a new owner (CEO) account. Online-first: Supabase is the source
  /// of truth during onboarding; Drift mirrors after the Supabase write returns.
  ///
  /// If an incomplete onboarding row already exists for this auth user
  /// (interrupted previous attempt), reuses its businessId so the user
  /// resumes with the same id end-to-end — no local/server divergence.
  ///
  /// Throws on network failure rather than seeding partial local state.
  Future<UserData> createNewOwner(String email, String name) async {
    final supabase = _supabase;
    final authUserId = supabase.auth.currentUser?.id;
    if (authUserId == null) {
      throw StateError(
        'createNewOwner called without an authenticated Supabase session',
      );
    }

    // 1. Resume detection. The tenant_select policy on businesses lets the
    //    user see their own row once a profile exists, which it does for
    //    any prior attempt that got past start_onboarding.
    final existingRow = await supabase
        .from('businesses')
        .select('id')
        .eq('owner_id', authUserId)
        .eq('onboarding_complete', false)
        .maybeSingle();

    final String businessId;
    if (existingRow != null) {
      businessId = existingRow['id'] as String;
      // Update the placeholder name with whatever they typed this time.
      await supabase
          .from('businesses')
          .update({'name': name})
          .eq('id', businessId);
    } else {
      businessId = UuidV7.generate();
      // Atomic businesses + profiles insert via SECURITY DEFINER RPC.
      // Avoids a partial-state crash window between two separate inserts
      // (business visible, profile missing → public.business_id() returns
      // null, blocking subsequent tenant inserts).
      await supabase.rpc(
        'start_onboarding',
        params: {'p_business_id': businessId, 'p_name': name},
      );
    }

    // 2. Mirror to Drift. BusinessTypeSelectionScreen._onRegister already
    //    called clearAllData() before pushing into onboarding, so the local
    //    DB starts empty. The user-by-email delete here only matters when
    //    createNewOwner runs twice in the same session (e.g. user backed
    //    out of NewOwnerNameScreen and re-submitted with a different name).
    final userId = UuidV7.generate();
    final now = DateTime.now();
    await _db.transaction(() async {
      await (_db.delete(_db.users)..where((u) => u.email.equals(email))).go();

      await _db
          .into(_db.businesses)
          .insertOnConflictUpdate(
            BusinessesCompanion.insert(
              id: Value(businessId),
              name: name,
              onboardingComplete: const Value(false),
              lastUpdatedAt: Value(now),
            ),
          );
      final userComp = UsersCompanion.insert(
        id: Value(userId),
        businessId: businessId,
        name: name,
        email: Value(email),
        pin: setupRequiredPin,
        lastUpdatedAt: Value(now),
      );
      await _db.into(_db.users).insert(userComp);
      await _db.syncDao.enqueueUpsert('users', userComp);
    });

    return (_db.select(
      _db.users,
    )..where((u) => u.id.equals(userId))).getSingle();
  }

  /// Atomic onboarding commit. Calls the `complete_onboarding` Postgres RPC
  /// (migration 0018) which inserts businesses + profiles + warehouses +
  /// settings in one server-side transaction with `onboarding_complete=true`,
  /// then mirrors the same rows into local Drift in one client-side
  /// transaction. PIN is NOT part of this — it's device-local and written
  /// separately by [setUserPin] after this returns.
  ///
  /// Local-mirror best-effort: if the Drift transaction fails (rare —
  /// disk full, schema mismatch), the cloud is authoritative. We hydrate
  /// from there via [upsertLocalUserFromProfile] + [SupabaseSyncService.pullChanges]
  /// — the same recovery path returning-user OTP uses.
  ///
  /// Throws on RPC failure (network drop, validation rejection, ownership
  /// mismatch). The caller should keep the draft in memory so the user can
  /// retry without re-typing.
  Future<UserData> completeOnboarding(OnboardingDraft draft) async {
    if (_supabase.auth.currentUser == null) {
      throw StateError(
        'completeOnboarding called without an authenticated Supabase session',
      );
    }

    // 1. Atomic cloud commit. Idempotent on (businesses.id, warehouses.id,
    //    profiles.id, settings(business_id, key)) so a retry after a
    //    transient network failure converges.
    debugPrint(
      '[AuthService] completeOnboarding: calling cloud RPC '
      'complete_onboarding(businessId=${draft.businessId}, '
      'warehouseId=${draft.warehouseId}, userId=${draft.userId})',
    );
    try {
      // p_user_id (migration 0041) makes the cloud's users.id agree with
      // the local Drift mirror's id. The membership table is gone with
      // staff management removed; cloud no longer mints/insertsa
      // business_members row.
      await _supabase.rpc(
        'complete_onboarding',
        params: {
          'p_business_id': draft.businessId,
          'p_warehouse_id': draft.warehouseId,
          'p_owner_name': draft.ownerName,
          'p_business_name': draft.businessName,
          'p_business_type': draft.businessType,
          'p_business_phone': draft.businessPhone,
          'p_business_email': draft.businessEmail,
          'p_location': {
            'name': draft.locationName,
            'street': draft.streetAddress,
            'city': draft.cityState,
            'country': draft.country,
          },
          'p_settings': {
            'currency': draft.currency,
            'timezone': draft.timezone,
            'tax_reg_number': draft.taxRegNumber,
          },
          'p_user_id': draft.userId,
        },
      );
      debugPrint('[AuthService] completeOnboarding: cloud RPC ok');
    } catch (e, stack) {
      // Surface the exact RPC failure (code/message/details for
      // PostgrestException) before propagating to the caller. The catch
      // upstream in create_pin_screen converts every exception into a
      // generic "Failed to save PIN" — this log is the only way to see
      // the real reason.
      debugPrint(
        '[AuthService] completeOnboarding: cloud RPC FAILED: '
        '${e.runtimeType}: $e\n$stack',
      );
      rethrow;
    }

    final now = DateTime.now();

    // 2. Best-effort local mirror in one Drift transaction. Direct table
    //    inserts (not enqueueUpsert) because AuthService.value is still null
    //    here — the resolver returns null, so any DAO that calls
    //    requireBusinessId() would throw. Payloads carry businessId
    //    explicitly so cross-tenant safety is enforced by the values, not
    //    by the resolver.
    try {
      await _db.transaction(() async {
        await (_db.delete(_db.users)
              ..where((u) => u.email.equals(draft.email)))
            .go();

        await _db
            .into(_db.businesses)
            .insertOnConflictUpdate(
              BusinessesCompanion.insert(
                id: Value(draft.businessId),
                name: draft.businessName ?? '',
                type: Value(draft.businessType),
                phone: Value(draft.businessPhone),
                email: Value(draft.businessEmail),
                onboardingComplete: const Value(true),
                lastUpdatedAt: Value(now),
              ),
            );

        await _db
            .into(_db.warehouses)
            .insertOnConflictUpdate(
              WarehousesCompanion.insert(
                id: Value(draft.warehouseId),
                businessId: draft.businessId,
                name: draft.locationName ?? 'Main Warehouse',
                location: Value(draft.locationCombined),
                lastUpdatedAt: Value(now),
              ),
            );

        await _db.into(_db.users).insert(
              UsersCompanion.insert(
                id: Value(draft.userId),
                businessId: draft.businessId,
                name: draft.ownerName ?? '',
                email: Value(draft.email),
                pin: setupRequiredPin,
                warehouseId: Value(draft.warehouseId),
                lastUpdatedAt: Value(now),
              ),
            );

        // Settings rows intentionally NOT mirrored locally here.
        //
        // The cloud `complete_onboarding` RPC inserted default_currency,
        // timezone, and (optionally) tax_registration_number cloud-side
        // with server-generated ids. The post-onboarding sync pull
        // populates them locally with those same cloud ids.
        //
        // Mirroring them client-side here would mint a fresh local id
        // and collide with the cloud's row on the UNIQUE(business_id,
        // key) constraint when the pull tried to insert — the PK-keyed
        // ON CONFLICT in `_restoreTableData` doesn't recognise the
        // local-only id. That conflict (SqliteException 2067) is the
        // settings half of Bug B. The settings restore path in
        // SupabaseSyncService now also upserts by (business_id, key)
        // so even if a divergent row sneaks in via some other path,
        // the next pull reconciles cleanly.
        //
        // Brief window between RPC return and pull completion where
        // local settings are absent — UI defaults (currency 'NGN',
        // timezone 'Africa/Lagos') cover that.
      });

      return (_db.select(_db.users)
            ..where((u) => u.id.equals(draft.userId)))
          .getSingle();
    } catch (e, stack) {
      // 3. Mirror failed. Cloud has the truth. Hydrate from there —
      //    upsertLocalUserFromProfile + pullChanges both go through the
      //    §5-exempt _restoreTableData path, so they're safe to call with
      //    a null AuthService.value.
      debugPrint(
        '[AuthService] completeOnboarding local mirror failed; '
        'falling back to cloud hydrate: $e\n$stack',
      );
      final hydrated = await upsertLocalUserFromProfile();
      if (hydrated == null) {
        throw StateError(
          'completeOnboarding: cloud commit succeeded but local hydrate '
          'returned no user. Original mirror error: $e',
        );
      }
      await _sync.pullChanges(draft.businessId);
      return hydrated;
    }
  }

  // ── Initialisation ──────────────────────────────────────────────────────
  Future<void> init() async {}

  // ── Google Sign-In (via Supabase OAuth) ──────────────────────────────────

  /// Authenticates with Google via Supabase OAuth redirect flow.
  /// Opens a browser for Google login, then redirects back to the app.
  /// Returns the user's email on success, or null if cancelled / failed.
  Future<String?> signInWithGoogle() async {
    try {
      final supabase = _supabase;

      // Start the OAuth flow — opens the browser.
      final success = await supabase.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: 'reebaplus://login-callback',
        authScreenLaunchMode: LaunchMode.externalApplication,
      );

      if (!success) {
        debugPrint('[AuthService] Google OAuth launch failed');
        return null;
      }

      // Wait for the auth state to change (user redirected back).
      final completer = Completer<String?>();
      late final StreamSubscription<AuthState> sub;

      sub = supabase.auth.onAuthStateChange.listen(
        (data) {
          if (data.event == AuthChangeEvent.signedIn) {
            final email = data.session?.user.email;
            sub.cancel();
            completer.complete(email?.toLowerCase());
          }
        },
        // Offline / DNS errors during refresh surface here; swallow so the
        // OAuth flow keeps waiting for the real signedIn event instead of
        // crashing on an uncaught stream error.
        onError: (e) =>
            debugPrint('[AuthService] onAuthStateChange error during OAuth: $e'),
      );

      // Timeout after 2 minutes if the user doesn't complete the flow.
      final email = await completer.future.timeout(
        const Duration(minutes: 2),
        onTimeout: () {
          sub.cancel();
          return null;
        },
      );

      if (email != null) {
        debugPrint('[AuthService] Google + Supabase sign-in success: $email');
      }
      return email;
    } catch (e) {
      debugPrint('[AuthService] Google Sign-In error: $e');
      return null;
    }
  }

  // ── Stubs kept for backward compatibility ───────────────────────────────
  Future<String?> signUpWithEmail({
    required String name,
    required String email,
    required String password,
  }) async => null;
  Future<String?> signInWithEmail({
    required String email,
    required String password,
  }) async => null;
  Future<bool> userExists(String email) async => false;
  Future<void> setPin(String pin) async {}
  Future<void> setBiometric(bool enabled) async {}
  Future<bool> hasQuickAccess() async => false;
  Future<UserData?> getQuickAccessUser() async => value;
  Future<void> enableQuickAccess() async {}
  Future<void> disableQuickAccess() async {}
  Future<bool> verifySupervisorPin(String userId, String pin) async => false;

  // Invite lifecycle moved to lib/features/invite/services/invite_api_service.dart
  // (cloud-first, server-validated). Callers go through inviteApiServiceProvider
  // directly; this service no longer exposes invite CRUD.
}

/// Snapshot of the current auth user's cloud profile + linked business,
/// used by the OTP flow to confirm an existing account on a fresh device.
class SupabaseAccountInfo {
  final String businessId;
  final String businessName;

  const SupabaseAccountInfo({
    required this.businessId,
    required this.businessName,
  });
}
