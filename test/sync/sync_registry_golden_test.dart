// sync_registry_golden_test.dart
//
// Golden equivalence test for the `SyncedTable` registry (issue #15).
//
// Before the registry, six per-table constructs held the truth about a table's
// sync behaviour, scattered across two files: the synced-tenant-table list, the
// pull order, the push-column whitelist, the created_at-scrub set, and the two
// hard-delete switches. This test FREEZES the exact values those constructs had
// the moment before they were collapsed into the registry, and asserts the
// registry's derived accessors reproduce each — byte-for-byte for the ordered
// pull sequence and the push map, and set-for-set for the membership lists.
//
// It is the highest-possible seam for "the data facts did not drift": it
// exercises the registry's public output directly, with no database spin-up. It
// also guards the DERIVATION — if computing the tenant-table list ever drops a
// table, or the pull order reorders, this goes red here instead of silently in
// production (a forgotten sync path = a peer device that never receives a whole
// class of rows).
//
// The seventh construct — the restore switch — is a BEHAVIOUR, not a data fact,
// and is guarded by the existing behavioural tests that drive
// `restoreTableDataForTesting` / `reconcileHardDeletesForTesting` unchanged
// (outbox_sacred_restore, restore_fk_resilience, snapshot_reconcile_hard_delete,
// the per-table dispatch tests). FK-resilient-or-not is likewise a behaviour and
// stays pinned by restore_fk_resilience_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';

