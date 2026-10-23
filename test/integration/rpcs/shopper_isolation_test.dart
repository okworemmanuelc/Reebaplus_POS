@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Uses a throwaway login, never the operator's refresh token. Explicit opt-in:
// this suite creates/deletes its own fixtures on a dedicated test project.
final _env = Platform.environment;
final _skip = [
  'TEST_SUPABASE_URL',
  'TEST_SUPABASE_ANON_KEY',
  'TEST_SUPABASE_SERVICE_ROLE_KEY',
].any((key) => _env[key]?.isNotEmpty != true)
    ? 'Shopper isolation needs the three TEST_SUPABASE_* variables; see integration/README.md.'
    : _env['TEST_SHOPPER_ISOLATION_ALLOW_WRITES'] != '1'
        ? 'Set TEST_SHOPPER_ISOLATION_ALLOW_WRITES=1 on a dedicated test project.'
        : null;

typedef _Json = Map<String, Object?>;

_Json _map(Object? value) => (value as Map).cast<String, Object?>();

_Json _resolveSchema(_Json value, _Json definitions) {
  final reference = value[r'$ref'] as String?;
  return reference == null ? value : _map(definitions[reference.split('/').last]);
}

Object _argument({required String name, required _Json property, required _Json ids}) {
  final id = ids[name];
  if (id != null) return id;
  if (property['format'] == 'uuid') return UuidV7.generate();
  if (property['format'] == 'timestamp with time zone' ||
      property['format'] == 'date-time') {
    return DateTime.now().toUtc().toIso8601String();
  }
  switch (property['type']) {
    case 'integer':
    case 'number':
      return 1;
    case 'boolean':
      return false;
    case 'array':
      return <String>[];
    case 'object':
      return <String, Object?>{};
    case 'string':
      // PostgREST describes Postgres json/jsonb as strings in OpenAPI 2.
      if (property['format'] == 'json' || property['format'] == 'jsonb') {
        return name == 'p_items' || name == 'p_movements' || name == 'p_pairs'
            ? <String>[] : <String, Object?>{};
      }
      return 'isolation-test';
  }
  throw StateError('Unhandled RPC parameter $name: $property');
}

// Read the service-role OpenAPI schema so new cloud-only tenant tables and
// new tenant RPCs enter coverage automatically, even before Drift knows them.
Future<_Json> _schema({required String url, required String key}) async {
  final http = HttpClient();
  try {
    final request = await http.getUrl(Uri.parse('$url/rest/v1/'));
    request.headers.set('apikey', key);
    request.headers.set('Authorization', 'Bearer $key');
    request.headers.set('Accept', 'application/openapi+json');
    final response = await request.close();
    expect(response.statusCode, 200, reason: 'service-role schema discovery must work');
    return _map(jsonDecode(await utf8.decoder.bind(response).join()));
  } finally {
    http.close();
  }
}

Future<void> _denied(Future<Object?> Function() call) async {
  try {
    await call();
    fail('Expected an authorization rejection, but the operation succeeded');
  } on PostgrestException catch (error) {
    // A missing function, invalid argument, FK error or empty-input validation
    // is not proof of isolation. Require an actual authorization refusal.
    expect(
      error.code == '42501' ||
          (error.code == 'P0001' &&
              RegExp('forbidden|unauthenticated|not.authori[sz]ed|not.owner|no.business|tenant.mismatch',
                      caseSensitive: false)
                  .hasMatch(error.message)),
      isTrue,
      reason: 'Expected authorization failure, got ${error.code}: ${error.message}',
    );
  }
}

Future<void> _noRows(Future<List<Map<String, Object?>>> Function() call) async {
  try {
    expect(await call(), isEmpty);
  } on PostgrestException catch (error) {
    expect(error.code, '42501', reason: error.message);
  }
}

