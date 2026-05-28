@Tags(['integration'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../../helpers/supabase_test_clients.dart';
import '../../helpers/supabase_test_env.dart';
import '../../helpers/test_business_fixture.dart';

/// Tier-2 integration tests for the v2 pos_create_customer RPC. Hits real
/// dev Supabase. Skipped automatically (per-test) when env vars are absent
/// so this file is safe to leave in the suite during normal `flutter test`
/// runs — only `flutter test test/integration/` opts in.
///
/// Pre-reqs: see test/integration/README.md.

/// Determined once at file load. If env vars are missing, every test in
/// this file is marked skipped with a helpful message; if present, tests
/// run and `clients` / `fixture` are guaranteed non-null inside test bodies.
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
  final createdIds = <String>[];

  setUpAll(() async {
    if (_skipReason != null) return;
    clients = await TestClients.setUp();
    fixture = TestBusinessFixture(clients.adminClient, clients.env.businessId);
  });

  tearDown(() async {
    if (_skipReason != null) return;
    for (final id in createdIds) {
      await fixture.deleteCustomerCascade(id);
    }
    createdIds.clear();
  });

  tearDownAll(() async {
    if (_skipReason != null) return;
    await clients.dispose();
  });

  group('pos_create_customer (Tier 2)', () {
    test('round-trip: response shape + cloud row matches', () async {
      final customerId = UuidV7.generate();
      final walletId = UuidV7.generate();
      createdIds.add(customerId);

      final response = await clients.userClient.rpc(
        'pos_create_customer',
        params: {
          'p_business_id': clients.env.businessId,
          'p_customer_id': customerId,
          'p_wallet_id': walletId,
          'p_name': 'Round Trip Rita',
          'p_phone': '+2348000000001',
          'p_price_tier': 'retailer',
        },
      );

      // Response shape.
      expect(response, isA<Map>());
      final map = response as Map;
      expect(map['replayed'], isFalse);

      final customer = map['customer'] as Map;
      expect(customer['id'], customerId);
      expect(customer['business_id'], clients.env.businessId);
      expect(customer['name'], 'Round Trip Rita');
      expect(customer['phone'], '+2348000000001');
      expect(customer['price_tier'], 'retailer');
      expect(customer['is_deleted'], isFalse);
      expect(customer['last_updated_at'], isNotNull);

      final wallet = map['customer_wallet'] as Map;
      expect(wallet['id'], walletId);
      expect(wallet['customer_id'], customerId);
      expect(wallet['currency'], 'NGN');
      expect(wallet['is_active'], isTrue);

      // Cloud-side verification via service role.
      final cloudCust = await clients.adminClient
          .from('customers')
          .select()
          .eq('id', customerId)
          .single();
      expect(cloudCust['name'], 'Round Trip Rita');
      expect(cloudCust['last_updated_at'], customer['last_updated_at']);

      final cloudWallets = await clients.adminClient
          .from('customer_wallets')
          .select()
          .eq('customer_id', customerId);
      expect(cloudWallets, hasLength(1));
      expect((cloudWallets[0] as Map)['id'], walletId);
    }, skip: _skipReason);

    test('replay: second call returns replayed=true with no duplicate inserts',
        () async {
      final customerId = UuidV7.generate();
      final walletId = UuidV7.generate();
      createdIds.add(customerId);

      Map<String, dynamic> params() => {
            'p_business_id': clients.env.businessId,
            'p_customer_id': customerId,
            'p_wallet_id': walletId,
            'p_name': 'Replay Ray',
          };

      final first = await clients.userClient
          .rpc('pos_create_customer', params: params()) as Map;
      expect(first['replayed'], isFalse);

      final second = await clients.userClient
          .rpc('pos_create_customer', params: params()) as Map;
      expect(second['replayed'], isTrue,
          reason: 'second call with same idempotency uuids must be detected');

      // Cloud has exactly one customer + one wallet for this id.
      final cust = await clients.adminClient
          .from('customers')
          .select('id')
          .eq('id', customerId);
      expect(cust, hasLength(1));
      final wal = await clients.adminClient
          .from('customer_wallets')
          .select('id')
          .eq('customer_id', customerId);
      expect(wal, hasLength(1));
    }, skip: _skipReason);

    test('atomicity (tenant guard): bogus business_id raises and creates nothing',
        () async {
      final bogusBusiness = UuidV7.generate();
      final customerId = UuidV7.generate();

      Object? caught;
      try {
        await clients.userClient.rpc('pos_create_customer', params: {
          'p_business_id': bogusBusiness, // not the test user's business
          'p_customer_id': customerId,
          'p_wallet_id': UuidV7.generate(),
          'p_name': 'Tenant Mismatch Tina',
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull,
          reason: 'tenant guard must raise when business_id does not match');

      // No row should have been created with that bogus business_id OR
      // with our customer id.
      expect(await fixture.countById('customers', customerId), 0);
      final crossBiz = await clients.adminClient
          .from('customers')
          .select('id')
          .eq('business_id', bogusBusiness);
      expect(crossBiz, isEmpty);
    }, skip: _skipReason);

    test('atomicity (validation): invalid p_price_tier raises mid-body, no rows',
        () async {
      final customerId = UuidV7.generate();
      final walletId = UuidV7.generate();

      Object? caught;
      try {
        await clients.userClient.rpc('pos_create_customer', params: {
          'p_business_id': clients.env.businessId,
          'p_customer_id': customerId,
          'p_wallet_id': walletId,
          'p_name': 'Bad Group Bob',
          'p_price_tier': 'invalid_group', // CHECK constraint rejects
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull,
          reason: 'price_tier CHECK constraint should fire');

      // Both inserts must roll back — proves the RPC is atomic, not just
      // that the dispatcher rejected the call before any work happened.
      expect(await fixture.countById('customers', customerId), 0);
      expect(await fixture.countById('customer_wallets', walletId), 0);
    }, skip: _skipReason);
  });
}
