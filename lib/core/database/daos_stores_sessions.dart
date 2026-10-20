part of 'daos.dart';

const _kManagerViewAllStoresSetting = 'manager_view_all_stores';

/// Reasons why a store deletion is blocked by safety guards (#456).
enum StoreDeleteBlockedReason {
  isOnlyStore,
  hasStock,
  hasStorelessStaff,
  hasOpenTransfers,
  hasPendingAdjustments,
  hasOpenVanTrip,
  hasCrates,
}

extension StoreDeleteBlockedReasonMessage on StoreDeleteBlockedReason {
  String get message {
    switch (this) {
      case StoreDeleteBlockedReason.isOnlyStore:
        return 'Cannot delete the only store in your business. A business must have at least one store.';
      case StoreDeleteBlockedReason.hasStock:
        return 'This store still has stock on hand. Transfer or write off all inventory before deleting.';
      case StoreDeleteBlockedReason.hasStorelessStaff:
        return 'Staff members are assigned only to this store. Reassign them to another store before deleting.';
      case StoreDeleteBlockedReason.hasOpenTransfers:
        return 'This store has open stock transfers (pending or in transit). Complete or cancel them before deleting.';
      case StoreDeleteBlockedReason.hasPendingAdjustments:
        return 'This store has pending stock adjustment requests. Approve or reject them before deleting.';
      case StoreDeleteBlockedReason.hasOpenVanTrip:
        return 'This store has an active van trip currently open. Close the van trip before deleting.';
      case StoreDeleteBlockedReason.hasCrates:
        return 'This store still holds empty crates. Transfer or return all crates before deleting.';
    }
  }
}

class StoreDeleteBlockedException implements Exception {
  final StoreDeleteBlockedReason reason;
  const StoreDeleteBlockedException(this.reason);

  String get message => reason.message;

