// Send to till (#431, PRD #421): an accepted Online Order goes to the Cart of
// its store at the agreed prices with the linked Customer, and a normal
// Checkout of that tagged Cart marks the order Sent out (`fulfilled`), linked
// to the new Order, in the sale's own transaction (OrderService.addOrder ->
// OrdersDao.createOrder, the existing checkout seam).

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
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
  late NavigationService nav;
  late String storeId;
  late String staffId;
  late String customerId;
  late String mfrId;
  late String beerId; // crate bottle, catalogue ₦1,000
  late String waterId; // plain, catalogue ₦300

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
    await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
        .write(const BusinessesCompanion(type: Value('Bar')));

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
        name: 'Cashier',
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
    mfrId = UuidV7.generate();
    await db.into(db.manufacturers).insert(
      ManufacturersCompanion.insert(
        id: Value(mfrId),
        businessId: businessId,
        name: 'Star',
        depositAmountKobo: const Value(50000),
      ),
    );
    beerId = await _product(
      db,
      businessId,
      storeId,
      name: 'Star Lager',
      retailKobo: 100000,
      stock: 50,
      manufacturerId: mfrId,
    );
    waterId = await _product(
      db,
      businessId,
      storeId,
      name: 'Eva Water',
      retailKobo: 30000,
      stock: 1,
    );

    final client = Supabase.instance.client;
    nav = NavigationService();
    final auth = AuthService(
      db,
      nav,
      SecureStorageService(),
      SupabaseSyncService(db, SupabaseCloudTransport(client)),
      client,
    );
    cart = CartService(auth, nav);
    // AuthService rebinds the resolver; point it back at the test business.
    db.businessIdResolver = () => businessId;
  });

  tearDown(() => db.close());

  /// An accepted order: beer ×3 agreed at ₦900 (catalogue ₦1,000), water
  /// asked ×2 accepted ×2 (only 1 in stock), and a removed line (0).
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
        reference: 'ON-ABCD1234',
        shopperName: 'Ada',
        deliveryPhone: '08030000000',
        deliveryState: 'Nasarawa',
        deliveryLga: 'Keffi',
        deliveryStreet: '1 Road',
      ),
    );
    Future<void> line(String productId, String name, int price, int asked,
        int accepted) {
      return db.into(db.onlineOrderLines).insert(
        OnlineOrderLinesCompanion.insert(
          id: UuidV7.generate(),
          businessId: businessId,
          onlineOrderId: id,
          productId: productId,
          productName: name,
          unitPriceKobo: price,
          requestedQty: asked,
          acceptedQty: Value(accepted),
        ),
      );
    }

    await line(beerId, 'Star Lager', 90000, 3, 3);
    await line(waterId, 'Eva Water', 30000, 2, 2);
    await line(waterId, 'Removed', 30000, 1, 0);
    return id;
  }

  Future<OnlineOrderData> readOrder(String id) =>
      (db.select(db.onlineOrders)..where((t) => t.id.equals(id))).getSingle();

  Future<String> checkout({String? customer}) {
    final items = cart.value;
    final total = items.fold<int>(
      0,
      (s, l) => s + (l['unitPriceKobo'] as int) * (l['qty'] as num).toInt(),
    );
    return OrderService(db).addOrder(
      customerId: customer,
      cart: items,
      totalAmountKobo: total,
      amountPaidKobo: total,
      paymentType: 'cash',
      staffId: staffId,
      storeId: storeId,
      onlineOrderId: CartService.onlineOrderIdOf(items),
    );
  }

  test('loads accepted lines at the agreed prices, with the customer and the '
      'tag, into the order\'s store', () async {
    final id = await acceptedOrder();
    final load = await db.onlineOrdersDao.tillLoad(id);
    final short = cart.loadOnlineOrder(load!);

    expect(nav.lockedStoreId.value, storeId, reason: 'the order\'s store');
    expect(cart.activeOnlineOrderId, id);
    expect(cart.activeCustomer.value?.id, customerId);
    expect(cart.value, hasLength(2), reason: 'the removed line stays out');
    final beer = cart.value.firstWhere((l) => l['id'] == beerId);
    expect(beer['qty'], 3);
    expect(beer['unitPriceKobo'], 90000, reason: 'agreed price');
    expect(beer['catalogPriceKobo'], 100000, reason: 'catalogue kept');
    expect(beer['customPriceKobo'], isNull, reason: 'no custom-price grant');
    final water = cart.value.firstWhere((l) => l['id'] == waterId);
    expect(water['qty'], 1, reason: 'lowered to the store\'s stock');
    expect(short, ['Eva Water']);
  });

  test('the agreed price holds against a catalogue refresh', () async {
    cart.loadOnlineOrder((await db.onlineOrdersDao.tillLoad(
      await acceptedOrder(),
    ))!);
    cart.refreshProduct(
      productId: beerId,
      name: 'Star Lager',
      price: 1100,
      unitPriceKobo: 110000,
      emptyCrateValueKobo: 0,
    );
    final beer = cart.value.firstWhere((l) => l['id'] == beerId);
    expect(beer['unitPriceKobo'], 90000);
    expect(CartService.holdsPrice(beer), isTrue);
  });

  test('checkout of the tagged cart marks the order fulfilled with the new '
      'order id, and records the price difference', () async {
    final id = await acceptedOrder();
    cart.loadOnlineOrder((await db.onlineOrdersDao.tillLoad(id))!);
    final number = await checkout(customer: customerId);

    final sale = await (db.select(db.orders)
          ..where((o) => o.orderNumber.equals(number)))
        .getSingle();
    final online = await readOrder(id);
    expect(online.status, 'fulfilled');
    expect(online.linkedOrderId, sale.id);
    expect(sale.customerId, customerId);

    final beerLine = await (db.select(db.orderItems)
          ..where((i) => i.orderId.equals(sale.id) & i.productId.equals(beerId)))
        .getSingle();
    expect(beerLine.unitPriceKobo, 90000);
    expect(beerLine.cataloguePriceKobo, 100000);

    final queued = (await getPendingQueue(db))
        .where((q) => q.actionType == 'online_orders:upsert')
        .map(decodePayload)
        .toList();
    expect(queued, hasLength(1));
    expect(queued.single['status'], 'fulfilled');
    expect(queued.single['linked_order_id'], sale.id);
  });

  test('on the v2 path the fulfilled push is held behind the sale', () async {
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: true);
    final id = await acceptedOrder();
    cart.loadOnlineOrder((await db.onlineOrdersDao.tillLoad(id))!);
    await checkout(customer: customerId);
    final online = await readOrder(id);
    final row = await (db.select(db.syncQueue)
          ..where((q) => q.actionType.equals('online_orders:upsert')))
        .getSingle();
    expect(row.heldByOrderId, online.linkedOrderId);

    // A server-rejected sale reverses locally and reopens the order.
    await db.ordersDao.reverseRejectedSaleLocal(
      orderId: online.linkedOrderId!,
      items: const [],
      staffId: staffId,
    );
    final reopened = await readOrder(id);
    expect(reopened.status, 'accepted');
    expect(reopened.linkedOrderId, isNull);
  });

  test('clearing the cart leaves the order accepted', () async {
    final id = await acceptedOrder();
    cart.loadOnlineOrder((await db.onlineOrdersDao.tillLoad(id))!);
    cart.clear();
    expect(cart.activeOnlineOrderId, isNull);
    expect((await readOrder(id)).status, 'accepted');

    // A later untagged sale does not touch it.
    cart.addItem(
      await (db.select(db.products)..where((p) => p.id.equals(waterId)))
          .getSingle(),
      maxStock: 1,
    );
    await checkout();
    final online = await readOrder(id);
    expect(online.status, 'accepted');
    expect(online.linkedOrderId, isNull);
  });

  test('a saved cart keeps the tag through save and recall', () async {
    final id = await acceptedOrder();
    cart.loadOnlineOrder((await db.onlineOrdersDao.tillLoad(id))!);
    final savedId = await db.ordersDao.saveCart(
      SavedCartsCompanion.insert(
        businessId: businessId,
        name: 'Ada online',
        customerId: Value(cart.activeCustomer.value?.id),
        cartData: jsonEncode(cart.value),
        storeId: Value(storeId),
      ),
    );
    cart.clear();

    final saved = await db.ordersDao.getSavedCart(savedId);
    final items = (jsonDecode(saved!.cartData) as List)
        .cast<Map<String, dynamic>>();
    cart.loadCart(items, null, storeId: saved.storeId);
    expect(cart.activeOnlineOrderId, id);
    final beer = cart.value.firstWhere((l) => l['id'] == beerId);
    expect(beer['unitPriceKobo'], 90000);

    await checkout(customer: customerId);
    expect((await readOrder(id)).status, 'fulfilled');
  });

  test('crates behave exactly as in a till sale', () async {
    Future<({List<OrderCrateLineData> lines, int ledger})> crates(
      String orderNumber,
    ) async {
      final o = await (db.select(db.orders)
            ..where((x) => x.orderNumber.equals(orderNumber)))
          .getSingle();
      final lines = await (db.select(db.orderCrateLines)
            ..where((l) => l.orderId.equals(o.id)))
          .get();
      final ledger = await (db.select(db.crateLedger)
            ..where((l) => l.referenceOrderId.equals(o.id)))
          .get();
      return (
        lines: lines,
        ledger: ledger.fold<int>(0, (s, r) => s + r.quantityDelta),
      );
    }

    // Till sale: beer ×3 at the same price, same customer.
    final beer = await (db.select(db.products)
          ..where((p) => p.id.equals(beerId)))
        .getSingle();
    cart.addItem(beer, qty: 3, maxStock: 50);
    final till = await crates(await checkout(customer: customerId));
    cart.clear();

    // The same beer ×3 sent to the till from an online order.
    final id = await acceptedOrder();
    cart.loadOnlineOrder((await db.onlineOrdersDao.tillLoad(id))!);
    cart.removeItem('Eva Water');
    final online = await crates(await checkout(customer: customerId));

    expect(online.lines, hasLength(till.lines.length));
    expect(online.lines.single.cratesTaken, till.lines.single.cratesTaken);
    expect(online.lines.single.depositRateKobo, till.lines.single.depositRateKobo);
    expect(online.lines.single.depositPaidKobo, till.lines.single.depositPaidKobo);
    expect(online.ledger, till.ledger);
    expect(online.ledger, isNot(0), reason: 'crates were issued');
  });
}

Future<String> _product(
  AppDatabase db,
  String businessId,
  String storeId, {
  required String name,
  required int retailKobo,
  required int stock,
  String? manufacturerId,
}) async {
  final id = UuidV7.generate();
  await db.into(db.products).insert(
    ProductsCompanion.insert(
      id: Value(id),
      businessId: businessId,
      name: name,
      retailerPriceKobo: Value(retailKobo),
      manufacturerId: Value(manufacturerId),
      unit: Value(manufacturerId == null ? 'Piece' : 'Bottle'),
      trackEmpties: Value(manufacturerId != null),
    ),
  );
  await db.into(db.inventory).insert(
    InventoryCompanion.insert(
      businessId: businessId,
      productId: id,
      storeId: storeId,
      quantity: Value(stock),
    ),
  );
  return id;
}
