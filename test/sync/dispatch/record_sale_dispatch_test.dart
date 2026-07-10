import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../../helpers/dispatch_test_utils.dart';

class _SaleSeed {
  final String storeId;
  final String staffId;
  final String productId;
  final String customerId;
  _SaleSeed({
    required this.storeId,
    required this.staffId,
    required this.productId,
    required this.customerId,
  });
}

/// Seeds the fixtures createOrder needs: store, staff, product (+10
/// inventory), customer (wallet auto-created by addCustomer).
Future<_SaleSeed> _seedSaleFixtures(AppDatabase db, String businessId) async {
  final storeId = UuidV7.generate();
  await db.into(db.stores).insert(
        StoresCompanion.insert(
          id: Value(storeId),
          businessId: businessId,
          name: 'Main',
        ),
      );
  final staffId = UuidV7.generate();
  await db.into(db.users).insert(
        UsersCompanion.insert(
          id: Value(staffId),
          businessId: businessId,
          name: 'Cashier',
          pin: '0000',
        ),
      );
  final productId = UuidV7.generate();
  await db.into(db.products).insert(
        ProductsCompanion.insert(
          id: Value(productId),
          businessId: businessId,
          name: 'Test Beer',
          retailerPriceKobo: const Value(100000),
        ),
      );
  await db.into(db.inventory).insert(
        InventoryCompanion.insert(
          businessId: businessId,
          productId: productId,
          storeId: storeId,
          quantity: const Value(10),
        ),
      );
  final customerId = await db.customersDao.addCustomer(
    CustomersCompanion.insert(businessId: businessId, name: 'Buyer'),
  );
  return _SaleSeed(
    storeId: storeId,
    staffId: staffId,
    productId: productId,
    customerId: customerId,
  );
}

OrdersCompanion _orderCompanion(
  _SaleSeed s,
  String businessId, {
  required String orderNumber,
  int totalKobo = 200000,
  int amountPaidKobo = 200000,
}) =>
    OrdersCompanion.insert(
      businessId: businessId,
      orderNumber: orderNumber,
      customerId: Value(s.customerId),
      totalAmountKobo: totalKobo,
      netAmountKobo: totalKobo,
      amountPaidKobo: Value(amountPaidKobo),
      paymentType: 'cash',
      status: 'completed',
      staffId: Value(s.staffId),
      storeId: Value(s.storeId),
    );

OrderItemsCompanion _itemCompanion(_SaleSeed s, String businessId) =>
    OrderItemsCompanion.insert(
      businessId: businessId,
      orderId: 'placeholder', // overwritten by createOrder
      productId: Value(s.productId),
      storeId: s.storeId,
      quantity: 2,
      unitPriceKobo: 100000,
      totalKobo: 200000,
    );

