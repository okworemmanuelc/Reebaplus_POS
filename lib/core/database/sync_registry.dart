// sync-exempt-file: this is the sync engine's per-table source of truth — the
// registry names every synced table, and its restore closures write to Drift
// directly (§5 exception #1, the restoration path). No DAO/enqueue concerns.
part of 'app_database.dart';

// ===========================================================================
// SyncedTable registry — the single ordered source of truth for every
// per-table sync fact (issue #15).
//
// Adding or changing a synced table used to mean editing the same table's
// knowledge in six scattered constructs (synced-tenant-table list, pull order,
// push-column whitelist, created_at-scrub set, two hard-delete switches) plus a
// ~50-case restore switch. Forgetting one path silently dropped that table's
// rows on peer devices. This registry collapses all of that into ONE ordered
// `List<SyncedTable>`; the old lists now DERIVE from it (see the accessors at
// the bottom), so they can never disagree, and a golden equivalence test pins
// that the derivations reproduce the historical constructs byte-for-byte.
//
// Placement: the DATABASE layer (invariant #8). The schema-builder (which reads
// the tenant-table list at create time) and the sync engine (which imports the
// database) both need these facts; the database layer is the only shared home
// that introduces no upward dependency / import cycle. The restore executor and
// the FK-resilient helper live here too, so the registry never reaches up into
// `lib/core/services/`.
//
// List order governs PULL / RESTORE / hard-delete RECONCILE only. Push drains
// the outbox row-by-row in adaptive chunks and never iterates tables in order —
// it only reads each table's push columns. Reordering the list therefore cannot
// change push behaviour.
// ===========================================================================

/// A restore function: applies a page of cloud rows for [table] into Drift.
/// Built from the [Restore] helpers (the common cases) or hand-written (the
/// genuinely bespoke tables, e.g. `users`). [rows] are already camelCased and
/// have passed the central pre-insert guards (LWW / invariant #12 / business
/// isolation) run by the executor's caller. [fkSkipped] collects tables whose
/// rows were FK-deferred so the caller can hold the pull cursor.
typedef RestoreFn =
    Future<void> Function(
      SyncRestoreExecutor ex,
      String table,
      List<Map<String, dynamic>> rows,
      Set<String>? fkSkipped,
    );

/// The two typed deletes a hard-delete table needs, reconciled from what used
/// to be two parallel per-table switches (`_deleteLocalRowById` for realtime
/// DELETEs, `_deleteLocalRowsNotIn` for full-snapshot reconcile). Both are
/// LOCAL-ONLY (§5 exception #1 — applying cloud truth, never enqueued).
class SyncHardDelete {
  /// Apply a realtime DELETE: remove the single row with [id].
  final Future<void> Function(AppDatabase db, String id) deleteById;

  /// Full-snapshot reconcile: business-scoped delete of every row whose id is
  /// NOT in [keepIds]. Returns the number of rows removed.
  final Future<int> Function(
    AppDatabase db,
    String businessId,
    List<String> keepIds,
  )
  deleteByIdsNotIn;

  const SyncHardDelete({
    required this.deleteById,
    required this.deleteByIdsNotIn,
  });

  /// Builds both deletes for a table from its id + business_id columns, so the
  /// per-table hard-delete fact lives in exactly one descriptor field. Captures
  /// the concrete Drift table type at the call site — no dynamic casts.
  static SyncHardDelete of<T extends Table, D>(
    TableInfo<T, D> Function(AppDatabase db) tableOf,
    Expression<bool> Function(T tbl, String id) idEquals,
    Expression<bool> Function(T tbl, String businessId) businessIdEquals,
    Expression<bool> Function(T tbl, List<String> ids) idIn,
  ) => SyncHardDelete(
    deleteById: (db, id) async {
      final t = tableOf(db);
      await (db.delete(t)..where((row) => idEquals(row, id))).go();
    },
    deleteByIdsNotIn: (db, businessId, ids) {
      final t = tableOf(db);
      return (db.delete(t)..where(
            (row) => businessIdEquals(row, businessId) & idIn(row, ids).not(),
          ))
          .go();
    },
  );
}

/// The complete truth about ONE table's sync behaviour. Required fields are
/// non-nullable so a half-configured table will not compile; optional fields
/// are absent when they do not apply (no push columns ⇒ pull-only /
/// cloud-authoritative; no [hardDelete] ⇒ append-only / soft-delete;
/// [scrubCreatedAt] false ⇒ not an immutable-created_at ledger).
class SyncedTable {
  /// Cloud + Drift table name (identical on every device).
  final String name;

  /// How a pulled page of this table's rows is written into Drift.
  final RestoreFn restore;

  /// Per-table whitelist of cloud-pushable columns. `null` ⇒ pass-through: the
  /// Drift column set IS the cloud column set (no leak surface). A whitelist is
  /// declared only for tables that diverge from cloud (auth/secret material,
  /// local-only columns, cloud-authoritative columns).
  final Set<String>? pushColumns;

  /// Set only for the hard-delete tables (the `enqueueDelete` call sites): a
  /// revoke/delete is a true row removal the cloud forgets, so a missed delete
  /// has no upsert to self-heal it. Absent ⇒ soft-delete / append-only, never
  /// hard-removed by a reconcile.
  final SyncHardDelete? hardDelete;

