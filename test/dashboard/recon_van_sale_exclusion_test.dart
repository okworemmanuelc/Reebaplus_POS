// recon_van_sale_exclusion_test.dart
//
// #142 (van-sales spec §5.4, §8.1; the exclusion ACs moved here from #147 by
// #161) — from the FIRST road sale, a van order must appear in NO per-store
// order list, POS report, profit report, dashboard total, or
// `reconStoreFilter`-scoped reconciliation figure.
//
// #140 landed the predicate (`VanStores` / `vanStoresProvider`) and wired it.
// What it did NOT do is prove the wiring at the level that matters — a MONEY
// FIGURE. Its own suite (`test/stores/van_store_test.dart`,
// `test/dashboard/recon_van_exclusion_test.dart`) stops at the predicate
// boundary: "does `reconStoreFilter` return false for a van?". That leaves the
// real question — "does the CEO's Total Sales move when a driver sells?" —
// untested, and it is the one that was wrong.
//
// The method is the same as recon_van_remittance_test.dart's, and for the same
// reason: compute the reconciliation TWICE over one day, once with a shop sale
// alone and once with that sale PLUS road sales, and assert every headline
// figure is byte-identical. An exclusion that holds for `cashSalesKobo` but
// leaks into `totalSalesKobo` is exactly the kind of half-fix a per-figure test
// misses.
//
// ADR 0019 on why the window mattered: shipping the exclusions last "guarantees
// five slices during which every road sale inflates All-Stores revenue with zero
// cost against it".
//
// Overriding `currentBusinessIdProvider` with null makes every business-scoped
// provider emit its `whenAbsent` value without touching a database, so only the
// order feed and the store-filter inputs need real values.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/stores/van_store.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/report_revenue.dart';

const _biz = 'biz';
const _warehouse = 'wh';
const _van = 'van';
const _trip = 'trip-1';
final _day = DateTime(2026, 7, 26, 10);

StoreData _store(String id, {String kind = kStoreKindStore}) => StoreData(
  id: id,
  businessId: _biz,
  name: 'Location $id',
  location: null,
  kind: kind,
  isDeleted: false,
  createdAt: DateTime.utc(2026, 1, 1),
  lastUpdatedAt: DateTime.utc(2026, 1, 1),
);

