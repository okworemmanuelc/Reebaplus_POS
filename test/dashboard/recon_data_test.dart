import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';

/// Builds a [ReconData] with everything zeroed except the P&L inputs a test
/// cares about — the getters under test only touch revenue / discounts / COGS /
/// expenses / damages, so the rest can be neutral.
ReconData recon({
  int costedRevenueKobo = 0,
  int totalRevenueKobo = -1, // -1 ⇒ mirror costedRevenueKobo (back-compat)
  int cogsKobo = 0,
  int discountsKobo = 0,
  bool vatEnabled = false,
  int vatRateBps = 0,
  int vatKobo = 0,
  int expensesKobo = 0,
  int damageCostKobo = 0,
  int crateDamageDepositKobo = 0,
  int cashSalesKobo = 0,
  int cashDebtsCollectedKobo = 0,
  int cashRefundsKobo = 0,
  int cashExpensesKobo = 0,
  int cashSupplierPaidKobo = 0,
  int cashCrateDepositsKobo = 0,
  bool hasStockCount = false,
  int shortageCostKobo = 0,
  int surplusCostKobo = 0,
  int stockOpeningKobo = 0,
  int stockReceivedKobo = 0,
  int stockCogsKobo = 0,
  int stockDamagesKobo = 0,
  int stockExpiredKobo = 0,
  int stockOtherMovementsKobo = 0,
  int stockExpectedClosingKobo = 0,
  // Business net position (#163) inputs — assets counted, liabilities netted.
  int inventoryOnHandKobo = 0,
  int totalOwedKobo = 0,
  bool showCrates = false,
  int crateDepositKobo = 0,
  int supplierPayableKobo = 0,
  int heldCrateDepositsKobo = 0,
  int supplierCrateDebtKobo = 0,
}) {
  return ReconData(
    totalRevenueKobo: totalRevenueKobo < 0 ? costedRevenueKobo : totalRevenueKobo,
    costedRevenueKobo: costedRevenueKobo,
    cogsKobo: cogsKobo,
    discountsKobo: discountsKobo,
    vatEnabled: vatEnabled,
    vatRateBps: vatRateBps,
    vatKobo: vatKobo,
    itemsSold: 0,
    skus: 0,
    uncostedItems: 0,
    refundsKobo: 0,
    cashSalesKobo: cashSalesKobo,
    cashDebtsCollectedKobo: cashDebtsCollectedKobo,
    cashRefundsKobo: cashRefundsKobo,
    cashExpensesKobo: cashExpensesKobo,
    cashSupplierPaidKobo: cashSupplierPaidKobo,
    cashCrateDepositsKobo: cashCrateDepositsKobo,
    bestStaff: null,
    bestStaffKobo: 0,
    expensesKobo: expensesKobo,
    expensesCount: 0,
    damageUnits: 0,
    damageCostKobo: damageCostKobo,
    damageRetailKobo: 0,
    crateDamageDepositKobo: crateDamageDepositKobo,
    hasStockCount: hasStockCount,
    productsCounted: 0,
    shortageCount: 0,
    shortageUnits: 0,
    surplusCount: 0,
    surplusUnits: 0,
    shortageCostKobo: shortageCostKobo,
    shortageRetailKobo: 0,
    shortages: const [],
    goodsReceivedKobo: 0,
    supplierPaidKobo: 0,
    totalOwedKobo: totalOwedKobo,
    showCrates: showCrates,
    crateUnits: 0,
    crateDepositKobo: crateDepositKobo,
    supplierPayableKobo: supplierPayableKobo,
    heldCrateDepositsKobo: heldCrateDepositsKobo,
    supplierCrateDebtKobo: supplierCrateDebtKobo,
    inventoryOnHandKobo: inventoryOnHandKobo,
    uncostedInventoryItems: 0,
    surplusCostKobo: surplusCostKobo,
    stockOpeningKobo: stockOpeningKobo,
    stockReceivedKobo: stockReceivedKobo,
    stockCogsKobo: stockCogsKobo,
    stockDamagesKobo: stockDamagesKobo,
    stockExpiredKobo: stockExpiredKobo,
    stockOtherMovementsKobo: stockOtherMovementsKobo,
    stockExpectedClosingKobo: stockExpectedClosingKobo,
    topItems: const [],
    manufacturerEmpties: const [],
  );
}

