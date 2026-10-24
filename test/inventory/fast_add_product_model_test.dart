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
    bool sellsOnePrice = false,
    int? existingWholesalerPriceKobo,
  }) => FastAddContext(
    tracksCrates: tracksCrates,
    canEditBuying: canEditBuying,
    storeIds: storeIds,
    sellsOnePrice: sellsOnePrice,
    existingWholesalerPriceKobo: existingWholesalerPriceKobo,
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

  group('optional unit (#108)', () {
    // The form pre-fills the trade's Lexicon unit as a clearable suggestion, so
    // the model no longer invents a trade default: a blank/cleared unit means
    // the user deliberately chose "no unit" and resolves to null.
    test('an unset unit resolves to null — no unit, no trade default', () {
      final result = resolveFastAdd(
        input(unit: null, hasManufacturer: true),
        ctx(tracksCrates: true),
      );
      expect(result, isA<FastAddIntent>());
      expect((result as FastAddIntent).unit, isNull);
    });

    test('a cleared (blank) unit resolves to null', () {
      final result = resolveFastAdd(input(unit: ''), ctx());
      expect((result as FastAddIntent).unit, isNull);
    });

    test('a whitespace-only unit resolves to null', () {
      final result = resolveFastAdd(input(unit: '   '), ctx());
      expect((result as FastAddIntent).unit, isNull);
    });

    test('an explicit unit is preserved (and trimmed)', () {
      final result = resolveFastAdd(input(unit: '  Can '), ctx());
      expect((result as FastAddIntent).unit, 'Can');
    });

    test('a null unit is not a bottle → no crate deposit value', () {
      // A crate business tracking empties: with no unit the deposit value is
      // dropped because a null unit is never a bottle.
      final result = resolveFastAdd(
        input(unit: null, hasManufacturer: true, emptyCrateValue: '500'),
        ctx(tracksCrates: true),
      );
      expect((result as FastAddIntent).unit, isNull);
      expect(result.emptyCrateValueKobo, isNull);
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
      // No unit supplied and none invented (#108): a blank field is "no unit".
      expect(intent.unit, isNull);
      expect(intent.storeId, 'store-1');
    });
  });

  group('required-field validation names the visible field', () {
    test('missing name → Product Name', () {
      final result = resolveFastAdd(input(name: '  '), ctx());
      expect(result, isA<FastAddInvalid>());
      expect((result as FastAddInvalid).field, FastAddField.name);
    });

    test('missing selling price → Selling Price', () {
      final result = resolveFastAdd(input(sellingPrice: ''), ctx());
      expect((result as FastAddInvalid).field, FastAddField.sellingPrice);
    });

    test('missing quantity → Quantity', () {
      final result = resolveFastAdd(input(quantity: ''), ctx());
      expect((result as FastAddInvalid).field, FastAddField.quantity);
    });

    test('zero quantity → Quantity', () {
      final result = resolveFastAdd(input(quantity: '0'), ctx());
      expect((result as FastAddInvalid).field, FastAddField.quantity);
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

    test('one-price shop, ADD: wholesaler = retail (#493)', () {
      final result = resolveFastAdd(
        input(sellingPrice: '500', wholesalePrice: '450'),
        ctx(sellsOnePrice: true),
      );
      final intent = result as FastAddIntent;
      expect(intent.retailerPriceKobo, 50000);
      expect(intent.wholesalerPriceKobo, 50000);
    });

    test('one-price shop, EDIT: the saved wholesaler price is kept (#493)', () {
      final result = resolveFastAdd(
        input(sellingPrice: '600', wholesalePrice: '600'),
        ctx(sellsOnePrice: true, existingWholesalerPriceKobo: 45000),
      );
      final intent = result as FastAddIntent;
      expect(intent.retailerPriceKobo, 60000);
      expect(intent.wholesalerPriceKobo, 45000);
    });
  });

  group('manufacturer is optional', () {
    test(
      'crate business with no manufacturer resolves (can be added later)',
      () {
        final result = resolveFastAdd(
          input(hasManufacturer: false),
          ctx(tracksCrates: true),
        );
        expect(result, isA<FastAddIntent>());
      },
    );

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
      expect((result as FastAddInvalid).field, FastAddField.buyingPrice);
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
      expect((result as FastAddInvalid).field, FastAddField.store);
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
    test(
      'non-crate business never tracks empties even if the toggle is on',
      () {
        final result = resolveFastAdd(
          input(trackEmpties: true, emptyCrateValue: '100'),
          ctx(),
        );
        final intent = result as FastAddIntent;
        expect(intent.trackEmpties, isFalse);
        expect(intent.emptyCrateValueKobo, isNull);
      },
    );

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

  group('#487: receive mode and "how many in one"', () {
    test('Receive Stock needs no store: the quantity goes onto the delivery '
        'list', () {
      final result = resolveFastAdd(
        input(quantity: '20'),
        const FastAddContext(
          tracksCrates: false,
          canEditBuying: true,
          storeIds: ['a', 'b'],
          routesToReceiveCart: true,
        ),
      );
      final intent = result as FastAddIntent;
      expect(intent.storeId, isNull);
      expect(intent.initialStock, 20);
    });

    test('Receive Stock still needs a quantity above 0', () {
      final result = resolveFastAdd(
        input(quantity: '0'),
        const FastAddContext(
          tracksCrates: false,
          canEditBuying: true,
          storeIds: ['a'],
          routesToReceiveCart: true,
        ),
      );
      expect((result as FastAddInvalid).field, FastAddField.quantity);
    });

    FastAddResult withPack(String? unit, String pack, {bool crates = true}) =>
        resolveFastAdd(
          FastAddInput(
            name: 'Star 60cl',
            sellingPrice: '500',
            quantity: '1',
            unit: unit,
            unitsPerPack: pack,
          ),
          ctx(tracksCrates: crates),
        );

    test('a count is kept for a unit that offers the box', () {
      expect((withPack('Bottle', '12') as FastAddIntent).unitsPerPack, 12);
      expect(
        (withPack('Pack', ' 6 ', crates: false) as FastAddIntent).unitsPerPack,
        6,
      );
    });

    test('blank, zero, another unit, or a non-crate Bottle: no count', () {
      expect((withPack('Bottle', '') as FastAddIntent).unitsPerPack, isNull);
      expect((withPack('Bottle', '0') as FastAddIntent).unitsPerPack, isNull);
      expect((withPack('Can', '12') as FastAddIntent).unitsPerPack, isNull);
      expect(
        (withPack('Bottle', '12', crates: false) as FastAddIntent).unitsPerPack,
        isNull,
      );
    });
  });
}
