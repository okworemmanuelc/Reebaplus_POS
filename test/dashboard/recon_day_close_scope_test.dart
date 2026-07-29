// recon_day_close_scope_test.dart
//
// #191 (PRD #155 slice #174, ADR 0022 — supersedes ADR 0021 §2's scope bullet) —
// a persisted day close is ONE durable record of what the whole BUSINESS's day
// looked like.
//
// What went wrong: the snapshot's natural key is (business, day), but its figures
// were computed in whatever store scope the FIRST opener happened to be locked
// to, and the delta badges rendered only while the viewer's scope still matched
// that captured scope. Combined with first-writer-wins, whoever opened the day
// first permanently decided what that day's baseline meant — and once a
// per-store snapshot existed, a business-wide baseline could never be captured.
// Production already had exactly that: one `daily_closings` row with a non-null
// `store_scope_id`, so a CEO at All Stores saw no banner and no badges for that
// day, forever.
//
// Two halves, both pinned here:
//
//   1. The CAPTURE is business-wide. `computeReconData(businessWide: true)`
//      ignores the active store lock AND the viewer's store confinement, so
//      whoever opens the finished day first freezes the SAME figures.
//   2. The COMPARISON is business-wide and ungated. `reconClosingComparisonOrNull`
//      never consults `store_scope_id`, so a day frozen inside one store's lock
//      — including the legacy production row — is read as business-wide and
//      stops being badge-blind.
//
// Method: drive the REAL compute through a ProviderScope with the store-filter
// inputs overridden (the seam recon_van_sale_exclusion_test.dart uses), freeze a
// snapshot row from one scope's answer, then compare it from another scope.
// Overriding `currentBusinessIdProvider` with null makes every business-scoped
// provider emit its `whenAbsent` value without touching a database, so only the
// order feed and the filter's four inputs need real values.

import 'dart:io';

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
const _warehouse = 'wh';
const _branch = 'br';
const _van = 'van';
final _day = DateTime(2026, 7, 26, 10);

/// One product line's money, so the expectations below read as counts.
const _price = 1000000; // ₦10,000 a crate
const _cost = 600000; // ₦6,000 a crate

/// Crates on hand per store, so a store-scoped stock read and an unscoped one
/// give different answers. `stockExpectedClosingKobo` — a FROZEN and BADGED
/// figure — is `on-hand × cost` rewound over the period, so this is what proves
/// a business-wide compute reads the UNSCOPED totals.
const _warehouseStock = 10;
const _branchStock = 4;

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

