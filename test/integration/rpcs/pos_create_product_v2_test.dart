@Tags(['integration'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../../helpers/supabase_test_clients.dart';
import '../../helpers/supabase_test_env.dart';
import '../../helpers/test_business_fixture.dart';

/// Tier-2 integration tests for the v2 pos_create_product_v2 RPC. Hits
/// real dev Supabase. Auto-skipped when env vars are absent.
///
/// Note on cleanup: products are soft-deletable but `stock_transactions`
/// and `stock_adjustments` are append-only and FK back to products /
/// stores, so the parent rows leak per run. Acceptable for
/// dev-machine integration runs; reset the test business periodically.

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

  late String storeId;

  setUpAll(() async {
    if (_skipReason != null) return;
    clients = await TestClients.setUp();
    fixture = TestBusinessFixture(clients.adminClient, clients.env.businessId);

    storeId = UuidV7.generate();
    await clients.adminClient.from('stores').insert({
      'id': storeId,
      'business_id': clients.env.businessId,
      'name': 'Create-Product Test Store',
    });
  });

  tearDownAll(() async {
    if (_skipReason != null) return;
    await clients.dispose();
  });

  group('pos_create_product_v2 (Tier 2)', () {
    test(
        'round-trip (no initial stock): product row returned, no '
        'stock_adjustments / stock_transactions / inventory_after',
        () async {
      final productId = UuidV7.generate();

      final response = await clients.userClient.rpc(
        'pos_create_product_v2',
        params: {
          'p_business_id': clients.env.businessId,
          'p_actor_id': clients.env.userId,
          'p_product_id': productId,
          'p_name': 'Round-Trip Beer',
          'p_retailer_price_kobo': 80000,
          'p_buying_price_kobo': 50000,
        },
      );

      expect(response, isA<Map>());
      final map = response as Map;
      expect(map['replayed'], isFalse);

      final product = map['product'] as Map;
      expect(product['id'], productId);
      expect(product['name'], 'Round-Trip Beer');
      expect(product['retailer_price_kobo'], 80000);
      expect(product['buying_price_kobo'], 50000);
      // Server defaults — confirm they kicked in for omitted client params.
      expect(product['unit'], 'Bottle');
      expect(product['low_stock_threshold'], 5);
      expect(product['track_empties'], false);
      expect(product['is_available'], true);
      expect(product['is_deleted'], false);

      expect(map['stock_adjustments'], isEmpty);
      expect(map['stock_transactions'], isEmpty);
      expect(map['inventory_after'], isEmpty);

      // Cloud-side verification.
      final cloudProduct = await clients.adminClient
          .from('products')
          .select()
          .eq('id', productId)
          .single();
      expect(cloudProduct['name'], 'Round-Trip Beer');
      expect(cloudProduct['last_updated_at'], product['last_updated_at']);
    }, skip: _skipReason);

    test(
        'round-trip (with initial stock): product + stock_adjustments + '
        'stock_tx + inventory_after returned', () async {
      final productId = UuidV7.generate();

      final response = await clients.userClient.rpc(
        'pos_create_product_v2',
        params: {
          'p_business_id': clients.env.businessId,
          'p_actor_id': clients.env.userId,
          'p_product_id': productId,
          'p_name': 'Stocked Beer V2',
          'p_retailer_price_kobo': 100000,
          'p_initial_stock': {
            'store_id': storeId,
            'quantity': 24,
          },
        },
      ) as Map;

      expect(response['replayed'], isFalse);

      final adjList = response['stock_adjustments'] as List;
      expect(adjList, hasLength(1));
      final adj = adjList.first as Map;
      expect(adj['quantity_diff'], 24);
      expect(adj['reason'], 'initial_stock');

      final stxList = response['stock_transactions'] as List;
      expect(stxList, hasLength(1));
      final stx = stxList.first as Map;
      expect(stx['quantity_delta'], 24);
      expect(stx['movement_type'], 'adjustment');
      expect(stx['adjustment_id'], adj['id'],
          reason: 'stock_tx FK must point at the minted adjustment');

      final invAfter = response['inventory_after'] as List;
      expect(invAfter, hasLength(1));
      expect((invAfter.first as Map)['quantity'], 24);
    }, skip: _skipReason);

    test('replay: second call returns replayed=true with no new rows',
        () async {
      final productId = UuidV7.generate();

      Map<String, dynamic> params() => {
            'p_business_id': clients.env.businessId,
            'p_actor_id': clients.env.userId,
            'p_product_id': productId,
            'p_name': 'Replay Beer',
            'p_retailer_price_kobo': 60000,
            'p_initial_stock': {
              'store_id': storeId,
              'quantity': 10,
            },
          };

      final first = await clients.userClient
          .rpc('pos_create_product_v2', params: params()) as Map;
      expect(first['replayed'], isFalse);
      final firstAdjId =
          ((first['stock_adjustments'] as List).first as Map)['id'];

      final second = await clients.userClient
          .rpc('pos_create_product_v2', params: params()) as Map;
      expect(second['replayed'], isTrue);
      expect(second['stock_adjustments'], isEmpty,
          reason: 'replay must not double-create the initial-stock rows');
      expect(second['stock_transactions'], isEmpty);
      expect(second['inventory_after'], isEmpty,
          reason: 'replay must not double-apply the initial-stock delta');

      // Cloud invariant: still exactly one product, one adjustment, one
      // stock_tx, one inventory row at qty=10.
      expect(await fixture.countById('products', productId), 1);
      expect(await fixture.countById('stock_adjustments', firstAdjId), 1);

      final cloudInv = await clients.adminClient
          .from('inventory')
          .select('quantity')
          .eq('business_id', clients.env.businessId)
          .eq('product_id', productId)
          .eq('store_id', storeId)
          .single();
      expect(cloudInv['quantity'], 10,
          reason: 'replay must not double the inventory cache');
    }, skip: _skipReason);

    test('atomicity (tenant guard): bogus business_id raises, no product',
        () async {
      final bogus = UuidV7.generate();
      final productId = UuidV7.generate();

      Object? caught;
      try {
        await clients.userClient.rpc('pos_create_product_v2', params: {
          'p_business_id': bogus,
          'p_actor_id': clients.env.userId,
          'p_product_id': productId,
          'p_name': 'Cross-Tenant Beer',
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught.toString(), contains('tenant_mismatch'),
          reason: '_assert_caller_owns_business must reject the bogus tenant; '
              'any other exception masks an unrelated regression');
      expect(await fixture.countById('products', productId), 0);
    }, skip: _skipReason);

    test(
        'atomicity (validation): null p_product_id raises, no product',
        () async {
      Object? caught;
      try {
        await clients.userClient.rpc('pos_create_product_v2', params: {
          'p_business_id': clients.env.businessId,
          'p_actor_id': clients.env.userId,
          'p_product_id': null,
          'p_name': 'No-ID Beer',
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull,
          reason: 'product_id_required guard should fire');
      expect(caught.toString(), contains('product_id_required'),
          reason: 'failure must be the validation guard, not an unrelated '
              'schema/network error');
    }, skip: _skipReason);
  });
}
