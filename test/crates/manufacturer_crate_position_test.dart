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
