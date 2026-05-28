/// Shared Drift stream providers.
///
/// Multiple screens that watch the same data share a single stream
/// automatically — Riverpod deduplicates by provider identity.
library;

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';

// ── Orders ──────────────────────────────────────────────────────────────────
final allOrdersProvider = StreamProvider<List<OrderWithItems>>((ref) {
  return ref.watch(orderServiceProvider).watchAllOrdersWithItems();
});

// ── Stores ──────────────────────────────────────────────────────────────────
final allStoresProvider = StreamProvider<List<StoreData>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.select(db.stores).watch();
});

// ── Expenses ───────────────────────────────────────────────────────────────
final allExpensesProvider = StreamProvider<List<ExpenseWithCategory>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.expensesDao.watchAll();
});


/// Map of expense category id → name. Resolves the category text for display
/// after the cached `expenses.category` column was removed.
final expenseCategoryNamesProvider =
    StreamProvider<Map<String, String>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.expensesDao
      .watchAllCategories()
      .map((cats) => {for (final c in cats) c.id: c.name});
});

// ── Products by store ───────────────────────────────────────────────────────
final productsByStoreProvider =
    StreamProvider.family<List<ProductDataWithStock>, String>((ref, storeId) {
  return ref
      .watch(databaseProvider)
      .inventoryDao
      .watchProductDatasWithStockByStore(storeId);
});

// ── Categories ──────────────────────────────────────────────────────────────
final allCategoriesProvider = StreamProvider<List<CategoryData>>((ref) {
  return ref.watch(databaseProvider).inventoryDao.watchAllCategories();
});

// ── Manufacturers ───────────────────────────────────────────────────────────
final allManufacturersProvider =
    StreamProvider<List<ManufacturerData>>((ref) {
  final db = ref.watch(databaseProvider);
  return (db.select(db.manufacturers)
        ..where((t) => t.isDeleted.equals(false))
        ..orderBy([(t) => OrderingTerm(expression: t.name)]))
      .watch();
});

// ── Store by id ─────────────────────────────────────────────────────────────
/// Streams a single store row keyed by id. Returns null when the
/// store hasn't loaded yet or has been (soft-)deleted. Used wherever
/// a screen needs to display the *active* store and have it auto-update
/// when the cloud renames or marks it deleted.
final storeByIdProvider =
    StreamProvider.family<StoreData?, String>((ref, storeId) {
  final db = ref.watch(databaseProvider);
  return (db.select(db.stores)
        ..where((t) => t.id.equals(storeId))
        ..limit(1))
      .watchSingleOrNull();
});

// ── Roles & permissions (master plan §2.4, schema v13) ─────────────────────

/// All non-deleted roles for the current business, ordered system
/// defaults first (CEO → Manager → Cashier → Stock keeper).
final allRolesProvider = StreamProvider<List<RoleData>>((ref) {
  return ref.watch(databaseProvider).rolesDao.watchAll();
});

/// Global permissions catalog. Identical on every device and every
/// business — seeded by migration, never written at runtime.
final allPermissionsProvider = StreamProvider<List<PermissionData>>((ref) {
  return ref.watch(databaseProvider).permissionsDao.watchAll();
});

/// Granted permissions for a specific role.
final rolePermissionsProvider =
    StreamProvider.family<List<RolePermissionData>, String>((ref, roleId) {
  return ref.watch(databaseProvider).rolePermissionsDao.watchForRole(roleId);
});

/// Per-role tunable settings (max discount %, max expense approval kobo).
final roleSettingsProvider =
    StreamProvider.family<List<RoleSettingData>, String>((ref, roleId) {
  return ref.watch(databaseProvider).roleSettingsDao.watchForRole(roleId);
});

/// All memberships for the current business — drives Staff Management
/// and the Who Is Working picker.
final userBusinessesProvider =
    StreamProvider<List<UserBusinessData>>((ref) {
  return ref
      .watch(databaseProvider)
      .userBusinessesDao
      .watchForCurrentBusiness();
});

/// Stores the given user is assigned to.
final myUserStoresProvider =
    StreamProvider.family<List<UserStoreData>, String>((ref, userId) {
  return ref.watch(databaseProvider).userStoresDao.watchForUser(userId);
});

/// Active (unused, unrevoked, unexpired) invite codes for the current
/// business — drives the Invites tab in Staff Management.
final activeInviteCodesProvider =
    StreamProvider<List<InviteCodeData>>((ref) {
  return ref.watch(databaseProvider).inviteCodesDao.watchActive();
});