  /// True for the append-only ledger tables whose void path re-pushes the FULL
  /// row; their `created_at` is cloud-owned and immutable, so it must be dropped
  /// at the push boundary or the re-push orphans (P0001). Default false.
  final bool scrubCreatedAt;

  /// True for the ~46 business-scoped tenant tables (carry `business_id` +
  /// `last_updated_at`, drive incremental cursor pulls, create the per-table
  /// cursor index + bump trigger at DB-create time). False for `businesses`
  /// (id-keyed, own realtime channel), the Phase-D caches, and the global
  /// pull-only tables (`profiles`, `system_config`).
  final bool tenantScoped;

  /// True for the Phase-D balance caches (`inventory`, `*_crate_balances`):
  /// enqueued + pushed, but deliberately not tenant-scoped (no cursor index /
  /// bump trigger — they arrive via snapshot or domain response).
  final bool isCache;

  const SyncedTable({
    required this.name,
    required this.restore,
    this.pushColumns,
    this.hardDelete,
    this.scrubCreatedAt = false,
    this.tenantScoped = false,
    this.isCache = false,
  });
}

// ---------------------------------------------------------------------------
// Restore helpers. Each captures the concrete Drift row type at its call site
// (so no dynamic casts leak) and returns a uniform [RestoreFn], so the registry
// stays one list even though the strategies differ.
// ---------------------------------------------------------------------------
abstract final class Restore {
  /// A no-op restore, for entries present only for their pull-order / push
  /// facts (`profiles` has no local mirror; it is short-circuited before the
  /// guards run and this closure is never reached).
  static RestoreFn skip() => (ex, table, rows, fkSkipped) async {};

  /// The common case: `insertOnConflictUpdate(fromJson(row))`, optionally
  /// FK-[resilient]. [defaults] fill local-only columns absent from the cloud
  /// row (camelCase keys, applied before fromJson). [jsonbColumns] JSON-encode
  /// cloud `jsonb` values that Drift mirrors as `text`.
  static RestoreFn plain<T extends Table, D extends Insertable<D>>(
    TableInfo<T, D> Function(AppDatabase db) tableOf,
    D Function(Map<String, dynamic> json) fromJson, {
    bool resilient = false,
    Map<String, Object?> defaults = const {},
    Set<String> jsonbColumns = const {},
  }) => (ex, table, rows, fkSkipped) async {
    final t = tableOf(ex.db);
    for (final r in rows) {
      for (final c in jsonbColumns) {
        r[c] = SyncRestoreExecutor.stringifyJsonb(r[c]);
      }
      defaults.forEach((k, v) => r.putIfAbsent(k, () => v));
      final data = fromJson(r);
      Future<void> doInsert() =>
          ex.db.into(t).insertOnConflictUpdate(data);
      if (resilient) {
        await ex.insertResilient(table, r, fkSkipped, doInsert);
      } else {
        await doInsert();
      }
    }
  };

  /// Upsert on a NATURAL key rather than the surrogate `id`: two id-minting
  /// authorities (client UuidV7 vs cloud gen_random_uuid) produce different ids
  /// for the same logical row, so a PK-keyed upsert trips the cloud UNIQUE
  /// (2067). [target] is the conflict clause; [buildUpdate] the SET on conflict
  /// (which aligns the local id to the cloud's so the two converge).
  static RestoreFn naturalKey<T extends Table, D extends Insertable<D>>(
    TableInfo<T, D> Function(AppDatabase db) tableOf,
    D Function(Map<String, dynamic> json) fromJson,
    List<Column> Function(AppDatabase db) target,
    Insertable<D> Function(D parsed) buildUpdate, {
    bool resilient = true,
    Set<String> jsonbColumns = const {},
  }) => (ex, table, rows, fkSkipped) async {
    final t = tableOf(ex.db);
    for (final r in rows) {
      for (final c in jsonbColumns) {
        r[c] = SyncRestoreExecutor.stringifyJsonb(r[c]);
      }
      final parsed = fromJson(r);
      Future<void> doInsert() => ex.db
          .into(t)
          .insert(
            parsed,
            onConflict: DoUpdate(
              (_) => buildUpdate(parsed),
              target: target(ex.db),
            ),
          );
      if (resilient) {
        await ex.insertResilient(table, r, fkSkipped, doInsert);
      } else {
        await doInsert();
      }
    }
  };

  /// Dedup on a LOGICAL key (grant / override tables): the surrogate `id` is a
  /// random per-grant UUID but identity is a natural tuple enforced by a UNIQUE
  /// constraint. A grant→revoke→re-grant cycle (or two devices) mint different
  /// ids for the same tuple, so drop any local twin (same tuple, different id)
  /// before the cloud row's upsert applies — the device converges on the cloud
  /// id without tripping 2067. [logicalTwin] must include `.id != parsed.id`.
  static RestoreFn dedup<T extends Table, D extends Insertable<D>>(
    TableInfo<T, D> Function(AppDatabase db) tableOf,
    D Function(Map<String, dynamic> json) fromJson,
    Expression<bool> Function(T tbl, D parsed) logicalTwin, {
    bool resilient = true,
  }) => (ex, table, rows, fkSkipped) async {
    final t = tableOf(ex.db);
    for (final r in rows) {
      final parsed = fromJson(r);
      Future<void> doInsert() async {
        await (ex.db.delete(t)..where((tbl) => logicalTwin(tbl, parsed))).go();
        await ex.db.into(t).insertOnConflictUpdate(parsed);
      }
      if (resilient) {
        await ex.insertResilient(table, r, fkSkipped, doInsert);
      } else {
        await doInsert();
      }
    }
  };

