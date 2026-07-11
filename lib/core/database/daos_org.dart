part of 'daos.dart';

@DriftAccessor(tables: [Settings])
class SettingsDao extends DatabaseAccessor<AppDatabase>
    with _$SettingsDaoMixin, BusinessScopedDao<AppDatabase> {
  SettingsDao(super.db);

  Future<String?> get(String key) async {
    final row =
        await (select(settings)
              ..where((t) => whereBusiness(t) & t.key.equals(key))
              ..limit(1))
            .getSingleOrNull();
    return row?.value;
  }

  Future<void> set(String key, String value) async {
    // customInsert (not customStatement) so Drift marks `settings` as updated
    // and re-fires any open watch() streams — without `updates:`, raw
    // statements are invisible to stream watchers, so reactive readers (e.g.
    // the business accent colour via businessDesignSystemProvider) never see
    // the new value until they re-subscribe.
    await customInsert(
      'INSERT INTO settings (id, business_id, "key", value) VALUES (?, ?, ?, ?) '
      'ON CONFLICT(business_id, "key") DO UPDATE SET value = excluded.value, last_updated_at = (strftime(\'%s\', \'now\'))',
      variables: [
        Variable.withString(UuidV7.generate()),
        Variable.withString(requireBusinessId()),
        Variable.withString(key),
        Variable.withString(value),
      ],
      updates: {settings},
    );
    final row =
        await (select(settings)
              ..where((t) => whereBusiness(t) & t.key.equals(key))
              ..limit(1))
            .getSingle();
    await db.syncDao.enqueueUpsert('settings', row);
  }

  Stream<String?> watch(String key) {
    return (select(settings)
          ..where((t) => whereBusiness(t) & t.key.equals(key))
          ..limit(1))
        .watchSingleOrNull()
        .map((row) => row?.value);
  }

  /// Helper for timezone-aware logic (PR 4c/4f)
  Future<String> getTimezone() async {
    return (await get('business_timezone')) ?? 'UTC';
  }

  Stream<String> watchTimezone() {
    return watch('business_timezone').map((v) => v ?? 'UTC');
  }
}

/// Sentinel used by [BusinessesDao.updateInfo] to distinguish "caller did not
/// pass logoUrl" (leave the column unchanged) from "caller passed null/empty"
/// (clear the logo). Using a typed default of `Object?` lets the method
/// accept `String`, `null`, `''`, or nothing, without overloading.
const _absent = Object();

// NB: `@DriftAccessor` must sit directly on the class — a declaration between
// the annotation and `class BusinessesDao` (the `_absent` sentinel above) steals
// the annotation, so drift_dev never emits `_$BusinessesDaoMixin` and a clean
// regeneration fails to compile.
@DriftAccessor(tables: [Businesses])
class BusinessesDao extends DatabaseAccessor<AppDatabase>
    with _$BusinessesDaoMixin, BusinessScopedDao<AppDatabase> {
  BusinessesDao(super.db);

  /// Edits the current business's name and/or type (CEO Settings > Business
  /// Info, §10.1). Currency is a synced `settings` key (`default_currency`),
  /// not a column here — set it via [SettingsDao.set].
  ///
  /// `businesses` is cloud-synced via its special push/pull/realtime path
  /// (it is intentionally absent from `_syncedTenantTables`), so the write
  /// still routes through `enqueueUpsert`. Because that absence also means
  /// no `bump_businesses_last_updated_at` trigger exists, `lastUpdatedAt`
  /// is stamped explicitly here (same as onboarding's local mirror).
  Future<void> updateInfo({
    String? name,
    String? type,
    String? phone,
    bool? tracksEmptyCrates,
    // null = leave unchanged; empty string = clear (remove logo).
    Object? logoUrl = _absent,
  }) async {
    final id = requireBusinessId();
    await (update(businesses)..where((t) => t.id.equals(id))).write(
      BusinessesCompanion(
        name: name == null ? const Value.absent() : Value(name),
        type: type == null ? const Value.absent() : Value(type),
        // Empty string clears the stored phone (nullable column).
        phone: phone == null
            ? const Value.absent()
            : Value(phone.isEmpty ? null : phone),
        tracksEmptyCrates: tracksEmptyCrates == null
            ? const Value.absent()
            : Value(tracksEmptyCrates),
        // logoUrl: pass a String to set/update, '' to clear, omit to leave.
        logoUrl: logoUrl == _absent
            ? const Value.absent()
            : Value(logoUrl == '' ? null : logoUrl as String?),
        lastUpdatedAt: Value(DateTime.now()),
      ),
    );
    final row = await (select(
      businesses,
    )..where((t) => t.id.equals(id))).getSingle();
    await db.syncDao.enqueueUpsert('businesses', row);
  }
}

