// barcode_scan_resolver_test.dart
//
// #317 — the pure scan resolver. Every outcome a scanned code can have, without
// a camera, a widget or a database: sellable, stock 0 in this store, not stocked
// in this store, cart == stock, switched off, unknown.

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/pos/services/barcode_scan_resolver.dart';

ProductData _product({
  String id = 'p-1',
  String name = 'Panadol',
  bool isAvailable = true,
}) {
  final now = DateTime(2026, 10, 1);
  return ProductData(
    id: id,
    businessId: 'biz-1',
    name: name,
    unit: 'Bottle',
    retailerPriceKobo: 100000,
    wholesalerPriceKobo: 80000,
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
      match: match,
      storeProducts: store,
      cartQty: cartQty,
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
}
