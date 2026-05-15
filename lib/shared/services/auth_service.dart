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

    // Wire single-active-device sign-in: SyncService notifies us when the
    // sessions row matching our currentSessionId has its revoked_at flipped
    // by another device, so we can fullLogout in response.
    _sync.currentSessionIdResolver = () => currentSessionId;
    _sync.onCurrentSessionRevoked = _handleRemoteKick;
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

  /// Set by [InviteLandingScreen] when an invite-link is being processed.
  /// Consumed by [InviteJoinNameScreen] post-OTP via [consumePendingInviteToken],
  /// or expired by the 10-minute TTL below if the user navigates away.
  /// In-memory only — never persisted.
  String? _pendingInviteToken;
  DateTime? _pendingInviteTokenSetAt;
  static const _pendingInviteTokenTtl = Duration(minutes: 10);

  /// Returns the current pending invite token if it's still within the
  /// [_pendingInviteTokenTtl] window. Auto-clears stale tokens on read.
  String? get pendingInviteToken {
    final at = _pendingInviteTokenSetAt;
    if (at == null) return null;
    if (DateTime.now().difference(at) > _pendingInviteTokenTtl) {
      _pendingInviteToken = null;
      _pendingInviteTokenSetAt = null;
      return null;
    }
    return _pendingInviteToken;
  }

  void setPendingInviteToken(String token) {
    _pendingInviteToken = token;
    _pendingInviteTokenSetAt = DateTime.now();
  }

  /// Read-and-clear, used by [InviteJoinNameScreen] before redeeming.
  String? consumePendingInviteToken() {
    final v = pendingInviteToken; // applies TTL check
    _pendingInviteToken = null;
    _pendingInviteTokenSetAt = null;
    return v;
  }

  void _clearPendingInviteToken() {
    _pendingInviteToken = null;
    _pendingInviteTokenSetAt = null;
  }

  /// The currently logged-in user, or null if nobody is logged in.
  UserData? get currentUser => value;

  /// Active membership for [currentUser] in the current business. Loaded
  /// lazily by [_refreshActiveMember] in [setCurrentUser] and cleared on
  /// logout. New screens (verification badge, member list, etc.) read this
  /// instead of [currentUser.roleTier] so the dependency on the legacy
  /// users.role/role_tier columns can be cut cleanly when Phase 5 drops
  /// them. During Phase 1 the values mirror exactly — both columns are
  /// backfilled from the same source — so existing call sites that still
  /// read `currentUser.roleTier` keep working unchanged.
  BusinessMemberData? _activeMember;
  BusinessMemberData? get currentMember => _activeMember;

  Future<void> _refreshActiveMember() async {
    final user = value;
    if (user == null) {
      _activeMember = null;
      return;
    }
    _activeMember = await (_db.select(_db.businessMembers)
          ..where((t) => t.userId.equals(user.id))
          ..limit(1))
        .getSingleOrNull();
  }

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
  /// BOTH the legacy device-local [Users.pin*] columns AND the cloud-synced
  /// [BusinessMembers.pin*] columns for the user's membership.
  ///
  /// Dual-write rationale: per the staff-onboarding plan §2, PIN now syncs
  /// per-membership so the same PIN works on every device for that
  /// membership. Phase 5 drops the legacy users.pin* columns; the dual-
  /// write here ensures every PIN set during the Phase 1→Phase 5 window
  /// also lands on the membership row, so the column drop in Phase 5 does
  /// not silently lose any user's PIN.
  ///
  /// Bypasses BusinessMembersDao.setPin because that method requires the
  /// tenant resolver to be wired (whereBusiness filter), and setUserPin is
  /// sometimes called during onboarding before setCurrentUser runs. Direct
  /// write + explicit enqueue keeps the CLAUDE.md §5 contract.
  Future<void> setUserPin(String userId, String plaintext) async {
    final salt = PinHasher.generateSaltBase64();
    final hash = PinHasher.hashBase64(
      plaintext,
      salt,
      PinHasher.defaultIterations,
    );
    const iterations = PinHasher.defaultIterations;

    // 1. Legacy users.pin* — device-local, never synced.
    await (_db.update(_db.users)..where((u) => u.id.equals(userId))).write(
      UsersCompanion(
        pin: const Value('__HASHED__'),
        pinHash: Value(hash),
        pinSalt: Value(salt),
        pinIterations: const Value(iterations),
      ),
    );

    // 2. business_members.pin_* — canonical going forward, syncs to cloud.
    //    Lookup is by user_id (globally unique in Phase 1 thanks to the
    //    auth_user_id UNIQUE on users). Skip silently if no membership row
    //    exists yet — defensive against a setUserPin call racing the
    //    membership-creation paths (complete_onboarding RPC, accept_invite
    //    RPC, or v5→v6 backfill).
    final member = await (_db.select(_db.businessMembers)
          ..where((t) => t.userId.equals(userId))
          ..limit(1))
        .getSingleOrNull();
    if (member != null) {
      final comp = BusinessMembersCompanion(
        id: Value(member.id),
        pinHash: Value(hash),
        pinSalt: Value(salt),
        pinIterations: const Value(iterations),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await (_db.update(_db.businessMembers)
            ..where((t) => t.id.equals(member.id)))
          .write(comp);
      await _db.syncDao.enqueueUpsert('business_members', comp);
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
          .select('business_id, role, role_tier')
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
        role: profile['role'] as String? ?? 'cashier',
        roleTier: (profile['role_tier'] as num?)?.toInt() ?? 3,
      );
    } catch (e) {
      debugPrint('[AuthService] fetchSupabaseAccount error: $e');
      return null;
    }
  }

  Future<void> syncOnLogin(String businessId) async {
    // Pull-only. syncOnLogin runs at login boundaries (returning user fresh
    // device, invite redeem, etc.) BEFORE setCurrentUser, so
    // AppDatabase.currentBusinessId is still null and the push half of
    // syncAll would either no-op (early-return guard) or throw if any DAO
    // call inside it consulted the resolver. Pending writes are drained by
    // startAutoPush, started inside setCurrentUser once the user/business
    // is fully bound.
    await _sync.pullChanges(businessId);
    _sync.startRealtimeSync(businessId);
  }

  /// Reads the current user's cloud profile (by `auth.uid()`) and reflects it
  /// into the local `users` table. On a fresh device this recreates the row
  /// so the existing PIN-entry / device-session flow can pick up.
  ///
  /// Only profile-owned fields (name, role, roleTier, businessId) are written.
  /// Device-local fields (pin, passwordHash, biometricEnabled, avatarColor,
  /// warehouseId) are never overwritten on existing rows.
  ///
  /// If no local row exists yet, one is inserted with [setupRequiredPin] as a
  /// placeholder so the caller can route to PIN setup.
  Future<UserData?> upsertLocalUserFromProfile() async {
    final authUser = _supabase.auth.currentUser;
    if (authUser == null || authUser.email == null) return null;

    Map<String, dynamic>? profile;
    try {
      profile = await _supabase
          .from('profiles')
          .select('name, role, role_tier, business_id')
          .eq('id', authUser.id)
          .maybeSingle();
    } catch (e) {
      debugPrint('[AuthService] upsertLocalUserFromProfile fetch error: $e');
      return null;
    }
    if (profile == null) return null;

    final name = profile['name'] as String? ?? '';
    final role = profile['role'] as String? ?? 'cashier';
    final roleTier = (profile['role_tier'] as num?)?.toInt() ?? 3;
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
          role: Value(role),
          roleTier: Value(roleTier),
          businessId: Value(businessId),
        ),
      );
      return (_db.select(
        _db.users,
      )..where((u) => u.id.equals(existing.id))).getSingle();
    }

    final newId = UuidV7.generate();
    final now = DateTime.now();
    final newComp = UsersCompanion.insert(
      id: Value(newId),
      name: name,
      email: Value(email),
      pin: setupRequiredPin,
      role: role,
      roleTier: Value(roleTier),
      businessId: businessId,
      lastUpdatedAt: Value(now),
    );
    final inserted = await _db.into(_db.users).insertReturning(newComp);
    await _db.syncDao.enqueueUpsert('users', newComp);
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
      _nav.applyUserWarehouseLock(user.roleTier, user.warehouseId);
      if (user.roleTier >= 4) {
        _nav.setIndex(0);
      } else {
        _nav.setIndex(1);
      }
      saveDeviceUserId(user.id);
      if (user.email != null) saveLastLoggedInEmail(user.email!);

      // Successful sign-in completes any pending invite redemption (or this
      // wasn't an invite path); either way, drop the token.
      _clearPendingInviteToken();

      // Set synchronously so VLB listener fires before any route pop cleans up
      value = user;

      // Load the active membership in the background so [currentMember] is
      // available to new screens. businessIdResolver still reads
      // value?.businessId so this doesn't gate the post-login render.
      scheduleMicrotask(_refreshActiveMember);

      _sync.startRealtimeSync(user.businessId);
      _sync.startAutoPush();

      if (user.roleTier < 5 && user.warehouseId == null) {
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
    value = null;
    _activeMember = null;
    bypassNextBiometric = true;
    _nav.clearWarehouseLock();
    _nav.resetNavigation();
  }

  /// Completely wipes the session, reverting the device to a fresh state.
  /// Next launch will demand Email + OTP.
  ///
  /// [preserveInviteToken] keeps any pending invite token across the logout,
  /// used by [InviteLandingScreen]'s "switch account" path where the user
  /// must sign out an existing session before redeeming the invite they
  /// just landed on. Default false — regular sign-out paths drop the token.
  Future<void> fullLogout({bool preserveInviteToken = false}) async {
    if (!preserveInviteToken) {
      _clearPendingInviteToken();
    }

    // 1. Wipe all encrypted auth data so the notifier fires and _hasDeviceUser
    //    becomes false before the ValueListenableBuilder rebuilds.
    await _secure.clearAll();
    deviceUserIdNotifier.value = null;

    // 2. Terminate all sessions globally via Supabase (fire-and-forget —
    //    network failures should not prevent local logout).
    _supabase.auth
        .signOut(scope: SignOutScope.global)
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
    value = null;
    _activeMember = null;
    _nav.clearWarehouseLock();
    _nav.resetNavigation();
  }

  /// Returns true if [pin] belongs to at least one user whose
  /// `roleTier` is greater than or equal to [minimumTier].
  ///
  /// Used by the PIN confirmation dialog and by refund / crate-return
  /// features that need a manager or CEO to approve.
  ///
  /// Role tiers: 2=Rider, 3=Cashier, 4=Stock Keeper, 5=Manager, 6=CEO
  Future<bool> verifyPinForTier(String pin, int minimumTier) async {
    final matches = await getUsersByPin(pin);
    return matches.any((u) => u.roleTier >= minimumTier);
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
        role: 'ceo',
        roleTier: const Value(6),
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
      },
    );

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
                role: 'ceo',
                roleTier: const Value(6),
                warehouseId: Value(draft.warehouseId),
                lastUpdatedAt: Value(now),
              ),
            );

        await _db.batch((batch) {
          batch.insert(
            _db.settings,
            SettingsCompanion.insert(
              key: 'default_currency',
              value: draft.currency ?? 'NGN',
              businessId: draft.businessId,
              lastUpdatedAt: Value(now),
            ),
            mode: InsertMode.insertOrReplace,
          );
          batch.insert(
            _db.settings,
            SettingsCompanion.insert(
              key: 'timezone',
              value: draft.timezone ?? 'Africa/Lagos',
              businessId: draft.businessId,
              lastUpdatedAt: Value(now),
            ),
            mode: InsertMode.insertOrReplace,
          );
          final tax = draft.taxRegNumber?.trim();
          if (tax != null && tax.isNotEmpty) {
            batch.insert(
              _db.settings,
              SettingsCompanion.insert(
                key: 'tax_registration_number',
                value: tax,
                businessId: draft.businessId,
                lastUpdatedAt: Value(now),
              ),
              mode: InsertMode.insertOrReplace,
            );
          }
        });
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

      sub = supabase.auth.onAuthStateChange.listen((data) {
        if (data.event == AuthChangeEvent.signedIn) {
          final email = data.session?.user.email;
          sub.cancel();
          completer.complete(email?.toLowerCase());
        }
      });

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
  final String role;
  final int roleTier;

  const SupabaseAccountInfo({
    required this.businessId,
    required this.businessName,
    required this.role,
    required this.roleTier,
  });
}
