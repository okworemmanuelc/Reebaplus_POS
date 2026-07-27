// recon_stock_deletions_term_test.dart
//
// #193 follow-up: pins WHEN the stock card's `stockDeletionsKobo` term can be
// non-zero, so nobody deletes the line as dead — or re-adds it blindly.
//
// The term is valued at CURRENT cost, per ADR 0014 ("this card keeps current
// cost on purpose" so its closing identity ties to the rewound perpetual
// figure). Current cost is resolved through `productById`, built from
// products-with-stock, which filters `isDeleted.not()`. So the term's value
// hinges on ONE thing: whether the product carrying the `product_deleted`
// write-off is still resolvable.
//
//   • Deleted product (the normal delete) → no current cost → term is ₦0. The
//     loss is reported instead by the snapshot-valued `deletionCostKobo` (#193).
//   • Product STILL LIVE while a write-off exists → term is non-zero. This is a
//     REACHABLE production state, not a hypothetical: `_confirmDelete` commits
//     the write-off first and soft-deletes second, so a `softDeleteProduct`
//     failure leaves exactly this shape. A peer device can also hold it if the
//     `products` push orphans while the adjustment rows push cleanly.
//
// Overriding `currentBusinessIdProvider` with null makes every business-scoped
// provider emit its `whenAbsent` value without touching a database, so only the
// feeds under test and the store-filter inputs need real values.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/stores/van_store.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';

const _biz = 'biz';
const _store1 = 'store-1';
const _prod = 'prod-1';
const _adj = 'adj-1';

final _day = DateTime(2026, 7, 26, 10);
final _julStart = DateTime(2026, 7, 1);
final _augStart = DateTime(2026, 8, 1);

StoreData _storeRow(String id) => StoreData(
  id: id,
  businessId: _biz,
  name: 'Location $id',
  location: null,
  kind: kStoreKindStore,
  isDeleted: false,
  createdAt: DateTime.utc(2026, 1, 1),
  lastUpdatedAt: DateTime.utc(2026, 1, 1),
);

ProductData _product({required int buyingPriceKobo}) => ProductData(
  id: _prod,
  businessId: _biz,
  name: 'Star 60cl',
  unit: 'bottle',
  buyingPriceKobo: buyingPriceKobo,
  retailerPriceKobo: 1150000,
  wholesalerPriceKobo: 1100000,
  isAvailable: true,
  isDeleted: false,
  lowStockThreshold: 0,
  avgDailySales: 0,
  leadTimeDays: 0,
  safetyStockQty: 0,
  monthlyTargetUnits: 0,
  emptyCrateValueKobo: 0,
  trackEmpties: false,
  allowFractionalSales: false,
  version: 1,
  createdAt: DateTime.utc(2026, 1, 1),
  lastUpdatedAt: DateTime.utc(2026, 1, 1),
);

/// The `product_deleted` write-off adjustment the delete sweep posts, carrying
/// its write-time FIFO snapshot (`valueKobo`).
StockAdjustmentData _writeOffAdjustment({
  required int units,
  required int snapshotValueKobo,
}) => StockAdjustmentData(
  id: _adj,
  businessId: _biz,
  productId: _prod,
  storeId: _store1,
  quantityDiff: -units,
  reason: InventoryDao.productDeletedReason,
  performedBy: null,
  unitCostKobo: (snapshotValueKobo / units).round(),
  valueKobo: snapshotValueKobo,
  createdAt: _day,
  lastUpdatedAt: _day,
);

/// The ledger row that adjustment writes, which is what the flow loop classifies.
StockTransactionData _writeOffTxn({required int units}) => StockTransactionData(
  id: 'txn-1',
  businessId: _biz,
  productId: _prod,
  locationId: _store1,
  quantityDelta: -units,
  movementType: 'adjustment',
  orderId: null,
  adjustmentId: _adj,
  transferId: null,
  performedBy: null,
  voidedAt: null,
  voidedBy: null,
  voidReason: null,
  createdAt: _day,
  lastUpdatedAt: _day,
);

