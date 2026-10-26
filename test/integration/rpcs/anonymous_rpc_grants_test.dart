@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// No signed-in session or tenant fixtures: these tests only call RPCs as anon.
void main() {
  final url = Platform.environment['TEST_SUPABASE_URL'];
  final key = Platform.environment['TEST_SUPABASE_ANON_KEY'];
  final enabled = url == 'https://yngwzuinxhxhzdfagcbg.supabase.co' &&
      key != null && key.isNotEmpty;
  late SupabaseClient client;
  setUpAll(() {
    if (enabled) client = SupabaseClient(url!, key);
  });
  tearDownAll(() async {
    if (enabled) await client.dispose();
  });

  const uuid = '00000000-0000-4000-8000-000000000001';
  final revoked = <String, Map<String, Object?>>{
    'is_console_admin': {},
    'is_console_admin_email': {'p_email': 'nobody@example.invalid'},
    'complete_onboarding': {
      'p_business_id': uuid, 'p_store_id': uuid, 'p_user_id': uuid,
      'p_owner_name': 'Test', 'p_business_name': 'Test',
      'p_business_type': 'Beverage distributor', 'p_business_phone': '',
      'p_business_email': '', 'p_location': <String, Object?>{},
      'p_settings': <String, Object?>{}, 'p_tracks_empty_crates': false,
    },
    'pos_record_sale_v2': {
      'p_business_id': uuid, 'p_actor_id': uuid, 'p_order_id': uuid,
      'p_order_number': 'DENIED-468', 'p_store_id': uuid,
      'p_payment_type': 'cash', 'p_items': <Object?>[],
    },
  };
  // Trigger-returning functions are excluded from PostgREST's schema cache.
  // Their actual SQL EXECUTE boundary is checked by anonymous_rpc_grants.sql.
  for (final entry in revoked.entries) {
    test('${entry.key} rejects signed-out callers at permission boundary', () async {
      await expectLater(
        client.rpc(entry.key, params: entry.value),
        throwsA(isA<PostgrestException>()
            .having((e) => e.code, 'SQLSTATE', '42501')
            .having((e) => e.message, 'message', contains('permission denied'))),
      );
    }, skip: enabled ? false : 'Requires dedicated ordering dev URL and anon key');
  }

  test('mobile invitation lookup remains callable without a session', () async {
    final result = await client.rpc('lookup_invite_code', params: {'p_code': ''});
    expect(result, [
      {'valid': false, 'business_name': null, 'role_name': null, 'email': null},
    ]);
  }, skip: enabled ? false : 'Requires dedicated ordering dev URL and anon key');

  // Legacy accept_invite_preview* were dropped in 0220 (#506): they read the
  // long-gone invites/warehouses tables. See docs/security/anonymous-rpcs.md.

  test('public trial duration remains a scalar', () async {
    expect(await client.rpc('console_get_trial_days'), isA<int>());
  }, skip: enabled ? false : 'Requires dedicated ordering dev URL and anon key');
}
