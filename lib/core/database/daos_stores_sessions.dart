part of 'daos.dart';

@DriftAccessor(tables: [Users, Stores])
class StoresDao extends DatabaseAccessor<AppDatabase>
    with _$StoresDaoMixin, BusinessScopedDao<AppDatabase> {
  StoresDao(super.db);

  /// Active (non-deleted) stores for the current business, ordered by name.
  /// Drives store pickers and the Stores screen.
  Stream<List<StoreData>> watchActiveStores() {
    return (select(stores)
          ..where((t) => whereBusiness(t) & t.isDeleted.not())
          ..orderBy([(t) => OrderingTerm(expression: t.name)]))
        .watch();
  }

  /// One-shot business-scoped variant of [watchActiveStores]. Use this for
  /// store pickers that read once (initState / load) so a device holding more
  /// than one business's data can't surface — and FK-reference — another
  /// business's store.
  Future<List<StoreData>> getActiveStores() {
    return (select(stores)
          ..where((t) => whereBusiness(t) & t.isDeleted.not())
          ..orderBy([(t) => OrderingTerm(expression: t.name)]))
        .get();
  }

  Stream<StoreData?> watchStore(String id) {
    return (select(
      stores,
    )..where((t) => t.id.equals(id) & whereBusiness(t))).watchSingleOrNull();
  }

  Future<StoreData?> getStore(String id) {
    return (select(
      stores,
    )..where((t) => t.id.equals(id) & whereBusiness(t))).getSingleOrNull();
  }

  /// Edit an existing store's name / address (§10.1 Stores). Business-scoped
  /// (a device can hold more than one business's stores) and routed through
  /// the sync queue so the change reaches the cloud + other devices. `stores`
  /// is a synced tenant table, so this is the only correct write path.
  /// An empty [location] clears the stored address (nullable column).
  Future<void> updateStore({
    required String id,
    String? name,
    String? location,
  }) async {
    await (update(
      stores,
    )..where((t) => t.id.equals(id) & whereBusiness(t))).write(
      StoresCompanion(
        name: name == null ? const Value.absent() : Value(name),
        location: location == null
            ? const Value.absent()
            : Value(location.isEmpty ? null : location),
        lastUpdatedAt: Value(DateTime.now()),
      ),
    );
    final row = await (select(
      stores,
    )..where((t) => t.id.equals(id))).getSingle();
    await db.syncDao.enqueueUpsert('stores', row);
  }

  /// Edit a user's own display name / avatar colour (profile, §10.1-adjacent).
  /// Routed through the sync queue so the change reaches the cloud + other
  /// devices (name is in the `users` push whitelist). Not business-scoped —
  /// the caller passes their own user id.
  Future<void> updateUserProfile({
    required String id,
    String? name,
    String? avatarColor,
  }) async {
    await (update(users)..where((t) => t.id.equals(id))).write(
      UsersCompanion(
        name: name == null ? const Value.absent() : Value(name),
        avatarColor: avatarColor == null
            ? const Value.absent()
            : Value(avatarColor),
        lastUpdatedAt: Value(DateTime.now()),
      ),
    );
    final row = await (select(
      users,
    )..where((t) => t.id.equals(id))).getSingle();
    await db.syncDao.enqueueUpsert('users', row);
  }

  Future<UserData?> getUserById(String id) {
    // deliberately not businessId-scoped
    return (select(users)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  Future<UserData?> getUserByEmail(
    String email, {
    String? preferredBusinessId,
  }) async {
    // Deliberately NOT businessId-scoped — login happens before a session
    // exists. Users has UNIQUE(business_id, email), so a single email can hold
    // one local row PER business (multi-business account / staff re-invite).
    // Tolerate >1 row instead of crashing (getSingleOrNull throws on multi-row,
    // which would kill the sign-in / upsertLocalUserFromProfile rebuild): prefer
    // the row for the active/cloud business, else the most-recently-updated.
    final rows = await (select(
      users,
    )..where((t) => t.email.equals(email))).get();
    if (rows.isEmpty) return null;
    if (rows.length == 1) return rows.first;
    if (preferredBusinessId != null) {
      for (final r in rows) {
        if (r.businessId == preferredBusinessId) return r;
      }
    }
    rows.sort((a, b) => b.lastUpdatedAt.compareTo(a.lastUpdatedAt));
    return rows.first;
  }

  /// Users belonging to the CURRENT business — business-scoped read for the
  /// Home staff-sales name lookup. The device can hold more than one business's
  /// users, so this must never be a bare `select(users)` (business-scoping
  /// invariant — CLAUDE.md). Runs post-login, so the session resolver is bound.
  Future<List<UserData>> getUsersForCurrentBusiness() {
    return (select(users)..where((t) => whereBusiness(t))).get();
  }
}

@DriftAccessor(tables: [Sessions])
class SessionsDao extends DatabaseAccessor<AppDatabase>
    with _$SessionsDaoMixin, BusinessScopedDao<AppDatabase> {
  SessionsDao(super.db);

  Future<String> createSession({
    required String userId,
    required Duration ttl,
    String? userAgent,
    String? ipAddress,
    String? deviceId,
  }) async {
    final businessId = requireBusinessId();
    final now = DateTime.now();

    // Reuse the existing active session for this device+user instead of minting
    // a fresh row on every re-auth (biometric unlock, PIN re-entry, Switch
    // User, app resume). Each `sessions` row is an idempotent, low-value
    // single-active-session record that must still sync; on a device that
    // re-auths while offline, minting a new id each time produces a *separate*
    // outbox row per login (different payload.id → enqueueUpsert can't coalesce
    // them), so they pile up in Sync Issues and burn retries for sessions that
    // no longer matter. Reusing the id collapses every re-auth push into the
    // one coalesced pending row for this device+user, and bumping the expiry
    // gives the session a sliding TTL window across active days.
    //
    // A revoked (kicked / logged-out) or expired session is NOT reused — a real
    // re-login after a kick legitimately starts a new session. Without a
    // deviceId we can't identify the device, so fall back to minting.
    if (deviceId != null) {
      final existing =
          await (select(sessions)
                ..where(
                  (t) =>
                      t.userId.equals(userId) &
                      t.deviceId.equals(deviceId) &
                      whereBusiness(t) &
                      t.revokedAt.isNull() &
                      t.expiresAt.isBiggerThanValue(now),
                )
                ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
                ..limit(1))
              .getSingleOrNull();
      if (existing != null) {
        await (update(sessions)..where((t) => t.id.equals(existing.id))).write(
          SessionsCompanion(
            expiresAt: Value(now.add(ttl)),
            lastUpdatedAt: Value(now),
          ),
        );
        // Full-row re-enqueue (same id) so the refreshed expiry reaches the
        // cloud. enqueueUpsert coalesces by (action_type, payload.id), so this
        // collapses into any still-pending push for this row rather than adding
        // another. Mirrors revokeSession's update-then-full-row-enqueue.
        final refreshed =
            await (select(sessions)
                  ..where((t) => t.id.equals(existing.id)))
                .getSingleOrNull();
        if (refreshed != null) {
          await db.syncDao.enqueueUpsert(
            'sessions',
            refreshed.toCompanion(true),
          );
        }
        return existing.id;
      }
    }

    final id = UuidV7.generate();
    // createdAt is set explicitly (not left to the column's SQL default) so the
    // enqueued companion carries it into the cloud push. Otherwise the pushed
    // payload omits created_at and the cloud's NOT NULL constraint rejects the
    // upsert (23502). Same explicit-value rule as the id in synced writes.
    final row = SessionsCompanion.insert(
      id: Value(id),
      businessId: businessId,
      userId: userId,
      expiresAt: now.add(ttl),
      userAgent: Value(userAgent),
      ipAddress: Value(ipAddress),
      deviceId: Value(deviceId),
      createdAt: Value(now),
      lastUpdatedAt: Value(now),
    );
    await into(sessions).insert(row);
    await db.syncDao.enqueueUpsert('sessions', row);
    return id;
  }

  Future<void> revokeSession(String sessionId) async {
    final now = DateTime.now();
    final comp = SessionsCompanion(
      id: Value(sessionId),
      revokedAt: Value(now),
      lastUpdatedAt: Value(now),
    );
    await (update(
      sessions,
    )..where((t) => t.id.equals(sessionId) & whereBusiness(t))).write(comp);
    // Full-row enqueue: a partial sessions upsert omits NOT NULL user_id/expires_at.
    final row =
        await (select(sessions)
              ..where((t) => t.id.equals(sessionId) & whereBusiness(t)))
            .getSingleOrNull();
    if (row != null) {
      await db.syncDao.enqueueUpsert('sessions', row.toCompanion(true));
    }
  }

  Future<void> revokeAllSessionsForUser(String userId) async {
    final now = DateTime.now();
    final active =
        await (select(sessions)..where(
              (t) =>
                  t.userId.equals(userId) &
                  whereBusiness(t) &
                  t.revokedAt.isNull() &
                  t.expiresAt.isBiggerThanValue(now),
            ))
            .get();
    if (active.isEmpty) return;

    await (update(sessions)..where(
          (t) =>
              t.userId.equals(userId) &
              whereBusiness(t) &
              t.revokedAt.isNull() &
              t.expiresAt.isBiggerThanValue(now),
        ))
        .write(
          SessionsCompanion(revokedAt: Value(now), lastUpdatedAt: Value(now)),
        );

    for (final s in active) {
      await db.syncDao.enqueueUpsert(
        'sessions',
        s
            .toCompanion(true)
            .copyWith(revokedAt: Value(now), lastUpdatedAt: Value(now)),
      );
    }
  }

  Future<SessionData?> findActiveSession(String sessionId) async {
    final now = DateTime.now();
    return (select(sessions)
          ..where(
            (t) =>
                t.id.equals(sessionId) &
                whereBusiness(t) &
                t.revokedAt.isNull() &
                t.expiresAt.isBiggerThanValue(now),
          )
          ..limit(1))
        .getSingleOrNull();
  }
}

@DriftAccessor(tables: [UserStores])
class UserStoresDao extends DatabaseAccessor<AppDatabase>
    with _$UserStoresDaoMixin, BusinessScopedDao<AppDatabase> {
  UserStoresDao(super.db);

  Stream<List<UserStoreData>> watchForUser(String userId) {
    return (select(userStores)..where((t) => t.userId.equals(userId))).watch();
  }

  Future<List<UserStoreData>> getForUser(String userId) {
    return (select(userStores)..where((t) => t.userId.equals(userId))).get();
  }

  /// User ids assigned to [storeId] in the current business. Routes the §26.4
  /// stock-keeper adjustment notification to the *affected store's* leadership
  /// (intersected with the Manager audience by the caller). Business-scoped so
  /// it never leaks across businesses held on the same device.
  Future<List<String>> getUserIdsForStore(String storeId) async {
    final rows = await (select(
      userStores,
    )..where((t) => whereBusiness(t) & t.storeId.equals(storeId))).get();
    return rows.map((r) => r.userId).toList();
  }

  /// Assign [userId] to [storeId] in the current business (§9.5 CEO staff
  /// store-assignment editor). Idempotent — if the pair already exists it's a
  /// no-op (also dodges the UNIQUE (user_id, store_id) constraint). Explicit
  /// `id` so the cloud echo can't mint a different one and collide on the
  /// natural key (SqliteException 2067). Synced via enqueueUpsert.
  Future<void> assign(String userId, String storeId) async {
    final existing =
        await (select(userStores)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    t.userId.equals(userId) &
                    t.storeId.equals(storeId),
              )
              ..limit(1))
            .getSingleOrNull();
    if (existing != null) return; // already assigned — nothing to do
    final row = UserStoresCompanion.insert(
      id: Value(UuidV7.generate()),
      businessId: requireBusinessId(),
      userId: userId,
      storeId: storeId,
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(userStores).insert(row);
    await db.syncDao.enqueueUpsert('user_stores', row);
  }

  /// Remove [userId]'s assignment to [storeId] (§9.5). Deletes the row and
  /// enqueues the tombstone — `user_stores` is a junction table, not an
  /// append-only ledger, so hard-delete via `enqueueDelete` is the right path
  /// here (same pattern as RolePermissionsDao.revoke).
  Future<void> unassign(String userId, String storeId) async {
    final existing =
        await (select(userStores)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    t.userId.equals(userId) &
                    t.storeId.equals(storeId),
              )
              ..limit(1))
            .getSingleOrNull();
    if (existing == null) return;
    await (delete(userStores)..where((t) => t.id.equals(existing.id))).go();
    await db.syncDao.enqueueDelete('user_stores', existing.id);
  }
}
