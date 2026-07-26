// recon_van_rollup_test.dart
//
// #147 (PRD #139 as amended by #161 / ADR 0019 decision 3, van-sales spec §8.2)
// — the four report lines the closing report gains, and nothing else.
//
// The slice is PURELY ADDITIVE by design: the exclusions shipped in #140/#142,
// and `van_remittance` already landed in no existing payment bucket (#144). So
// what this file proves is the other half — that the van channel, having been
// correctly excluded from every per-store figure, is now VISIBLE in its own
// right rather than gone:
//
//   1. Van Sales (aggregated), attributed through each trip's SOURCE WAREHOUSE
//      — the van itself fails every store scope, so an order that only knew its
//      own store would be invisible on All Stores too.
//   2. Cash from drivers, on the day the money arrived.
//   3. Van profit, READ from each closed trip's persisted artifact — never
//      re-derived (ADR 0019's rejected alternative #3).
//   4. The open-trip caveat, printed instead of implying profit is complete.
//
// Plus the month-straddling case, which is the reason the caveat exists at all:
// revenue lands in the ring month and profit in the close month, BY DESIGN
// (spec §9.4 #18), and the report has to say so rather than look broken.
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
const _warehouse = 'wh';
const _otherWarehouse = 'wh2';
const _van = 'van';
const _trip = 'trip-1';

final _julDay = DateTime(2026, 7, 26, 10);
final _julStart = DateTime(2026, 7, 1);
final _augStart = DateTime(2026, 8, 1);
final _sepStart = DateTime(2026, 9, 1);

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

OrderWithItems _roadSale({
  required String id,
  required int qty,
  required String tripId,
  DateTime? at,
  int unitPriceKobo = 1150000,
  String status = 'completed',
}) {
  final product = _product('prod-1');
  final when = at ?? _julDay;
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
      storeId: _van,
      confirmedBy: null,
      crateDepositPaidKobo: 0,
      vanTripId: tripId,
      completedAt: when,
      cancelledAt: null,
      createdAt: when,
      lastUpdatedAt: when,
    ),
    [
      OrderItemDataWithProductData(
        OrderItemData(
          id: '$id-line',
          businessId: _biz,
          orderId: id,
          productId: product.id,
          storeId: _van,
          quantity: qty,
          unitPriceKobo: unitPriceKobo,
          // A road line books no per-sale COGS by design (ADR 0019).
          buyingPriceKobo: 0,
          totalKobo: qty * unitPriceKobo,
          cataloguePriceKobo: null,
          priceSnapshot: null,
          createdAt: when,
          lastUpdatedAt: when,
        ),
        product,
      ),
    ],
    null,
  );
}

VanTripData _tripRow({
  String id = _trip,
  String sourceStoreId = _warehouse,
  String status = kVanTripStatusOpen,
  DateTime? closedAt,
  int profitKobo = 0,
  int cogsKobo = 0,
}) => VanTripData(
  id: id,
  businessId: _biz,
  vanStoreId: _van,
  driverUserId: 'driver-1',
  sourceStoreId: sourceStoreId,
  status: status,
  openedAt: DateTime(2026, 7, 20),
  openedBy: null,
  closedAt: closedAt,
  closedBy: null,
  closedWithBalance: false,
  shellsOut: 0,
  shellsBack: 0,
  restatedAt: null,
  restatedReason: null,
  cogsKobo: cogsKobo,
  recoveredKobo: 0,
  unremittedKobo: 0,
  shortageWriteoffKobo: 0,
  damageWriteoffKobo: 0,
  shortageLossKobo: 0,
  damageLossKobo: 0,
  profitKobo: profitKobo,
  createdAt: DateTime(2026, 7, 20),
  lastUpdatedAt: DateTime(2026, 7, 20),
);

