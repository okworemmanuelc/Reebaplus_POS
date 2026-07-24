import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/utils/order_number.dart';

import '../helpers/dispatch_test_utils.dart';
import 'golden_scenario.dart';

/// Golden-Scenario Suite — the DART DAO side (ADR 0009, issue #43).
///
/// Runs the shared cash-sale fixtures (test/golden/fixtures/*.json) against the
/// mobile checkout money path (OrdersDao.createOrder + CostBatchesDao.drawDown
/// Sale) on an in-memory Drift DB. Offline and network-free, so it runs in EVERY
/// CI build. Its Tier-2 twin (test/integration/rpcs/checkout_order_golden_test)
/// runs the SAME fixtures against the SQL `checkout_order` RPC; any drift between
/// the two fails the build.
void main() {
  final scenarios = [...loadCashSaleScenarios(), ...loadCrateSaleScenarios()];
  for (final scenario in scenarios) {
    test('golden (dart dao): ${scenario.name}', () async {
      final boot = await bootstrapTestDb();
      final db = boot.db;
      final businessId = boot.businessId;
      addTearDown(db.close);

      // v1 record-sale path so createOrder writes order_items locally (the v2
      // path defers the line write to the cloud RPC response).
      await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);

      // ── Seed the input state ────────────────────────────────────────────────
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

      // Slice 4 (#45): crate scenarios set the business type (drives
      // isCrateBusiness) + the empties opt-in, and register the manufacturers
      // whose deposit rates the sale snapshots. bootstrapTestDb's business has a
      // null type, so a non-crate fixture leaves the crate gate closed.
      if (scenario.businessType != null) {
        await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
            .write(BusinessesCompanion(
          type: Value(scenario.businessType),
          tracksEmptyCrates: Value(scenario.tracksEmptyCrates),
        ));
      }
      final manufacturerIdByKey = <String, String>{};
      for (final m in scenario.manufacturers) {
        final id = UuidV7.generate();
        manufacturerIdByKey[m.key] = id;
        await db.into(db.manufacturers).insert(
              ManufacturersCompanion.insert(
                id: Value(id),
                businessId: businessId,
                name: m.name,
                depositAmountKobo: Value(m.depositRateKobo),
              ),
            );
      }

      // Slice 3 (#44): a registered customer + wallet, seeded with any opening
      // balance as one topup_cash credit BEFORE the sale (so Pay-with-Credit has
      // credit to draw). The opening leg carries no order_id, so the runner's
      // per-order leg collection below excludes it.
      String? customerId;
      if (scenario.customer != null) {
        customerId = UuidV7.generate();
        final walletId = UuidV7.generate();
        await db.into(db.customers).insert(
              CustomersCompanion.insert(
                id: Value(customerId),
                businessId: businessId,
                name: 'Credit Customer',
                walletLimitKobo: Value(scenario.customer!.debtLimitKobo),
              ),
            );
        await db.into(db.customerWallets).insert(
              CustomerWalletsCompanion.insert(
                id: Value(walletId),
                businessId: businessId,
                customerId: customerId,
              ),
            );
        if (scenario.customer!.openingBalanceKobo != 0) {
          await db.into(db.walletTransactions).insert(
                WalletTransactionsCompanion.insert(
                  id: Value(UuidV7.generate()),
                  businessId: businessId,
                  walletId: walletId,
                  customerId: customerId,
                  type: 'credit',
                  amountKobo: scenario.customer!.openingBalanceKobo,
                  signedAmountKobo: scenario.customer!.openingBalanceKobo,
                  referenceType: 'topup_cash',
                ),
              );
        }
      }

      final productIdByKey = <String, String>{};
      for (final p in scenario.products) {
        final id = UuidV7.generate();
        productIdByKey[p.key] = id;
        // A crate-eligible product (manufacturerKey set) is a returnable bottle
        // with empties tracking on; everything else is a plain 'Piece' product.
        final crateEligible = p.manufacturerKey != null;
        await db.into(db.products).insert(
              ProductsCompanion.insert(
                id: Value(id),
                businessId: businessId,
                name: p.name,
                retailerPriceKobo: Value(p.unitPriceKobo),
                buyingPriceKobo: Value(p.scalarCostKobo),
                unit: Value(crateEligible ? 'Bottle' : 'Piece'),
                trackEmpties: Value(crateEligible),
                manufacturerId: crateEligible
                    ? Value(manufacturerIdByKey[p.manufacturerKey]!)
                    : const Value.absent(),
              ),
            );
      }
      for (final inv in scenario.inventory) {
        await db.into(db.inventory).insert(
              InventoryCompanion.insert(
                businessId: businessId,
                productId: productIdByKey[inv.productKey]!,
                storeId: storeId,
                quantity: Value(inv.quantity),
              ),
            );
      }
      // batchId → (productKey, receivedAt) so remainders can be read back by key.
      final seededBatches = <(String, String, String)>[];
      for (final b in scenario.batches) {
        final id = UuidV7.generate();
        await db.into(db.costBatches).insert(
              CostBatchesCompanion.insert(
                id: Value(id),
                businessId: businessId,
                productId: productIdByKey[b.productKey]!,
                storeId: storeId,
                qtyRemaining: b.qty,
                qtyOriginal: b.qty,
                costKobo: Value(b.costKobo),
                receivedAt: Value(b.receivedAtUtc),
              ),
            );
        seededBatches.add((id, b.productKey, b.receivedAt));
      }

      // ── Perform the checkout the mobile way ────────────────────────────────
      final orderId = UuidV7.generate();
      final orderNumber =
          await db.ordersDao.generateOrderNumber(deviceOrderTag('golden-device'));

      var gross = 0;
      final items = <OrderItemsCompanion>[];
      for (final line in scenario.checkout.items) {
        final p = scenario.product(line.productKey);
        final total = p.unitPriceKobo * line.quantity;
        gross += total;
        items.add(OrderItemsCompanion.insert(
          businessId: businessId,
          orderId: orderId,
          productId: Value(productIdByKey[line.productKey]!),
          storeId: storeId,
          quantity: line.quantity,
          unitPriceKobo: p.unitPriceKobo,
          totalKobo: total,
        ));
      }
      // The role discount cap (§12.6/§13.2): clamp the requested discount to the
      // caller's percentage of gross, identical to the RPC's server-side clamp.
      final discount = clampDiscountKobo(
          scenario.checkout.discountKobo, scenario.maxDiscountPercent, gross);
      final net = gross - discount;

      // #175: the crate deposit paid at checkout, keyed by manufacturer id. Added
      // ON TOP of the goods total — the grand total the checkout passes is
      // goods + deposit, and createOrder carves the deposit into its own
      // `crate_deposit` payment row. 0 for the Slice 2–4 fixtures.
      final depositByMfrId = <String, int>{
        for (final e in scenario.checkout.depositPaidByManufacturer.entries)
          manufacturerIdByKey[e.key]!: e.value,
      };
      final depositTotal =
          depositByMfrId.values.fold<int>(0, (s, v) => s + v);
      final grandTotal = net + depositTotal;

      // The cash actually settled: for a walk-in cash/transfer it's the net; for
      // a credit/wallet sale it's exactly what the fixture tendered (0 for a
      // Pay-with-Credit or a no-cash Credit Sale). The wallet's DEBIT leg is the
      // grand total owed (goods + held deposit), so createOrder's
      // totalAmountKobo arg is [grandTotal], while the order header carries the
      // same grand total (deposit inclusive).
      final cashPaid =
          customerId != null ? scenario.checkout.amountPaidKobo : grandTotal;
      // createOrder uses paymentMethod only to label the CREDIT leg's reference
      // (topup_cash / topup_transfer). The RPC maps every non-transfer tender to
      // topup_cash, so mirror that: 'transfer' stays, everything else → 'cash'.
      final tenderMethod =
          scenario.checkout.paymentMethod == 'transfer' ? 'transfer' : 'cash';

      // A rejection scenario (Slice 3, #55): mirror mobile's hide-don't-write
      // debt-limit guard — a sale that would push the customer past their limit is
      // refused before any write (mobile never reaches createOrder past the
      // block). Assert the guard fires and that nothing persisted. Same rule as
      // the RPC (0136) + CheckoutDialog: only a sale that books NEW debt is gated;
      // limit ≤ 0 forbids any credit; otherwise the projected balance must stay
      // ≥ −limit.
      if (scenario.expectRejection != null) {
        final balance = scenario.customer!.openingBalanceKobo;
        final projected = balance + cashPaid - net;
        final booksNewDebt = cashPaid < net && projected < 0;
        final limit = scenario.customer!.debtLimitKobo;
        final overLimit = booksNewDebt && (limit <= 0 || projected < -limit);
        expect(overLimit, isTrue,
            reason: '${scenario.name}: expected the debt-limit guard to reject');
        final rows = await (db.select(db.orders)
              ..where((o) => o.id.equals(orderId)))
            .get();
        expect(rows, isEmpty,
            reason: '${scenario.name}: a rejected sale writes no order');
        return;
      }

      await db.ordersDao.createOrder(
        order: OrdersCompanion.insert(
          id: Value(orderId),
          businessId: businessId,
          orderNumber: orderNumber,
          totalAmountKobo: gross + depositTotal,
          discountKobo: Value(discount),
          netAmountKobo: grandTotal,
          amountPaidKobo: Value(cashPaid),
          paymentType: 'cash',
          status: 'pending',
          staffId: Value(staffId),
          storeId: Value(storeId),
          customerId: Value(customerId),
          crateDepositPaidKobo: Value(depositTotal),
        ),
        items: items,
        customerId: customerId,
        amountPaidKobo: cashPaid,
        totalAmountKobo: grandTotal,
        staffId: staffId,
        storeId: storeId,
        paymentMethod: tenderMethod,
        crateDepositPaidByManufacturer: depositByMfrId,
      );

      // ── Collect the resulting rows in fixture terms ────────────────────────
      final keyByProductId = {
        for (final e in productIdByKey.entries) e.value: e.key
      };

      final order =
          await (db.select(db.orders)..where((o) => o.id.equals(orderId)))
              .getSingle();
      final orderItems = await (db.select(db.orderItems)
            ..where((i) => i.orderId.equals(orderId)))
          .get();
      final payment = await (db.select(db.paymentTransactions)
            ..where((p) => p.orderId.equals(orderId) & p.type.equals('sale')))
          .getSingleOrNull();
      // #175: the non-`sale` money rows this checkout posted (crate_deposit /
      // wallet_topup), for the split assertion.
      final extraPaymentRows = await (db.select(db.paymentTransactions)
            ..where((p) =>
                p.orderId.equals(orderId) & p.type.equals('sale').not()))
          .get();
      final extraPayments = [
        for (final p in extraPaymentRows)
          ActualTypedPayment(
              type: p.type, method: p.method, amountKobo: p.amountKobo),
      ];

      // Wallet legs THIS sale posted (order_id == this order — excludes the
      // seeded opening balance) + the customer's derived spendable balance.
      const crateDepositRefs = {
        'crate_deposit',
        'crate_deposit_refunded',
        'crate_deposit_forfeited',
      };
      final walletLegs = <ActualWalletLeg>[];
      int? customerBalanceAfter;
      if (customerId != null) {
        final legRows = await (db.select(db.walletTransactions)
              ..where((w) => w.orderId.equals(orderId)))
            .get();
        for (final l in legRows) {
          walletLegs.add(ActualWalletLeg(
            referenceType: l.referenceType,
            signedAmountKobo: l.signedAmountKobo,
          ));
        }
        final allLegs = await (db.select(db.walletTransactions)
              ..where((w) => w.customerId.equals(customerId!)))
            .get();
        customerBalanceAfter = allLegs
            .where((l) => !crateDepositRefs.contains(l.referenceType))
            .fold<int>(0, (s, l) => s + l.signedAmountKobo);
      }

      // Crate rows THIS sale posted (Slice 4, #45), keyed by manufacturer:
      // order_crate_lines, the 'issued' crate_ledger movements, and
      // customer_crate_balances. Empty for a non-crate sale.
      final keyByManufacturerId = {
        for (final e in manufacturerIdByKey.entries) e.value: e.key
      };
      final crateLines = <String, ActualCrateLine>{};
      final crateLedgerIssued = <String, int>{};
      final crateBalances = <String, int>{};
      if (customerId != null && manufacturerIdByKey.isNotEmpty) {
        final lineRows = await (db.select(db.orderCrateLines)
              ..where((l) => l.orderId.equals(orderId)))
            .get();
        for (final l in lineRows) {
          crateLines[keyByManufacturerId[l.manufacturerId]!] = ActualCrateLine(
            cratesTaken: l.cratesTaken,
            depositRateKobo: l.depositRateKobo,
            depositPaidKobo: l.depositPaidKobo,
          );
        }
        final ledgerRows = await (db.select(db.crateLedger)
              ..where((c) =>
                  c.referenceOrderId.equals(orderId) &
                  c.movementType.equals('issued')))
            .get();
        for (final c in ledgerRows) {
          final key = keyByManufacturerId[c.manufacturerId]!;
          crateLedgerIssued[key] =
              (crateLedgerIssued[key] ?? 0) + c.quantityDelta;
        }
        final balanceRows = await (db.select(db.customerCrateBalances)
              ..where((b) => b.customerId.equals(customerId!)))
            .get();
        for (final b in balanceRows) {
          crateBalances[keyByManufacturerId[b.manufacturerId]!] = b.balance;
        }
      }

      final batchRemaining = <String, int>{};
      for (final (id, productKey, receivedAt) in seededBatches) {
        final row = await (db.select(db.costBatches)
              ..where((b) => b.id.equals(id)))
            .getSingle();
        batchRemaining['$productKey|$receivedAt'] = row.qtyRemaining;
      }

      final inventoryAfter = <String, int>{};
      final scalarCost = <String, int>{};
      for (final entry in productIdByKey.entries) {
        final invRow = await (db.select(db.inventory)
              ..where((i) =>
                  i.productId.equals(entry.value) & i.storeId.equals(storeId)))
            .getSingleOrNull();
        if (invRow != null) inventoryAfter[entry.key] = invRow.quantity;
        final prodRow = await (db.select(db.products)
              ..where((p) => p.id.equals(entry.value)))
            .getSingle();
        scalarCost[entry.key] = prodRow.buyingPriceKobo;
      }

      final outcome = CheckoutOutcome(
        orderNumber: order.orderNumber,
        order: ActualOrder(
          status: order.status,
          paymentType: order.paymentType,
          totalAmountKobo: order.totalAmountKobo,
          discountKobo: order.discountKobo,
          netAmountKobo: order.netAmountKobo,
          amountPaidKobo: order.amountPaidKobo,
          completedAtNull: order.completedAt == null,
        ),
        items: [
          for (final i in orderItems)
            ActualItem(
              productKey: keyByProductId[i.productId]!,
              quantity: i.quantity,
              unitPriceKobo: i.unitPriceKobo,
              totalKobo: i.totalKobo,
              buyingPriceKobo: i.buyingPriceKobo,
            ),
        ],
        batchRemaining: batchRemaining,
        inventoryAfter: inventoryAfter,
        productScalarCost: scalarCost,
        payment: payment == null
            ? null
            : ActualPayment(
                method: payment.method, amountKobo: payment.amountKobo),
        extraPayments: extraPayments,
        walletLegs: walletLegs,
        customerBalanceAfter: customerBalanceAfter,
        crateLines: crateLines,
        crateLedgerIssued: crateLedgerIssued,
        crateBalances: crateBalances,
      );

      expectGolden(scenario, outcome, orderNumberScheme: mobileOrderNumberScheme);
    });
  }
}
