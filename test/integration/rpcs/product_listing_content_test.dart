@Tags(['integration'])
library;

// #473 tier-2: cloud 0201 listing columns, their CHECKs and the shared
// order_quantity_allowed rule the place-order RPC (#426) will call.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/listings/listing_content.dart';
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
    await admin.from('businesses').insert({'id': businessId, 'name': 'Listing content fixture'});
    businessCreated = true;
  });

  tearDownAll(() async {
    if (!initialized) return;
    try {
      if (businessCreated) await admin.from('businesses').delete().eq('id', businessId);
    } finally { await admin.dispose(); }
  });

  test('columns default, persist and refuse out-of-range values', () async {
    final inserted = await admin.from('products').insert({
      'id': productId, 'business_id': businessId, 'name': 'Listing content product',
    }).select().single();
    expect((inserted['online_description'], inserted['brand'], inserted['min_order_qty'],
      inserted['order_step'], inserted['max_order_qty']), (null, null, 1, 1, null));
    await admin.from('products').update({'online_description': 'Cold', 'brand': 'Gulder',
      'min_order_qty': 12, 'order_step': 12, 'max_order_qty': 48}).eq('id', productId);
    for (final bad in <Map<String, Object>>[
      {'min_order_qty': 0}, {'order_step': 0}, {'max_order_qty': 6},
      {'brand': 'x' * 61}, {'online_description': 'x' * 2001},
    ]) {
      await expectLater(admin.from('products').update(bad).eq('id', productId),
        throwsA(isA<PostgrestException>()), reason: '$bad');
    }
  }, skip: _skip);

  test('order_quantity_allowed matches the Dart rule', () async {
    for (final (min, step, max) in [(1, 1, null), (1, 12, null), (6, 6, 18), (5, 2, 9)]) {
      final rule = OrderQuantityRule(min: min, step: step, max: max);
      for (final qty in [0, 1, 5, 6, 12, 13, 18, 24]) {
        final cloud = await admin.rpc('order_quantity_allowed', params: {
          'p_quantity': qty, 'p_min': min, 'p_step': step, 'p_max': max});
        expect(cloud, rule.allows(qty), reason: '($min,$step,$max) qty $qty');
      }
    }
  }, skip: _skip);
}
