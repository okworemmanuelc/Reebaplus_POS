@Tags(['integration'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// #425 storefront contract, tier-2. Calls the four storefront RPCs as a
// SIGNED-OUT (anon) client against throwaway fixtures written with the
// service role. Fixtures use a per-run made-up state name, so the feed sees
// only this run's shops. Requires migration 0202 on reebaplus-dev.
final _env = Platform.environment;
const _devUrl = 'https://yngwzuinxhxhzdfagcbg.supabase.co';
final _skip = [
  'TEST_SUPABASE_URL',
  'TEST_SUPABASE_ANON_KEY',
  'TEST_SUPABASE_SERVICE_ROLE_KEY',
].any((key) => _env[key]?.isNotEmpty != true)
    ? 'Storefront tests need the three TEST_SUPABASE_* variables (reebaplus-dev).'
    : _env['TEST_STOREFRONT_ALLOW_WRITES'] != '1'
        ? 'Set TEST_STOREFRONT_ALLOW_WRITES=1 on reebaplus-dev.'
        : null;

typedef _Row = Map<String, Object?>;

/// The only keys a card may carry: public listing fields.
const _cardKeys = {
  'product_id', 'store_id', 'name', 'image_url', 'unit', 'units_per_pack',
  'category', 'price_kobo', 'currency', 'crate_deposit_kobo', 'stock_label',
  'only_left', 'age_restricted', 'stock_may_be_stale', 'business_name',
  'store_lga', 'sponsored', 'cursor',
};
const _storeKeys = {
  'store_id', 'business_name', 'logo_url', 'store_state', 'store_lga',
  'online_note', 'currency', 'delivers_to_area', 'stock_may_be_stale',
};

void main() {
  late SupabaseClient admin;
  late SupabaseClient anon;
  var initialized = false;

  final token = 'zq${Random().nextInt(1 << 30).toRadixString(36)}';
  final state = 'Teststate $token';
  final lgaNear = 'Near $token';
  final lgaFar = 'Far $token';
  final rxSlug = 'test-rx-$token';
  final now = DateTime.now().toUtc();
  String ago(Duration d) => now.subtract(d).toIso8601String();

  final biz = <String, String>{}; // key → business id
  final store = <String, String>{}; // key → store id
  final product = <String, String>{}; // name → product id
  var rxCreated = false;
  String? tombstoned;

  Future<String> business(String key, {
    String status = 'active',
    DateTime? trialEnds,
  }) async {
    final id = UuidV7.generate();
    await admin.from('businesses').insert({
      'id': id,
      'name': 'Fixture $key $token',
      'subscription_status': status,
      'trial_ends_at': trialEnds?.toIso8601String(),
      'tracks_empty_crates': true,
    });
    biz[key] = id;
    return id;
  }

  Future<String> onlineStore(String key, String businessId, {
    String lga = '',
    bool online = true,
    String? deliverState,
    String? deliverLga,
    Duration syncedAgo = Duration.zero,
  }) async {
    final id = UuidV7.generate();
    await admin.from('stores').insert({
      'id': id,
      'business_id': businessId,
      'name': 'Store $key',
      'kind': 'store',
      'country': 'Nigeria',
      'state': state,
      'lga': lga.isEmpty ? lgaNear : lga,
      'online_ordering_enabled': online,
      'last_updated_at': ago(syncedAgo),
    });
    await admin.from('store_delivery_areas').insert({
      'id': UuidV7.generate(),
      'business_id': businessId,
      'store_id': id,
      'country': 'Nigeria',
      'state': deliverState ?? state,
      'lga': deliverLga,
    });
    store[key] = id;
    return id;
  }

  Future<String> item(String name, String businessId, Map<String, int> stock, {
    int threshold = 10,
    bool showOnline = true,
    bool available = true,
    bool deleted = false,
    String? imageUrl,
    String? categoryId,
    String? unit,
    bool trackEmpties = false,
    int crateValue = 0,
    Duration updatedAgo = Duration.zero,
    Duration syncedAgo = Duration.zero,
  }) async {
    final id = UuidV7.generate();
    await admin.from('products').insert({
      'id': id,
      'business_id': businessId,
      'name': '$name $token',
      'retailer_price_kobo': 450000,
      'buying_price_kobo': 300000,
      'low_stock_threshold': threshold,
      'show_online': showOnline,
      'is_available': available,
      'is_deleted': deleted,
      'image_url': imageUrl,
      'category_id': categoryId,
      'unit': unit,
      'track_empties': trackEmpties,
      'empty_crate_value_kobo': crateValue,
      'last_updated_at': ago(updatedAgo),
    });
    for (final entry in stock.entries) {
      await admin.from('inventory').insert({
        'id': UuidV7.generate(),
        'business_id': businessId,
        'product_id': id,
        'store_id': entry.key,
        'quantity': entry.value,
        'last_updated_at': ago(syncedAgo),
      });
    }
    product[name] = id;
    return id;
  }

  Future<String> category(String businessId, String? slug) async {
    final id = UuidV7.generate();
    await admin.from('categories').insert({
      'id': id, 'business_id': businessId, 'name': 'Cat $slug $token',
      'marketplace_category': slug,
    });
    return id;
  }

  Future<List<_Row>> call(String fn, Map<String, Object?> params) async {
    final result = await anon.rpc(fn, params: params);
    return [for (final row in result as List) (row as Map).cast<String, Object?>()];
  }

  final area = <String, Object?>{'p_country': 'Nigeria', 'p_state': state};
  Map<String, Object?> near() => {...area, 'p_lga': lgaNear};

  Future<List<_Row>> allPages(String fn, Map<String, Object?> params, {int limit = 50}) async {
    final out = <_Row>[];
    String? after;
    for (var i = 0; i < 40; i++) {
      final page = await call(fn, {...params, 'p_after': after, 'p_limit': limit});
      out.addAll(page);
      if (page.length < limit) break;
      after = page.last['cursor'] as String;
    }
    return out;
  }

  String nameOf(_Row row) => (row['name'] as String).replaceAll(' $token', '');

  setUpAll(() async {
    if (_skip != null) return;
    final url = _env['TEST_SUPABASE_URL']!;
    if (url != _devUrl) {
      throw StateError('Storefront fixture writes require approved reebaplus-dev.');
    }
    admin = SupabaseClient(url, _env['TEST_SUPABASE_SERVICE_ROLE_KEY']!);
    anon = SupabaseClient(url, _env['TEST_SUPABASE_ANON_KEY']!);
    initialized = true;

    await admin.from('marketplace_categories').insert({
      'slug': rxSlug, 'name': 'Rx $token', 'sort': 9999, 'restricted': 'prescription',
    });
    rxCreated = true;

    final a = await business('A');
    final a1 = await onlineStore('A1', a, lga: lgaNear, deliverLga: lgaNear);
    final a2 = await onlineStore('A2', a, lga: lgaFar); // whole state
    final a3 = await onlineStore('A3', a, online: false, deliverLga: lgaNear);
    final beer = await category(a, 'beer');
    final rx = await category(a, rxSlug);

    // One card per business per product: nearest store wins.
    await item('Shared', a, {a1: 2, a2: 50, a3: 99});
    await item('Only at far store', a, {a2: 50});
    // Stock label boundaries (threshold 10).
    await item('Q11', a, {a1: 11});
    await item('Q10', a, {a1: 10});
    await item('Q4', a, {a1: 4});
    await item('Q3', a, {a1: 3});
    await item('Q1', a, {a1: 1});
    await item('Q0', a, {a1: 0});
    await item('No inventory row', a, {});
    // Low threshold: 3 left is still "Only 3 left".
    await item('Q3 low threshold', a, {a1: 3}, threshold: 1);
    // Ranking: photo first, then most recently updated.
    await item('Photo', a, {a1: 40}, imageUrl: 'https://example.invalid/p.jpg',
        updatedAgo: const Duration(days: 3));
    await item('Newer', a, {a1: 40}, updatedAgo: const Duration(hours: 1));
    await item('Older', a, {a1: 40}, updatedAgo: const Duration(days: 2));
    // Hidden products.
    await item('Show online off', a, {a1: 20}, showOnline: false);
    await item('Archived', a, {a1: 20}, available: false);
    await item('Deleted', a, {a1: 20}, deleted: true);
    await item('Prescription', a, {a1: 20}, categoryId: rx);
    // 18+ and the crate deposit note.
    await item('Beer bottle', a, {a1: 20}, categoryId: beer, unit: 'Bottle',
        trackEmpties: true, crateValue: 150000);

    final t = await business('T', status: 'trial',
        trialEnds: now.subtract(const Duration(days: 1)));
    await item('Trial ended', t, {await onlineStore('T1', t): 20});
    final ok = await business('Trial', status: 'trial',
        trialEnds: now.add(const Duration(days: 10)));
    await item('Trial running', ok, {await onlineStore('Trial1', ok): 20});
    final i = await business('I', status: 'inactive');
    await item('Inactive', i, {await onlineStore('I1', i): 20});
    final x = await business('X');
    await item('Tombstoned', x, {await onlineStore('X1', x): 20});
    await admin.from('deleted_businesses').insert({
      'business_id': x, 'business_name': 'Fixture X $token',
    });
    tombstoned = x;
    final o = await business('O');
    await item('Out of area', o, {
      await onlineStore('O1', o, deliverState: 'Elsewhere $token'): 20,
    });
    final s = await business('S');
    await item('Stale 80h', s, {
      await onlineStore('S1', s, syncedAgo: const Duration(hours: 80)): 20,
    }, syncedAgo: const Duration(hours: 80));
    final h = await business('H');
    await item('Stale 8d', h, {
      await onlineStore('H1', h, syncedAgo: const Duration(days: 8)): 20,
    }, syncedAgo: const Duration(days: 8));
  });

  tearDownAll(() async {
    if (!initialized) return;
    try {
      if (tombstoned != null) {
        await admin.from('deleted_businesses').delete().eq('business_id', tombstoned!);
      }
      for (final id in biz.values) {
        await admin.from('businesses').delete().eq('id', id);
      }
      if (rxCreated) {
        await admin.from('marketplace_categories').delete().eq('slug', rxSlug);
      }
    } finally {
      await admin.dispose();
      await anon.dispose();
    }
  });

  test('responses carry public listing fields only', () async {
    final feed = await call('storefront_feed', near());
    final search = await call('storefront_search', {...near(), 'p_query': token});
    final page = await call('storefront_store_products', {'p_store_id': store['A1']});
    for (final row in [...feed, ...search, ...page]) {
      expect(row.keys.toSet(), _cardKeys, reason: 'no raw stock / cost / tenant ids');
      expect(row['sponsored'], isFalse);
      final left = row['only_left'];
      expect(left == null || (left as int) >= 1 && left <= 3, isTrue);
    }
    final header = await call('storefront_store', {'p_store_id': store['A1'], ...near()});
    expect(header.single.keys.toSet(), _storeKeys);
  }, skip: _skip);

  test('feed: hide rules, one card per product, Business · LGA', () async {
    final feed = await allPages('storefront_feed', near());
    final names = feed.map(nameOf).toList();
    expect(names.toSet().length, names.length, reason: 'no duplicate cards');
    expect(names, containsAll(['Shared', 'Only at far store', 'Q11', 'Q10', 'Q4', 'Q3',
        'Q1', 'Photo', 'Newer', 'Older', 'Beer bottle', 'Trial running', 'Stale 80h',
        'Q3 low threshold']));
    for (final hidden in ['Q0', 'No inventory row', 'Show online off', 'Archived',
        'Deleted', 'Prescription', 'Trial ended', 'Inactive', 'Tombstoned',
        'Out of area', 'Stale 8d']) {
      expect(names, isNot(contains(hidden)), reason: '$hidden must be hidden');
    }
    final shared = feed.singleWhere((r) => nameOf(r) == 'Shared');
    expect(shared['store_id'], store['A1'], reason: 'nearest delivering store');
    expect(shared['stock_label'], 'only_few_left');
    expect(shared['only_left'], 2);
    expect(shared['business_name'], 'Fixture A $token');
    expect(shared['store_lga'], lgaNear);
    final beer = feed.singleWhere((r) => nameOf(r) == 'Beer bottle');
    expect(beer['age_restricted'], isTrue);
    expect(beer['crate_deposit_kobo'], 150000);
    expect(beer['category'], 'beer');
    expect(feed.singleWhere((r) => nameOf(r) == 'Q11')['category'], 'other');
  }, skip: _skip);

  test('stock label boundaries', () async {
    final rows = await allPages('storefront_search', {...near(), 'p_query': token});
    String label(String name) => rows.singleWhere((r) => nameOf(r) == name)['stock_label'] as String;
    expect(label('Q11'), 'in_stock');
    expect(label('Q10'), 'low_stock');
    expect(label('Q4'), 'low_stock');
    expect(label('Q3'), 'only_few_left');
    expect(label('Q1'), 'only_few_left');
    expect(label('Q0'), 'out_of_stock');
    expect(label('No inventory row'), 'out_of_stock');
    expect(label('Q3 low threshold'), 'only_few_left');
    expect(rows.singleWhere((r) => nameOf(r) == 'Q1')['only_left'], 1);
  }, skip: _skip);

  test('ranking: LGA before state, stock, photo, recency; stale last', () async {
    final names = (await allPages('storefront_feed', near())).map(nameOf).toList();
    int at(String n) => names.indexOf(n);
    for (final nearName in ['Q11', 'Q10', 'Q1', 'Photo', 'Beer bottle']) {
      expect(at(nearName), lessThan(at('Only at far store')));
    }
    expect(at('Q11'), lessThan(at('Q10')), reason: 'in stock before low');
    expect(at('Q4'), lessThan(at('Q3')), reason: 'low before only N');
    expect(at('Photo'), lessThan(at('Newer')), reason: 'photo first');
    expect(at('Newer'), lessThan(at('Older')), reason: 'recent first');
    expect(at('Stale 80h'), names.length - 1, reason: '72 h stale is demoted');
    final stale = (await call('storefront_search', {...near(), 'p_query': 'Stale 80h'}))
        .single;
    expect(stale['stock_may_be_stale'], isTrue);
  }, skip: _skip);

  test('keyset pages join up to the full ranked list', () async {
    final full = (await allPages('storefront_feed', near())).map((r) => r['product_id']);
    final paged = (await allPages('storefront_feed', near(), limit: 3))
        .map((r) => r['product_id']);
    expect(paged.toList(), full.toList());
    await expectLater(
      call('storefront_feed', {...near(), 'p_after': 'not-a-cursor'}),
      throwsA(isA<PostgrestException>().having((e) => e.code, 'code', '22023')),
    );
  }, skip: _skip);

  test('delivery areas: LGA, whole state, other areas, all of Nigeria', () async {
    final otherLga = (await allPages('storefront_feed',
        {...area, 'p_lga': 'Nowhere $token'})).map(nameOf);
    expect(otherLga, contains('Only at far store'), reason: 'whole-state store');
    expect(otherLga, isNot(contains('Q11')), reason: 'A1 delivers to one LGA only');
    final otherState = await call('storefront_feed', {
      'p_country': 'Nigeria', 'p_state': 'Nostate $token'});
    expect(otherState.map(nameOf), isNot(contains('Shared')));
    final elsewhere = (await allPages('storefront_search', {
      'p_country': 'Nigeria', 'p_state': 'Elsewhere $token', 'p_query': token})).map(nameOf);
    expect(elsewhere, contains('Out of area'));
    expect(elsewhere, isNot(contains('Shared')));
  }, skip: _skip);

  test('search and store page show out-of-stock; category filter', () async {
    final search = (await allPages('storefront_search', {...near(), 'p_query': token}))
        .map(nameOf).toList();
    expect(search, containsAll(['Q0', 'Shared']));
    expect(search, isNot(contains('Out of area')));
    expect(search, isNot(contains('Show online off')));
    final beverages = await allPages('storefront_search',
        {...near(), 'p_query': token, 'p_category': 'beverages'});
    expect(beverages.map(nameOf), ['Beer bottle']);
    final other = await allPages('storefront_feed', {...near(), 'p_category': 'other'});
    expect(other.map(nameOf), isNot(contains('Beer bottle')));
    expect(other.map(nameOf), contains('Q11'));

    final page = (await allPages('storefront_store_products', {'p_store_id': store['A1']}))
        .map(nameOf).toList();
    expect(page, containsAll(['Q0', 'Shared']));
    expect(page, isNot(contains('Only at far store')), reason: 'own store only');
    final own = await call('storefront_store_products',
        {'p_store_id': store['A1'], 'p_query': 'q1'});
    expect(own.map(nameOf), containsAll(['Q11', 'Q10', 'Q1']));
  }, skip: _skip);

  test('store page: out of area browsable, hidden stores empty', () async {
    final far = await call('storefront_store', {'p_store_id': store['O1'], ...near()});
    expect(far.single['delivers_to_area'], isFalse);
    expect((await call('storefront_store_products', {'p_store_id': store['O1']}))
        .map(nameOf), ['Out of area']);
    final mine = await call('storefront_store', {'p_store_id': store['A1'], ...near()});
    expect(mine.single['delivers_to_area'], isTrue);
    expect(mine.single['business_name'], 'Fixture A $token');
    for (final hidden in ['A3', 'T1', 'I1', 'X1', 'H1']) {
      expect(await call('storefront_store', {'p_store_id': store[hidden], ...near()}),
          isEmpty, reason: '$hidden is not listed');
      expect(await call('storefront_store_products', {'p_store_id': store[hidden]}),
          isEmpty, reason: '$hidden catalogue is not listed');
    }
  }, skip: _skip);

  test('a van can never be switched online', () async {
    await expectLater(
      admin.from('stores').insert({
        'id': UuidV7.generate(), 'business_id': biz['A'], 'name': 'Van $token',
        'kind': 'van', 'state': state, 'lga': lgaNear,
        'online_ordering_enabled': true,
      }),
      throwsA(isA<PostgrestException>()),
    );
  }, skip: _skip);

  test('signed-out callers cannot reach tenant tables or internal helpers', () async {
    for (final table in ['products', 'inventory', 'stores', 'businesses', 'customers',
        'cost_batches', 'store_delivery_areas', 'settings', 'devices']) {
      try {
        final rows = await anon.from(table).select().limit(1);
        expect(rows, isEmpty, reason: 'anon must not read $table');
      } on PostgrestException catch (e) {
        expect(e.code, anyOf('42501', 'PGRST301', '42P01'));
      }
    }
    for (final helper in {
      '_storefront_stores': {'p_store_id': store['A1']},
      '_storefront_reach': {'p_country': 'Nigeria', 'p_state': state, 'p_lga': lgaNear},
      '_storefront_cards': {
        'p_mode': 'feed', 'p_country': 'Nigeria', 'p_state': state, 'p_lga': lgaNear,
        'p_store_id': null, 'p_category': null, 'p_query': null, 'p_after': null,
        'p_limit': 5,
      },
    }.entries) {
      await expectLater(anon.rpc(helper.key, params: helper.value),
          throwsA(isA<PostgrestException>()), reason: helper.key);
    }
  }, skip: _skip);
}