void main() {
  // === FROZEN GOLDEN DATA =================================================
  // The literal values the six constructs held at the moment of collapse. Do
  // NOT "fix" these to match a registry change — a diff here means the registry
  // changed a sync fact, which is exactly what this test exists to surface for
  // deliberate review. A legitimate change updates BOTH sides in one commit.

  // 1) Pull / restore / reconcile order — an ORDERED sequence (FK-safe).
  const goldenPullOrder = <String>[
    'businesses',
    'crate_size_groups',
    'manufacturers',
    'stores',
    'users',
    'roles',
    'role_settings',
    'role_permissions',
    'user_permission_overrides',
    'store_role_permissions',
    'user_businesses',
    'user_stores',
    'invite_codes',
    'profiles',
    'categories',
    'suppliers',
    'products',
    'inventory',
    'cost_batches',
    'customers',
    'orders',
    'order_items',
    'order_crate_lines',
    'shipments',
    'purchase_items',
    'expense_categories',
    'expenses',
    'expense_budgets',
    'customer_crate_balances',
    'delivery_receipts',
    'drivers',
    'stock_transfers',
    'stock_adjustments',
    'stock_adjustment_requests',
    'quick_sale_requests',
    'activity_logs',
    'error_logs',
    'notifications',
    'stock_transactions',
    'customer_wallets',
    'wallet_transactions',
    'supplier_ledger_entries',
    'supplier_crate_ledger',
    'saved_carts',
    'pending_crate_returns',
    'manufacturer_crate_balances',
    'store_crate_balances',
    'supplier_crate_balances',
    'crate_ledger',
    'system_config',
    'price_lists',
    'payment_transactions',
    'stock_counts',
    'sessions',
    'settings',
  ];

  // 2) The synced tenant tables (membership set; order not significant).
  const goldenTenantTables = <String>{
    'users',
    'sessions',
    'stores',
    'manufacturers',
    'crate_size_groups',
    'categories',
    'suppliers',
    'supplier_ledger_entries',
    'supplier_crate_ledger',
    'products',
    'cost_batches',
    'price_lists',
    'customers',
    'customer_wallets',
    'wallet_transactions',
    'crate_ledger',
    'stock_transfers',
    'stock_adjustments',
    'stock_transactions',
    'stock_adjustment_requests',
    'quick_sale_requests',
    'orders',
    'order_items',
    'order_crate_lines',
    'shipments',
    'purchase_items',
    'drivers',
    'delivery_receipts',
    'saved_carts',
    'pending_crate_returns',
    'payment_transactions',
    'stock_counts',
    'expense_categories',
    'expenses',
    'expense_budgets',
    'activity_logs',
    'error_logs',
    'notifications',
    'settings',
    'roles',
    'role_permissions',
    'user_permission_overrides',
    'store_role_permissions',
    'role_settings',
    'user_businesses',
    'invite_codes',
    'user_stores',
  };

  // 3) The Phase-D caches (enqueued + pushed, but not tenant-scoped).
  const goldenCacheTables = <String>{
    'inventory',
    'customer_crate_balances',
    'manufacturer_crate_balances',
    'store_crate_balances',
    'supplier_crate_balances',
  };

  // 4) The push-column whitelist — only the tables that diverge from cloud.
  const goldenPushColumns = <String, Set<String>>{
    // #159: `empty_crate_stock` is DEMOTED off the push set — the physical
    // empties pool is derived from the append-only `crate_ledger`, so the
    // absolute scalar never crosses the wire. This whitelist is every
    // manufacturers column EXCEPT `empty_crate_stock`.
    'manufacturers': {
      'id',
      'business_id',
      'name',
      'deposit_amount_kobo',
      'is_deleted',
      'created_at',
      'last_updated_at',
    },
    'profiles': {
      'id',
      'business_id',
      'role',
      'role_tier',
      'name',
      'created_at',
      'last_updated_at',
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
    },
    'sessions': {
      'id',
      'business_id',
      'user_id',
      'expires_at',
      'revoked_at',
      'created_at',
      'last_updated_at',
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
    },
  };

  // 5) The append-only ledger created_at-scrub set.
  const goldenScrubCreatedAt = <String>{
    'payment_transactions',
    'wallet_transactions',
    'supplier_ledger_entries',
  };

  // 6) The hard-delete tables (the two former switches, one set now).
  const goldenHardDelete = <String>{
    'role_permissions',
    'user_permission_overrides',
    'store_role_permissions',
    'user_stores',
    'saved_carts',
    'notifications',
  };

  // === ASSERTIONS =========================================================

  test('pull order sequence reproduces the frozen construct byte-for-byte', () {
    expect(kSyncPullOrder, goldenPullOrder);
  });

  test('synced tenant tables reproduce the frozen set', () {
    expect(kSyncedTenantTables.toSet(), goldenTenantTables);
    // No duplicates snuck into the derivation.
    expect(kSyncedTenantTables.length, kSyncedTenantTables.toSet().length);
  });

  test('cache tables reproduce the frozen set', () {
    expect(kSyncCacheTables.toSet(), goldenCacheTables);
  });

  test('push-column whitelist reproduces the frozen map', () {
    expect(kSyncPushColumns, goldenPushColumns);
  });

  test('created_at-scrub set reproduces the frozen set', () {
    expect(kSyncScrubCreatedAtTables, goldenScrubCreatedAt);
  });

  test('hard-delete reconcile set reproduces the frozen set', () {
    expect(kHardDeleteReconcileTables, goldenHardDelete);
  });

  test('enqueueable tables = tenant ∪ cache ∪ {businesses}', () {
    expect(
      kEnqueueableTables.toSet(),
      {...goldenTenantTables, ...goldenCacheTables, 'businesses'},
    );
  });

  // The pull order is the union of every construct's tables — it is the one
  // place all of them appear. This pins that nothing was dropped from the
  // registry when the constructs collapsed into it.
  test('every construct table appears in the pull order', () {
    final order = kSyncPullOrder.toSet();
    for (final t in goldenTenantTables) {
      expect(order, contains(t), reason: 'tenant table $t missing from pull order');
    }
    for (final t in goldenCacheTables) {
      expect(order, contains(t), reason: 'cache table $t missing from pull order');
    }
    for (final t in goldenPushColumns.keys) {
      expect(order, contains(t), reason: 'push-whitelist table $t missing from pull order');
    }
    for (final t in goldenScrubCreatedAt) {
      expect(order, contains(t), reason: 'scrub table $t missing from pull order');
    }
    for (final t in goldenHardDelete) {
      expect(order, contains(t), reason: 'hard-delete table $t missing from pull order');
    }
  });
}
