// recon_day_close_delta_coverage_test.dart
//
// #192 (PRD #155 slice #174, US 18 / US 35) — the changed-since-review
// comparison must cover the WHOLE frozen figure set, and must be answerable from
// OUTSIDE the day it belongs to.
//
// What went wrong: `dailyClosingFiguresFrom` freezes SIXTEEN figures, but
// `ReconClosingComparison` compared four. A reviewed day whose expenses, refunds
// or damages moved afterwards therefore read as unchanged — and because the four
// it did compare included two CEO-only cards, a Manager could be told "the
// flagged cards show what moved" with no flagged card on screen. US 35's own
// case (a supplier payment backdated into a reviewed day) flowed through to
// `cashSupplierPaidKobo` and was compared, but had no test at all.
//
// Three things are pinned here, all on the REAL compute path ([reconDataFrom],
// the pure seam #195 extracted — no widget, no database):
//
//   1. Every frozen column is wired to its own delta. Perturb one column of a
//      snapshot and exactly one delta fires; a column nobody compares fires
//      none, which is the hole this issue is about.
//   2. The money cases behave: a backdated supplier payment (US 35), a late
//      expense, a late refund and a late damage each move their own figure.
//   3. The reconciliation LIST's sweep flags the day from outside it, and its
//      day-local question deliberately excludes `stockExpectedClosing` — the one
//      frozen figure that is rewound from today's on-hand and so is not
//      derivable from a single day's rows.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/business_scoped_stream.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/stores/van_store.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';

const _biz = 'biz';
const _store = 'store-1';
const _van = 'van-1';

/// The reviewed day under test, and a second day that never moves.
const _day = '2026-07-26';
const _quietDay = '2026-07-25';
final _dayStart = DateTime(2026, 7, 26);
final _dayEnd = DateTime(2026, 7, 27);

const _price = 1000000; // ₦10,000
const _cost = 600000; // ₦6,000

StoreData _storeRow(String id, {String kind = kStoreKindStore}) => StoreData(
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

/// One recognised cash sale of [qty] crates, rung at [at].
OrderWithItems _sale({
  required String id,
  required int qty,
  DateTime? at,
}) {
  final product = _product();
  final ts = at ?? _dayStart.add(const Duration(hours: 10));
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
      storeId: _store,
      confirmedBy: null,
      crateDepositPaidKobo: 0,
      vanTripId: null,
      completedAt: ts,
      cancelledAt: null,
      createdAt: ts,
      lastUpdatedAt: ts,
    ),
    [
      OrderItemDataWithProductData(
        OrderItemData(
          id: '$id-line',
          businessId: _biz,
          orderId: id,
          productId: product.id,
          storeId: _store,
          quantity: qty,
          unitPriceKobo: _price,
          buyingPriceKobo: _cost,
          totalKobo: qty * _price,
          cataloguePriceKobo: null,
          priceSnapshot: null,
          createdAt: ts,
          lastUpdatedAt: ts,
        ),
        product,
      ),
    ],
    null,
  );
}

/// A supplier-ledger CASH payment dated into [activityDate] but RECORDED at
/// [recordedAt] — the US 35 shape: the money is stated to have moved on the
/// reviewed day, the row itself arrives afterwards.
SupplierLedgerEntryData _supplierCashPayment({
  required int amountKobo,
  required DateTime activityDate,
  required DateTime recordedAt,
}) => SupplierLedgerEntryData(
  id: 'sl-1',
  businessId: _biz,
  supplierId: 'sup-1',
  storeId: _store,
  type: 'payment',
  amountKobo: amountKobo,
  signedAmountKobo: amountKobo,
  referenceType: 'payment_cash',
  paymentMethod: 'cash',
  activityDate: activityDate,
  createdAt: recordedAt,
  lastUpdatedAt: recordedAt,
);

PaymentTransactionData _payment({
  required String id,
  required String type,
  required int amountKobo,
  required DateTime at,
  String method = 'cash',
}) => PaymentTransactionData(
  id: id,
  businessId: _biz,
  storeId: _store,
  amountKobo: amountKobo,
  method: method,
  type: type,
  createdAt: at,
  lastUpdatedAt: at,
);

ExpenseWithCategory _expense({
  required int amountKobo,
  required DateTime expenseDate,
  required DateTime recordedAt,
}) => ExpenseWithCategory(
  expense: ExpenseData(
    id: 'exp-1',
    businessId: _biz,
    amountKobo: amountKobo,
    description: 'Diesel',
    storeId: _store,
    status: 'approved',
    expenseDate: expenseDate,
    isDeleted: false,
    createdAt: recordedAt,
    lastUpdatedAt: recordedAt,
  ),
  category: null,
);

