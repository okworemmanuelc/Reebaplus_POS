@Tags(['integration'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../../helpers/supabase_test_clients.dart';
import '../../helpers/supabase_test_env.dart';
import '../../helpers/test_business_fixture.dart';

/// Tier-2 integration tests for the v2 pos_cancel_order RPC. Hits real
/// dev Supabase. Auto-skipped when env vars are absent.
///
/// Since #201 / migration 0169 the cancel implements the #155 rule: it APPENDS
/// one dated compensating row per reversible original and mutates nothing — no
/// in-place void, deposits and top-ups reversed in their own money families
/// (never as `refund`), every wallet leg reversed, and the drawn cost layer
/// restored. These tests pin that rule; they will FAIL against a cloud that
/// predates 0169 (which voided the originals and posted a full-amount `refund`
/// for every row).
///
/// Note on cleanup:
///   * `stock_transactions`, `payment_transactions`, `wallet_transactions`,
///     `crate_ledger`, and `activity_logs` are append-only — the cancel
///     RPC inserts compensating rows. None of those rows can be deleted via
///     REST. They leak per test. Since 0169 a cancel also inserts one
///     `cost_batches` row per line; those leak too, which is harmless here —
///     the store and product are created once in `setUpAll` and are themselves
///     left behind, so nothing FK-blocks on them.
///   * `orders` and `order_items` are deletable in principle, but FK
///     references from the append-only ledgers (NO ACTION) block them.
///     They also leak.
///
/// Acceptable for dev-machine integration runs; reset the test business
/// periodically if rows accumulate.
///
/// Note on mid-flight rollback:
///   The cancel RPC has no intermediate failure points between the
///   `UPDATE orders SET status='cancelled'` and the final RETURN — every
///   compensating INSERT references existing parent ids that are valid
///   by construction. Triggering a deterministic mid-flight failure
///   would require contrived setup (e.g. racing a concurrent DELETE),
///   which doesn't reflect a real-world hazard. We exercise atomicity
///   via the validation guards instead (tenant + status), each of which
///   raises before the order header is mutated and which we verify by
///   re-reading the order's status post-failure.

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

  // One store + product reused across tests; admin-inserted in setUpAll.
  late String storeId;
  late String productId;

  // Per-test resources.
  final createdCustomerIds = <String>[];

  Future<({String orderId, String customerId, String paymentId, String stxId})>
      seedCompletedSale({int qty = 2, int unitPriceKobo = 100000}) async {
    final customerId = UuidV7.generate();
    final walletId = UuidV7.generate();
    await clients.userClient.rpc('pos_create_customer', params: {
      'p_business_id': clients.env.businessId,
      'p_customer_id': customerId,
      'p_wallet_id': walletId,
      'p_name': 'Cancel Test Customer',
    });
    createdCustomerIds.add(customerId);

    final orderId = UuidV7.generate();
    // UuidV7's leading chars are timestamp-derived and collide across
    // rapid generations; use the trailing random segment for uniqueness.
    final orderNumber = 'ORD-T-${orderId.substring(orderId.length - 12)}';
    final totalKobo = qty * unitPriceKobo;
    await clients.adminClient.from('orders').insert({
      'id': orderId,
      'business_id': clients.env.businessId,
      'order_number': orderNumber,
      'customer_id': customerId,
      'total_amount_kobo': totalKobo,
      'net_amount_kobo': totalKobo,
      'amount_paid_kobo': totalKobo,
      'payment_type': 'cash',
      'status': 'completed',
      'staff_id': clients.env.userId,
      'store_id': storeId,
      'completed_at': DateTime.now().toUtc().toIso8601String(),
    });

    await clients.adminClient.from('order_items').insert({
      'business_id': clients.env.businessId,
      'order_id': orderId,
      'product_id': productId,
      'store_id': storeId,
      'quantity': qty,
      'unit_price_kobo': unitPriceKobo,
      'total_kobo': totalKobo,
    });

    final stxId = UuidV7.generate();
    await clients.adminClient.from('stock_transactions').insert({
      'id': stxId,
      'business_id': clients.env.businessId,
      'product_id': productId,
      'location_id': storeId,
      'quantity_delta': -qty,
      'movement_type': 'sale',
      'order_id': orderId,
      'performed_by': clients.env.userId,
    });

    final paymentId = UuidV7.generate();
    await clients.adminClient.from('payment_transactions').insert({
      'id': paymentId,
      'business_id': clients.env.businessId,
      'amount_kobo': totalKobo,
      'method': 'cash',
      'type': 'sale',
      'order_id': orderId,
      'performed_by': clients.env.userId,
    });

    return (
      orderId: orderId,
      customerId: customerId,
      paymentId: paymentId,
      stxId: stxId,
    );
  }

  setUpAll(() async {
    if (_skipReason != null) return;
    clients = await TestClients.setUp();
    fixture = TestBusinessFixture(clients.adminClient, clients.env.businessId);

    // Reusable store + product (idempotent — leak across runs is fine).
    storeId = UuidV7.generate();
    await clients.adminClient.from('stores').insert({
      'id': storeId,
      'business_id': clients.env.businessId,
      'name': 'Cancel Test Store',
    });

    productId = UuidV7.generate();
    await clients.adminClient.from('products').insert({
      'id': productId,
      'business_id': clients.env.businessId,
      'name': 'Cancel Test Beer',
      'selling_price_kobo': 100000,
    });

    // Inventory: seed plenty so test cancellations don't underflow on
    // restore. The RPC INSERTs ON CONFLICT DO UPDATE adds to whatever
    // is here, so a high starting point is fine.
    await clients.adminClient.from('inventory').insert({
      'business_id': clients.env.businessId,
      'product_id': productId,
      'store_id': storeId,
      'quantity': 1000,
    });
  });

  tearDown(() async {
    if (_skipReason != null) return;
    for (final id in createdCustomerIds) {
      await fixture.deleteCustomerCascade(id);
    }
    createdCustomerIds.clear();
  });

  tearDownAll(() async {
    if (_skipReason != null) return;
    await clients.dispose();
  });

  group('pos_cancel_order (Tier 2)', () {
    test('round-trip: order flips, compensating rows + refund returned',
        () async {
      final s = await seedCompletedSale(qty: 2, unitPriceKobo: 100000);

      final response = await clients.userClient.rpc(
        'pos_cancel_order',
        params: {
          'p_business_id': clients.env.businessId,
          'p_actor_id': clients.env.userId,
          'p_order_id': s.orderId,
          'p_cancellation_reason': 'customer changed mind',
        },
      );

      expect(response, isA<Map>());
      final map = response as Map;
      expect(map['replayed'], isFalse);

      final order = map['order'] as Map;
      expect(order['id'], s.orderId);
      expect(order['status'], 'cancelled');
      expect(order['cancelled_at'], isNotNull);
      expect(order['cancellation_reason'], 'customer changed mind');

      final stxList = map['stock_transactions'] as List;
      expect(stxList, hasLength(1),
          reason: 'one compensating return row per order item');
      final compStx = stxList.first as Map;
      expect(compStx['movement_type'], 'return');
      expect(compStx['quantity_delta'], 2);
      expect(compStx['order_id'], s.orderId);

      // #201 — nothing is voided in place any more; the key is retained for
      // envelope compatibility and is always empty.
      final voided = map['voided_payments'] as List;
      expect(voided, isEmpty,
          reason: 'the append-only rule (#172): originals are never mutated');

      final refunds = map['refund_payments'] as List;
      expect(refunds, hasLength(1));
      final refund = refunds.first as Map;
      expect(refund['type'], 'refund');
      expect(refund['amount_kobo'], 200000);
      expect(refund['order_id'], s.orderId);
      expect(refund['void_reason'], 'order_cancelled: customer changed mind',
          reason: 'the correction reason is recorded on the compensating row');

      final compens = map['wallet_compensations'] as List;
      expect(compens, isEmpty,
          reason: 'no wallet leg on this order, so nothing to compensate');

      final restoredBatches = map['cost_batches'] as List;
      expect(restoredBatches, hasLength(1),
          reason: 'one restored cost layer per sale line (#170 #7c / 0167)');
      expect((restoredBatches.first as Map)['qty_remaining'], 2);

      // Cloud-side verification: the ORIGINAL payment is untouched, a dated
      // refund row was appended, sale stock_tx unchanged but a "return" appeared.
      final cloudPayments = await clients.adminClient
          .from('payment_transactions')
          .select()
          .eq('order_id', s.orderId);
      expect(cloudPayments, hasLength(2),
          reason: 'one sale (intact) + one compensating refund');
      final original = (cloudPayments as List).firstWhere(
          (p) => (p as Map)['id'] == s.paymentId) as Map;
      expect(original['voided_at'], isNull,
          reason: 'no in-place void — the sale day is never rewritten');

      final cloudStx = await clients.adminClient
          .from('stock_transactions')
          .select()
          .eq('order_id', s.orderId);
      expect(cloudStx, hasLength(2),
          reason: 'one sale + one compensating return');
    }, skip: _skipReason);

    test('replay: second cancel returns replayed=true; no extra rows',
        () async {
      final s = await seedCompletedSale(qty: 1, unitPriceKobo: 50000);

      Map<String, dynamic> params() => {
            'p_business_id': clients.env.businessId,
            'p_actor_id': clients.env.userId,
            'p_order_id': s.orderId,
            'p_cancellation_reason': 'replay test',
          };

      final first = await clients.userClient
          .rpc('pos_cancel_order', params: params()) as Map;
      expect(first['replayed'], isFalse);

      final second = await clients.userClient
          .rpc('pos_cancel_order', params: params()) as Map;
      expect(second['replayed'], isTrue);
      // Replay arrays are empty by contract — replay does not re-emit
      // the original cancel's compensating rows.
      expect(second['stock_transactions'], isEmpty);
      expect(second['voided_payments'], isEmpty);
      expect(second['refund_payments'], isEmpty);
      expect(second['cost_batches'], isEmpty,
          reason: 'a replay must not append a second restored cost layer');

      // Cloud invariant: still one sale + one return, one intact sale-pay
      // + one refund. No duplicates.
      final cloudStx = await clients.adminClient
          .from('stock_transactions')
          .select('id')
          .eq('order_id', s.orderId);
      expect(cloudStx, hasLength(2),
          reason: 'replay must not append a third stock_tx row');

      final cloudPay = await clients.adminClient
          .from('payment_transactions')
          .select('id')
          .eq('order_id', s.orderId);
      expect(cloudPay, hasLength(2),
          reason: 'replay must not append a second refund');
    }, skip: _skipReason);

    test(
        'atomicity (tenant guard): bogus business_id raises, order untouched',
        () async {
      final s = await seedCompletedSale();
      final bogus = UuidV7.generate();

      Object? caught;
      try {
        await clients.userClient.rpc('pos_cancel_order', params: {
          'p_business_id': bogus,
          'p_actor_id': clients.env.userId,
          'p_order_id': s.orderId,
          'p_cancellation_reason': 'cross-tenant attempt',
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);

      // The tenant guard fires before any UPDATE: the order's status must
      // still be 'completed' and no return-stx must exist.
      final cloudOrder = await clients.adminClient
          .from('orders')
          .select('status')
          .eq('id', s.orderId)
          .single();
      expect(cloudOrder['status'], 'completed',
          reason: 'tenant_mismatch must roll back before status flips');

      final cloudStx = await clients.adminClient
          .from('stock_transactions')
          .select('id')
          .eq('order_id', s.orderId)
          .eq('movement_type', 'return');
      expect(cloudStx, isEmpty,
          reason: 'no compensating row created on a failed cancel');
    }, skip: _skipReason);

    test(
        'atomicity (status guard): refunded order cannot be cancelled '
        'mid-flight, header unchanged', () async {
      final s = await seedCompletedSale();
      // Force the order into a non-pending/non-completed state via service
      // role. The RPC's status guard will raise — the test asserts the
      // failure does not partially flip the header to 'cancelled'.
      await clients.adminClient
          .from('orders')
          .update({'status': 'refunded'}).eq('id', s.orderId);

      Object? caught;
      try {
        await clients.userClient.rpc('pos_cancel_order', params: {
          'p_business_id': clients.env.businessId,
          'p_actor_id': clients.env.userId,
          'p_order_id': s.orderId,
          'p_cancellation_reason': 'should not apply',
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull,
          reason: 'cannot_cancel_status_refunded guard should fire');

      final cloudOrder = await clients.adminClient
          .from('orders')
          .select('status, cancelled_at, cancellation_reason')
          .eq('id', s.orderId)
          .single();
      expect(cloudOrder['status'], 'refunded',
          reason: 'header must NOT flip to cancelled on a guard raise');
      expect(cloudOrder['cancelled_at'], isNull);
      expect(cloudOrder['cancellation_reason'], isNull);

      final cloudStx = await clients.adminClient
          .from('stock_transactions')
          .select('id')
          .eq('order_id', s.orderId)
          .eq('movement_type', 'return');
      expect(cloudStx, isEmpty);
    }, skip: _skipReason);
  });
}
