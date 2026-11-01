import 'package:flutter_test/flutter_test.dart';

import '../../../tool/legacy_import/src/config.dart';
import '../../../tool/legacy_import/src/cost_rule.dart';
import '../../../tool/legacy_import/src/export_reader.dart';
import '../../../tool/legacy_import/src/ids.dart';
import '../../../tool/legacy_import/src/outputs.dart';
import '../../../tool/legacy_import/src/plan.dart';

const _ownerUid = '11111111-1111-4111-8111-111111111111';
const _supportUid = '22222222-2222-4222-8222-222222222222';
const _mainStore = 'store-main';
const _branch = 'store-branch';

Row _store(String id, {bool main = false}) => Row({
  'id': id,
  'name': 'Test $id',
  'isActive': true,
  'isMain': main,
  'createdAt': '2026-01-01T00:00:00.000Z',
});

Row _product(
  String id, {
  String? category,
  bool returnable = false,
  String? cost,
  String? drinkType,
}) => Row({
  'id': id,
  'sku': 'sku-$id',
  'name': 'Test Product $id',
  'unitPriceCents': '1000',
  'costCents': cost,
  'isActive': true,
  'categoryId': category,
  'supplierId': null,
  'isReturnable': returnable,
  'drinkType': drinkType,
  'createdAt': '2026-01-01T00:00:00.000Z',
});

Row _sale(
  String id, {
  required String total,
  required String paid,
  String? customer,
  String? cancelledAt,
  String store = _mainStore,
  String at = '2026-02-10T10:00:00.000Z',
}) => Row({
  'id': id,
  'customerId': customer,
  'totalCents': total,
  'amountPaidCents': paid,
  'storeId': store,
  'createdAt': at,
  'occurredAt': null,
  'createdByProfileId': 'profile-1',
  'cancelledAt': cancelledAt,
  'cancelReason': cancelledAt == null ? null : 'Mistake',
  'cancelledByProfileId': cancelledAt == null ? null : 'profile-1',
});

Row _line(
  String id,
  String sale,
  String product,
  String qty,
  String unit,
  String total,
) => Row({
  'id': id,
  'saleId': sale,
  'productId': product,
  'quantity': qty,
  'unitPriceCents': unit,
  'lineTotalCents': total,
  'standardUnitPriceCents': null,
});

Row _movement(
  String id,
  String type,
  String qty, {
  String product = 'p-glass',
  String? sale,
  String? transfer,
  String? delivery,
  String at = '2026-02-10T10:00:00.000Z',
  String store = _mainStore,
}) => Row({
  'id': id,
  'productId': product,
  'type': type,
  'quantityChange': qty,
  'relatedSaleId': sale,
  'note': null,
  'createdAt': at,
  'relatedVanTripId': null,
  'storeId': store,
  'createdByProfileId': 'profile-1',
  'relatedStoreTransferId': transfer,
  'relatedSupplyDeliveryId': delivery,
});

Row _customerEntry(String id, String type, String amount, {String? sale}) =>
    Row({
      'id': id,
      'customerId': 'c-1',
      'type': type,
      'amountCents': amount,
      'relatedSaleId': sale,
      'note': null,
      'createdAt': '2026-02-11T10:00:00.000Z',
      'createdByProfileId': 'profile-1',
      'cancelledAt': null,
      'cancelReason': null,
      'cancelledByProfileId': null,
    });

Row _supplier(String id, String store) => Row({
  'id': id,
  'name': 'Test Supplier',
  'storeId': store,
  'phone': store == _branch ? '000' : null,
  'createdAt': '2026-01-01T00:00:00.000Z',
});

