import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import 'package:reebaplus_pos/core/crates/crate_exchange.dart';
import 'package:reebaplus_pos/core/utils/reversal_labels.dart';

import '../helpers/dispatch_test_utils.dart';

/// #709 — a cancelled sale's reversal rows read "Sale cancelled — ORD-…".
void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    // Crate tracking runs for Bar / Beer Distributor businesses only
    // (createOrder + the cancel reversal read via the same crate ledger). Stamp
    // the bootstrap business 'Bar' so the crate paths under test actually run.
    await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
        .write(const BusinessesCompanion(type: Value('Bar')));
    // Exercise the per-table (v1) sync path for both sale and cancel — the live
    // path (the v2 cancel envelope is held off until it mints the reversal).
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
    await setFlag(db, 'feature.domain_rpcs_v2.cancel_order', on: false);
  });

  tearDown(() => db.close());

  // Seeds store + staff + customer (wallet auto-created) and returns their ids.
  Future<(String storeId, String staffId, String customerId)>
      seedBase() async {
    final storeId = UuidV7.generate();
    await db.into(db.stores).insert(StoresCompanion.insert(
        id: Value(storeId), businessId: businessId, name: 'Main'));
    final staffId = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
        id: Value(staffId),
        businessId: businessId,
        name: 'Cashier',
        pin: '0000'));
    final customerId = await db.customersDao.addCustomer(
        CustomersCompanion.insert(businessId: businessId, name: 'Buyer'));
    return (storeId, staffId, customerId);
  }

  // Seeds a manufacturer (deposit rate ₦500) + a crate-tracked bottle product
  // (+inventory) and returns (manufacturerId, productId).
  Future<(String, String)> seedCrateProduct(String storeId) async {
    final manufacturerId = UuidV7.generate();
    await db.into(db.manufacturers).insert(ManufacturersCompanion.insert(
        id: Value(manufacturerId),
        businessId: businessId,
        name: 'Star',
        depositAmountKobo: const Value(50000)));
    final productId = UuidV7.generate();
    await db.into(db.products).insert(ProductsCompanion.insert(
        id: Value(productId),
        businessId: businessId,
        name: 'Star Bottle',
        retailerPriceKobo: const Value(100000),
        manufacturerId: Value(manufacturerId),
        unit: const Value('Bottle'),
        trackEmpties: const Value(true)));
    await db.into(db.inventory).insert(InventoryCompanion.insert(
        businessId: businessId,
        productId: productId,
        storeId: storeId,
        quantity: const Value(100)));
    return (manufacturerId, productId);
  }

  // Checkout convention (§13.4 Ring 3): grand total = goods + deposit held; the
  // deposit slice (per manufacturer) is carved into a held `crate_deposit` leg.
  // An empty [deposits] map is a crate-track sale (crates issued to the
  // customer); a non-empty map is a money-track sale (deposit held in money).
  Future<String> sell(
    String storeId,
    String staffId,
    String customerId,
    String productId,
    int qty, {
    Map<String, int> deposits = const {},
  }) async {
    final goodsKobo = qty * 100000;
    final depositKobo = deposits.values.fold<int>(0, (s, v) => s + v);
    final grandKobo = goodsKobo + depositKobo;
    return db.ordersDao.createOrder(
      order: OrdersCompanion.insert(
        businessId: businessId,
        orderNumber: 'ORD-${UuidV7.generate()}',
        customerId: Value(customerId),
        totalAmountKobo: grandKobo,
        netAmountKobo: grandKobo,
        amountPaidKobo: Value(grandKobo),
        paymentType: 'cash',
        status: 'pending',
        staffId: Value(staffId),
        storeId: Value(storeId),
        crateDepositPaidKobo: Value(depositKobo),
      ),
      items: [
        OrderItemsCompanion.insert(
          businessId: businessId,
          orderId: 'placeholder',
          productId: Value(productId),
          storeId: storeId,
          quantity: qty.toDouble(),
          unitPriceKobo: 100000,
          totalKobo: goodsKobo,
        ),
      ],
      customerId: customerId,
      amountPaidKobo: grandKobo,
      totalAmountKobo: grandKobo,
      staffId: staffId,
      storeId: storeId,
      crateDepositPaidByManufacturer: deposits,
    );
  }


  group('pure label mapping', () {
    test('saleCancelledLabel', () {
      expect(saleCancelledLabel('ORD-1'), 'Sale cancelled — ORD-1');
      expect(saleCancelledLabel(null), 'Sale cancelled');
    });

    test('crateReversalLabel: new reason, old row, and non-matches', () {
      String? l(String? reason, {String? status, String mt = 'adjusted',
              String? customer = 'c', String? order = 'o'}) =>
          crateReversalLabel(
            movementType: mt,
            reason: reason,
            customerId: customer,
            referenceOrderId: order,
            orderNumber: 'ORD-9',
            orderStatus: status,
          );
      expect(l(kOrderCancelledReason), 'Sale cancelled — ORD-9');
      expect(l(null, status: 'cancelled'), 'Sale cancelled — ORD-9');
      expect(l(null, status: 'completed'), isNull);
      expect(l(null, status: 'cancelled', customer: null), isNull);
      expect(l(null, status: 'cancelled', order: null), isNull);
      expect(l(kOrderCancelledReason, mt: 'issued'), isNull);
      expect(l('rotten_wood', status: 'cancelled'), isNull);
    });

    test('walletReversalLabel', () {
      String? l(String t, String? o) => walletReversalLabel(
          referenceType: t, orderId: o, orderNumber: 'ORD-9');
      expect(l('refund', 'o'), 'Sale cancelled — ORD-9');
      expect(l('void', 'o'), 'Sale cancelled — ORD-9');
      expect(l('refund', null), isNull);
      expect(l('crate_deposit_refunded', 'o'), isNull);
    });

    test('stock return label', () {
      StockTransactionWithDetails tx(String type, String? n) =>
          StockTransactionWithDetails(
            transactionId: 't',
            productId: 'p',
            productName: 'P',
            movementType: type,
            quantityDelta: 1,
            performedByName: 'U',
            locationId: 'l',
            createdAt: DateTime(2026),
            unitPriceKobo: 0,
            orderNumber: n,
          );
      expect(tx('return', 'ORD-9').movementLabel, 'Sale cancelled — ORD-9');
      expect(tx('return', null).movementLabel, 'Return');
      expect(tx('sale', 'ORD-9').movementLabel, 'Sale');
    });
  });

  test('cancel writes labelled rows in all three histories', () async {
    final (storeId, staffId, customerId) = await seedBase();
    final (mfrId, productId) = await seedCrateProduct(storeId);
    final orderId = await sell(storeId, staffId, customerId, productId, 2);
    final number = (await db.ordersDao.findById(orderId))!.orderNumber;
    await db.ordersDao.markCancelled(orderId, 'changed mind', staffId);

    // Crate history.
    final crate = await db.cratePoolDao
        .watchManufacturerCrateMovements(mfrId)
        .first;
    final rev = crate.where((e) => e.reason == kOrderCancelledReason).toList();
    expect(rev, hasLength(1));
    expect(rev.single.movementType, 'adjusted');
    expect(rev.single.movementLabel, 'Sale cancelled — $number');

    // Stock history.
    final stock = await db.stockLedgerDao.watchAllTransactionsFiltered().first;
    final returns = stock.where((t) => t.movementType == 'return').toList();
    expect(returns, isNotEmpty);
    expect(returns.first.movementLabel, 'Sale cancelled — $number');

    // Customer statement.
    final legs = await db.customersDao.watchWalletHistory(customerId).first;
    final reversal = legs.where((t) =>
        t.orderId == orderId &&
        (t.referenceType == 'refund' || t.referenceType == 'void'));
    expect(reversal, isNotEmpty);
    final numbers = await db.walletTransactionsDao.orderNumbersFor({orderId});
    expect(
      walletReversalLabel(
        referenceType: reversal.first.referenceType,
        orderId: orderId,
        orderNumber: numbers[orderId],
      ),
      'Sale cancelled — $number',
    );
  });
}
