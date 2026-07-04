import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart'
    show SaleSyncException;
import 'package:reebaplus_pos/shared/services/orders/crate_return_input.dart';
import 'package:reebaplus_pos/shared/services/orders/order_commands.dart';
import 'package:reebaplus_pos/shared/services/orders/order_service.dart';
import 'package:reebaplus_pos/shared/services/orders/sale_flusher.dart';

import '../helpers/dispatch_test_utils.dart';

/// A [SaleFlusher] whose foreground flush always reports a permanent server
/// rejection — drives the checkout reject→compensate path without a network.
class _RejectingFlusher implements SaleFlusher {
  @override
  bool get canFlush => true;

  @override
  Future<void> flushSale(String orderId) async =>
      throw SaleSyncException(orderId: orderId, errorMessage: 'insufficient_stock');
}

/// Focused characterization tests for the Order module extraction (ADR 0004).
/// The broad suite is the equivalence net for the mechanical move; these pin the
/// two highest-drift-risk behaviours the extraction actually reshaped:
///
///  1. **Checkout payment-type / wallet-debit resolution** — the money-semantics
///     logic that moved from `OrderService` into `OrderCommands`.
///  2. **Confirm = settle-then-complete** — the crate-return settlement that
///     moved off the UI (`CrateReturnModal`) into `OrderCommands.confirm`.
void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    // Use the local (v1) record-sale path so createOrder writes order_crate_lines
    // itself instead of deferring to the cloud RPC.
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
  });

  tearDown(() => db.close());

  Future<(String storeId, String staffId, String customerId)> seedBase() async {
    final storeId = UuidV7.generate();
    await db.into(db.stores).insert(
          StoresCompanion.insert(
              id: Value(storeId), businessId: businessId, name: 'Main'),
        );
    final staffId = UuidV7.generate();
    await db.into(db.users).insert(
          UsersCompanion.insert(
              id: Value(staffId),
              businessId: businessId,
              name: 'Cashier',
              pin: '0000'),
        );
    final customerId = await db.customersDao.addCustomer(
      CustomersCompanion.insert(businessId: businessId, name: 'Buyer'),
    );
    return (storeId, staffId, customerId);
  }

  // A plain (non-crate) product with inventory.
  Future<String> seedProduct(String storeId) async {
    final productId = UuidV7.generate();
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: Value(productId),
            businessId: businessId,
            name: 'Cola',
            retailerPriceKobo: const Value(100000),
            unit: const Value('Piece'),
          ),
        );
    await db.into(db.inventory).insert(
          InventoryCompanion.insert(
            businessId: businessId,
            productId: productId,
            storeId: storeId,
            quantity: const Value(100),
          ),
        );
    return productId;
  }

  List<Map<String, dynamic>> cartOf(String productId, int qty) => [
        {
          'id': productId,
          'qty': qty,
          'unitPriceKobo': 100000,
          'name': 'Cola',
        },
      ];

  Future<OrderData> orderByNumber(String number) => (db.select(db.orders)
        ..where((o) => o.orderNumber.equals(number)))
      .getSingle();

  group('Checkout — payment-type & wallet-debit resolution', () {
    test('full cash (paid == total) → cash, no wallet debit', () async {
      final (storeId, staffId, customerId) = await seedBase();
      final productId = await seedProduct(storeId);
      final svc = OrderService(db);

      final number = await svc.addOrder(
        customerId: null,
        cart: cartOf(productId, 1),
        totalAmountKobo: 100000,
        amountPaidKobo: 100000,
        paymentType: 'cash',
        staffId: staffId,
        storeId: storeId,
        paymentSubType: 'cash',
      );

      expect((await orderByNumber(number)).paymentType, 'cash');
      // Untouched customer wallet stays at 0.
      expect(await db.walletTransactionsDao.getBalanceKobo(customerId), 0);
    });

    test('partial (0 < paid < total) → mixed, wallet debited the remainder',
        () async {
      final (storeId, staffId, customerId) = await seedBase();
      final productId = await seedProduct(storeId);
      final svc = OrderService(db);

      final number = await svc.addOrder(
        customerId: customerId,
        cart: cartOf(productId, 1),
        totalAmountKobo: 100000,
        amountPaidKobo: 60000,
        paymentType: 'cash',
        staffId: staffId,
        storeId: storeId,
        paymentSubType: 'cash',
      );

      expect((await orderByNumber(number)).paymentType, 'mixed');
      // Remainder (100000 − 60000) came out of the credit balance.
      expect(await db.walletTransactionsDao.getBalanceKobo(customerId), -40000);
    });

    test('wallet sub-type → wallet, full total debited', () async {
      final (storeId, staffId, customerId) = await seedBase();
      final productId = await seedProduct(storeId);
      final svc = OrderService(db);

      final number = await svc.addOrder(
        customerId: customerId,
        cart: cartOf(productId, 1),
        totalAmountKobo: 100000,
        amountPaidKobo: 0,
        paymentType: 'wallet',
        staffId: staffId,
        storeId: storeId,
        paymentSubType: 'wallet',
      );

      expect((await orderByNumber(number)).paymentType, 'wallet');
      expect(await db.walletTransactionsDao.getBalanceKobo(customerId), -100000);
    });

    test('nothing paid, no existing credit → credit sale, full total debited',
        () async {
      final (storeId, staffId, customerId) = await seedBase();
      final productId = await seedProduct(storeId);
      final svc = OrderService(db);

      final number = await svc.addOrder(
        customerId: customerId,
        cart: cartOf(productId, 1),
        totalAmountKobo: 100000,
        amountPaidKobo: 0,
        paymentType: 'cash',
        staffId: staffId,
        storeId: storeId,
        paymentSubType: 'cash',
        walletBalanceKobo: 0,
      );

      expect((await orderByNumber(number)).paymentType, 'credit');
      expect(await db.walletTransactionsDao.getBalanceKobo(customerId), -100000);
    });
  });

  group('Confirm — settle crate returns, then complete', () {
    test('money-track full return: deposit refunded to credit, empties '
        'restocked, and the order flips to completed', () async {
      // Crate business + a bottle brand with a per-crate deposit.
      await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
          .write(const BusinessesCompanion(type: Value('Bar')));
      final (storeId, staffId, customerId) = await seedBase();

      const rateKobo = 50000; // deposit per crate
      final mfrId = UuidV7.generate();
      await db.into(db.manufacturers).insert(
            ManufacturersCompanion.insert(
              id: Value(mfrId),
              businessId: businessId,
              name: 'Star',
              depositAmountKobo: const Value(rateKobo),
            ),
          );
      final productId = UuidV7.generate();
      await db.into(db.products).insert(
            ProductsCompanion.insert(
              id: Value(productId),
              businessId: businessId,
              name: 'Star Bottle',
              retailerPriceKobo: const Value(100000),
              manufacturerId: Value(mfrId),
              unit: const Value('Bottle'),
              trackEmpties: const Value(true),
            ),
          );
      await db.into(db.inventory).insert(
            InventoryCompanion.insert(
              businessId: businessId,
              productId: productId,
              storeId: storeId,
              quantity: const Value(100),
            ),
          );

      // Sell 5 crates with the full deposit held (money-track).
      const crates = 5;
      const depositKobo = rateKobo * crates; // 250000
      const goodsKobo = 100000 * crates; // 500000
      final orderId = await db.ordersDao.createOrder(
        order: OrdersCompanion.insert(
          businessId: businessId,
          orderNumber: 'ORD-${UuidV7.generate()}',
          customerId: Value(customerId),
          totalAmountKobo: goodsKobo + depositKobo,
          netAmountKobo: goodsKobo + depositKobo,
          amountPaidKobo: const Value(goodsKobo + depositKobo),
          paymentType: 'cash',
          status: 'pending',
          staffId: Value(staffId),
          storeId: Value(storeId),
        ),
        items: [
          OrderItemsCompanion.insert(
            businessId: businessId,
            orderId: 'placeholder',
            productId: Value(productId),
            storeId: storeId,
            quantity: crates,
            unitPriceKobo: 100000,
            totalKobo: goodsKobo,
          ),
        ],
        customerId: customerId,
        amountPaidKobo: goodsKobo + depositKobo,
        totalAmountKobo: goodsKobo + depositKobo,
        staffId: staffId,
        storeId: storeId,
        crateDepositPaidByManufacturer: {mfrId: depositKobo},
      );

      // Confirm with a full return — the consolidated command settles the
      // deposit and flips the status in one call.
      await OrderService(db).markAsCompleted(
        orderId,
        staffId,
        customerId: customerId,
        storeId: storeId,
        crateReturns: [
          CrateReturnLine(
            manufacturerId: mfrId,
            takenCrates: crates,
            returnedCrates: crates,
            rateKobo: rateKobo,
            paidKobo: depositKobo,
          ),
        ],
        refundAsCash: false,
      );

      // 1. Status flipped.
      final order =
          await (db.select(db.orders)..where((o) => o.id.equals(orderId)))
              .getSingle();
      expect(order.status, 'completed');
      expect(order.completedAt, isNotNull);

      // 2. Deposit refunded to the credit balance (settle ran).
      final refund = await (db.select(db.walletTransactions)
            ..where((t) =>
                t.orderId.equals(orderId) &
                t.referenceType.equals('crate_refund')))
          .getSingleOrNull();
      expect(refund, isNotNull, reason: 'a crate_refund credit leg was posted');
      expect(refund!.signedAmountKobo, depositKobo);

      // 3. Physical empties restocked.
      final mfr =
          await (db.select(db.manufacturers)..where((m) => m.id.equals(mfrId)))
              .getSingle();
      expect(mfr.emptyCrateStock, crates);
    });

    test('a crate-settle failure aborts before the status flip — order stays '
        'pending', () async {
      final (storeId, staffId, _) = await seedBase();

      // A customer with NO wallet: the money-track settle throws when it looks
      // the wallet up, which must happen BEFORE the status flip.
      final walletlessId = UuidV7.generate();
      await db.into(db.customers).insert(
            CustomersCompanion.insert(
              id: Value(walletlessId),
              businessId: businessId,
              name: 'No Wallet',
            ),
          );

      // A bare pending order to (not) flip.
      final orderId = UuidV7.generate();
      await db.into(db.orders).insert(
            OrdersCompanion.insert(
              id: Value(orderId),
              businessId: businessId,
              orderNumber: 'ORD-${UuidV7.generate()}',
              customerId: Value(walletlessId),
              totalAmountKobo: 100000,
              netAmountKobo: 100000,
              amountPaidKobo: const Value(100000),
              paymentType: 'cash',
              status: 'pending',
              staffId: Value(staffId),
              storeId: Value(storeId),
            ),
          );

      await expectLater(
        OrderService(db).markAsCompleted(
          orderId,
          staffId,
          customerId: walletlessId,
          storeId: storeId,
          crateReturns: [
            CrateReturnLine(
              manufacturerId: UuidV7.generate(),
              takenCrates: 1,
              returnedCrates: 0,
              rateKobo: 50000,
              paidKobo: 50000, // money-track → settle runs → wallet lookup fails
            ),
          ],
        ),
        throwsA(isA<StateError>()),
      );

      final order =
          await (db.select(db.orders)..where((o) => o.id.equals(orderId)))
              .getSingle();
      expect(order.status, 'pending',
          reason: 'settle threw before markCompleted could flip the status');
      expect(order.completedAt, isNull);
    });
  });

  group('Checkout — server rejection compensates locally', () {
    test('a permanent flush rejection cancels the order and refunds inventory',
        () async {
      final (storeId, staffId, _) = await seedBase();
      final productId = await seedProduct(storeId); // inventory seeded at 100
      final cmds = OrderCommands(db, _RejectingFlusher());

      await expectLater(
        cmds.checkout(
          customerId: null,
          cart: cartOf(productId, 1),
          totalAmountKobo: 100000,
          amountPaidKobo: 100000,
          paymentType: 'cash',
          staffId: staffId,
          storeId: storeId,
          paymentSubType: 'cash',
        ),
        throwsA(isA<SaleSyncException>()),
      );

      // The order was created, then compensated: cancelled + stock restored.
      final order = await db.select(db.orders).getSingle();
      expect(order.status, 'cancelled');
      expect(order.cancellationReason, 'rejected_by_server');

      final inv = await (db.select(db.inventory)
            ..where((i) => i.productId.equals(productId)))
          .getSingle();
      expect(inv.quantity, 100, reason: 'optimistic deduction was refunded');
    });
  });
}
