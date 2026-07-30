import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

/// #162 (PRD #156, ADR 0020) — **Cancel completes the crate ledger.** When a
/// sale that issued crates or held a crate deposit is cancelled, the Crate Pool
/// seam must complete the ledger so a refunded sale leaves:
///   1. **no phantom crate debt** — a crate-track sale's `issued` rows are
///      reversed with compensating rows, so the customer's *derived* crate debt
///      ([CratePoolDao.watchCustomerCrateDebt]) returns to its pre-sale value;
///   2. **a correctly-deflated deposit** — a money-track sale's held
///      `crate_deposit` wallet leg is reversed with a **deposit-family**
///      reference type (one of [kCrateDepositReferenceTypes]), NOT the generic
///      `'void'`, so "deposits held" deflates to 0 and the customer's spendable
///      balance is not wrongly docked (mirrors the wallet's compensating-entry
///      void model).
///
/// The suite drives the full Checkout → Cancel path through `OrdersDao`
/// (`createOrder` → `markCancelled`) — the A1 regression named in the PRD's
/// Testing Decisions.
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

  // The customer's DERIVED crate debt per manufacturer (SUM over the ledger).
  Future<Map<String, int>> debt(String customerId) async {
    final rows =
        await db.cratePoolDao.watchCustomerCrateDebt(customerId).first;
    return {for (final r in rows) r.manufacturerId: r.balance};
  }

  Future<List<String>> queuedActionTypes() async {
    final rows = await db.select(db.syncQueue).get();
    return rows.map((r) => r.actionType).toList();
  }

  group('AC1 — cancelling a crate-track sale leaves no phantom crate debt', () {
    test('the customer derived crate debt returns to its pre-sale value',
        () async {
      final (storeId, staffId, customerId) = await seedBase();
      final (mfrId, productId) = await seedCrateProduct(storeId);

      // Pre-sale: the customer owes no crates.
      expect(await debt(customerId), isEmpty);

      // A crate-track sale (no deposit) issues 5 crates against the customer.
      final orderId = await sell(storeId, staffId, customerId, productId, 5);
      expect((await debt(customerId))[mfrId], 5,
          reason: '5 crates issued at sale');

      await db.ordersDao
          .markCancelled(orderId, 'customer changed mind', staffId);

      // The compensating rows net the derived debt back to its pre-sale value:
      // no phantom debt for crates the customer never actually kept.
      expect((await debt(customerId))[mfrId] ?? 0, 0,
          reason: 'cancel completes the ledger — derived debt back to pre-sale');
    });

    test(
        'the compensating crate row syncs (only ledger rows, never the cache)',
        () async {
      final (storeId, staffId, customerId) = await seedBase();
      final (mfrId, productId) = await seedCrateProduct(storeId);

      await sell(storeId, staffId, customerId, productId, 5);
      final orderId = await (db.select(db.orders)
            ..where((o) => o.customerId.equals(customerId)))
          .getSingle()
          .then((o) => o.id);
      // The sale enqueued exactly one crate_ledger row (the 'issued' leg).
      expect(
          (await queuedActionTypes())
              .where((t) => t == 'crate_ledger:upsert')
              .length,
          1);

      await db.ordersDao.markCancelled(orderId, 'refund', staffId);

      final types = await queuedActionTypes();
      // The cancel appended AND enqueued the compensating crate_ledger row so
      // peers converge (a cancel reverses a sale the cloud ACCEPTED — unlike the
      // rejected-sale reversal, which is local-only).
      expect(types.where((t) => t == 'crate_ledger:upsert').length, 2,
          reason: 'issue + cancel-reversal ledger rows both sync');
      // The demoted cache is a local-only projection — never pushed (#158).
      expect(types, isNot(contains('customer_crate_balances:upsert')));
      // The compensating row is a system 'adjusted' correction, not a phantom
      // customer 'returned' movement.
      final reversal = await (db.select(db.crateLedger)
            ..where((l) =>
                l.referenceOrderId.equals(orderId) &
                l.movementType.equals('adjusted')))
          .get();
      expect(reversal, hasLength(1));
      expect(reversal.single.quantityDelta, -5);
      expect(reversal.single.customerId, customerId);
      expect(reversal.single.manufacturerId, mfrId);
    });
  });

  group(
      'AC2 — cancelling a money-track deposit sale releases the held deposit',
      () {
    test('deposits-held deflates to 0 and the spendable balance is unaffected',
        () async {
      final (storeId, staffId, customerId) = await seedBase();
      final (mfrId, productId) = await seedCrateProduct(storeId);

      // A money-track sale: the customer pays a ₦500 deposit held for the brand.
      final orderId = await sell(storeId, staffId, customerId, productId, 1,
          deposits: {mfrId: 50000});

      expect(await db.walletTransactionsDao.getDepositsHeldKobo(customerId),
          50000,
          reason: 'the sale holds the deposit');
      expect(await db.walletTransactionsDao.getBalanceKobo(customerId), 0,
          reason: 'fully paid: spendable nets to 0');
      // A money-track brand issues NO customer crate balance (only the deposit).
      expect(await debt(customerId), isEmpty);

      await db.ordersDao.markCancelled(orderId, 'refund', staffId);

      expect(await db.walletTransactionsDao.getDepositsHeldKobo(customerId), 0,
          reason: 'the held deposit is released — "deposits held" deflates');
      expect(await db.walletTransactionsDao.getBalanceKobo(customerId), 0,
          reason:
              'spendable untouched — the release is NOT a generic void debit');
    });

    test(
        'the held crate_deposit leg is reversed with a deposit-family reference '
        'type, never the generic void', () async {
      final (storeId, staffId, customerId) = await seedBase();
      final (mfrId, productId) = await seedCrateProduct(storeId);

      final orderId = await sell(storeId, staffId, customerId, productId, 1,
          deposits: {mfrId: 50000});
      await db.ordersDao.markCancelled(orderId, 'refund', staffId);

      final legs = await (db.select(db.walletTransactions)
            ..where((t) => t.orderId.equals(orderId)))
          .get();

      // The original held credit and its reversal are BOTH in the deposit
      // family, so they cancel under the "deposits held" sum.
      final depositFamily = legs
          .where((l) => kCrateDepositReferenceTypes.contains(l.referenceType))
          .toList();
      expect(depositFamily.map((l) => l.referenceType).toSet(),
          containsAll(['crate_deposit', 'crate_deposit_refunded']),
          reason: 'held via crate_deposit, released via crate_deposit_refunded');

      // The ₦500 held deposit must NEVER be released via a generic 'void' debit
      // (that lands in the spendable bucket and docks the customer wrongly).
      final voidReleaseOfDeposit = legs
          .where((l) => l.referenceType == 'void' && l.amountKobo == 50000)
          .toList();
      expect(voidReleaseOfDeposit, isEmpty,
          reason: 'the deposit is not reversed with the generic void type');
    });
  });
}
