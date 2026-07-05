import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';

/// Builds a [ReconData] with everything zeroed except the P&L inputs a test
/// cares about — the getters under test only touch revenue / discounts / COGS /
/// expenses / damages, so the rest can be neutral.
ReconData recon({
  int costedRevenueKobo = 0,
  int cogsKobo = 0,
  int discountsKobo = 0,
  int expensesKobo = 0,
  int damageCostKobo = 0,
  int crateDamageDepositKobo = 0,
}) {
  return ReconData(
    totalRevenueKobo: costedRevenueKobo,
    costedRevenueKobo: costedRevenueKobo,
    cogsKobo: cogsKobo,
    discountsKobo: discountsKobo,
    itemsSold: 0,
    skus: 0,
    uncostedItems: 0,
    refundsKobo: 0,
    bestStaff: null,
    bestStaffKobo: 0,
    expensesKobo: expensesKobo,
    expensesCount: 0,
    damageUnits: 0,
    damageCostKobo: damageCostKobo,
    damageRetailKobo: 0,
    crateDamageDepositKobo: crateDamageDepositKobo,
    hasStockCount: false,
    productsCounted: 0,
    shortageCount: 0,
    shortageUnits: 0,
    surplusCount: 0,
    surplusUnits: 0,
    shortageCostKobo: 0,
    shortageRetailKobo: 0,
    shortages: const [],
    goodsReceivedKobo: 0,
    supplierPaidKobo: 0,
    totalOwedKobo: 0,
    showCrates: false,
    crateUnits: 0,
    crateDepositKobo: 0,
    supplierPayableKobo: 0,
    inventoryOnHandKobo: 0,
    uncostedInventoryItems: 0,
    surplusCostKobo: 0,
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
}
