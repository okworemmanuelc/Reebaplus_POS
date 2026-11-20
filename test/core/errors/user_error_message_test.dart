import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/errors/user_error_message.dart';

void main() {
  const hint =
      '{"product_id":"p-1","store_id":"s-1","requested_qty":20,"available_qty":12}';
  const raw =
      'SaleSyncException(orderId=01a1f954-3d53-73bb-8060-661874942351); '
      'pg_P0001: insufficient_stock hint=$hint';

  test('stock rejection names the product with quantities', () {
    final m = userErrorMessage(
      Exception(raw),
      productName: (id) => id == 'p-1' ? 'Trophy Lager' : null,
    );
    expect(m, contains('Not enough stock for Trophy Lager'));
    expect(m, contains('cart has 20, only 12 left'));
    expect(m, contains('refresh'));
  });

  test('stock rejection without name or hint stays plain', () {
    expect(
      userErrorMessage('pg_P0001: insufficient_stock'),
      startsWith('Not enough stock for one of the items.'),
    );
    expect(
      userErrorMessage(raw, productName: (_) => null),
      contains('one of the items (cart has 20'),
    );
  });

  test('postgrest style hint: is parsed too', () {
    final m = userErrorMessage(
      'PostgrestException(message: insufficient_stock, code: P0001, hint: $hint)',
      productName: (_) => 'Hero',
    );
    expect(m, contains('Hero'));
  });

  final cases = <String, String>{
    'inventory_row_missing': 'not stocked',
    'insufficient_wallet_balance': 'wallet',
    'customer_wallet_missing': 'wallet is not set up',
    'debt_limit_exceeded': 'credit limit',
    'pg_23505: duplicate key value': 'already been saved',
    'pg_23503: foreign key': 'missing or was removed',
    'permission_denied: sales.make': 'permission',
    'code: 42501': 'permission',
    'insufficient_privilege': 'permission',
    'tenant_mismatch': 'does not belong',
    'JWT expired': 'session has expired',
    'cannot_cancel_status_completed': 'already been dealt with',
  };
  cases.forEach((input, expected) {
    test('maps $input', () {
      expect(userErrorMessage(Exception(input)), contains(expected));
    });
  });

  test('network failures', () {
    for (final e in [
      const SocketException('x'),
      TimeoutException('t'),
      Exception('Failed host lookup: foo'),
      Exception('ClientException: oops'),
    ]) {
      expect(userErrorMessage(e), contains('no internet'));
    }
  });

  test('unknown errors get the generic message, no technical text', () {
    final m = userErrorMessage(
      Exception('StateError pg_XX000 01a1f954-3d53-73bb-8060-661874942351'),
      action: 'completing the sale',
    );
    expect(m, startsWith('Something went wrong while completing the sale.'));
    expect(m, contains('contact support'));
  });

  test('no output leaks jargon', () {
    final outs = [
      userErrorMessage(Exception(raw), productName: (_) => 'X'),
      userErrorMessage(Exception('weird pg_P0001 boom')),
      userErrorMessage(Exception('tenant_mismatch')),
    ];
    for (final m in outs) {
      expect(m, isNot(contains('Exception')));
      expect(m, isNot(contains('pg_')));
      expect(
        m,
        isNot(
          matches(
            RegExp(
              r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
            ),
          ),
        ),
      );
    }
  });
}
