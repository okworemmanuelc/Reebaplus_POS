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

    test('businesses: subscription columns are app-read-only (dropped on push)',
        () {
      // §32: the app must never push subscription state — it is cloud-
      // authoritative (only the admin console writes it). If these ever leak
      // through, a cashier could self-activate from the device.
      final scrubbed = SupabaseSyncService.scrubForTesting('businesses', {
        'id': 'biz',
        'name': 'Acme',
        'subscription_status': 'active',
        'subscription_plan': 'international',
        'trial_ends_at': '2026-12-31T00:00:00Z',
        'current_period_end': '2026-12-31T00:00:00Z',
      });
      expect(scrubbed.containsKey('subscription_status'), isFalse);
      expect(scrubbed.containsKey('subscription_plan'), isFalse);
      expect(scrubbed.containsKey('trial_ends_at'), isFalse);
      expect(scrubbed.containsKey('current_period_end'), isFalse);
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

  // The append-only ledgers whose void path re-pushes the FULL row
  // (payment/wallet/supplier-ledger) must never carry `created_at`: the cloud
  // owns it (DEFAULT now()) and Drift truncates the local value to whole
  // seconds, so a re-push can't match the stored value and the BEFORE UPDATE
  // append-only trigger rejects it (P0001 → the row orphans). Dropping it on
  // every push keeps voids legal and a mixed insert/void batch homogeneous.
  group('append-only ledger created_at scrub', () {
    for (final table in const [
      'payment_transactions',
      'wallet_transactions',
      'supplier_ledger_entries',
    ]) {
      test('$table: created_at dropped, all other columns survive', () {
        final scrubbed = SupabaseSyncService.scrubForTesting(table, {
          'id': 'led-1',
          'business_id': 'biz',
          'amount_kobo': 5830000,
          'created_at': '2026-06-07T20:23:10.123456Z',
          // void columns are the only legitimate change on these tables
          'voided_at': '2026-06-07T20:25:00.000000Z',
          'voided_by': 'u1',
          'void_reason': 'order_cancelled',
          'last_updated_at': '2026-06-07T20:25:00.000000Z',
        });
        expect(scrubbed.containsKey('created_at'), isFalse,
            reason: 'created_at is immutable on cloud; re-push would orphan');
        // Everything else — keys, amount, and the mutable void columns — rides.
        expect(scrubbed['id'], 'led-1');
        expect(scrubbed['amount_kobo'], 5830000);
        expect(scrubbed['voided_at'], '2026-06-07T20:25:00.000000Z');
        expect(scrubbed['voided_by'], 'u1');
        expect(scrubbed['void_reason'], 'order_cancelled');
        expect(scrubbed['last_updated_at'], '2026-06-07T20:25:00.000000Z');
      });
    }

    test('stock_transactions: created_at NOT scrubbed (append-only, never '
        'full-row re-pushed → keeps event-time on cloud)', () {
      final scrubbed = SupabaseSyncService.scrubForTesting('stock_transactions', {
        'id': 'st-1',
        'business_id': 'biz',
        'created_at': '2026-06-07T20:23:10.123456Z',
      });
      expect(scrubbed['created_at'], '2026-06-07T20:23:10.123456Z',
          reason: 'stock voids append compensating rows, never re-push the '
              'original, so created_at is safe and intentionally preserved');
    });
  });
}