void main() {
  late SupabaseClient admin;
  late SupabaseClient shopper;
  late SupabaseClient anon;
  late _Json schema;
  String? authId;
  final businessId = UuidV7.generate();
  final productId = UuidV7.generate();
  final customerId = UuidV7.generate();
  final storeId = UuidV7.generate();
  var businessCreated = false;

  setUpAll(() async {
    if (_skip != null) return;
    final url = _env['TEST_SUPABASE_URL']!;
    final key = _env['TEST_SUPABASE_ANON_KEY']!;
    admin = SupabaseClient(url, _env['TEST_SUPABASE_SERVICE_ROLE_KEY']!);
    shopper = SupabaseClient(url, key);
    anon = SupabaseClient(url, key);
    schema = await _schema(url: url, key: _env['TEST_SUPABASE_SERVICE_ROLE_KEY']!);

    final email = 'shopper-isolation-${UuidV7.generate()}@example.com';
    final password = '${UuidV7.generate()}Aa1!';
    final created = await admin.auth.admin.createUser(AdminUserAttributes(
      email: email,
      password: password,
      emailConfirm: true,
    ));
    authId = created.user!.id;
    await shopper.auth.signInWithPassword(email: email, password: password);
    expect(shopper.auth.currentUser!.id, authId);
    expect(await shopper.rpc('current_user_linked_business'), isEmpty);
    expect(await shopper.rpc('current_user_business_ids'), isEmpty);

    // The target tenant belongs to neither client. Only these fixture UUIDs
    // are passed to write probes; never use an existing business's IDs.
    await admin.from('businesses').insert({'id': businessId, 'name': 'Shopper isolation test'});
    businessCreated = true;
    await admin.from('stores').insert({
      'id': storeId, 'business_id': businessId, 'name': 'Test store',
    });
    await admin.from('products').insert({
      'id': productId, 'business_id': businessId, 'name': 'Private test product',
      'buying_price_kobo': 12345,
    });
    await admin.from('customers').insert({
      'id': customerId, 'business_id': businessId, 'name': 'Private test customer',
    });
  });

  tearDown(() async {
    if (_skip != null || authId == null) return;
    // Even a failed pointer-forgery test cannot contaminate subsequent tests.
    await admin.from('profiles').delete().eq('id', authId!);
  });

  tearDownAll(() async {
    if (_skip != null) return;
    try {
      if (authId != null) {
        await admin.from('profiles').delete().eq('id', authId!);
      }
      if (businessCreated) await admin.from('businesses').delete().eq('id', businessId);
    } finally {
      try {
        if (authId != null) await admin.auth.admin.deleteUser(authId!);
      } finally {
        await shopper.dispose();
        await anon.dispose();
        await admin.dispose();
      }
    }
  });

  group('Shopper tenant boundary (#422)', () {
    test('anon and a real membership-less login see no live tenant table rows', () async {
      final definitions = _map(schema['definitions']);
      final tenantTables = <String>{'businesses'};
      for (final entry in definitions.entries) {
        final properties = _map(_map(entry.value)['properties']);
        if (properties.containsKey('business_id')) tenantTables.add(entry.key);
      }
      // Tombstones intentionally survive membership deletion (0114). Their
      // broad read policy is an explicit unresolved blocker in the audit doc.
      tenantTables.remove('deleted_businesses');
      expect(tenantTables, containsAll(['products', 'cost_batches', 'customers', 'profiles']));
      expect(tenantTables.length, greaterThan(50), reason: 'schema discovery must not be vacuous');
      // A positive control proves RLS, rather than an empty database, hides data.
      expect(await admin.from('products').select('id').eq('id', productId), hasLength(1));
      for (final client in [anon, shopper]) {
        for (final table in tenantTables) {
          try {
            expect(await client.from(table).select().limit(1), isEmpty, reason: table);
          } on PostgrestException catch (error) {
            expect(error.code, '42501', reason: '$table: ${error.message}');
          }
        }
      }
    }, skip: _skip);

    test('cannot forge a profile pointer to gain another business', () async {
      await _denied(() => shopper.from('profiles').insert({
        'id': authId!, 'business_id': businessId, 'name': 'Pointer forgery',
      }));
      expect(await shopper.from('products').select().eq('id', productId), isEmpty);
      expect(await shopper.rpc('current_user_business_ids'), isEmpty);
    }, skip: _skip);

    test('cannot move an existing own profile pointer to another business', () async {
      final ownBusinessId = UuidV7.generate();
      try {
        await admin.from('businesses').insert({
          'id': ownBusinessId, 'name': 'Profile update control', 'owner_id': authId!,
        });
        // Legitimate owner profile bootstrap remains possible after the policy change.
        await shopper.from('profiles').insert({
          'id': authId!, 'business_id': ownBusinessId, 'name': 'Profile owner',
        });
        await shopper.from('profiles').update({'name': 'Updated owner'}).eq('id', authId!);
        final ownProfile = await shopper.from('profiles').select('name').single();
        expect(ownProfile['name'], 'Updated owner');
        await _denied(() => shopper.from('profiles').update({
          'business_id': businessId,
        }).eq('id', authId!));
        final profile = await shopper.from('profiles').select('business_id').single();
        expect(profile['business_id'], ownBusinessId);
        expect(await shopper.from('products').select().eq('id', productId), isEmpty);
      } finally {
        await admin.from('profiles').delete().eq('id', authId!);
        await admin.from('businesses').delete().eq('id', ownBusinessId);
      }
    }, skip: _skip);

    test('internal checkout and role-seeding functions are not client RPCs', () async {
      final probes = <String, _Json>{
        '_checkout_mint_order_number': {'p_business_id': businessId, 'p_order_id': UuidV7.generate()},
        '_customer_wallet_balance': {'p_business_id': businessId, 'p_customer_id': customerId},
        '_checkout_draw_fifo': {
          'p_business_id': businessId, 'p_order_id': UuidV7.generate(),
          'p_store_id': storeId, 'p_items': <String>[], 'p_now': DateTime.now().toUtc().toIso8601String(),
        },
        '_checkout_insert_lines': {
          'p_business_id': businessId, 'p_order_id': UuidV7.generate(),
          'p_store_id': storeId, 'p_items': <String>[], 'p_actor_id': UuidV7.generate(),
          'p_now': DateTime.now().toUtc().toIso8601String(),
        },
        'seed_default_roles_for_business': {'p_business_id': businessId},
      };
      // Optional web-baseline function: harden when installed; a clean mobile
      // migration chain does not create it. The five helpers above are required.
      if (_map(schema['paths']).containsKey('/rpc/is_other_business_owner')) {
        probes['is_other_business_owner'] = {
          'p_email': 'unrelated@example.com', 'p_exclude_business_id': businessId,
        };
      }
      for (final client in [anon, shopper]) {
        for (final probe in probes.entries) {
          await _denied(() => client.rpc(probe.key, params: probe.value));
        }
      }
    }, skip: _skip);

    test('read and write entry points reject a membership-less caller', () async {
      for (final client in [anon, shopper]) {
        await _denied(() => client.rpc('pos_pull_snapshot', params: {'p_business_id': businessId}));
        await _denied(() => client.rpc('pos_create_customer', params: {
          'p_business_id': businessId, 'p_customer_id': UuidV7.generate(),
          'p_wallet_id': UuidV7.generate(), 'p_name': 'Forbidden customer',
        }));
        await _denied(() => client.from('products').insert({
          'id': UuidV7.generate(), 'business_id': businessId, 'name': 'Forbidden product',
        }));
        await _noRows(() => client.from('products').update({'name': 'Forbidden edit'})
            .eq('id', productId).select('id'));
        await _noRows(() => client.from('customers').delete().eq('id', customerId).select('id'));
      }
      final product = await admin.from('products').select('name').eq('id', productId).single();
      expect(product['name'], 'Private test product');
      expect(await admin.from('customers').select('id').eq('id', customerId), hasLength(1));
    }, skip: _skip);

    test('every discovered business-scoped RPC enforces the tenant boundary', () async {
      final definitions = _map(schema['definitions']);
      final paths = _map(schema['paths']);
      final tested = <String>[];
      final ids = <String, Object?>{
        'p_business_id': businessId, 'p_product_id': productId,
        'p_store_id': storeId, 'p_customer_id': customerId,
      };
      // These are explicitly pre-membership operations, not tenant access.
      const bootstrap = {'start_onboarding', 'complete_onboarding'};
      // These disclose only the caller's own lack of authority.
      const neutralHelpers = {'caller_has_permission', 'caller_role_slug', 'caller_max_discount_percent'};
      for (final entry in paths.entries) {
        if (!entry.key.startsWith('/rpc/')) continue;
        final name = entry.key.substring('/rpc/'.length);
        if (bootstrap.contains(name)) continue;
        final post = _map(entry.value)['post'];
        if (post == null) continue;
        final parameters = _map(post)['parameters'] as List? ?? const [];
        for (final parameter in parameters) {
          final body = _map(parameter);
          if (body['in'] != 'body') continue;
          final input = _resolveSchema(_map(body['schema']), definitions);
          final properties = _map(input['properties'] ?? <String, Object?>{});
          if (!properties.containsKey('p_business_id')) continue;
          final params = <String, Object?>{};
          final required = (input['required'] as List? ?? const []).cast<String>().toSet();
          for (final property in properties.entries) {
            if (property.key != 'p_business_id' && !required.contains(property.key)) continue;
            params[property.key] = _argument(
              name: property.key, property: _map(property.value), ids: ids,
            );
          }
          tested.add(name);
          printOnFailure('RPC isolation probe: $name');
          for (final client in [anon, shopper]) {
            if (neutralHelpers.contains(name) && identical(client, shopper)) {
              final result = await client.rpc(name, params: params);
              expect(result == null || result == false || result == 0, isTrue, reason: name);
            } else {
              await _denied(() => client.rpc(name, params: params));
            }
          }
        }
      }
      expect(tested, containsAll(['pos_pull_snapshot', 'pos_record_sale_v2', 'checkout_order']));
      expect(tested.length, greaterThan(20), reason: 'RPC discovery must not be vacuous');
    }, skip: _skip);
  });
}
