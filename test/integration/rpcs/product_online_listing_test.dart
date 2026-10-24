@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _env = Platform.environment;
final _skip = ['TEST_SUPABASE_URL', 'TEST_SUPABASE_SERVICE_ROLE_KEY']
    .any((key) => _env[key]?.isNotEmpty != true)
    ? 'Listing tests need development URL and service-role credentials.'
    : _env['TEST_LISTING_ALLOW_WRITES'] != '1'
        ? 'Set TEST_LISTING_ALLOW_WRITES=1 on reebaplus-dev.' : null;

void main() {
  late SupabaseClient admin;
  final businessId = UuidV7.generate();
  final productId = UuidV7.generate();
  var initialized = false;
  var businessCreated = false;

  setUpAll(() async {
    if (_skip != null) return;
    final url = _env['TEST_SUPABASE_URL']!;
    if (url != 'https://yngwzuinxhxhzdfagcbg.supabase.co') {
      throw StateError('Listing fixture writes require approved reebaplus-dev.');
    }
    admin = SupabaseClient(url, _env['TEST_SUPABASE_SERVICE_ROLE_KEY']!);
    initialized = true;
    await admin.from('businesses').insert({'id': businessId, 'name': 'Listing fixture'});
    businessCreated = true;
  });

  tearDownAll(() async {
    if (!initialized) return;
    try {
      if (businessCreated) await admin.from('businesses').delete().eq('id', businessId);
    } finally { await admin.dispose(); }
  });

  test('cloud visibility defaults on, persists off and excludes unavailable products', () async {
    final inserted = await admin.from('products').insert({
      'id': productId, 'business_id': businessId, 'name': 'Listing fixture product',
    }).select().single();
    expect(inserted['show_online'], isTrue);

    Future<List<Map<String, Object?>>> storefrontCandidates() async =>
        await admin.from('products').select().eq('business_id', businessId)
          .eq('show_online', true).eq('is_available', true).eq('is_deleted', false);

    expect(await storefrontCandidates(), hasLength(1));
    await admin.from('products').update({'show_online': false}).eq('id', productId);
    expect(await storefrontCandidates(), isEmpty);
    expect((await admin.from('products').select('show_online').eq('id', productId).single())
      ['show_online'], isFalse);
    await admin.from('products').update({'show_online': true, 'is_available': false})
      .eq('id', productId);
    expect(await storefrontCandidates(), isEmpty);
    await admin.from('products').update({'is_available': true, 'is_deleted': true})
      .eq('id', productId);
    expect(await storefrontCandidates(), isEmpty);
  }, skip: _skip);

  test('new-business seed grants independent listing key only to CEO and Manager', () async {
    await admin.rpc('seed_default_roles_for_business', params: {'p_business_id': businessId});
    final roles = await admin.from('roles').select('id,slug').eq('business_id', businessId);
    final grants = await admin.from('role_permissions').select('role_id')
      .eq('business_id', businessId).eq('permission_key', 'products.manage_listing');
    final grantedIds = grants.map((row) => row['role_id']).toSet();
    expect(roles.where((role) => grantedIds.contains(role['id'])).map((role) => role['slug']),
      unorderedEquals(['ceo', 'manager']));
    final permission = await admin.from('permissions').select('category')
      .eq('key', 'products.manage_listing').single();
    expect(permission['category'], 'Online store');
  }, skip: _skip);
}
