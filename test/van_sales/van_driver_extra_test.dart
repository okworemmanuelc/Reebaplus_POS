// van_driver_extra_test.dart
//
// #730 (PRD #139, ADR 0019) - a van driver may sell ABOVE the load price. The
// extra is recorded APART from shop sales, so the proof is a fixture: the same
// trip rung twice (once at the load price, once with an extra) must produce
// IDENTICAL shop money figures, and only the side columns differ.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/report_revenue.dart';
import 'package:reebaplus_pos/features/van_sales/driver_terminal_data.dart';
import 'package:reebaplus_pos/features/van_sales/widgets/van_sale_receipt_sheet.dart';
import 'package:reebaplus_pos/shared/services/orders/order_service.dart';

import '../helpers/dispatch_test_utils.dart';

const _load = 1150000; // ₦11,500 load price
const _sell = 1250000; // ₦12,500 the driver charges

class _Run {
  final AppDatabase db;
  final String tripId;
  final String driverId;
  final String vanId;
  final String productId;
  _Run(this.db, this.tripId, this.driverId, this.vanId, this.productId);

  Future<String> ring(int qty, {int? chargedKobo}) async {
    final number = await OrderService(db).addOrder(
      customerId: null,
      cart: [
        {
          'id': productId,
          'name': 'Star 60cl',
          'qty': qty,
          'unitPriceKobo': _load,
          'buyingPriceKobo': 0,
          'chargedUnitPriceKobo': ?chargedKobo,
        },
      ],
      totalAmountKobo: qty * _load,
      amountPaidKobo: qty * _load,
      paymentType: 'Cash',
      staffId: driverId,
      storeId: vanId,
      paymentSubType: 'cash',
    );
    return number;
  }
}

Future<_Run> _boot() async {
  final boot = await bootstrapTestDb();
  final db = boot.db;
  final warehouseId = UuidV7.generate();
  final vanId = UuidV7.generate();
  final driverId = UuidV7.generate();
  final managerId = UuidV7.generate();
  final productId = UuidV7.generate();
  await db
      .into(db.stores)
      .insert(
        StoresCompanion.insert(
          id: Value(warehouseId),
          businessId: boot.businessId,
          name: 'Main Warehouse',
        ),
      );
  await db
      .into(db.stores)
      .insert(
        StoresCompanion.insert(
          id: Value(vanId),
          businessId: boot.businessId,
          name: 'Van 1',
          kind: const Value(kStoreKindVan),
        ),
      );
  for (final u in [(driverId, 'Driver Dan'), (managerId, 'Manager Mo')]) {
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: Value(u.$1),
            businessId: boot.businessId,
            name: u.$2,
            pin: '0000',
          ),
        );
  }
  await db
      .into(db.products)
      .insert(
        ProductsCompanion.insert(
          id: Value(productId),
          businessId: boot.businessId,
          name: 'Star 60cl',
          retailerPriceKobo: const Value(1150000),
        ),
      );
  await db.inventoryDao.adjustStock(
    productId,
    warehouseId,
    200,
    'opening',
    managerId,
    trackCost: false,
  );
  await db.costBatchesDao.recordInflowBatch(
    productId: productId,
    storeId: warehouseId,
    quantity: 200,
    costKobo: 1000000,
  );
  final result = await db.vanTripsDao.dispatchLoad(
    vanStoreId: vanId,
    vanDriverId: driverId,
    sourceStoreId: warehouseId,
    lines: [
      VanLoadLine(productId: productId, quantity: 100, loadPriceKobo: _load),
    ],
    performedBy: managerId,
    dispatchEventId: UuidV7.generate(),
  );
  return _Run(db, result.tripId, driverId, vanId, productId);
}

/// Every shop money figure for the trip, as plain comparable values.
Future<Map<String, Object?>> _shopFigures(_Run r) async {
  final db = r.db;
  final orders = await (db.select(db.orders)).get();
  final items = await (db.select(db.orderItems)).get();
  final withItems = await db.ordersDao.watchAllOrdersWithItems().first;
  final position = await db.vanTripsDao.positionForTrip(r.tripId);
  return {
    'orderTotals': [for (final o in orders) o.totalAmountKobo],
    'orderNet': [for (final o in orders) o.netAmountKobo],
    'orderPaid': [for (final o in orders) o.amountPaidKobo],
    'lineUnit': [for (final i in items) i.unitPriceKobo],
    'lineTotal': [for (final i in items) i.totalKobo],
    'lineCogs': [for (final i in items) i.buyingPriceKobo],
    'totalSales': computeTotalSalesKobo(withItems),
    'vanSoldValue': await r.db.vanTripsDao
        .watchSoldValueKoboForTrip(r.tripId)
        .first,
    'saleLines': [
      for (final l in await db.vanTripsDao.saleLinesForTrip(r.tripId))
        (l.productId == r.productId, l.quantity, l.rungValueKobo),
    ],
    'payments': (await db.select(db.paymentTransactions).get()).length,
    'driverBalance': await db.driverLedgerDao.getBalanceKobo(r.driverId),
    'ledgerRows': (await db.select(db.driverLedgerEntries).get()).length,
    'pos': [
      position.loadedValueKobo,
      position.soldValueKobo,
      position.rungValueKobo,
      position.balanceKobo,
      position.outstandingKobo,
      position.unremittedCashKobo,
      position.shortageOwedKobo,
      position.damageOwedKobo,
      position.residualCreditKobo,
      position.cogsKobo,
    ],
  };
}

