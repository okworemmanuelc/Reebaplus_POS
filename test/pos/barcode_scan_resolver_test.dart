// barcode_scan_resolver_test.dart
//
// #317 — the pure scan resolver. Every outcome a scanned code can have, without
// a camera, a widget or a database: sellable, stock 0 in this store, not stocked
// in this store, cart == stock, switched off, unknown.
// #318 — two or more matches → "Which one?" (ScanChooseAmong), and the
// single-product checks (resolveProduct) re-run for the picked row.

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/pos/services/barcode_scan_resolver.dart';

ProductData _product({
  String id = 'p-1',
  String name = 'Panadol',
  bool isAvailable = true,
  int retailerPriceKobo = 100000,
  int wholesalerPriceKobo = 80000,
}) {
  final now = DateTime(2026, 10, 1);
  return ProductData(
    id: id,
    businessId: 'biz-1',
    name: name,
    unit: 'Bottle',
    retailerPriceKobo: retailerPriceKobo,
    wholesalerPriceKobo: wholesalerPriceKobo,
    buyingPriceKobo: 0,
    lowStockThreshold: 5,
    avgDailySales: 0,
    leadTimeDays: 0,
    safetyStockQty: 0,
    monthlyTargetUnits: 0,
    isAvailable: isAvailable,
    isDeleted: false,
    trackEmpties: false,
    allowFractionalSales: false,
    emptyCrateValueKobo: 0,
    version: 1,
    createdAt: now,
    lastUpdatedAt: now,
    barcode: 'BC-1',
  );
}

