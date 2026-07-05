@Tags(['integration'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../golden/stock_adjustment_scenario.dart';
import '../../helpers/supabase_test_clients.dart';
import '../../helpers/supabase_test_env.dart';

/// Stock-adjustment approval-gate Golden Suite — the SQL RPC side (ADR 0009, #50).
///
/// Runs the shared fixtures against approve_stock_adjustment (0141) on real dev
/// Supabase, seeding a pending request via the admin client, then approving /
/// rejecting via the signed-in CEO userClient; asserts the request status + the
/// inventory after. 'request' scenarios are SKIPPED here: the Tier-2 identity is
/// the business CEO, whom request_stock_adjustment routes to immediate-apply, so
/// the stock-keeper → pending path is pinned on the Dart arm. Tier-2:
/// auto-skipped when the env vars are absent.
final String? _skipReason = (() {
  try {
    TestEnv.load();
    return null;
  } on StateError catch (e) {
    return e.message;
  }
})();

void main() {
  late TestClients clients;
  late String businessId;

  String? storeId;
  final productIds = <String>[];
  final requestIds = <String>[];

  setUpAll(() async {
    if (_skipReason != null) return;
    clients = await TestClients.setUp();
    businessId = clients.env.businessId;
  });

  tearDown(() async {
    if (_skipReason != null) return;
    Future<void> del(String table, String column, String id) async {
      try {
        await clients.adminClient.from(table).delete().eq(column, id);
      } on PostgrestException catch (e) {
        if (e.code != 'P0001' && e.code != '23503') rethrow;
      }
    }

    for (final id in requestIds) {
      await del('activity_logs', 'entity_id', id);
      await del('stock_adjustment_requests', 'id', id);
    }
    for (final id in productIds) {
      await del('stock_transactions', 'product_id', id);
      await del('stock_adjustments', 'product_id', id);
      await del('inventory', 'product_id', id);
      await del('products', 'id', id);
    }
    if (storeId != null) await del('stores', 'id', storeId!);
    storeId = null;
    productIds.clear();
    requestIds.clear();
  });

  tearDownAll(() async {
    if (_skipReason != null) return;
    await clients.dispose();
  });

  final scenarios = loadStockAdjScenarios();
  for (final s in scenarios) {
    test('golden (stock-adjust rpc): ${s.name}', () async {
      final admin = clients.adminClient;
      final store = UuidV7.generate();
      storeId = store;
      await admin.from('stores').insert(
          {'id': store, 'business_id': businessId, 'name': 'Golden Adj Store'});

      final productId = UuidV7.generate();
      productIds.add(productId);
      await admin.from('products').insert(
          {'id': productId, 'business_id': businessId, 'name': 'Widget'});
      await admin.from('inventory').insert({
        'id': UuidV7.generate(),
        'business_id': businessId,
        'product_id': productId,
        'store_id': store,
        'quantity': s.startQty,
      });

      // Seed a pending request (as if a stock keeper had raised it).
      final requestId = UuidV7.generate();
      requestIds.add(requestId);
      await admin.from('stock_adjustment_requests').insert({
        'id': requestId,
        'business_id': businessId,
        'product_id': productId,
        'store_id': store,
        'quantity_diff': s.quantityDiff,
        'reason': s.reason,
        'summary': s.reason,
        'status': 'pending',
      });

      // Approve or reject via the RPC as the signed-in CEO.
      await clients.userClient.rpc('approve_stock_adjustment', params: {
        'p_business_id': businessId,
        'p_request_id': requestId,
        'p_approve': s.operation == 'approve',
        'p_reason': s.reason,
      });

      final reqRow = await admin
          .from('stock_adjustment_requests')
          .select('status')
          .eq('id', requestId)
          .single();
      final invRow = await admin
          .from('inventory')
          .select('quantity')
          .eq('product_id', productId)
          .eq('store_id', store)
          .maybeSingle();

      expectStockAdjGolden(
        s,
        StockAdjOutcome(
          status: reqRow['status'] as String,
          inventoryAfter:
              invRow == null ? 0 : (invRow['quantity'] as num).toInt(),
        ),
      );
    },
        skip: _skipReason ??
            (s.operation == 'request'
                ? 'stock-keeper → pending pinned on the Dart arm (Tier-2 identity is CEO)'
                : null));
  }
}
