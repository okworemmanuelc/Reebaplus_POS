part of 'daos.dart';

@DriftAccessor(tables: [Permissions])
class PermissionsDao extends DatabaseAccessor<AppDatabase>
    with _$PermissionsDaoMixin {
  PermissionsDao(super.db);

  Future<List<PermissionData>> getAll() {
    return (select(permissions)..orderBy([
          (t) => OrderingTerm.asc(t.category),
          (t) => OrderingTerm.asc(t.key),
        ]))
        .get();
  }

  Stream<List<PermissionData>> watchAll() {
    return (select(permissions)..orderBy([
          (t) => OrderingTerm.asc(t.category),
          (t) => OrderingTerm.asc(t.key),
        ]))
        .watch();
  }

  Future<PermissionData?> getByKey(String key) {
    return (select(
      permissions,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
  }
}

@DriftAccessor(tables: [Roles])
class RolesDao extends DatabaseAccessor<AppDatabase>
    with _$RolesDaoMixin, BusinessScopedDao<AppDatabase> {
  RolesDao(super.db);

  /// All non-deleted roles for the current business, ordered for
  /// display: system defaults first (CEO → Manager → Cashier →
  /// Stock keeper), then any Phase 2 custom roles.
  Stream<List<RoleData>> watchAll() {
    return (select(roles)
          ..where((t) => whereBusiness(t) & t.isDeleted.not())
          ..orderBy([
            (t) => OrderingTerm.desc(t.isSystemDefault),
            (t) => OrderingTerm.asc(t.name),
          ]))
        .watch();
  }

  Future<List<RoleData>> getAll() {
    return (select(roles)
          ..where((t) => whereBusiness(t) & t.isDeleted.not())
          ..orderBy([
            (t) => OrderingTerm.desc(t.isSystemDefault),
            (t) => OrderingTerm.asc(t.name),
          ]))
        .get();
  }

  /// All non-deleted roles across every business on this device, NOT scoped
  /// to the current session. Role ids are globally unique, so the role-badge
  /// resolver (see `userRoleProvider`) can look up a role by id even before
  /// login binds a business — the Who Is Working / shared-PIN picker shows
  /// each candidate's role before `setCurrentUser` runs.
  Stream<List<RoleData>> watchAllUnscoped() {
    return (select(roles)..where((t) => t.isDeleted.not())).watch();
  }

  /// Lookup by slug — the stable machine identifier (`ceo`, `manager`,
  /// `cashier`, `stock_keeper`). Code that branches on role identity
  /// uses this, not `name`.
  Future<RoleData?> getBySlug(String slug) {
    return (select(roles)
          ..where((t) => whereBusiness(t) & t.slug.equals(slug))
          ..limit(1))
        .getSingleOrNull();
  }

  /// Insert a role. Used by tests and (future) Phase 2 custom-role UI.
  /// The four system defaults are seeded server-side by
  /// `complete_onboarding` and arrive locally via sync pull.
  Future<void> insertRole(RolesCompanion row) async {
    await into(roles).insert(row);
    await db.syncDao.enqueueUpsert('roles', row);
  }
}

@DriftAccessor(tables: [RolePermissions])
class RolePermissionsDao extends DatabaseAccessor<AppDatabase>
    with _$RolePermissionsDaoMixin, BusinessScopedDao<AppDatabase> {
  RolePermissionsDao(super.db);

  Stream<List<RolePermissionData>> watchForRole(String roleId) {
    return (select(rolePermissions)
          ..where((t) => whereBusiness(t) & t.roleId.equals(roleId))
          ..orderBy([(t) => OrderingTerm.asc(t.permissionKey)]))
        .watch();
  }

  Future<List<RolePermissionData>> getForRole(String roleId) {
    return (select(rolePermissions)
          ..where((t) => whereBusiness(t) & t.roleId.equals(roleId))
          ..orderBy([(t) => OrderingTerm.asc(t.permissionKey)]))
        .get();
  }

  /// Count of granted permissions for a role. Used by the verification
  /// test and by CEO Settings to show "N of M permissions granted".
  Future<int> countForRole(String roleId) async {
    final row =
        await (selectOnly(rolePermissions)
              ..addColumns([rolePermissions.id.count()])
              ..where(
                whereBusiness(rolePermissions) &
                    rolePermissions.roleId.equals(roleId),
              ))
            .getSingle();
    return row.read(rolePermissions.id.count()) ?? 0;
  }

  /// Grant a permission to a role. Idempotent on the logical identity
  /// (role_id, permission_key): if the pair is already granted, this is a
  /// no-op. A blind `insert` with a fresh UUID would trip
  /// UNIQUE(role_id, permission_key) (SqliteException 2067) whenever a row for
  /// the pair already exists — e.g. a stale toggle, or a row that arrived from
  /// the cloud since the UI last built.
  Future<void> grant(String roleId, String permissionKey) async {
    final existing =
        await (select(rolePermissions)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    t.roleId.equals(roleId) &
                    t.permissionKey.equals(permissionKey),
              )
              ..limit(1))
            .getSingleOrNull();
    if (existing != null) return; // already granted — nothing to do
    final row = RolePermissionsCompanion.insert(
      id: Value(UuidV7.generate()),
      businessId: requireBusinessId(),
      roleId: roleId,
      permissionKey: permissionKey,
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(rolePermissions).insert(row);
    await db.syncDao.enqueueUpsert('role_permissions', row);
  }

  /// Revoke a permission. Deletes the row and enqueues the
  /// tombstone — `role_permissions` is not an append-only ledger, so
  /// hard-delete via `enqueueDelete` is the right path here.
  Future<void> revoke(String roleId, String permissionKey) async {
    final existing =
        await (select(rolePermissions)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    t.roleId.equals(roleId) &
                    t.permissionKey.equals(permissionKey),
              )
              ..limit(1))
            .getSingleOrNull();
    if (existing == null) return;
    await (delete(
      rolePermissions,
    )..where((t) => t.id.equals(existing.id))).go();
    await db.syncDao.enqueueDelete('role_permissions', existing.id);
  }
}

@DriftAccessor(tables: [UserPermissionOverrides])
class UserPermissionOverridesDao extends DatabaseAccessor<AppDatabase>
    with _$UserPermissionOverridesDaoMixin, BusinessScopedDao<AppDatabase> {
  UserPermissionOverridesDao(super.db);

  Stream<List<UserPermissionOverrideData>> watchForUser(String userId) {
    return (select(userPermissionOverrides)
          ..where((t) => whereBusiness(t) & t.userId.equals(userId))
          ..orderBy([(t) => OrderingTerm.asc(t.permissionKey)]))
        .watch();
  }

  Future<List<UserPermissionOverrideData>> getForUser(String userId) {
    return (select(userPermissionOverrides)
          ..where((t) => whereBusiness(t) & t.userId.equals(userId))
          ..orderBy([(t) => OrderingTerm.asc(t.permissionKey)]))
        .get();
  }

  /// Set or clear a staff member's override for [permissionKey] (§10.2.1).
  /// [value] true = force-grant, false = force-revoke, null = clear the
  /// override (inherit the role default). Idempotent on the logical identity
  /// (business_id, user_id, permission_key): a value that already matches is a
  /// no-op, so we never trip UNIQUE on a stale toggle or a row that arrived
  /// from the cloud since the UI last built.
  Future<void> setOverride(
    String userId,
    String permissionKey,
    bool? value,
  ) async {
    final existing =
        await (select(userPermissionOverrides)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    t.userId.equals(userId) &
                    t.permissionKey.equals(permissionKey),
              )
              ..limit(1))
            .getSingleOrNull();

    if (value == null) {
      // Inherit — remove the override row and tombstone it cloud-side.
      // `user_permission_overrides` is not an append-only ledger, so
      // hard-delete via `enqueueDelete` is the right path here.
      if (existing == null) return;
      await (delete(
        userPermissionOverrides,
      )..where((t) => t.id.equals(existing.id))).go();
      await db.syncDao.enqueueDelete('user_permission_overrides', existing.id);
      return;
    }

    if (existing != null) {
      if (existing.isGranted == value) return; // already at this value
      final row = UserPermissionOverridesCompanion(
        id: Value(existing.id),
        businessId: Value(existing.businessId),
        userId: Value(existing.userId),
        permissionKey: Value(existing.permissionKey),
        isGranted: Value(value),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await (update(
        userPermissionOverrides,
      )..where((t) => t.id.equals(existing.id))).write(row);
      await db.syncDao.enqueueUpsert('user_permission_overrides', row);
      return;
    }

    final row = UserPermissionOverridesCompanion.insert(
      id: Value(UuidV7.generate()),
      businessId: requireBusinessId(),
      userId: userId,
      permissionKey: permissionKey,
      isGranted: value,
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(userPermissionOverrides).insert(row);
    await db.syncDao.enqueueUpsert('user_permission_overrides', row);
  }

  /// Restore defaults — clear EVERY override for [userId] so all permissions
  /// revert to the role default. Each row is hard-deleted and tombstoned
  /// (`enqueueDelete`) so other devices drop it too (same path as a single
  /// inherit/clear in [setOverride]). Returns the number of overrides cleared.
  Future<int> clearAllForUser(String userId) async {
    final rows = await getForUser(userId);
    for (final r in rows) {
      await (delete(
        userPermissionOverrides,
      )..where((t) => t.id.equals(r.id))).go();
      await db.syncDao.enqueueDelete('user_permission_overrides', r.id);
    }
    return rows.length;
  }
}

@DriftAccessor(tables: [StoreRolePermissions])
class StoreRolePermissionsDao extends DatabaseAccessor<AppDatabase>
    with _$StoreRolePermissionsDaoMixin, BusinessScopedDao<AppDatabase> {
  StoreRolePermissionsDao(super.db);

  Stream<List<StoreRolePermissionData>> watchFor(
    String storeId,
    String roleId,
  ) {
    return (select(storeRolePermissions)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.storeId.equals(storeId) &
                t.roleId.equals(roleId),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.permissionKey)]))
        .watch();
  }

  Future<List<StoreRolePermissionData>> getFor(String storeId, String roleId) {
    return (select(storeRolePermissions)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.storeId.equals(storeId) &
                t.roleId.equals(roleId),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.permissionKey)]))
        .get();
  }

  /// Set or clear a store's override of [permissionKey] for [roleId] (§10.2.1
  /// Store scope). [value] true = force-grant, false = force-revoke, null =
  /// clear the override (inherit the role's business default). Idempotent on the
  /// logical identity (store_id, role_id, permission_key): a value that already
  /// matches is a no-op, so we never trip UNIQUE on a stale toggle or a row that
  /// arrived from the cloud since the UI last built. Same shape as
  /// [UserPermissionOverridesDao.setOverride].
  Future<void> setOverride(
    String storeId,
    String roleId,
    String permissionKey,
    bool? value,
  ) async {
    final existing =
        await (select(storeRolePermissions)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    t.storeId.equals(storeId) &
                    t.roleId.equals(roleId) &
                    t.permissionKey.equals(permissionKey),
              )
              ..limit(1))
            .getSingleOrNull();

    if (value == null) {
      // Inherit — remove the override row and tombstone it cloud-side.
      // `store_role_permissions` is not an append-only ledger, so hard-delete
      // via `enqueueDelete` is the right path here.
      if (existing == null) return;
      await (delete(
        storeRolePermissions,
      )..where((t) => t.id.equals(existing.id))).go();
      await db.syncDao.enqueueDelete('store_role_permissions', existing.id);
      return;
    }

    if (existing != null) {
      if (existing.isGranted == value) return; // already at this value
      final row = StoreRolePermissionsCompanion(
        id: Value(existing.id),
        businessId: Value(existing.businessId),
        storeId: Value(existing.storeId),
        roleId: Value(existing.roleId),
        permissionKey: Value(existing.permissionKey),
        isGranted: Value(value),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await (update(
        storeRolePermissions,
      )..where((t) => t.id.equals(existing.id))).write(row);
      await db.syncDao.enqueueUpsert('store_role_permissions', row);
      return;
    }

    final row = StoreRolePermissionsCompanion.insert(
      id: Value(UuidV7.generate()),
      businessId: requireBusinessId(),
      storeId: storeId,
      roleId: roleId,
      permissionKey: permissionKey,
      isGranted: value,
      lastUpdatedAt: Value(DateTime.now()),
    );
    await into(storeRolePermissions).insert(row);
    await db.syncDao.enqueueUpsert('store_role_permissions', row);
  }

  /// Restore store defaults — clear EVERY override for [storeId] + [roleId] so
  /// that store's permissions revert to the role's business defaults. Each row
  /// is hard-deleted and tombstoned (`enqueueDelete`) so other devices drop it
  /// too. Returns the number of overrides cleared.
  Future<int> clearAllForStoreRole(String storeId, String roleId) async {
    final rows = await getFor(storeId, roleId);
    for (final r in rows) {
      await (delete(
        storeRolePermissions,
      )..where((t) => t.id.equals(r.id))).go();
      await db.syncDao.enqueueDelete('store_role_permissions', r.id);
    }
    return rows.length;
  }
}

