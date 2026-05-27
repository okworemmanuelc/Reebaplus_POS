@Tags(['integration'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../../helpers/supabase_test_clients.dart';
import '../../helpers/supabase_test_env.dart';
import '../../helpers/test_business_fixture.dart';

/// Tier-2 integration tests for the v2 pos_inventory_delta_v2 RPC. Hits
/// real dev Supabase. Auto-skipped when env vars are absent.
///
/// Note on cleanup: `stock_transactions` and `stock_adjustments` are
/// append-only — `forbid_delete` blocks DELETE outright. Test rows leak
/// per run into the shared test business. Acceptable for dev-machine
/// integration runs; reset the test business periodically.

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

  // Reusable store + product across tests (admin-inserted in setUpAll).
  late String storeId;
  late String productId;

  setUpAll(() async {
    if (_skipReason != null) return;
    clients = await TestClients.setUp();
    fixture = TestBusinessFixture(clients.adminClient, clients.env.businessId);

    storeId = UuidV7.generate();
    await clients.adminClient.from('stores').insert({
      'id': storeId,
      'business_id': clients.env.businessId,
      'name': 'Inventory Delta Store',
    });

    productId = UuidV7.generate();
    await clients.adminClient.from('products').insert({
      'id': productId,
      'business_id': clients.env.businessId,
      'name': 'Inventory Delta Product',
      'selling_price_kobo': 100000,
    });

    // Seed inventory at 100 so debit tests have headroom and the
    // insufficient-stock test has a known cap.
    await clients.adminClient.from('inventory').insert({
      'business_id': clients.env.businessId,
      'product_id': productId,
      'store_id': storeId,
      'quantity': 100,
    });
  });

  tearDownAll(() async {
    if (_skipReason != null) return;
    await clients.dispose();
  });

  group('pos_inventory_delta_v2 (Tier 2)', () {
    test(
        'round-trip: positive adjustment → stock_adjustments + stock_tx + '
        'inventory_after returned', () async {
      final movementId = UuidV7.generate();

      final response = await clients.userClient.rpc(
        'pos_inventory_delta_v2',
        params: {
          'p_business_id': clients.env.businessId,
          'p_actor_id': clients.env.userId,
          'p_movements': [
            {
              'movement_id': movementId,
              'product_id': productId,
              'store_id': storeId,
              'quantity_delta': 10,
              'movement_type': 'adjustment',
              'reason': 'restock',
            },
          ],
        },
      );

      expect(response, isA<Map>());
      final map = response as Map;

      final stxList = map['stock_transactions'] as List;
      expect(stxList, hasLength(1));
      final stx = stxList.first as Map;
      expect(stx['id'], movementId,
          reason: 'server must use the client-supplied movement_id');
      expect(stx['quantity_delta'], 10);
      expect(stx['movement_type'], 'adjustment');
      expect(stx['adjustment_id'], isNotNull,
          reason: 'server auto-mints stock_adjustments and links via FK');

      final adjList = map['stock_adjustments'] as List;
      expect(adjList, hasLength(1),
          reason: 'adjustment movement with no ref_type must auto-mint adjustment');
      final adj = adjList.first as Map;
      expect(adj['quantity_diff'], 10);
      expect(adj['reason'], 'restock');
      expect(stx['adjustment_id'], adj['id'],
          reason: 'stock_tx FK must point at the minted adjustment');

      final invAfter = map['inventory_after'] as List;
      expect(invAfter, hasLength(1));
      expect((invAfter.first as Map)['quantity'], greaterThanOrEqualTo(10),
          reason: 'inventory increased by the delta');

      // Cloud-side: ledger row exists with our movement_id.
      final cloudStx = await clients.adminClient
          .from('stock_transactions')
          .select()
          .eq('id', movementId)
          .single();
      expect(cloudStx['quantity_delta'], 10);
    }, skip: _skipReason);

    test('replay: same movement_id twice → second is a no-op', () async {
      final movementId = UuidV7.generate();

      Map<String, dynamic> params() => {
            'p_business_id': clients.env.businessId,
            'p_actor_id': clients.env.userId,
            'p_movements': [
              {
                'movement_id': movementId,
                'product_id': productId,
                'store_id': storeId,
                'quantity_delta': 5,
                'movement_type': 'adjustment',
                'reason': 'replay test',
              },
            ],
          };

      final first = await clients.userClient
          .rpc('pos_inventory_delta_v2', params: params()) as Map;
      // The first call appends a stock_tx + an adjustment row.
      expect((first['stock_transactions'] as List), hasLength(1));
      expect((first['stock_adjustments'] as List), hasLength(1));

      final second = await clients.userClient
          .rpc('pos_inventory_delta_v2', params: params()) as Map;
      // Replay: server detects the existing stock_tx row and skips the
      // body. Returns the existing stock_tx, no new adjustment, no
      // inventory delta.
      final stxList2 = second['stock_transactions'] as List;
      expect(stxList2, hasLength(1));
      expect((stxList2.first as Map)['id'], movementId);
      expect(second['stock_adjustments'], isEmpty,
          reason: 'replay must not re-mint the adjustment');
      expect(second['inventory_after'], isEmpty,
          reason: 'replay must not double-apply the delta');

      // Cloud invariant: still exactly one stock_tx for this movement_id.
      expect(await fixture.countById('stock_transactions', movementId), 1);
    }, skip: _skipReason);

    test('atomicity (tenant guard): bogus business_id raises, no rows',
        () async {
      final bogus = UuidV7.generate();
      final movementId = UuidV7.generate();

      Object? caught;
      try {
        await clients.userClient.rpc('pos_inventory_delta_v2', params: {
          'p_business_id': bogus,
          'p_actor_id': clients.env.userId,
          'p_movements': [
            {
              'movement_id': movementId,
              'product_id': productId,
              'store_id': storeId,
              'quantity_delta': 1,
              'movement_type': 'adjustment',
            },
          ],
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(await fixture.countById('stock_transactions', movementId), 0);
    }, skip: _skipReason);

    test(
        'atomicity (mid-flight): two-movement batch where the SECOND fails '
        'rolls back the FIRST', () async {
      // Read inventory pre-call so we can assert it didn't change.
      final preInv = await clients.adminClient
          .from('inventory')
          .select('quantity')
          .eq('business_id', clients.env.businessId)
          .eq('product_id', productId)
          .eq('store_id', storeId)
          .single();
      final preQty = preInv['quantity'] as int;

      final goodMovementId = UuidV7.generate();
      final badMovementId = UuidV7.generate();

      Object? caught;
      try {
        await clients.userClient.rpc('pos_inventory_delta_v2', params: {
          'p_business_id': clients.env.businessId,
          'p_actor_id': clients.env.userId,
          'p_movements': [
            {
              // Movement 1: succeeds — small positive delta.
              'movement_id': goodMovementId,
              'product_id': productId,
              'store_id': storeId,
              'quantity_delta': 3,
              'movement_type': 'adjustment',
              'reason': 'first ok',
            },
            {
              // Movement 2: fails — tries to debit more than the cap.
              'movement_id': badMovementId,
              'product_id': productId,
              'store_id': storeId,
              'quantity_delta': -100000,
              'movement_type': 'adjustment',
              'reason': 'second blows up',
            },
          ],
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull,
          reason: 'insufficient_stock guard should fire on movement 2');

      // Atomicity: neither movement landed.
      expect(await fixture.countById('stock_transactions', goodMovementId), 0,
          reason: 'first movement must roll back when second fails');
      expect(await fixture.countById('stock_transactions', badMovementId), 0);

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
        'atomicity (validation): movement_type=sale rejected, no rows',
        () async {
      final movementId = UuidV7.generate();
      Object? caught;
      try {
        await clients.userClient.rpc('pos_inventory_delta_v2', params: {
          'p_business_id': clients.env.businessId,
          'p_actor_id': clients.env.userId,
          'p_movements': [
            {
              'movement_id': movementId,
              'product_id': productId,
              'store_id': storeId,
              'quantity_delta': -1,
              'movement_type': 'sale', // forbidden — sales must use record_sale
            },
          ],
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull,
          reason: 'sale_must_use_pos_record_sale_v2 guard should fire');
      expect(await fixture.countById('stock_transactions', movementId), 0);
    }, skip: _skipReason);
  });
}