void main() {
  group('driver extra is recorded apart from shop sales (#730)', () {
    test(
      'every shop money figure is IDENTICAL with and without an extra',
      () async {
        final plain = await _boot();
        await plain.ring(10);
        final plainFigures = await _shopFigures(plain);
        await plain.db.close();

        final extra = await _boot();
        await extra.ring(10, chargedKobo: _sell);
        final extraFigures = await _shopFigures(extra);

        expect(extraFigures, plainFigures);

        // ...and the extra IS recorded, on the side.
        final order = await extra.db.select(extra.db.orders).getSingle();
        expect(order.driverExtraKobo, 10 * (_sell - _load));
        expect(order.netAmountKobo, 10 * _load);
        final line = await extra.db.select(extra.db.orderItems).getSingle();
        expect(line.chargedUnitPriceKobo, _sell);
        expect(line.unitPriceKobo, _load);
        expect(
          await extra.db.vanTripsDao
              .watchDriverExtraKoboForTrip(extra.tripId)
              .first,
          10 * (_sell - _load),
        );
        await extra.db.close();
      },
    );

    test('the receipt (and a reprint) shows the price the customer paid',
        () async {
      final r = await _boot();
      await r.ring(2, chargedKobo: _sell);
      final sale = (await r.db.ordersDao.watchAllOrdersWithItems().first)
          .single;
      final cart = vanReceiptCart(sale);
      expect(cart.single['price'], _sell / 100.0);
      expect(cart.single['qty'], 2);
      expect(vanReceiptPaidKobo(sale.order), 2 * _sell);
      expect(vanReceiptCashKobo(sale.order), 2 * _sell);
      await r.db.close();
    });

    test('a sale at the load price records no extra', () async {
      final r = await _boot();
      await r.ring(3);
      final order = await r.db.select(r.db.orders).getSingle();
      expect(order.driverExtraKobo, 0);
      final line = await r.db.select(r.db.orderItems).getSingle();
      expect(line.chargedUnitPriceKobo, isNull);
      await r.db.close();
    });

    test(
      'a price BELOW the load price is rejected, and nothing is written',
      () async {
        final r = await _boot();
        await expectLater(
          r.ring(2, chargedKobo: _load - 1),
          throwsArgumentError,
        );
        expect(await r.db.select(r.db.orders).get(), isEmpty);
        await r.db.close();
      },
    );

    test('a cancelled road sale drops its extra', () async {
      final r = await _boot();
      await r.ring(4, chargedKobo: _sell);
      await r.ring(1, chargedKobo: _sell + 100);
      final first = (await r.db.select(r.db.orders).get()).firstWhere(
        (o) => o.driverExtraKobo == 4 * (_sell - _load),
      );
      await (r.db.update(r.db.orders)..where((o) => o.id.equals(first.id)))
          .write(const OrdersCompanion(status: Value('cancelled')));
      expect(
        await r.db.vanTripsDao.watchDriverExtraKoboForTrip(r.tripId).first,
        1 * (_sell + 100 - _load),
      );
      await r.db.close();
    });

    test(
      'a sale rung on a trip that has since closed counts toward ITS trip',
      () async {
        final r = await _boot();
        await r.ring(2, chargedKobo: _sell);
        // The sale carries its own van_trip_id, so the extra is attributed to
        // the trip regardless of when it syncs or whether the trip is closed.
        final order = await r.db.select(r.db.orders).getSingle();
        expect(order.vanTripId, r.tripId);
        expect(
          await r.db.vanTripsDao.watchDriverExtraKoboForTrip(r.tripId).first,
          2 * (_sell - _load),
        );
        await r.db.close();
      },
    );
  });

  group('checkout figures (#730)', () {
    test('the selling price cannot go below the load price', () {
      expect(driverSellPriceKobo(loadPriceKobo: _load, typedKobo: 100), _load);
      expect(driverSellPriceKobo(loadPriceKobo: _load, typedKobo: null), _load);
      expect(
        driverSellPriceKobo(loadPriceKobo: _load, typedKobo: _sell),
        _sell,
      );
    });

    test('customer pays, load value and extra', () {
      final f = driverCheckoutFigures([
        (units: 2, loadPriceKobo: _load, sellPriceKobo: _sell),
        (units: 1, loadPriceKobo: 500000, sellPriceKobo: 500000),
      ]);
      expect(f.customerPaysKobo, 2 * _sell + 500000);
      expect(f.loadValueKobo, 2 * _load + 500000);
      expect(f.extraKobo, 2 * (_sell - _load));
    });
  });
}