@DriftAccessor(tables: [SystemConfig])
class SystemConfigDao extends DatabaseAccessor<AppDatabase>
    with _$SystemConfigDaoMixin {
  SystemConfigDao(super.db);

  Future<String?> get(String key) async {
    final row =
        await (select(systemConfig)
              ..where((t) => t.key.equals(key))
              ..limit(1))
            .getSingleOrNull();
    return row?.value;
  }

  Future<void> set(String key, String? value) async {
    await customStatement(
      'INSERT INTO system_config ("key", value) VALUES (?, ?) '
      'ON CONFLICT("key") DO UPDATE SET value = excluded.value, last_updated_at = (strftime(\'%s\', \'now\'))',
      [key, value],
    );
  }
}

// ---------------------------------------------------------------------------
// Master plan §2.4 — roles, permissions, membership (schema v13)
// ---------------------------------------------------------------------------

/// Read-only access to the global `permissions` table. Rows are seeded
/// by migration on both the client and the cloud; nothing writes to
/// this table at runtime, so no enqueue path.

@DriftAccessor(tables: [UserBusinesses, Users, Roles])
class UserBusinessesDao extends DatabaseAccessor<AppDatabase>
    with _$UserBusinessesDaoMixin, BusinessScopedDao<AppDatabase> {
  UserBusinessesDao(super.db);

  /// The user id of this business's CEO (the single owner, CLAUDE.md), or null
  /// if none is resolved locally. Used to route §26.4 CEO-only notifications.
  Future<String?> getCeoUserId() async {
    final ceoRole = await db.rolesDao.getBySlug('ceo');
    if (ceoRole == null) return null;
    final row =
        await (select(userBusinesses)
              ..where(
                (t) =>
                    whereBusiness(t) &
                    t.roleId.equals(ceoRole.id) &
                    t.status.equals('active'),
              )
              ..limit(1))
            .getSingleOrNull();
    return row?.userId;
  }

  /// Active user ids whose role slug is in [slugs] for the current business.
  /// Routes §26.4 notifications to a role audience (e.g. Close Day's "day
  /// closed" fires to CEO + Manager). Empty if none resolve locally.
  Future<List<String>> getUserIdsForRoleSlugs(List<String> slugs) async {
    if (slugs.isEmpty) return const [];
    final query =
        select(userBusinesses).join([
          innerJoin(roles, roles.id.equalsExp(userBusinesses.roleId)),
        ])..where(
          whereBusiness(userBusinesses) &
              userBusinesses.status.equals('active') &
              roles.slug.isIn(slugs),
        );
    final rows = await query.get();
    return rows.map((r) => r.readTable(userBusinesses).userId).toList();
  }

  /// Memberships for the current business, excluding terminally-`removed` staff
  /// (#107). Drives the Staff Management list and the Who Is Working picker.
  /// Keeps `active` and `suspended` (both surface in Staff Management — suspended
  /// greyed out); `removed` staff no longer appear in any active staff list,
  /// though their users row is retained as an attribution stub for history.
  Stream<List<UserBusinessData>> watchForCurrentBusiness() {
    return (select(userBusinesses)
          ..where((t) => whereBusiness(t) & t.status.equals('removed').not())
          ..orderBy([(t) => OrderingTerm.asc(t.status)]))
        .watch();
  }

  /// Active staff (with their user + role rows) for [businessId], joined in
  /// one query — drives the Who Is Working picker (master plan §8).
  ///
  /// Deliberately NOT business-scoped via [whereBusiness]/[requireBusinessId]:
  /// the picker renders BEFORE sign-in, so the session resolver has no current
  /// business yet (`currentBusinessId == null`). It filters by the explicit
  /// [businessId] argument instead. Suspended staff are excluded (§8.3).
  Stream<List<WhoIsWorkingEntry>> watchActiveStaffForBusiness(
    String businessId,
  ) {
    final query =
        select(userBusinesses).join([
            innerJoin(users, users.id.equalsExp(userBusinesses.userId)),
            leftOuterJoin(roles, roles.id.equalsExp(userBusinesses.roleId)),
          ])
          ..where(
            userBusinesses.businessId.equals(businessId) &
                userBusinesses.status.equals('active'),
          )
          ..orderBy([OrderingTerm.asc(users.name)]);
    return query.watch().map(
      (rows) => rows
          .map(
            (row) => WhoIsWorkingEntry(
              user: row.readTable(users),
              role: row.readTableOrNull(roles),
            ),
          )
          .toList(),
    );
  }

  /// One-shot count of active staff for [businessId]. Drives cold-start
  /// routing (master plan §7.2): >1 → Who Is Working picker so the signer is
  /// chosen explicitly; ≤1 → that user's personalized PIN screen. Not
  /// session-scoped (runs before sign-in), same as [watchActiveStaffForBusiness].
  Future<int> countActiveStaffForBusiness(String businessId) async {
    final countExp = userBusinesses.id.count();
    final row =
        await (selectOnly(userBusinesses)
              ..addColumns([countExp])
              ..where(
                userBusinesses.businessId.equals(businessId) &
                    userBusinesses.status.equals('active'),
              ))
            .getSingle();
    return row.read(countExp) ?? 0;
  }

  /// Streams the list of active staff for [businessId] who are also device-authenticated
  /// (meaning their users.pinHash is not null). Drives the filtered staff picker.
  Stream<List<WhoIsWorkingEntry>> watchDeviceStaffForBusiness(
    String businessId,
  ) {
    final query =
        select(userBusinesses).join([
            innerJoin(users, users.id.equalsExp(userBusinesses.userId)),
            leftOuterJoin(roles, roles.id.equalsExp(userBusinesses.roleId)),
          ])
          ..where(
            userBusinesses.businessId.equals(businessId) &
                userBusinesses.status.equals('active') &
                users.pinHash.isNotNull(),
          )
          ..orderBy([OrderingTerm.asc(users.name)]);
    return query.watch().map(
      (rows) => rows
          .map(
            (row) => WhoIsWorkingEntry(
              user: row.readTable(users),
              role: row.readTableOrNull(roles),
            ),
          )
          .toList(),
    );
  }

  /// One-shot count of active staff for [businessId] who are device-authenticated
  /// (meaning their users.pinHash is not null).
  Future<int> countDeviceStaffForBusiness(String businessId) async {
    final countExp = userBusinesses.id.count();
    final query = selectOnly(userBusinesses).join([
      innerJoin(users, users.id.equalsExp(userBusinesses.userId)),
    ])
      ..addColumns([countExp])
      ..where(
        userBusinesses.businessId.equals(businessId) &
            userBusinesses.status.equals('active') &
            users.pinHash.isNotNull(),
      );
    final row = await query.getSingle();
    return row.read(countExp) ?? 0;
  }

  /// All memberships for a specific user — Phase 1 always returns
  /// at most one row, but the query supports the Phase 2 multi-
  /// business model without a schema change.
  Future<List<UserBusinessData>> getForUser(String userId) {
    return (select(
      userBusinesses,
    )..where((t) => t.userId.equals(userId))).get();
  }

  /// Reactive memberships for a specific user, NOT scoped to the current
  /// session. Filters by user id only so the role-badge resolver works
  /// before login binds a business (the shared-PIN picker). Drives
  /// `userRoleProvider`.
  Stream<List<UserBusinessData>> watchForUser(String userId) {
    return (select(
      userBusinesses,
    )..where((t) => t.userId.equals(userId))).watch();
  }

  Future<UserBusinessData?> getForUserInBusiness(
    String userId,
    String businessId,
  ) {
    return (select(userBusinesses)
          ..where(
            (t) => t.userId.equals(userId) & t.businessId.equals(businessId),
          )
          ..limit(1))
        .getSingleOrNull();
  }

  Future<void> insertMembership(UserBusinessesCompanion row) async {
    await into(userBusinesses).insert(row);
    await db.syncDao.enqueueUpsert('user_businesses', row);
  }

  /// Sync-exempt local mirror of a server-confirmed removal (#107 offboarding).
  /// The authoritative write is the `remove_staff_member` SECURITY DEFINER RPC
  /// (see [AuthService.removeStaffMember]) — it sets the membership `removed` and
  /// nulls the identity's cloud auth link atomically. This only reflects that
  /// confirmed terminal status into the local row so the member drops out of the
  /// active staff list immediately; a background pull converges the rest.
  /// Deliberately does NOT enqueue: the RPC already wrote the cloud row, and the
  /// §6 outbox must not re-push a status the server owns.
  Future<void> markRemovedLocal(String membershipId) async {
    await (update(
      userBusinesses,
    )..where((t) => t.id.equals(membershipId))).write(
      const UserBusinessesCompanion(status: Value('removed')),
    );
  }

  /// Suspend or reactivate a membership. [status] is `'active'` or
  /// `'suspended'` — the two non-terminal states. The terminal `'removed'`
  /// state is NEVER set through this outbox path; it is server-authoritative
  /// (see [markRemovedLocal] / `remove_staff_member`). Enqueues the updated
  /// row for sync.
  Future<void> setStatus(String membershipId, String status) async {
    await (update(
      userBusinesses,
    )..where((t) => t.id.equals(membershipId))).write(
      UserBusinessesCompanion(
        status: Value(status),
        lastUpdatedAt: Value(DateTime.now()),
      ),
    );
    // Re-read the full row so the enqueue payload carries businessId etc.
    final refreshed = await (select(
      userBusinesses,
    )..where((t) => t.id.equals(membershipId))).getSingle();
    await db.syncDao.enqueueUpsert('user_businesses', refreshed);
  }

  /// Change the role on a membership. Enqueues the updated row for sync.
  Future<void> setRole(String membershipId, String roleId) async {
    await (update(
      userBusinesses,
    )..where((t) => t.id.equals(membershipId))).write(
      UserBusinessesCompanion(
        roleId: Value(roleId),
        lastUpdatedAt: Value(DateTime.now()),
      ),
    );
    // Re-read the full row so the enqueue payload carries businessId etc.
    final refreshed = await (select(
      userBusinesses,
    )..where((t) => t.id.equals(membershipId))).getSingle();
    await db.syncDao.enqueueUpsert('user_businesses', refreshed);
  }

  /// Stamp the login time on a user's membership. Enqueues the updated row
  /// for sync. No-op if the user has no membership in [businessId].
  Future<void> touchLastLogin(String userId, String businessId) async {
    final now = DateTime.now();
    await (update(userBusinesses)..where(
          (t) => t.userId.equals(userId) & t.businessId.equals(businessId),
        ))
        .write(
          UserBusinessesCompanion(
            lastLoginAt: Value(now),
            lastUpdatedAt: Value(now),
          ),
        );
    // Re-read the full row so the enqueue payload carries businessId etc.
    final refreshed = await getForUserInBusiness(userId, businessId);
    if (refreshed != null) {
      await db.syncDao.enqueueUpsert('user_businesses', refreshed);
    }
  }
}

