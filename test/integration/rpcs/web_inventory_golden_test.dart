@Tags(['integration'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../golden/inventory_scenario.dart';
import '../../helpers/supabase_test_clients.dart';
import '../../helpers/supabase_test_env.dart';

/// Batch-creation Golden Suite — the SQL RPC side (ADR 0009, issue #48).
///
/// Runs the SAME inventory fixtures as the Dart producer runner
/// (test/golden/inventory_dart_dao_golden_test.dart) against the server-
/// authoritative add_product / receive_stock RPCs (migration 0140) on real dev
/// Supabase. Any drift in the Cost Batch producer rule between the two fails the
/// build. Tier-2: hits live Supabase, auto-skipped when the env vars are absent.
/// Seeds via the service-role adminClient; invokes the RPC via the signed-in
/// userClient (the RPCs read auth.uid() for the tenant + permission guards).
final String? _skipReason = (() {
  try {
    TestEnv.load();
    return null;
  } on StateError catch (e) {
    return e.message;
  }
})();

String _dateKey(String iso) => iso.substring(0, 10);

void main() {
  late TestClients clients;
  late String businessId;

  String? storeId;
  String? supplierId;
  final productIds = <String>[];
  final receiptIds = <String>[];

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
        // supplier_ledger_entries / activity are append-only in places → P0001;
        // FK parents can 23503. Both are expected in the shared test business.
        if (e.code != 'P0001' && e.code != '23503') rethrow;
      }
    }

    for (final id in productIds) {
      await del('stock_transactions', 'product_id', id);
      await del('stock_adjustments', 'product_id', id);
      await del('cost_batches', 'product_id', id);
      await del('inventory', 'product_id', id);
      await del('activity_logs', 'product_id', id);
      await del('products', 'id', id);
    }
    for (final id in receiptIds) {
      await del('activity_logs', 'id', id);
    }
    if (supplierId != null) {
      await del('supplier_ledger_entries', 'supplier_id', supplierId!);
      await del('suppliers', 'id', supplierId!);
    }
    if (storeId != null) {
      await del('stores', 'id', storeId!);
    }
    storeId = null;
    supplierId = null;
    productIds.clear();
    receiptIds.clear();
  });

  tearDownAll(() async {
    if (_skipReason != null) return;
    await clients.dispose();
  });

  final scenarios = loadInventoryScenarios();
  for (final s in scenarios) {
    test('golden (inventory rpc): ${s.name}', () async {
      final admin = clients.adminClient;
      final store = UuidV7.generate();
      storeId = store;
      await admin.from('stores').insert({
        'id': store,
        'business_id': businessId,
        'name': 'Golden Inv Store',
      });

      final productId = UuidV7.generate();
      productIds.add(productId);
      final batches = <String, ExpectedInvBatch>{};
      int? supplierBalance;

      if (s.operation == 'add_product') {
        // add_product creates the product + opening stock + opening batch.
        await clients.userClient.rpc('add_product', params: {
          'p_business_id': businessId,
          'p_product_id': productId,
          'p_store_id': store,
          'p_name': s.productName,
          'p_unit': s.unit,
          'p_retailer_price_kobo': s.retailerPriceKobo,
          'p_wholesaler_price_kobo': s.wholesalerPriceKobo,
          'p_buying_price_kobo': s.buyingPriceKobo,
          'p_opening_stock': s.openingStock,
        });
      } else {
        // Receive Stock: seed the product + pre-existing state, then the receipt.
        await admin.from('products').insert({
          'id': productId,
          'business_id': businessId,
          'name': s.productName,
          'unit': s.unit,
          'retailer_price_kobo': s.retailerPriceKobo,
          'wholesaler_price_kobo': s.wholesalerPriceKobo,
          'buying_price_kobo': s.buyingPriceKobo,
        });
        if (s.existingStock > 0) {
          await admin.from('inventory').insert({
            'id': UuidV7.generate(),
            'business_id': businessId,
            'product_id': productId,
            'store_id': store,
            'quantity': s.existingStock,
          });
        }
        for (final b in s.existingBatches) {
          await admin.from('cost_batches').insert({
            'id': UuidV7.generate(),
            'business_id': businessId,
            'product_id': productId,
            'store_id': store,
            'qty_remaining': b.qty,
            'qty_original': b.qty,
            'cost_kobo': b.costKobo,
            'received_at': b.receivedAtUtc.toIso8601String(),
          });
        }
        final supplier = UuidV7.generate();
        supplierId = supplier;
        await admin.from('suppliers').insert({
          'id': supplier,
          'business_id': businessId,
          'name': 'Golden Supplier',
        });

        final receiptId = UuidV7.generate();
        receiptIds.add(receiptId);
        await clients.userClient.rpc('receive_stock', params: {
          'p_business_id': businessId,
          'p_receipt_id': receiptId,
          'p_supplier_id': supplier,
          'p_store_id': store,
          'p_received_at': s.lines.first.receivedAtUtc.toIso8601String(),
          'p_lines': [
            for (final l in s.lines)
              {
                'product_id': productId,
                'quantity': l.quantity,
                'buying_price_kobo': l.buyingPriceKobo,
              }
          ],
          'p_amount_paid_kobo': s.amountPaidKobo,
          'p_payment_method': s.paymentMethod,
          'p_note': 'golden receipt',
        });

        final ledger = await admin
            .from('supplier_ledger_entries')
            .select('signed_amount_kobo')
            .eq('supplier_id', supplier);
        supplierBalance = ledger.fold<int>(
            0, (sum, r) => sum + (r['signed_amount_kobo'] as num).toInt());
      }

      // ── Collect the resulting cost batches + inventory ─────────────────────
      final batchRows = await admin
          .from('cost_batches')
          .select('qty_remaining, qty_original, cost_kobo, received_at')
          .eq('product_id', productId);
      for (final b in batchRows) {
        final key = s.operation == 'add_product'
            ? 'opening'
            : _dateKey(b['received_at'] as String);
        batches[key] = ExpectedInvBatch({
          'received_at': key,
          'qty_remaining': (b['qty_remaining'] as num).toInt(),
          'qty_original': (b['qty_original'] as num).toInt(),
          'cost_kobo': (b['cost_kobo'] as num).toInt(),
        });
      }

      final invRow = await admin
          .from('inventory')
          .select('quantity')
          .eq('product_id', productId)
          .eq('store_id', store)
          .maybeSingle();

      expectInventoryGolden(
        s,
        InventoryOutcome(
          batches: batches,
          inventoryAfter: invRow == null ? 0 : (invRow['quantity'] as num).toInt(),
          supplierBalanceAfterKobo: supplierBalance,
        ),
      );
    }, skip: _skipReason);
  }
}