ProductData _product() => ProductData(
  id: 'prod-1',
  businessId: _biz,
  name: 'Star 60cl',
  unit: 'bottle',
  buyingPriceKobo: _cost,
  retailerPriceKobo: _price,
  wholesalerPriceKobo: _price,
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

/// One recognised cash sale of [qty] crates in [storeId].
OrderWithItems _sale({
  required String id,
  required String storeId,
  required int qty,
  int buyingPriceKobo = _cost,
  String? vanTripId,
}) {
  final product = _product();
  return OrderWithItems(
    OrderData(
      id: id,
      businessId: _biz,
      orderNumber: id,
      customerId: null,
      totalAmountKobo: qty * _price,
      discountKobo: 0,
      netAmountKobo: qty * _price,
      amountPaidKobo: qty * _price,
      paymentType: 'cash',
      status: 'completed',
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
          unitPriceKobo: _price,
          buyingPriceKobo: buyingPriceKobo,
          totalKobo: qty * _price,
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

/// A persisted `daily_closings` row carrying [f]. [storeScopeId] models the
/// LEGACY column: rows written before #191 stamped the opener's active lock,
/// rows written after it are always business-wide (null).
DailyClosingData _snapshotRow(
  DailyClosingFigures f, {
  String? storeScopeId,
  String? reviewedBy,
}) {
  final ts = DateTime.utc(2026, 7, 27, 8);
  return DailyClosingData(
    id: 'snap-1',
    businessId: _biz,
    businessDate: '2026-07-26',
    storeScopeId: storeScopeId,
    totalSalesKobo: f.totalSalesKobo,
    refundsKobo: f.refundsKobo,
    discountsKobo: f.discountsKobo,
    cogsKobo: f.cogsKobo,
    grossProfitKobo: f.grossProfitKobo,
    netProfitKobo: f.netProfitKobo,
    expensesKobo: f.expensesKobo,
    damagesCostKobo: f.damagesCostKobo,
    cashSalesKobo: f.cashSalesKobo,
    cashInKobo: f.cashInKobo,
    cashOutKobo: f.cashOutKobo,
    netCashMovementKobo: f.netCashMovementKobo,
    stockCogsKobo: f.stockCogsKobo,
    stockExpectedClosingKobo: f.stockExpectedClosingKobo,
    itemsSold: f.itemsSold,
    shortageUnits: f.shortageUnits,
    reviewedBy: reviewedBy,
    reviewedAt: ts,
    createdAt: ts,
    lastUpdatedAt: ts,
  );
}

/// Runs the real reconciliation compute for the day in the scope described by
/// [lockedStoreId] / [selectable] / [canViewAll], and returns BOTH answers: the
/// figures the cards show (`viewer`, §12.1 store-scoped) and the business-wide
/// basis the day close freezes and compares against (`wide`, #191).
Future<({ReconData viewer, ReconData wide})> computeWith(
  WidgetTester tester,
  List<OrderWithItems> orders, {
  String? lockedStoreId,
  List<StoreData>? selectable,
  bool canViewAll = true,
}) async {
  // Tear the previous ProviderScope down first so two computes in one test never
  // share a container (the second could read the first's stream value).
  await tester.pumpWidget(const SizedBox.shrink());
  late ReconData viewer;
  late ReconData wide;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // No business bound ⇒ every business-scoped provider emits its
        // `whenAbsent` value and never reaches for a database.
        currentBusinessIdProvider.overrideWithValue(null),
        allOrdersProvider.overrideWith((ref) => Stream.value(orders)),
        // Stock on hand per scope — the family key IS the store scope, so this
        // is what distinguishes a store-scoped compute from a business-wide one.
        productsWithStockProvider.overrideWith(
          (ref, storeId) => Stream.value([
            ProductDataWithStock(
              product: _product(),
              totalStock: switch (storeId) {
                _warehouse => _warehouseStock,
                _branch => _branchStock,
                // null = All Stores / business-wide.
                _ => _warehouseStock + _branchStock,
              },
            ),
          ]),
        ),
        // reconStoreFilter's four inputs.
        selectableStoresProvider.overrideWithValue(
          selectable ?? [_store(_warehouse), _store(_branch)],
        ),
        canViewAllStoresProvider.overrideWithValue(canViewAll),
        lockedStoreProvider.overrideWith(
          (ref) => ValueNotifier<String?>(lockedStoreId),
        ),
        vanStoresProvider.overrideWithValue(
          VanStores.of([
            _store(_warehouse),
            _store(_branch),
            _store(_van, kind: kStoreKindVan),
          ]),
        ),
      ],
      child: Consumer(
        builder: (_, ref, _) {
          viewer = computeReconData(
            ref,
            start: DateTime(2026, 7, 26),
            endExclusive: DateTime(2026, 7, 27),
            isCeo: true,
          );
          wide = computeReconData(
            ref,
            start: DateTime(2026, 7, 26),
            endExclusive: DateTime(2026, 7, 27),
            isCeo: true,
            businessWide: true,
          );
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  await tester.pump();
  return (viewer: viewer, wide: wide);
}

/// Pumps a throwaway consumer and hands back the business-wide predicate.
Future<bool Function(String?)> buildBusinessWideFilter(
  WidgetTester tester, {
  required List<StoreData> selectable,
  required bool canViewAll,
  String? lockedStoreId,
}) async {
  late bool Function(String?) filter;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        selectableStoresProvider.overrideWithValue(selectable),
        canViewAllStoresProvider.overrideWithValue(canViewAll),
        lockedStoreProvider.overrideWith(
          (ref) => ValueNotifier<String?>(lockedStoreId),
        ),
        vanStoresProvider.overrideWithValue(
          VanStores.of([
            _store(_warehouse),
            _store(_branch),
            _store(_van, kind: kStoreKindVan),
          ]),
        ),
      ],
      child: Consumer(
        builder: (_, ref, _) {
          filter = reconStoreFilter(ref, businessWide: true);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return filter;
}

void main() {
  final warehouseSale = _sale(id: 'ord-wh', storeId: _warehouse, qty: 5);
  final branchSale = _sale(id: 'ord-br', storeId: _branch, qty: 3);
  final lateSale = _sale(id: 'ord-late', storeId: _branch, qty: 2);
  final roadSale = _sale(
    id: 'ord-road',
    storeId: _van,
    qty: 60,
    buyingPriceKobo: 0,
    vanTripId: 'trip-1',
  );

  group('the business-wide store predicate (#191)', () {
    testWidgets('ignores a concrete store lock', (tester) async {
      final inScope = await buildBusinessWideFilter(
        tester,
        selectable: [_store(_warehouse), _store(_branch)],
        canViewAll: true,
        lockedStoreId: _warehouse,
      );

      expect(inScope(_warehouse), isTrue);
      expect(
        inScope(_branch),
        isTrue,
        reason: 'the frozen day must not depend on which store the opener '
            'happened to be locked to',
      );
      expect(inScope(null), isTrue, reason: 'a legacy, pre-store row counts');
    });

    testWidgets("ignores a confined viewer's store set", (tester) async {
      final inScope = await buildBusinessWideFilter(
        tester,
        selectable: [_store(_branch)],
        canViewAll: false,
      );

      expect(inScope(_branch), isTrue);
      expect(
        inScope(_warehouse),
        isTrue,
        reason: 'a confined Manager opening the day first must still freeze the '
            'whole business — otherwise first-writer-wins banks a partial '
            'baseline that no one can ever replace',
      );
    });

    testWidgets('still keeps the van out', (tester) async {
      final inScope = await buildBusinessWideFilter(
        tester,
        selectable: [_store(_warehouse), _store(_branch)],
        canViewAll: true,
      );

      expect(
        inScope(_van),
        isFalse,
        reason: 'road revenue carries no cost against it until the trip closes '
            '(van-sales spec §8.1) — business-wide is not "vans too"',
      );
    });
  });

  group('the frozen figures are business-wide, whatever scope opened the day',
      () {
    testWidgets('a store lock scopes the CARDS but not the day close',
        (tester) async {
      final r = await computeWith(
        tester,
        [warehouseSale, branchSale],
        lockedStoreId: _warehouse,
      );

      // What the viewer reads is still their store's day (§12.1 — unchanged).
      expect(r.viewer.totalSalesKobo, 5 * _price);
      expect(r.viewer.itemsSold, 5);
      expect(r.viewer.stockExpectedClosingKobo, _warehouseStock * _cost);
      // What the day close freezes is the whole business's day.
      expect(r.wide.totalSalesKobo, 8 * _price);
      expect(r.wide.itemsSold, 8);
      expect(r.wide.cogsKobo, 8 * _cost);
      expect(
        r.wide.stockExpectedClosingKobo,
        (_warehouseStock + _branchStock) * _cost,
        reason: 'the frozen stock figure must read the UNSCOPED totals — a lock '
            'that narrowed it would freeze one store as if it were the business',
      );
    });

    testWidgets('a confined Manager freezes the same figures a CEO would',
        (tester) async {
      final confined = await computeWith(
        tester,
        [warehouseSale, branchSale],
        selectable: [_store(_branch)],
        canViewAll: false,
      );
      final ceo = await computeWith(tester, [warehouseSale, branchSale]);

      expect(confined.viewer.totalSalesKobo, 3 * _price,
          reason: 'their own cards stay confined');
      expect(
        confined.wide.totalSalesKobo,
        ceo.wide.totalSalesKobo,
        reason: 'first-writer-wins means whoever opens first decides the '
            'baseline forever — so every opener must compute the same one',
      );
      expect(confined.wide.netProfitKobo, ceo.wide.netProfitKobo);
      expect(confined.wide.netCashMovementKobo, ceo.wide.netCashMovementKobo);
      expect(
        confined.wide.stockExpectedClosingKobo,
        (_warehouseStock + _branchStock) * _cost,
        reason: 'stated absolutely, not just as an equality — two zeros would '
            'agree without the unscoped stock read ever happening',
      );
      expect(
        confined.wide.stockExpectedClosingKobo,
        ceo.wide.stockExpectedClosingKobo,
      );
    });

    testWidgets('the All-Stores view already WAS the business-wide answer',
        (tester) async {
      // Pins that the fix adds no SECOND definition of "business-wide": with
      // nothing locked and an all-stores viewer, the two computes agree.
      final r = await computeWith(tester, [warehouseSale, branchSale]);

      expect(r.wide.totalSalesKobo, r.viewer.totalSalesKobo);
      expect(r.wide.netProfitKobo, r.viewer.netProfitKobo);
      expect(r.wide.itemsSold, r.viewer.itemsSold);
      expect(
        r.wide.stockExpectedClosingKobo,
        r.viewer.stockExpectedClosingKobo,
      );
    });

    testWidgets('road sales stay out of the frozen figures', (tester) async {
      final r = await computeWith(
        tester,
        [warehouseSale, branchSale, roadSale],
        lockedStoreId: _warehouse,
      );

      expect(r.wide.totalSalesKobo, 8 * _price);
      expect(r.wide.itemsSold, 8);
      expect(r.wide.uncostedItems, 0);
    });
  });

  group('a snapshot is never badge-blind outside the scope that froze it', () {
    testWidgets('frozen while a store was locked, read clean at All Stores',
        (tester) async {
      // A Manager locked to the warehouse opens the finished day first and
      // freezes it. Post-#191 that captures the BUSINESS-WIDE figures.
      final locked = await computeWith(
        tester,
        [warehouseSale, branchSale],
        lockedStoreId: _warehouse,
      );
      final frozen = _snapshotRow(dailyClosingFiguresFrom(locked.wide));

      // The CEO opens the same day at All Stores. Nothing has changed since the
      // review, so the banner says exactly that — and no card is badged.
      final allStores = await computeWith(tester, [warehouseSale, branchSale]);
      final cmp = reconClosingComparisonOrNull(frozen, allStores.wide);

      expect(cmp, isNotNull,
          reason: 'the reviewed banner needs a comparison to render — this is '
              'the All-Stores blindness #191 fixes');
      expect(cmp!.anyChanged, isFalse);
      expect(cmp.totalSales.reviewed, 8 * _price,
          reason: 'the lock never narrowed what was frozen');
    });

    testWidgets('frozen at All Stores, still badged inside a store lock',
        (tester) async {
      final allStores = await computeWith(tester, [warehouseSale, branchSale]);
      final frozen = _snapshotRow(dailyClosingFiguresFrom(allStores.wide));

      // A ₦20,000 sale syncs into the day AFTER the review, then a Manager
      // locked to the warehouse re-opens it. The day DID move, so the banner
      // and the sales badge must appear at that scope too.
      final later = await computeWith(
        tester,
        [warehouseSale, branchSale, lateSale],
        lockedStoreId: _warehouse,
      );
      final cmp = reconClosingComparisonOrNull(frozen, later.wide)!;

      expect(cmp.anyChanged, isTrue);
      expect(cmp.totalSales.changed, isTrue);
      expect(
        cmp.totalSales.delta,
        2 * _price,
        reason: 'the comparison is business-wide on BOTH sides, so a late sale '
            'in another store still surfaces — the delta is the day\'s '
            'movement, not the scope difference',
      );
    });

    testWidgets('a LEGACY row with a non-null store_scope_id is read as '
        'business-wide', (tester) async {
      // The production row, reproduced: frozen from the WAREHOUSE-scoped figures
      // while someone was locked to it, with the column stamped. Before #191
      // every All-Stores view of that day showed no banner and no badges —
      // forever, because first-writer-wins meant it could never be re-frozen.
      final locked = await computeWith(
        tester,
        [warehouseSale, branchSale],
        lockedStoreId: _warehouse,
      );
      final legacy = _snapshotRow(
        dailyClosingFiguresFrom(locked.viewer), // partial: one store only
        storeScopeId: _warehouse,
      );

      final allStores = await computeWith(tester, [warehouseSale, branchSale]);
      final cmp = reconClosingComparisonOrNull(legacy, allStores.wide);

      expect(cmp, isNotNull,
          reason: 'the column must be ignored on read, so the fix is '
              'retroactive and needs no production data change');
      expect(cmp!.anyChanged, isTrue);
      expect(
        cmp.totalSales.delta,
        3 * _price,
        reason: 'accepted residual: a pre-#191 row froze one store only, so its '
            'badge discloses the difference against the business-wide day. A '
            '"look again" nudge, not silence — and the row cannot be re-frozen',
      );
    });

    testWidgets('an unreviewed day still renders nothing', (tester) async {
      final r = await computeWith(tester, [warehouseSale]);
      expect(
        reconClosingComparisonOrNull(null, r.wide),
        isNull,
        reason: 'no snapshot, no banner and no badges',
      );
    });
  });

  group('static enforcement — the screen must not re-scope the day close', () {
    const screen =
        'lib/features/dashboard/screens/daily_reconciliation_detail_screen.dart';

    test('the reconciliation detail never consults the captured store scope',
        () {
      final source = File(screen).readAsStringSync();

      expect(
        source.contains('storeScopeId'),
        isFalse,
        reason:
            'A day close is business-wide (#191): the capture must not stamp the '
            'active lock, and the badges/banner must not be gated on it. Reading '
            "`snapshot.storeScopeId` here is what made production's single "
            'daily_closings row permanently badge-blind at All Stores.\n'
            'File: $screen',
      );
      // Matched as a CALL, not a mention: a comment saying "businessWide: true"
      // must not satisfy the claim.
      final businessWideCompute = RegExp(
        r'computeReconData\((?:[^;]*?)businessWide:\s*true',
        dotAll: true,
      );
      expect(
        businessWideCompute.hasMatch(source),
        isTrue,
        reason:
            'The snapshot + comparison basis must be the BUSINESS-WIDE compute, '
            'not the viewer-scoped one — otherwise the frozen record depends on '
            "the first opener's store lock again (#191).\n"
            'File: $screen',
      );
    });
  });
}
