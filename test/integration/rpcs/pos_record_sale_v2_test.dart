@Tags(['integration'])
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../helpers/supabase_test_clients.dart';
import '../../helpers/supabase_test_env.dart';
import '../../helpers/test_business_fixture.dart';

/// Tier-2 integration tests for the v2 pos_record_sale_v2 RPC. Hits real
/// dev Supabase. Auto-skipped when env vars are absent.
///
/// Note on cleanup: `stock_transactions`, `payment_transactions`,
/// `wallet_transactions` are all append-only — `forbid_delete` blocks
/// DELETE outright. Sale rows leak per run into the shared test
/// business. `orders` and `order_items` are deletable in principle but
/// FK references from the append-only ledgers (NO ACTION) block them
/// too. Acceptable for dev-machine integration runs; reset the test
/// business periodically.
///
/// Mid-flight rollback: this RPC has a real intermediate failure point
/// — `insufficient_stock` raises during the per-item inventory UPDATE
/// loop, after the order header + earlier order_items / stock_tx rows
/// have already been inserted. Per the redesign policy, batch 10 must
/// exercise this path and assert atomicity (no rows persist for the
/// failed sale).

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
  late TestBusinessFixture fixture;

  // Reusable store + product (admin-inserted in setUpAll).
  late String storeId;
  late String productId;
  // Product with NO inventory row at [storeId]. Used to exercise the
  // `inventory_row_missing` path that 0017 split out from `insufficient_stock`.
  late String stocklessProductId;

  Future<String> seedCustomer() async {
    final customerId = UuidV7.generate();
    final walletId = UuidV7.generate();
    await clients.userClient.rpc('pos_create_customer', params: {
      'p_business_id': clients.env.businessId,
      'p_customer_id': customerId,
      'p_wallet_id': walletId,
      'p_name': 'Sale Test Customer',
    });
    return customerId;
  }

  setUpAll(() async {
    if (_skipReason != null) return;
    clients = await TestClients.setUp();
    fixture = TestBusinessFixture(clients.adminClient, clients.env.businessId);

    storeId = UuidV7.generate();
    await clients.adminClient.from('stores').insert({
      'id': storeId,
      'business_id': clients.env.businessId,
      'name': 'Sale Test Store',
    });

    productId = UuidV7.generate();
    await clients.adminClient.from('products').insert({
      'id': productId,
      'business_id': clients.env.businessId,
      'name': 'Sale Test Beer',
      'selling_price_kobo': 100000,
    });

    // Bump the inventory high enough that round-trip + replay don't
    // exhaust stock; the mid-flight test deliberately overdraws.
    await clients.adminClient.from('inventory').insert({
      'business_id': clients.env.businessId,
      'product_id': productId,
      'store_id': storeId,
      'quantity': 1000,
    });

    // Second product, intentionally never given an inventory row at
    // [storeId]. This isolates the `inventory_row_missing` raise from
    // the `insufficient_stock` raise — see 0017 for the split rationale.
    stocklessProductId = UuidV7.generate();
    await clients.adminClient.from('products').insert({
      'id': stocklessProductId,
      'business_id': clients.env.businessId,
      'name': 'Sale Test Stockless Beer',
      'selling_price_kobo': 100000,
    });
  });

  tearDownAll(() async {
    if (_skipReason != null) return;
    await clients.dispose();
  });

  group('pos_record_sale_v2 (Tier 2)', () {
    test(
        'round-trip: full response shape, inventory deducted, server '
        'computes totals', () async {
      final orderId = UuidV7.generate();
      // Truly-unique trailing slice — UuidV7's prefix is timestamp-derived
      // and collides on rapid generation (same fix used in cancel tier-2).
      final orderNumber =
          'ORD-V2-${orderId.substring(orderId.length - 12)}';

      final response = await clients.userClient.rpc(
        'pos_record_sale_v2',
        params: {
          'p_business_id': clients.env.businessId,
          'p_actor_id': clients.env.userId,
          'p_order_id': orderId,
          'p_order_number': orderNumber,
          'p_store_id': storeId,
          'p_payment_type': 'cash',
          'p_items': [
            {
              'product_id': productId,
              'quantity': 2,
              'unit_price_kobo': 100000,
            },
          ],
          'p_amount_paid_kobo': 200000,
          'p_payment_method': 'cash',
        },
      );

      expect(response, isA<Map>());
      final map = response as Map;
      expect(map['replayed'], isFalse);

      final order = map['order'] as Map;
      expect(order['id'], orderId);
      expect(order['order_number'], orderNumber);
      expect(order['total_amount_kobo'], 200000,
          reason: 'server computes total = sum(qty * unit_price)');
      expect(order['net_amount_kobo'], 200000);
      expect(order['amount_paid_kobo'], 200000);
      expect(order['status'], 'completed');

      final items = map['order_items'] as List;
      expect(items, hasLength(1));
      final item = items.first as Map;
      expect(item['product_id'], productId);
      expect(item['quantity'], 2);
      expect(item['total_kobo'], 200000,
          reason: 'server computes per-item total');

      final stxList = map['stock_transactions'] as List;
      expect(stxList, hasLength(1));
      expect((stxList.first as Map)['quantity_delta'], -2);
      expect((stxList.first as Map)['movement_type'], 'sale');

      final payment = map['payment_transaction'] as Map;
      expect(payment['amount_kobo'], 200000);
      expect(payment['method'], 'cash');
      expect(payment['type'], 'sale');
      expect(payment['order_id'], orderId);

      // No wallet portion on this sale.
      expect(map['wallet_transaction'], isNull);

      // Cloud-side verification.
      final cloudOrder = await clients.adminClient
          .from('orders')
          .select()
          .eq('id', orderId)
          .single();
      expect(cloudOrder['status'], 'completed');
      expect(cloudOrder['total_amount_kobo'], 200000);
    }, skip: _skipReason);

    test('replay: same p_order_id returns replayed=true with existing rows',
        () async {
      final orderId = UuidV7.generate();
      final orderNumber =
          'ORD-RPL-${orderId.substring(orderId.length - 12)}';

      Map<String, dynamic> params() => {
            'p_business_id': clients.env.businessId,
            'p_actor_id': clients.env.userId,
            'p_order_id': orderId,
            'p_order_number': orderNumber,
            'p_store_id': storeId,
            'p_payment_type': 'cash',
            'p_items': [
              {
                'product_id': productId,
                'quantity': 1,
                'unit_price_kobo': 50000,
              },
            ],
            'p_amount_paid_kobo': 50000,
            'p_payment_method': 'cash',
          };

      final first = await clients.userClient
          .rpc('pos_record_sale_v2', params: params()) as Map;
      expect(first['replayed'], isFalse);

      final second = await clients.userClient
          .rpc('pos_record_sale_v2', params: params()) as Map;
      expect(second['replayed'], isTrue);

      // Cloud invariant: still exactly one order, one stock_tx for this id.
      expect(await fixture.countById('orders', orderId), 1);

      final cloudStx = await clients.adminClient
          .from('stock_transactions')
          .select('id')
          .eq('order_id', orderId);
      expect(cloudStx, hasLength(1),
          reason: 'replay must not append a second sale stock_tx');
    }, skip: _skipReason);

    test('atomicity (tenant guard): bogus business_id raises, no order',
        () async {
      final bogus = UuidV7.generate();
      final orderId = UuidV7.generate();

      Object? caught;
      try {
        await clients.userClient.rpc('pos_record_sale_v2', params: {
          'p_business_id': bogus,
          'p_actor_id': clients.env.userId,
          'p_order_id': orderId,
          'p_order_number': 'ORD-XTNT',
          'p_store_id': storeId,
          'p_payment_type': 'cash',
          'p_items': [
            {
              'product_id': productId,
              'quantity': 1,
              'unit_price_kobo': 1000,
            },
          ],
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(await fixture.countById('orders', orderId), 0);
    }, skip: _skipReason);

    test(
        'atomicity (mid-flight): two-item sale where the SECOND fails on '
        'insufficient_stock rolls back the FIRST + the order header',
        () async {
      // Read inventory pre-call so we can assert it didn't change.
      final preInv = await clients.adminClient
          .from('inventory')
          .select('quantity')
          .eq('business_id', clients.env.businessId)
          .eq('product_id', productId)
          .eq('store_id', storeId)
          .single();
      final preQty = preInv['quantity'] as int;

      final orderId = UuidV7.generate();
      Object? caught;
      try {
        await clients.userClient.rpc('pos_record_sale_v2', params: {
          'p_business_id': clients.env.businessId,
          'p_actor_id': clients.env.userId,
          'p_order_id': orderId,
          'p_order_number':
              'ORD-MF-${orderId.substring(orderId.length - 12)}',
          'p_store_id': storeId,
          'p_payment_type': 'cash',
          'p_items': [
            // Item 1: succeeds — small qty.
            {
              'product_id': productId,
              'quantity': 1,
              'unit_price_kobo': 100000,
            },
            // Item 2: fails — overdraw blows the stock guard mid-flight,
            // AFTER item 1's order_items + inventory UPDATE + stock_tx
            // have all been written within the txn.
            {
              'product_id': productId,
              'quantity': 100000,
              'unit_price_kobo': 100000,
            },
          ],
          'p_amount_paid_kobo': 100000,
          'p_payment_method': 'cash',
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull,
          reason: 'insufficient_stock should fire on item 2');

      // Atomicity proof:
      //   - order header NOT inserted (rolled back).
      //   - no order_items rows for this order_id.
      //   - no stock_tx rows for this order_id (item 1's row was rolled back).
      //   - no payment_transactions row for this order_id.
      //   - inventory unchanged (item 1's deduction reverted).
      expect(await fixture.countById('orders', orderId), 0,
          reason: 'order header must roll back on mid-flight raise');

      final cloudItems = await clients.adminClient
          .from('order_items')
          .select('id')
          .eq('order_id', orderId);
      expect(cloudItems, isEmpty,
          reason: 'item 1 must roll back when item 2 fails');

      final cloudStx = await clients.adminClient
          .from('stock_transactions')
          .select('id')
          .eq('order_id', orderId);
      expect(cloudStx, isEmpty,
          reason: 'item 1 stock_tx must roll back too');

      final cloudPay = await clients.adminClient
          .from('payment_transactions')
          .select('id')
          .eq('order_id', orderId);
      expect(cloudPay, isEmpty);

      final postInv = await clients.adminClient
          .from('inventory')
          .select('quantity')
          .eq('business_id', clients.env.businessId)
          .eq('product_id', productId)
          .eq('store_id', storeId)
          .single();
      expect(postInv['quantity'], preQty,
          reason: 'inventory must be unchanged after a mid-flight rollback');
    }, skip: _skipReason);

    test(
        'atomicity (validation): empty items rejected before any write',
        () async {
      final orderId = UuidV7.generate();
      Object? caught;
      try {
        await clients.userClient.rpc('pos_record_sale_v2', params: {
          'p_business_id': clients.env.businessId,
          'p_actor_id': clients.env.userId,
          'p_order_id': orderId,
          'p_order_number':
              'ORD-EMPTY-${orderId.substring(orderId.length - 12)}',
          'p_store_id': storeId,
          'p_payment_type': 'cash',
          'p_items': [],
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull,
          reason: 'items_required guard should fire on empty array');
      expect(await fixture.countById('orders', orderId), 0);
    }, skip: _skipReason);

    test(
        'wallet portion: customer with sufficient balance → wallet_transaction '
        'returned, balance debited atomically', () async {
      final customerId = await seedCustomer();
      // Top up the wallet so there's something to debit.
      final topupTxnId = UuidV7.generate();
      final topupPayId = UuidV7.generate();
      await clients.userClient.rpc('pos_wallet_topup', params: {
        'p_business_id': clients.env.businessId,
        'p_actor_id': clients.env.userId,
        'p_wallet_txn_id': topupTxnId,
        'p_payment_id': topupPayId,
        'p_customer_id': customerId,
        'p_amount_kobo': 50000,
        'p_method': 'cash',
        'p_reference_type': 'topup_cash',
      });

      final orderId = UuidV7.generate();
      final response = await clients.userClient.rpc(
        'pos_record_sale_v2',
        params: {
          'p_business_id': clients.env.businessId,
          'p_actor_id': clients.env.userId,
          'p_order_id': orderId,
          'p_order_number':
              'ORD-WAL-${orderId.substring(orderId.length - 12)}',
          'p_store_id': storeId,
          'p_payment_type': 'wallet',
          'p_items': [
            {
              'product_id': productId,
              'quantity': 1,
              'unit_price_kobo': 30000,
            },
          ],
          'p_customer_id': customerId,
          'p_amount_paid_kobo': 30000,
          'p_payment_method': 'cash',
          'p_wallet_amount_kobo': 30000,
        },
      ) as Map;

      final walletTxn = response['wallet_transaction'] as Map;
      expect(walletTxn['type'], 'debit');
      expect(walletTxn['amount_kobo'], 30000);
      expect(walletTxn['signed_amount_kobo'], -30000);
      expect(walletTxn['reference_type'], 'order_payment');
      expect(walletTxn['order_id'], orderId);
      expect(walletTxn['customer_id'], customerId);
    }, skip: _skipReason);

    test(
        'error: inventory_row_missing raises (with HINT) when no inventory '
        'row exists for product+store — 0017 split guard',
        () async {
      final orderId = UuidV7.generate();
      Object? caught;
      try {
        await clients.userClient.rpc('pos_record_sale_v2', params: {
          'p_business_id': clients.env.businessId,
          'p_actor_id': clients.env.userId,
          'p_order_id': orderId,
          'p_order_number':
              'ORD-MISS-${orderId.substring(orderId.length - 12)}',
          'p_store_id': storeId,
          'p_payment_type': 'cash',
          'p_items': [
            {
              'product_id': stocklessProductId,
              'quantity': 1,
              'unit_price_kobo': 50000,
            },
          ],
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<PostgrestException>(),
          reason: 'RPC must surface a Postgrest error');
      final ex = caught as PostgrestException;
      expect(ex.message, contains('inventory_row_missing'),
          reason:
              'must be the missing-row error, not insufficient_stock — see 0017');
      expect(ex.hint, isNotNull,
          reason: '0017 attaches a JSON HINT for diagnostics');
      final hint = jsonDecode(ex.hint!) as Map<String, dynamic>;
      expect(hint['product_id'], stocklessProductId);
      expect(hint['store_id'], storeId);

      // Atomicity: nothing landed.
      expect(await fixture.countById('orders', orderId), 0,
          reason: 'pre-write raise must not leave an order header');
    }, skip: _skipReason);

    test(
        'error: insufficient_stock still raises (with available_qty) when '
        'row exists but qty too low — confirms 0017 did not collapse cases',
        () async {
      // Read current quantity so we request strictly more.
      final preInv = await clients.adminClient
          .from('inventory')
          .select('quantity')
          .eq('business_id', clients.env.businessId)
          .eq('product_id', productId)
          .eq('store_id', storeId)
          .single();
      final available = preInv['quantity'] as int;

      final orderId = UuidV7.generate();
      Object? caught;
      try {
        await clients.userClient.rpc('pos_record_sale_v2', params: {
          'p_business_id': clients.env.businessId,
          'p_actor_id': clients.env.userId,
          'p_order_id': orderId,
          'p_order_number':
              'ORD-LOW-${orderId.substring(orderId.length - 12)}',
          'p_store_id': storeId,
          'p_payment_type': 'cash',
          'p_items': [
            {
              'product_id': productId,
              'quantity': available + 1,
              'unit_price_kobo': 100000,
            },
          ],
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<PostgrestException>());
      final ex = caught as PostgrestException;
      expect(ex.message, contains('insufficient_stock'),
          reason:
              'must be the low-qty error, not inventory_row_missing — see 0017');
      expect(ex.hint, isNotNull);
      final hint = jsonDecode(ex.hint!) as Map<String, dynamic>;
      expect(hint['product_id'], productId);
      expect(hint['store_id'], storeId);
      expect(hint['available_qty'], available,
          reason: '0017 added available_qty to the HINT');

      expect(await fixture.countById('orders', orderId), 0);
    }, skip: _skipReason);

    test(
        'atomicity (inventory_row_missing): two-item sale where item 2 has '
        'no inventory row rolls back item 1 + the order header',
        () async {
      // Snapshot inventory before the call so we can prove item 1 reverted.
      final preInv = await clients.adminClient
          .from('inventory')
          .select('quantity')
          .eq('business_id', clients.env.businessId)
          .eq('product_id', productId)
          .eq('store_id', storeId)
          .single();
      final preQty = preInv['quantity'] as int;

      final orderId = UuidV7.generate();
      Object? caught;
      try {
        await clients.userClient.rpc('pos_record_sale_v2', params: {
          'p_business_id': clients.env.businessId,
          'p_actor_id': clients.env.userId,
          'p_order_id': orderId,
          'p_order_number':
              'ORD-MFM-${orderId.substring(orderId.length - 12)}',
          'p_store_id': storeId,
          'p_payment_type': 'cash',
          'p_items': [
            // Item 1: succeeds — order_items + inventory UPDATE + stock_tx
            // are all written within the txn.
            {
              'product_id': productId,
              'quantity': 1,
              'unit_price_kobo': 100000,
            },
            // Item 2: fails — no inventory row exists for this product at
            // [storeId], triggering the 0017 raise.
            {
              'product_id': stocklessProductId,
              'quantity': 1,
              'unit_price_kobo': 100000,
            },
          ],
          'p_amount_paid_kobo': 100000,
          'p_payment_method': 'cash',
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<PostgrestException>());
      expect((caught as PostgrestException).message,
          contains('inventory_row_missing'));

      // Atomicity proof — same shape as the insufficient_stock variant.
      expect(await fixture.countById('orders', orderId), 0,
          reason: 'order header must roll back on mid-flight raise');

      final cloudItems = await clients.adminClient
          .from('order_items')
          .select('id')
          .eq('order_id', orderId);
      expect(cloudItems, isEmpty,
          reason: 'item 1 must roll back when item 2 fails');

      final cloudStx = await clients.adminClient
          .from('stock_transactions')
          .select('id')
          .eq('order_id', orderId);
      expect(cloudStx, isEmpty,
          reason: 'item 1 stock_tx must roll back too');

      final postInv = await clients.adminClient
          .from('inventory')
          .select('quantity')
          .eq('business_id', clients.env.businessId)
          .eq('product_id', productId)
          .eq('store_id', storeId)
          .single();
      expect(postInv['quantity'], preQty,
          reason: 'item 1 inventory deduction must roll back');
    }, skip: _skipReason);
  });
}
