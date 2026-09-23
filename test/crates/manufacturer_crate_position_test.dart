import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/crates/manufacturer_crate_position.dart';

void main() {
  group('computeManufacturerCratePosition (pure function)', () {
    test('computes all six statuses correctly with positive crate value', () {
      final pos = computeManufacturerCratePosition(
        manufacturerId: 'mfr-1',
        crateValueKobo: 300000, // ₦3,000
        warehouseCrates: 25,
        fullCrates: 40,
        customerOnDepositCrates: 15,
        customerOnDepositKobo: 4500000, // ₦45,000
        customerNoDepositCrates: 10,
        shortCrates: 0,
        damagedCrates: 2,
        damagedLossKobo: 600000,
      );

      expect(pos.manufacturerId, 'mfr-1');
      expect(pos.crateValueKobo, 300000);

      // 1. In the warehouse: 25 * 3,000 = 75,000 (7,500,000 kobo)
      expect(pos.inWarehouse.count, 25);
      expect(pos.inWarehouse.moneyKobo, 7500000);
      expect(pos.inWarehouse.hasMoney, isTrue);

      // 2. Full crates in stock: 40 * 3,000 = 120,000 (12,000,000 kobo)
      expect(pos.fullCratesInStock.count, 40);
      expect(pos.fullCratesInStock.moneyKobo, 12000000);
      expect(pos.fullCratesInStock.hasMoney, isTrue);

      // 3. With customers, on deposit: 15 crates, ₦45,000 actually paid in
      expect(pos.withCustomersOnDeposit.count, 15);
      expect(pos.withCustomersOnDeposit.moneyKobo, 4500000);
      expect(pos.withCustomersOnDeposit.hasMoney, isTrue);

      // 4. With customers, no deposit: 10 * 3,000 = 30,000 (3,000,000 kobo)
      expect(pos.withCustomersNoDeposit.count, 10);
      expect(pos.withCustomersNoDeposit.moneyKobo, 3000000);
      expect(pos.withCustomersNoDeposit.hasMoney, isTrue);

      // 5. Short: 0 count, no money
      expect(pos.short.count, 0);
      expect(pos.short.moneyKobo, 0);
      expect(pos.short.hasMoney, isFalse);

      // 6. Damaged: 2 crates, snapshotted loss = 600,000 kobo
      expect(pos.damaged.count, 2);
      expect(pos.damaged.moneyKobo, 600000);
      expect(pos.damaged.hasMoney, isTrue);

      // Totals
      expect(pos.totalCrates, 25 + 40 + 15 + 10);
      expect(pos.totalCrateValueKobo, 7500000 + 12000000 + 4500000 + 3000000);
      expect(pos.allStatuses.length, 6);
    });

    test('clamps negative crate value to zero and handles defaults', () {
      final pos = computeManufacturerCratePosition(
        manufacturerId: 'mfr-2',
        crateValueKobo: -100,
      );

      expect(pos.crateValueKobo, 0);
      expect(pos.inWarehouse.count, 0);
      expect(pos.inWarehouse.moneyKobo, 0);
      expect(pos.fullCratesInStock.count, 0);
      expect(pos.fullCratesInStock.moneyKobo, 0);
      expect(pos.withCustomersOnDeposit.count, 0);
      expect(pos.withCustomersOnDeposit.moneyKobo, 0);
      expect(pos.withCustomersNoDeposit.count, 0);
      expect(pos.withCustomersNoDeposit.moneyKobo, 0);
      expect(pos.short.count, 0);
      expect(pos.damaged.count, 0);
      expect(pos.damaged.moneyKobo, 0);
      expect(pos.totalCrates, 0);
      expect(pos.totalCrateValueKobo, 0);
    });

    test('damagedLossKobo falls back to damagedCrates * rate when null', () {
      final pos = computeManufacturerCratePosition(
        manufacturerId: 'mfr-3',
        crateValueKobo: 250000,
        damagedCrates: 4,
        damagedLossKobo: null,
      );

      expect(pos.damaged.count, 4);
      expect(pos.damaged.moneyKobo, 4 * 250000);
    });

    test('stores sum up to All Stores cleanly', () {
      // Store 1
      final s1 = computeManufacturerCratePosition(
        manufacturerId: 'mfr-nb',
        crateValueKobo: 300000,
        warehouseCrates: 10,
        fullCrates: 20,
        customerOnDepositCrates: 5,
        customerOnDepositKobo: 1500000,
        customerNoDepositCrates: 3,
        damagedCrates: 1,
      );

      // Store 2
      final s2 = computeManufacturerCratePosition(
        manufacturerId: 'mfr-nb',
        crateValueKobo: 300000,
        warehouseCrates: 15,
        fullCrates: 30,
        customerOnDepositCrates: 10,
        customerOnDepositKobo: 3000000,
        customerNoDepositCrates: 7,
        damagedCrates: 2,
      );

      // All Stores = sum of Store 1 + Store 2
      final all = computeManufacturerCratePosition(
        manufacturerId: 'mfr-nb',
        crateValueKobo: 300000,
        warehouseCrates: s1.inWarehouse.count + s2.inWarehouse.count,
        fullCrates: s1.fullCratesInStock.count + s2.fullCratesInStock.count,
        customerOnDepositCrates:
            s1.withCustomersOnDeposit.count + s2.withCustomersOnDeposit.count,
        customerOnDepositKobo:
            s1.withCustomersOnDeposit.moneyKobo + s2.withCustomersOnDeposit.moneyKobo,
        customerNoDepositCrates:
            s1.withCustomersNoDeposit.count + s2.withCustomersNoDeposit.count,
        damagedCrates: s1.damaged.count + s2.damaged.count,
      );

      expect(all.inWarehouse.count, 25);
      expect(all.fullCratesInStock.count, 50);
      expect(all.withCustomersOnDeposit.count, 15);
      expect(all.withCustomersOnDeposit.moneyKobo, 4500000);
      expect(all.withCustomersNoDeposit.count, 10);
      expect(all.damaged.count, 3);
      expect(all.totalCrates, s1.totalCrates + s2.totalCrates);
      expect(all.totalCrateValueKobo, s1.totalCrateValueKobo + s2.totalCrateValueKobo);
    });
  });

  group('computeCustomerDepositAttribution', () {
    test('sums exactly to business-wide Held Deposit when fully attributed', () {
      final attribution = computeCustomerDepositAttribution(
        businessWideHeldDepositKobo: 10000000, // ₦100,000
        brandDepositsKobo: {
          'mfr-1': 6000000, // ₦60,000
          'mfr-2': 4000000, // ₦40,000
        },
      );

      expect(attribution.totalAttributedKobo, 10000000);
      expect(attribution.unattributedKobo, 0);
      expect(
        attribution.totalAttributedKobo + attribution.unattributedKobo,
        attribution.businessWideHeldDepositKobo,
      );
    });

    test('surfaces unattributed deposit when brand deposits are less than held', () {
      final attribution = computeCustomerDepositAttribution(
        businessWideHeldDepositKobo: 15000000, // ₦150,000
        brandDepositsKobo: {
          'mfr-1': 5000000, // ₦50,000
          'mfr-2': 7000000, // ₦70,000
        },
      );

      expect(attribution.totalAttributedKobo, 12000000);
      // Unattributed = 150,000 - 120,000 = 30,000 (3,000,000 kobo)
      expect(attribution.unattributedKobo, 3000000);
      // Invariant: sum of brands + unattributed == business-wide held deposit
      expect(
        attribution.totalAttributedKobo + attribution.unattributedKobo,
        attribution.businessWideHeldDepositKobo,
      );
    });

    test('handles zero brand deposits and preserves entire held as unattributed', () {
      final attribution = computeCustomerDepositAttribution(
        businessWideHeldDepositKobo: 5000000,
        brandDepositsKobo: const {},
      );

      expect(attribution.totalAttributedKobo, 0);
      expect(attribution.unattributedKobo, 5000000);
      expect(
        attribution.totalAttributedKobo + attribution.unattributedKobo,
        attribution.businessWideHeldDepositKobo,
      );
    });
  });

  group('computeManufacturerCratePosition — Short status money valuation', () {
    test('values shortage at count * crateValue and sets hasMoney = true when count > 0', () {
      final pos = computeManufacturerCratePosition(
        manufacturerId: 'mfr-short',
        crateValueKobo: 250000, // ₦2,500
        shortCrates: 7,
      );

      expect(pos.short.count, 7);
      expect(pos.short.moneyKobo, 7 * 250000); // ₦17,500 (1,750,000 kobo)
      expect(pos.short.hasMoney, isTrue);
    });
  });

  group('pure shortage fold (PRD #284 §7, #293)', () {
    final t0 = DateTime(2026, 9, 23, 10, 0);
    final t1 = DateTime(2026, 9, 23, 11, 0);
    final t2 = DateTime(2026, 9, 23, 12, 0);
    final t3 = DateTime(2026, 9, 23, 13, 0);

    test('an Opening Count sets the number and raises no shortage', () {
      final movements = [
        CrateCountMovement(
          movementType: 'opening_count',
          quantityDelta: -20, // counted 30 when expected 50
          createdAt: t0,
        ),
      ];

      expect(foldCrateShortageForStore(movements), 0);
    });

    test('a count below expected opens shortage by the gap', () {
      final movements = [
        CrateCountMovement(
          movementType: 'opening_count',
          quantityDelta: -10,
          createdAt: t0,
        ),
        CrateCountMovement(
          movementType: 'count',
          quantityDelta: -8, // counted 8 below expected
          createdAt: t1,
        ),
      ];

      expect(foldCrateShortageForStore(movements), 8);
    });

    test('a count above expected closes open shortage first', () {
      final movements = [
        CrateCountMovement(
          movementType: 'opening_count',
          quantityDelta: 0,
          createdAt: t0,
        ),
        CrateCountMovement(
          movementType: 'count',
          quantityDelta: -10, // 10 short
          createdAt: t1,
        ),
        CrateCountMovement(
          movementType: 'count',
          quantityDelta: 4, // 4 found -> 6 short remaining
          createdAt: t2,
        ),
      ];

      expect(foldCrateShortageForStore(movements), 6);
    });

    test('surplus is not banked: surplus then a later short still shows the later shortage', () {
      final movements = [
        CrateCountMovement(
          movementType: 'opening_count',
          quantityDelta: 0,
          createdAt: t0,
        ),
        CrateCountMovement(
          movementType: 'count',
          quantityDelta: -5, // 5 short
          createdAt: t1,
        ),
        CrateCountMovement(
          movementType: 'count',
          quantityDelta: 15, // 15 surplus: closes 5 short, excess 10 is NOT banked
          createdAt: t2,
        ),
      ];
      // Shortage is fully closed to 0
      expect(foldCrateShortageForStore(movements), 0);

      // Later count is short 6
      final laterMovements = [
        ...movements,
        CrateCountMovement(
          movementType: 'count',
          quantityDelta: -6,
          createdAt: t3,
        ),
      ];
      // Later shortage is 6, NOT offset by the unbanked 10 surplus from earlier
      expect(foldCrateShortageForStore(laterMovements), 6);
    });

    test('multi-store summation: surplus in Store B never offsets shortage in Store A', () {
      final movements = [
        // Store A
        CrateCountMovement(
          storeId: 'store-a',
          movementType: 'opening_count',
          quantityDelta: 0,
          createdAt: t0,
        ),
        CrateCountMovement(
          storeId: 'store-a',
          movementType: 'count',
          quantityDelta: -10, // 10 short in Store A
          createdAt: t1,
        ),
        // Store B
        CrateCountMovement(
          storeId: 'store-b',
          movementType: 'opening_count',
          quantityDelta: 0,
          createdAt: t0,
        ),
        CrateCountMovement(
          storeId: 'store-b',
          movementType: 'count',
          quantityDelta: 25, // 25 surplus in Store B
          createdAt: t2,
        ),
      ];

      final perStore = foldCrateShortagePerStore(movements);
      expect(perStore['store-a'], 10);
      expect(perStore['store-b'], 0);

      // All Stores total = sum of store shortages = 10 + 0 = 10
      expect(foldTotalCrateShortage(movements), 10);
    });

    test('empty movements list yields 0 shortage', () {
      expect(foldCrateShortageForStore([]), 0);
      expect(foldTotalCrateShortage([]), 0);
      expect(foldCrateShortagePerStore([]), isEmpty);
    });
  });

  group('labelForCrateMovement', () {
    test('labels known and unknown movement kinds cleanly', () {
      expect(labelForCrateMovement('issued'), 'Issued to customer');
      expect(labelForCrateMovement('returned'), 'Returned');
      expect(labelForCrateMovement('damaged'), 'Damaged');
      expect(labelForCrateMovement('adjusted'), 'Adjusted');
      expect(labelForCrateMovement('count'), 'Count');
      expect(labelForCrateMovement('opening_count'), 'Opening Count');
      expect(labelForCrateMovement('received'), 'Received from supplier');
      expect(labelForCrateMovement('transferred_in'), 'Transferred in');
      expect(labelForCrateMovement('transferred_out'), 'Transferred out');
      expect(labelForCrateMovement('purchase'), 'Purchased');
      expect(labelForCrateMovement('custom_audit_op'), 'Custom Audit Op');
    });
  });
}