StockAdjustmentData _damage({
  required int units,
  required int valueKobo,
  required DateTime at,
}) => StockAdjustmentData(
  id: 'adj-1',
  businessId: _biz,
  productId: 'prod-1',
  storeId: _store,
  quantityDiff: -units,
  reason: 'damage:broken',
  valueKobo: valueKobo,
  createdAt: at,
  lastUpdatedAt: at,
);

/// The persisted `daily_closings` row carrying [f] for [businessDate].
DailyClosingData _snapshotRow(
  DailyClosingFigures f, {
  String businessDate = _day,
}) {
  final ts = DateTime.utc(2026, 7, 27, 8);
  return DailyClosingData(
    id: 'snap-$businessDate',
    businessId: _biz,
    businessDate: businessDate,
    storeScopeId: null,
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
    reviewedBy: null,
    reviewedAt: ts,
    createdAt: ts,
    lastUpdatedAt: ts,
  );
}

/// The day's business-wide figures over exactly the rows given — the same shape
/// the day-close capture computes.
ReconData _figuresFor({
  List<OrderWithItems> orders = const [],
  List<PaymentTransactionData> payments = const [],
  List<SupplierLedgerEntryData> supplierLedger = const [],
  List<ExpenseWithCategory> expenses = const [],
  List<StockAdjustmentData> adjustments = const [],
}) => reconDataFrom(
  ReconInputs(
    orders: orders,
    payments: payments,
    supplierLedger: supplierLedger,
    expenses: expenses,
    adjustments: adjustments,
    productsWithStock: [
      ProductDataWithStock(product: _product(), totalStock: 10),
    ],
    isCeo: true,
    start: _dayStart,
    endExclusive: _dayEnd,
  ),
);

