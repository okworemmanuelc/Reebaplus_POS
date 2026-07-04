@Tags(['integration'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../../helpers/supabase_test_clients.dart';
import '../../helpers/supabase_test_env.dart';

/// Tier-2 integration tests for the server-authoritative FIFO batch
/// consumption + replay logic (migration 0133, issue #39, Epic 2 F3). Hits
/// real dev Supabase; auto-skipped when env vars are absent.
///
/// Two seams:
///   * `fifo_assign(batches, sales)` — the PURE draw-down. Tenant-agnostic, no
///     fixtures: a queue + an ordered sale sequence in, per-line COGS out.
///     Deterministic and idempotent by construction.
///   * `pos_recost_product_store(business, product, store)` — the orchestrator:
///     loads the queue + recognized-sale ledger, replays via fifo_assign, and
///     writes the authoritative COGS back onto order_items. A late
///     earlier-timestamped sale re-assigns already-corrected lines.
///
/// Cleanup: orders / order_items / cost_batches are NOT append-only, so rows
/// created per test are deleted by id in tearDown. fifo_assign writes nothing.

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
  late String storeId;

  // Ids created per test, torn down (children before parents).
  final orderIds = <String>[];
  final orderItemIds = <String>[];
  final costBatchIds = <String>[];
  final productIds = <String>[];

  setUpAll(() async {
    if (_skipReason != null) return;
    clients = await TestClients.setUp();
    businessId = clients.env.businessId;

    storeId = UuidV7.generate();
    await clients.adminClient.from('stores').insert({
      'id': storeId,
      'business_id': businessId,
      'name': 'Recost Store',
    });
  });

  tearDown(() async {
    if (_skipReason != null) return;
    // Delete children before parents. order_items → orders → cost_batches →
    // products. All mutable (non-append-only) so DELETE is permitted.
    for (final id in orderItemIds) {
      await clients.adminClient.from('order_items').delete().eq('id', id);
    }
    for (final id in orderIds) {
      await clients.adminClient.from('orders').delete().eq('id', id);
    }
    for (final id in costBatchIds) {
      await clients.adminClient.from('cost_batches').delete().eq('id', id);
    }
    for (final id in productIds) {
      await clients.adminClient.from('products').delete().eq('id', id);
    }
    orderItemIds.clear();
    orderIds.clear();
    costBatchIds.clear();
    productIds.clear();
  });

  tearDownAll(() async {
    if (_skipReason != null) return;
    await clients.adminClient.from('stores').delete().eq('id', storeId);
    await clients.dispose();
  });

  // ── Fixture helpers ───────────────────────────────────────────────────────

  Future<String> newProduct() async {
    final id = UuidV7.generate();
    await clients.adminClient.from('products').insert({
      'id': id,
      'business_id': businessId,
      'name': 'Recost Product',
      'selling_price_kobo': 100000,
    });
    productIds.add(id);
    return id;
  }

  Future<String> addBatch(
    String productId, {
    required int costKobo,
    required int qty,
    required DateTime receivedAt,
  }) async {
    final id = UuidV7.generate();
    await clients.adminClient.from('cost_batches').insert({
      'id': id,
      'business_id': businessId,
      'product_id': productId,
      'store_id': storeId,
      'qty_remaining': qty,
      'qty_original': qty,
      'cost_kobo': costKobo,
      'received_at': receivedAt.toUtc().toIso8601String(),
    });
    costBatchIds.add(id);
    return id;
  }

  /// Inserts an order + one order_item for [productId], stamped at [soldAt]
  /// (the sale's recorded timestamp — the FIFO ordering key). Returns the
  /// order_item id.
  Future<String> addSale(
    String productId, {
    required int qty,
    required DateTime soldAt,
    String status = 'completed',
    int buyingPriceKobo = 0,
  }) async {
    final orderId = UuidV7.generate();
    final ts = soldAt.toUtc().toIso8601String();
    await clients.adminClient.from('orders').insert({
      'id': orderId,
      'business_id': businessId,
      'order_number': 'RC-${UuidV7.generate().substring(0, 12)}',
      'total_amount_kobo': qty * 100000,
      'net_amount_kobo': qty * 100000,
      'payment_type': 'cash',
      'status': status,
      'store_id': storeId,
      'created_at': ts,
      'last_updated_at': ts,
    });
    orderIds.add(orderId);

    final itemId = UuidV7.generate();
    await clients.adminClient.from('order_items').insert({
      'id': itemId,
      'business_id': businessId,
      'order_id': orderId,
      'product_id': productId,
      'store_id': storeId,
      'quantity': qty,
      'unit_price_kobo': 100000,
      'buying_price_kobo': buyingPriceKobo,
      'total_kobo': qty * 100000,
      'created_at': ts,
      'last_updated_at': ts,
    });
    orderItemIds.add(itemId);
    return itemId;
  }

  Future<int> readBuyingPrice(String itemId) async {
    final row = await clients.adminClient
        .from('order_items')
        .select('buying_price_kobo')
        .eq('id', itemId)
        .single();
    return (row['buying_price_kobo'] as num).toInt();
  }

  Future<int> readQtyRemaining(String batchId) async {
    final row = await clients.adminClient
        .from('cost_batches')
        .select('qty_remaining')
        .eq('id', batchId)
        .single();
    return (row['qty_remaining'] as num).toInt();
  }

  Future<Map<String, dynamic>> recost(String productId) async {
    final res = await clients.userClient.rpc('pos_recost_product_store', params: {
      'p_business_id': businessId,
      'p_product_id': productId,
      'p_store_id': storeId,
    });
    return (res as Map).cast<String, dynamic>();
  }

  // ── fifo_assign (pure seam — no fixtures) ─────────────────────────────────

  group('fifo_assign (pure FIFO draw-down)', () {
    Future<Map<String, dynamic>> assign(
      List<Map<String, Object>> batches,
      List<Map<String, Object>> sales,
    ) async {
      final res = await clients.userClient.rpc('fifo_assign', params: {
        'p_batches': batches,
        'p_sales': sales,
      });
      return (res as Map).cast<String, dynamic>();
    }

    test('single costed batch → exact per-unit COGS', () async {
      final out = await assign(
        [
          {'cost_kobo': 50000, 'qty': 10},
        ],
        [
          {'line_id': 'A', 'quantity': 3},
        ],
      );
      final line = (out['lines'] as List).single as Map;
      expect(line['cogs_total_kobo'], 150000);
      expect(line['cogs_per_unit_kobo'], 50000);
      expect(line['uncosted_units'], 0);
      expect((out['batches_remaining'] as List), [7]);
    }, skip: _skipReason);

    test('line spanning a batch boundary → weighted total + rounded per-unit',
        () async {
      // 6 @ ₦500 then 4 @ ₦600 = 300000 + 240000 = 540000 over 10 = 54000/unit.
      final out = await assign(
        [
          {'cost_kobo': 50000, 'qty': 6},
          {'cost_kobo': 60000, 'qty': 4},
        ],
        [
          {'line_id': 'A', 'quantity': 10},
        ],
      );
      final line = (out['lines'] as List).single as Map;
      expect(line['cogs_total_kobo'], 540000);
      expect(line['cogs_per_unit_kobo'], 54000);
      expect(line['uncosted_units'], 0);
      expect((out['batches_remaining'] as List), [0, 0]);
    }, skip: _skipReason);

    test('uncosted (cost-0) batch → COGS 0, units counted as uncosted',
        () async {
      final out = await assign(
        [
          {'cost_kobo': 0, 'qty': 5},
        ],
        [
          {'line_id': 'A', 'quantity': 3},
        ],
      );
      final line = (out['lines'] as List).single as Map;
      expect(line['cogs_total_kobo'], 0);
      expect(line['cogs_per_unit_kobo'], 0);
      expect(line['uncosted_units'], 3);
      expect((out['batches_remaining'] as List), [2]);
    }, skip: _skipReason);

    test('queue exhausted → shortfall is uncosted', () async {
      final out = await assign(
        [
          {'cost_kobo': 50000, 'qty': 2},
        ],
        [
          {'line_id': 'A', 'quantity': 5},
        ],
      );
      final line = (out['lines'] as List).single as Map;
      expect(line['cogs_total_kobo'], 100000, reason: '2 costed units only');
      expect(line['uncosted_units'], 3);
      expect((out['batches_remaining'] as List), [0]);
    }, skip: _skipReason);

    test('sequential sales draw oldest-first; cursor persists across lines',
        () async {
      final out = await assign(
        [
          {'cost_kobo': 50000, 'qty': 3},
          {'cost_kobo': 90000, 'qty': 3},
        ],
        [
          {'line_id': 'A', 'quantity': 3},
          {'line_id': 'B', 'quantity': 3},
        ],
      );
      final lines = (out['lines'] as List).cast<Map>();
      expect(lines[0]['cogs_per_unit_kobo'], 50000, reason: 'A gets batch 1');
      expect(lines[1]['cogs_per_unit_kobo'], 90000, reason: 'B gets batch 2');
      expect((out['batches_remaining'] as List), [0, 0]);
    }, skip: _skipReason);

    test('deterministic + idempotent: same input twice → identical output',
        () async {
      final input = [
        {
          'cost_kobo': 50000,
          'qty': 6,
        },
        {'cost_kobo': 60000, 'qty': 10},
      ];
      final sales = [
        {'line_id': 'A', 'quantity': 4},
        {'line_id': 'B', 'quantity': 6},
      ];
      final first = await assign(input, sales);
      final second = await assign(input, sales);
      expect(first, equals(second));
    }, skip: _skipReason);
  });

  // ── pos_recost_product_store (orchestrator + replay/cascade) ──────────────

  group('pos_recost_product_store', () {
    test('assigns COGS by sale timestamp and writes it onto order_items',
        () async {
      final product = await newProduct();
      final b1 = await addBatch(product,
          costKobo: 50000, qty: 6, receivedAt: DateTime(2026, 1, 1));
      await addBatch(product,
          costKobo: 60000, qty: 10, receivedAt: DateTime(2026, 2, 1));
      // One sale of 10 spanning the boundary: 6@500 + 4@600 = 540000 → 54000/u.
      final sale =
          await addSale(product, qty: 10, soldAt: DateTime(2026, 3, 1));

      final res = await recost(product);
      expect(res['recosted_count'], 1);
      expect(await readBuyingPrice(sale), 54000);
      expect(await readQtyRemaining(b1), 0, reason: 'cheap batch drawn dry');
    }, skip: _skipReason);

    test(
        'replay/cascade: a late EARLIER-timestamped sale re-assigns an '
        'already-corrected line', () async {
      final product = await newProduct();
      await addBatch(product,
          costKobo: 50000, qty: 6, receivedAt: DateTime(2026, 1, 1)); // cheap
      await addBatch(product,
          costKobo: 60000, qty: 10, receivedAt: DateTime(2026, 2, 1)); // pricey

      // First: only the LATER sale (T2) exists. It claims all 6 cheap units.
      final saleLate =
          await addSale(product, qty: 6, soldAt: DateTime(2026, 3, 2));
      await recost(product);
      expect(await readBuyingPrice(saleLate), 50000,
          reason: 'with no earlier sale, the late sale takes the cheap batch');

      // Now the EARLIER sale (T1) arrives late. It has first claim on the
      // cheap batch, pushing the late sale onto the pricey batch.
      final saleEarly =
          await addSale(product, qty: 4, soldAt: DateTime(2026, 3, 1));
      final res = await recost(product);

      // saleEarly: 4 @ ₦500 = 50000/u. saleLate: 2 @ ₦500 + 4 @ ₦600 =
      // 340000 over 6 = 56666.67 → 56667. Both the early line (new) and the
      // late line (re-assigned) changed.
      expect(await readBuyingPrice(saleEarly), 50000);
      expect(await readBuyingPrice(saleLate), 56667,
          reason: 'late sale re-costed onto the pricier batch');
      expect(res['recosted_count'], 2);
    }, skip: _skipReason);

    test('idempotent: re-running on an unchanged ledger recosts nothing',
        () async {
      final product = await newProduct();
      await addBatch(product,
          costKobo: 50000, qty: 10, receivedAt: DateTime(2026, 1, 1));
      final sale = await addSale(product, qty: 3, soldAt: DateTime(2026, 2, 1));

      final first = await recost(product);
      expect(first['recosted_count'], 1);
      expect(await readBuyingPrice(sale), 50000);

      final second = await recost(product);
      expect(second['recosted_count'], 0,
          reason: 'nothing changed → no re-cost, no last_updated_at churn');
    }, skip: _skipReason);

    test('cancelled orders do not consume a batch', () async {
      final product = await newProduct();
      final b1 = await addBatch(product,
          costKobo: 50000, qty: 10, receivedAt: DateTime(2026, 1, 1));
      // A cancelled sale must be ignored entirely.
      await addSale(product,
          qty: 4, soldAt: DateTime(2026, 2, 1), status: 'cancelled');
      final live =
          await addSale(product, qty: 3, soldAt: DateTime(2026, 3, 1));

      await recost(product);
      expect(await readBuyingPrice(live), 50000);
      expect(await readQtyRemaining(b1), 7,
          reason: 'only the live sale of 3 drew down the batch');
    }, skip: _skipReason);
  });

  // ── pos_recost_pairs (batch roll-up) ──────────────────────────────────────

  group('pos_recost_pairs', () {
    test('recosts multiple (product, store) pairs and rolls up the count',
        () async {
      final p1 = await newProduct();
      final p2 = await newProduct();
      await addBatch(p1,
          costKobo: 50000, qty: 5, receivedAt: DateTime(2026, 1, 1));
      await addBatch(p2,
          costKobo: 70000, qty: 5, receivedAt: DateTime(2026, 1, 1));
      final s1 = await addSale(p1, qty: 2, soldAt: DateTime(2026, 2, 1));
      final s2 = await addSale(p2, qty: 2, soldAt: DateTime(2026, 2, 1));

      final res = await clients.userClient.rpc('pos_recost_pairs', params: {
        'p_business_id': businessId,
        'p_pairs': [
          {'product_id': p1, 'store_id': storeId},
          {'product_id': p2, 'store_id': storeId},
          // Duplicate pair — must be deduped, not double-counted.
          {'product_id': p1, 'store_id': storeId},
        ],
      }) as Map;

      expect(res['recosted_count'], 2);
      expect((res['pairs'] as List), hasLength(2), reason: 'deduped');
      expect(await readBuyingPrice(s1), 50000);
      expect(await readBuyingPrice(s2), 70000);
    }, skip: _skipReason);
  });
}
