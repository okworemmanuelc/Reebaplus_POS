// Pay on delivery + Mark as paid (#432, PRD #421). Money tests at the
// existing seams: Checkout (OrderService.addOrder -> OrdersDao.createOrder),
// Record Payment (CustomerService.topUpWallet) and the sale reversal
// (OrdersDao.markCancelled).

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/online_orders/pay_on_delivery.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/features/customers/data/services/customer_service.dart';
import 'package:reebaplus_pos/shared/services/activity_log_service.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/services/cart_service.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/services/orders/order_service.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late CartService cart;
  late CustomerService customers;
  late String storeId;
  late String staffId;
  late String customerId;
  late String waterId; // ₦300, plenty of stock

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://placeholder.supabase.co',
      anonKey: 'placeholder',
    );
  });

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
    storeId = UuidV7.generate();
    await db.into(db.stores).insert(
      StoresCompanion.insert(
        id: Value(storeId),
        businessId: businessId,
        name: 'Main',
      ),
    );
    staffId = UuidV7.generate();
    await db.into(db.users).insert(
      UsersCompanion.insert(
        id: Value(staffId),
        businessId: businessId,
        name: 'Owner',
        pin: '0',
      ),
    );
    customerId = await db.customersDao.addCustomer(
      CustomersCompanion.insert(
        businessId: businessId,
        name: 'Ada Buyer',
        shopperAccountId: const Value('shopper-1'),
      ),
    );
    waterId = UuidV7.generate();
    await db.into(db.products).insert(
      ProductsCompanion.insert(
        id: Value(waterId),
        businessId: businessId,
        name: 'Eva Water',
        retailerPriceKobo: const Value(30000),
        unit: const Value('Piece'),
      ),
    );
    await db.into(db.inventory).insert(
      InventoryCompanion.insert(
        businessId: businessId,
        productId: waterId,
        storeId: storeId,
        quantity: const Value(100),
      ),
    );

    final client = Supabase.instance.client;
    final nav = NavigationService();
    final auth = AuthService(
      db,
      nav,
      SecureStorageService(),
      SupabaseSyncService(db, SupabaseCloudTransport(client)),
      client,
    );
    cart = CartService(auth, nav);
    db.businessIdResolver = () => businessId;
    customers = CustomerService(db, ActivityLogService(db, auth));
  });

  tearDown(() => db.close());

  /// An accepted online order for water ×4 at ₦300 (₦1,200).
  Future<String> acceptedOrder() async {
    final id = UuidV7.generate();
    await db.into(db.onlineOrders).insert(
      OnlineOrdersCompanion.insert(
        id: id,
        businessId: businessId,
        storeId: storeId,
        shopperAccountId: const Value('shopper-1'),
        customerId: Value(customerId),
        status: const Value('accepted'),
        reference: 'ON-POD12345',
        shopperName: 'Ada',
        deliveryPhone: '08030000000',
        deliveryState: 'Nasarawa',
        deliveryLga: 'Keffi',
        deliveryStreet: '1 Road',
      ),
    );
    await db.into(db.onlineOrderLines).insert(
      OnlineOrderLinesCompanion.insert(
        id: UuidV7.generate(),
        businessId: businessId,
        onlineOrderId: id,
        productId: waterId,
        productName: 'Eva Water',
        unitPriceKobo: 30000,
        requestedQty: 4,
        acceptedQty: const Value(4),
      ),
    );
    return id;
  }

  /// A credit-sale Checkout (nothing paid now) of [items]: the exact call
  /// Checkout makes for Register as Credit Sale and for Pay on delivery.
  Future<String> creditCheckout(List<Map<String, dynamic>> items) async {
    final total = items.fold<int>(
      0,
      (s, l) => s + (l['unitPriceKobo'] as int) * (l['qty'] as num).toInt(),
    );
    final number = await OrderService(db).addOrder(
      customerId: customerId,
      cart: items,
      totalAmountKobo: total,
      amountPaidKobo: 0,
      paymentType: 'Credit Sale',
      staffId: staffId,
      storeId: storeId,
      onlineOrderId: CartService.onlineOrderIdOf(items),
    );
    final sale = await (db.select(db.orders)
          ..where((o) => o.orderNumber.equals(number)))
        .getSingle();
    return sale.id;
  }

  Future<String> payOnDeliverySale() async {
    cart.loadOnlineOrder((await db.onlineOrdersDao.tillLoad(
      await acceptedOrder(),
    ))!);
    return creditCheckout(cart.value);
  }

  /// The money shape of one order: header, wallet legs and payment rows,
  /// without ids or times.
  Future<Map<String, Object?>> moneyRows(String orderId) async {
    final o = await (db.select(db.orders)..where((t) => t.id.equals(orderId)))
        .getSingle();
    final wallet = await (db.select(db.walletTransactions)
          ..where((t) => t.orderId.equals(orderId)))
        .get();
    final payments = await (db.select(db.paymentTransactions)
          ..where((t) => t.orderId.equals(orderId)))
        .get();
    return {
      'order': [o.paymentType, o.status, o.netAmountKobo, o.amountPaidKobo],
      'wallet': (wallet
              .map((w) => '${w.type}/${w.referenceType}/${w.signedAmountKobo}')
              .toList()
            ..sort()),
      'payments': (payments
              .map((p) => '${p.type}/${p.method}/${p.amountKobo}')
              .toList()
            ..sort()),
    };
  }

  Future<int> balance() => db.customersDao.getWalletBalanceKobo(customerId);

  test('Pay on delivery posts the same rows as a credit sale', () async {
    final podId = await payOnDeliverySale();
    final plainItems = [
      for (final l in cart.value)
        {...l}..remove(CartService.kOnlineOrderIdKey),
    ];
    expect(CartService.onlineOrderIdOf(plainItems), isNull);
    final creditId = await creditCheckout(plainItems);

    expect(await moneyRows(podId), await moneyRows(creditId));
    final pod = await db.onlineOrdersDao.payOnDeliveryFor(podId);
    expect(pod, isNotNull, reason: 'linked to the online order');
    expect(
      await db.onlineOrdersDao.payOnDeliveryFor(creditId),
      isNull,
      reason: 'an untagged credit sale is not Pay on delivery',
    );
    expect(await balance(), -240000, reason: 'two ₦1,200 sales owed');
  });

  test('the label says Pay on delivery and what to collect, never credit',
      () async {
    final podId = await payOnDeliverySale();
    final pod = (await db.onlineOrdersDao.payOnDeliveryFor(podId))!;
    expect(pod.dueKobo, 120000);
    expect(pod.outstandingKobo, 120000);
    expect(pod.label, 'Pay on delivery · ${formatCurrency(1200.0)} to collect');
    expect(pod.label.toLowerCase(), isNot(contains('credit')));
    expect(payOnDeliveryLabel(50000).toLowerCase(), isNot(contains('credit')));
    expect(kPayOnDeliveryPaidLabel.toLowerCase(), isNot(contains('credit')));
  });

  test('Mark as paid posts the Record Payment rows, linked to the order; the '
      'order shows Paid and the balance clears', () async {
    final podId = await payOnDeliverySale();
    expect(await balance(), -120000);

    final collected = await customers.markPayOnDeliveryPaid(
      orderId: podId,
      method: 'transfer',
      staffId: staffId,
      storeId: storeId,
    );
    expect(collected, 120000);

    final credit = await (db.select(db.walletTransactions)
          ..where((t) =>
              t.orderId.equals(podId) & t.referenceType.equals('topup_transfer')))
        .getSingle();
    expect(credit.type, 'credit');
    expect(credit.signedAmountKobo, 120000);
    final payment = await (db.select(db.paymentTransactions)
          ..where((t) => t.walletTxnId.equals(credit.id)))
        .getSingle();
    expect(payment.type, 'wallet_topup');
    expect(payment.method, 'transfer');
    expect(payment.amountKobo, 120000);
    expect(payment.storeId, storeId);
    expect(payment.orderId, isNull, reason: 'one parent: the wallet row');

    // Exactly the rows Record Payment posts for the same money.
    await customers.topUpWallet(
      customerId: customerId,
      amountKobo: 120000,
      method: 'transfer',
      staffId: staffId,
      storeId: storeId,
    );
    final recordPayment = await (db.select(db.walletTransactions)
          ..where((t) =>
              t.orderId.isNull() & t.referenceType.equals('topup_transfer')))
        .getSingle();
    expect(
      [recordPayment.type, recordPayment.referenceType, recordPayment.amountKobo],
      [credit.type, credit.referenceType, credit.amountKobo],
    );
    final rpPayment = await (db.select(db.paymentTransactions)
          ..where((t) => t.walletTxnId.equals(recordPayment.id)))
        .getSingle();
    expect([rpPayment.type, rpPayment.method, rpPayment.amountKobo],
        [payment.type, payment.method, payment.amountKobo]);

    final pod = (await db.onlineOrdersDao.payOnDeliveryFor(podId))!;
    expect(pod.isPaid, isTrue);
    expect(pod.label, kPayOnDeliveryPaidLabel);
    expect(await balance(), 120000,
        reason: 'debt cleared; the extra Record Payment is credit');

    final queued = (await getPendingQueue(db)).map((q) => q.actionType);
    expect(queued, contains('wallet_transactions:upsert'));
    expect(queued, contains('payment_transactions:upsert'));
  });

  test('Mark as paid in cash, twice: the second call collects nothing',
      () async {
    final podId = await payOnDeliverySale();
    expect(
      await customers.markPayOnDeliveryPaid(
        orderId: podId,
        method: 'cash',
        staffId: staffId,
        storeId: storeId,
      ),
      120000,
    );
    expect(
      await customers.markPayOnDeliveryPaid(
        orderId: podId,
        method: 'cash',
        staffId: staffId,
        storeId: storeId,
      ),
      0,
    );
    final credits = await (db.select(db.walletTransactions)
          ..where((t) => t.referenceType.equals('topup_cash')))
        .get();
    expect(credits, hasLength(1));
    expect(credits.single.orderId, podId);
    expect(await balance(), 0);
  });

  test('Mark as paid takes cash or transfer only, and only for Pay on delivery',
      () async {
    final podId = await payOnDeliverySale();
    expect(
      () => customers.markPayOnDeliveryPaid(
        orderId: podId,
        method: 'wallet',
        staffId: staffId,
      ),
      throwsArgumentError,
    );
    final plain = await creditCheckout([
      for (final l in cart.value)
        {...l}..remove(CartService.kOnlineOrderIdKey),
    ]);
    expect(
      () => customers.markPayOnDeliveryPaid(
        orderId: plain,
        method: 'cash',
        staffId: staffId,
      ),
      throwsStateError,
    );
  });

  test('a later cancel keeps the collected money as the customer\'s credit',
      () async {
    final podId = await payOnDeliverySale();
    await customers.markPayOnDeliveryPaid(
      orderId: podId,
      method: 'cash',
      staffId: staffId,
      storeId: storeId,
    );
    expect(await balance(), 0);
    await db.ordersDao.markCancelled(podId, 'Returned', staffId);
    expect(await balance(), 120000,
        reason: 'goods reversed, the cash collected stays as credit');
    final pod = (await db.onlineOrdersDao.payOnDeliveryFor(podId))!;
    expect(pod.isLive, isFalse);
    expect(payOnDeliveryUncollectedKobo([pod]), 0);
  });

  test('the uncollected total counts only live, unpaid orders', () async {
    final a = await payOnDeliverySale();
    cart.clear();
    final b = await payOnDeliverySale();
    var all = await db.onlineOrdersDao.watchPayOnDelivery().first;
    expect(payOnDeliveryUncollectedKobo(all), 240000);
    await customers.markPayOnDeliveryPaid(
      orderId: a,
      method: 'cash',
      staffId: staffId,
    );
    all = await db.onlineOrdersDao.watchPayOnDelivery().first;
    expect(payOnDeliveryUncollectedKobo(all), 120000);
    expect(all.singleWhere((o) => o.orderId == b).isPaid, isFalse);
  });
}
