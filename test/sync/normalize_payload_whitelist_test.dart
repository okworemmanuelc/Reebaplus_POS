import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

/// Locks in the §6.6 whitelist scrub for the four sensitive tables.
/// New local-only columns added to Drift must NOT leak through this
/// scrub unless they're explicitly added to `_pushableColumns`.
void main() {
  group('normalizePayloadForCloud whitelist (§6.6)', () {
    test('users: pin / password_hash / pin_salt / pin_iterations dropped',
        () {
      final scrubbed = SupabaseSyncService.scrubForTesting('users', {
        'id': 'abc',
        'business_id': 'biz',
        'name': 'Alice',
        'role': 'ceo',
        'pin': '0000',
        'password_hash': 'hash',
        'pin_salt': 'salt',
        'pin_iterations': 100000,
      });
      expect(scrubbed.containsKey('pin'), isFalse);
      expect(scrubbed.containsKey('password_hash'), isFalse);
      expect(scrubbed.containsKey('pin_salt'), isFalse);
      expect(scrubbed.containsKey('pin_iterations'), isFalse);
      expect(scrubbed['name'], 'Alice');
      expect(scrubbed['role'], 'ceo');
    });

    test('sessions: token / ip_address / user_agent dropped', () {
      final scrubbed = SupabaseSyncService.scrubForTesting('sessions', {
        'id': 'sess-1',
        'business_id': 'biz',
        'user_id': 'u1',
        'token': 'super-secret-bearer',
        'ip_address': '10.0.0.1',
        'user_agent': 'Mozilla/5.0',
        'expires_at': '2026-12-31T00:00:00Z',
      });
      expect(scrubbed.containsKey('token'), isFalse,
          reason: 'auth material must never push');
      expect(scrubbed.containsKey('ip_address'), isFalse);
      expect(scrubbed.containsKey('user_agent'), isFalse);
      expect(scrubbed['user_id'], 'u1');
    });

    test('businesses: local-only `timezone` dropped', () {
      final scrubbed = SupabaseSyncService.scrubForTesting('businesses', {
        'id': 'biz',
        'name': 'Acme',
        'timezone': 'Africa/Lagos',
        'owner_id': 'owner-1',
      });
      expect(scrubbed.containsKey('timezone'), isFalse,
          reason: 'cloud businesses has no timezone column');
      expect(scrubbed['name'], 'Acme');
    });

    test('fail-closed: unknown columns dropped from whitelisted tables',
        () {
      final scrubbed = SupabaseSyncService.scrubForTesting('users', {
        'id': 'abc',
        'name': 'Bob',
        'shadow_field': 'leak-vector', // not in whitelist
      });
      expect(scrubbed.containsKey('shadow_field'), isFalse,
          reason: 'unknown columns must fail-closed for sensitive tables');
      expect(scrubbed['name'], 'Bob');
    });

    test('non-whitelisted tables pass through unchanged', () {
      final scrubbed = SupabaseSyncService.scrubForTesting('products', {
        'id': 'p1',
        'name': 'Beer',
        'selling_price_kobo': 1000,
      });
      // products isn't in the whitelist (cloud column set == drift
      // column set), so all keys pass through.
      expect(scrubbed['id'], 'p1');
      expect(scrubbed['name'], 'Beer');
      expect(scrubbed['selling_price_kobo'], 1000);
    });
  });
}
