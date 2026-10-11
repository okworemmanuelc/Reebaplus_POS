// Home quick-actions resolver (#362 PRs 1–4, PRD #270 "Which tiles show"):
// the default role table for all five tiles and the Record Payment sides, the
// store-count rule (vans excluded by the caller), the customer / supplier
// count rules (walk-in excluded by the caller), the fixed order, single-key
// revocation and "nothing visible → empty".

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/dashboard/quick_actions.dart';

// The seeded default grants for the keys these tiles read (see
// test/database/roles_v13_seed_test.dart; `stores.request_transfer` is CEO +
// Manager by default, cloud 0122).
const _grants = <String, (int, Set<String>)>{
  'CEO': (
    GateTier.ceo,
    {
      'stores.request_transfer',
      'products.add',
      'stock.add',
      'stock.view',
      'stock.adjust',
      'expenses.create',
      'customers.wallet.update',
      'suppliers.manage',
    },
  ),
  'Manager': (
    GateTier.manager,
    {
      'stores.request_transfer',
      'products.add',
      'stock.add',
      'stock.view',
      'stock.adjust',
      'expenses.create',
      'customers.wallet.update',
    },
  ),
  'Cashier': (
    GateTier.cashier,
    {
      'sales.make',
      'stock.view',
      'reports.see_sales',
      'customers.wallet.update',
    },
  ),
  'Stock keeper': (
    GateTier.stockKeeper,
    {'stock.add', 'stock.view', 'stock.adjust'},
  ),
};

QuickActions _resolve(
  int rank,
  Set<String> keys, {
  int storeCount = 2,
  int customerCount = 1,
  int supplierCount = 1,
}) {
  final ctx = GateContext(grantedKeys: keys, roleRank: rank, isReady: true);
  return resolveQuickActions(
    (g) => g.evaluate(ctx),
    storeCount: storeCount,
    customerCount: customerCount,
    supplierCount: supplierCount,
  );
}

QuickActions _all(bool allowed) => resolveQuickActions(
  (_) => allowed,
  storeCount: 2,
  customerCount: 1,
  supplierCount: 1,
);

