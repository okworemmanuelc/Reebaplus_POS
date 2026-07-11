// stock_approval_pending_clear_test.dart
//
// Regression lock for issue #115 — "stuck approvals count on Reports".
//
// A stock-keeper Add/Remove lands in `stock_adjustment_requests` as `pending`;
// a Manager/CEO resolves it via StockAdjustmentRequestsDao.approveRequest /
// rejectRequest (flips status → approved/rejected, bumps last_updated_at,
// enqueues a full-row upsert). That local flip has always worked (golden
// suite). The bug was DOWNSTREAM in the pull path: the generic LWW clobber
// guard is status-blind, and its same-second `>=` tie rule (or clock skew) let
// a stale / out-of-order cloud snapshot carrying the pre-resolution `pending`
// state overwrite the locally-resolved row once the protecting outbox entry had
// drained — resurrecting the request into the pending approvals count. Over
// time these resurrected rows made the count appear permanently stuck.
//
// The fix makes the request tables' restore MONOTONIC (pending → terminal,
// never back) via Restore.monotonicStatus in sync_registry.dart. These tests
// drive the real SupabaseSyncService restore path (the @visibleForTesting seam)
// so a stale pending re-pull can never revert a resolved request, while the
// normal cross-device `pending → approved` convergence still applies.

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