void main() {
  group('ReconData P&L — discounts are subtracted (issue #70)', () {
    test('net revenue is gross costed revenue minus discounts', () {
      final d = recon(costedRevenueKobo: 100000, discountsKobo: 15000);
      expect(d.netRevenueKobo, 85000);
    });

    test('gross profit subtracts discounts before COGS', () {
      // Gross revenue 100,000; discount 15,000; COGS 60,000.
      final d = recon(
        costedRevenueKobo: 100000,
        discountsKobo: 15000,
        cogsKobo: 60000,
      );
      // 100,000 − 15,000 − 60,000 = 25,000 (was 40,000 before the fix).
      expect(d.grossProfitKobo, 25000);
    });

    test('net profit flows the discount through expenses and damages', () {
      final d = recon(
        costedRevenueKobo: 100000,
        discountsKobo: 15000,
        cogsKobo: 60000,
        expensesKobo: 5000,
        damageCostKobo: 2000,
        crateDamageDepositKobo: 1000,
      );
      // grossProfit 25,000 − 5,000 − 2,000 − 1,000 = 17,000.
      expect(d.netProfitKobo, 17000);
    });

    test('gross margin is measured against net revenue', () {
      final d = recon(
        costedRevenueKobo: 100000,
        discountsKobo: 20000,
        cogsKobo: 40000,
      );
      // net revenue 80,000; gross profit 40,000 → 50.0%.
      expect(d.grossMarginPct, '50.0');
    });

    test('zero discounts leave the pre-fix behaviour intact', () {
      final d = recon(costedRevenueKobo: 100000, cogsKobo: 60000);
      expect(d.netRevenueKobo, 100000);
      expect(d.grossProfitKobo, 40000);
      expect(d.grossMarginPct, '40.0');
    });

    test('gross margin is "0.0" when there is no net revenue', () {
      expect(recon().grossMarginPct, '0.0');
      // A fully-discounted period has no net revenue → no divide-by-zero.
      expect(recon(costedRevenueKobo: 5000, discountsKobo: 5000).grossMarginPct,
          '0.0');
    });
  });

  group('ReconData VAT (opt-in, per-business)', () {
    test('vatRateLabel renders the configured rate as a percent', () {
      final d = recon(vatEnabled: true, vatRateBps: 750, vatKobo: 1000);
      expect(d.vatRateLabel, '7.5');
    });

    test('VAT is a pass-through — it does not enter the profit lines', () {
      // Same P&L inputs, VAT on vs off → identical gross/net profit.
      final off = recon(costedRevenueKobo: 100000, cogsKobo: 60000);
      final on = recon(
        costedRevenueKobo: 100000,
        cogsKobo: 60000,
        vatEnabled: true,
        vatRateBps: 750,
        vatKobo: 7500,
      );
      expect(on.grossProfitKobo, off.grossProfitKobo);
      expect(on.netProfitKobo, off.netProfitKobo);
    });
  });

  group('ReconData cash-flow summary (issue #72, ADR 0014)', () {
    test('cash in = cash sales + debts collected', () {
      final d = recon(cashSalesKobo: 80000, cashDebtsCollectedKobo: 12000);
      expect(d.cashInKobo, 92000);
    });

    test('cash out = refunds + cash expenses + cash supplier payments', () {
      final d = recon(
        cashRefundsKobo: 3000,
        cashExpensesKobo: 7000,
        cashSupplierPaidKobo: 20000,
      );
      expect(d.cashOutKobo, 30000);
    });

    test('net cash movement is in minus out (can be negative)', () {
      final d = recon(
        cashSalesKobo: 50000,
        cashDebtsCollectedKobo: 10000,
        cashRefundsKobo: 5000,
        cashExpensesKobo: 15000,
        cashSupplierPaidKobo: 60000,
      );
      // 60,000 in − 80,000 out = −20,000.
      expect(d.netCashMovementKobo, -20000);
    });

    test('hasCashActivity is false only when nothing moved', () {
      expect(recon().hasCashActivity, isFalse);
      expect(recon(cashSalesKobo: 1).hasCashActivity, isTrue);
      expect(recon(cashSupplierPaidKobo: 1).hasCashActivity, isTrue);
    });
  });

  group('ReconData stock flow-equation (issue #72 slice 2, ADR 0014)', () {
    test('derived closing = opening + received − cogs − damages − expired', () {
      // Opening 100,000 + received 40,000 − COGS 55,000 − damages 3,000 −
      // expired 2,000 = 80,000, and no other movements.
      final d = recon(
        stockOpeningKobo: 100000,
        stockReceivedKobo: 40000,
        stockCogsKobo: 55000,
        stockDamagesKobo: 3000,
        stockExpiredKobo: 2000,
        stockExpectedClosingKobo: 80000,
      );
      expect(d.stockDerivedClosingKobo, 80000);
      // Ties out to the perpetual system figure fed in independently.
      expect(d.stockDerivedClosingKobo, d.stockExpectedClosingKobo);
    });

    test('other movements (transfers / count fixes) fold into the equation', () {
      // A +5,000 transfer-in shifts derived closing up by 5,000.
      final d = recon(
        stockOpeningKobo: 100000,
        stockReceivedKobo: 0,
        stockCogsKobo: 20000,
        stockOtherMovementsKobo: 5000,
        stockExpectedClosingKobo: 85000,
      );
      expect(d.stockDerivedClosingKobo, 85000);
      expect(d.stockDerivedClosingKobo, d.stockExpectedClosingKobo);
    });

    test('variance is surplus minus shortage (physical − expected, at cost)', () {
      // Counted 2,000 over in one product, 5,000 short in another → net −3,000.
      final d = recon(surplusCostKobo: 2000, shortageCostKobo: 5000);
      expect(d.stockVarianceKobo, -3000);
      // A pure surplus is positive.
      expect(recon(surplusCostKobo: 1500).stockVarianceKobo, 1500);
    });

    test('hasStockFlow is false only when every flow line is zero', () {
      expect(recon().hasStockFlow, isFalse);
      expect(recon(stockExpectedClosingKobo: 1).hasStockFlow, isTrue);
      expect(recon(stockReceivedKobo: 1).hasStockFlow, isTrue);
      expect(recon(stockExpiredKobo: 1).hasStockFlow, isTrue);
    });
  });

  group('ReconData business net position — crate honesty (#163)', () {
    test('counts the empties asset AND subtracts both crate liabilities', () {
      // Inventory 500,000 + customer debt 40,000 + empties held 90,000
      //   − supplier money owed 30,000 − customer deposits held 60,000
      //   − supplier crate debt 20,000 = 520,000.
      final d = recon(
        inventoryOnHandKobo: 500000,
        totalOwedKobo: 40000,
        showCrates: true,
        crateDepositKobo: 90000,
        supplierPayableKobo: 30000,
        heldCrateDepositsKobo: 60000,
        supplierCrateDebtKobo: 20000,
      );
      expect(d.businessNetPositionKobo, 520000);
    });

    test('a shop holding deposits and owing suppliers shows a LOWER, correct '
        'net position than the asset-only figure', () {
      // Same crate asset, but one shop has resolved liabilities and the other
      // still holds customer deposits and owes suppliers empties.
      final assetOnly = recon(
        inventoryOnHandKobo: 500000,
        showCrates: true,
        crateDepositKobo: 90000,
      );
      final withLiabilities = recon(
        inventoryOnHandKobo: 500000,
        showCrates: true,
        crateDepositKobo: 90000,
        heldCrateDepositsKobo: 60000,
        supplierCrateDebtKobo: 20000,
      );
      expect(assetOnly.businessNetPositionKobo, 590000);
      expect(withLiabilities.businessNetPositionKobo, 510000);
      expect(
        withLiabilities.businessNetPositionKobo,
        lessThan(assetOnly.businessNetPositionKobo),
        reason: 'held deposits + supplier crate debt cut the honest position',
      );
      // The gap is exactly the two liability legs (80,000).
      expect(
        assetOnly.businessNetPositionKobo -
            withLiabilities.businessNetPositionKobo,
        80000,
      );
    });

    test('each liability leg subtracts independently', () {
      final base = recon(inventoryOnHandKobo: 100000, showCrates: true);
      expect(base.businessNetPositionKobo, 100000);
      expect(
        recon(inventoryOnHandKobo: 100000, showCrates: true,
                heldCrateDepositsKobo: 15000)
            .businessNetPositionKobo,
        85000,
      );
      expect(
        recon(inventoryOnHandKobo: 100000, showCrates: true,
                supplierCrateDebtKobo: 25000)
            .businessNetPositionKobo,
        75000,
      );
    });

    test('a non-crate business (no crate legs) is unchanged — position is just '
        'inventory + debt − supplier money owed', () {
      final d = recon(
        inventoryOnHandKobo: 200000,
        totalOwedKobo: 50000,
        supplierPayableKobo: 30000,
      );
      // No crate asset, no crate liabilities → 200,000 + 50,000 − 30,000.
      expect(d.businessNetPositionKobo, 220000);
    });
  });

  group('ReconData integrity flag (issue #72 slice 3, ADR 0014)', () {
    test('count-reconciled profit is net profit plus the stock variance', () {
      // Net profit 30,000; counted 4,000 short (shortage cost) → 26,000.
      final d = recon(
        costedRevenueKobo: 100000,
        cogsKobo: 70000,
        hasStockCount: true,
        shortageCostKobo: 4000,
      );
      expect(d.netProfitKobo, 30000);
      expect(d.stockVarianceKobo, -4000);
      expect(d.integrityAdjustedProfitKobo, 26000);
    });

    test('a surplus lifts the reconciled profit above the reported profit', () {
      final d = recon(
        costedRevenueKobo: 50000,
        cogsKobo: 30000,
        hasStockCount: true,
        surplusCostKobo: 1500,
      );
      // net profit 20,000 + surplus 1,500 = 21,500.
      expect(d.integrityAdjustedProfitKobo, 21500);
    });

    test('hasIntegrityGap requires both a count and a non-zero variance', () {
      // Variance present but no count taken → nothing to reconcile against.
      expect(recon(shortageCostKobo: 5000).hasIntegrityGap, isFalse);
      // Count taken and it ties out → reconciled, no gap.
      expect(recon(hasStockCount: true).hasIntegrityGap, isFalse);
      // Count taken and it diverges → flagged.
      expect(
        recon(hasStockCount: true, shortageCostKobo: 5000).hasIntegrityGap,
        isTrue,
      );
      expect(
        recon(hasStockCount: true, surplusCostKobo: 5000).hasIntegrityGap,
        isTrue,
      );
    });
  });
}