void main() {
  final saleOrder = _sale(id: 'ord-1', qty: 5);
  final salePayment = _payment(
    id: 'pay-1',
    type: 'sale',
    amountKobo: 5 * _price,
    at: _dayStart.add(const Duration(hours: 10)),
  );

  group('every frozen figure is compared (#192)', () {
    test('each frozen column is wired to exactly one delta', () {
      final live = _figuresFor(orders: [saleOrder], payments: [salePayment]);
      final frozen = _snapshotRow(dailyClosingFiguresFrom(live));

      expect(
        reconClosingComparison(frozen, live).anyChanged,
        isFalse,
        reason: 'the baseline must be a clean freeze, or every perturbation '
            'below would pass for the wrong reason',
      );

      // One perturbation per frozen column. A column NOBODY compares moves no
      // delta at all — which is exactly the state #192 found (12 of 16).
      final perturbed = <String, DailyClosingData>{
        'totalSalesKobo': frozen.copyWith(totalSalesKobo: frozen.totalSalesKobo + 1),
        'refundsKobo': frozen.copyWith(refundsKobo: frozen.refundsKobo + 1),
        'discountsKobo': frozen.copyWith(discountsKobo: frozen.discountsKobo + 1),
        'cogsKobo': frozen.copyWith(cogsKobo: frozen.cogsKobo + 1),
        'grossProfitKobo': frozen.copyWith(grossProfitKobo: frozen.grossProfitKobo + 1),
        'netProfitKobo': frozen.copyWith(netProfitKobo: frozen.netProfitKobo + 1),
        'expensesKobo': frozen.copyWith(expensesKobo: frozen.expensesKobo + 1),
        'damagesCostKobo': frozen.copyWith(damagesCostKobo: frozen.damagesCostKobo + 1),
        'cashSalesKobo': frozen.copyWith(cashSalesKobo: frozen.cashSalesKobo + 1),
        'cashInKobo': frozen.copyWith(cashInKobo: frozen.cashInKobo + 1),
        'cashOutKobo': frozen.copyWith(cashOutKobo: frozen.cashOutKobo + 1),
        'netCashMovementKobo':
            frozen.copyWith(netCashMovementKobo: frozen.netCashMovementKobo + 1),
        'stockCogsKobo': frozen.copyWith(stockCogsKobo: frozen.stockCogsKobo + 1),
        'stockExpectedClosingKobo': frozen.copyWith(
          stockExpectedClosingKobo: frozen.stockExpectedClosingKobo + 1,
        ),
        'itemsSold': frozen.copyWith(itemsSold: frozen.itemsSold + 1),
        'shortageUnits': frozen.copyWith(shortageUnits: frozen.shortageUnits + 1),
      };

      expect(
        perturbed.length,
        16,
        reason: 'the frozen set is 16 figures — if this number moves, a column '
            'was added to daily_closings and this test must follow it',
      );

      for (final entry in perturbed.entries) {
        final cmp = reconClosingComparison(entry.value, live);
        expect(
          cmp.all.where((d) => d.changed).length,
          1,
          reason:
              'moving `${entry.key}` alone must flag exactly one delta. 0 means '
              'the column is frozen but never compared — a reviewed day that '
              'moved would read as unchanged. More than 1 means two deltas read '
              'the same column.',
        );
      }
      expect(reconClosingComparison(frozen, live).all.length, 16);
    });
  });

  group('US 35 — a supplier payment backdated into a reviewed day', () {
    test('moves the cash figures and nothing else', () {
      // The day is reviewed on the strength of one ₦50,000 cash sale.
      final atReview = _figuresFor(
        orders: [saleOrder],
        payments: [salePayment],
      );
      final frozen = _snapshotRow(dailyClosingFiguresFrom(atReview));

      // Two days later someone records a ₦20,000 cash payment to a supplier and
      // dates it back into the reviewed day.
      final backdated = _supplierCashPayment(
        amountKobo: 2000000,
        activityDate: _dayStart.add(const Duration(hours: 15)),
        recordedAt: DateTime(2026, 7, 28, 9),
      );
      final now = _figuresFor(
        orders: [saleOrder],
        payments: [salePayment],
        supplierLedger: [backdated],
      );
      final cmp = reconClosingComparison(frozen, now);

      expect(cmp.cashOut.delta, 2000000);
      expect(cmp.netCashMovement.delta, -2000000);
      expect(
        cmp.totalSales.changed,
        isFalse,
        reason: 'no sale moved — paying a supplier is not a sale',
      );
      expect(cmp.cashSales.changed, isFalse);
      expect(
        cmp.anyChanged,
        isTrue,
        reason: 'the day the shop banked against is no longer the day on file',
      );
      expect(
        cmp.anyDayLocalChanged,
        isTrue,
        reason: 'the reconciliation list must be able to flag this from '
            'outside the day — that is the whole point of the sweep',
      );
    });

    test('a payment dated OUTSIDE the day leaves the reviewed day alone', () {
      final atReview = _figuresFor(
        orders: [saleOrder],
        payments: [salePayment],
      );
      final frozen = _snapshotRow(dailyClosingFiguresFrom(atReview));

      final elsewhere = _supplierCashPayment(
        amountKobo: 2000000,
        activityDate: DateTime(2026, 7, 28, 9),
        recordedAt: DateTime(2026, 7, 28, 9),
      );
      final now = _figuresFor(
        orders: [saleOrder],
        payments: [salePayment],
        supplierLedger: [elsewhere],
      );

      expect(
        reconClosingComparison(frozen, now).anyChanged,
        isFalse,
        reason: 'a badge must mean THIS day moved, not that the business had '
            'activity somewhere',
      );
    });
  });

  group('the figures a Manager can see (#192 gaps 1 and 2)', () {
    test('a late expense moves the expenses delta', () {
      final atReview = _figuresFor(orders: [saleOrder]);
      final frozen = _snapshotRow(dailyClosingFiguresFrom(atReview));

      final now = _figuresFor(
        orders: [saleOrder],
        expenses: [
          _expense(
            amountKobo: 750000,
            expenseDate: _dayStart,
            recordedAt: DateTime(2026, 7, 29),
          ),
        ],
      );
      final cmp = reconClosingComparison(frozen, now);

      expect(
        cmp.expenses.delta,
        750000,
        reason: "the Manager's Debts & expenses card renders exactly this "
            'figure and rendered it with no delta at all before #192',
      );
      expect(cmp.netProfit.delta, -750000);
    });

    test('a late refund moves the refunds delta', () {
      final atReview = _figuresFor(
        orders: [saleOrder],
        payments: [salePayment],
      );
      final frozen = _snapshotRow(dailyClosingFiguresFrom(atReview));

      final now = _figuresFor(
        orders: [saleOrder],
        payments: [
          salePayment,
          _payment(
            id: 'pay-refund',
            type: 'refund',
            amountKobo: 1000000,
            at: _dayStart.add(const Duration(hours: 20)),
          ),
        ],
      );
      final cmp = reconClosingComparison(frozen, now);

      expect(cmp.refunds.delta, 1000000);
      expect(cmp.cashOut.delta, 1000000);
    });

    test('a late damage moves the damages delta', () {
      final atReview = _figuresFor(orders: [saleOrder]);
      final frozen = _snapshotRow(dailyClosingFiguresFrom(atReview));

      final now = _figuresFor(
        orders: [saleOrder],
        adjustments: [
          _damage(
            units: 2,
            valueKobo: 2 * _cost,
            at: _dayStart.add(const Duration(hours: 18)),
          ),
        ],
      );
      final cmp = reconClosingComparison(frozen, now);

      expect(cmp.damagesCost.delta, 2 * _cost);
      expect(cmp.netProfit.delta, -2 * _cost);
    });
  });

  group('the day-local subset the list sweep asks about', () {
    test('excludes stockExpectedClosing and nothing else', () {
      final live = _figuresFor(orders: [saleOrder]);
      final frozen = _snapshotRow(dailyClosingFiguresFrom(live));
      final cmp = reconClosingComparison(frozen, live);

      expect(cmp.dayLocal.length, cmp.all.length - 1);
      expect(
        cmp.dayLocal.contains(cmp.stockExpectedClosing),
        isFalse,
        reason: 'expected closing is rewound from TODAY\'s on-hand over every '
            'later movement, so one day\'s own rows cannot reproduce it',
      );
    });

    test('a day that moved ONLY in expected closing is not swept up', () {
      final live = _figuresFor(orders: [saleOrder]);
      final frozen = _snapshotRow(dailyClosingFiguresFrom(live)).copyWith(
        stockExpectedClosingKobo: 999,
      );
      final cmp = reconClosingComparison(frozen, live);

      expect(cmp.anyChanged, isTrue);
      expect(
        cmp.anyDayLocalChanged,
        isFalse,
        reason: 'the list must not claim a change it computed on a basis it '
            'cannot reproduce — the day\'s own screen still catches this one',
      );
    });
  });

  group('the reconciliation list learns it from outside the day', () {
    /// Runs the real sweep over [orders] / [ledger] with [snapshots] frozen.
    Future<Set<String>> sweep({
      required List<DailyClosingData> snapshots,
      List<OrderWithItems> orders = const [],
      List<SupplierLedgerEntryData> ledger = const [],
      List<PaymentTransactionData> payments = const [],
    }) async {
      final container = ProviderContainer(
        overrides: [
          // No business bound ⇒ every business-scoped provider not listed below
          // emits its `whenAbsent` value and never reaches for a database.
          currentBusinessIdProvider.overrideWithValue(null),
          currentBusinessProvider.overrideWith((ref) => null),
          vanStoresProvider.overrideWithValue(
            VanStores.of([
              _storeRow(_store),
              _storeRow(_van, kind: kStoreKindVan),
            ]),
          ),
          allDailyClosingsProvider.overrideWith((ref) => Stream.value(snapshots)),
          allOrdersProvider.overrideWith((ref) => Stream.value(orders)),
          allSupplierLedgerEntriesProvider
              .overrideWith((ref) => Stream.value(ledger)),
          allPaymentTransactionsProvider
              .overrideWith((ref) => Stream.value(payments)),
          productsWithStockProvider.overrideWith(
            (ref, storeId) => Stream.value([
              ProductDataWithStock(product: _product(), totalStock: 10),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);
      // Keep the derivation alive while its stream inputs deliver their first
      // values (a `Stream.value` lands on the next microtask), then read the
      // settled answer — reading straight away would only see the pre-emission
      // empty state and pass for the wrong reason.
      container.listen(changedReviewedDaysProvider, (_, __) {});
      for (var i = 0; i < 3; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      return container.read(changedReviewedDaysProvider);
    }

    test('flags the day a backdated supplier payment landed in, and only it',
        () async {
      final quietSale = _sale(
        id: 'ord-quiet',
        qty: 1,
        at: DateTime(2026, 7, 25, 11),
      );
      final atReview = _figuresFor(
        orders: [saleOrder],
        payments: [salePayment],
      );
      final backdated = _supplierCashPayment(
        amountKobo: 2000000,
        activityDate: _dayStart.add(const Duration(hours: 15)),
        recordedAt: DateTime(2026, 7, 28, 9),
      );

      // The quiet day is frozen from ITS own rows, so it must stay unflagged.
      final quietLive = reconDataFrom(
        ReconInputs(
          orders: [quietSale],
          productsWithStock: [
            ProductDataWithStock(product: _product(), totalStock: 10),
          ],
          isCeo: true,
          start: DateTime(2026, 7, 25),
          endExclusive: _dayStart,
        ),
      );

      final flagged = await sweep(
        snapshots: [
          _snapshotRow(dailyClosingFiguresFrom(atReview)),
          _snapshotRow(
            dailyClosingFiguresFrom(quietLive),
            businessDate: _quietDay,
          ),
        ],
        orders: [saleOrder, quietSale],
        payments: [salePayment],
        ledger: [backdated],
      );

      expect(
        flagged,
        {_day},
        reason: 'the day that moved is named from the LIST, without anyone '
            'having to open it — and the day that did not move is left alone, '
            'or the marker is noise',
      );
    });

    test('an untouched reviewed day is flagged by nothing', () async {
      final atReview = _figuresFor(
        orders: [saleOrder],
        payments: [salePayment],
      );

      expect(
        await sweep(
          snapshots: [_snapshotRow(dailyClosingFiguresFrom(atReview))],
          orders: [saleOrder],
          payments: [salePayment],
        ),
        isEmpty,
      );
    });

    test('a business with no reviewed day does no work at all', () async {
      expect(await sweep(snapshots: const [], orders: [saleOrder]), isEmpty);
    });
  });
}