@DriftAccessor(tables: [RoleSettings])
class RoleSettingsDao extends DatabaseAccessor<AppDatabase>
    with _$RoleSettingsDaoMixin, BusinessScopedDao<AppDatabase> {
  RoleSettingsDao(super.db);

  Stream<List<RoleSettingData>> watchForRole(String roleId) {
    return (select(roleSettings)
          ..where((t) => whereBusiness(t) & t.roleId.equals(roleId))
          ..orderBy([(t) => OrderingTerm.asc(t.settingKey)]))
        .watch();
  }

  Future<List<RoleSettingData>> getForRole(String roleId) {
    return (select(roleSettings)
          ..where((t) => whereBusiness(t) & t.roleId.equals(roleId))
          ..orderBy([(t) => OrderingTerm.asc(t.settingKey)]))
        .get();
  }

  Future<String?> getValue(String roleId, String settingKey) async {
    final row =
        await (select(roleSettings)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    t.roleId.equals(roleId) &
                    t.settingKey.equals(settingKey),
              )
              ..limit(1))
            .getSingleOrNull();
    return row?.settingValue;
  }

  /// Set a setting value. Upserts on (role_id, setting_key).
  Future<void> set(String roleId, String settingKey, String? value) async {
    final existing =
        await (select(roleSettings)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    t.roleId.equals(roleId) &
                    t.settingKey.equals(settingKey),
              )
              ..limit(1))
            .getSingleOrNull();
    if (existing != null) {
      final comp = RoleSettingsCompanion(
        id: Value(existing.id),
        settingValue: Value(value),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await (update(
        roleSettings,
      )..where((t) => t.id.equals(existing.id))).write(comp);
      // Refresh full row for enqueue (payload carries businessId etc.)
      final refreshed = await (select(
        roleSettings,
      )..where((t) => t.id.equals(existing.id))).getSingle();
      await db.syncDao.enqueueUpsert('role_settings', refreshed);
    } else {
      final comp = RoleSettingsCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: requireBusinessId(),
        roleId: roleId,
        settingKey: settingKey,
        settingValue: Value(value),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await into(roleSettings).insert(comp);
      await db.syncDao.enqueueUpsert('role_settings', comp);
    }
  }
}

/// One active staff member for the Who Is Working picker (master plan §8):
/// the user row plus their resolved role (null if the role row hasn't synced
/// locally yet).
class WhoIsWorkingEntry {
  final UserData user;
  final RoleData? role;
  const WhoIsWorkingEntry({required this.user, this.role});
}