void main() {
  late AppDatabase db;
  late SupabaseClient supabase;
  late SupabaseSyncService sync;
  late String businessId;
  late String storeId;
  late String productId;
  late String requesterId;
  late String approverId;
  late String requestId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    businessId = UuidV7.generate();
    db.businessIdResolver = () => businessId;
    // Bare client — the restore path never calls it, but the constructor needs
    // one (mirrors roles_pull_restore_test.dart).
    supabase = SupabaseClient('https://placeholder.supabase.co', 'anon-key');
    sync = SupabaseSyncService(db, SupabaseCloudTransport(supabase));

    storeId = UuidV7.generate();
    productId = UuidV7.generate();
    requesterId = UuidV7.generate();
    approverId = UuidV7.generate();
    requestId = UuidV7.generate();

    await db.into(db.businesses).insert(
        BusinessesCompanion.insert(id: Value(businessId), name: 'Biz'));
    await db.into(db.stores).insert(StoresCompanion.insert(
        id: Value(storeId), businessId: businessId, name: 'Main'));
    await db.into(db.users).insert(UsersCompanion.insert(
        id: Value(requesterId),
        businessId: businessId,
        name: 'Keeper',
        pin: '0000'));
    await db.into(db.users).insert(UsersCompanion.insert(
        id: Value(approverId),
        businessId: businessId,
        name: 'Manager',
        pin: '0001'));
    await db.into(db.products).insert(ProductsCompanion.insert(
        id: Value(productId), businessId: businessId, name: 'Widget'));
    await db.into(db.inventory).insert(InventoryCompanion.insert(
        businessId: businessId,
        productId: productId,
        storeId: storeId,
        quantity: const Value(50)));
    // v1 dispatch so approveRequest's adjustStock writes inventory locally.
    await db.systemConfigDao
        .set('feature.domain_rpcs_v2.inventory_delta', 'false');
  });

  tearDown(() async {
    await supabase.dispose();
    await db.close();
  });

  // A snake_case "cloud" pending row exactly as PostgREST / pos_pull_snapshot
  // return it (the shape SupabaseSyncService._restoreTableData consumes).
  Map<String, dynamic> cloudRow(String status, String lua, {String? by}) => {
        'id': requestId,
        'business_id': businessId,
        'product_id': productId,
        'store_id': storeId,
        'quantity_diff': 5,
        'reason': 'restock',
        'summary': 'Add 5 Widget',
        'requested_by': requesterId,
        'status': status,
        'approved_by': by,
        'approved_at': status == 'pending' ? null : lua,
        'created_at': lua,
        'last_updated_at': lua,
      };

  Future<String> statusOf(String id) async =>
      (await (db.select(db.stockAdjustmentRequests)..where((t) => t.id.equals(id)))
              .getSingle())
          .status;

  Future<int> pendingCount() async =>
      (await db.stockAdjustmentRequestsDao.watchPending().first).length;

  // The tightest deterministic reproduction of the tie: after resolving, echo
  // the resolved row's own last_updated_at back as the stale pending snapshot's
  // timestamp (same unix second) — the exact `incoming >= local` case that
  // clobbered pre-fix (a request created + resolved within the same second,
  // then realtime redelivers the pre-resolution pending insert).
  Future<String> resolvedLua(String id) async {
    final row = await (db.select(db.stockAdjustmentRequests)
          ..where((t) => t.id.equals(id)))
        .getSingle();
    return row.lastUpdatedAt.toUtc().toIso8601String();
  }

  test('approving, then a stale pending re-pull, leaves the request resolved',
      () async {
    // 1. Pending request arrives via pull.
    await sync.restoreTableDataForTesting('stock_adjustment_requests',
        [cloudRow('pending', DateTime.utc(2026, 6, 1, 10).toIso8601String())]);
    expect(await statusOf(requestId), 'pending');
    expect(await pendingCount(), 1);

    // 2. Manager approves locally — flips to approved and drops from the count.
    await db.stockAdjustmentRequestsDao
        .approveRequest(requestId: requestId, approverId: approverId);
    expect(await statusOf(requestId), 'approved');
    expect(await pendingCount(), 0);

    // 3. The approved-upsert drains (push confirmed) — invariant #12 no longer
    //    protects the row.
    await db.delete(db.syncQueue).go();

    // 4. A stale / out-of-order PENDING snapshot is redelivered with a
    //    same-second timestamp (the pre-fix clobber trigger).
    await sync.restoreTableDataForTesting(
        'stock_adjustment_requests', [cloudRow('pending', await resolvedLua(requestId))]);

    // The resolution is durable — no resurrection into the pending count.
    expect(await statusOf(requestId), 'approved',
        reason: 'a stale pending pull must not revert an approved request');
    expect(await pendingCount(), 0);
  });

  test('rejecting, then a stale pending re-pull, leaves the request resolved',
      () async {
    await sync.restoreTableDataForTesting('stock_adjustment_requests',
        [cloudRow('pending', DateTime.utc(2026, 6, 1, 10).toIso8601String())]);
    expect(await pendingCount(), 1);

    await db.stockAdjustmentRequestsDao
        .rejectRequest(requestId: requestId, approverId: approverId);
    expect(await statusOf(requestId), 'rejected');
    expect(await pendingCount(), 0);

    await db.delete(db.syncQueue).go();

    await sync.restoreTableDataForTesting(
        'stock_adjustment_requests', [cloudRow('pending', await resolvedLua(requestId))]);

    expect(await statusOf(requestId), 'rejected',
        reason: 'a stale pending pull must not revert a rejected request');
    expect(await pendingCount(), 0);
  });

  test('a newer pending re-pull (clock skew) still cannot revert a resolution',
      () async {
    await sync.restoreTableDataForTesting('stock_adjustment_requests',
        [cloudRow('pending', DateTime.utc(2026, 6, 1, 10).toIso8601String())]);
    await db.stockAdjustmentRequestsDao
        .approveRequest(requestId: requestId, approverId: approverId);
    await db.delete(db.syncQueue).go();

    // Even a pending snapshot that is strictly NEWER than the local resolution
    // (approver device clock behind the writer's) must not win — status is
    // monotonic, not timestamp-driven, for the resolved case.
    await sync.restoreTableDataForTesting('stock_adjustment_requests',
        [cloudRow('pending', DateTime.utc(2030, 1, 1).toIso8601String())]);

    expect(await statusOf(requestId), 'approved');
    expect(await pendingCount(), 0);
  });

  test('the guard does NOT block normal cross-device pending → approved',
      () async {
    // A brand-new pending request arrives on this device.
    await sync.restoreTableDataForTesting('stock_adjustment_requests',
        [cloudRow('pending', DateTime.utc(2026, 6, 1, 10).toIso8601String())]);
    expect(await statusOf(requestId), 'pending');

    // Another device approved it; the approved row propagates here via pull.
    // The monotonic guard only blocks incoming `pending` over a resolved local
    // row — this pending → approved convergence must still apply.
    await sync.restoreTableDataForTesting('stock_adjustment_requests', [
      cloudRow('approved', DateTime.utc(2026, 6, 1, 11).toIso8601String(),
          by: approverId)
    ]);

    expect(await statusOf(requestId), 'approved',
        reason: 'cross-device approval must still converge locally');
    expect(await pendingCount(), 0);
  });

  test('sibling quick_sale_requests is guarded by the same monotonic restore',
      () async {
    final qsId = UuidV7.generate();
    Map<String, dynamic> qs(String status, String lua) => {
          'id': qsId,
          'business_id': businessId,
          'store_id': storeId,
          'item_name': 'Bottled Water',
          'quantity': 3.0,
          'unit_price_kobo': 50000,
          'summary': '3 x Bottled Water',
          'requested_by': requesterId,
          'status': status,
          'approved_by': status == 'pending' ? null : approverId,
          'approved_at': status == 'pending' ? null : lua,
          'created_at': lua,
          'last_updated_at': lua,
        };

    // Pending arrives, then a cross-device approval converges it locally.
    await sync.restoreTableDataForTesting(
        'quick_sale_requests', [qs('pending', DateTime.utc(2026, 6, 1, 10).toIso8601String())]);
    await sync.restoreTableDataForTesting(
        'quick_sale_requests', [qs('approved', DateTime.utc(2026, 6, 1, 11).toIso8601String())]);
    final resolved = await (db.select(db.quickSaleRequests)
          ..where((t) => t.id.equals(qsId)))
        .getSingle();
    expect(resolved.status, 'approved');

    // A stale pending snapshot (same second as the resolution) must not revert.
    await sync.restoreTableDataForTesting('quick_sale_requests',
        [qs('pending', resolved.lastUpdatedAt.toUtc().toIso8601String())]);

    final after = await (db.select(db.quickSaleRequests)
          ..where((t) => t.id.equals(qsId)))
        .getSingle();
    expect(after.status, 'approved',
        reason: 'a stale pending pull must not revert a resolved quick sale');
    final pendingQs =
        await db.quickSaleRequestsDao.watchPending().first;
    expect(pendingQs, isEmpty);
  });
}