Export _export() => Export(
  generatedAt: DateTime.utc(2026, 3, 1),
  tables: {
    'BusinessSettings': [
      const Row({'id': 'settings-1', 'phone': '000', 'email': null}),
    ],
    'Store': [_store(_mainStore, main: true), _store(_branch)],
    'Profile': [
      const Row({
        'id': 'profile-1',
        'email': 'Owner@Example.test',
        'name': 'Test Owner',
        'storeId': _mainStore,
      }),
    ],
    'Category': [
      const Row({
        'id': 'cat-company',
        'name': 'Test Company',
        'createdAt': '2026-01-01T00:00:00.000Z',
      }),
      const Row({
        'id': 'cat-type',
        'name': 'Test Type',
        'createdAt': '2026-01-01T00:00:00.000Z',
      }),
    ],
    'Product': [
      _product(
        'p-glass',
        category: 'cat-company',
        returnable: true,
        cost: '700',
        drinkType: 'Lager',
      ),
      _product('p-plain', category: 'cat-type'),
    ],
    'StoreStock': [
      const Row({
        'id': 'stock-1',
        'storeId': _mainStore,
        'productId': 'p-glass',
        'stockQty': '10.5',
        'lowStockThreshold': 7,
      }),
      const Row({
        'id': 'stock-2',
        'storeId': _branch,
        'productId': 'p-plain',
        'stockQty': '0',
        'lowStockThreshold': 5,
      }),
    ],
    'Customer': [
      const Row({
        'id': 'c-1',
        'name': 'Test Customer',
        'businessName': 'Test Shop',
        'storeId': _mainStore,
        'creditLimitCents': null,
        'createdAt': '2026-01-01T00:00:00.000Z',
      }),
    ],
    'Sale': [
      _sale('sale-paid-12345678', total: '500', paid: '500'),
      _sale(
        'sale-credit-1234567',
        total: '1000',
        paid: '0',
        customer: 'c-1',
        at: '2026-02-11T10:00:00.000Z',
      ),
      _sale(
        'sale-over-87654321',
        total: '1000',
        paid: '1200',
        customer: 'c-1',
        at: '2026-02-12T10:00:00.000Z',
      ),
      _sale(
        'sale-gone-11223344',
        total: '1000',
        paid: '1000',
        cancelledAt: '2026-02-13T10:00:00.000Z',
        at: '2026-02-13T09:00:00.000Z',
      ),
    ],
    'SaleItem': [
      _line('line-1', 'sale-paid-12345678', 'p-glass', '0.5', '1000', '500'),
      _line('line-2', 'sale-credit-1234567', 'p-glass', '1', '1000', '1000'),
      _line('line-3', 'sale-over-87654321', 'p-plain', '1', '1000', '1000'),
      _line('line-4', 'sale-gone-11223344', 'p-glass', '1', '1000', '1000'),
    ],
    'SupplyDelivery': [
      const Row({
        'id': 'delivery-1',
        'deliveryDate': '2026-02-11T08:00:00.000Z',
        'cancelledAt': null,
      }),
    ],
    'SupplyDeliveryItem': [
      const Row({
        'id': 'delivery-item-1',
        'supplyDeliveryId': 'delivery-1',
        'productId': 'p-glass',
        'buyingRateCents': '700',
      }),
    ],
    'Supplier': [
      _supplier('s-main', _mainStore),
      _supplier('s-branch', _branch),
    ],
    'SupplierLedgerEntry': [
      const Row({
        'id': 'sl-1',
        'supplierId': 's-branch',
        'type': 'DELIVERY_CREDIT',
        'amountCents': '9000',
        'relatedSupplyDeliveryId': 'delivery-1',
        'note': null,
        'createdAt': '2026-02-11T08:00:00.000Z',
        'createdByProfileId': 'profile-1',
      }),
      const Row({
        'id': 'sl-2',
        'supplierId': 's-main',
        'type': 'PAYMENT',
        'amountCents': '-4000',
        'relatedSupplyDeliveryId': null,
        'note': 'by Opay',
        'createdAt': '2026-02-12T08:00:00.000Z',
        'createdByProfileId': 'profile-1',
      }),
    ],
    'CustomerLedgerEntry': [
      _customerEntry(
        'cl-1',
        'SALE_CREDIT',
        '1000',
        sale: 'sale-credit-1234567',
      ),
      _customerEntry('cl-2', 'PAYMENT', '-300'),
      _customerEntry('cl-3', 'SALE_CREDIT', '-200', sale: 'sale-over-87654321'),
    ],
    'EmptiesLedgerEntry': [
      const Row({'customerId': 'c-1', 'productId': 'p-glass', 'quantity': '3'}),
      const Row({
        'customerId': 'c-1',
        'productId': 'p-glass',
        'quantity': '-0.5',
      }),
      const Row({'customerId': null, 'productId': 'p-glass', 'quantity': '1'}),
      const Row({'customerId': null, 'productId': 'p-glass', 'quantity': '-1'}),
    ],
    'EmptiesDepositEntry': [
      const Row({
        'id': 'dep-1',
        'customerId': 'c-1',
        'type': 'DEPOSITED',
        'amountCents': '6000',
        'createdAt': '2026-02-11T10:00:00.000Z',
        'createdByProfileId': 'profile-1',
      }),
    ],
    'StoreTransfer': [
      const Row({
        'id': 'transfer-1',
        'fromStoreId': _mainStore,
        'toStoreId': _branch,
        'status': 'RECEIVED',
        'dispatchedAt': '2026-02-09T10:00:00.000Z',
        'receivedAt': '2026-02-09T12:00:00.000Z',
        'dispatchedByProfileId': null,
        'receivedByProfileId': 'profile-1',
      }),
    ],
    'StoreTransferItem': [
      const Row({
        'id': 'transfer-item-1',
        'storeTransferId': 'transfer-1',
        'productId': 'p-plain',
        'quantitySent': '4',
      }),
    ],
    'StockMovement': [
      _movement('m-sale', 'SALE', '-0.5', sale: 'sale-paid-12345678'),
      _movement('m-split-a', 'SALE', '-0.7', sale: 'sale-credit-1234567'),
      _movement(
        'm-split-b',
        'ADJUSTMENT',
        '-0.3',
        sale: 'sale-credit-1234567',
        at: '2026-02-11T11:00:00.000Z',
      ),
      _movement('m-back', 'ADJUSTMENT', '1', sale: 'sale-gone-11223344'),
      _movement('m-restock', 'RESTOCK', '20', delivery: 'delivery-1'),
      _movement(
        'm-out',
        'TRANSFER_OUT',
        '-4',
        product: 'p-plain',
        transfer: 'transfer-1',
      ),
      _movement(
        'm-in',
        'TRANSFER_IN',
        '4',
        product: 'p-plain',
        transfer: 'transfer-1',
        store: _branch,
      ),
    ],
  },
);