Future<ReconData> computeWith(
  WidgetTester tester, {
  required List<ProductDataWithStock> productsWithStock,
  List<StockAdjustmentData> adjustments = const [],
  List<StockTransactionData> stockTxns = const [],
}) async {
  late ReconData out;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentBusinessIdProvider.overrideWithValue(null),
        productsWithStockProvider.overrideWith(
          (ref, arg) => Stream.value(productsWithStock),
        ),
        allStockAdjustmentsProvider.overrideWith(
          (ref) => Stream.value(adjustments),
        ),
        allStockTransactionsProvider.overrideWith(
          (ref) => Stream.value(stockTxns),
        ),
        selectableStoresProvider.overrideWithValue([_storeRow(_store1)]),
        canViewAllStoresProvider.overrideWithValue(true),
        lockedStoreProvider.overrideWith((ref) => ValueNotifier<String?>(null)),
        vanStoresProvider.overrideWithValue(VanStores.of([_storeRow(_store1)])),
      ],
      child: Consumer(
        builder: (_, ref, _) {
          out = computeReconData(
            ref,
            start: _julStart,
            endExclusive: _augStart,
            isCeo: true,
          );
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  await tester.pump();
  return out;
}

void main() {
  const units = 8;
  const cost = 15000;
  const snapshot = units * cost; // 120,000

  testWidgets('the NORMAL delete leaves the card term at ₦0 — the deleted '
      'product has no resolvable current cost', (tester) async {
    final d = await computeWith(
      tester,
      // The product is deleted, so products-with-stock no longer lists it. This
      // is what `productById` sees after any successful delete.
      productsWithStock: const [],
      adjustments: [
        _writeOffAdjustment(units: units, snapshotValueKobo: snapshot),
      ],
      stockTxns: [_writeOffTxn(units: units)],
    );

    // The card term is ₦0 — ADR 0014's current-cost basis cannot value it.
    expect(d.stockDeletionsKobo, 0);
    // But the loss is NOT lost: the snapshot-valued P&L figure carries it, and
    // that is the figure net profit and the period result are built from (#193).
    expect(d.deletionCostKobo, snapshot);
    expect(d.netProfitKobo, -snapshot);
  });

  testWidgets('a write-off on a STILL-LIVE product makes the card term '
      'non-zero — the term is reachable, not structurally dead', (tester) async {
    // `_confirmDelete` commits the write-off BEFORE soft-deleting, so a
    // `softDeleteProduct` failure leaves the write-off recorded against a
    // product that is still listed and still costed. Stock really did leave the
    // shelf, the product really is still sellable-in-catalogue, so the card
    // books the outflow at current cost and its equation ties.
    final d = await computeWith(
      tester,
      productsWithStock: [
        ProductDataWithStock(
          product: _product(buyingPriceKobo: cost),
          totalStock: 0, // the write-off already zeroed it
        ),
      ],
      adjustments: [
        _writeOffAdjustment(units: units, snapshotValueKobo: snapshot),
      ],
      stockTxns: [_writeOffTxn(units: units)],
    );

    // THE POINT: non-zero. A negative signed flow term — stock leaving.
    expect(d.stockDeletionsKobo, -snapshot);
    expect(d.stockDeletionsKobo, isNot(0));

    // And with the product resolvable, the card's equation ties by construction:
    // it opened holding those 8 units and closed at zero.
    expect(d.stockOpeningKobo, snapshot);
    expect(d.stockExpectedClosingKobo, 0);
    expect(d.stockDerivedClosingKobo, d.stockExpectedClosingKobo);
  });

  testWidgets('an UNCOSTED live product still leaves the card term at ₦0, '
      'while the P&L keeps the snapshot', (tester) async {
    // cost <= 0 is the card's documented "uncosted units carry no value" rule —
    // the one case where a ₦0 term is correct even for a live product.
    final d = await computeWith(
      tester,
      productsWithStock: [
        ProductDataWithStock(
          product: _product(buyingPriceKobo: 0),
          totalStock: 0,
        ),
      ],
      adjustments: [
        _writeOffAdjustment(units: units, snapshotValueKobo: snapshot),
      ],
      stockTxns: [_writeOffTxn(units: units)],
    );

    expect(d.stockDeletionsKobo, 0);
    expect(d.deletionCostKobo, snapshot);
  });

  testWidgets('a voided write-off ledger row books no card outflow but still '
      'reports the loss', (tester) async {
    // Documents the one asymmetry between the two figures: the card reads the
    // stock_transactions ledger (which honours voidedAt) while the loss reducer
    // reads stock_adjustments (which has no void column). Pinned so a future
    // void path cannot silently double-count or silently drop.
    final voided = StockTransactionData(
      id: 'txn-1',
      businessId: _biz,
      productId: _prod,
      locationId: _store1,
      quantityDelta: -units,
      movementType: 'adjustment',
      orderId: null,
      adjustmentId: _adj,
      transferId: null,
      performedBy: null,
      voidedAt: _day,
      voidedBy: null,
      voidReason: 'test',
      createdAt: _day,
      lastUpdatedAt: _day,
    );
    final d = await computeWith(
      tester,
      productsWithStock: [
        ProductDataWithStock(
          product: _product(buyingPriceKobo: cost),
          totalStock: 0,
        ),
      ],
      adjustments: [
        _writeOffAdjustment(units: units, snapshotValueKobo: snapshot),
      ],
      stockTxns: [voided],
    );

    expect(d.stockDeletionsKobo, 0); // voided ledger row is skipped
    expect(d.deletionCostKobo, snapshot); // the adjustment still reports
  });
}