void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
  });

  tearDown(() => db.close());

  group('OrdersDao.createOrder dispatch', () {
    test(
        'flag OFF: full local mirror + per-table upserts (orders + items + '
        'stock_tx + payment + inventory)', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
      final s = await _seedSaleFixtures(db, businessId);

      final orderId = await db.ordersDao.createOrder(
        order: _orderCompanion(s, businessId, orderNumber: 'ORD-V1-1'),
        items: [_itemCompanion(s, businessId)],
        customerId: s.customerId,
        amountPaidKobo: 200000,
        totalAmountKobo: 200000,
        staffId: s.staffId,
        storeId: s.storeId,
      );

      // Local mirror.
      expect((await db.select(db.orders).getSingle()).id, orderId);
      expect(await db.select(db.orderItems).get(), hasLength(1));
      expect(await db.select(db.stockTransactions).get(), hasLength(1));
      expect(await db.select(db.paymentTransactions).get(), hasLength(1));
      final inv = await db.select(db.inventory).getSingle();
      expect(inv.quantity, 8, reason: 'inventory deducted by 2');

      final actionTypes =
          (await getPendingQueue(db)).map((r) => r.actionType).toSet();
      expect(actionTypes.contains('domain:pos_record_sale_v2'), isFalse);
      expect(actionTypes, contains('orders:upsert'));
      expect(actionTypes, contains('order_items:upsert'));
      expect(actionTypes, contains('stock_transactions:upsert'));
      expect(actionTypes, contains('payment_transactions:upsert'));
      expect(actionTypes, contains('inventory:upsert'));
    });

    test(
        'flag ON: envelope + client wallet legs; order_items/stock/payment '
        'wait for the RPC; thin item shape; no p_wallet_amount_kobo', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: true);
      final s = await _seedSaleFixtures(db, businessId);
      // Drain the customers + customer_wallets enqueues from addCustomer
      // so only the sale-related rows remain.
      await db.delete(db.syncQueue).go();

      final orderId = await db.ordersDao.createOrder(
        order: _orderCompanion(s, businessId, orderNumber: 'ORD-V2-1'),
        items: [_itemCompanion(s, businessId)],
        customerId: s.customerId,
        amountPaidKobo: 200000,
        totalAmountKobo: 200000,
        staffId: s.staffId,
        storeId: s.storeId,
        paymentMethod: 'cash',
      );

      // Local: order header + inventory deduction + the client-authored wallet
      // double-entry. NOT order_items, stock_tx, or payment_tx — those land via
      // _applyDomainResponse from the RPC (server mints their ids).
      expect((await db.select(db.orders).getSingle()).id, orderId);
      expect(await db.select(db.orderItems).get(), isEmpty,
          reason: 'order_items wait for the RPC response (server mints ids)');
      expect(await db.select(db.stockTransactions).get(), isEmpty);
      expect(await db.select(db.paymentTransactions).get(), isEmpty);
      final inv = await db.select(db.inventory).getSingle();
      expect(inv.quantity, 8, reason: 'inventory still deducted on v2 path');

      // §14.3 wallet legs are client-authored on BOTH paths (invariant #3) —
      // pos_record_sale_v2 is passed NO wallet amount. A fully-paid registered
      // sale posts a goods debit (−total) and a cash credit (+paid).
      final wallet = await db.select(db.walletTransactions).get();
      expect(wallet, hasLength(2));
      expect(
        wallet.where((w) => w.type == 'debit' && w.signedAmountKobo == -200000),
        hasLength(1),
      );
      expect(
        wallet.where((w) => w.type == 'credit' && w.signedAmountKobo == 200000),
        hasLength(1),
      );

      // The pending queue: exactly one domain envelope + the two wallet legs.
      final pending = await getPendingQueue(db);
      final domainRows =
          pending.where((r) => r.actionType == 'domain:pos_record_sale_v2');
      final walletRows =
          pending.where((r) => r.actionType == 'wallet_transactions:upsert');
      expect(domainRows, hasLength(1));
      expect(walletRows, hasLength(2));
      expect(pending, hasLength(3));

      final payload = decodePayload(domainRows.single);
      expect(payload['p_business_id'], businessId);
      expect(payload['p_actor_id'], s.staffId);
      expect(payload['p_order_id'], orderId);
      expect(payload['p_order_number'], 'ORD-V2-1');
      expect(payload['p_store_id'], s.storeId);
      expect(payload['p_payment_type'], 'cash');
      expect(payload['p_payment_method'], 'cash');
      expect(payload['p_amount_paid_kobo'], 200000);
      expect(payload['p_customer_id'], s.customerId);
      expect(payload['p_status'], 'completed');
      // The RPC's wallet branch stays a no-op — the legs above own the ledger.
      expect(payload.containsKey('p_wallet_amount_kobo'), isFalse);

      final items = payload['p_items'] as List;
      expect(items, hasLength(1));
      final item = items.first as Map;
      // Thin item: no order_id, no business_id, no id — server mints
      // those. total_kobo is server-computed, so absent.
      expect(item.containsKey('id'), isFalse);
      expect(item.containsKey('order_id'), isFalse);
      expect(item.containsKey('business_id'), isFalse);
      expect(item.containsKey('total_kobo'), isFalse);
      expect(item['product_id'], s.productId);
      expect(item['quantity'], 2);
      expect(item['unit_price_kobo'], 100000);
    });

    test(
        'flag ON (insufficient stock): InsufficientStockException raised '
        'before the envelope lands, no order created', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: true);
      final s = await _seedSaleFixtures(db, businessId);
      await db.delete(db.syncQueue).go();

      // Try to sell 50 against stock=10. The local stock guard fires
      // before the envelope is built; the transaction rolls back.
      Object? caught;
      try {
        await db.ordersDao.createOrder(
          order: _orderCompanion(s, businessId, orderNumber: 'ORD-OVER'),
          items: [
            OrderItemsCompanion.insert(
              businessId: businessId,
              orderId: 'placeholder',
              productId: Value(s.productId),
              storeId: s.storeId,
              quantity: 50,
              unitPriceKobo: 100000,
              totalKobo: 5000000,
            ),
          ],
          customerId: s.customerId,
          amountPaidKobo: 5000000,
          totalAmountKobo: 5000000,
          staffId: s.staffId,
          storeId: s.storeId,
        );
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<InsufficientStockException>());

      // Atomicity: order header rolled back too (drift transaction
      // wraps the whole createOrder body).
      expect(await db.select(db.orders).get(), isEmpty);
      // No envelope landed.
      expect(await getPendingQueue(db), isEmpty);
      // Inventory unchanged.
      expect((await db.select(db.inventory).getSingle()).quantity, 10);
    });

    test(
        'flag ON (register-as-credit): wallet legs client-authored, envelope '
        'carries NO p_wallet_amount_kobo — the RPC cannot reject a debt sale',
        () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: true);
      final s = await _seedSaleFixtures(db, businessId);
      await db.delete(db.syncQueue).go();

      // A register-as-credit sale: pay part now, owe the rest. On the OLD v2
      // path this set p_wallet_amount_kobo and pos_record_sale_v2 rejected it
      // (insufficient_wallet_balance — the customer's balance is 0, cannot be
      // debited). Now the double-entry is posted client-side and the RPC is
      // passed no wallet amount, so the sale is never gated by the balance —
      // exactly the regression Option ① fixes.
      await db.ordersDao.createOrder(
        order: _orderCompanion(
          s,
          businessId,
          orderNumber: 'ORD-CREDIT',
          amountPaidKobo: 50000,
        ),
        items: [_itemCompanion(s, businessId)],
        customerId: s.customerId,
        amountPaidKobo: 50000,
        totalAmountKobo: 200000,
        staffId: s.staffId,
        storeId: s.storeId,
        paymentMethod: 'cash',
      );

      // Two legs: a −200000 goods debit and a +50000 cash credit, netting to
      // −150000 — the customer now owes 150000 (the RPC never sees this).
      final wallet = await db.select(db.walletTransactions).get();
      expect(wallet, hasLength(2));
      expect(
        wallet.where((w) => w.type == 'debit' && w.signedAmountKobo == -200000),
        hasLength(1),
      );
      expect(
        wallet.where((w) => w.type == 'credit' && w.signedAmountKobo == 50000),
        hasLength(1),
      );
      expect(
        await db.walletTransactionsDao.getBalanceKobo(s.customerId),
        -150000,
      );

      // The envelope carries the customer + amount paid, but NO wallet amount.
      final pending = await getPendingQueue(db);
      final domainRow =
          pending.firstWhere((r) => r.actionType == 'domain:pos_record_sale_v2');
      final payload = decodePayload(domainRow);
      expect(payload['p_customer_id'], s.customerId);
      expect(payload['p_amount_paid_kobo'], 50000);
      expect(payload.containsKey('p_wallet_amount_kobo'), isFalse);
    });
  });
}