  /// Append-only ledger restore (catch-up insert + targeted void update).
  /// Delegates to the executor's [SyncRestoreExecutor.restoreLedger].
  static RestoreFn ledger<T extends Table, D extends Insertable<D>>(
    TableInfo<T, D> Function(AppDatabase db) tableOf,
    D Function(Map<String, dynamic> json) fromJson,
    DateTime? Function(D data) voidedAtOf,
    Expression<bool> Function(T tbl, D data) whereNotYetVoided,
    UpdateCompanion<D> Function(D data) buildVoidCompanion,
  ) => (ex, table, rows, fkSkipped) => ex.restoreLedger<T, D>(
    rows,
    tableName: table,
    table: tableOf(ex.db),
    fromJson: fromJson,
    voidedAtOf: voidedAtOf,
    whereNotYetVoided: whereNotYetVoided,
    buildVoidCompanion: buildVoidCompanion,
    fkSkipped: fkSkipped,
  );
}

// ---------------------------------------------------------------------------
// Restore executor — the database-layer runtime the restore closures call.
// It carries the FK-resilient helper, the ledger restore, and the small static
// error/JSON helpers that used to live on the sync service, so the registry has
// no upward dependency. The central pre-insert guards (LWW / invariant #12 /
// business isolation) stay in the sync service, verbatim, before dispatch.
// ---------------------------------------------------------------------------
class SyncRestoreExecutor {
  final AppDatabase db;

  /// §3.7 (A2) collector: the map the sync service passes during a
  /// `pullInitialData` restore loop so the post-restore targeted-parent fetch
  /// can pull a missing parent by id and retry the orphan inline. `null` on the
  /// realtime path (a single row → no in-pull second pass).
  final Map<String, List<Map<String, dynamic>>>? fkOrphanedRows;

  /// §30.8.1 pull-side heal, injected by the sync service (needs secure storage
  /// + ordersDao, which are service concerns). `null` in DB-only test/bootstrap
  /// constructions — the collision then falls through as a normal skip.
  final Future<bool> Function(OrderData cloudOrder)? _healOrderBlocker;

  SyncRestoreExecutor(
    this.db, {
    this.fkOrphanedRows,
    Future<bool> Function(OrderData cloudOrder)? healOrderBlocker,
  }) : _healOrderBlocker = healOrderBlocker;

  /// Pull-side counterpart to the push heal (§30.8.1); see the sync service's
  /// `_healLocalOrderNumberBlocker`. Returns false when no heal is wired.
  Future<bool> healLocalOrderNumberBlocker(OrderData cloudOrder) =>
      _healOrderBlocker?.call(cloudOrder) ?? Future.value(false);

