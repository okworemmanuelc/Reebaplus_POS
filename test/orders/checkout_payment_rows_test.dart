import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

/// #175 (Money integrity #5, PRD #155) — **tender picker + cash-card honesty.**
/// Checkout splits the tender into distinct `payment_transactions` rows so
/// "Cash sales" finally ties to the drawer:
///   • the chosen tender ('cash' | 'transfer') is written to `method`, so a
///     transfer sale is EXCLUDED from the cash-drawer figure and a cash sale is
///     included;
///   • a refundable crate deposit is booked under its own `crate_deposit` type,
///     kept out of "Cash sales" and headline "Total Sales", shown as held money;
///   • an overpayment records a goods `sale` row + a `wallet_topup` row for the
///     excess, NOT the full tender as a sale.
///
/// Drives the Checkout path through `OrdersDao.createOrder` on the v1 (live)
/// sync path — the seam the PRD's Testing Decisions name.
void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
    await setFlag(db, 'feature.domain_rpcs_v2.cancel_order', on: false);
  });

  tearDown(() => db.close());

  Future<(String storeId, String staffId, String customerId)> seedBase() async {
    final storeId = UuidV7.generate();
    await db.into(db.stores).insert(StoresCompanion.insert(
        id: Value(storeId), businessId: businessId, name: 'Main'));
    final staffId = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
        id: Value(staffId), businessId: businessId, name: 'Cashier', pin: '0000'));
    final customerId = await db.customersDao.addCustomer(
        CustomersCompanion.insert(businessId: businessId, name: 'Buyer'));
    return (storeId, staffId, customerId);
  }

  Future<String> seedProduct(String storeId, {String? manufacturerId}) async {
    final productId = UuidV7.generate();
    await db.into(db.products).insert(ProductsCompanion.insert(
        id: Value(productId),
        businessId: businessId,
        name: 'Beer',
        retailerPriceKobo: const Value(100000),
        manufacturerId: Value(manufacturerId),
        unit: Value(manufacturerId == null ? 'Piece' : 'Bottle'),
        trackEmpties: Value(manufacturerId != null)));
    await db.into(db.inventory).insert(InventoryCompanion.insert(
        businessId: businessId,
        productId: productId,
        storeId: storeId,
        quantity: const Value(100)));
    return productId;
  }

  // Sum of the payment rows of a [type] with a cash [method] — mirrors the
  // reconciliation's cash-drawer bucket (cash sales = type 'sale', method
  // 'cash', voided rows excluded).
  Future<int> cashDrawer(String type) async {
    final rows = await (db.select(db.paymentTransactions)
          ..where((p) =>
              p.type.equals(type) &
              p.method.equals('cash') &
              p.voidedAt.isNull()))
        .get();
    return rows.fold<int>(0, (s, r) => s + r.amountKobo);
  }

  Future<PaymentTransactionData?> onlyRow(String type) => (db
          .select(db.paymentTransactions)
        ..where((p) => p.type.equals(type)))
      .getSingleOrNull();

  // A single-line sale of [qty] @ ₦1,000. Returns the order id. [method] is the
  // tender; [paidKobo]/[depositByMfr] default to a fully-paid, deposit-free sale.
  Future<String> sell(
    String storeId,
    String staffId,
    String customerId,
    String productId, {
    required int qty,
    required String method,
    int? paidKobo,
    Map<String, int> depositByMfr = const {},
  }) async {
    final goodsKobo = qty * 100000;
    final depositKobo = depositByMfr.values.fold<int>(0, (s, v) => s + v);
    final grandKobo = goodsKobo + depositKobo;
    final paid = paidKobo ?? grandKobo;
    return db.ordersDao.createOrder(
      order: OrdersCompanion.insert(
        businessId: businessId,
        orderNumber: 'ORD-${UuidV7.generate()}',
        customerId: Value(customerId),
        totalAmountKobo: grandKobo,
        netAmountKobo: grandKobo,
        amountPaidKobo: Value(paid),
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
          quantity: qty,
          unitPriceKobo: 100000,
          totalKobo: goodsKobo,
        ),
      ],
      customerId: customerId,
      amountPaidKobo: paid,
      totalAmountKobo: grandKobo,
      staffId: staffId,
      storeId: storeId,
      paymentMethod: method,
      crateDepositPaidByManufacturer: depositByMfr,
    );
  }

  test('a cash sale writes one goods sale row, included in the cash drawer',
      () async {
    final (storeId, staffId, customerId) = await seedBase();
    final productId = await seedProduct(storeId);

    await sell(storeId, staffId, customerId, productId,
        qty: 2, method: 'cash');

    final sale = await onlyRow('sale');
    expect(sale, isNotNull);
    expect(sale!.amountKobo, 200000);
    expect(sale.method, 'cash');
    expect(sale.storeId, storeId, reason: 'the sale-level store is stamped (#169)');
    expect(await onlyRow('crate_deposit'), isNull);
    expect(await onlyRow('wallet_topup'), isNull);
    expect(await cashDrawer('sale'), 200000);
  });

  test('a transfer sale books method transfer and is out of the cash drawer',
      () async {
    final (storeId, staffId, customerId) = await seedBase();
    final productId = await seedProduct(storeId);

    await sell(storeId, staffId, customerId, productId,
        qty: 2, method: 'transfer');

    final sale = await onlyRow('sale');
    expect(sale!.method, 'transfer');
    expect(sale.amountKobo, 200000);
    expect(await cashDrawer('sale'), 0,
        reason: 'a transfer sale is excluded from the cash-drawer figure');
  });

  test(
      'a crate-deposit sale splits into a goods sale row + a crate_deposit row',
      () async {
    await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
        .write(const BusinessesCompanion(type: Value('Bar')));
    final (storeId, staffId, customerId) = await seedBase();
    final mfrId = UuidV7.generate();
    await db.into(db.manufacturers).insert(ManufacturersCompanion.insert(
        id: Value(mfrId),
        businessId: businessId,
        name: 'Star',
        depositAmountKobo: const Value(50000)));
    final productId = await seedProduct(storeId, manufacturerId: mfrId);

    // 1 bottle @ ₦1,000 + ₦500 deposit = ₦1,500 paid, cash.
    await sell(storeId, staffId, customerId, productId,
        qty: 1, method: 'cash', depositByMfr: {mfrId: 50000});

    final sale = await onlyRow('sale');
    expect(sale!.amountKobo, 100000, reason: 'the sale row is goods only');
    expect(sale.method, 'cash');
    final deposit = await onlyRow('crate_deposit');
    expect(deposit!.amountKobo, 50000);
    expect(deposit.method, 'cash');
    expect(deposit.storeId, storeId);
    expect(await onlyRow('wallet_topup'), isNull);

    // "Cash sales" (goods) excludes the deposit; the deposit shows on its own.
    expect(await cashDrawer('sale'), 100000);
    expect(await cashDrawer('crate_deposit'), 50000);
  });

  test('an overpayment records a goods sale row + a wallet_topup for the excess',
      () async {
    final (storeId, staffId, customerId) = await seedBase();
    final productId = await seedProduct(storeId);

    // Goods ₦1,000; the customer tenders ₦1,500 (₦500 over).
    await sell(storeId, staffId, customerId, productId,
        qty: 1, method: 'cash', paidKobo: 150000);

    final sale = await onlyRow('sale');
    expect(sale!.amountKobo, 100000,
        reason: 'the sale row is the goods amount, not the full tender');
    final topup = await onlyRow('wallet_topup');
    expect(topup!.amountKobo, 50000, reason: 'the excess is the customer credit');
    expect(topup.method, 'cash');
    expect(topup.orderId, isNotNull);
    expect(await onlyRow('crate_deposit'), isNull);

    // The three rows sum to the amount paid — no cash created or lost.
    final rows = await (db.select(db.paymentTransactions)
          ..where((p) => p.orderId.equals(sale.orderId!)))
        .get();
    expect(rows.fold<int>(0, (s, r) => s + r.amountKobo), 150000);
  });
}
