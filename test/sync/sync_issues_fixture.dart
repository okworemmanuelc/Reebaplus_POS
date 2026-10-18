// Shared fixture for the Sync Issues tests and goldens (#443): a small outbox
// with pending, failed and orphaned rows, sample data only ("Stallion Global").
//
// Dates are fixed, never `DateTime.now()`. Rows that are due "as soon as
// possible" leave `nextAttemptAt` null; the one date the screen prints in
// local time (an orphan's `archived:`) is a fixed UTC instant.

import 'dart:convert';

import 'package:drift/drift.dart' show Value;

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../helpers/screen_harness.dart';

/// The business id shown in the sample payloads and, via the auth user, on the
/// Health card (see the golden test), so images are the same on every run.
const String kSampleBusinessId = '0192a9d0-1111-7000-8000-stallion00001';

/// Ids of the seeded rows, so a test can find its buttons by key.
class SyncSample {
  const SyncSample({
    required this.pendingPlainId,
    required this.pendingRlsId,
    required this.pendingNetworkId,
    required this.failedFkId,
    required this.failedDuplicateId,
    required this.orphanSaleId,
    required this.orphanPlainId,
  });

  final String pendingPlainId;
  final String pendingRlsId;
  final String pendingNetworkId;
  final String failedFkId;
  final String failedDuplicateId;
  final String orphanSaleId;
  final String orphanPlainId;
}

/// The shared-preferences entry that makes the "Catching up" card show.
Map<String, Object> deferredTablesPrefs(ScreenTestEnvironment env) => {
  SupabaseSyncService.pendingDeferredTablesKey(env.businessId):
      'order_items,payments',
};

Future<SyncSample> seedSyncSample(ScreenTestEnvironment env) async {
  final db = env.db;
  // The payload text is only shown, so it carries a fixed id: a golden must not
  // depend on the random business id the harness mints.
  const biz = kSampleBusinessId;
  final bizColumn = env.businessId;

  Future<String> queue({
    required String action,
    required Map<String, Object?> payload,
    String status = 'pending',
    String? error,
    int attempts = 0,
  }) async {
    final id = UuidV7.generate();
    await db
        .into(db.syncQueue)
        .insert(
          SyncQueueCompanion.insert(
            id: Value(id),
            businessId: bizColumn,
            actionType: action,
            payload: jsonEncode(payload),
            status: Value(status),
            errorMessage: Value(error),
            attempts: Value(attempts),
            createdAt: Value(DateTime.utc(2026, 3, 14, 9)),
          ),
        );
    return id;
  }

  Future<String> orphan({
    required String action,
    required Map<String, Object?> payload,
    required String reason,
  }) async {
    final id = UuidV7.generate();
    await db
        .into(db.syncQueueOrphans)
        .insert(
          SyncQueueOrphansCompanion.insert(
            id: Value(id),
            originalId: UuidV7.generate(),
            actionType: action,
            payload: jsonEncode(payload),
            reason: reason,
            createdAt: Value(DateTime.utc(2026, 3, 14, 8)),
            movedAt: Value(DateTime.utc(2026, 3, 14, 12)),
          ),
        );
    return id;
  }

  final pendingPlain = await queue(
    action: 'orders:upsert',
    payload: {'id': 'ord-1001', 'business_id': biz, 'total_kobo': 1250000},
  );
  final pendingRls = await queue(
    action: 'payments:upsert',
    payload: {'id': 'pay-2002', 'business_id': biz, 'amount_kobo': 500000},
    error: 'new row violates row-level security policy for table "payments"',
    attempts: 3,
  );
  final pendingNetwork = await queue(
    action: 'customers:upsert',
    payload: {'id': 'cus-3003', 'business_id': biz, 'name': 'Ada Obi'},
    error: 'SocketException: Failed host lookup',
    attempts: 2,
  );
  final failedFk = await queue(
    action: 'inventory:upsert',
    payload: {'id': 'inv-4004', 'business_id': biz, 'quantity': 12},
    status: 'failed',
    error:
        'insert or update violates foreign key constraint '
        '"inventory_product_id_fkey"',
    attempts: 5,
  );
  final failedDuplicate = await queue(
    action: 'products:upsert',
    payload: {'id': 'prd-5005', 'business_id': biz, 'name': 'Malt 33cl'},
    status: 'failed',
    error: 'duplicate key value violates unique constraint "products_pkey"',
    attempts: 4,
  );
  final orphanSale = await orphan(
    action: 'domain:pos_record_sale_v2',
    payload: {'p_order_id': 'ord-6006', 'p_business_id': biz},
    reason: 'insufficient_stock (P0001)',
  );
  final orphanPlain = await orphan(
    action: 'expenses:upsert',
    payload: {'id': 'exp-7007', 'business_id': biz},
    reason: 'insufficient_privilege (42501)',
  );

  return SyncSample(
    pendingPlainId: pendingPlain,
    pendingRlsId: pendingRls,
    pendingNetworkId: pendingNetwork,
    failedFkId: failedFk,
    failedDuplicateId: failedDuplicate,
    orphanSaleId: orphanSale,
    orphanPlainId: orphanPlain,
  );
}