void main() {
  ScanOutcome resolve({
    ProductData? match,
    List<ProductDataWithStock> store = const [],
    double cartQty = 0,
    PriceTier tier = PriceTier.retailer,
  }) {
    return resolveBarcodeScan(
      code: 'BC-1',
      matches: match == null ? const [] : [match],
      storeProducts: store,
      cartQtyOf: (_) => cartQty,
      tier: tier,
    );
  }

  test('sellable → add sheet with store stock, cart qty and tier', () {
    final p = _product();
    final outcome = resolve(
      match: p,
      store: [ProductDataWithStock(product: p, totalStock: 10)],
      cartQty: 2,
      tier: PriceTier.wholesaler,
    );

    expect(outcome, isA<ScanAddSheet>());
    final sheet = outcome as ScanAddSheet;
    expect(sheet.product.id, p.id);
    expect(sheet.stock, 10);
    expect(sheet.inCart, 2);
    expect(sheet.tier, PriceTier.wholesaler);
  });

  test('stock 0 in this store → out of stock here', () {
    final p = _product();
    final outcome = resolve(
      match: p,
      store: [ProductDataWithStock(product: p, totalStock: 0)],
    );

    expect(outcome, isA<ScanOutOfStockHere>());
    expect((outcome as ScanOutOfStockHere).product.id, p.id);
  });

  test('not stocked in this store (absent from the list) → out of stock here', () {
    final p = _product();
    final other = _product(id: 'p-2', name: 'Other');
    final outcome = resolve(
      match: p,
      store: [ProductDataWithStock(product: other, totalStock: 50)],
    );

    expect(outcome, isA<ScanOutOfStockHere>());
  });

  test('cart already holds all the stock → all in cart', () {
    final p = _product();
    final outcome = resolve(
      match: p,
      store: [ProductDataWithStock(product: p, totalStock: 5)],
      cartQty: 5,
    );

    expect(outcome, isA<ScanAllInCart>());
    expect((outcome as ScanAllInCart).stock, 5);
  });

  test('one below stock is still sellable', () {
    final p = _product();
    final outcome = resolve(
      match: p,
      store: [ProductDataWithStock(product: p, totalStock: 5)],
      cartQty: 4,
    );

    expect(outcome, isA<ScanAddSheet>());
  });

  test('switched off for sale → switched off, even with stock', () {
    final p = _product(isAvailable: false);
    final outcome = resolve(
      match: p,
      store: [ProductDataWithStock(product: p, totalStock: 10)],
    );

    expect(outcome, isA<ScanSwitchedOff>());
    expect((outcome as ScanSwitchedOff).product.id, p.id);
  });

  test('switched off wins over out of stock', () {
    final p = _product(isAvailable: false);
    expect(resolve(match: p), isA<ScanSwitchedOff>());
  });

  test('no match → unknown, carrying the code', () {
    final outcome = resolve();

    expect(outcome, isA<ScanUnknown>());
    expect((outcome as ScanUnknown).code, 'BC-1');
  });

  group('more than one match — "Which one?" (#318)', () {
    test('two matches → choose among both, in lookup order', () {
      final a = _product(id: 'p-a', name: 'Panadol Extra');
      final b = _product(
        id: 'p-b',
        name: 'Panadol Junior',
        retailerPriceKobo: 50000,
        wholesalerPriceKobo: 40000,
      );
      final outcome = resolveBarcodeScan(
        code: 'BC-1',
        matches: [a, b],
        storeProducts: [
          ProductDataWithStock(product: a, totalStock: 10),
          ProductDataWithStock(product: b, totalStock: 3),
        ],
        cartQtyOf: (_) => 0,
        tier: PriceTier.wholesaler,
      );

      expect(outcome, isA<ScanChooseAmong>());
      final choices = (outcome as ScanChooseAmong).choices;
      expect(choices.map((c) => c.product.id), ['p-a', 'p-b']);
      // Price at the active tier, stock in the active store.
      expect(choices.map((c) => c.unitPriceKobo), [80000, 40000]);
      expect(choices.map((c) => c.stock), [10, 3]);
      expect(choices.every((c) => c.isSellable), isTrue);
    });

    test('unsellable matches are still listed, each with its own reason', () {
      final off = _product(id: 'p-off', name: 'A', isAvailable: false);
      final none = _product(id: 'p-none', name: 'B');
      final full = _product(id: 'p-full', name: 'C');
      final ok = _product(id: 'p-ok', name: 'D');
      final outcome = resolveBarcodeScan(
        code: 'BC-1',
        matches: [off, none, full, ok],
        storeProducts: [
          ProductDataWithStock(product: off, totalStock: 10),
          ProductDataWithStock(product: full, totalStock: 2),
          ProductDataWithStock(product: ok, totalStock: 4),
        ],
        // Each product's OWN cart qty.
        cartQtyOf: (id) => id == 'p-full' ? 2 : 1,
        tier: PriceTier.retailer,
      );

      final choices = (outcome as ScanChooseAmong).choices;
      expect(choices, hasLength(4));
      expect(choices[0].outcome, isA<ScanSwitchedOff>());
      expect(choices[1].outcome, isA<ScanOutOfStockHere>());
      expect(choices[1].stock, 0);
      expect(choices[2].outcome, isA<ScanAllInCart>());
      expect(choices[3].outcome, isA<ScanAddSheet>());
      expect((choices[3].outcome as ScanAddSheet).inCart, 1);
      expect(choices.map((c) => c.isSellable), [false, false, false, true]);
    });

    test('a single match never asks "Which one?"', () {
      final p = _product();
      final outcome = resolve(
        match: p,
        store: [ProductDataWithStock(product: p, totalStock: 10)],
      );

      expect(outcome, isNot(isA<ScanChooseAmong>()));
      expect(outcome, isA<ScanAddSheet>());
    });

    test('resolveProduct re-runs the single checks for the picked product', () {
      final picked = _product(id: 'p-b', name: 'Panadol Junior');
      final other = _product(id: 'p-a', name: 'Panadol Extra');
      final store = [
        ProductDataWithStock(product: other, totalStock: 50),
        ProductDataWithStock(product: picked, totalStock: 3),
      ];

      final sellable = resolveProduct(
        product: picked,
        storeProducts: store,
        cartQty: 1,
        tier: PriceTier.retailer,
      );
      expect(sellable, isA<ScanAddSheet>());
      final sheet = sellable as ScanAddSheet;
      // Its own stock and cart qty, not the other match's.
      expect(sheet.product.id, 'p-b');
      expect(sheet.stock, 3);
      expect(sheet.inCart, 1);

      expect(
        resolveProduct(
          product: picked,
          storeProducts: store,
          cartQty: 3,
          tier: PriceTier.retailer,
        ),
        isA<ScanAllInCart>(),
      );
      expect(
        resolveProduct(
          product: _product(id: 'p-b', isAvailable: false),
          storeProducts: store,
          cartQty: 0,
          tier: PriceTier.retailer,
        ),
        isA<ScanSwitchedOff>(),
      );
      expect(
        resolveProduct(
          product: _product(id: 'p-c'),
          storeProducts: store,
          cartQty: 0,
          tier: PriceTier.retailer,
        ),
        isA<ScanOutOfStockHere>(),
      );
    });
  });
}