PaymentTransactionData _remittance({
  required String id,
  required int amountKobo,
  String method = 'cash',
  String? storeId = _warehouse,
  DateTime? at,
}) => PaymentTransactionData(
  id: id,
  businessId: _biz,
  storeId: storeId,
  amountKobo: amountKobo,
  method: method,
  type: kPaymentTypeVanRemittance,
  orderId: null,
  shipmentId: null,
  expenseId: null,
  walletTxnId: null,
  deliveryId: null,
  vanTripId: _trip,
  performedBy: null,
  voidedAt: null,
  voidedBy: null,
  voidReason: null,
  createdAt: at ?? _julDay,
  lastUpdatedAt: at ?? _julDay,
);

Future<ReconData> computeWith(
  WidgetTester tester, {
  List<OrderWithItems> orders = const [],
  List<VanTripData> trips = const [],
  List<PaymentTransactionData> payments = const [],
  String? lockedStoreId,
  DateTime? start,
  DateTime? endExclusive,
}) async {
  late ReconData out;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentBusinessIdProvider.overrideWithValue(null),
        allOrdersProvider.overrideWith((ref) => Stream.value(orders)),
        allVanTripsProvider.overrideWith((ref) => Stream.value(trips)),
        allPaymentTransactionsProvider.overrideWith(
          (ref) => Stream.value(payments),
        ),
        selectableStoresProvider.overrideWithValue([
          _store(_warehouse),
          _store(_otherWarehouse),
        ]),
        canViewAllStoresProvider.overrideWithValue(true),
        lockedStoreProvider.overrideWith(
          (ref) => ValueNotifier<String?>(lockedStoreId),
        ),
        vanStoresProvider.overrideWithValue(
          VanStores.of([
            _store(_warehouse),
            _store(_otherWarehouse),
            _store(_van, kind: kStoreKindVan),
          ]),
        ),
      ],
      child: Consumer(
        builder: (_, ref, _) {
          out = computeReconData(
            ref,
            start: start ?? _julStart,
            endExclusive: endExclusive ?? _augStart,
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
  // The spec §6.3 run: 60 crates Tuesday + 30 Wednesday at the ₦11,500 load
  // price, all on one trip out of the main warehouse.
  final sale1 = _roadSale(id: 'ord-1', qty: 60, tripId: _trip);
  final sale2 = _roadSale(id: 'ord-2', qty: 30, tripId: _trip);
  const roadRevenue = 90 * 1150000; // ₦1,035,000

  group('1. Van Sales (aggregated)', () {
    testWidgets('the period\'s road revenue surfaces as one line',
        (tester) async {
      final d = await computeWith(
        tester,
        orders: [sale1, sale2],
        trips: [_tripRow()],
      );

      expect(d.van.salesKobo, roadRevenue);
      // …and it is STILL out of every per-store figure (#140/#142). Both
      // halves matter: excluded from the totals, visible on its own line.
      expect(d.totalSalesKobo, 0);
      expect(d.itemsSold, 0);
      expect(d.cogsKobo, 0);
    });

    testWidgets('the SOURCE warehouse sees the revenue', (tester) async {
      // The order's own store is the VAN, which is in no scope at all — so
      // without the trip lookup this line would read ₦0 on every scope,
      // including All Stores. Attribution runs through `source_store_id`.
      final d = await computeWith(
        tester,
        orders: [sale1, sale2],
        trips: [_tripRow(sourceStoreId: _otherWarehouse)],
        lockedStoreId: _otherWarehouse,
      );
      expect(d.van.salesKobo, roadRevenue);
    });

    testWidgets('another warehouse does not see it', (tester) async {
      final d = await computeWith(
        tester,
        orders: [sale1, sale2],
        trips: [_tripRow(sourceStoreId: _otherWarehouse)],
        lockedStoreId: _warehouse,
      );
      expect(d.van.salesKobo, 0);
    });

    testWidgets('an order whose trip is unknown is not counted', (tester) async {
      // Defensive: a road order that arrived before its trip row did must not
      // be attributed to a warehouse the report cannot name.
      final d = await computeWith(tester, orders: [sale1], trips: const []);
      expect(d.van.salesKobo, 0);
      expect(d.van.hasActivity, isFalse);
    });

    testWidgets('a cancelled road sale drops out', (tester) async {
      final cancelled = _roadSale(
        id: 'ord-x',
        qty: 10,
        tripId: _trip,
        status: 'cancelled',
      );
      final d = await computeWith(
        tester,
        orders: [sale1, cancelled],
        trips: [_tripRow()],
      );
      expect(d.van.salesKobo, 60 * 1150000);
    });
  });

  group('2. Cash from drivers', () {
    testWidgets('a cash remittance lands on its own line and inside cash in',
        (tester) async {
      final d = await computeWith(
        tester,
        payments: [_remittance(id: 'p1', amountKobo: 90000000)],
      );

      expect(d.van.remittedKobo, 90000000);
      expect(d.cashFromDriversKobo, 90000000);
      expect(
        d.cashSalesKobo,
        0,
        reason:
            '"Cash sales" stays sale-only — road revenue was already '
            'recognised when the driver rang it (ADR 0019)',
      );
      expect(
        d.cashInKobo,
        90000000,
        reason:
            'the money physically arrived; leaving it out understates the '
            'drawer by every naira a driver handed in',
      );
      expect(d.netCashMovementKobo, 90000000);
      expect(d.totalSalesKobo, 0, reason: 'a remittance is not a sale');
      expect(d.refundsKobo, 0);
    });

    testWidgets('a bank transfer counts as handed in but not as CASH movement',
        (tester) async {
      final d = await computeWith(
        tester,
        payments: [
          _remittance(id: 'p1', amountKobo: 50000000, method: 'transfer'),
        ],
      );

      expect(d.van.remittedKobo, 50000000);
      expect(
        d.cashFromDriversKobo,
        0,
        reason: 'the cash card is what could be counted in the drawer',
      );
      expect(d.cashInKobo, 0);
    });

    testWidgets('a remittance outside the period is not counted', (tester) async {
      final d = await computeWith(
        tester,
        payments: [
          _remittance(
            id: 'p1',
            amountKobo: 90000000,
            at: DateTime(2026, 8, 2),
          ),
        ],
      );
      expect(d.van.remittedKobo, 0);
      expect(d.cashFromDriversKobo, 0);
    });
  });

  group('3. Van profit — read, never re-derived', () {
    testWidgets('a trip closed in the period contributes its artifact',
        (tester) async {
      final closed = _tripRow(
        status: kVanTripStatusClosed,
        closedAt: DateTime(2026, 7, 30),
        profitKobo: 46750000, // ₦467,500 — the spec §6.3 artifact
        cogsKobo: 95000000,
      );
      final d = await computeWith(
        tester,
        orders: [sale1, sale2],
        trips: [closed],
      );

      expect(d.van.profitKobo, 46750000);
      expect(d.van.cogsKobo, 95000000);
      expect(d.van.closedTripCount, 1);
      expect(
        d.van.hasOpenTripCaveat,
        isFalse,
        reason: 'the trip closed inside the period — profit IS booked',
      );
      // The store P&L is untouched: van profit is its own line, not folded in.
      expect(d.netProfitKobo, 0);
    });

    testWidgets('the figure is the persisted one, whatever the sales say',
        (tester) async {
      // The artifact is a settlement outcome — a manager's write-off decisions
      // at a moment in time. The report must print THAT, not something it
      // recomputed from the same orders.
      final closed = _tripRow(
        status: kVanTripStatusClosed,
        closedAt: DateTime(2026, 7, 30),
        profitKobo: 123456,
        cogsKobo: 654321,
      );
      final d = await computeWith(tester, orders: [sale1], trips: [closed]);

      expect(d.van.profitKobo, 123456);
      expect(d.van.cogsKobo, 654321);
    });

    testWidgets('a trip closed elsewhere does not count at a locked store',
        (tester) async {
      final closed = _tripRow(
        sourceStoreId: _otherWarehouse,
        status: kVanTripStatusClosed,
        closedAt: DateTime(2026, 7, 30),
        profitKobo: 46750000,
      );
      final d = await computeWith(
        tester,
        trips: [closed],
        lockedStoreId: _warehouse,
      );
      expect(d.van.profitKobo, 0);
    });
  });

  group('4. The open-trip caveat', () {
    testWidgets('an open trip prints the caveat instead of a profit figure',
        (tester) async {
      final d = await computeWith(
        tester,
        orders: [sale1, sale2],
        trips: [_tripRow()], // still open
      );

      expect(d.van.salesKobo, roadRevenue);
      expect(d.van.profitKobo, 0);
      expect(d.van.openRevenueKobo, roadRevenue);
      expect(d.van.openTripCount, 1);
      expect(d.van.hasOpenTripCaveat, isTrue);
      expect(
        d.van.caveatLine((v) => '₦${v.toStringAsFixed(2)}'),
        '₦1035000.00 van revenue awaiting trip close — profit not yet booked.',
      );
    });

    testWidgets('a closed trip prints no caveat', (tester) async {
      final d = await computeWith(
        tester,
        orders: [sale1],
        trips: [
          _tripRow(
            status: kVanTripStatusClosed,
            closedAt: DateTime(2026, 7, 28),
            profitKobo: 100,
          ),
        ],
      );
      expect(d.van.hasOpenTripCaveat, isFalse);
      expect(d.van.openRevenueKobo, 0);
      expect(d.van.openTripCount, 0);
    });
  });

  group('the month-straddling trip (spec §9.4 #18)', () {
    // Rung in July, closed in August. Revenue belongs to July; profit belongs
    // to August; and July says so out loud rather than looking like a loss.
    final straddling = _tripRow(
      status: kVanTripStatusClosed,
      closedAt: DateTime(2026, 8, 3),
      profitKobo: 46750000,
      cogsKobo: 95000000,
    );

    testWidgets('July shows the revenue and the caveat, no profit',
        (tester) async {
      final july = await computeWith(
        tester,
        orders: [sale1, sale2],
        trips: [straddling],
        start: _julStart,
        endExclusive: _augStart,
      );

      expect(july.van.salesKobo, roadRevenue);
      expect(july.van.profitKobo, 0);
      expect(july.van.closedTripCount, 0);
      expect(
        july.van.hasOpenTripCaveat,
        isTrue,
        reason:
            'the trip had not closed by the end of July, so July cannot claim '
            'its profit — and must say why',
      );
      expect(july.van.openRevenueKobo, roadRevenue);
    });

    testWidgets('August shows the profit and no revenue', (tester) async {
      final august = await computeWith(
        tester,
        orders: [sale1, sale2],
        trips: [straddling],
        start: _augStart,
        endExclusive: _sepStart,
      );

      expect(
        august.van.salesKobo,
        0,
        reason: 'the sales were rung in July and stay there',
      );
      expect(august.van.profitKobo, 46750000);
      expect(august.van.cogsKobo, 95000000);
      expect(august.van.closedTripCount, 1);
      expect(august.van.hasOpenTripCaveat, isFalse);
    });
  });

  group('the rollup is inert when there is no van', () {
    testWidgets('a business with no van activity carries an empty rollup',
        (tester) async {
      final d = await computeWith(tester);

      expect(d.van.hasActivity, isFalse);
      expect(d.van.salesKobo, 0);
      expect(d.van.remittedKobo, 0);
      expect(d.van.profitKobo, 0);
      expect(d.cashFromDriversKobo, 0);
      expect(d.cashInKobo, 0);
    });

    test('the default rollup is all zeroes — additive by construction', () {
      // #207 will add `depositsHeldKobo` here. Every field is
      // optional-defaulted so that addition changes no call site.
      const empty = ReconVanRollup();
      expect(empty.hasActivity, isFalse);
      expect(empty.hasOpenTripCaveat, isFalse);
      expect(ReconData, isNotNull);
    });
  });
}
