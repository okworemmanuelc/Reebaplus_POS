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
import 'package:reebaplus_pos/core/diagnostics/sync_diagnostic.dart';

void main() {
  test('#472 category mapping stays in tenant sync; public reference stays out', () {
    expect(kSyncedTenantTables, contains('categories'));
    expect(kSyncedTenantTables, isNot(contains('marketplace_categories')));
    final row = CategoryData.fromJson({
      'id': 'category', 'businessId': 'business', 'name': 'Phones',
      'marketplaceCategory': 'phones', 'isDeleted': false,
      'createdAt': DateTime.utc(2026).millisecondsSinceEpoch,
      'lastUpdatedAt': DateTime.utc(2026).millisecondsSinceEpoch,
    });
    expect(row.marketplaceCategory, 'phones');
  });
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
    // #423: per-store delivery areas, right after their parent store.
    'store_delivery_areas',
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
    // #474: gallery photos, right after their parent product.
    'product_photos',
    'inventory',
    'cost_batches',
    'customers',
    // #141 Van Sales: the trip, then its priced load lots, then the ledger rows
    // that reference both (FK-safe among themselves; stores/users/products are
    // pulled far earlier).
    //
    // #142 MOVED this block from after `daily_closings` to HERE, ahead of
    // `orders` and `payment_transactions`. Both of those now carry a
    // `van_trip_id` FK — payment_transactions since #144's remittance, orders
    // since #142's trip tag — and both restore RESILIENTLY, so a trip arriving
    // after its child would not raise: it would silently DROP a money row on
    // every restore. Parents first.
    // #143 inserted `van_return_events` between the lots and the ledger: its
    // parent is `van_trips` (above it) and the ledger rows that reference a
    // return event come after it.
    'van_trips',
    'van_trip_lots',
    'van_return_events',
    'driver_ledger_entries',
    'orders',
    'order_items',
    'order_crate_lines',
    // #426: Online Orders + lines, after their parents.
    'online_orders',
    'online_order_lines',
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
    // #212 (PRD #203): the crate-deposit money approval queue and the
    // append-only Placed Deposit ledger. The queue precedes the ledger, which
    // FK-references it.
    'supplier_crate_deposit_requests',
    'supplier_crate_deposits',
    // #216 (PRD #203): the Crate Shortfall write-off ledger — the deliberate,
    // dated acceptance of a loss. Append-only, no void columns, so it restores
    // INSERT-OR-IGNORE like the Placed Deposit ledger above it.
    'crate_shortfall_writeoffs',
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
    // #174: persisted day close — one snapshot per (business, calendar day).
    'daily_closings',
    'sessions',
    'settings',
  ];

  // 2) The synced tenant tables (membership set; order not significant).
  const goldenTenantTables = <String>{
    'users',
    'sessions',
    'stores',
    'store_delivery_areas', // #423
    'manufacturers',
    'crate_size_groups',
    'categories',
    'suppliers',
    'supplier_ledger_entries',
    'supplier_crate_ledger',
    // #212 (PRD #203): the crate-deposit money tables.
    'supplier_crate_deposit_requests',
    'supplier_crate_deposits',
    // #216 (PRD #203): the Crate Shortfall write-off ledger.
    'crate_shortfall_writeoffs',
    'products',
    'product_photos', // #474
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
    'online_orders', // #426
    'online_order_lines', // #426
    'shipments',
    'purchase_items',
    'drivers',
    'delivery_receipts',
    'saved_carts',
    'pending_crate_returns',
    'payment_transactions',
    'stock_counts',
    // #174: persisted day close snapshot.
    'daily_closings',
    // #141 Van Sales: trip aggregate, priced load lots, consignment ledger.
    // #143 added the dated return events (good = credit + re-batch, damaged =
    // loss at snapshotted cost).
    'van_trips',
    'van_trip_lots',
    'van_return_events',
    'driver_ledger_entries',
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
    // #211: `crate_money_arrangement` IS pushed — an owner-chosen money policy
    // has to reach every other device, exactly like `deposit_amount_kobo`.
    'manufacturers': {
      'id',
      'business_id',
      'name',
      'deposit_amount_kobo',
      'crate_money_arrangement',
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
    // #427: the shop's answer pushes only what it may change plus the NOT
    // NULL placement text; cloud-owned timestamps / total / note stay off.
    'online_orders': {
      'id',
      'business_id',
      'store_id',
      'reference',
      'shopper_name',
      'delivery_phone',
      'delivery_state',
      'delivery_lga',
      'delivery_street',
      'status',
      'customer_id',
      'decline_reason',
      'cancel_reason',
      'linked_order_id',
      'responded_at',
      'last_updated_at',
    },
    'online_order_lines': {
      'id',
      'business_id',
      'online_order_id',
      'product_id',
      'product_name',
      'unit_price_kobo',
      'requested_qty',
      'accepted_qty',
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
      'sells_one_price',
      'created_at',
      'last_updated_at',
    },
  };

  // 5) The append-only ledger created_at-scrub set. #169 added the two crate
  //    ledgers preemptively (close the void-push orphan trap before any void
  //    feature ships).
  const goldenScrubCreatedAt = <String>{
    'payment_transactions',
    'wallet_transactions',
    'supplier_ledger_entries',
    'crate_ledger',
    'supplier_crate_ledger',
    // #141: the driver consignment ledger — append-only, void by an
    // opposite-sign compensating row, so the same created_at trap applies.
    'driver_ledger_entries',
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

  // === #572 — the per-table maps that lived OUTSIDE the registry ===========
  // Frozen literals of the constructs moved onto SyncedTable fields by #572
  // (supabase_sync_service: _tablePushPriority, _naturalKeyPushConflictTargets,
  // _deferrableTables, _targetedParentFkFields, _onlineOrderAnswerTables;
  // app_database: kWithdrawableReversalTables, _softDeletableTables,
  // _ledgerTables; sync_diagnostic: SyncDiagnostic.tables). Same rule as above:
  // a diff here is a sync/schema fact change — update BOTH sides deliberately.
  group('#572 moved per-table maps', () {
    const goldenPushPriority = <String, int>{
      'businesses': 0,
      'profiles': 1,
      'users': 1,
      'stores': 2,
      'manufacturers': 3,
      'crate_size_groups': 3,
      'categories': 4,
      'suppliers': 5,
      'products': 10,
      'customers': 11,
      'inventory': 12,
      'customer_wallets': 20,
      'orders': 30,
      'order_items': 31,
      'wallet_transactions': 32,
      'crate_ledger': 33,
      'store_crate_balances': 35,
      'supplier_crate_ledger': 36,
      'system_config': 50,
    };
    const goldenConflictTargets = <String, String>{
      'store_crate_balances': 'business_id,store_id,manufacturer_id',
    };
    const goldenDeferrable = <String>{
      'stock_transactions',
      'sessions',
      'activity_logs',
      'error_logs',
      'notifications',
      'payment_transactions',
      'crate_ledger',
      'supplier_crate_ledger',
    };
    const goldenTargetedParentFkFields = <String, String>{
      'supplierId': 'suppliers',
      'categoryId': 'categories',
      'manufacturerId': 'manufacturers',
    };
    const goldenOnlineOrderAnswer = <String>{
      'online_orders',
      'online_order_lines',
    };
    const goldenWithdrawable = <String>{
      'stock_transactions',
      'stock_adjustments',
      'payment_transactions',
      'wallet_transactions',
      'crate_ledger',
      'cost_batches',
    };
    const goldenSoftDeletable = <String>[
      'stores',
      'manufacturers',
      'crate_size_groups',
      'categories',
      'suppliers',
      'products',
      'price_lists',
      'customers',
      'customer_wallets',
      'drivers',
      'expense_categories',
      'expenses',
      'expense_budgets',
      'roles',
      'invite_codes',
    ];
    const goldenLedgerImmutableColumns = <String, List<String>>{
      'stock_transactions': [
        'id',
        'business_id',
        'product_id',
        'location_id',
        'quantity_delta',
        'movement_type',
        'order_id',
        'transfer_id',
        'adjustment_id',
        'shipment_id',
        'performed_by',
        'created_at',
      ],
      'wallet_transactions': [
        'id',
        'business_id',
        'wallet_id',
        'customer_id',
        'type',
        'amount_kobo',
        'signed_amount_kobo',
        'reference_type',
        'order_id',
        'performed_by',
        'customer_verified',
        'created_at',
      ],
      'supplier_ledger_entries': [
        'id',
        'business_id',
        'supplier_id',
        'store_id',
        'type',
        'amount_kobo',
        'signed_amount_kobo',
        'reference_type',
        'payment_method',
        'receipt_path',
        'reference_note',
        'activity_date',
        'performed_by',
        'created_at',
      ],
      'payment_transactions': [
        'id',
        'business_id',
        'store_id',
        'amount_kobo',
        'method',
        'type',
        'order_id',
        'shipment_id',
        'expense_id',
        'wallet_txn_id',
        'delivery_id',
        'van_trip_id',
        'crate_deposit_id',
        'performed_by',
        'created_at',
      ],
      'activity_logs': [
        'id',
        'business_id',
        'user_id',
        'action',
        'description',
        'entity_type',
        'entity_id',
        'before_json',
        'after_json',
        'store_id',
        'created_at',
      ],
      'crate_ledger': [
        'id',
        'business_id',
        'customer_id',
        'manufacturer_id',
        'crate_size_group_id',
        'quantity_delta',
        'movement_type',
        'reference_order_id',
        'reference_return_id',
        'performed_by',
        'rate_per_crate_kobo',
        'reason',
        'created_at',
      ],
      'driver_ledger_entries': [
        'id',
        'business_id',
        'driver_user_id',
        'trip_id',
        'type',
        'amount_kobo',
        'signed_amount_kobo',
        'reference_type',
        'reference_id',
        'payment_method',
        'receipt_path',
        'reference_note',
        'activity_date',
        'performed_by',
        'created_at',
      ],
      'supplier_crate_ledger': [
        'id',
        'business_id',
        'supplier_id',
        'manufacturer_id',
        'store_id',
        'quantity_delta',
        'movement_type',
        'deposit_paid_kobo',
        'note',
        'performed_by',
        'created_at',
      ],
      'supplier_crate_deposits': [
        'id',
        'business_id',
        'supplier_id',
        'manufacturer_id',
        'store_id',
        'movement_type',
        'signed_amount_kobo',
        'crate_count',
        'rate_per_crate_kobo',
        'request_id',
        'supplier_crate_ledger_id',
        'note',
        'performed_by',
        'created_at',
      ],
      'crate_shortfall_writeoffs': [
        'id',
        'business_id',
        'manufacturer_id',
        'store_id',
        'crate_count',
        'rate_per_crate_kobo',
        'note',
        'source',
        'performed_by',
        'created_at',
      ],
    };
    // The old SyncDiagnostic.tables literal. It was a stale hand-copy of the
    // pull order (it even listed the long-gone `invites` table); the derived
    // list must still cover every real table it named.
    const goldenDiagnosticTables = <String>[
      'stores', 'manufacturers', 'crate_size_groups', 'categories',
      'suppliers', 'products', 'inventory', 'customers', 'customer_wallets',
      'orders', 'order_items', 'wallet_transactions', 'expenses',
      'expense_categories', 'customer_crate_balances', 'delivery_receipts',
      'drivers', 'stock_transfers', 'stock_adjustments', 'activity_logs',
      'notifications', 'stock_transactions', 'saved_carts',
      'pending_crate_returns', 'invites',
    ];

    test('push priority reproduces the frozen map', () {
      expect(kSyncPushPriority, goldenPushPriority);
    });

    test('natural-key conflict targets reproduce the frozen map', () {
      expect(kSyncPushConflictTargets, goldenConflictTargets);
    });

    test('deferrable tables reproduce the frozen set', () {
      expect(kSyncDeferrableTables, goldenDeferrable);
    });

    test('targeted-parent FK fields reproduce the frozen map', () {
      expect(kSyncTargetedParentFkFields, goldenTargetedParentFkFields);
    });

    test('online-order answer tables reproduce the frozen set', () {
      expect(kOnlineOrderAnswerTables, goldenOnlineOrderAnswer);
    });

    test('withdrawable reversal tables: same members, children first', () {
      expect(kWithdrawableReversalTables, goldenWithdrawable);
      // Iteration order (reverse registry) withdraws a referencing row before
      // the row it references — the two FK pairs inside the set.
      final order = kWithdrawableReversalTables.toList();
      expect(order, [
        'payment_transactions',
        'crate_ledger',
        'wallet_transactions',
        'stock_transactions',
        'stock_adjustments',
        'cost_batches',
      ]);
      expect(order.indexOf('stock_transactions'),
          lessThan(order.indexOf('stock_adjustments')));
      expect(order.indexOf('payment_transactions'),
          lessThan(order.indexOf('wallet_transactions')));
    });

    test('soft-delete tables reproduce the frozen set', () {
      expect(kSoftDeletableTables.toSet(), goldenSoftDeletable.toSet());
      expect(kSoftDeletableTables.length, goldenSoftDeletable.length);
    });

    test('ledger immutable columns reproduce the frozen map (column order too)',
        () {
      expect(kLedgerImmutableColumns, goldenLedgerImmutableColumns);
    });

    test('diagnostic tables derive from the registry and cover the old list',
        () {
      expect(SyncDiagnostic.tables, [
        for (final t in kSyncRegistry)
          if (t.tenantScoped || t.isCache) t.name,
      ]);
      expect(SyncDiagnostic.tables, isNot(contains('businesses')));
      final real = goldenDiagnosticTables.where((t) => t != 'invites');
      expect(SyncDiagnostic.tables, containsAll(real));
    });

    test('every moved-map table is a registry table', () {
      final names = kSyncPullOrder.toSet();
      for (final t in {
        ...goldenPushPriority.keys,
        ...goldenConflictTargets.keys,
        ...goldenDeferrable,
        ...goldenTargetedParentFkFields.values,
        ...goldenOnlineOrderAnswer,
        ...goldenWithdrawable,
        ...goldenSoftDeletable,
        ...goldenLedgerImmutableColumns.keys,
      }) {
        expect(names, contains(t), reason: '$t missing from the registry');
      }
    });
  });
}
