import 'package:flutter_test/flutter_test.dart';

import '../../../tool/legacy_import/src/ids.dart';
import '../../../tool/legacy_import/src/mapping.dart';
import '../../../tool/legacy_import/src/quantity.dart';

void main() {
  group('legacyId', () {
    test('the same old id always gives the same new id', () {
      expect(legacyId('Sale', 'abc'), legacyId('Sale', 'abc'));
    });

    test('the namespace is pinned and output is a v5 uuid', () {
      expect(kImportNamespace, '6f1d8b0e-3c52-4c1a-9a57-2f4e8d7b1c90');
      expect(
        legacyId('Sale', 'abc'),
        matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-')),
      );
    });

    test('kinds keep one old id apart', () {
      expect(legacyId('Sale', 'abc'), isNot(legacyId('Customer', 'abc')));
    });

    test('different old ids differ', () {
      expect(legacyId('Sale', 'abc'), isNot(legacyId('Sale', 'abd')));
    });
  });

  group('qtyLiteral', () {
    test('whole values have no decimal point', () {
      expect(qtyLiteral(5), '5');
      expect(qtyLiteral(-3), '-3');
      expect(qtyLiteral(0), '0');
    });

    test('fractions are plain numeric literals', () {
      expect(qtyLiteral(0.5), '0.5');
      expect(qtyLiteral(1.25), '1.25');
      expect(qtyLiteral(0.75), '0.75');
      expect(qtyLiteral(-2.5), '-2.5');
    });

    test('refuses what the 0.25 CHECK would reject', () {
      expect(() => qtyLiteral(0.2), throwsArgumentError);
      expect(() => qtyLiteral(-0.7), throwsArgumentError);
    });
  });

  group('lineValueKobo', () {
    test('rounds a half kobo up', () {
      expect(lineValueKobo(unitKobo: 101, qty: 0.5), 51);
    });

    test('rounds a quarter kobo down', () {
      expect(lineValueKobo(unitKobo: 101, qty: 0.25), 25);
    });

    test('a negative quantity exactly cancels its original', () {
      expect(lineValueKobo(unitKobo: 101, qty: -0.5), -51);
    });
  });

  group('walletLegFor', () {
    test('a sale on credit becomes a debit: the customer owes', () {
      final leg = walletLegFor(oldType: 'SALE_CREDIT', oldAmountKobo: 5000);

      expect(leg.signedKobo, -5000);
      expect(leg.amountKobo, 5000);
      expect(leg.type, 'debit');
      expect(leg.referenceType, 'order_payment');
      expect(leg.isCashIn, isFalse);
    });

    test('a payment becomes a cash top-up credit', () {
      final leg = walletLegFor(oldType: 'PAYMENT', oldAmountKobo: -3000);

      expect(leg.signedKobo, 3000);
      expect(leg.type, 'credit');
      expect(leg.referenceType, 'topup_cash');
      expect(leg.isCashIn, isTrue);
    });

    test('an overpaid sale leaves the customer in credit', () {
      final leg = walletLegFor(oldType: 'SALE_CREDIT', oldAmountKobo: -700);

      expect(leg.signedKobo, 700);
      expect(leg.type, 'credit');
      expect(leg.referenceType, 'topup_cash');
      expect(leg.isCashIn, isFalse);
    });

    test('an adjustment keeps either direction', () {
      final up = walletLegFor(oldType: 'ADJUSTMENT', oldAmountKobo: 900);
      final down = walletLegFor(oldType: 'ADJUSTMENT', oldAmountKobo: -900);

      expect(up.signedKobo, -900);
      expect(up.type, 'debit');
      expect(down.signedKobo, 900);
      expect(down.type, 'credit');
      expect(down.referenceType, 'adjustment');
    });

    test('a zero row stays zero', () {
      final leg = walletLegFor(oldType: 'ADJUSTMENT', oldAmountKobo: 0);

      expect(leg.signedKobo, 0);
      expect(leg.amountKobo, 0);
    });

    test('rejects an unknown type', () {
      expect(
        () => walletLegFor(oldType: 'MYSTERY', oldAmountKobo: 1),
        throwsArgumentError,
      );
    });
  });

  group('supplierLegFor', () {
    test('a delivery becomes an invoice debit: we owe them', () {
      final leg = supplierLegFor(
        oldType: 'DELIVERY_CREDIT',
        oldAmountKobo: 8000,
        note: null,
      );

      expect(leg.signedKobo, -8000);
      expect(leg.type, 'debit');
      expect(leg.referenceType, 'invoice');
      expect(leg.paymentMethod, isNull);
    });

    test('a payment is cash by default', () {
      final leg = supplierLegFor(
        oldType: 'PAYMENT',
        oldAmountKobo: -2000,
        note: 'paid at the door',
      );

      expect(leg.signedKobo, 2000);
      expect(leg.type, 'credit');
      expect(leg.referenceType, 'payment_cash');
      expect(leg.paymentMethod, 'cash');
    });

    test('a payment whose note names a transfer is a transfer', () {
      for (final note in ['via Opay', 'MONIEPOINT 123', 'bank transfer']) {
        final leg = supplierLegFor(
          oldType: 'PAYMENT',
          oldAmountKobo: -2000,
          note: note,
        );

        expect(leg.referenceType, 'payment_transfer');
        expect(leg.paymentMethod, 'transfer');
      }
    });

    test('a cancelled-delivery adjustment becomes a void', () {
      final leg = supplierLegFor(
        oldType: 'ADJUSTMENT',
        oldAmountKobo: -1500,
        note: null,
      );

      expect(leg.signedKobo, 1500);
      expect(leg.referenceType, 'void');
    });
  });

  group('orderNumberFor', () {
    test('keeps the last 8 characters, unchanged', () {
      expect(orderNumberFor('cmabcdefghijklmnop12345678'), 'OLD-12345678');
    });

    test('copes with a short id', () {
      expect(orderNumberFor('abc'), 'OLD-abc');
    });
  });

  group('orderPaymentType', () {
    test('paid in full is cash', () {
      expect(orderPaymentType(paidKobo: 500, totalKobo: 500), 'cash');
    });

    test('overpaid is cash', () {
      expect(orderPaymentType(paidKobo: 600, totalKobo: 500), 'cash');
    });

    test('part paid is mixed', () {
      expect(orderPaymentType(paidKobo: 100, totalKobo: 500), 'mixed');
    });

    test('nothing paid is credit', () {
      expect(orderPaymentType(paidKobo: 0, totalKobo: 500), 'credit');
    });

    test('a free sale is cash, not credit', () {
      expect(orderPaymentType(paidKobo: 0, totalKobo: 0), 'cash');
    });
  });

  group('splitTender', () {
    test('an overpayment splits off the goods', () {
      final split = splitTender(paidKobo: 700, totalKobo: 500);

      expect(split.goodsKobo, 500);
      expect(split.overpaidKobo, 200);
    });

    test('a part payment is all goods', () {
      final split = splitTender(paidKobo: 300, totalKobo: 500);

      expect(split.goodsKobo, 300);
      expect(split.overpaidKobo, 0);
    });
  });

  group('customerDisplayName', () {
    test('keeps the trading name in brackets', () {
      expect(
        customerDisplayName(name: 'Ada Test', businessName: 'Test Stores'),
        'Ada Test (Test Stores)',
      );
    });

    test('a blank or repeated trading name adds nothing', () {
      expect(customerDisplayName(name: 'Ada', businessName: ' '), 'Ada');
      expect(customerDisplayName(name: 'Ada', businessName: null), 'Ada');
      expect(customerDisplayName(name: 'Ada', businessName: 'ada'), 'Ada');
    });
  });

  group('productUnit', () {
    test('returnable glass is a Bottle whatever the name says', () {
      expect(productUnit(isReturnable: true, name: 'Test Lager 60cl'), 'Bottle');
    });

    test('PET and cans map to their packs', () {
      expect(productUnit(isReturnable: false, name: 'Test Cola PET'), 'Pack');
      expect(productUnit(isReturnable: false, name: 'Test Malt Can'), 'Carton');
      expect(productUnit(isReturnable: false, name: 'Test 6 Cans'), 'Carton');
    });

    test('a word merely containing pet or can stays a Piece', () {
      expect(productUnit(isReturnable: false, name: 'Petal Juice'), 'Piece');
      expect(productUnit(isReturnable: false, name: 'Canary Water'), 'Piece');
    });
  });

  group('mergeSuppliers', () {
    SupplierInput supplier(String id, String name, String store, int day) =>
        SupplierInput(
          id: id,
          name: name,
          storeId: store,
          createdAt: DateTime.utc(2026, 1, day),
        );

    test('same name across branches merges into the main store copy', () {
      final survivors = mergeSuppliers(
        suppliers: [
          supplier('branch', 'Acme Drinks', 'b', 1),
          supplier('main', 'Acme Drinks', 'm', 2),
        ],
        mainStoreId: 'm',
      );

      expect(survivors, {'branch': 'main', 'main': 'main'});
    });

    test('the match ignores case and spacing', () {
      final survivors = mergeSuppliers(
        suppliers: [
          supplier('one', 'Acme  Drinks', 'm', 1),
          supplier('two', ' acme drinks ', 'b', 2),
        ],
        mainStoreId: 'm',
      );

      expect(survivors['two'], 'one');
    });

    test('with no main store copy the earliest survives', () {
      final survivors = mergeSuppliers(
        suppliers: [
          supplier('late', 'Acme', 'b', 9),
          supplier('early', 'Acme', 'c', 1),
        ],
        mainStoreId: 'm',
      );

      expect(survivors['late'], 'early');
    });

    test('different names stay apart', () {
      final survivors = mergeSuppliers(
        suppliers: [
          supplier('one', 'Acme', 'm', 1),
          supplier('two', 'Bravo', 'm', 1),
        ],
        mainStoreId: 'm',
      );

      expect(survivors, {'one': 'one', 'two': 'two'});
    });
  });

  group('reconcileOffGridMovements', () {
    MovementQty movement(String id, double qty, int minute, [String key = 'g']) =>
        MovementQty(
          id: id,
          groupKey: key,
          createdAt: DateTime.utc(2026, 1, 1, 0, minute),
          qty: qty,
        );

    test('on-grid movements are left alone', () {
      final result = reconcileOffGridMovements([movement('m1', -0.5, 1)]);

      expect(result.replacedQty, isEmpty);
      expect(result.dropped, isEmpty);
    });

    test('a split pair folds into the earliest, keeping the total', () {
      final result = reconcileOffGridMovements([
        movement('later', -0.3, 2),
        movement('first', -0.7, 1),
      ]);

      expect(result.replacedQty, {'first': -1.0});
      expect(result.dropped, {'later'});
      expect(result.unresolved, isEmpty);
    });

    test('a group that stays off the grid is dropped and reported', () {
      final result = reconcileOffGridMovements([movement('m1', -0.7, 1)]);

      expect(result.dropped, {'m1'});
      expect(result.unresolved.single.id, 'm1');
    });

    test('a group that nets to zero leaves nothing', () {
      final result = reconcileOffGridMovements([
        movement('m1', -0.7, 1),
        movement('m2', 0.7, 2),
      ]);

      expect(result.replacedQty, isEmpty);
      expect(result.dropped, {'m1', 'm2'});
    });

    test('groups do not mix', () {
      final result = reconcileOffGridMovements([
        movement('m1', -0.7, 1, 'a'),
        movement('m2', -0.3, 2, 'b'),
      ]);

      expect(result.unresolved, hasLength(2));
    });
  });

  group('lagosDay', () {
    test('late evening UTC is already tomorrow in Lagos', () {
      expect(lagosDay(DateTime.utc(2026, 1, 1, 23, 30)), '2026-01-02');
    });

    test('earlier in the day stays on the same date', () {
      expect(lagosDay(DateTime.utc(2026, 1, 1, 22, 59)), '2026-01-01');
    });
  });
}
