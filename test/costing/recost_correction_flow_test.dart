import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../helpers/dispatch_test_utils.dart';
import '../helpers/in_memory_cloud_transport.dart';

/// The client correction flow for FIFO batch costing (Epic 2 / ADR 0005,
/// issue #40). After a sync batch delivers sale lines to the cloud, the client
/// asks the server to re-derive the authoritative COGS for the touched
/// (product, store) pairs (`pos_recost_pairs`, migration 0133). The correction
/// then:
///   • replaces the provisional `OrderItems.buyingPriceKobo` snapshot as an
///     ordinary LWW row update on the next pull (no merge conflict), and
///   • is audited with EXACTLY ONE rolled-up Activity Log row per sync batch —
///     never a per-sale prompt, and only when something actually changed.
///
/// Driven through the real [SupabaseSyncService] + the in-memory transport, so
/// the engine → seam wiring (RPC call + LWW restore) is exercised end-to-end
/// without a live Supabase.
void main() {
  late AppDatabase db;
  late String businessId;
  late InMemoryCloudTransport transport;
  late SupabaseSyncService sync;
  late String storeId;
  late String productId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    transport = InMemoryCloudTransport(authUserId: 'user-1');
    sync = SupabaseSyncService(db, transport);

    storeId = UuidV7.generate();
    await db.into(db.stores).insert(
          StoresCompanion.insert(
              id: Value(storeId), businessId: businessId, name: 'Main'),
        );
    productId = UuidV7.generate();
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: Value(productId),
            businessId: businessId,
            name: 'Star 60cl',
            retailerPriceKobo: const Value(100000),
            unit: const Value('Bottle'),
          ),
        );
  });

  tearDown(() async {
    await transport.dispose();
    await db.close();
  });

  /// Inserts an order + one order_item for [productId], stamping a provisional
  /// [buyingPriceKobo] and an OLD [lastUpdatedAt] (so a later cloud correction
  /// wins the LWW). No sync_queue entry — the row is treated as already pushed,
  /// so Invariant #12 does not protect it from the correction.
  Future<String> seedProvisionalSale({
    required int buyingPriceKobo,
    required DateTime lastUpdatedAt,
    int quantity = 10,
  }) async {
    final orderId = UuidV7.generate();
    await db.into(db.orders).insert(
          OrdersCompanion.insert(
            id: Value(orderId),
            businessId: businessId,
            orderNumber: 'ORD-${UuidV7.generate().substring(0, 8)}',
            totalAmountKobo: quantity * 100000,
            netAmountKobo: quantity * 100000,
            paymentType: 'cash',
            status: 'completed',
            storeId: Value(storeId),
            lastUpdatedAt: Value(lastUpdatedAt),
          ),
        );
    final itemId = UuidV7.generate();
    await db.into(db.orderItems).insert(
          OrderItemsCompanion.insert(
            id: Value(itemId),
            businessId: businessId,
            orderId: orderId,
            productId: Value(productId),
            storeId: storeId,
            quantity: quantity,
            unitPriceKobo: 100000,
            buyingPriceKobo: Value(buyingPriceKobo),
            totalKobo: quantity * 100000,
            lastUpdatedAt: Value(lastUpdatedAt),
          ),
        );
    return itemId;
  }

  Future<int> buyingPriceOf(String itemId) async {
    final row = await (db.select(db.orderItems)
          ..where((i) => i.id.equals(itemId)))
        .getSingle();
    return row.buyingPriceKobo;
  }

  Future<List<ActivityLogData>> activityLogs() =>
      (db.select(db.activityLogs)).get();

  ({String productId, String storeId}) pairFor(String pid) =>
      (productId: pid, storeId: storeId);

  test(
      'server-corrected COGS replaces the provisional as an LWW update and '
      'writes exactly one rolled-up Activity Log row', () async {
    // Provisional COGS is present pre-sync (the offline till's local estimate).
    final oldTs = DateTime.utc(2026, 7, 4, 10);
    final itemId =
        await seedProvisionalSale(buyingPriceKobo: 5000, lastUpdatedAt: oldTs);
    expect(await buyingPriceOf(itemId), 5000, reason: 'provisional present');

    // The server re-derives the authoritative COGS: it changed 3 sale lines of
    // this product and (in real life) rewrote their buying_price_kobo.
    transport.stubRpc('pos_recost_pairs', (params) {
      return {
        'recosted_count': 3,
        'pairs': [
          {
            'product_id': productId,
            'store_id': storeId,
            'recosted_count': 3,
            'recosted_lines': [
              {'line_id': itemId, 'cogs_per_unit_kobo': 5400}
            ],
          },
        ],
      };
    });

    final total = await sync.reconcilePushedSaleCosts({pairFor(productId)}, businessId);
    expect(total, 3);

    // The recost RPC was called for exactly the touched pair.
    final calls = transport.rpcCalls.where((c) => c.name == 'pos_recost_pairs');
    expect(calls, hasLength(1));
    expect(calls.single.params['p_business_id'], businessId);
    expect(calls.single.params['p_pairs'], [
      {'product_id': productId, 'store_id': storeId},
    ]);

    // Exactly one rolled-up Activity Log row, naming the product + count and
    // worded as batch-boundary reconciliation. No per-sale prompt.
    final logs = await activityLogs();
    expect(logs, hasLength(1));
    expect(logs.single.action, 'cost.recosted_on_sync');
    expect(logs.single.description, contains('3 sales'));
    expect(logs.single.description, contains('Star 60cl'));
    expect(logs.single.description, contains('batch-boundary reconciliation'));

    // The authoritative value now flows down as an ordinary LWW row update
    // (newer last_updated_at) and replaces the provisional snapshot — no merge
    // conflict, no special-casing.
    await sync.restoreTableDataForTesting('order_items', [
      {
        'id': itemId,
        'business_id': businessId,
        'order_id': (await (db.select(db.orderItems)
                  ..where((i) => i.id.equals(itemId)))
                .getSingle())
            .orderId,
        'product_id': productId,
        'store_id': storeId,
        'quantity': 10,
        'unit_price_kobo': 100000,
        'buying_price_kobo': 5400,
        'total_kobo': 1000000,
        'created_at': oldTs.toIso8601String(),
        'last_updated_at': DateTime.utc(2026, 7, 4, 11).toIso8601String(),
      },
    ]);
    expect(await buyingPriceOf(itemId), 5400,
        reason: 'corrected value replaced the provisional via LWW');
  });

  test('no correction (recosted_count 0) writes no Activity Log row', () async {
    // Single-till happy path: the provisional already equalled the
    // authoritative, so the server re-costs nothing — nothing to audit.
    await seedProvisionalSale(
        buyingPriceKobo: 5400, lastUpdatedAt: DateTime.utc(2026, 7, 4, 10));
    transport.stubRpc('pos_recost_pairs', (_) => {
          'recosted_count': 0,
          'pairs': <Map<String, dynamic>>[],
        });

    final total =
        await sync.reconcilePushedSaleCosts({pairFor(productId)}, businessId);
    expect(total, 0);
    expect(await activityLogs(), isEmpty,
        reason: 'silent no-op when nothing was re-costed');
  });

  test('no touched pairs → the recost RPC is never called', () async {
    final total = await sync.reconcilePushedSaleCosts({}, businessId);
    expect(total, 0);
    expect(transport.rpcCalls.where((c) => c.name == 'pos_recost_pairs'),
        isEmpty);
    expect(await activityLogs(), isEmpty);
  });

  test('a batch spanning several products rolls up into ONE row', () async {
    final product2 = UuidV7.generate();
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: Value(product2),
            businessId: businessId,
            name: 'Trophy 60cl',
            retailerPriceKobo: const Value(100000),
            unit: const Value('Bottle'),
          ),
        );
    transport.stubRpc('pos_recost_pairs', (_) => {
          'recosted_count': 5,
          'pairs': [
            {'product_id': productId, 'store_id': storeId, 'recosted_count': 2},
            {'product_id': product2, 'store_id': storeId, 'recosted_count': 3},
          ],
        });

    final total = await sync.reconcilePushedSaleCosts(
      {pairFor(productId), pairFor(product2)},
      businessId,
    );
    expect(total, 5);

    final logs = await activityLogs();
    expect(logs, hasLength(1), reason: 'one rolled-up row, not one per product');
    expect(logs.single.description, contains('5 sales'));
    expect(logs.single.description, contains('across 2 products'));
    expect(logs.single.description, contains('batch-boundary reconciliation'));
  });

  test('a failed recost RPC is swallowed (best-effort, off the sale path)',
      () async {
    await seedProvisionalSale(
        buyingPriceKobo: 5000, lastUpdatedAt: DateTime.utc(2026, 7, 4, 10));
    transport.failRpc(
      'pos_recost_pairs',
      const PostgrestException(message: 'boom', code: '500'),
    );

    final total =
        await sync.reconcilePushedSaleCosts({pairFor(productId)}, businessId);
    expect(total, 0, reason: 'never throws — the recost self-heals next sync');
    expect(await activityLogs(), isEmpty);
  });

  // ── The pure pair collectors (which sale rows a push made recost candidates) ─

  group('recost pair collectors', () {
    test('collectOrderItemPairs gathers (product, store), dedups, skips '
        'quick-sale (null product) lines', () {
      final into = <({String productId, String storeId})>{};
      SupabaseSyncService.collectOrderItemPairs([
        {'product_id': 'p1', 'store_id': 's1'},
        {'product_id': 'p1', 'store_id': 's1'}, // duplicate → one pair
        {'product_id': 'p2', 'store_id': 's1'},
        {'product_id': null, 'store_id': 's1'}, // quick sale → skipped
        {'store_id': 's1'}, // missing product → skipped
      ], into);
      expect(into, {
        (productId: 'p1', storeId: 's1'),
        (productId: 'p2', storeId: 's1'),
      });
    });

    test('collectSaleEnvelopePairs pairs each item with the sale-level store, '
        'skipping quick-sale lines', () {
      final into = <({String productId, String storeId})>{};
      SupabaseSyncService.collectSaleEnvelopePairs({
        'p_store_id': 'sX',
        'p_items': [
          {'product_id': 'a', 'quantity': 2},
          {'product_id': 'b', 'quantity': 1},
          {'quantity': 1}, // quick-sale line → no product → skipped
        ],
      }, into);
      expect(into, {
        (productId: 'a', storeId: 'sX'),
        (productId: 'b', storeId: 'sX'),
      });
    });

    test('collectSaleEnvelopePairs is a no-op on a malformed envelope', () {
      final into = <({String productId, String storeId})>{};
      SupabaseSyncService.collectSaleEnvelopePairs(
          {'p_items': 'not-a-list'}, into);
      SupabaseSyncService.collectSaleEnvelopePairs(
          {'p_store_id': 'sX'}, into); // no items
      expect(into, isEmpty);
    });
  });
}
