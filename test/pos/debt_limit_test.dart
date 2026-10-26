// The Checkout debt-limit gate, with the Pay on delivery exception (#432).

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/shared/services/orders/debt_limit.dart';

void main() {
  DebtLimitResult check({
    required int balance,
    int paid = 0,
    int total = 100000,
    required int limit,
    bool pod = false,
  }) => checkDebtLimit(
    balanceKobo: balance,
    paidKobo: paid,
    totalKobo: total,
    limitKobo: limit,
    excludeOwnAmount: pod,
  );

  group('the usual rule', () {
    test('a fully paid sale is never gated', () {
      expect(check(balance: -999999, paid: 100000, limit: 0),
          isA<DebtLimitOk>());
    });
    test('new debt with no limit is refused', () {
      expect(check(balance: 0, limit: 0), isA<DebtLimitNotSet>());
    });
    test('new debt over the limit is refused by the amount over', () {
      final r = check(balance: -50000, limit: 120000);
      expect(r, isA<DebtLimitExceeded>());
      expect((r as DebtLimitExceeded).overByKobo, 30000);
    });
    test('new debt within the limit passes', () {
      expect(check(balance: 0, limit: 100000), isA<DebtLimitOk>());
    });
  });

  group('Pay on delivery leaves this order\'s own amount out', () {
    test('a new customer with no limit can be served', () {
      expect(check(balance: 0, limit: 0, pod: true), isA<DebtLimitOk>());
    });
    test('a customer holding credit can be served', () {
      expect(check(balance: 5000, limit: 0, pod: true), isA<DebtLimitOk>());
    });
    test('prior debt within the limit passes even if this order breaks it', () {
      expect(check(balance: -90000, limit: 100000, pod: true),
          isA<DebtLimitOk>());
    });
    test('prior debt over the limit still blocks', () {
      final r = check(balance: -150000, limit: 100000, pod: true);
      expect(r, isA<DebtLimitExceeded>());
      expect((r as DebtLimitExceeded).overByKobo, 50000);
    });
    test('prior debt with no limit set still blocks', () {
      expect(check(balance: -1, limit: 0, pod: true), isA<DebtLimitNotSet>());
    });
  });
}
