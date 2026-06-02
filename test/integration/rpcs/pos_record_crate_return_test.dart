@Tags(['integration'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../../helpers/supabase_test_clients.dart';
import '../../helpers/supabase_test_env.dart';
import '../../helpers/test_business_fixture.dart';

/// Tier-2 integration tests for the v2 pos_record_crate_return RPC. Hits
/// real dev Supabase. Auto-skipped when env vars are absent.
///
/// Note on cleanup: `crate_ledger` is append-only on the cloud — the
/// `forbid_delete` trigger raises on any DELETE. Customers, manufacturers,
/// and crate_size_groups referenced by ledger rows are also undeleteable
/// (FK NO ACTION + the ledger's append-only trigger blocks cascade
/// nullification). These tests therefore leak a ledger row + their
/// referenced seed entities per run. Cache balance rows are cleaned in
/// tearDown — they're not append-only.

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

  // Each test seeds its own customer / manufacturer / crate_group so
  // balance composites are fresh and assertions don't tangle with prior
  // runs' values. We track them only for the cache-balance cleanup.
  // v29: crate tracking is keyed by manufacturer (§13.4).
  final createdCustomers = <({String customerId, String manufacturerId})>[];
  final createdManufacturers = <({String manufacturerId})>[];

  Future<({String customerId, String manufacturerId})>
      seedCustomerAndManufacturer() async {
    final customerId = UuidV7.generate();
    final walletId = UuidV7.generate();
    final manufacturerId = UuidV7.generate();
    await clients.userClient.rpc('pos_create_customer', params: {
      'p_business_id': clients.env.businessId,
      'p_customer_id': customerId,
      'p_wallet_id': walletId,
      'p_name': 'Crate Test Customer',
    });
    await clients.adminClient.from('manufacturers').insert({
      'id': manufacturerId,
      'business_id': clients.env.businessId,
      'name': 'Crate Test Manco C',
    });
    createdCustomers
        .add((customerId: customerId, manufacturerId: manufacturerId));
    return (customerId: customerId, manufacturerId: manufacturerId);
  }

  Future<({String manufacturerId})> seedManufacturer() async {
    final manufacturerId = UuidV7.generate();
    await clients.adminClient.from('manufacturers').insert({
      'id': manufacturerId,
      'business_id': clients.env.businessId,
      'name': 'Crate Test Manco',
    });
    createdManufacturers.add((manufacturerId: manufacturerId));
    return (manufacturerId: manufacturerId);
  }

  setUpAll(() async {
    if (_skipReason != null) return;
    clients = await TestClients.setUp();
    fixture = TestBusinessFixture(clients.adminClient, clients.env.businessId);
  });

  tearDown(() async {
    if (_skipReason != null) return;
    for (final c in createdCustomers) {
      await fixture.deleteCustomerCrateBalance(
        customerId: c.customerId,
        manufacturerId: c.manufacturerId,
      );
    }
    createdCustomers.clear();
    for (final m in createdManufacturers) {
      await fixture.deleteManufacturerCrateBalance(
        manufacturerId: m.manufacturerId,
      );
    }
    createdManufacturers.clear();
  });

  tearDownAll(() async {
    if (_skipReason != null) return;
    await clients.dispose();
  });

  group('pos_record_crate_return (Tier 2)', () {
    test('round-trip (customer): response shape + cloud rows match', () async {
      final s = await seedCustomerAndManufacturer();
      final ledgerId = UuidV7.generate();

      final response = await clients.userClient.rpc(
        'pos_record_crate_return',
        params: {
          'p_business_id': clients.env.businessId,
          'p_actor_id': clients.env.userId,
          'p_ledger_id': ledgerId,
          'p_owner_kind': 'customer',
          'p_owner_id': s.customerId,
          'p_manufacturer_id': s.manufacturerId,
          'p_quantity_delta': -5, // customer returning 5 reduces our liability
          'p_movement_type': 'returned',
        },
      );

      expect(response, isA<Map>());
      final map = response as Map;
      expect(map['replayed'], isFalse);

      final ledger = map['crate_ledger_row'] as Map;
      expect(ledger['id'], ledgerId);
      expect(ledger['customer_id'], s.customerId);
      expect(ledger['manufacturer_id'], s.manufacturerId);
      expect(ledger['quantity_delta'], -5);
      expect(ledger['movement_type'], 'returned');
      expect(ledger['voided_at'], isNull);

      final bal = map['balance_row'] as Map;
      expect(bal['customer_id'], s.customerId);
      expect(bal['manufacturer_id'], s.manufacturerId);
      expect(bal['balance'], -5,
          reason: 'fresh composite — first delta IS the balance');

      // Cloud-side verification: row exists with the expected last_updated_at.
      final cloudLedger = await clients.adminClient
          .from('crate_ledger')
          .select()
          .eq('id', ledgerId)
          .single();
      expect(cloudLedger['quantity_delta'], -5);
      expect(cloudLedger['last_updated_at'], ledger['last_updated_at']);

      final cloudBal = await fixture.readCustomerCrateBalance(
        customerId: s.customerId,
        manufacturerId: s.manufacturerId,
      );
      expect(cloudBal, -5);
    }, skip: _skipReason);

    test('round-trip (manufacturer): owner_kind=manufacturer wires the right cache',
        () async {
      final s = await seedManufacturer();
      final ledgerId = UuidV7.generate();

      final response = await clients.userClient.rpc(
        'pos_record_crate_return',
        params: {
          'p_business_id': clients.env.businessId,
          'p_actor_id': clients.env.userId,
          'p_ledger_id': ledgerId,
          'p_owner_kind': 'manufacturer',
          'p_owner_id': s.manufacturerId,
          'p_manufacturer_id': s.manufacturerId,
          'p_quantity_delta': 8, // we received 8 empties from the manufacturer
          'p_movement_type': 'returned',
        },
      );

      final map = response as Map;
      final ledger = map['crate_ledger_row'] as Map;
      expect(ledger['customer_id'], isNull);
      expect(ledger['manufacturer_id'], s.manufacturerId);

      final bal = map['balance_row'] as Map;
      expect(bal['manufacturer_id'], s.manufacturerId);
      expect(bal['customer_id'], isNull);
      expect(bal['balance'], 8);

      // Customer cache must NOT have a row for this composite — proves the
      // RPC didn't accidentally double-write to both balance tables.
      final customerSideRows = await clients.adminClient
          .from('customer_crate_balances')
          .select('id')
          .eq('business_id', clients.env.businessId)
          .eq('manufacturer_id', s.manufacturerId);
      expect(customerSideRows, isEmpty);
    }, skip: _skipReason);

    test('replay: same ledger id twice → replayed=true, balance unchanged',
        () async {
      final s = await seedCustomerAndManufacturer();
      final ledgerId = UuidV7.generate();

      Map<String, dynamic> params() => {
            'p_business_id': clients.env.businessId,
            'p_actor_id': clients.env.userId,
            'p_ledger_id': ledgerId,
            'p_owner_kind': 'customer',
            'p_owner_id': s.customerId,
            'p_manufacturer_id': s.manufacturerId,
            'p_quantity_delta': -3,
            'p_movement_type': 'returned',
          };

      final first = await clients.userClient
          .rpc('pos_record_crate_return', params: params()) as Map;
      expect(first['replayed'], isFalse);
      expect((first['balance_row'] as Map)['balance'], -3);

      final second = await clients.userClient
          .rpc('pos_record_crate_return', params: params()) as Map;
      expect(second['replayed'], isTrue);

      // Crucial: balance must not have been applied twice. A retry storm
      // here would silently corrupt the customer's recorded crate debt.
      expect((second['balance_row'] as Map)['balance'], -3,
          reason: 'replay must NOT re-apply the delta');

      final cloudBal = await fixture.readCustomerCrateBalance(
        customerId: s.customerId,
        manufacturerId: s.manufacturerId,
      );
      expect(cloudBal, -3);

      // Exactly one ledger row exists for this id.
      final ledgerRows = await clients.adminClient
          .from('crate_ledger')
          .select('id')
          .eq('id', ledgerId);
      expect(ledgerRows, hasLength(1));
    }, skip: _skipReason);

    test('atomicity (tenant guard): bogus business_id raises, no rows',
        () async {
      final bogus = UuidV7.generate();
      final ledgerId = UuidV7.generate();

      Object? caught;
      try {
        await clients.userClient.rpc('pos_record_crate_return', params: {
          'p_business_id': bogus,
          'p_actor_id': clients.env.userId,
          'p_ledger_id': ledgerId,
          'p_owner_kind': 'customer',
          'p_owner_id': UuidV7.generate(),
          'p_manufacturer_id': UuidV7.generate(),
          'p_quantity_delta': -1,
          'p_movement_type': 'returned',
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(await fixture.countById('crate_ledger', ledgerId), 0);
    }, skip: _skipReason);

    test(
        'atomicity (validation): invalid p_owner_kind raises before any write',
        () async {
      final s = await seedCustomerAndManufacturer();
      final ledgerId = UuidV7.generate();

      Object? caught;
      try {
        await clients.userClient.rpc('pos_record_crate_return', params: {
          'p_business_id': clients.env.businessId,
          'p_actor_id': clients.env.userId,
          'p_ledger_id': ledgerId,
          'p_owner_kind': 'driver', // not in {customer, manufacturer}
          'p_owner_id': s.customerId,
          'p_manufacturer_id': s.manufacturerId,
          'p_quantity_delta': -1,
          'p_movement_type': 'returned',
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull,
          reason: 'invalid_owner_kind guard should fire');
      expect(await fixture.countById('crate_ledger', ledgerId), 0);
      // Balance row also must not exist (no partial write).
      final cloudBal = await fixture.readCustomerCrateBalance(
        customerId: s.customerId,
        manufacturerId: s.manufacturerId,
      );
      expect(cloudBal, isNull,
          reason: 'failed RPC must not have created a balance row');
    }, skip: _skipReason);

    test(
        'atomicity (validation): invalid p_movement_type raises, no rows',
        () async {
      final s = await seedCustomerAndManufacturer();
      final ledgerId = UuidV7.generate();

      Object? caught;
      try {
        await clients.userClient.rpc('pos_record_crate_return', params: {
          'p_business_id': clients.env.businessId,
          'p_actor_id': clients.env.userId,
          'p_ledger_id': ledgerId,
          'p_owner_kind': 'customer',
          'p_owner_id': s.customerId,
          'p_manufacturer_id': s.manufacturerId,
          'p_quantity_delta': -1,
          'p_movement_type': 'lost_to_god', // not in CHECK list
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull,
          reason: 'invalid_movement_type guard should fire');
      expect(await fixture.countById('crate_ledger', ledgerId), 0);
    }, skip: _skipReason);
  });
}