void main() {
  group('default role table, two stores, a customer and a supplier '
      '(PRD #270)', () {
    const expected = <String, (List<QuickAction>, List<PaymentSide>)>{
      'CEO': (
        [
          QuickAction.addExpense,
          QuickAction.stockTransfer,
          QuickAction.takeStock,
          QuickAction.recordPayment,
          QuickAction.receiveStock,
        ],
        [PaymentSide.customer, PaymentSide.supplier],
      ),
      'Manager': (
        [
          QuickAction.addExpense,
          QuickAction.stockTransfer,
          QuickAction.takeStock,
          QuickAction.recordPayment,
          QuickAction.receiveStock,
        ],
        [PaymentSide.customer],
      ),
      'Cashier': ([QuickAction.recordPayment], [PaymentSide.customer]),
      'Stock keeper': ([QuickAction.takeStock, QuickAction.receiveStock], []),
    };
    expected.forEach((role, want) {
      test(role, () {
        final (rank, keys) = _grants[role]!;
        final got = _resolve(rank, keys);
        expect(got.tiles, want.$1);
        expect(got.paymentSides, want.$2);
      });
    });
  });

  group('Record Payment sides need someone to pay or be paid', () {
    final (rank, keys) = _grants['CEO']!;
    test('no customers → supplier side only, tile stays', () {
      final got = _resolve(rank, keys, customerCount: 0);
      expect(got.paymentSides, [PaymentSide.supplier]);
      expect(got.tiles, contains(QuickAction.recordPayment));
    });
    test('no suppliers → customer side only, tile stays', () {
      final got = _resolve(rank, keys, supplierCount: 0);
      expect(got.paymentSides, [PaymentSide.customer]);
      expect(got.tiles, contains(QuickAction.recordPayment));
    });
    test('neither → no sides and no tile', () {
      final got = _resolve(rank, keys, customerCount: 0, supplierCount: 0);
      expect(got.paymentSides, isEmpty);
      expect(got.tiles, isNot(contains(QuickAction.recordPayment)));
    });
    test('a cashier with no customers gets no tile at all', () {
      final (cRank, cKeys) = _grants['Cashier']!;
      expect(_resolve(cRank, cKeys, customerCount: 0).tiles, isEmpty);
    });
    test('revoking customers.wallet.update drops the customer side', () {
      expect(
        _resolve(
          rank,
          {...keys}..remove('customers.wallet.update'),
        ).paymentSides,
        [PaymentSide.supplier],
      );
    });
    test('revoking suppliers.manage drops the supplier side', () {
      expect(
        _resolve(rank, {...keys}..remove('suppliers.manage')).paymentSides,
        [PaymentSide.customer],
      );
    });
    test('a supplier side without the key, even with suppliers, is absent', () {
      final (mRank, mKeys) = _grants['Manager']!;
      expect(_resolve(mRank, mKeys, supplierCount: 5).paymentSides, [
        PaymentSide.customer,
      ]);
    });
  });

  group('Stock Transfer needs two or more (non-van) stores', () {
    final (rank, keys) = _grants['CEO']!;
    for (final (count, shown) in const [
      (0, false),
      (1, false),
      (2, true),
      (3, true),
    ]) {
      test('$count store(s) → ${shown ? 'tile' : 'no tile'}', () {
        expect(
          _resolve(
            rank,
            keys,
            storeCount: count,
          ).tiles.contains(QuickAction.stockTransfer),
          shown,
        );
      });
    }
    test('one store: the other tiles are unaffected', () {
      expect(_resolve(rank, keys, storeCount: 1).tiles, [
        QuickAction.addExpense,
        QuickAction.takeStock,
        QuickAction.recordPayment,
        QuickAction.receiveStock,
      ]);
    });
    test('revoking stores.request_transfer hides it with two stores', () {
      expect(
        _resolve(
          rank,
          {...keys}..remove('stores.request_transfer'),
        ).tiles.contains(QuickAction.stockTransfer),
        isFalse,
      );
    });
  });

  test('the order is fixed: Add Expense, Stock Transfer, Take Stock, '
      'Record Payment, Receive Stock (Receive Stock always last)', () {
    expect(QuickAction.values, [
      QuickAction.addExpense,
      QuickAction.stockTransfer,
      QuickAction.takeStock,
      QuickAction.recordPayment,
      QuickAction.receiveStock,
    ]);
    final all = _all(true);
    expect(all.tiles, QuickAction.values);
    expect(all.paymentSides, [PaymentSide.customer, PaymentSide.supplier]);
  });

  test('nothing allowed → no tiles and no payment sides', () {
    final none = _all(false);
    expect(none.tiles, isEmpty);
    expect(none.paymentSides, isEmpty);
  });

  group('revoking one key hides exactly its tile', () {
    final (rank, keys) = _grants['Manager']!;
    test('expenses.create → no Add Expense', () {
      expect(_resolve(rank, {...keys}..remove('expenses.create')).tiles, [
        QuickAction.stockTransfer,
        QuickAction.takeStock,
        QuickAction.recordPayment,
        QuickAction.receiveStock,
      ]);
    });
    test('stock.adjust → no Take Stock', () {
      expect(_resolve(rank, {...keys}..remove('stock.adjust')).tiles, [
        QuickAction.addExpense,
        QuickAction.stockTransfer,
        QuickAction.recordPayment,
        QuickAction.receiveStock,
      ]);
    });
    test('stock.add + products.add → no Receive Stock', () {
      expect(
        _resolve(
          rank,
          {...keys}
            ..remove('stock.add')
            ..remove('products.add'),
        ).tiles,
        [
          QuickAction.addExpense,
          QuickAction.stockTransfer,
          QuickAction.takeStock,
          QuickAction.recordPayment,
        ],
      );
    });
    test('customers.wallet.update → no Record Payment', () {
      expect(
        _resolve(rank, {...keys}..remove('customers.wallet.update')).tiles,
        [
          QuickAction.addExpense,
          QuickAction.stockTransfer,
          QuickAction.takeStock,
          QuickAction.receiveStock,
        ],
      );
    });
  });

  test('a cashier given stock.adjust still gets no Take Stock (tier rule)', () {
    final (rank, keys) = _grants['Cashier']!;
    expect(_resolve(rank, {...keys, 'stock.adjust'}).tiles, [
      QuickAction.recordPayment,
    ]);
  });

  test('permissions not resolved yet → no tiles', () {
    const ctx = GateContext(grantedKeys: {}, roleRank: null, isReady: false);
    expect(
      resolveQuickActions(
        (g) => g.evaluate(ctx),
        storeCount: 2,
        customerCount: 1,
        supplierCount: 1,
      ).tiles,
      isEmpty,
    );
  });

  group('registered customers (the picker\'s list)', () {
    Customer named(String id) => Customer(
      id: id,
      name: 'Customer $id',
      addressText: 'N/A',
      googleMapsLocation: 'N/A',
      createdAt: DateTime(2026, 10, 1),
    );
    test('the walk-in alone counts as no customers', () {
      expect(registeredCustomerCount([Customer.walkIn()]), 0);
      final (rank, keys) = _grants['Cashier']!;
      expect(
        _resolve(
          rank,
          keys,
          customerCount: registeredCustomerCount([Customer.walkIn()]),
        ).tiles,
        isEmpty,
      );
    });
    test('everyone but the walk-in counts', () {
      expect(
        registeredCustomerCount([Customer.walkIn(), named('a'), named('b')]),
        2,
      );
    });
  });
}
