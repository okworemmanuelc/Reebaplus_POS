// Home quick-actions resolver (#362 PRs 1–2, PRD #270 "Which tiles show"):
// the default role table for Add Expense, Stock Transfer, Receive Stock and
// Take Stock, the store-count rule (vans excluded by the caller), the fixed
// order, single-key revocation and "nothing visible → empty".

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/permissions/permissions.dart';
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

QuickActions _resolve(int rank, Set<String> keys, {int storeCount = 2}) {
  final ctx = GateContext(grantedKeys: keys, roleRank: rank, isReady: true);
  return resolveQuickActions((g) => g.evaluate(ctx), storeCount: storeCount);
}

void main() {
  group('default role table, two stores (PRD #270)', () {
    const expected = <String, List<QuickAction>>{
      'CEO': [
        QuickAction.addExpense,
        QuickAction.stockTransfer,
        QuickAction.receiveStock,
        QuickAction.takeStock,
      ],
      'Manager': [
        QuickAction.addExpense,
        QuickAction.stockTransfer,
        QuickAction.receiveStock,
        QuickAction.takeStock,
      ],
      'Cashier': [],
      'Stock keeper': [QuickAction.receiveStock, QuickAction.takeStock],
    };
    expected.forEach((role, tiles) {
      test(role, () {
        final (rank, keys) = _grants[role]!;
        expect(_resolve(rank, keys).tiles, tiles);
      });
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
    test('one store: the other three tiles are unaffected', () {
      expect(_resolve(rank, keys, storeCount: 1).tiles, [
        QuickAction.addExpense,
        QuickAction.receiveStock,
        QuickAction.takeStock,
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

  test('the order is fixed: Add Expense, Stock Transfer, Receive Stock, '
      'Take Stock', () {
    expect(QuickAction.values, [
      QuickAction.addExpense,
      QuickAction.stockTransfer,
      QuickAction.receiveStock,
      QuickAction.takeStock,
    ]);
    final all = resolveQuickActions((_) => true, storeCount: 2);
    expect(all.tiles, QuickAction.values);
  });

  test('nothing allowed → no tiles and no payment sides', () {
    final none = resolveQuickActions((_) => false, storeCount: 2);
    expect(none.tiles, isEmpty);
    expect(none.paymentSides, isEmpty);
  });

  group('revoking one key hides exactly its tile', () {
    final (rank, keys) = _grants['Manager']!;
    test('expenses.create → no Add Expense', () {
      expect(_resolve(rank, {...keys}..remove('expenses.create')).tiles, [
        QuickAction.stockTransfer,
        QuickAction.receiveStock,
        QuickAction.takeStock,
      ]);
    });
    test('stock.adjust → no Take Stock', () {
      expect(_resolve(rank, {...keys}..remove('stock.adjust')).tiles, [
        QuickAction.addExpense,
        QuickAction.stockTransfer,
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
        ],
      );
    });
  });

  test('a cashier given stock.adjust still gets no Take Stock (tier rule)', () {
    final (rank, keys) = _grants['Cashier']!;
    expect(_resolve(rank, {...keys, 'stock.adjust'}).tiles, isEmpty);
  });

  test('permissions not resolved yet → no tiles', () {
    const ctx = GateContext(grantedKeys: {}, roleRank: null, isReady: false);
    expect(
      resolveQuickActions((g) => g.evaluate(ctx), storeCount: 2).tiles,
      isEmpty,
    );
  });
}