@DriftAccessor(tables: [InviteCodes])
class InviteCodesDao extends DatabaseAccessor<AppDatabase>
    with _$InviteCodesDaoMixin, BusinessScopedDao<AppDatabase> {
  InviteCodesDao(super.db);

  /// Active invite codes (not yet used, not revoked, not soft-
  /// deleted, not expired). Drives the Invites tab.
  Stream<List<InviteCodeData>> watchActive() {
    final now = DateTime.now();
    return (select(inviteCodes)
          ..where(
            (t) =>
                whereBusiness(t) &
                t.isDeleted.not() &
                t.usedAt.isNull() &
                t.revokedAt.isNull() &
                t.expiresAt.isBiggerThanValue(now),
          )
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .watch();
  }

  Future<InviteCodeData?> getByCode(String code) {
    return (select(inviteCodes)
          ..where((t) => t.code.equals(code))
          ..limit(1))
        .getSingleOrNull();
  }

  Future<void> insertInvite(InviteCodesCompanion row) async {
    await into(inviteCodes).insert(row);
    await db.syncDao.enqueueUpsert('invite_codes', row);
  }

  /// Revoke an invite code (soft — stays in sync). Sets `revokedAt` so the
  /// code drops out of `watchActive` and can no longer be redeemed. The
  /// row stays in `invite_codes`; enqueue the full row so the cloud sees
  /// the revoke (CLAUDE.md hard rule #9 / §5 soft-delete via enqueueUpsert).
  Future<void> revoke(String id) async {
    final now = DateTime.now();
    await (update(inviteCodes)..where((t) => t.id.equals(id))).write(
      InviteCodesCompanion(revokedAt: Value(now), lastUpdatedAt: Value(now)),
    );
    // Re-read the full row so the enqueue payload carries businessId etc.
    final refreshed = await (select(
      inviteCodes,
    )..where((t) => t.id.equals(id))).getSingle();
    await db.syncDao.enqueueUpsert('invite_codes', refreshed);
  }
}