  /// Inserts one restore row, isolating FOREIGN KEY violations so a single
  /// orphaned child can't abort the whole restore transaction and crash the
  /// pull. An FK violation means the referenced parent slice is genuinely absent
  /// from THIS snapshot; we skip-and-log the row and record its table in
  /// [fkSkipped] so the caller holds the sync cursor for the next full pull.
  /// A cross-device natural-key UNIQUE collision (2067) is skipped (permanent
  /// data a re-pull can't reconcile) unless [healUniqueCollision] frees the key.
  /// Non-FK / non-UNIQUE errors rethrow. §5 exception #1 — no enqueue concerns.
  Future<void> insertResilient(
    String table,
    Map<String, dynamic> r,
    Set<String>? fkSkipped,
    Future<void> Function() doInsert, {
    Future<bool> Function()? healUniqueCollision,
  }) async {
    try {
      await doInsert();
    } catch (e) {
      if (isUniqueConstraintViolation(e)) {
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
      if (!isForeignKeyViolation(e)) rethrow;
      fkSkipped?.add(table);
      fkOrphanedRows?.putIfAbsent(table, () => []).add(r);
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

  /// Restore rows into an append-only ledger table. Pull is catch-up only: a
  /// full upsert would trip the BEFORE UPDATE trigger (domain RPCs stamp
  /// `created_at` server-side, so the cloud row disagrees on an immutable
  /// column). Void columns ride in a separate targeted update gated by
  /// `voidedAt IS NULL` so a local-then-newer void isn't clobbered by a stale
  /// cloud snapshot. FK-resilient via [insertResilient].
  Future<void>
  restoreLedger<TableT extends Table, RowT extends Insertable<RowT>>(
    List<Map<String, dynamic>> rows, {
    required String tableName,
    required TableInfo<TableT, RowT> table,
    required RowT Function(Map<String, dynamic>) fromJson,
    required DateTime? Function(RowT data) voidedAtOf,
    required Expression<bool> Function(TableT t, RowT data) whereNotYetVoided,
    required UpdateCompanion<RowT> Function(RowT data) buildVoidCompanion,
    Set<String>? fkSkipped,
  }) async {
    for (final map in rows) {
      final data = fromJson(map);
      await insertResilient(tableName, map, fkSkipped, () async {
        await db.into(table).insert(data, mode: InsertMode.insertOrIgnore);
        if (voidedAtOf(data) != null) {
          await (db.update(table)..where((t) => whereNotYetVoided(t, data)))
              .write(buildVoidCompanion(data));
        }
      });
    }
  }

  /// True if [e] is a SQLite FOREIGN KEY constraint violation (787). Matched by
  /// message so it doesn't depend on the concrete `SqliteException` type.
  static bool isForeignKeyViolation(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('foreign key constraint failed') ||
        s.contains('sqlite_constraint_foreignkey') ||
        s.contains('(787)');
  }

  /// True if [e] is a SQLite UNIQUE constraint violation (2067) — the
  /// cross-device natural-key collision. Matched by message.
  static bool isUniqueConstraintViolation(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('unique constraint failed') ||
        s.contains('sqlite_constraint_unique') ||
        s.contains('(2067)');
  }

  /// Cloud `jsonb` columns can hold any JSON shape; Drift mirrors them as
  /// `text`, so anything non-string must be JSON-encoded before fromJson.
  static dynamic stringifyJsonb(dynamic v) {
    if (v == null || v is String) return v;
    return jsonEncode(v);
  }
}

// ===========================================================================
// THE REGISTRY. One ordered list, in FK-safe PULL order (parents before
// children). Every per-table sync fact derives from this (see accessors below).
// To add a synced table: add ONE entry here, after its parent(s). The reflection
// test turns red if a sync-fingerprinted table has no entry.
// ===========================================================================

final List<SyncedTable> kSyncRegistry = [
  // --- roots / login-critical -------------------------------------------
  SyncedTable(
    name: 'businesses',
    // id-keyed, own realtime channel, no business_id ⇒ not tenant-scoped.
    // Cloud lacks the local-only `timezone`; pre-column-window rows lack
    // onboarding_complete / subscription_status. NON-resilient (a root table
    // with no parent to defer on).
    restore: Restore.plain(
      (db) => db.businesses,
      BusinessData.fromJson,
      defaults: {
        'timezone': 'UTC',
        'onboardingComplete': false,
        'subscriptionStatus': 'trial',
      },
    ),
    pushColumns: {
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
      // timezone: local-only. subscription_*: cloud-authoritative (§32) —
      // deliberately omitted so the device can never push them.
    },
  ),
  SyncedTable(
    name: 'crate_size_groups',
    tenantScoped: true,
    restore: Restore.plain(
      (db) => db.crateSizeGroups,
      CrateSizeGroupData.fromJson,
      resilient: true,
    ),
  ),
  SyncedTable(
    name: 'manufacturers',
    tenantScoped: true,
    restore: Restore.plain(
      (db) => db.manufacturers,
      ManufacturerData.fromJson,
      resilient: true,
    ),
  ),
  SyncedTable(
    name: 'stores',
    tenantScoped: true,
    restore: Restore.plain(
      (db) => db.stores,
      StoreData.fromJson,
      resilient: true,
    ),
  ),
  const SyncedTable(
    name: 'users',
    tenantScoped: true,
    // Bespoke: never overwrite device-local auth/UI material (PIN, biometrics,
    // avatar). See [_restoreUsers].
    restore: _restoreUsers,
    pushColumns: {
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
      // auth_user_id: cloud-authoritative (never originated locally). PIN
      // material: local secret. Both intentionally absent.
    },
  ),
  // --- roles + membership (§2.4) ----------------------------------------
  SyncedTable(
    name: 'roles',
    tenantScoped: true,
    restore: Restore.plain(
      (db) => db.roles,
      RoleData.fromJson,
      resilient: true,
    ),
  ),
  SyncedTable(
    name: 'role_settings',
    tenantScoped: true,
    restore: Restore.plain(
      (db) => db.roleSettings,
      RoleSettingData.fromJson,
      resilient: true,
    ),
  ),
  SyncedTable(
    name: 'role_permissions',
    tenantScoped: true,
    hardDelete: SyncHardDelete.of(
      (db) => db.rolePermissions,
      (t, id) => t.id.equals(id),
      (t, biz) => t.businessId.equals(biz),
      (t, ids) => t.id.isIn(ids),
    ),
    // Logical identity (role_id, permission_key); random id.
    restore: Restore.dedup(
      (db) => db.rolePermissions,
      RolePermissionData.fromJson,
      (t, p) =>
          t.roleId.equals(p.roleId) &
          t.permissionKey.equals(p.permissionKey) &
          t.id.equals(p.id).not(),
    ),
  ),
  SyncedTable(
    name: 'user_permission_overrides',
    tenantScoped: true,
    hardDelete: SyncHardDelete.of(
      (db) => db.userPermissionOverrides,
      (t, id) => t.id.equals(id),
      (t, biz) => t.businessId.equals(biz),
      (t, ids) => t.id.isIn(ids),
    ),
    // Logical identity (business_id, user_id, permission_key); random id.
    restore: Restore.dedup(
      (db) => db.userPermissionOverrides,
      UserPermissionOverrideData.fromJson,
      (t, p) =>
          t.businessId.equals(p.businessId) &
          t.userId.equals(p.userId) &
          t.permissionKey.equals(p.permissionKey) &
          t.id.equals(p.id).not(),
    ),
  ),
  SyncedTable(
    name: 'store_role_permissions',
    tenantScoped: true,
    hardDelete: SyncHardDelete.of(
      (db) => db.storeRolePermissions,
      (t, id) => t.id.equals(id),
      (t, biz) => t.businessId.equals(biz),
      (t, ids) => t.id.isIn(ids),
    ),
    // Logical identity (store_id, role_id, permission_key); random id.
    restore: Restore.dedup(
      (db) => db.storeRolePermissions,
      StoreRolePermissionData.fromJson,
      (t, p) =>
          t.storeId.equals(p.storeId) &
          t.roleId.equals(p.roleId) &
          t.permissionKey.equals(p.permissionKey) &
          t.id.equals(p.id).not(),
    ),
  ),
  SyncedTable(
    name: 'user_businesses',
    tenantScoped: true,
    restore: Restore.plain(
      (db) => db.userBusinesses,
      UserBusinessData.fromJson,
      resilient: true,
    ),
  ),
  SyncedTable(
    name: 'user_stores',
    tenantScoped: true,
    hardDelete: SyncHardDelete.of(
      (db) => db.userStores,
      (t, id) => t.id.equals(id),
      (t, biz) => t.businessId.equals(biz),
      (t, ids) => t.id.isIn(ids),
    ),
    restore: Restore.plain(
      (db) => db.userStores,
      UserStoreData.fromJson,
      resilient: true,
    ),
  ),
  SyncedTable(
    name: 'invite_codes',
    tenantScoped: true,
    restore: Restore.plain(
      (db) => db.inviteCodes,
      InviteCodeData.fromJson,
      resilient: true,
    ),
  ),
  // --- profiles: cloud-only, no local mirror (short-circuited before the
  //     guards). Present only for its pull-order + push-whitelist facts. ---
  SyncedTable(
    name: 'profiles',
    restore: Restore.skip(),
    pushColumns: {
      'id',
      'business_id',
      'role',
      'role_tier',
      'name',
      'created_at',
      'last_updated_at',
    },
  ),
  // --- catalogue --------------------------------------------------------
  SyncedTable(
    name: 'categories',
    tenantScoped: true,
    restore: Restore.plain(
      (db) => db.categories,
      CategoryData.fromJson,
      resilient: true,
    ),
  ),
  SyncedTable(
    name: 'suppliers',
    tenantScoped: true,
    restore: Restore.plain(
      (db) => db.suppliers,
      SupplierData.fromJson,
      resilient: true,
    ),
  ),
  SyncedTable(
    name: 'products',
    tenantScoped: true,
    restore: Restore.plain(
      (db) => db.products,
      ProductData.fromJson,
      resilient: true,
    ),
  ),
  SyncedTable(
    name: 'inventory',
    isCache: true,
    // Natural-key cache (business_id, product_id, store_id) — client UuidV7 vs
    // cloud gen_random_uuid diverge; align id + quantity to the cloud row.
    restore: Restore.naturalKey(
      (db) => db.inventory,
      InventoryData.fromJson,
      (db) => [
        db.inventory.businessId,
        db.inventory.productId,
        db.inventory.storeId,
      ],
      (p) => InventoryCompanion(
        id: Value(p.id),
        quantity: Value(p.quantity),
        lastUpdatedAt: Value(p.lastUpdatedAt),
      ),
    ),
  ),
  SyncedTable(
    name: 'customers',
    tenantScoped: true,
    // Root table (no parent) — NON-resilient, matching historical behaviour.
    restore: Restore.plain((db) => db.customers, CustomerData.fromJson),
  ),
  const SyncedTable(
    name: 'orders',
    tenantScoped: true,
    // Resilient + §30.8.1 legacy order-number collision heal.
    restore: _restoreOrders,
  ),
  SyncedTable(
    name: 'order_items',
    tenantScoped: true,
    restore: Restore.plain(
      (db) => db.orderItems,
      OrderItemData.fromJson,
      resilient: true,
      jsonbColumns: {'priceSnapshot'},
    ),
  ),
  SyncedTable(
    name: 'order_crate_lines',
    tenantScoped: true,
    // Natural key (business_id, order_id, manufacturer_id); heal divergent id.
    restore: Restore.dedup(
      (db) => db.orderCrateLines,
      OrderCrateLineData.fromJson,
      (t, p) =>
          t.businessId.equals(p.businessId) &
          t.orderId.equals(p.orderId) &
          t.manufacturerId.equals(p.manufacturerId) &
          t.id.equals(p.id).not(),
    ),
  ),
  SyncedTable(
    name: 'shipments',
    tenantScoped: true,
    restore: Restore.plain((db) => db.shipments, ShipmentData.fromJson),
  ),
  SyncedTable(
    name: 'purchase_items',
    tenantScoped: true,
    restore: Restore.plain(
      (db) => db.purchaseItems,
      PurchaseItemData.fromJson,
      resilient: true,
    ),
  ),
  SyncedTable(
    name: 'expense_categories',
    tenantScoped: true,
    restore: Restore.plain(
      (db) => db.expenseCategories,
      ExpenseCategoryData.fromJson,
    ),
  ),
  SyncedTable(
    name: 'expenses',
    tenantScoped: true,
    restore: Restore.plain(
      (db) => db.expenses,
      ExpenseData.fromJson,
      resilient: true,
    ),
  ),
  SyncedTable(
    name: 'expense_budgets',
    tenantScoped: true,
    restore: Restore.plain(
      (db) => db.expenseBudgets,
      ExpenseBudgetData.fromJson,
      resilient: true,
    ),
  ),
  SyncedTable(
    name: 'customer_crate_balances',
    isCache: true,
    restore: Restore.naturalKey(
      (db) => db.customerCrateBalances,
      CustomerCrateBalance.fromJson,
      (db) => [
        db.customerCrateBalances.businessId,
        db.customerCrateBalances.customerId,
        db.customerCrateBalances.manufacturerId,
      ],
      (p) => CustomerCrateBalancesCompanion(
        id: Value(p.id),
        balance: Value(p.balance),
        lastUpdatedAt: Value(p.lastUpdatedAt),
      ),
    ),
  ),
  SyncedTable(
    name: 'delivery_receipts',
    tenantScoped: true,
    restore: Restore.plain(
      (db) => db.deliveryReceipts,
      DeliveryReceiptData.fromJson,
    ),
  ),
  SyncedTable(
    name: 'drivers',
    tenantScoped: true,
    restore: Restore.plain((db) => db.drivers, DriverData.fromJson),
  ),
  SyncedTable(
    name: 'stock_transfers',
    tenantScoped: true,
    restore: Restore.plain(
      (db) => db.stockTransfers,
      StockTransferData.fromJson,
      resilient: true,
    ),
  ),
  SyncedTable(
    name: 'stock_adjustments',
    tenantScoped: true,
    restore: Restore.plain(
      (db) => db.stockAdjustments,
      StockAdjustmentData.fromJson,
      resilient: true,
    ),
  ),
  SyncedTable(
    name: 'stock_adjustment_requests',
    tenantScoped: true,
    restore: Restore.plain(
      (db) => db.stockAdjustmentRequests,
      StockAdjustmentRequestData.fromJson,
      resilient: true,
    ),
  ),
  SyncedTable(
    name: 'quick_sale_requests',
    tenantScoped: true,
    restore: Restore.plain(
      (db) => db.quickSaleRequests,
      QuickSaleRequestData.fromJson,
      resilient: true,
    ),
  ),
  SyncedTable(
    name: 'activity_logs',
    tenantScoped: true,
    restore: Restore.ledger(
      (db) => db.activityLogs,
      ActivityLogData.fromJson,
      (d) => d.voidedAt,
      (t, d) => t.id.equals(d.id) & t.voidedAt.isNull(),
      (d) => ActivityLogsCompanion(
        voidedAt: Value(d.voidedAt),
        voidedBy: Value(d.voidedBy),
        voidReason: Value(d.voidReason),
        lastUpdatedAt: Value(d.lastUpdatedAt),
      ),
    ),
  ),
  SyncedTable(
    name: 'error_logs',
    tenantScoped: true,
    restore: Restore.plain(
      (db) => db.errorLogs,
      ErrorLogData.fromJson,
      resilient: true,
    ),
  ),
  SyncedTable(
    name: 'notifications',
    tenantScoped: true,
    hardDelete: SyncHardDelete.of(
      (db) => db.notifications,
      (t, id) => t.id.equals(id),
      (t, biz) => t.businessId.equals(biz),
      (t, ids) => t.id.isIn(ids),
    ),
    restore: Restore.plain((db) => db.notifications, NotificationData.fromJson),
  ),
  SyncedTable(
    name: 'stock_transactions',
    tenantScoped: true,
    restore: Restore.ledger(
      (db) => db.stockTransactions,
      StockTransactionData.fromJson,
      (d) => d.voidedAt,
      (t, d) => t.id.equals(d.id) & t.voidedAt.isNull(),
      (d) => StockTransactionsCompanion(
        voidedAt: Value(d.voidedAt),
        voidedBy: Value(d.voidedBy),
        voidReason: Value(d.voidReason),
        lastUpdatedAt: Value(d.lastUpdatedAt),
      ),
    ),
  ),
  SyncedTable(
    name: 'customer_wallets',
    tenantScoped: true,
    restore: Restore.plain(
      (db) => db.customerWallets,
      CustomerWalletData.fromJson,
      resilient: true,
    ),
  ),
  SyncedTable(
    name: 'wallet_transactions',
    tenantScoped: true,
    scrubCreatedAt: true,
    restore: Restore.ledger(
      (db) => db.walletTransactions,
      WalletTransactionData.fromJson,
      (d) => d.voidedAt,
      (t, d) => t.id.equals(d.id) & t.voidedAt.isNull(),
      (d) => WalletTransactionsCompanion(
        voidedAt: Value(d.voidedAt),
        voidedBy: Value(d.voidedBy),
        voidReason: Value(d.voidReason),
        lastUpdatedAt: Value(d.lastUpdatedAt),
      ),
    ),
  ),
  SyncedTable(
    name: 'supplier_ledger_entries',
    tenantScoped: true,
    scrubCreatedAt: true,
    restore: Restore.ledger(
      (db) => db.supplierLedgerEntries,
      SupplierLedgerEntryData.fromJson,
      (d) => d.voidedAt,
      (t, d) => t.id.equals(d.id) & t.voidedAt.isNull(),
      (d) => SupplierLedgerEntriesCompanion(
        voidedAt: Value(d.voidedAt),
        voidedBy: Value(d.voidedBy),
        voidReason: Value(d.voidReason),
        lastUpdatedAt: Value(d.lastUpdatedAt),
      ),
    ),
  ),
  SyncedTable(
    name: 'supplier_crate_ledger',
    tenantScoped: true,
    restore: Restore.ledger(
      (db) => db.supplierCrateLedger,
      SupplierCrateLedgerEntryData.fromJson,
      (d) => d.voidedAt,
      (t, d) => t.id.equals(d.id) & t.voidedAt.isNull(),
      (d) => SupplierCrateLedgerCompanion(
        voidedAt: Value(d.voidedAt),
        voidedBy: Value(d.voidedBy),
        voidReason: Value(d.voidReason),
        lastUpdatedAt: Value(d.lastUpdatedAt),
      ),
    ),
  ),
  SyncedTable(
    name: 'saved_carts',
    tenantScoped: true,
    hardDelete: SyncHardDelete.of(
      (db) => db.savedCarts,
      (t, id) => t.id.equals(id),
      (t, biz) => t.businessId.equals(biz),
      (t, ids) => t.id.isIn(ids),
    ),
    restore: Restore.plain(
      (db) => db.savedCarts,
      SavedCartData.fromJson,
      jsonbColumns: {'cartData'},
    ),
  ),
  SyncedTable(
    name: 'pending_crate_returns',
    tenantScoped: true,
    restore: Restore.plain(
      (db) => db.pendingCrateReturns,
      PendingCrateReturnData.fromJson,
      resilient: true,
    ),
  ),
  SyncedTable(
    name: 'manufacturer_crate_balances',
    isCache: true,
    restore: Restore.naturalKey(
      (db) => db.manufacturerCrateBalances,
      ManufacturerCrateBalance.fromJson,
      (db) => [
        db.manufacturerCrateBalances.businessId,
        db.manufacturerCrateBalances.manufacturerId,
      ],
      (p) => ManufacturerCrateBalancesCompanion(
        id: Value(p.id),
        balance: Value(p.balance),
        lastUpdatedAt: Value(p.lastUpdatedAt),
      ),
    ),
  ),
  SyncedTable(
    name: 'store_crate_balances',
    isCache: true,
    restore: Restore.naturalKey(
      (db) => db.storeCrateBalances,
      StoreCrateBalanceData.fromJson,
      (db) => [
        db.storeCrateBalances.businessId,
        db.storeCrateBalances.storeId,
        db.storeCrateBalances.manufacturerId,
      ],
      (p) => StoreCrateBalancesCompanion(
        id: Value(p.id),
        balance: Value(p.balance),
        lastUpdatedAt: Value(p.lastUpdatedAt),
      ),
    ),
  ),
  SyncedTable(
    name: 'supplier_crate_balances',
    isCache: true,
    restore: Restore.naturalKey(
      (db) => db.supplierCrateBalances,
      SupplierCrateBalanceData.fromJson,
      (db) => [
        db.supplierCrateBalances.businessId,
        db.supplierCrateBalances.supplierId,
        db.supplierCrateBalances.manufacturerId,
      ],
      (p) => SupplierCrateBalancesCompanion(
        id: Value(p.id),
        balance: Value(p.balance),
        lastUpdatedAt: Value(p.lastUpdatedAt),
      ),
    ),
  ),
  SyncedTable(
    name: 'crate_ledger',
    tenantScoped: true,
    restore: Restore.ledger(
      (db) => db.crateLedger,
      CrateLedgerData.fromJson,
      (d) => d.voidedAt,
      (t, d) => t.id.equals(d.id) & t.voidedAt.isNull(),
      (d) => CrateLedgerCompanion(
        voidedAt: Value(d.voidedAt),
        voidedBy: Value(d.voidedBy),
        voidReason: Value(d.voidReason),
        lastUpdatedAt: Value(d.lastUpdatedAt),
      ),
    ),
  ),
  // global config table: keyed by (business_id, key)? — no; keyed by `key`, no
  // LUA. Not tenant-scoped (pull-only). jsonb `value` mirrored as text.
  SyncedTable(
    name: 'system_config',
    restore: Restore.plain(
      (db) => db.systemConfig,
      SystemConfigData.fromJson,
      jsonbColumns: {'value'},
    ),
  ),
  SyncedTable(
    name: 'price_lists',
    tenantScoped: true,
    restore: Restore.plain(
      (db) => db.priceLists,
      PriceListData.fromJson,
      resilient: true,
    ),
  ),
  SyncedTable(
    name: 'payment_transactions',
    tenantScoped: true,
    scrubCreatedAt: true,
    restore: Restore.ledger(
      (db) => db.paymentTransactions,
      PaymentTransactionData.fromJson,
      (d) => d.voidedAt,
      (t, d) => t.id.equals(d.id) & t.voidedAt.isNull(),
      (d) => PaymentTransactionsCompanion(
        voidedAt: Value(d.voidedAt),
        voidedBy: Value(d.voidedBy),
        voidReason: Value(d.voidReason),
        lastUpdatedAt: Value(d.lastUpdatedAt),
      ),
    ),
  ),
  SyncedTable(
    name: 'stock_counts',
    tenantScoped: true,
    restore: Restore.plain(
      (db) => db.stockCounts,
      StockCountData.fromJson,
      resilient: true,
    ),
  ),
  SyncedTable(
    name: 'sessions',
    tenantScoped: true,
    restore: Restore.plain((db) => db.sessions, SessionData.fromJson),
    pushColumns: {
      'id',
      'business_id',
      'user_id',
      'expires_at',
      'revoked_at',
      'created_at',
      'last_updated_at',
      // token, ip_address, user_agent: local secret material, never pushed.
    },
  ),
  SyncedTable(
    name: 'settings',
    tenantScoped: true,
    // Keyed by (business_id, key); align local id to cloud on conflict.
    // NON-resilient (matches historical behaviour — nothing FK-references it).
    restore: Restore.naturalKey(
      (db) => db.settings,
      SettingData.fromJson,
      (db) => [db.settings.businessId, db.settings.key],
      (p) => SettingsCompanion(
        id: Value(p.id),
        value: Value(p.value),
        lastUpdatedAt: Value(p.lastUpdatedAt),
      ),
      resilient: false,
    ),
  ),
];

// ---------------------------------------------------------------------------
// Bespoke restore closures (too table-specific for a helper).
// ---------------------------------------------------------------------------

/// `orders`: plain resilient upsert + §30.8.1 legacy order-number collision
/// heal (a local order holding this cloud order's number under a different id
/// is renumbered so the cloud row and its children can land in this pull).
Future<void> _restoreOrders(
  SyncRestoreExecutor ex,
  String table,
  List<Map<String, dynamic>> rows,
  Set<String>? fkSkipped,
) async {
  for (final r in rows) {
    final data = OrderData.fromJson(r);
    await ex.insertResilient(
      'orders',
      r,
      fkSkipped,
      () => ex.db.into(ex.db.orders).insertOnConflictUpdate(data),
      healUniqueCollision: () => ex.healLocalOrderNumberBlocker(data),
    );
  }
}

/// `users`: manual upsert that never overwrites device-local auth/UI material
/// (PIN hash/salt/iterations, biometrics, avatar). On an existing row only
/// cloud-owned fields are touched; new rows insert with the setup-required PIN
/// sentinel so the row exists for FK targets and the OTP flow can route into
/// PIN setup here.
Future<void> _restoreUsers(
  SyncRestoreExecutor ex,
  String table,
  List<Map<String, dynamic>> rows,
  Set<String>? fkSkipped,
) async {
  final db = ex.db;
  for (final r in rows) {
    final id = r['id'] as String;
    final existing = await (db.select(
      db.users,
    )..where((u) => u.id.equals(id))).getSingleOrNull();

    DateTime parseTs(Object? v, {DateTime? fallback}) {
      if (v is String) return DateTime.parse(v);
      if (v is DateTime) return v;
      return fallback ?? DateTime.now().toUtc();
    }

    final lastUpdatedAt = parseTs(r['lastUpdatedAt']);
    final createdAt = parseTs(r['createdAt'], fallback: lastUpdatedAt);

    if (existing != null) {
      await (db.update(db.users)..where((u) => u.id.equals(id))).write(
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
      await db
          .into(db.users)
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
}

// ===========================================================================
// Derived accessors — the old six constructs, now COMPUTED from the registry
// so they can never disagree. The golden equivalence test pins each against the
// historical literal it replaced.
// ===========================================================================

/// Registry lookup by table name (restore dispatch, push scrub, hard-delete).
final Map<String, SyncedTable> _syncRegistryByName = {
  for (final t in kSyncRegistry) t.name: t,
};

/// The registry entry for [name], or null (unknown / not-synced table).
SyncedTable? syncedTableForName(String name) => _syncRegistryByName[name];

/// Pull / restore / hard-delete-reconcile order == registry order (FK-safe:
/// parents before children).
final List<String> kSyncPullOrder = [for (final t in kSyncRegistry) t.name];

/// The business-scoped tenant tables (create the per-table cursor index + bump
/// trigger at DB-create; enqueue via a DAO). Order is not significant — every
/// consumer treats it as a membership set.
final List<String> kSyncedTenantTables = [
  for (final t in kSyncRegistry)
    if (t.tenantScoped) t.name,
];

/// Phase-D §6.3 caches: enqueued + pushed, but deliberately NOT tenant-scoped
/// (no cursor index / bump trigger). They carry the sync fingerprint, so the
/// registration test treats them as an explicit exemption.
final List<String> kSyncCacheTables = [
  for (final t in kSyncRegistry)
    if (t.isCache) t.name,
];

/// Every table name a DAO may legitimately enqueue: the tenant tables + the
/// caches + `businesses` (which syncs via its own realtime channel and has no
/// `business_id`, so it is not tenant-scoped but IS pushed).
final List<String> kEnqueueableTables = [
  ...kSyncedTenantTables,
  ...kSyncCacheTables,
  'businesses',
];

/// Per-table push-column whitelist (tables absent ⇒ pass-through, no scrub).
final Map<String, Set<String>> kSyncPushColumns = {
  for (final t in kSyncRegistry)
    if (t.pushColumns != null) t.name: t.pushColumns!,
};

/// Append-only ledger tables whose `created_at` must be dropped on every push.
final Set<String> kSyncScrubCreatedAtTables = {
  for (final t in kSyncRegistry)
    if (t.scrubCreatedAt) t.name,
};

/// The hard-delete tables (one per-table rule, reconciled from the two former
/// switches). The reconcile / realtime-DELETE paths look up [SyncHardDelete]
/// via [syncedTableForName].
final Set<String> kHardDeleteReconcileTables = {
  for (final t in kSyncRegistry)
    if (t.hardDelete != null) t.name,
};
