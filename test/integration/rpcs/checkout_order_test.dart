@Tags(['integration'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../../helpers/supabase_test_clients.dart';
import '../../helpers/supabase_test_env.dart';

/// Tier-2 tests for the web-specific server guards of `checkout_order`
/// (migration 0135, Web POS Slice 2 / issue #43) — the acceptance criteria the
/// happy-path Golden-Scenario Suite (checkout_order_golden_test) doesn't cover:
///
///   * the sale is REJECTED when live stock is insufficient at commit (two
///     concurrent tills can't oversell);
///   * the server-minted order number matches `^WEB-…` and can NEVER collide
///     with a mobile device-tag number (`^ORD-…`);
///   * the checkout is idempotent on the order id (a replay applies nothing new);
///   * an order-level discount within the caller's role cap is honored, and the
///     sale settles at `pending` (revenue recognized at checkout).
///
/// Hits real dev Supabase; auto-skipped when env vars are absent. Assumes the
/// test user is the CEO of TEST_BUSINESS_ID (100% discount cap, sales.make).
final String? _skipReason = (() {
  try {
    TestEnv.load();
    return null;
  } on StateError catch (e) {
    return e.message;
  }
})();

void main() {
  late TestClients clients;
  late String businessId;
  late String storeId;

  final productIds = <String>[];
  final inventoryIds = <String>[];
  final batchIds = <String>[];
  final orderIds = <String>[];
  final customerIds = <String>[];
  final walletIds = <String>[];

  setUpAll(() async {
    if (_skipReason != null) return;
    clients = await TestClients.setUp();
    businessId = clients.env.businessId;
    storeId = UuidV7.generate();
    await clients.adminClient.from('stores').insert({
      'id': storeId,
      'business_id': businessId,
      'name': 'Checkout Guard Store',
    });
  });

  tearDown(() async {
    if (_skipReason != null) return;
    for (final id in customerIds) {
      await clients.adminClient.from('wallet_transactions').delete().eq('customer_id', id);
    }
    for (final id in orderIds) {
      await clients.adminClient.from('stock_transactions').delete().eq('order_id', id);
      await clients.adminClient.from('payment_transactions').delete().eq('order_id', id);
      await clients.adminClient.from('orders').delete().eq('id', id);
    }
    for (final id in walletIds) {
      await clients.adminClient.from('customer_wallets').delete().eq('id', id);
    }
    for (final id in customerIds) {
      await clients.adminClient.from('customers').delete().eq('id', id);
    }
    for (final id in batchIds) {
      await clients.adminClient.from('cost_batches').delete().eq('id', id);
    }
    for (final id in inventoryIds) {
      await clients.adminClient.from('inventory').delete().eq('id', id);
    }
    for (final id in productIds) {
      await clients.adminClient.from('products').delete().eq('id', id);
    }
    orderIds.clear();
    batchIds.clear();
    inventoryIds.clear();
    productIds.clear();
    customerIds.clear();
    walletIds.clear();
  });

  tearDownAll(() async {
    if (_skipReason != null) return;
    await clients.adminClient.from('stores').delete().eq('id', storeId);
    await clients.dispose();
  });

  Future<String> seedProduct({int scalarCostKobo = 50000}) async {
    final id = UuidV7.generate();
    await clients.adminClient.from('products').insert({
      'id': id,
      'business_id': businessId,
      'name': 'Guard Product',
      'retailer_price_kobo': 100000,
      'buying_price_kobo': scalarCostKobo,
    });
    productIds.add(id);
    return id;
  }

  // A registered customer + wallet with a debt limit and an optional opening
  // balance (seeded as one topup_cash credit).
  Future<String> seedCustomer({
    int debtLimitKobo = 0,
    int openingBalanceKobo = 0,
  }) async {
    final customerId = UuidV7.generate();
    final walletId = UuidV7.generate();
    customerIds.add(customerId);
    walletIds.add(walletId);
    await clients.adminClient.from('customers').insert({
      'id': customerId,
      'business_id': businessId,
      'name': 'Guard Customer',
      'wallet_limit_kobo': debtLimitKobo,
    });
    await clients.adminClient.from('customer_wallets').insert({
      'id': walletId,
      'business_id': businessId,
      'customer_id': customerId,
    });
    if (openingBalanceKobo != 0) {
      await clients.adminClient.from('wallet_transactions').insert({
        'id': UuidV7.generate(),
        'business_id': businessId,
        'wallet_id': walletId,
        'customer_id': customerId,
        'type': 'credit',
        'amount_kobo': openingBalanceKobo,
        'signed_amount_kobo': openingBalanceKobo,
        'reference_type': 'topup_cash',
      });
    }
    return customerId;
  }

  // The customer's derived spendable balance (SUM(signed) excluding deposits).
  Future<int> balanceOf(String customerId) async {
    const crateRefs = {
      'crate_deposit',
      'crate_deposit_refunded',
      'crate_deposit_forfeited',
    };
    final rows = await clients.adminClient
        .from('wallet_transactions')
        .select('reference_type, signed_amount_kobo')
        .eq('customer_id', customerId);
    return rows
        .where((r) => !crateRefs.contains(r['reference_type']))
        .fold<int>(0, (s, r) => s + (r['signed_amount_kobo'] as num).toInt());
  }

  Future<void> seedInventory(String productId, int qty) async {
    final id = UuidV7.generate();
    await clients.adminClient.from('inventory').insert({
      'id': id,
      'business_id': businessId,
      'product_id': productId,
      'store_id': storeId,
      'quantity': qty,
    });
    inventoryIds.add(id);
  }

  Future<void> seedBatch(String productId, int qty, int costKobo) async {
    final id = UuidV7.generate();
    await clients.adminClient.from('cost_batches').insert({
      'id': id,
      'business_id': businessId,
      'product_id': productId,
      'store_id': storeId,
      'qty_remaining': qty,
      'qty_original': qty,
      'cost_kobo': costKobo,
      'received_at': DateTime.utc(2026, 1, 1).toIso8601String(),
    });
    batchIds.add(id);
  }

  Future<Map<String, dynamic>> checkout({
    required String orderId,
    required String productId,
    required int quantity,
    int unitPriceKobo = 100000,
    String method = 'cash',
    int? amountPaidKobo,
    int discountKobo = 0,
    String? customerId,
  }) async {
    orderIds.add(orderId);
    final res = await clients.userClient.rpc('checkout_order', params: {
      'p_business_id': businessId,
      'p_order_id': orderId,
      'p_store_id': storeId,
      'p_items': [
        {'product_id': productId, 'quantity': quantity, 'unit_price_kobo': unitPriceKobo}
      ],
      'p_payment_method': method,
      'p_amount_paid_kobo': amountPaidKobo ?? quantity * unitPriceKobo - discountKobo,
      'p_discount_kobo': discountKobo,
      'p_customer_id': customerId,
    });
    return (res as Map).cast<String, dynamic>();
  }

  Future<int> onHand(String productId) async {
    final row = await clients.adminClient
        .from('inventory')
        .select('quantity')
        .eq('product_id', productId)
        .eq('store_id', storeId)
        .single();
    return (row['quantity'] as num).toInt();
  }

  test('cash sale settles at pending with a WEB- order number, never ORD-', () async {
    final product = await seedProduct();
    await seedInventory(product, 10);
    await seedBatch(product, 10, 50000);

    final res = await checkout(
        orderId: UuidV7.generate(), productId: product, quantity: 3);
    final order = res['order'] as Map;

    expect(order['status'], 'pending',
        reason: 'revenue recognized at checkout, not at confirm');
    expect(order['completed_at'], isNull);
    expect(order['order_number'], matches(RegExp(r'^WEB-\d{6}-[0-9A-F]{6}$')));
    expect(order['order_number'], isNot(startsWith('ORD-')),
        reason: 'must not collide with the mobile device-tag scheme');
    expect(res['replayed'], false);
    expect(await onHand(product), 7, reason: '3 units left the shelf');
  }, skip: _skipReason);

  test('rejects when live stock is insufficient — no partial write', () async {
    final product = await seedProduct();
    await seedInventory(product, 2); // only 2 on hand
    await seedBatch(product, 2, 50000);

    final orderId = UuidV7.generate();
    await expectLater(
      () => checkout(orderId: orderId, productId: product, quantity: 5),
      throwsA(anything),
      reason: 'selling 5 against 2 must be rejected at commit',
    );

    // All-or-nothing: the order never landed and stock is untouched.
    final order = await clients.adminClient
        .from('orders')
        .select('id')
        .eq('id', orderId)
        .maybeSingle();
    expect(order, isNull);
    expect(await onHand(product), 2);
  }, skip: _skipReason);

  test('two tills cannot oversell the last units (the concurrency guard)', () async {
    final product = await seedProduct();
    await seedInventory(product, 1); // a single unit left
    await seedBatch(product, 1, 50000);

    // First till takes the unit.
    await checkout(orderId: UuidV7.generate(), productId: product, quantity: 1);
    expect(await onHand(product), 0);

    // Second till's checkout for the same unit is rejected.
    await expectLater(
      () => checkout(orderId: UuidV7.generate(), productId: product, quantity: 1),
      throwsA(anything),
    );
    expect(await onHand(product), 0, reason: 'never oversold');
  }, skip: _skipReason);

  test('idempotent replay: same order id twice applies nothing new', () async {
    final product = await seedProduct();
    await seedInventory(product, 10);
    await seedBatch(product, 10, 50000);
    final orderId = UuidV7.generate();

    final first = await checkout(orderId: orderId, productId: product, quantity: 3);
    expect(first['replayed'], false);
    expect(await onHand(product), 7);

    final second = await checkout(orderId: orderId, productId: product, quantity: 3);
    expect(second['replayed'], true);
    expect((second['order'] as Map)['order_number'],
        (first['order'] as Map)['order_number']);
    expect(await onHand(product), 7, reason: 'stock decremented once, not twice');
  }, skip: _skipReason);

  test('order-level discount within the role cap reduces net; COGS unaffected',
      () async {
    final product = await seedProduct(scalarCostKobo: 50000);
    await seedInventory(product, 10);
    await seedBatch(product, 10, 50000);

    // Sell 10 @ ₦1,000 = ₦10,000 gross, ₦500 discount → ₦9,500 net.
    final res = await checkout(
      orderId: UuidV7.generate(),
      productId: product,
      quantity: 10,
      discountKobo: 50000,
    );
    final order = res['order'] as Map;
    expect((order['total_amount_kobo'] as num).toInt(), 1000000);
    expect((order['discount_kobo'] as num).toInt(), 50000);
    expect((order['net_amount_kobo'] as num).toInt(), 950000);

    final item = (res['order_items'] as List).first as Map;
    expect((item['buying_price_kobo'] as num).toInt(), 50000,
        reason: 'discount does not touch COGS');
  }, skip: _skipReason);

  // ── Slice 3 (#44): registered-customer credit & the wallet ledger ──────────

  test('Register-as-Credit-Sale (no cash) posts one order_payment debit; balance goes negative within the limit',
      () async {
    final product = await seedProduct();
    await seedInventory(product, 10);
    await seedBatch(product, 10, 50000);
    final customer = await seedCustomer(debtLimitKobo: 500000);

    final res = await checkout(
      orderId: UuidV7.generate(),
      productId: product,
      quantity: 3,
      method: 'credit',
      amountPaidKobo: 0,
      customerId: customer,
    );

    final order = res['order'] as Map;
    expect(order['status'], 'pending');
    expect((order['amount_paid_kobo'] as num).toInt(), 0,
        reason: 'no cash settled on a pure credit sale');
    expect(order['customer_id'], customer);

    final legs = (res['wallet_transactions'] as List).cast<Map>();
    expect(legs.length, 1, reason: 'debit only — no cash credit leg');
    expect(legs.single['reference_type'], 'order_payment');
    expect((legs.single['signed_amount_kobo'] as num).toInt(), -300000);

    expect(res['payment_transaction'], isNull,
        reason: 'no payment_transactions row when nothing is paid in cash');
    expect((res['customer_balance_kobo'] as num).toInt(), -300000);
    expect(await balanceOf(customer), -300000,
        reason: 'derived balance = the customer now owes the order total');
  }, skip: _skipReason);

  test('Pay-with-Credit draws the sale from an existing balance; balance drops, no cash payment',
      () async {
    final product = await seedProduct();
    await seedInventory(product, 10);
    await seedBatch(product, 10, 50000);
    // Debt limit 0 (no credit allowed) but a covering balance to spend.
    final customer =
        await seedCustomer(debtLimitKobo: 0, openingBalanceKobo: 500000);

    final res = await checkout(
      orderId: UuidV7.generate(),
      productId: product,
      quantity: 3,
      method: 'wallet',
      amountPaidKobo: 0,
      customerId: customer,
    );

    final legs = (res['wallet_transactions'] as List).cast<Map>();
    expect(legs.length, 1);
    expect(legs.single['reference_type'], 'order_payment');
    expect((legs.single['signed_amount_kobo'] as num).toInt(), -300000);
    expect(res['payment_transaction'], isNull);
    expect((res['customer_balance_kobo'] as num).toInt(), 200000,
        reason: '500,000 credit − 300,000 order');
    expect(await balanceOf(customer), 200000);
  }, skip: _skipReason);

  test('Register-as-Credit-Sale with partial cash posts a debit + a cash credit leg',
      () async {
    final product = await seedProduct();
    await seedInventory(product, 10);
    await seedBatch(product, 10, 50000);
    final customer = await seedCustomer(debtLimitKobo: 500000);

    final res = await checkout(
      orderId: UuidV7.generate(),
      productId: product,
      quantity: 3,
      method: 'credit',
      amountPaidKobo: 100000, // ₦1,000 of the ₦3,000 now
      customerId: customer,
    );

    final legs = (res['wallet_transactions'] as List)
        .cast<Map>()
        .map((l) =>
            '${l['reference_type']}|${(l['signed_amount_kobo'] as num).toInt()}')
        .toList()
      ..sort();
    expect(legs, ['order_payment|-300000', 'topup_cash|100000']);

    final pay = res['payment_transaction'] as Map;
    expect(pay['method'], 'cash');
    expect((pay['amount_kobo'] as num).toInt(), 100000);
    expect(await balanceOf(customer), -200000);
  }, skip: _skipReason);

  test('a sale that would exceed the debt limit is rejected — no order written',
      () async {
    final product = await seedProduct();
    await seedInventory(product, 10);
    await seedBatch(product, 10, 50000);
    // Limit ₦2,000; the ₦3,000 credit sale would push the balance to −₦3,000.
    final customer = await seedCustomer(debtLimitKobo: 200000);

    final orderId = UuidV7.generate();
    await expectLater(
      () => checkout(
        orderId: orderId,
        productId: product,
        quantity: 3,
        method: 'credit',
        amountPaidKobo: 0,
        customerId: customer,
      ),
      throwsA(predicate(
          (e) => e.toString().contains('debt_limit_exceeded'))),
    );

    final order = await clients.adminClient
        .from('orders')
        .select('id')
        .eq('id', orderId)
        .maybeSingle();
    expect(order, isNull, reason: 'all-or-nothing: nothing committed');
    expect(await onHand(product), 10, reason: 'stock untouched');
    expect(await balanceOf(customer), 0, reason: 'no wallet legs posted');
  }, skip: _skipReason);

  test('a customer with no debt limit cannot go into debt at all', () async {
    final product = await seedProduct();
    await seedInventory(product, 10);
    await seedBatch(product, 10, 50000);
    final customer = await seedCustomer(debtLimitKobo: 0); // no credit allowed

    await expectLater(
      () => checkout(
        orderId: UuidV7.generate(),
        productId: product,
        quantity: 3,
        method: 'credit',
        amountPaidKobo: 0,
        customerId: customer,
      ),
      throwsA(predicate(
          (e) => e.toString().contains('debt_limit_exceeded'))),
    );
  }, skip: _skipReason);

  test('a credit sale without a customer is rejected', () async {
    final product = await seedProduct();
    await seedInventory(product, 10);
    await seedBatch(product, 10, 50000);

    await expectLater(
      () => checkout(
        orderId: UuidV7.generate(),
        productId: product,
        quantity: 3,
        method: 'credit',
        amountPaidKobo: 0,
      ),
      throwsA(predicate(
          (e) => e.toString().contains('credit_requires_customer'))),
    );
  }, skip: _skipReason);
}