  @override
  String toString() => message;
}

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

  /// Create a location for the current business (#140, #231). [kind] is the only
  /// thing that separates a warehouse from a van: pass [kStoreKindVan] and the
  /// row drops out of every normal store surface while still holding real
  /// per-SKU inventory (van-sales spec §4.1).
  ///
  /// Atomic first-store write path (#231):
  /// - Writes the store row.
  /// - When an owner/user is provided or bound ([userId] ?? [currentUserId]):
  ///   - Writes the user-to-store binding (`user_stores`).
  ///   - Sets `users.store_id` if currently null or empty.
  /// - Writes an activity log entry (`activity_logs`).
  /// - Enqueues sync queue upserts for all written rows.
  /// All executed inside a single transaction.
  Future<String> createStore({
    required String name,
    String? location,
    String kind = kStoreKindStore,
    String? userId,
  }) async {
    assert(kStoreKinds.contains(kind), 'unknown store kind: $kind');
    final storeId = UuidV7.generate();
    final now = DateTime.now();
    final businessId = requireBusinessId();
    final targetUserId = userId ?? currentUserId;

    await transaction(() async {
      final storeRow = StoresCompanion.insert(
        id: Value(storeId),
        businessId: businessId,
        name: name,
        location: Value(location == null || location.isEmpty ? null : location),
        kind: Value(kind),
        lastUpdatedAt: Value(now),
      );
      await into(stores).insert(storeRow);
      await db.syncDao.enqueueUpsert('stores', storeRow);

      if (targetUserId != null) {
        final user = await (select(users)
              ..where((u) =>
                  u.id.equals(targetUserId) & u.businessId.equals(businessId)))
            .getSingleOrNull();
        if (user != null) {
          final userStoreRow = UserStoresCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            userId: targetUserId,
            storeId: storeId,
            lastUpdatedAt: Value(now),
          );
          await into(db.userStores).insert(userStoreRow);
          await db.syncDao.enqueueUpsert('user_stores', userStoreRow);

          if (user.storeId == null || user.storeId!.isEmpty) {
            final userUpdate = UsersCompanion(
              storeId: Value(storeId),
              lastUpdatedAt: Value(now),
            );
            await (update(users)
                  ..where((u) =>
                      u.id.equals(targetUserId) &
                      u.businessId.equals(businessId)))
                .write(userUpdate);
            final updatedUser = await (select(users)
                  ..where((u) =>
                      u.id.equals(targetUserId) &
                      u.businessId.equals(businessId)))
                .getSingle();
            await db.syncDao.enqueueUpsert('users', updatedUser);
          }
        }
      }

      final activityRow = ActivityLogsCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: businessId,
        userId: Value(targetUserId),
        action: 'store.create',
        description: 'Created store "$name"',
        entityType: const Value('store'),
        entityId: Value(storeId),
        storeId: Value(storeId),
        lastUpdatedAt: Value(now),
      );
      await into(db.activityLogs).insert(activityRow);
      await db.syncDao.enqueueUpsert('activity_logs', activityRow);
    });

    return storeId;
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

  /// Check whether deleting [storeId] is blocked by any safety invariant (#456):
  /// 1. isOnlyStore: Business has <= 1 active stores.
  /// 2. hasStock: Store has remaining inventory quantity > 0.
  /// 3. hasStorelessStaff: Staff member would be left with no other active store.
  /// 4. hasOpenTransfers: Store is part of an open transfer (pending or in_transit).
  /// 5. hasPendingAdjustments: Store has pending stock adjustment requests.
  /// 6. hasOpenVanTrip: Store is linked to an active open van trip.
  /// 7. hasCrates: Store holds empty crates with balance > 0.
  ///
  /// Returns the first [StoreDeleteBlockedReason] found, or null if clear.
  Future<StoreDeleteBlockedReason?> checkStoreDeleteBlocked(
    String storeId,
  ) async {
    final businessId = requireBusinessId();

    // Guard 1: Cannot delete if it is the only active store.
    final activeStores = await getActiveStores();
    if (activeStores.length <= 1) {
      return StoreDeleteBlockedReason.isOnlyStore;
    }

    // Guard 2: Cannot delete if store has inventory with quantity > 0.
    final stockRows =
        await (select(db.inventory)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    t.storeId.equals(storeId) &
                    t.quantity.isBiggerThanValue(0),
              )
              ..limit(1))
            .get();
    if (stockRows.isNotEmpty) {
      return StoreDeleteBlockedReason.hasStock;
    }

    // Guard 3: Block only when a staff member would be left with NO other active store.
    // Staff assigned to several stores, and CEO/"All stores" users, don't block.
    final otherActiveStoreIds = activeStores
        .map((s) => s.id)
        .where((id) => id != storeId)
        .toSet();

    final bizUsers = await (select(
      users,
    )..where((u) => whereBusiness(u))).get();
    for (final u in bizUsers) {
      // Only ACTIVE staff count: a suspended or removed member's leftover
      // store assignments must not block the delete (they can't be reassigned).
      final ub =
          await (select(db.userBusinesses)..where(
                (t) =>
                    t.businessId.equals(businessId) &
                    t.userId.equals(u.id) &
                    t.status.equals('active'),
              ))
              .getSingleOrNull();
      if (ub == null) continue;

      final role = await (select(
        db.roles,
      )..where((r) => r.id.equals(ub.roleId))).getSingleOrNull();
      if (role != null) {
        if (role.slug == 'ceo') continue;
        if (role.slug == 'manager') {
          final setting = await db.roleSettingsDao.getValue(
            role.id,
            _kManagerViewAllStoresSetting,
          );
          if (setting == 'true') continue;
        }
      }

      // Check assigned stores for this user
      final userStoreRows = await (select(
        db.userStores,
      )..where((t) => whereBusiness(t) & t.userId.equals(u.id))).get();
      final assignedStoreIds = userStoreRows.map((r) => r.storeId).toSet();
      if (assignedStoreIds.isEmpty && u.storeId != null) {
        assignedStoreIds.add(u.storeId!);
      }

      if (assignedStoreIds.contains(storeId)) {
        final hasOtherActiveStore = assignedStoreIds.any(
          (id) => otherActiveStoreIds.contains(id),
        );
        if (!hasOtherActiveStore) {
          return StoreDeleteBlockedReason.hasStorelessStaff;
        }
      }
    }

    // Guard 4: Cannot delete if store is part of a pending or in-transit transfer.
    final transferRows =
        await (select(db.stockTransfers)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    (t.fromLocationId.equals(storeId) |
                        t.toLocationId.equals(storeId)) &
                    (t.status.equals('pending') |
                        t.status.equals('in_transit')),
              )
              ..limit(1))
            .get();
    if (transferRows.isNotEmpty) {
      return StoreDeleteBlockedReason.hasOpenTransfers;
    }

    // Guard 5: Cannot delete if store has pending stock adjustment requests.
    final adjustmentRows =
        await (select(db.stockAdjustmentRequests)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    t.storeId.equals(storeId) &
                    t.status.equals('pending'),
              )
              ..limit(1))
            .get();
    if (adjustmentRows.isNotEmpty) {
      return StoreDeleteBlockedReason.hasPendingAdjustments;
    }

    // Guard 6: Cannot delete if store is linked to an open van trip.
    final vanTripRows =
        await (select(db.vanTrips)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    (t.vanStoreId.equals(storeId) |
                        t.sourceStoreId.equals(storeId)) &
                    t.status.equals(kVanTripStatusOpen),
              )
              ..limit(1))
            .get();
    if (vanTripRows.isNotEmpty) {
      return StoreDeleteBlockedReason.hasOpenVanTrip;
    }

    // Guard 7: Cannot delete if store still holds empty crates.
    final crateRows =
        await (select(db.storeCrateBalances)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    t.storeId.equals(storeId) &
                    t.balance.isBiggerThanValue(0),
              )
              ..limit(1))
            .get();
    if (crateRows.isNotEmpty) {
      return StoreDeleteBlockedReason.hasCrates;
    }

    return null;
  }

  /// Soft-delete a store for the current business (#456).
  ///
  /// Business-scoped and transactional:
  /// 1. Re-verifies all 7 safety guards inside the transaction at write time.
  ///    Throws [StoreDeleteBlockedException] if any guard fails.
  /// 2. Updates `stores.is_deleted = true` with bumped `last_updated_at`.
  /// 3. Appends an `activity_logs` entry with action 'store.delete'.
  /// 4. Enqueues upserts to `sync_queue` for both `stores` and `activity_logs`.
  Future<void> softDeleteStore(String storeId) async {
    final businessId = requireBusinessId();
    final now = DateTime.now();
    final targetUserId = currentUserId;

    await transaction(() async {
      final blocker = await checkStoreDeleteBlocked(storeId);
      if (blocker != null) {
        throw StoreDeleteBlockedException(blocker);
      }

      final store =
          await (select(stores)
                ..where((t) => t.id.equals(storeId) & whereBusiness(t)))
              .getSingleOrNull();
      if (store == null) {
        throw StateError('Store $storeId not found.');
      }

      final storeUpdate = StoresCompanion(
        id: Value(storeId),
        isDeleted: const Value(true),
        lastUpdatedAt: Value(now),
      );
      await (update(stores)
            ..where((t) => t.id.equals(storeId) & whereBusiness(t)))
          .write(storeUpdate);

      final updatedStore = await (select(
        stores,
      )..where((t) => t.id.equals(storeId))).getSingle();
      await db.syncDao.enqueueUpsert('stores', updatedStore);

      final activityRow = ActivityLogsCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: businessId,
        userId: Value(targetUserId),
        action: 'store.delete',
        description: 'Deleted store "${store.name}"',
        entityType: const Value('store'),
        entityId: Value(storeId),
        storeId: Value(storeId),
        lastUpdatedAt: Value(now),
      );
      await into(db.activityLogs).insert(activityRow);
      await db.syncDao.enqueueUpsert('activity_logs', activityRow);
    });
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
    // which would kill the sign-in / upsertLocalUserFromProfile rebuild).
    final rows = await (select(
      users,
    )..where((t) => t.email.equals(email))).get();
    if (rows.isEmpty) return null;
    // [preferredBusinessId] is the business the CLOUD named for this sign-in,
    // so it is a filter, not a tiebreaker: a row from any other business
    // belongs to a tenant this login has left behind, and binding it logs the
    // user into the wrong business (#285 — the row count is irrelevant, the
    // single-row shortcut used to skip this check and return the stale row).
    if (preferredBusinessId != null) {
      for (final r in rows) {
        if (r.businessId == preferredBusinessId) return r;
      }
      return null;
    }
    if (rows.length == 1) return rows.first;
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
