@Tags(['integration'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../../helpers/supabase_test_clients.dart';
import '../../helpers/supabase_test_env.dart';
import '../../helpers/test_business_fixture.dart';

/// Tier-2 integration tests for the v2 pos_approve_crate_return RPC. Hits
/// real dev Supabase. Auto-skipped when env vars are absent.
///
/// Note on cleanup: `crate_ledger` is append-only — once approved, the
/// ledger row is undeletable, which means `pending_crate_returns` (FK'd
/// by reference_return_id) and `crate_size_groups` (FK'd by crate_size_group_id)
/// also leak per run. Acceptable for dev-machine integration runs; reset
/// the test business periodically if rows accumulate.

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

  final createdCustomerIds = <String>[];
  final createdBalances =
      <({String customerId, String crateSizeGroupId})>[];

  Future<({String customerId, String crateSizeGroupId, String pendingId, int quantity})>
      seedPendingReturn({int quantity = 5}) async {
    final customerId = UuidV7.generate();
    final walletId = UuidV7.generate();
    await clients.userClient.rpc('pos_create_customer', params: {
      'p_business_id': clients.env.businessId,
      'p_customer_id': customerId,
      'p_wallet_id': walletId,
      'p_name': 'Approve Test Customer',
    });
    createdCustomerIds.add(customerId);

    final crateSizeGroupId = UuidV7.generate();
    await clients.adminClient.from('crate_size_groups').insert({
      'id': crateSizeGroupId,
      'business_id': clients.env.businessId,
      'name': 'Test Crate Group ${UuidV7.generate().substring(0, 8)}',
      'crate_size_label': 'small',
    });

    final pendingId = UuidV7.generate();
    await clients.adminClient.from('pending_crate_returns').insert({
      'id': pendingId,
      'business_id': clients.env.businessId,
      'customer_id': customerId,
      'crate_size_group_id': crateSizeGroupId,
      'quantity': quantity,
      'submitted_by': clients.env.userId,
      'status': 'pending',
    });

    createdBalances
        .add((customerId: customerId, crateSizeGroupId: crateSizeGroupId));

    return (
      customerId: customerId,
      crateSizeGroupId: crateSizeGroupId,
      pendingId: pendingId,
      quantity: quantity,
    );
  }

  setUpAll(() async {
    if (_skipReason != null) return;
    clients = await TestClients.setUp();
    fixture = TestBusinessFixture(clients.adminClient, clients.env.businessId);
  });

  tearDown(() async {
    if (_skipReason != null) return;
    for (final b in createdBalances) {
      await fixture.deleteCustomerCrateBalance(
        customerId: b.customerId,
        crateSizeGroupId: b.crateSizeGroupId,
      );
    }
    createdBalances.clear();
    for (final id in createdCustomerIds) {
      await fixture.deleteCustomerCascade(id);
    }
    createdCustomerIds.clear();
  });

  tearDownAll(() async {
    if (_skipReason != null) return;
    await clients.dispose();
  });

  group('pos_approve_crate_return (Tier 2)', () {
    test('round-trip: pending → approved, ledger + balance reflect -quantity',
        () async {
      final s = await seedPendingReturn(quantity: 5);
      final ledgerId = UuidV7.generate();

      final response = await clients.userClient.rpc(
        'pos_approve_crate_return',
        params: {
          'p_business_id': clients.env.businessId,
          'p_actor_id': clients.env.userId,
          'p_pending_return_id': s.pendingId,
          'p_ledger_id': ledgerId,
        },
      );

      expect(response, isA<Map>());
      final map = response as Map;
      expect(map['replayed'], isFalse);

      final pcr = map['pending_return'] as Map;
      expect(pcr['id'], s.pendingId);
      expect(pcr['status'], 'approved');
      expect(pcr['approved_by'], clients.env.userId);
      expect(pcr['approved_at'], isNotNull);

      final ledger = map['crate_ledger_row'] as Map;
      expect(ledger['id'], ledgerId);
      expect(ledger['quantity_delta'], -s.quantity,
          reason: 'returns must reduce what the customer owes');
      expect(ledger['movement_type'], 'returned');
      expect(ledger['reference_return_id'], s.pendingId);
      expect(ledger['customer_id'], s.customerId);

      final balance = map['balance_row'] as Map;
      expect(balance['balance'], -s.quantity,
          reason: 'cache must decrement by the returned quantity');
      expect(balance['customer_id'], s.customerId);
      expect(balance['crate_size_group_id'], s.crateSizeGroupId);

      // Cloud-side verification.
      final cloudPcr = await clients.adminClient
          .from('pending_crate_returns')
          .select()
          .eq('id', s.pendingId)
          .single();
      expect(cloudPcr['status'], 'approved');
      expect(cloudPcr['last_updated_at'], pcr['last_updated_at']);

      final cloudLedger = await clients.adminClient
          .from('crate_ledger')
          .select()
          .eq('id', ledgerId)
          .single();
      expect(cloudLedger['quantity_delta'], -s.quantity);

      final cloudBalance = await clients.adminClient
          .from('customer_crate_balances')
          .select()
          .eq('business_id', clients.env.businessId)
          .eq('customer_id', s.customerId)
          .eq('crate_size_group_id', s.crateSizeGroupId)
          .single();
      expect(cloudBalance['balance'], -s.quantity);
    }, skip: _skipReason);

    test('replay: second call returns replayed=true; no second ledger row',
        () async {
      final s = await seedPendingReturn(quantity: 3);
      final ledgerId = UuidV7.generate();

      Map<String, dynamic> params() => {
            'p_business_id': clients.env.businessId,
            'p_actor_id': clients.env.userId,
            'p_pending_return_id': s.pendingId,
            'p_ledger_id': ledgerId,
          };

      final first = await clients.userClient
          .rpc('pos_approve_crate_return', params: params()) as Map;
      expect(first['replayed'], isFalse);

      final second = await clients.userClient
          .rpc('pos_approve_crate_return', params: params()) as Map;
      expect(second['replayed'], isTrue);

      // Exactly one ledger row + balance unchanged from a single -3 delta.
      final ledgerRows = await clients.adminClient
          .from('crate_ledger')
          .select('id')
          .eq('id', ledgerId);
      expect(ledgerRows, hasLength(1),
          reason: 'replay must not append a second ledger row');

      final cloudBalance = await clients.adminClient
          .from('customer_crate_balances')
          .select('balance')
          .eq('business_id', clients.env.businessId)
          .eq('customer_id', s.customerId)
          .eq('crate_size_group_id', s.crateSizeGroupId)
          .single();
      expect(cloudBalance['balance'], -s.quantity,
          reason: 'replay must not double-debit the cache');
    }, skip: _skipReason);

    test('atomicity (tenant guard): bogus business_id raises, no rows',
        () async {
      final bogus = UuidV7.generate();
      final pendingId = UuidV7.generate();
      final ledgerId = UuidV7.generate();

      Object? caught;
      try {
        await clients.userClient.rpc('pos_approve_crate_return', params: {
          'p_business_id': bogus,
          'p_actor_id': clients.env.userId,
          'p_pending_return_id': pendingId,
          'p_ledger_id': ledgerId,
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(await fixture.countById('crate_ledger', ledgerId), 0);
    }, skip: _skipReason);

    test('atomicity (validation): missing pending return raises, no ledger row',
        () async {
      final pendingId = UuidV7.generate(); // doesn't exist
      final ledgerId = UuidV7.generate();

      Object? caught;
      try {
        await clients.userClient.rpc('pos_approve_crate_return', params: {
          'p_business_id': clients.env.businessId,
          'p_actor_id': clients.env.userId,
          'p_pending_return_id': pendingId,
          'p_ledger_id': ledgerId,
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull,
          reason: 'pending_return_not_found guard should fire');
      expect(await fixture.countById('crate_ledger', ledgerId), 0,
          reason: 'no ledger row when pending return is absent');
    }, skip: _skipReason);

    test(
        'atomicity (state guard): rejected pending return cannot be approved',
        () async {
      final s = await seedPendingReturn(quantity: 4);
      // Flip to rejected via service role.
      await clients.adminClient
          .from('pending_crate_returns')
          .update({'status': 'rejected'}).eq('id', s.pendingId);

      final ledgerId = UuidV7.generate();
      Object? caught;
      try {
        await clients.userClient.rpc('pos_approve_crate_return', params: {
          'p_business_id': clients.env.businessId,
          'p_actor_id': clients.env.userId,
          'p_pending_return_id': s.pendingId,
          'p_ledger_id': ledgerId,
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull,
          reason: 'cannot_approve_status_rejected guard should fire');
      expect(await fixture.countById('crate_ledger', ledgerId), 0);

      // Pending row's status must remain rejected (no UPDATE leaked).
      final cloudPcr = await clients.adminClient
          .from('pending_crate_returns')
          .select('status')
          .eq('id', s.pendingId)
          .single();
      expect(cloudPcr['status'], 'rejected');
    }, skip: _skipReason);
  });
}