ImportConfig _config({String ownerUid = _ownerUid}) => ImportConfig(
  businessId: legacyId('Business', 'settings-1'),
  businessName: 'Test Business',
  businessType: 'Beer distributor',
  businessPhone: null,
  businessEmail: null,
  ownerAuthUid: ownerUid,
  accounts: [
    Account(
      oldProfileId: 'profile-1',
      email: 'owner@example.test',
      authUid: ownerUid,
      name: null,
      role: 'ceo',
      hidden: false,
    ),
    const Account(
      oldProfileId: null,
      email: 'support@example.test',
      authUid: _supportUid,
      name: 'Test Support',
      role: 'ceo',
      hidden: true,
    ),
  ],
  productTypeCategories: const ['test type'],
);

ImportPlan _build() => Planner(export: _export(), config: _config()).build();

/// A row of [table] as `column → literal`, picked by id.
Map<String, String> _row(ImportPlan plan, String table, String id) {
  final target = plan.table(table);
  final idIndex = target.columns.indexOf('id');
  final row = target.rows.firstWhere((r) => r[idIndex] == "'$id'");
  return Map.fromIterables(target.columns, row);
}

void main() {
  group('Planner row counts', () {
    final plan = _build();

    test('one row per old row where the mapping is one to one', () {
      expect(plan.table('stores').rows, hasLength(2));
      expect(plan.table('products').rows, hasLength(2));
      expect(plan.table('customers').rows, hasLength(1));
      expect(plan.table('customer_wallets').rows, hasLength(1));
      expect(plan.table('orders').rows, hasLength(4));
      expect(plan.table('order_items').rows, hasLength(4));
      expect(plan.table('supplier_ledger_entries').rows, hasLength(2));
      expect(plan.table('stock_transfers').rows, hasLength(1));
    });

    test('same-name suppliers merge, keeping a detail only a copy held', () {
      expect(plan.table('suppliers').rows, hasLength(1));
      final supplier = _row(plan, 'suppliers', legacyId('Supplier', 's-main'));
      expect(supplier['phone'], "'000'");
    });

    test('the old mixed Category table splits in two', () {
      expect(plan.table('manufacturers').rows, hasLength(1));
      final names = plan.table('categories').rows.map((r) => r[2]);
      expect(names, containsAll(["'Lager'", "'Test Type'"]));
    });

    test('accounts become rows, the support login hidden and with no profile '
        'id from the old app', () {
      expect(plan.table('users').rows, hasLength(2));
      expect(plan.table('profiles').rows, hasLength(2));
      expect(plan.table('user_businesses').rows, hasLength(2));
      expect(plan.table('user_stores').rows, hasLength(4));
      final hidden = plan
          .table('user_businesses')
          .rows
          .where((row) => row[5] == 'true');
      expect(hidden, hasLength(1));
    });

    test('a role comes from the seeded roles of this business', () {
      final row = plan.table('user_businesses').rows.first;

      expect(row[3], contains("slug = 'ceo'"));
    });
  });

  group('Planner money', () {
    final plan = _build();

    test('customer balance is the old ledger with its sign flipped', () {
      expect(plan.customerBalanceKobo.values.single, -1000 + 300 + 200);
    });

    test('supplier balance survives the merge, sign flipped', () {
      expect(plan.supplierBalanceKobo.values.single, -9000 + 4000);
    });

    test('a supplier ledger row keeps its own branch', () {
      final row = _row(
        plan,
        'supplier_ledger_entries',
        legacyId('SupplierEntry', 'sl-1'),
      );

      expect(row['store_id'], "'${legacyId('Store', _branch)}'");
    });

    test('a payment noted as a transfer stays a transfer', () {
      final row = _row(
        plan,
        'supplier_ledger_entries',
        legacyId('SupplierEntry', 'sl-2'),
      );

      expect(row['reference_type'], "'payment_transfer'");
    });

    test('a held deposit does not flip and stays out of spendable balance', () {
      final row = _row(
        plan,
        'wallet_transactions',
        legacyId('DepositEntry', 'dep-1'),
      );

      expect(row['signed_amount_kobo'], '6000');
      expect(row['reference_type'], "'crate_deposit'");
      expect(plan.heldDepositKobo.values.single, 6000);
    });

    test('no credit limit means 0, which the app reads as unlimited', () {
      final row = _row(plan, 'customers', legacyId('Customer', 'c-1'));

      expect(row['wallet_limit_kobo'], '0');
      expect(row['name'], "'Test Customer (Test Shop)'");
    });

    test('cancelled sales add no cash and keep no paid amount', () {
      final order = _row(
        plan,
        'orders',
        legacyId('Sale', 'sale-gone-11223344'),
      );

      expect(order['status'], "'cancelled'");
      expect(order['amount_paid_kobo'], '0');
      expect(plan.table('order_reversals').rows, hasLength(1));
      final orderId = "'${legacyId('Sale', 'sale-gone-11223344')}'";
      final orderColumn = plan
          .table('payment_transactions')
          .columns
          .indexOf('order_id');
      expect(
        plan
            .table('payment_transactions')
            .rows
            .where((row) => row[orderColumn] == orderId),
        isEmpty,
      );
    });

    test('a customer payment writes a cash row linked to its wallet row', () {
      final cash = _row(
        plan,
        'payment_transactions',
        legacyId('WalletCash', 'cl-2'),
      );

      expect(cash['type'], "'wallet_topup'");
      expect(cash['method'], "'cash'");
      expect(cash['wallet_txn_id'], "'${legacyId('WalletEntry', 'cl-2')}'");
    });

    test('an overpaid sale splits its cash into goods and a top-up', () {
      final goods = _row(
        plan,
        'payment_transactions',
        legacyId('SalePaymentGoods', 'sale-over-87654321'),
      );
      final over = _row(
        plan,
        'payment_transactions',
        legacyId('SalePaymentOver', 'sale-over-87654321'),
      );

      expect(goods['amount_kobo'], '1000');
      expect(goods['type'], "'sale'");
      expect(over['amount_kobo'], '200');
      expect(over['type'], "'wallet_topup'");
    });

    test('daily figures count live sales only', () {
      expect(plan.days, hasLength(3));
      expect(plan.days['2026-02-13'], isNull);
      expect(plan.days['2026-02-12']!.cashKobo, 1200);
      expect(plan.cancelledSales, 1);
    });
  });

  group('Planner orders and costs', () {
    final plan = _build();

    test('order numbers keep the last 8 of the old id', () {
      final order = _row(
        plan,
        'orders',
        legacyId('Sale', 'sale-paid-12345678'),
      );

      expect(order['order_number'], "'OLD-12345678'");
    });

    test('a half crate is written as a plain literal', () {
      final line = _row(plan, 'order_items', legacyId('SaleItem', 'line-1'));

      expect(line['quantity'], '0.5');
      expect(line['total_kobo'], '500');
    });

    test('the cost rule fills every line', () {
      final beforeDelivery = _row(
        plan,
        'order_items',
        legacyId('SaleItem', 'line-1'),
      );
      final neverDelivered = _row(
        plan,
        'order_items',
        legacyId('SaleItem', 'line-3'),
      );

      expect(beforeDelivery['buying_price_kobo'], '700');
      expect(neverDelivered['buying_price_kobo'], '1000');
      expect(plan.zeroCostLines, 0);
    });

    test('groups count live lines only', () {
      expect(plan.costGroups[CostGroup.a]!.lines, 1);
      expect(plan.costGroups[CostGroup.b]!.lines, 1);
      expect(plan.costGroups[CostGroup.c]!.lines, 1);
    });
  });

  group('Planner stock', () {
    final plan = _build();

    test('stock is the old figure', () {
      final row = _row(plan, 'inventory', legacyId('Inventory', 'stock-1'));

      expect(row['quantity'], '10.5');
    });

    test('an opening layer holds all stock, dated at the cutover', () {
      final layer = _row(
        plan,
        'cost_batches',
        legacyId('OpeningLayer', 'stock-1'),
      );

      expect(layer['qty_remaining'], '10.5');
      expect(layer['qty_original'], '10.5');
      expect(layer['cost_kobo'], '700');
      expect(layer['received_at'], "'2026-03-01T00:00:00.000Z'");
    });

    test('no opening layer for an empty shelf', () {
      expect(
        () => _row(plan, 'cost_batches', legacyId('OpeningLayer', 'stock-2')),
        throwsStateError,
      );
    });

    test('history layers are already drawn, so live sales never see them', () {
      final target = plan.table('cost_batches');
      final remaining = target.columns.indexOf('qty_remaining');
      final received = target.columns.indexOf('received_at');
      final history = target.rows.where(
        (row) => row[received] != "'2026-03-01T00:00:00.000Z'",
      );

      expect(history, isNotEmpty);
      expect(history.every((row) => row[remaining] == '0'), isTrue);
    });

    test('split off-grid movements fold into one row', () {
      final merged = _row(
        plan,
        'stock_transactions',
        legacyId('StockMovement', 'm-split-a'),
      );

      expect(merged['quantity_delta'], '-1');
      expect(plan.table('stock_transactions').rows, hasLength(6));
    });

    test('a cancel reversal becomes a return on its order', () {
      final row = _row(
        plan,
        'stock_transactions',
        legacyId('StockMovement', 'm-back'),
      );

      expect(row['movement_type'], "'return'");
      expect(row['order_id'], "'${legacyId('Sale', 'sale-gone-11223344')}'");
      expect(row['adjustment_id'], 'NULL');
    });

    test('a restock uses the reason the receipt classifier knows', () {
      final row = _row(
        plan,
        'stock_adjustments',
        legacyId('Adjustment', 'm-restock'),
      );

      expect(row['reason'], "'Stock received'");
    });

    test('transfer legs point at their transfer row', () {
      final row = _row(
        plan,
        'stock_transactions',
        legacyId('StockMovement', 'm-out'),
      );

      expect(
        row['transfer_id'],
        "'${legacyId('Transfer', 'transfer-item-1')}'",
      );
      expect(row['order_id'], 'NULL');
    });

    test('a transfer with no dispatcher falls back to the owner', () {
      final row = _row(
        plan,
        'stock_transfers',
        legacyId('Transfer', 'transfer-item-1'),
      );

      expect(row['initiated_by'], "'${legacyId('User', 'profile-1')}'");
    });
  });

  group('Planner crates', () {
    final plan = _build();

    test('one opening balance per customer per company', () {
      expect(plan.table('crate_ledger').rows, hasLength(1));
      expect(plan.table('customer_crate_balances').rows, hasLength(1));
      expect(plan.crates.values.single, 2.5);
    });

    test('the opening row carries the agreed type and reason', () {
      final columns = plan.table('crate_ledger').columns;
      final row = plan.table('crate_ledger').rows.single;

      expect(row[columns.indexOf('quantity_delta')], '2.5');
      expect(row[columns.indexOf('movement_type')], "'adjusted'");
      expect(row[columns.indexOf('reason')], "'Opening balance from old app'");
    });

    test('walk-in empties are dropped', () {
      final walkIn = plan.notes.firstWhere((note) => note.contains('walk-in'));

      expect(walkIn, contains('net to 0.0'));
    });
  });

  group('determinism', () {
    test('two builds write the same SQL byte for byte', () {
      final first = buildImportSql(plan: _build(), config: _config());
      final second = buildImportSql(plan: _build(), config: _config());

      expect(first, second);
    });
  });

  group('safety against the export', () {
    test('refuses files that differ from the manifest', () {
      final export = Export(
        generatedAt: DateTime.utc(2026, 3, 1),
        tables: const {'Store': []},
        manifestRows: const {'Store': 2},
      );

      expect(
        () => Planner(export: export, config: _config()).build(),
        throwsStateError,
      );
    });

    test('refuses an owner who is not in the accounts', () {
      expect(
        () => ImportConfig(
          businessId: 'b',
          businessName: 'n',
          businessType: 't',
          businessPhone: null,
          businessEmail: null,
          ownerAuthUid: _ownerUid,
          accounts: const [
            Account(
              oldProfileId: null,
              email: 'other@example.test',
              authUid: _supportUid,
              name: null,
              role: 'ceo',
              hidden: false,
            ),
          ],
          productTypeCategories: const [],
        ),
        throwsFormatException,
      );
    });

    test('rejects an unknown role', () {
      expect(
        () => Account.fromJson(const {
          'email': 'a@example.test',
          'authUid': _ownerUid,
          'role': 'boss',
        }),
        throwsFormatException,
      );
    });
  });

  group('import.sql', () {
    final sql = buildImportSql(plan: _build(), config: _config());

    int at(String text) {
      final index = sql.indexOf(text);
      expect(index, isNot(-1), reason: 'missing: $text');
      return index;
    }

    test('is one transaction', () {
      expect(sql.split(RegExp(r'^BEGIN;$', multiLine: true)), hasLength(2));
      expect(sql.trimRight(), endsWith('COMMIT;'));
    });

    test('every insert is safe to run twice', () {
      final inserts = RegExp(r'^INSERT INTO', multiLine: true).allMatches(sql);
      final conflicts = RegExp(
        r'^ON CONFLICT .*;$',
        multiLine: true,
      ).allMatches(sql);

      expect(conflicts.length, inserts.length);
    });

    test('roles are seeded once, through the onboarding function', () {
      expect(
        at('public.seed_default_roles_for_business'),
        greaterThan(at('IF NOT EXISTS (SELECT 1 FROM public.roles')),
      );
    });

    test('Premium goes in before any store or staff row', () {
      final business = at('INSERT INTO public.businesses');

      expect(sql, contains("'active', 'premium', NULL"));
      expect(business, lessThan(at('INSERT INTO public.stores')));
      expect(business, lessThan(at('INSERT INTO public.user_businesses')));
    });

    test('roles are seeded before staff need them', () {
      expect(
        at('PERFORM public.seed_default_roles_for_business'),
        lessThan(at('INSERT INTO public.user_businesses')),
      );
    });

    test('plan-limit rows load with triggers on, history with them off', () {
      final off = at('SET LOCAL session_replication_role = replica');

      expect(at('INSERT INTO public.user_businesses'), lessThan(off));
      expect(at('INSERT INTO public.stores'), lessThan(off));
      expect(at('INSERT INTO public.orders'), greaterThan(off));
      expect(at('INSERT INTO public.wallet_transactions'), greaterThan(off));
    });

    test('triggers return, and orphans abort, before the commit', () {
      final origin = at('SET LOCAL session_replication_role = origin');

      expect(origin, greaterThan(at('INSERT INTO public.crate_ledger')));
      expect(at('orphan rows in order_items.order_id'), greaterThan(origin));
      expect(
        at('orphan rows in order_items.order_id'),
        lessThan(at('COMMIT;')),
      );
    });

    test('refuses to run before the quantity migration', () {
      expect(sql, contains('apply the #627 migration first'));
      expect(sql, contains("('order_items', 'quantity')"));
      expect(at('apply the #627 migration'), lessThan(at('INSERT INTO')));
    });

    test('refuses a login already tied to another business', () {
      expect(at('already belongs to another business'), lessThan(at('INSERT')));
    });

    test('runs as written with real accounts', () {
      expect(sql, isNot(contains('placeholder accounts')));
    });

    test('a file built with placeholder accounts cannot run', () {
      const placeholder = '00000000-0000-0000-0000-000000000001';
      final config = _config(ownerUid: placeholder);
      final plan = Planner(export: _export(), config: config).build();

      final guarded = buildImportSql(plan: plan, config: config);

      expect(guarded, contains('placeholder accounts'));
      expect(
        guarded.indexOf('RAISE EXCEPTION'),
        lessThan(guarded.indexOf('INSERT INTO')),
      );
    });

    test('escapes quotes in text', () {
      final export = _export();
      final plan = Planner(
        export: Export(
          generatedAt: export.generatedAt,
          tables: {
            for (final table in kImportedOldTables)
              table: table == 'Store'
                  ? [
                      const Row({
                        'id': _mainStore,
                        'name': "Test's Store",
                        'isActive': true,
                        'isMain': true,
                        'createdAt': '2026-01-01T00:00:00.000Z',
                      }),
                      _store(_branch),
                    ]
                  : export.rows(table),
          },
        ),
        config: _config(),
      ).build();

      expect(
        buildImportSql(plan: plan, config: _config()),
        contains("'Test''s Store'"),
      );
    });
  });

  group('checks.sql', () {
    final sql = buildChecksSql(plan: _build(), config: _config());

    test('cannot write', () {
      expect(sql, contains('BEGIN TRANSACTION READ ONLY;'));
      expect(sql.trimRight(), endsWith('ROLLBACK;'));
      expect(sql, isNot(contains('INSERT ')));
      expect(sql, isNot(contains('UPDATE ')));
      expect(sql, isNot(contains('DELETE ')));
    });

    test('covers every check the issue lists', () {
      for (final check in [
        'rows: orders',
        'each customer balance',
        'each supplier balance',
        'each held deposit',
        'stock per store per product',
        'live sales count per day',
        'takings per day',
        'cancelled sales add no money',
        'crate balance per customer per company',
        'past lines at zero cost',
      ]) {
        expect(sql, contains(check));
      }
    });

    test('proves the re-cost cannot move history', () {
      expect(sql, contains('a FIFO replay changes no past line cost'));
      expect(sql, contains('public.fifo_assign('));
      expect(sql, contains('opening layers equal stock on hand'));
    });

    test('rechecks foreign keys, which replica mode skipped', () {
      expect(sql, contains('no orphans: order_items.order_id'));
    });

    test('balances exclude the held-deposit family, as the app does', () {
      expect(sql, contains("reference_type NOT IN ('crate_deposit'"));
    });

    test('ends with one overall verdict', () {
      expect(sql, contains('ALL CHECKS (failures)'));
    });
  });

  group('report.md', () {
    final report = buildReport(
      plan: _build(),
      config: _config(),
      manifestRows: const {'Sale': 4},
    );

    test('lists row counts, cost groups and what was left out', () {
      expect(report, contains('| orders | 4 |'));
      expect(report, contains('| Sale | 4 |'));
      expect(report, contains('## Live sale lines by cost group'));
      expect(report, contains('## Left out or changed'));
    });

    test('shows money in naira with separators', () {
      expect(report, contains('Held deposits: N60.00'));
    });
  });
}