ProductData _product(String id) => ProductData(
  id: id,
  businessId: _biz,
  name: 'Star 60cl',
  unit: 'bottle',
  buyingPriceKobo: 1000000,
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

/// One recognised sale. [buyingPriceKobo] 0 models a ROAD line: a van sale books
/// no per-sale COGS by design (ADR 0019 decision 1), which is precisely why an
/// unexcluded road sale reports at 100% margin.
OrderWithItems _sale({
  required String id,
  required String storeId,
  required int qty,
  required int unitPriceKobo,
  int buyingPriceKobo = 1000000,
  String? vanTripId,
  String status = 'completed',
}) {
  final product = _product('prod-1');
  return OrderWithItems(
    OrderData(
      id: id,
      businessId: _biz,
      orderNumber: id,
      customerId: null,
      totalAmountKobo: qty * unitPriceKobo,
      discountKobo: 0,
      netAmountKobo: qty * unitPriceKobo,
      amountPaidKobo: qty * unitPriceKobo,
      paymentType: 'cash',
      status: status,
      riderName: 'Pick-up Order',
      cancellationReason: null,
      barcode: null,
      staffId: null,
      storeId: storeId,
      confirmedBy: null,
      crateDepositPaidKobo: 0,
      vanTripId: vanTripId,
      completedAt: _day,
      cancelledAt: null,
      createdAt: _day,
      lastUpdatedAt: _day,
    ),
    [
      OrderItemDataWithProductData(
        OrderItemData(
          id: '$id-line',
          businessId: _biz,
          orderId: id,
          productId: product.id,
          storeId: storeId,
          quantity: qty,
          unitPriceKobo: unitPriceKobo,
          buyingPriceKobo: buyingPriceKobo,
          totalKobo: qty * unitPriceKobo,
          cataloguePriceKobo: null,
          priceSnapshot: null,
          createdAt: _day,
          lastUpdatedAt: _day,
        ),
        product,
      ),
    ],
    null,
  );
}

/// The whole surface a leaked road sale could disturb: the day-close headline
/// figures plus the cash card and the asset lines.
Map<String, int> _figures(ReconData d) => {
  'totalRevenueKobo': d.totalRevenueKobo,
  'totalSalesKobo': d.totalSalesKobo,
  'costedRevenueKobo': d.costedRevenueKobo,
  'cogsKobo': d.cogsKobo,
  'grossProfitKobo': d.grossProfitKobo,
  'netProfitKobo': d.netProfitKobo,
  'discountsKobo': d.discountsKobo,
  'refundsKobo': d.refundsKobo,
  'itemsSold': d.itemsSold,
  'uncostedItems': d.uncostedItems,
  'salesPaidNowKobo': d.salesPaidNowKobo,
  'salesOnCreditKobo': d.salesOnCreditKobo,
  'cashSalesKobo': d.cashSalesKobo,
  'cashInKobo': d.cashInKobo,
  'cashOutKobo': d.cashOutKobo,
  'netCashMovementKobo': d.netCashMovementKobo,
  'totalOwedKobo': d.totalOwedKobo,
};

Future<ReconData> computeWith(
  WidgetTester tester,
  List<OrderWithItems> orders, {
  String? lockedStoreId,
}) async {
  late ReconData out;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentBusinessIdProvider.overrideWithValue(null),
        allOrdersProvider.overrideWith((ref) => Stream.value(orders)),
        // reconStoreFilter's four inputs.
        selectableStoresProvider.overrideWithValue([_store(_warehouse)]),
        canViewAllStoresProvider.overrideWithValue(true),
        lockedStoreProvider.overrideWith(
          (ref) => ValueNotifier<String?>(lockedStoreId),
        ),
        vanStoresProvider.overrideWithValue(
          VanStores.of([_store(_warehouse), _store(_van, kind: kStoreKindVan)]),
        ),
      ],
      child: Consumer(
        builder: (_, ref, _) {
          out = computeReconData(
            ref,
            start: DateTime(2026, 7, 26),
            endExclusive: DateTime(2026, 7, 27),
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
  final shopSale = _sale(
    id: 'ord-shop',
    storeId: _warehouse,
    qty: 5,
    unitPriceKobo: 1000000, // ₦50,000 over the counter
  );
  // The spec §6.3 Tuesday: 60 crates at the ₦11,500 load price, no per-line
  // COGS, tagged to the trip.
  final roadSale = _sale(
    id: 'ord-road-1',
    storeId: _van,
    qty: 60,
    unitPriceKobo: 1150000,
    buyingPriceKobo: 0,
    vanTripId: _trip,
  );
  final roadSale2 = _sale(
    id: 'ord-road-2',
    storeId: _van,
    qty: 30,
    unitPriceKobo: 1150000,
    buyingPriceKobo: 0,
    vanTripId: _trip,
  );

  group('the reconciliation (All Stores, CEO)', () {
    testWidgets('road sales move NO figure the owner reads', (tester) async {
      final without = _figures(await computeWith(tester, [shopSale]));
      final with_ = _figures(
        await computeWith(tester, [shopSale, roadSale, roadSale2]),
      );

      expect(
        with_,
        equals(without),
        reason:
            'van orders are excluded from every per-store figure from the '
            'FIRST road sale (spec §8.1). A figure that moved means the '
            'exclusion is missing from that bucket — and because road sales '
            'carry no COGS, the leak reports at 100% margin.',
      );
    });

    testWidgets('the first road sale of the business leaks nothing either',
        (tester) async {
      // The window ADR 0019 closed: a business whose ONLY sales are road sales.
      // With no shop sale to hide behind, a leak is the whole figure.
      final d = await computeWith(tester, [roadSale, roadSale2]);

      expect(d.totalSalesKobo, 0);
      expect(d.totalRevenueKobo, 0);
      expect(d.grossProfitKobo, 0);
      expect(d.itemsSold, 0);
      expect(
        d.uncostedItems,
        0,
        reason:
            'road lines are uncosted BY DESIGN — they must not show up in the '
            'Uncosted transparency bucket as if someone forgot a cost',
      );
    });

    testWidgets('a shop sale still counts — the exclusion is van-only',
        (tester) async {
      final d = await computeWith(tester, [shopSale, roadSale]);

      expect(d.totalSalesKobo, 5 * 1000000);
      expect(d.itemsSold, 5);
      expect(d.cogsKobo, 5 * 1000000);
    });

    testWidgets('a manager locked to the warehouse sees the same figures',
        (tester) async {
      // Defence in depth: with a concrete store locked the van fails the
      // store-match anyway, so this pins that the two mechanisms agree rather
      // than one masking the other's absence.
      final d = await computeWith(
        tester,
        [shopSale, roadSale],
        lockedStoreId: _warehouse,
      );

      expect(d.totalSalesKobo, 5 * 1000000);
      expect(d.itemsSold, 5);
    });
  });

  group('the shared Total Sales definition (#176)', () {
    test('computeTotalSalesKobo excludes road lines when given the van scope',
        () {
      final vans = VanStores.of([
        _store(_warehouse),
        _store(_van, kind: kStoreKindVan),
      ]);

      // This is the exact call the Profit Report's headline tile and the Home
      // dashboard make. Before #142 the Profit Report passed no `inScope`, so
      // its Total Sales counted road revenue while the Revenue / COGS / Gross
      // Profit figures under it did not — one screen, two answers.
      expect(
        computeTotalSalesKobo(
          [shopSale, roadSale, roadSale2],
          inScope: vans.isNotVan,
        ),
        5 * 1000000,
      );

      // Unscoped is the leak, kept here so the assertion above cannot be read
      // as "the function does this anyway".
      expect(
        computeTotalSalesKobo([shopSale, roadSale, roadSale2]),
        5 * 1000000 + 60 * 1150000 + 30 * 1150000,
      );
    });
  });

  group('the profit report and the dashboard', () {
    // Both surfaces filter with the same predicate over the same order set
    // (`profit_report_screen._compute` and `home_screen`'s
    // `filteredOrdersWithItems`), so the contract worth pinning is the
    // predicate's behaviour on a road order — including the belt-and-braces
    // case where the tag is present.
    test('a van order is excluded by store, and a tagged order is identifiable '
        'independently of it', () {
      final vans = VanStores.of([
        _store(_warehouse),
        _store(_van, kind: kStoreKindVan),
      ]);

      expect(vans.isVan(roadSale.order.storeId), isTrue);
      expect(vans.isVan(shopSale.order.storeId), isFalse);
      // The tag is attribution (#145/#147 read it); the store is the fact the
      // exclusion keys on. Both are present on a real road sale.
      expect(roadSale.order.vanTripId, _trip);
      expect(shopSale.order.vanTripId, isNull);
    });
  });
}
