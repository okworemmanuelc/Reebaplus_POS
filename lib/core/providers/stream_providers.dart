/// Shared Drift stream providers.
///
/// Multiple screens that watch the same data share a single stream
/// automatically — Riverpod deduplicates by provider identity.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/theme_notifier.dart';
import 'package:reebaplus_pos/core/utils/business_time.dart';
import 'package:reebaplus_pos/shared/utils/role_display.dart';

// ── Orders ──────────────────────────────────────────────────────────────────
final allOrdersProvider = StreamProvider<List<OrderWithItems>>((ref) {
  return ref.watch(orderServiceProvider).watchAllOrdersWithItems();
});

// ── Stores ──────────────────────────────────────────────────────────────────
final allStoresProvider = StreamProvider<List<StoreData>>((ref) {
  return ref.watch(databaseProvider).storesDao.watchActiveStores();
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

/// Products with stock totals for a store scope, where the key may be null to
/// mean "All Stores". Drives the Product Details screen's realtime refresh so a
/// product edit / stock change syncing in from another device updates the open
/// detail view live (§5).
final productsWithStockProvider =
    StreamProvider.family<List<ProductDataWithStock>, String?>((ref, storeId) {
  return ref
      .watch(databaseProvider)
      .inventoryDao
      .watchProductsWithStock(storeId: storeId);
});

// ── Categories ──────────────────────────────────────────────────────────────
final allCategoriesProvider = StreamProvider<List<CategoryData>>((ref) {
  return ref.watch(databaseProvider).inventoryDao.watchAllCategories();
});

// ── Manufacturers ───────────────────────────────────────────────────────────
final allManufacturersProvider =
    StreamProvider<List<ManufacturerData>>((ref) {
  final db = ref.watch(databaseProvider);
  // Business-scoped via the DAO so a device holding more than one business's
  // data can't surface another business's manufacturers.
  return db.inventoryDao.watchAllManufacturers();
});

// ── Store by id ─────────────────────────────────────────────────────────────
/// Streams a single store row keyed by id. Returns null when the
/// store hasn't loaded yet or has been (soft-)deleted. Used wherever
/// a screen needs to display the *active* store and have it auto-update
/// when the cloud renames or marks it deleted.
final storeByIdProvider =
    StreamProvider.family<StoreData?, String>((ref, storeId) {
  final db = ref.watch(databaseProvider);
  // Business-scoped lookup (DAO filters by current business + id).
  return db.storesDao.watchStore(storeId);
});

// ── Roles & permissions (master plan §2.4, schema v13) ─────────────────────

/// All non-deleted roles for the current business, sorted by role tier
/// (CEO → Manager → Cashier → Stock keeper) via [roleRank]. This is the
/// canonical display order for roles across the whole app — any UI that lists
/// roles must come through this provider (or otherwise sort by [roleRank]) so
/// the tier order is consistent everywhere.
final allRolesProvider = StreamProvider<List<RoleData>>((ref) {
  return ref.watch(databaseProvider).rolesDao.watchAll().map(
        (roles) => roles.toList()
          ..sort((a, b) => roleRank(a.slug).compareTo(roleRank(b.slug))),
      );
});

// ── Appearance (business accent colour, §10.1) ──────────────────────────────

/// Settings key for the CEO-chosen business accent (synced). Value is the
/// [DesignSystem] enum name: 'amber' | 'blue' | 'purple' | 'green'.
const kBusinessDesignSystemKey = 'business_design_system';

DesignSystem? _parseDesignSystem(String? v) {
  if (v == null) return null;
  try {
    return DesignSystem.values.byName(v);
  } catch (_) {
    return null;
  }
}

/// The business-wide accent colour, streamed from the synced `settings` row.
/// Null when no session is bound (pre-login) or the key is unset/invalid — the
/// app-root bridge then leaves the device's themeController value alone (amber
/// default). The null-session guard is required because `settingsDao.watch`
/// calls `requireBusinessId()`, which throws without a business.
final businessDesignSystemProvider = StreamProvider<DesignSystem?>((ref) {
  ref.watch(authProvider); // re-subscribe when the session binds / unbinds
  final db = ref.watch(databaseProvider);
  if (db.currentBusinessId == null) return Stream.value(null);
  return db.settingsDao.watch(kBusinessDesignSystemKey).map(_parseDesignSystem);
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

/// All memberships for the current business — drives Staff Management.
final userBusinessesProvider =
    StreamProvider<List<UserBusinessData>>((ref) {
  return ref
      .watch(databaseProvider)
      .userBusinessesDao
      .watchForCurrentBusiness();
});

/// Active staff (user + role) for a given business — drives the Who Is
/// Working picker (master plan §8). Keyed by an explicit businessId because
/// the picker renders before sign-in, when the session has no current
/// business; the session-scoped [userBusinessesProvider] can't be used there.
final activeStaffProvider =
    StreamProvider.family<List<WhoIsWorkingEntry>, String>((ref, businessId) {
  return ref
      .watch(databaseProvider)
      .userBusinessesDao
      .watchActiveStaffForBusiness(businessId);
});

/// Stores the given user is assigned to.
final myUserStoresProvider =
    StreamProvider.family<List<UserStoreData>, String>((ref, userId) {
  return ref.watch(databaseProvider).userStoresDao.watchForUser(userId);
});

/// All users in the current business, keyed by id — joins to
/// [userBusinessesProvider] so Staff Management can render each
/// membership's name/avatar. Read-only (no synced write); businessId
/// is the current session's via the Drift business resolver.
final usersByBusinessProvider =
    StreamProvider<Map<String, UserData>>((ref) {
  final db = ref.watch(databaseProvider);
  final businessId = db.currentBusinessId;
  if (businessId == null) {
    return Stream<Map<String, UserData>>.value(const {});
  }
  return (db.select(db.users)..where((t) => t.businessId.equals(businessId)))
      .watch()
      .map((rows) => {for (final u in rows) u.id: u});
});

// ── Role badge resolver (master plan §8.2) ──────────────────────────────────

/// Every role on this device, NOT scoped to the current session — role ids
/// are globally unique, so [userRoleProvider] resolves a role by id even
/// before login binds a business.
final _allRolesUnscopedProvider = StreamProvider<List<RoleData>>((ref) {
  return ref.watch(databaseProvider).rolesDao.watchAllUnscoped();
});

/// Memberships for a given user, NOT scoped to the current session.
final _userMembershipsProvider =
    StreamProvider.family<List<UserBusinessData>, String>((ref, userId) {
  return ref.watch(databaseProvider).userBusinessesDao.watchForUser(userId);
});

/// The [RoleData] for a user, reactive across both membership and role-table
/// changes. Resolves by user id so it works before `setCurrentUser` binds a
/// business (the shared-PIN picker, master plan §8.4). Returns null until the
/// membership + role rows are present locally — on a fresh device they arrive
/// via the post-login background pull, so callers must render a graceful
/// fallback while it's null.
final userRoleProvider = Provider.family<RoleData?, String>((ref, userId) {
  final roles = ref.watch(_allRolesUnscopedProvider).valueOrNull;
  final memberships = ref.watch(_userMembershipsProvider(userId)).valueOrNull;
  if (roles == null || memberships == null || memberships.isEmpty) return null;

  // Once a business is bound, resolve the role for THAT business — never an
  // arbitrary membership. A multi-business email can have >1 membership locally;
  // picking `memberships.first` could surface another business's role under the
  // active one. Before bind (shared-PIN Who's-Working picker, §8.4) fall back to
  // the first membership (Phase-1: one membership per user on the happy path).
  final boundBusinessId = ref.watch(authProvider).currentUser?.businessId;
  UserBusinessData? membership;
  if (boundBusinessId != null) {
    for (final m in memberships) {
      if (m.businessId == boundBusinessId) {
        membership = m;
        break;
      }
    }
  }
  membership ??= memberships.first;
  final roleId = membership.roleId;
  for (final r in roles) {
    if (r.id == roleId) return r;
  }
  return null;
});

/// Active (unused, unrevoked, unexpired) invite codes for the current
/// business — drives the Invites tab in Staff Management.
final activeInviteCodesProvider =
    StreamProvider<List<InviteCodeData>>((ref) {
  return ref.watch(databaseProvider).inviteCodesDao.watchActive();
});

// ── Current-user role & permission checks (PIVOT_PLAN step 8A) ───────────────

/// The [RoleData] for the currently logged-in user. Resolves the session
/// user's id via [authProvider] and reuses [userRoleProvider]. Returns null
/// while no one is logged in or before the membership + role rows have
/// arrived locally — callers must render a graceful fallback while null.
final currentUserRoleProvider = Provider<RoleData?>((ref) {
  final userId = ref.watch(authProvider).currentUser?.id;
  if (userId == null) return null;
  return ref.watch(userRoleProvider(userId));
});

/// The set of permission keys granted to the current user's role (e.g.
/// `staff.invite`, `sales.make`). Empty until the role + its grants are
/// resolved locally. Use [hasPermission] for a single-key check.
final currentUserPermissionsProvider = Provider<Set<String>>((ref) {
  final role = ref.watch(currentUserRoleProvider);
  if (role == null) return const <String>{};
  final grants = ref.watch(rolePermissionsProvider(role.id)).valueOrNull;
  if (grants == null) return const <String>{};
  return grants.map((g) => g.permissionKey).toSet();
});

/// True if the current user's role grants [key]. Thin reader over
/// [currentUserPermissionsProvider] — reused by every role-gated screen,
/// button, and action (CLAUDE.md hard rule #6). Hide, don't disable, when
/// this returns false (hard rule #7).
bool hasPermission(WidgetRef ref, String key) {
  return ref.watch(currentUserPermissionsProvider).contains(key);
}

// ── Discount cap (master plan §12.6 / §13.2) ─────────────────────────────────

/// `role_settings` key holding the max discount % a role may apply in the
/// Cart. Stored on each role row by CEO Settings; shared here so the Cart
/// reads the same key the settings screen writes.
const kMaxDiscountPercentKey = 'max_discount_percent';

/// The max discount percentage the currently logged-in user may apply on a
/// cart line (§13.2). Reads the stored `max_discount_percent` on the user's
/// role; falls back to the seed defaults (CEO 100, Manager 10, others 0) when
/// the setting row hasn't been written yet. Returns 0 (no discount) until the
/// role resolves locally — the safe default for an unresolved role.
final currentUserMaxDiscountPercentProvider = Provider<int>((ref) {
  final role = ref.watch(currentUserRoleProvider);
  if (role == null) return 0;
  int seedDefault() {
    switch (role.slug) {
      case 'ceo':
        return 100;
      case 'manager':
        return 10;
      default:
        return 0;
    }
  }

  final settings = ref.watch(roleSettingsProvider(role.id)).valueOrNull;
  if (settings == null) return seedDefault();
  final stored = settings
      .where((s) => s.settingKey == kMaxDiscountPercentKey)
      .map((s) => s.settingValue)
      .firstOrNull;
  return int.tryParse(stored ?? '') ?? seedDefault();
});

// ── Manager cross-store view toggle (master plan §11.2 / §10.2) ──────────────

/// `role_settings` key for the CEO toggle that unlocks the Home store picker
/// for Managers. Stored on the Manager role row; value is `'true'`/`'false'`.
/// Shared by the settings toggle and the Home screen so both agree on the key.
const kManagerViewAllStoresKey = 'manager_view_all_stores';

/// Whether the currently logged-in Manager may view other stores on Home.
/// True only when the current user's role is Manager AND the CEO has flipped
/// [kManagerViewAllStoresKey] ON. Other roles get false here — their store
/// access is decided by Home directly from the role slug (the CEO always gets
/// the free picker; Cashier/Stock keeper are always locked).
final managerCanViewAllStoresProvider = Provider<bool>((ref) {
  final role = ref.watch(currentUserRoleProvider);
  if (role == null || role.slug != 'manager') return false;
  final settings = ref.watch(roleSettingsProvider(role.id)).valueOrNull;
  if (settings == null) return false;
  for (final s in settings) {
    if (s.settingKey == kManagerViewAllStoresKey) {
      return s.settingValue == 'true';
    }
  }
  return false;
});

// ── Funds Register (master plan §23) ─────────────────────────────────────────

/// Today's business-day calendar date (`YYYY-MM-DD`) in the business timezone.
/// The single definition shared by the POS Open-Day gate, the Open Day flow,
/// and the live balances view so they always agree on "today". Computed from
/// the business timezone, never the raw device clock (R3 in the plan).
final todaysBusinessDateProvider = FutureProvider<String>((ref) async {
  final db = ref.watch(databaseProvider);
  final bizId = db.currentBusinessId;
  final tz = bizId == null ? 'UTC' : await getBusinessTimezone(db, bizId);
  final now = DateTime.now();
  // An always-on shared till must re-gate and re-bucket sales when the local
  // day rolls over. A FutureProvider caches its value forever, so without this
  // the till stays stuck on the day it was opened — POS keeps selling into the
  // new calendar day without a fresh Open Day, and sales bucket under the old
  // date (Hard Rule #11 / Funds plan R3). Self-invalidate just after the next
  // business-day boundary so watchers recompute "today".
  final timer = Timer(
    untilNextBusinessDay(now, tz) + const Duration(seconds: 2),
    ref.invalidateSelf,
  );
  ref.onDispose(timer.cancel);
  return businessDateString(now, tz);
});

/// Active funds accounts for a store (Cash Till first). Drives the Accounts
/// list and the checkout receiving-account picker.
final fundsAccountsForStoreProvider =
    StreamProvider.family<List<FundsAccountData>, String>((ref, storeId) {
  return ref
      .watch(databaseProvider)
      .fundsAccountsDao
      .watchActiveAccountsForStore(storeId);
});

/// Whether the day is open for (store, businessDate) — THE POS gate.
final isDayOpenProvider =
    StreamProvider.family<bool, ({String storeId, String businessDate})>(
        (ref, key) {
  return ref
      .watch(databaseProvider)
      .fundDaysDao
      .watchIsDayOpen(key.storeId, key.businessDate);
});

/// Live per-account expected balances (kobo) for (store, businessDate).
final fundDayBalancesProvider = StreamProvider.family<Map<String, int>,
    ({String storeId, String businessDate})>((ref, key) {
  return ref
      .watch(databaseProvider)
      .fundTransactionsDao
      .watchStoreBalancesForDay(key.storeId, key.businessDate);
});
