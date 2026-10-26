@Tags(['integration'])
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../../helpers/supabase_test_clients.dart';
import '../../helpers/supabase_test_env.dart';

/// Tier-2 (live dev Supabase, auto-skipped without env) for #550 / migration
/// 0227 — "first reversal wins". Two phones reverse the same order: the first
/// claim lands (and its rows upload after it), the second is rejected WHOLE
/// (`reversal_already_applied`, P0001): its rows were held on the phone, so no
/// stock, payment or wallet row of it ever reaches the cloud. Also pins the
/// winner's idempotent retry, the evidence rule for an order reversed without a
/// claim (v2 pos_cancel_order), and the sticky cancellation on the header.
///
/// Ledger rows are append-only and leak per run, like pos_cancel_order_test.

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
  late String storeId;
  late String productId;

  Future<String> seedCompletedSale() async {
    final orderId = UuidV7.generate();
    await clients.adminClient.from('orders').insert({
      'id': orderId,
      'business_id': clients.env.businessId,
      'order_number': 'ORD-REV-${orderId.substring(orderId.length - 12)}',
      'total_amount_kobo': 100000,
      'net_amount_kobo': 100000,
      'amount_paid_kobo': 100000,
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
      'quantity': 1,
      'unit_price_kobo': 100000,
      'total_kobo': 100000,
    });
    await clients.adminClient.from('stock_transactions').insert({
      'id': UuidV7.generate(),
      'business_id': clients.env.businessId,
      'product_id': productId,
      'location_id': storeId,
      'quantity_delta': -1,
      'movement_type': 'sale',
      'order_id': orderId,
      'performed_by': clients.env.userId,
    });
    await clients.adminClient.from('payment_transactions').insert({
      'id': UuidV7.generate(),
      'business_id': clients.env.businessId,
      'amount_kobo': 100000,
      'method': 'cash',
      'type': 'sale',
      'order_id': orderId,
      'performed_by': clients.env.userId,
    });
    return orderId;
  }

  Future<dynamic> claim(String orderId, String reversalId, String reason) =>
      clients.userClient.rpc('pos_claim_order_reversal', params: {
        'p_business_id': clients.env.businessId,
        'p_actor_id': clients.env.userId,
        'p_order_id': orderId,
        'p_reversal_id': reversalId,
        'p_cancellation_reason': reason,
        'p_cancelled_at': DateTime.now().toUtc().toIso8601String(),
      });

  /// The winner's held rows, uploaded after its claim lands (as the drain does).
  Future<void> uploadReversalRows(String orderId) async {
    await clients.userClient.from('stock_transactions').upsert({
      'id': UuidV7.generate(),
      'business_id': clients.env.businessId,
      'product_id': productId,
      'location_id': storeId,
      'quantity_delta': 1,
      'movement_type': 'return',
      'order_id': orderId,
      'performed_by': clients.env.userId,
    });
    await clients.userClient.from('payment_transactions').upsert({
      'id': UuidV7.generate(),
      'business_id': clients.env.businessId,
      'amount_kobo': 100000,
      'method': 'cash',
      'type': 'refund',
      'order_id': orderId,
      'performed_by': clients.env.userId,
    });
  }

  Future<({int stock, int payments, int wallet})> rowCounts(
    String orderId,
  ) async {
    final stock = await clients.adminClient
        .from('stock_transactions')
        .select('id')
        .eq('order_id', orderId);
    final payments = await clients.adminClient
        .from('payment_transactions')
        .select('id')
        .eq('order_id', orderId);
    final wallet = await clients.adminClient
        .from('wallet_transactions')
        .select('id')
        .eq('order_id', orderId);
    return (
      stock: (stock as List).length,
      payments: (payments as List).length,
      wallet: (wallet as List).length,
    );
  }

  setUpAll(() async {
    if (_skipReason != null) return;
    clients = await TestClients.setUp();
    storeId = UuidV7.generate();
    await clients.adminClient.from('stores').insert({
      'id': storeId,
      'business_id': clients.env.businessId,
      'name': 'Reversal Test Store',
    });
    productId = UuidV7.generate();
    await clients.adminClient.from('products').insert({
      'id': productId,
      'business_id': clients.env.businessId,
      'name': 'Reversal Test Beer',
      'selling_price_kobo': 100000,
    });
  });

  tearDownAll(() async {
    if (_skipReason != null) return;
    await clients.dispose();
  });

  group('pos_claim_order_reversal (Tier 2)', () {
    test('two reversals: the first lands, the second is rejected whole',
        () async {
      final orderId = await seedCompletedSale();
      final phoneA = UuidV7.generate();
      final phoneB = UuidV7.generate();

      final first = await claim(orderId, phoneA, 'refund on A') as Map;
      expect(first['replayed'], isFalse);
      await uploadReversalRows(orderId);
      final afterWinner = await rowCounts(orderId);
      expect(afterWinner.stock, 2);
      expect(afterWinner.payments, 2);

      await expectLater(
        claim(orderId, phoneB, 'refund on B'),
        throwsA(isA<PostgrestException>()
            .having((e) => e.code, 'code', 'P0001')
            .having((e) => e.message, 'message',
                contains('reversal_already_applied'))),
      );
      // Phone B never sends its held rows; nothing of B is in the cloud.
      final afterLoser = await rowCounts(orderId);
      expect(afterLoser.stock, afterWinner.stock);
      expect(afterLoser.payments, afterWinner.payments);
      expect(afterLoser.wallet, afterWinner.wallet);

      final markers = await clients.adminClient
          .from('order_reversals')
          .select()
          .eq('order_id', orderId);
      expect(markers, hasLength(1));
      expect((markers as List).single['id'], phoneA);

      final order = await clients.adminClient
          .from('orders')
          .select()
          .eq('id', orderId)
          .single();
      expect(order['status'], 'cancelled');
      expect(order['cancellation_reason'], 'refund on A');
    }, skip: _skipReason);

    test('the rejection DETAIL carries the cloud header', () async {
      final orderId = await seedCompletedSale();
      await claim(orderId, UuidV7.generate(), 'winner');
      try {
        await claim(orderId, UuidV7.generate(), 'loser');
        fail('second claim must be rejected');
      } on PostgrestException catch (e) {
        final details = e.details;
        final header = details is String
            ? jsonDecode(details) as Map
            : details as Map;
        expect(header['status'], 'cancelled');
        expect(header['cancellation_reason'], 'winner');
        expect(header['last_updated_at'], isNotNull);
      }
    }, skip: _skipReason);

    test("the winner's retry replays idempotently", () async {
      final orderId = await seedCompletedSale();
      final reversalId = UuidV7.generate();
      await claim(orderId, reversalId, 'refund');
      final retry = await claim(orderId, reversalId, 'refund') as Map;
      expect(retry['replayed'], isTrue);
      final markers = await clients.adminClient
          .from('order_reversals')
          .select('id')
          .eq('order_id', orderId);
      expect(markers, hasLength(1));
    }, skip: _skipReason);

    test('an order reversed without a claim (v2 pos_cancel_order) rejects a '
        'later claim', () async {
      final orderId = await seedCompletedSale();
      await clients.userClient.rpc('pos_cancel_order', params: {
        'p_business_id': clients.env.businessId,
        'p_actor_id': clients.env.userId,
        'p_order_id': orderId,
        'p_cancellation_reason': 'v2 cancel',
      });
      final before = await rowCounts(orderId);
      await expectLater(
        claim(orderId, UuidV7.generate(), 'late refund'),
        throwsA(isA<PostgrestException>()
            .having((e) => e.message, 'message',
                contains('reversal_already_applied'))),
      );
      expect((await rowCounts(orderId)).stock, before.stock);
    }, skip: _skipReason);

    test('a late header push cannot un-cancel a claimed order', () async {
      final orderId = await seedCompletedSale();
      await claim(orderId, UuidV7.generate(), 'refund');
      await clients.userClient
          .from('orders')
          .update({'status': 'completed', 'cancellation_reason': null})
          .eq('id', orderId);
      final order = await clients.adminClient
          .from('orders')
          .select()
          .eq('id', orderId)
          .single();
      expect(order['status'], 'cancelled');
      expect(order['cancellation_reason'], 'refund');
    }, skip: _skipReason);
  });
}
