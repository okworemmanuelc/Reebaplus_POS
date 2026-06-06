import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/orders/widgets/crate_return_modal.dart'
    show allocateLegacyDeposit;

import '../helpers/dispatch_test_utils.dart';

/// §13.4 Ring 4 — the fix for the "returned everything but still shows owing"
/// bug. Before this, customer_crate_balances was ONLY ever decremented (on
/// return); nothing recorded the crates a customer TOOK at the sale, so
/// `returned == taken` could never net to zero. createOrder now records an
/// 'issued' ledger row + balance increment per brand, and the existing return
/// path nets it back to zero.
void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    // §13.4 / rule #13 — crate tracking only runs for Bar / Beer Distributor
    // businesses (createOrder guards on it). The bootstrap business has no type;
    // stamp it 'Bar' so the crate-issue path under test actually runs.
    await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
        .write(const BusinessesCompanion(type: Value('Bar')));
  });

  tearDown(() => db.close());

  // Seeds store + staff + customer (wallet auto-created) and returns their ids.
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

  // Seeds a manufacturer + a crate-tracked bottle product (+inventory) and
  // returns (manufacturerId, productId).
  Future<(String, String)> seedCrateProduct(String storeId,
      {bool trackEmpties = true, String unit = 'Bottle'}) async {
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
        unit: Value(unit),
        trackEmpties: Value(trackEmpties)));
    await db.into(db.inventory).insert(InventoryCompanion.insert(
        businessId: businessId,
        productId: productId,
        storeId: storeId,
        quantity: const Value(100)));
    return (manufacturerId, productId);
  }

  Future<int?> crateBalance(String customerId, String manufacturerId) async {
    final row = await (db.select(db.customerCrateBalances)
          ..where((t) =>
              t.customerId.equals(customerId) &
              t.manufacturerId.equals(manufacturerId)))
        .getSingleOrNull();
    return row?.balance;
  }

  Future<String> sell(
    String storeId,
    String staffId,
    String customerId,
    String productId,
    int qty, {
    Map<String, int> deposits = const {},
  }) async {
    // New checkout convention (§13.4 Ring 3): the grand total the customer
    // settles = goods + the deposit held. amountPaid covers both; createOrder
    // carves the deposit slice into a held `crate_deposit` leg.
    final goodsKobo = qty * 100000;
    final depositKobo = deposits.values.fold<int>(0, (s, v) => s + v);
    final grandKobo = goodsKobo + depositKobo;
    return db.ordersDao.createOrder(
      order: OrdersCompanion.insert(
        businessId: businessId,
        // Full UUID — substring(0,6) is the v7 timestamp prefix and collides
        // for sells in the same millisecond (the Ring 7 test sells 3× rapidly).
        orderNumber: 'ORD-${UuidV7.generate()}',
        customerId: Value(customerId),
        totalAmountKobo: grandKobo,
        netAmountKobo: grandKobo,
        amountPaidKobo: Value(grandKobo),
        paymentType: 'cash',
        status: 'completed',
        staffId: Value(staffId),
        storeId: Value(storeId),
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
      amountPaidKobo: grandKobo,
      totalAmountKobo: grandKobo,
      staffId: staffId,
      storeId: storeId,
      crateDepositPaidByManufacturer: deposits,
    );
  }

  group('recordCrateIssueByCustomer (the dispatch half)', () {
    test('issue +N then return N nets the balance to 0 (not owing)', () async {
      final (storeId, staffId, customerId) = await seedBase();
      final (mfrId, _) = await seedCrateProduct(storeId);

      await db.crateLedgerDao.recordCrateIssueByCustomer(
          customerId: customerId,
          manufacturerId: mfrId,
          quantity: 10,
          performedBy: staffId);
      expect(await crateBalance(customerId, mfrId), 10, reason: '10 owed');

      await db.crateLedgerDao.recordCrateReturnByCustomer(
          customerId: customerId,
          manufacturerId: mfrId,
          quantity: 10,
          performedBy: staffId);
      expect(await crateBalance(customerId, mfrId), 0,
          reason: 'returned == taken -> not owing');
    });

    test('a short return leaves the shortage as crate debt', () async {
      final (storeId, staffId, customerId) = await seedBase();
      final (mfrId, _) = await seedCrateProduct(storeId);

      await db.crateLedgerDao.recordCrateIssueByCustomer(
          customerId: customerId,
          manufacturerId: mfrId,
          quantity: 10,
          performedBy: staffId);
      await db.crateLedgerDao.recordCrateReturnByCustomer(
          customerId: customerId,
          manufacturerId: mfrId,
          quantity: 7,
          performedBy: staffId);
      expect(await crateBalance(customerId, mfrId), 3, reason: '3 still owed');
    });
  });

  group('createOrder records crates issued at sale', () {
    test('a crate-tracked sale to a registered customer increments the balance, '
        'and a full return nets it to 0', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
      final (storeId, staffId, customerId) = await seedBase();
      final (mfrId, productId) = await seedCrateProduct(storeId);

      await sell(storeId, staffId, customerId, productId, 5);
      expect(await crateBalance(customerId, mfrId), 5,
          reason: '5 crates issued at sale');

      // The issued ledger row exists.
      final issued = await (db.select(db.crateLedger)
            ..where((t) => t.movementType.equals('issued')))
          .get();
      expect(issued, hasLength(1));
      expect(issued.first.quantityDelta, 5);
      expect(issued.first.customerId, customerId);
      expect(issued.first.manufacturerId, mfrId);

      // Returning all 5 nets to "not owing".
      await db.crateLedgerDao.recordCrateReturnByCustomer(
          customerId: customerId,
          manufacturerId: mfrId,
          quantity: 5,
          performedBy: staffId);
      expect(await crateBalance(customerId, mfrId), 0);
    });

    test('the enqueued order_crate_lines upsert carries the SAME id as the '
        'local row (no local/cloud id divergence → no 2067 on echo)', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
      final (storeId, staffId, customerId) = await seedBase();
      final (_, productId) = await seedCrateProduct(storeId);

      final orderId = await sell(storeId, staffId, customerId, productId, 5);

      final localRow = await (db.select(db.orderCrateLines)
            ..where((t) => t.orderId.equals(orderId)))
          .getSingle();
      final queued = await (db.select(db.syncQueue)
            ..where((t) => t.actionType.equals('order_crate_lines:upsert')))
          .get();
      expect(queued, hasLength(1));
      final payload = jsonDecode(queued.first.payload) as Map<String, dynamic>;
      expect(payload['id'], isA<String>());
      expect(payload['id'], localRow.id,
          reason: 'enqueued id must equal the local id, else the cloud mints a '
              'new id and its echo collides on the natural-key UNIQUE');
    });

    test('a NON-crate product (trackEmpties off) issues no crate balance',
        () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
      final (storeId, staffId, customerId) = await seedBase();
      final (mfrId, productId) =
          await seedCrateProduct(storeId, trackEmpties: false);

      await sell(storeId, staffId, customerId, productId, 5);
      expect(await crateBalance(customerId, mfrId), isNull,
          reason: 'no crate tracking -> no balance row');
      expect(await db.select(db.crateLedger).get(), isEmpty);
    });

    test('rule #13 — a NON-crate business writes NO crate data even for a '
        'bottle+trackEmpties product', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
      // Flip the business to a non-crate type for this case.
      await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
          .write(const BusinessesCompanion(type: Value('Supermarket')));
      final (storeId, staffId, customerId) = await seedBase();
      final (mfrId, productId) = await seedCrateProduct(storeId);

      await sell(storeId, staffId, customerId, productId, 5);

      expect(await crateBalance(customerId, mfrId), isNull,
          reason: 'non-crate business never accrues a crate balance');
      expect(await db.select(db.crateLedger).get(), isEmpty);
      expect(await db.select(db.orderCrateLines).get(), isEmpty,
          reason: 'no order_crate_lines for a non-crate business');
    });

    test('a walk-in (no customer) issues no crate balance', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
      final (storeId, staffId, _) = await seedBase();
      final (_, productId) = await seedCrateProduct(storeId);

      await db.ordersDao.createOrder(
        order: OrdersCompanion.insert(
          businessId: businessId,
          orderNumber: 'ORD-WALKIN',
          totalAmountKobo: 200000,
          netAmountKobo: 200000,
          amountPaidKobo: const Value(200000),
          paymentType: 'cash',
          status: 'completed',
          staffId: Value(staffId),
          storeId: Value(storeId),
        ),
        items: [
          OrderItemsCompanion.insert(
            businessId: businessId,
            orderId: 'placeholder',
            productId: Value(productId),
            storeId: storeId,
            quantity: 2,
            unitPriceKobo: 100000,
            totalKobo: 200000,
          ),
        ],
        customerId: null,
        amountPaidKobo: 200000,
        totalAmountKobo: 200000,
        staffId: staffId,
        storeId: storeId,
      );

      expect(await db.select(db.customerCrateBalances).get(), isEmpty);
      expect(await db.select(db.crateLedger).get(), isEmpty);
    });

    test('writes an order_crate_lines row with crates + manufacturer rate '
        'snapshot (deposit 0 when none captured)', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
      final (storeId, staffId, customerId) = await seedBase();
      final (mfrId, productId) = await seedCrateProduct(storeId);

      final orderId = await sell(storeId, staffId, customerId, productId, 5);
      final line = await (db.select(db.orderCrateLines)
            ..where((t) => t.orderId.equals(orderId)))
          .getSingle();
      expect(line.manufacturerId, mfrId);
      expect(line.cratesTaken, 5);
      expect(line.depositRateKobo, 50000,
          reason: 'rate snapshot from Manufacturers.depositAmountKobo');
      expect(line.depositPaidKobo, 0);
    });

    test('a brand paid for in money (deposit) records NO crate balance, but the '
        'deposit + crates land on order_crate_lines', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
      final (storeId, staffId, customerId) = await seedBase();
      final (mfrId, productId) = await seedCrateProduct(storeId);

      // Full deposit paid: 5 crates × 50000 = 250000 (money-track).
      final orderId = await sell(storeId, staffId, customerId, productId, 5,
          deposits: {mfrId: 250000});

      expect(await crateBalance(customerId, mfrId), isNull,
          reason: 'money-track brand holds no crate balance (decision 5)');
      expect(
          await (db.select(db.crateLedger)
                ..where((t) => t.movementType.equals('issued')))
              .get(),
          isEmpty,
          reason: 'no issued ledger row for a money-track brand');

      final line = await (db.select(db.orderCrateLines)
            ..where((t) => t.orderId.equals(orderId)))
          .getSingle();
      expect(line.cratesTaken, 5);
      expect(line.depositPaidKobo, 250000);
    });

    test('Ring 6 — a paid deposit posts a held crate_deposit leg; spendable '
        'net is 0 and deposits-held equals the deposit', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
      final (storeId, staffId, customerId) = await seedBase();
      final (mfrId, productId) = await seedCrateProduct(storeId);

      // 5 × ₦1000 goods = ₦500,000; full deposit 5 × ₦500 = ₦250,000.
      final orderId =
          await sell(storeId, staffId, customerId, productId, 5,
              deposits: {mfrId: 250000});

      // Held leg present and labelled.
      final held = await (db.select(db.walletTransactions)
            ..where((t) =>
                t.orderId.equals(orderId) &
                t.referenceType.equals('crate_deposit')))
          .get();
      expect(held, hasLength(1));
      expect(held.first.signedAmountKobo, 250000);

      // Goods debit excludes the deposit (= ₦500,000, not ₦750,000).
      final debit = await (db.select(db.walletTransactions)
            ..where((t) =>
                t.orderId.equals(orderId) &
                t.referenceType.equals('order_payment')))
          .getSingle();
      expect(debit.signedAmountKobo, -500000);

      // Spendable balance nets to 0 (deposit excluded); held = ₦250,000.
      expect(await db.walletTransactionsDao.getBalanceKobo(customerId), 0,
          reason: 'goods debit ₦500k + goods credit ₦500k; deposit excluded');
      expect(
          await db.walletTransactionsDao.getDepositsHeldKobo(customerId),
          250000);
    });

    test('Ring 6 — a no-deposit sale posts only the two goods legs (no held '
        'leg), behaviour unchanged', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
      final (storeId, staffId, customerId) = await seedBase();
      final (_, productId) = await seedCrateProduct(storeId);

      final orderId = await sell(storeId, staffId, customerId, productId, 5);

      expect(
          await (db.select(db.walletTransactions)
                ..where((t) =>
                    t.orderId.equals(orderId) &
                    t.referenceType.equals('crate_deposit')))
              .get(),
          isEmpty);
      expect(await db.walletTransactionsDao.getDepositsHeldKobo(customerId), 0);
      expect(await db.walletTransactionsDao.getBalanceKobo(customerId), 0);
    });
  });

  group('wallet netting excludes the crate-deposit family (decision 13)', () {
    Future<void> addWalletRow(
      String walletId,
      String customerId,
      String referenceType,
      int signed,
    ) async {
      await db.into(db.walletTransactions).insert(
            WalletTransactionsCompanion.insert(
              businessId: businessId,
              walletId: walletId,
              customerId: customerId,
              type: signed >= 0 ? 'credit' : 'debit',
              amountKobo: signed.abs(),
              signedAmountKobo: signed,
              referenceType: referenceType,
            ),
          );
    }

    test('spendable balance excludes deposits; deposits-held sums them; a '
        'forfeit/refund debit nets held back to 0', () async {
      final (_, _, customerId) = await seedBase();
      final wallet = await (db.select(db.customerWallets)
            ..where((w) => w.customerId.equals(customerId)))
          .getSingle();

      await addWalletRow(wallet.id, customerId, 'topup_cash', 1000);
      await addWalletRow(wallet.id, customerId, 'crate_deposit', 500);

      expect(await db.walletTransactionsDao.getBalanceKobo(customerId), 1000,
          reason: 'deposit excluded from spendable');
      expect(await db.walletTransactionsDao.getDepositsHeldKobo(customerId), 500);

      // A general (spendable) credit IS counted in the balance.
      await addWalletRow(wallet.id, customerId, 'crate_refund', 200);
      expect(await db.walletTransactionsDao.getBalanceKobo(customerId), 1200);
      expect(await db.walletTransactionsDao.getDepositsHeldKobo(customerId), 500,
          reason: 'crate_refund is spendable, not part of held');

      // Forfeiting the deposit nets held back to 0; spendable unchanged.
      await addWalletRow(
          wallet.id, customerId, 'crate_deposit_forfeited', -500);
      expect(await db.walletTransactionsDao.getDepositsHeldKobo(customerId), 0);
      expect(await db.walletTransactionsDao.getBalanceKobo(customerId), 1200);
    });
  });

  group('Ring 5 — settleCrateDepositReturn (money-track return settlement)', () {
    // Each case sells with a deposit (posts the held leg) then settles the
    // return, asserting the held deposit resolves to 0 and spendable/cash land
    // where they should. Rate ₦500/crate (50000 kobo), product ₦1000.
    Future<int> forfeited(String customerId) async {
      final rows = await (db.select(db.walletTransactions)
            ..where((t) =>
                t.customerId.equals(customerId) &
                t.referenceType.equals('crate_deposit_forfeited')))
          .get();
      return rows.fold<int>(0, (s, r) => s + r.signedAmountKobo);
    }

    test('full deposit, full return → wallet refund (held 0, spendable +full)',
        () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
      final (storeId, staffId, customerId) = await seedBase();
      final (mfrId, productId) = await seedCrateProduct(storeId);
      final orderId = await sell(storeId, staffId, customerId, productId, 5,
          deposits: {mfrId: 250000});

      await db.ordersDao.settleCrateDepositReturn(
        customerId: customerId,
        manufacturerId: mfrId,
        orderId: orderId,
        takenCrates: 5,
        returnedCrates: 5,
        rateKobo: 50000,
        paidKobo: 250000,
        refundAsCash: false,
        performedBy: staffId,
      );

      expect(await db.walletTransactionsDao.getDepositsHeldKobo(customerId), 0,
          reason: 'held deposit fully resolved');
      expect(await db.walletTransactionsDao.getBalanceKobo(customerId), 250000,
          reason: 'returned everything → deposit back as spendable credit');
      expect(await forfeited(customerId), 0, reason: 'nothing kept');
    });

    test('the crate_refund credit sorts ABOVE its paired crate_deposit_refunded '
        'debit in wallet history (headline money-back reads first)', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
      final (storeId, staffId, customerId) = await seedBase();
      final (mfrId, productId) = await seedCrateProduct(storeId);
      final orderId = await sell(storeId, staffId, customerId, productId, 5,
          deposits: {mfrId: 250000});

      await db.ordersDao.settleCrateDepositReturn(
        customerId: customerId,
        manufacturerId: mfrId,
        orderId: orderId,
        takenCrates: 5,
        returnedCrates: 5,
        rateKobo: 50000,
        paidKobo: 250000,
        refundAsCash: false,
        performedBy: staffId,
      );

      final history =
          await db.walletTransactionsDao.watchHistory(customerId).first;
      final refundIdx =
          history.indexWhere((t) => t.referenceType == 'crate_refund');
      final refundedIdx =
          history.indexWhere((t) => t.referenceType == 'crate_deposit_refunded');
      expect(refundIdx, isNonNegative);
      expect(refundedIdx, isNonNegative);
      expect(refundIdx, lessThan(refundedIdx),
          reason: 'crate_refund (the +money-back) reads above its bookkeeping '
              'crate_deposit_refunded debit at the same timestamp');
      expect(history.first.referenceType, 'crate_refund',
          reason: 'and it is the very top (most recent) row');
    });

    test('full deposit, full return → cash refund (held 0, spendable 0, '
        'payment refund row)', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
      final (storeId, staffId, customerId) = await seedBase();
      final (mfrId, productId) = await seedCrateProduct(storeId);
      final orderId = await sell(storeId, staffId, customerId, productId, 5,
          deposits: {mfrId: 250000});

      await db.ordersDao.settleCrateDepositReturn(
        customerId: customerId,
        manufacturerId: mfrId,
        orderId: orderId,
        takenCrates: 5,
        returnedCrates: 5,
        rateKobo: 50000,
        paidKobo: 250000,
        refundAsCash: true,
        performedBy: staffId,
      );

      expect(await db.walletTransactionsDao.getDepositsHeldKobo(customerId), 0);
      expect(await db.walletTransactionsDao.getBalanceKobo(customerId), 0,
          reason: 'cash refund → no spendable wallet credit');
      final refunds = await (db.select(db.paymentTransactions)
            ..where((t) => t.type.equals('refund')))
          .get();
      expect(refunds, hasLength(1));
      expect(refunds.first.amountKobo, 250000);
      expect(refunds.first.method, 'cash');
    });

    test('full deposit, partial return → forfeit kept + refund rest', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
      final (storeId, staffId, customerId) = await seedBase();
      final (mfrId, productId) = await seedCrateProduct(storeId);
      final orderId = await sell(storeId, staffId, customerId, productId, 5,
          deposits: {mfrId: 250000});

      // Return 3 of 5: keep 2 (forfeit ₦100k), refund 3 (₦150k).
      await db.ordersDao.settleCrateDepositReturn(
        customerId: customerId,
        manufacturerId: mfrId,
        orderId: orderId,
        takenCrates: 5,
        returnedCrates: 3,
        rateKobo: 50000,
        paidKobo: 250000,
        refundAsCash: false,
        performedBy: staffId,
      );

      expect(await db.walletTransactionsDao.getDepositsHeldKobo(customerId), 0);
      expect(await db.walletTransactionsDao.getBalanceKobo(customerId), 150000,
          reason: 'refund for 3 returned crates → spendable credit');
      expect(await forfeited(customerId), -100000,
          reason: '2 kept crates × ₦500 forfeited (income)');
    });

    test('PART deposit, partial return → forfeit all paid + shortfall debt',
        () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
      final (storeId, staffId, customerId) = await seedBase();
      final (mfrId, productId) = await seedCrateProduct(storeId);
      // Part deposit: full would be ₦250k, only ₦100k paid.
      final orderId = await sell(storeId, staffId, customerId, productId, 5,
          deposits: {mfrId: 100000});
      expect(await db.walletTransactionsDao.getDepositsHeldKobo(customerId),
          100000);

      // Keep 3 (worth ₦150k deposit) — exceeds the ₦100k paid → ₦50k debt.
      await db.ordersDao.settleCrateDepositReturn(
        customerId: customerId,
        manufacturerId: mfrId,
        orderId: orderId,
        takenCrates: 5,
        returnedCrates: 2,
        rateKobo: 50000,
        paidKobo: 100000,
        refundAsCash: false,
        performedBy: staffId,
      );

      expect(await db.walletTransactionsDao.getDepositsHeldKobo(customerId), 0);
      expect(await forfeited(customerId), -100000,
          reason: 'the whole ₦100k held is forfeited');
      expect(await db.walletTransactionsDao.getBalanceKobo(customerId), -50000,
          reason: 'kept crates worth ₦150k − ₦100k paid → ₦50k wallet debt');
    });

    test('settling a money-track return does NOT create a crate balance',
        () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
      final (storeId, staffId, customerId) = await seedBase();
      final (mfrId, productId) = await seedCrateProduct(storeId);
      final orderId = await sell(storeId, staffId, customerId, productId, 5,
          deposits: {mfrId: 250000});

      await db.ordersDao.settleCrateDepositReturn(
        customerId: customerId,
        manufacturerId: mfrId,
        orderId: orderId,
        takenCrates: 5,
        returnedCrates: 4,
        rateKobo: 50000,
        paidKobo: 250000,
        refundAsCash: false,
        performedBy: staffId,
      );

      expect(await crateBalance(customerId, mfrId), isNull,
          reason: 'money-track never touches the crate ledger');
    });
  });

  group('Ring 7 — crate deposit balancing summary', () {
    test('held = taken − refunded − kept across sales + settlements', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
      final (storeId, staffId, customerId) = await seedBase();
      final (mfrId, productId) = await seedCrateProduct(storeId);

      // Order 1: ₦250k deposit, full return → all refunded.
      final o1 = await sell(storeId, staffId, customerId, productId, 5,
          deposits: {mfrId: 250000});
      await db.ordersDao.settleCrateDepositReturn(
        customerId: customerId,
        manufacturerId: mfrId,
        orderId: o1,
        takenCrates: 5,
        returnedCrates: 5,
        rateKobo: 50000,
        paidKobo: 250000,
        refundAsCash: false,
        performedBy: staffId,
      );

      // Order 2: ₦250k deposit, return 3/5 → keep 2 (forfeit ₦100k), refund ₦150k.
      final o2 = await sell(storeId, staffId, customerId, productId, 5,
          deposits: {mfrId: 250000});
      await db.ordersDao.settleCrateDepositReturn(
        customerId: customerId,
        manufacturerId: mfrId,
        orderId: o2,
        takenCrates: 5,
        returnedCrates: 3,
        rateKobo: 50000,
        paidKobo: 250000,
        refundAsCash: false,
        performedBy: staffId,
      );

      // Order 3: ₦200k deposit, NOT settled → still held.
      await sell(storeId, staffId, customerId, productId, 4,
          deposits: {mfrId: 200000});

      final s =
          await db.walletTransactionsDao.watchCrateDepositSummary().first;
      expect(s.takenKobo, 700000);
      expect(s.refundedKobo, 400000, reason: '₦250k + ₦150k refunded');
      expect(s.keptKobo, 100000, reason: '2 kept crates × ₦500 forfeited');
      expect(s.heldKobo, 200000, reason: 'only order 3 still held');
      expect(s.heldKobo, s.takenKobo - s.refundedKobo - s.keptKobo,
          reason: 'the balancing identity holds');

      final byCustomer =
          await db.walletTransactionsDao.watchDepositsHeldByCustomer().first;
      expect(byCustomer[customerId], 200000);
    });

    test('no deposits → all-zero summary, empty held-by-customer', () async {
      await seedBase();
      final s =
          await db.walletTransactionsDao.watchCrateDepositSummary().first;
      expect(s.takenKobo, 0);
      expect(s.heldKobo, 0);
      expect(
          await db.walletTransactionsDao.watchDepositsHeldByCustomer().first,
          isEmpty);
    });
  });

  // §13.4 reconciliation — a sale created by an older device may carry the held
  // `crate_deposit` wallet leg + the order's lump-sum `crateDepositPaidKobo`,
  // but NOT the per-brand `order_crate_lines` the return modal reads. The modal
  // fallback rebuilds the per-brand deposit from the order total so the held
  // deposit always has a settlement path and resolves to 0.
  group('legacy reconciliation — held deposit with no order_crate_lines', () {
    test('allocateLegacyDeposit splits the total EXACTLY across brands', () {
      // Single brand → the whole deposit.
      expect(allocateLegacyDeposit(250000, [250000]), [250000]);
      // Two brands weighted by full value — exact sum.
      final two = allocateLegacyDeposit(300000, [100000, 200000]);
      expect(two, [100000, 200000]);
      expect(two.fold<int>(0, (s, v) => s + v), 300000);
      // Rounding remainder lands on the last brand (still sums exactly).
      final r = allocateLegacyDeposit(100, [1, 1, 1]);
      expect(r.fold<int>(0, (s, v) => s + v), 100);
      expect(r.last, 34);
      // All-zero weights → even split, exact sum.
      expect(allocateLegacyDeposit(90, [0, 0, 0]).fold<int>(0, (s, v) => s + v),
          90);
      // No deposit / no brands → all zero.
      expect(allocateLegacyDeposit(0, [5, 5]), [0, 0]);
      expect(allocateLegacyDeposit(250000, <int>[]), <int>[]);
    });

    test('an orphaned held deposit (no lines) settles to 0 once reconstructed '
        'from the order total', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
      final (storeId, staffId, customerId) = await seedBase();
      final (mfrId, productId) = await seedCrateProduct(storeId);

      // Full deposit at sale → posts the held crate_deposit leg + lines.
      final orderId = await sell(storeId, staffId, customerId, productId, 5,
          deposits: {mfrId: 250000});
      expect(
          await db.walletTransactionsDao.getDepositsHeldKobo(customerId), 250000,
          reason: 'deposit held after the sale');

      // Simulate the OLD-device shape: the order recorded its lump-sum deposit,
      // but the per-brand order_crate_lines were never written.
      await (db.update(db.orders)..where((o) => o.id.equals(orderId)))
          .write(const OrdersCompanion(crateDepositPaidKobo: Value(250000)));
      await (db.delete(db.orderCrateLines)
            ..where((l) => l.orderId.equals(orderId)))
          .go();
      expect(await db.orderCrateLinesDao.getForOrder(orderId), isEmpty,
          reason: 'no lines — the modal must reconstruct from the order total');

      // Reconstruct exactly as the modal fallback does (single brand → all of
      // the recorded deposit, current manufacturer rate), then settle a full
      // return.
      final order = await (db.select(db.orders)
            ..where((o) => o.id.equals(orderId)))
          .getSingle();
      final mfr = await (db.select(db.manufacturers)
            ..where((m) => m.id.equals(mfrId)))
          .getSingle();
      final shares = allocateLegacyDeposit(
          order.crateDepositPaidKobo, [mfr.depositAmountKobo * 5]);

      await db.ordersDao.settleCrateDepositReturn(
        customerId: customerId,
        manufacturerId: mfrId,
        orderId: orderId,
        takenCrates: 5,
        returnedCrates: 5,
        rateKobo: mfr.depositAmountKobo,
        paidKobo: shares.first,
        refundAsCash: false,
        performedBy: staffId,
      );

      expect(await db.walletTransactionsDao.getDepositsHeldKobo(customerId), 0,
          reason: 'the orphaned held deposit is now fully resolved');
      expect(await db.walletTransactionsDao.getBalanceKobo(customerId), 250000,
          reason: 'returned everything → deposit back as spendable credit');
    });
  });
}
