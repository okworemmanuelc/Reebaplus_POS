@Tags(['integration'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../../helpers/supabase_test_clients.dart';
import '../../helpers/supabase_test_env.dart';

/// Tier-2 integration tests for public.complete_onboarding (migration 0018).
///
/// IMPORTANT — this RPC mutates the calling user's `profiles.business_id`
/// (it onboards a brand-new business under auth.uid()). The other tests in
/// this folder share a single test user pinned to TEST_BUSINESS_ID via
/// profiles, so a bare invocation would re-bind the test user to a
/// throwaway business and break every subsequent test in the run.
///
/// To stay safe in the shared fixture: every test snapshots
/// profiles.business_id (and a couple of other profile fields) via the
/// admin client before invoking the RPC, runs the assertion, then restores
/// the snapshot in tearDown — *before* deleting the throwaway business so
/// the FK from profiles to businesses still resolves at delete time.
///
/// Pre-reqs: see test/integration/README.md.

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
  Map<String, dynamic>? profileSnapshot;
  final createdBusinessIds = <String>[];

  setUpAll(() async {
    if (_skipReason != null) return;
    clients = await TestClients.setUp();
  });

  setUp(() async {
    if (_skipReason != null) return;
    profileSnapshot = await clients.adminClient
        .from('profiles')
        .select('id, business_id, name, role, role_tier')
        .eq('id', clients.env.userId)
        .single();
  });

  tearDown(() async {
    if (_skipReason != null) return;

    // Restore the profile FIRST — must happen before we delete the
    // throwaway business, because profiles.business_id has an FK to
    // businesses(id) and the original TEST_BUSINESS_ID is what the rest
    // of the suite expects.
    if (profileSnapshot != null) {
      await clients.adminClient.from('profiles').update({
        'business_id': profileSnapshot!['business_id'],
        'name': profileSnapshot!['name'],
        'role': profileSnapshot!['role'],
        'role_tier': profileSnapshot!['role_tier'],
      }).eq('id', clients.env.userId);
    }

    for (final bid in createdBusinessIds) {
      // CASCADE on businesses → settings, stores, etc. all drop.
      await clients.adminClient.from('businesses').delete().eq('id', bid);
    }
    createdBusinessIds.clear();
    profileSnapshot = null;
  });

  tearDownAll(() async {
    if (_skipReason != null) return;
    await clients.dispose();
  });

  group('complete_onboarding (Tier 2)', () {
    test('round-trip: businesses + profile + store + settings all land', () async {
      final businessId = UuidV7.generate();
      final storeId = UuidV7.generate();
      createdBusinessIds.add(businessId);

      await clients.userClient.rpc('complete_onboarding', params: {
        'p_business_id': businessId,
        'p_store_id': storeId,
        'p_owner_name': 'Round Trip Owner',
        'p_business_name': 'Reeba Round Trip',
        'p_business_type': 'Liquor Store',
        'p_business_phone': '+2348000000999',
        'p_business_email': 'rt@example.test',
        'p_location': {
          'name': 'Main Store',
          'street': '12 Test Street',
          'city': 'Lagos',
          'state': 'Lagos',
          'country': 'Nigeria',
        },
        'p_settings': {
          'currency': 'NGN',
          'timezone': 'Africa/Lagos',
          'tax_reg_number': 'TIN-12345',
        },
      });

      final biz = await clients.adminClient
          .from('businesses')
          .select()
          .eq('id', businessId)
          .single();
      expect(biz['name'], 'Reeba Round Trip');
      expect(biz['type'], 'Liquor Store');
      expect(biz['phone'], '+2348000000999');
      expect(biz['email'], 'rt@example.test');
      expect(biz['onboarding_complete'], isTrue);
      expect(biz['owner_id'], clients.env.userId);

      final profile = await clients.adminClient
          .from('profiles')
          .select()
          .eq('id', clients.env.userId)
          .single();
      expect(profile['business_id'], businessId);
      expect(profile['role'], 'ceo');
      expect(profile['role_tier'], 5);
      expect(profile['name'], 'Round Trip Owner');

      final stores = await clients.adminClient
          .from('stores')
          .select()
          .eq('business_id', businessId);
      expect(stores, hasLength(1));
      final wh = (stores[0] as Map);
      expect(wh['id'], storeId);
      expect(wh['name'], 'Main Store');
      expect(wh['location'], '12 Test Street, Lagos, Nigeria');

      final settings = await clients.adminClient
          .from('settings')
          .select('key, value')
          .eq('business_id', businessId);
      final asMap = {
        for (final r in settings as List) (r as Map)['key']: r['value'],
      };
      expect(asMap['default_currency'], 'NGN');
      expect(asMap['timezone'], 'Africa/Lagos');
      expect(asMap['tax_registration_number'], 'TIN-12345');
    }, skip: _skipReason);

    test('idempotent retry: second call with same ids overwrites, no duplicates',
        () async {
      final businessId = UuidV7.generate();
      final storeId = UuidV7.generate();
      createdBusinessIds.add(businessId);

      Map<String, dynamic> params({required String name}) => {
            'p_business_id': businessId,
            'p_store_id': storeId,
            'p_owner_name': 'Retry Owner',
            'p_business_name': name,
            'p_business_type': 'Restaurant',
            'p_business_phone': '+2348000001000',
            'p_business_email': 'retry@example.test',
            'p_location': {
              'name': 'HQ',
              'street': '1 First Avenue',
              'city': 'Lagos',
              'country': 'Nigeria',
            },
            'p_settings': {
              'currency': 'NGN',
              'timezone': 'Africa/Lagos',
            },
          };

      await clients.userClient
          .rpc('complete_onboarding', params: params(name: 'First Name'));
      await clients.userClient
          .rpc('complete_onboarding', params: params(name: 'Renamed'));

      // Exactly one business, one store, two settings.
      final biz = await clients.adminClient
          .from('businesses')
          .select()
          .eq('id', businessId);
      expect(biz, hasLength(1));
      expect((biz[0] as Map)['name'], 'Renamed',
          reason: 'second call should overwrite the business name');

      final wh = await clients.adminClient
          .from('stores')
          .select('id')
          .eq('business_id', businessId);
      expect(wh, hasLength(1),
          reason: 'store upsert must not duplicate on retry');

      final settings = await clients.adminClient
          .from('settings')
          .select('key')
          .eq('business_id', businessId);
      expect(settings, hasLength(2),
          reason: 'currency + timezone, no tax this time');
    }, skip: _skipReason);

    test('atomicity: empty owner name raises and creates nothing', () async {
      final businessId = UuidV7.generate();
      final storeId = UuidV7.generate();

      Object? caught;
      try {
        await clients.userClient.rpc('complete_onboarding', params: {
          'p_business_id': businessId,
          'p_store_id': storeId,
          'p_owner_name': '   ', // whitespace-only — function must reject
          'p_business_name': 'Should Not Land',
          'p_business_type': 'Other',
          'p_business_phone': null,
          'p_business_email': null,
          'p_location': {'name': 'X', 'street': 'Y', 'city': 'Z', 'country': 'NG'},
          'p_settings': {'currency': 'NGN', 'timezone': 'Africa/Lagos'},
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull,
          reason: 'whitespace-only owner name should raise');

      // Nothing should have landed — the function raises before any INSERT.
      final biz = await clients.adminClient
          .from('businesses')
          .select('id')
          .eq('id', businessId);
      expect(biz, isEmpty);
      final wh = await clients.adminClient
          .from('stores')
          .select('id')
          .eq('id', storeId);
      expect(wh, isEmpty);
    }, skip: _skipReason);
  });
}
