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
        'flag ON: one envelope, only order header + inventory mirrored '
        'locally, thin item shape', () async {
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

      // Local: order header + inventory deduction. NOT order_items, stock_tx,
      // or payment_tx — those land via _applyDomainResponse from the RPC.
      expect((await db.select(db.orders).getSingle()).id, orderId);
      expect(await db.select(db.orderItems).get(), isEmpty,
          reason: 'order_items wait for the RPC response (server mints ids)');
      expect(await db.select(db.stockTransactions).get(), isEmpty);
      expect(await db.select(db.paymentTransactions).get(), isEmpty);
      final inv = await db.select(db.inventory).getSingle();
      expect(inv.quantity, 8, reason: 'inventory still deducted on v2 path');

      final pending = await getPendingQueue(db);
      expect(pending, hasLength(1));
      expect(pending.first.actionType, 'domain:pos_record_sale_v2');

      final payload = decodePayload(pending.first);
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

    test('flag ON (wallet portion): payload carries p_wallet_amount_kobo',
        () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: true);
      final s = await _seedSaleFixtures(db, businessId);
      await db.delete(db.syncQueue).go();

      // Topup the wallet so the v1-style local guard would pass; on v2
      // the server is authoritative for the balance check, but the local
      // DAO still requires a customer wallet to exist for the OFF path
      // to compile. For dispatch-shape testing, we only care that the
      // envelope carries the wallet portion.
      final wallet = await (db.select(db.customerWallets)
            ..where((t) => t.customerId.equals(s.customerId)))
          .getSingle();
      expect(wallet, isNotNull);

      await db.ordersDao.createOrder(
        order: _orderCompanion(s, businessId, orderNumber: 'ORD-WAL'),
        items: [_itemCompanion(s, businessId)],
        customerId: s.customerId,
        amountPaidKobo: 200000,
        totalAmountKobo: 200000,
        staffId: s.staffId,
        storeId: s.storeId,
        walletDebitKobo: 50000,
        paymentMethod: 'cash',
      );

      final pending = await getPendingQueue(db);
      final payload = decodePayload(pending.first);
      expect(payload['p_wallet_amount_kobo'], 50000);
      expect(payload['p_customer_id'], s.customerId);
    });
  });
}
