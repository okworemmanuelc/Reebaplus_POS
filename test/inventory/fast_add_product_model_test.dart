import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/features/inventory/models/fast_add_product_model.dart';

/// Pure unit tests for the Fast-Add form model (Seam 1, issue #30 / ADR 0006).
/// These assert external behaviour only — given raw field values + a business
/// context, what the model decides or produces — never widget internals. Prior
/// art: `test/orders/order_module_test.dart` (pins payment/wallet resolution).
void main() {
  // A one-store, non-crate business whose role can edit the buying price. The
  // common baseline; individual tests vary only what they exercise.
  FastAddContext ctx({
    bool tracksCrates = false,
    bool canEditBuying = true,
    List<String> storeIds = const ['store-1'],
  }) => FastAddContext(
    tracksCrates: tracksCrates,
    canEditBuying: canEditBuying,
    storeIds: storeIds,
  );

  FastAddInput input({
    String name = 'Star 60cl',
    String sellingPrice = '500',
    String quantity = '10',
    String buyingPrice = '',
    String wholesalePrice = '',
    String lowStock = '',
    String? unit,
    bool trackEmpties = true,
    String emptyCrateValue = '',
    bool hasManufacturer = false,
    String? selectedStoreId,
  }) => FastAddInput(
    name: name,
    sellingPrice: sellingPrice,
    quantity: quantity,
    buyingPrice: buyingPrice,
    wholesalePrice: wholesalePrice,
    lowStock: lowStock,
    unit: unit,
    trackEmpties: trackEmpties,
    emptyCrateValue: emptyCrateValue,
    hasManufacturer: hasManufacturer,
    selectedStoreId: selectedStoreId,
  );

  group('business-type-aware unit default', () {
    test('defaults to Bottle for a crate-tracking business', () {
      expect(fastAddDefaultUnit(tracksCrates: true), 'Bottle');
    });

    test('defaults to Pack otherwise', () {
      expect(fastAddDefaultUnit(tracksCrates: false), 'Pack');
    });

    test('an unset unit resolves to the business-type default (crate)', () {
      final result = resolveFastAdd(
        input(unit: null, hasManufacturer: true),
        ctx(tracksCrates: true),
      );
      expect(result, isA<FastAddIntent>());
      expect((result as FastAddIntent).unit, 'Bottle');
    });

    test('an unset unit resolves to the business-type default (non-crate)', () {
      final result = resolveFastAdd(input(unit: null), ctx());
      expect((result as FastAddIntent).unit, 'Pack');
    });

    test('an explicit unit is preserved', () {
      final result = resolveFastAdd(input(unit: 'Can'), ctx());
      expect((result as FastAddIntent).unit, 'Can');
    });
  });

  group('three-field minimum', () {
    test('a non-crate business saves with only name + selling + quantity', () {
      final result = resolveFastAdd(
        const FastAddInput(
          name: 'Eva Water 75cl',
          sellingPrice: '250',
          quantity: '6',
        ),
        ctx(),
      );
      expect(result, isA<FastAddIntent>());
      final intent = result as FastAddIntent;
      expect(intent.name, 'Eva Water 75cl');
      expect(intent.retailerPriceKobo, 25000);
      expect(intent.initialStock, 6);
      expect(intent.unit, 'Pack');
      expect(intent.storeId, 'store-1');
    });
  });

  group('required-field validation names the visible field', () {
    test('missing name → Product Name', () {
      final result = resolveFastAdd(input(name: '  '), ctx());
      expect(result, isA<FastAddInvalid>());
      expect((result as FastAddInvalid).field, 'Product Name');
    });

    test('missing selling price → Selling Price', () {
      final result = resolveFastAdd(input(sellingPrice: ''), ctx());
      expect((result as FastAddInvalid).field, 'Selling Price');
    });

    test('missing quantity → Quantity', () {
      final result = resolveFastAdd(input(quantity: ''), ctx());
      expect((result as FastAddInvalid).field, 'Quantity');
    });

    test('zero quantity → Quantity', () {
      final result = resolveFastAdd(input(quantity: '0'), ctx());
      expect((result as FastAddInvalid).field, 'Quantity');
    });
  });

  group('wholesaler mirror', () {
    test('blank wholesaler is stored equal to the selling price', () {
      final result = resolveFastAdd(input(sellingPrice: '500'), ctx());
      final intent = result as FastAddIntent;
      expect(intent.retailerPriceKobo, 50000);
      expect(intent.wholesalerPriceKobo, 50000);
    });

    test('a supplied wholesaler price is kept', () {
      final result = resolveFastAdd(
        input(sellingPrice: '500', wholesalePrice: '450'),
        ctx(),
      );
      expect((result as FastAddIntent).wholesalerPriceKobo, 45000);
    });
  });

  group('manufacturer-required-for-crate rule', () {
    test('crate business with no manufacturer → Manufacturer error', () {
      final result = resolveFastAdd(
        input(hasManufacturer: false),
        ctx(tracksCrates: true),
      );
      expect(result, isA<FastAddInvalid>());
      expect((result as FastAddInvalid).field, 'Manufacturer');
    });

    test('crate business with a manufacturer resolves', () {
      final result = resolveFastAdd(
        input(hasManufacturer: true),
        ctx(tracksCrates: true),
      );
      expect(result, isA<FastAddIntent>());
    });

    test('non-crate business needs no manufacturer', () {
      final result = resolveFastAdd(input(hasManufacturer: false), ctx());
      expect(result, isA<FastAddIntent>());
    });
  });

  group('buying price / Uncosted', () {
    test('blank buying price is accepted and produces an Uncosted product', () {
      final result = resolveFastAdd(input(buyingPrice: ''), ctx());
      final intent = result as FastAddIntent;
      expect(intent.buyingPriceKobo, 0);
      expect(intent.isUncosted, isTrue);
    });

    test('a role that cannot edit buying saves Uncosted even if a value is '
        'present', () {
      final result = resolveFastAdd(
        input(buyingPrice: '300'),
        ctx(canEditBuying: false),
      );
      final intent = result as FastAddIntent;
      expect(intent.buyingPriceKobo, 0);
      expect(intent.isUncosted, isTrue);
    });

    test('a supplied buying price is costed', () {
      final result = resolveFastAdd(input(buyingPrice: '300'), ctx());
      final intent = result as FastAddIntent;
      expect(intent.buyingPriceKobo, 30000);
      expect(intent.isUncosted, isFalse);
    });

    test('buying price above the selling price → Buying Price error', () {
      final result = resolveFastAdd(
        input(sellingPrice: '500', buyingPrice: '600'),
        ctx(),
      );
      expect(result, isA<FastAddInvalid>());
      expect((result as FastAddInvalid).field, 'Buying Price');
    });
  });

  group('store resolution', () {
    test('single-store context resolves the store without input', () {
      final result = resolveFastAdd(
        input(selectedStoreId: null),
        ctx(storeIds: const ['only-store']),
      );
      expect((result as FastAddIntent).storeId, 'only-store');
    });

    test('multi-store requires a selection', () {
      final result = resolveFastAdd(
        input(selectedStoreId: null),
        ctx(storeIds: const ['a', 'b']),
      );
      expect(result, isA<FastAddInvalid>());
      expect((result as FastAddInvalid).field, 'Store');
    });

    test('multi-store uses the supplied selection', () {
      final result = resolveFastAdd(
        input(selectedStoreId: 'b'),
        ctx(storeIds: const ['a', 'b']),
      );
      expect((result as FastAddIntent).storeId, 'b');
    });
  });

  group('effective crate tracking + value', () {
    test('non-crate business never tracks empties even if the toggle is on', () {
      final result = resolveFastAdd(
        input(trackEmpties: true, emptyCrateValue: '100'),
        ctx(),
      );
      final intent = result as FastAddIntent;
      expect(intent.trackEmpties, isFalse);
      expect(intent.emptyCrateValueKobo, isNull);
    });

    test('crate + bottle + value populates the crate deposit', () {
      final result = resolveFastAdd(
        input(
          unit: 'Bottle',
          trackEmpties: true,
          emptyCrateValue: '1200',
          hasManufacturer: true,
        ),
        ctx(tracksCrates: true),
      );
      final intent = result as FastAddIntent;
      expect(intent.trackEmpties, isTrue);
      expect(intent.emptyCrateValueKobo, 120000);
    });

    test('crate value is null on a non-bottle unit', () {
      final result = resolveFastAdd(
        input(
          unit: 'Pack',
          trackEmpties: true,
          emptyCrateValue: '1200',
          hasManufacturer: true,
        ),
        ctx(tracksCrates: true),
      );
      expect((result as FastAddIntent).emptyCrateValueKobo, isNull);
    });
  });

  group('low-stock default', () {
    test('blank low stock falls back to 5', () {
      final result = resolveFastAdd(input(lowStock: ''), ctx());
      expect((result as FastAddIntent).lowStockThreshold, 5);
    });

    test('a supplied low-stock threshold is kept', () {
      final result = resolveFastAdd(input(lowStock: '12'), ctx());
      expect((result as FastAddIntent).lowStockThreshold, 12);
    });
  });
}
