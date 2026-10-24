import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';

void main() {
  for (final deleted in [true, false]) {
    test('deletion check returns $deleted through the restricted RPC', () async {
      final client = SupabaseClient(
        'https://example.supabase.co', 'test-key',
        httpClient: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/rest/v1/rpc/business_deletion_status');
          expect(jsonDecode(request.body), {'p_business_id': 'business-id'});
          return http.Response(jsonEncode(deleted), 200,
              headers: {'content-type': 'application/json'}, request: request);
        }),
      );
      try {
        expect(await SupabaseCloudTransport(client)
            .businessDeletedTombstoneExists('business-id'), deleted);
      } finally {
        await client.dispose();
      }
    });
  }

  test('authorization failure is propagated rather than treated as deleted', () async {
    final client = SupabaseClient(
      'https://example.supabase.co', 'test-key',
      httpClient: MockClient((request) async => http.Response(
        jsonEncode({'code': '42501', 'message': 'Unauthenticated'}), 403,
        headers: {'content-type': 'application/json'}, request: request,
      )),
    );
    try {
      await expectLater(SupabaseCloudTransport(client)
          .businessDeletedTombstoneExists('business-id'),
          throwsA(isA<PostgrestException>()));
    } finally {
      await client.dispose();
    }
  });
}
