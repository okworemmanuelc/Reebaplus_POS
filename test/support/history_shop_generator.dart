// history_shop_generator.dart
//
// #682 (PRD #680, "Smooth screens") — a deterministic test shop with N months of
// realistic history, for measuring (and later regression-testing) the report
// screens at the size a long-running shop really reaches.
//
// TEST / DEV TOOL ONLY. It lives under test/ and is never imported by lib/, so
// it is not shipped in the app.
//
// What it fills (all through the real DAOs / OrderService, so the app's own
// invariants hold — stock guard, FIFO cost layers, payment tender split, wallet
// double entry, reversal rows):
//   · sales with 1–6 lines each (cash / transfer / part-credit, some to
//     registered customers, some with a crate deposit held), via checkout;
//   · sales cancelled on a LATER day (a return), via markCancelled;
//   · van sales (a road trip is loaded, sells, is closed);
//   · crate deposits held / released / forfeited (settleCrateDepositReturn);
//   · expenses, supplier payments + invoices, stock adjustments / damages,
//     stock movements (receiving stock), stock counts, empty-crate damages.
//
// Time travel: the DAOs stamp "now". After each simulated day the rows written
// that day are re-stamped onto that day (rowid-window UPDATE). The append-only
// ledgers refuse UPDATE through their `_immutable` triggers, so — exactly like
// test/crates/crate_forfeit_netting_test.dart's `backdate` — this drops those
// guards on the throwaway database. Nothing in lib/ may ever do this.

import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/shared/services/orders/order_service.dart';

/// The last simulated day. Fixed so a run never depends on the clock.
final DateTime kHistoryShopEnd = DateTime(2026, 10, 31);

/// A built shop: the open database plus the ids a measurement needs.
class HistoryShop {
  HistoryShop({
    required this.db,
    required this.businessId,
    required this.storeId,
    required this.vanStoreId,
    required this.staffId,
    required this.productIds,
    required this.customerIds,
    required this.manufacturerIds,
    required this.start,
    required this.end,
    required this.counts,
  });

  final AppDatabase db;
  final String businessId;
  final String storeId;
  final String vanStoreId;
  final String staffId;
  final List<String> productIds;
  final List<String> customerIds;
  final List<String> manufacturerIds;

  /// First and last simulated day (both inclusive).
  final DateTime start;
  final DateTime end;

  /// Row counts the generator wrote, by what they are (sales, saleLines, ...).
  final Map<String, int> counts;

  /// The product with the most sale lines (the "busy product").
  late final String busiestProductId = productIds.first;

  Future<void> close() => db.close();
}

/// How big and how busy. Defaults (8-20 sales a day, 1-6 lines each) put
/// 24 months at ~35k sale lines, 4x the largest real shop (~8,800 lines).
class HistoryShopSpec {
  const HistoryShopSpec({
    required this.months,
    this.seed = 682,
    this.minSalesPerDay = 8,
    this.maxSalesPerDay = 20,
    this.productCount = 40,
    this.customerCount = 40,
  });

  final int months;
  final int seed;
  final int minSalesPerDay;
  final int maxSalesPerDay;
  final int productCount;
  final int customerCount;
}

/// A fresh in-memory database, or a file-backed one when [filePath] is given
/// (the benchmark uses a file so timings include real disk IO).
AppDatabase newHistoryDb({String? filePath}) {
  if (filePath == null) return AppDatabase.forTesting(NativeDatabase.memory());
  final f = File(filePath);
  if (f.existsSync()) f.deleteSync();
  return AppDatabase.forTesting(NativeDatabase(f));
}

/// Tables whose rows the DAOs stamp with the real clock and that therefore need
/// moving onto the simulated day. (Row-id windows, so nothing else is touched.)
const _stampedTables = [
  'orders',
  'order_items',
  'payment_transactions',
  'wallet_transactions',
  'stock_transactions',
  'stock_adjustments',
  'crate_ledger',
  'cost_batches',
  'supplier_ledger_entries',
  'expenses',
  'crate_shortfall_writeoffs',
  'stock_counts',
  'van_trips',
  'van_trip_lines',
  'driver_ledger_entries',
  'activity_logs',
];

Future<HistoryShop> buildHistoryShop(
  AppDatabase db,
  HistoryShopSpec spec,
) async {
  final rnd = Random(spec.seed);
  final businessId = UuidV7.generate();
  db.businessIdResolver = () => businessId;
  await db.customSelect('SELECT 1').get(); // force onCreate

  // Time machine: drop every append-only guard on this throwaway database.
  final triggers = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type='trigger' "
        "AND name LIKE '%\\_immutable' ESCAPE '\\'",
      )
      .get();
  for (final t in triggers) {
    await db.customStatement(
      'DROP TRIGGER IF EXISTS ${t.read<String>('name')}',
    );
  }
  // Which of the stamped tables really exist and carry created_at.
  final stamped = <String, bool>{}; // table -> has last_updated_at
  for (final t in _stampedTables) {
    final cols = await db.customSelect('PRAGMA table_info($t)').get();
    final names = {for (final c in cols) c.read<String>('name')};
    if (names.contains('created_at')) {
      stamped[t] = names.contains('last_updated_at');
    }
  }

  await db
      .into(db.businesses)
      .insert(
        BusinessesCompanion.insert(id: Value(businessId), name: 'History Shop'),
      );
  final storeId = UuidV7.generate();
  final warehouseId = storeId;
  await db
      .into(db.stores)
      .insert(
        StoresCompanion.insert(
          id: Value(storeId),
          businessId: businessId,
          name: 'Main Store',
        ),
      );
  final vanStoreId = UuidV7.generate();
  await db
      .into(db.stores)
      .insert(
        StoresCompanion.insert(
          id: Value(vanStoreId),
          businessId: businessId,
          name: 'Van 1',
          kind: const Value(kStoreKindVan),
        ),
      );
  final staffId = UuidV7.generate();
  await db
      .into(db.users)
      .insert(
        UsersCompanion.insert(
          id: Value(staffId),
          businessId: businessId,
          name: 'Amaka Obi',
          pin: '123456',
        ),
      );
  final driverId = UuidV7.generate();
  await db
      .into(db.users)
      .insert(
        UsersCompanion.insert(
          id: Value(driverId),
          businessId: businessId,
          name: 'Driver Dan',
          pin: '654321',
        ),
      );

  final manufacturerIds = <String>[];
  for (final (name, deposit) in const [
    ('Nigerian Breweries', 120000),
    ('Guinness Nigeria', 150000),
  ]) {
    final id = UuidV7.generate();
    await db
        .into(db.manufacturers)
        .insert(
          ManufacturersCompanion.insert(
            id: Value(id),
            businessId: businessId,
            name: name,
            depositAmountKobo: Value(deposit),
          ),
        );
    manufacturerIds.add(id);
  }

  final supplierId = UuidV7.generate();
  await db
      .into(db.suppliers)
      .insert(
        SuppliersCompanion.insert(
          id: Value(supplierId),
          businessId: businessId,
          name: 'Kano Distributors',
        ),
      );

  final customerIds = <String>[];
  for (var i = 0; i < spec.customerCount; i++) {
    customerIds.add(
      await db.customersDao.addCustomer(
        CustomersCompanion.insert(
          businessId: businessId,
          name: 'Customer ${i + 1}',
        ),
      ),
    );
  }

  // Catalogue: each product has a stable sell price and cost; a zipf-ish weight
  // makes a few products "busy" and most quiet, like a real shop.
  final productIds = <String>[];
  final sellKobo = <int>[];
  final costKobo = <int>[];
  final unitCostFor = <String, int>{};
  for (var i = 0; i < spec.productCount; i++) {
    final cost = (200 + rnd.nextInt(2800)) * 100;
    final sell = (cost * (1.1 + rnd.nextDouble() * 0.3)).round();
    final id = await db.catalogDao.insertProductWithInitialStock(
      ProductsCompanion.insert(
        name: 'Product ${i + 1}',
        businessId: businessId,
        retailerPriceKobo: Value(sell),
        buyingPriceKobo: Value(cost),
        unit: const Value('Piece'),
        manufacturerId: Value(manufacturerIds[i % manufacturerIds.length]),
      ),
      initialStock: 0,
      storeId: storeId,
      performedBy: staffId,
    );
    productIds.add(id);
    sellKobo.add(sell);
    costKobo.add(cost);
    unitCostFor[id] = cost;
  }
  // weights 1/(rank+1): product 0 is the busiest.
  final weights = [for (var i = 0; i < productIds.length; i++) 1 / (i + 1)];
  final weightTotal = weights.fold<double>(0, (a, b) => a + b);
  int pickProduct() {
    var r = rnd.nextDouble() * weightTotal;
    for (var i = 0; i < weights.length; i++) {
      r -= weights[i];
      if (r <= 0) return i;
    }
    return weights.length - 1;
  }

  final orders = OrderService(db);
  final counts = <String, int>{
    'sales': 0,
    'saleLines': 0,
    'cancelled': 0,
    'vanSales': 0,
    'depositsHeld': 0,
    'depositsReleased': 0,
    'depositsForfeited': 0,
    'expenses': 0,
    'supplierEntries': 0,
    'adjustments': 0,
    'receipts': 0,
    'stockCounts': 0,
    'crateDamages': 0,
    'days': 0,
  };

  Future<void> stockIn(
    int index,
    double qty, {
    required String storeId,
    String note = 'Received stock',
  }) async {
    await db.inventoryDao.adjustStock(
      productIds[index],
      storeId,
      qty,
      note,
      staffId,
      movementType: 'purchase_received',
      inflowUnitCostKobo: costKobo[index],
    );
  }

  // Opening stock for the whole catalogue, then restocked monthly.
  for (var i = 0; i < productIds.length; i++) {
    await stockIn(i, 3000, storeId: storeId, note: 'Opening stock');
  }

  final end = kHistoryShopEnd;
  final start = DateTime(end.year, end.month - spec.months, end.day + 1);
  final totalDays = end.difference(start).inDays + 1;
  final stockOnHand = {for (final id in productIds) id: 3000.0};

  // Re-stamp everything written since [marks] onto [day] (noon-ish + jitter).
  Future<Map<String, int>> snapshotMarks() async {
    final out = <String, int>{};
    for (final t in stamped.keys) {
      final r = await db
          .customSelect('SELECT COALESCE(MAX(rowid),0) AS m FROM $t')
          .getSingle();
      out[t] = r.read<int>('m');
    }
    return out;
  }

  Future<void> restamp(Map<String, int> marks, DateTime day) async {
    // Seconds since epoch; spread through trading hours by rowid so a day's
    // rows are not all the same instant (stable + deterministic).
    final base = DateTime(day.year, day.month, day.day, 8).toUtc();
    final baseSecs = base.millisecondsSinceEpoch ~/ 1000;
    for (final e in stamped.entries) {
      final set = e.value
          ? 'created_at = $baseSecs + ((rowid * 37) % 36000), '
                'last_updated_at = $baseSecs + ((rowid * 37) % 36000)'
          : 'created_at = $baseSecs + ((rowid * 37) % 36000)';
      await db.customStatement(
        'UPDATE ${e.key} SET $set WHERE rowid > ${marks[e.key]}',
      );
    }
  }

  DateTime stampOf(DateTime day, int hour) =>
      DateTime(day.year, day.month, day.day, hour);

  // Orders cancelled on a later day: (orderId, cancelDay).
  final cancelQueue = <(String, DateTime)>[];
  final completedOrders = <String>[];
  String? openVanTripId;
  DateTime? vanOpenedOn;

  for (var d = 0; d < totalDays; d++) {
    final day = DateTime(start.year, start.month, start.day + d);
    final isSunday = day.weekday == DateTime.sunday;
    final marks = await snapshotMarks();

    // ── Monthly restock (first day of month): stock movements + supplier invoice
    if (day.day == 1 || d == 0) {
      var invoiceKobo = 0;
      for (var i = 0; i < productIds.length; i++) {
        final onHand = stockOnHand[productIds[i]]!;
        if (onHand < 1500) {
          const qty = 2000.0;
          await stockIn(i, qty, storeId: storeId);
          stockOnHand[productIds[i]] = onHand + qty;
          invoiceKobo += (qty * costKobo[i]).round();
          counts['receipts'] = counts['receipts']! + 1;
        }
      }
      if (invoiceKobo > 0) {
        final at = stampOf(day, 9);
        await db
            .into(db.supplierLedgerEntries)
            .insert(
              SupplierLedgerEntriesCompanion.insert(
                businessId: businessId,
                supplierId: supplierId,
                storeId: Value(storeId),
                type: 'debit',
                amountKobo: invoiceKobo,
                signedAmountKobo: -invoiceKobo,
                referenceType: 'invoice',
                activityDate: at,
              ),
            );
        // pay most of it a little later
        await db
            .into(db.supplierLedgerEntries)
            .insert(
              SupplierLedgerEntriesCompanion.insert(
                businessId: businessId,
                supplierId: supplierId,
                storeId: Value(storeId),
                type: 'credit',
                amountKobo: (invoiceKobo * 0.8).round(),
                signedAmountKobo: (invoiceKobo * 0.8).round(),
                referenceType: 'payment_cash',
                paymentMethod: const Value('cash'),
                activityDate: at.add(const Duration(days: 2)),
              ),
            );
        counts['supplierEntries'] = counts['supplierEntries']! + 2;
      }
    }

    // ── Sales
    if (!isSunday || rnd.nextInt(4) == 0) {
      final n =
          spec.minSalesPerDay +
          rnd.nextInt(spec.maxSalesPerDay - spec.minSalesPerDay + 1);
      for (var s = 0; s < n; s++) {
        final lineCount = 1 + rnd.nextInt(6);
        final picked = <int>{};
        while (picked.length < lineCount) {
          picked.add(pickProduct());
        }
        final cart = <Map<String, dynamic>>[];
        var total = 0;
        for (final idx in picked) {
          final qty = 1 + rnd.nextInt(6);
          // Keep the stock guard happy; restock on the spot if a hot product
          // ran dry (a real shop would have received stock by now).
          if (stockOnHand[productIds[idx]]! < qty + 5) {
            await stockIn(idx, 2000, storeId: storeId);
            stockOnHand[productIds[idx]] = stockOnHand[productIds[idx]]! + 2000;
          }
          stockOnHand[productIds[idx]] = stockOnHand[productIds[idx]]! - qty;
          cart.add({
            'id': productIds[idx],
            'qty': qty,
            'unitPriceKobo': sellKobo[idx],
            'buyingPriceKobo': 0,
            'name': 'Product ${idx + 1}',
          });
          total += qty * sellKobo[idx];
        }
        final registered = rnd.nextInt(10) < 3;
        final customerId = registered
            ? customerIds[rnd.nextInt(customerIds.length)]
            : null;
        final kind = rnd.nextInt(10);
        var paid = total;
        var subType = 'cash';
        if (registered && kind == 0) {
          paid = (total * 0.4).round();
          subType = 'cash'; // part-credit: pays less than the total
        } else if (kind >= 7) {
          subType = 'transfer';
        }
        // A crate deposit held on some registered sales.
        final depositKobo = registered && rnd.nextInt(8) == 0 ? 240000 : 0;
        final orderNumber = await orders.addOrder(
          customerId: customerId,
          cart: cart,
          totalAmountKobo: total,
          amountPaidKobo: paid + depositKobo,
          paymentType: subType == 'transfer' ? 'Transfer' : 'Cash',
          staffId: staffId,
          storeId: storeId,
          paymentSubType: subType,
          crateDepositPaidKobo: depositKobo,
          crateDepositPaidByManufacturer: depositKobo > 0
              ? {manufacturerIds.first: depositKobo}
              : const {},
        );
        counts['sales'] = counts['sales']! + 1;
        counts['saleLines'] = counts['saleLines']! + cart.length;
        if (depositKobo > 0) {
          counts['depositsHeld'] = counts['depositsHeld']! + 1;
        }
        if (rnd.nextInt(25) == 0) {
          final row = await (db.select(
            db.orders,
          )..where((o) => o.orderNumber.equals(orderNumber))).getSingle();
          cancelQueue.add((
            row.id,
            day.add(Duration(days: 1 + rnd.nextInt(6))),
          ));
        } else if (depositKobo > 0 && rnd.nextBool()) {
          final row = await (db.select(
            db.orders,
          )..where((o) => o.orderNumber.equals(orderNumber))).getSingle();
          completedOrders.add(row.id);
        }
      }
    }

    // ── Expenses
    if (rnd.nextInt(2) == 0) {
      await db.expensesDao.addExpense(
        categoryName: const [
          'Transport',
          'Fuel',
          'Rent',
          'Wages',
          'Repairs',
        ][rnd.nextInt(5)],
        amountKobo: (500 + rnd.nextInt(20000)) * 100,
        description: 'Expense ${d + 1}',
        paymentMethod: 'cash',
        storeId: storeId,
        recordedBy: staffId,
        expenseDate: stampOf(day, 11),
      );
      counts['expenses'] = counts['expenses']! + 1;
    }

    // ── Stock adjustments / damages
    if (rnd.nextInt(3) == 0) {
      final idx = pickProduct();
      final damage = rnd.nextBool();
      final qty = 1.0 + rnd.nextInt(5);
      await db.inventoryDao.adjustStock(
        productIds[idx],
        storeId,
        -qty,
        damage ? 'Broken' : 'Count correction',
        staffId,
        movementType: damage ? 'damage' : 'adjustment',
      );
      stockOnHand[productIds[idx]] = stockOnHand[productIds[idx]]! - qty;
      counts['adjustments'] = counts['adjustments']! + 1;
    }

    // ── Weekly stock count (Saturday)
    if (day.weekday == DateTime.saturday) {
      final lines = <Map<String, dynamic>>[];
      for (var k = 0; k < 6; k++) {
        final idx = rnd.nextInt(productIds.length);
        final diff = rnd.nextInt(7) - 3;
        final system = stockOnHand[productIds[idx]]!.round();
        lines.add({
          'p': productIds[idx],
          'n': 'Product ${idx + 1}',
          's': system,
          'a': system + diff,
          'd': diff.toDouble(),
        });
      }
      await db.stockCountsDao.recordCount(
        storeId: storeId,
        businessDate:
            '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}',
        productsCounted: productIds.length,
        changedLines: lines,
        countedBy: staffId,
      );
      counts['stockCounts'] = counts['stockCounts']! + 1;
    }

    // ── Crate damages (empties) — rare
    if (rnd.nextInt(20) == 0) {
      try {
        await db.cratePoolDao.recordManualCountCorrection(
          manufacturerId: manufacturerIds.first,
          storeId: storeId,
          performedBy: staffId,
          countedEmpties: 30,
        );
        await db.cratePoolDao.recordDamage(
          manufacturerIds.first,
          1,
          storeId: storeId,
          performedBy: staffId,
          ratePerCrateKobo: 120000,
          reason: 'broken in store',
        );
        counts['crateDamages'] = counts['crateDamages']! + 1;
      } on ArgumentError {
        // not enough empties on hand that day — skip, like a real shop would
      }
    }

    // ── Deposits released / forfeited, on completed registered sales
    while (completedOrders.isNotEmpty && rnd.nextInt(3) != 0) {
      final orderId = completedOrders.removeLast();
      final o = await (db.select(
        db.orders,
      )..where((t) => t.id.equals(orderId))).getSingle();
      if (o.customerId == null) continue;
      final forfeit = rnd.nextBool();
      await db.ordersDao.settleCrateDepositReturn(
        customerId: o.customerId!,
        manufacturerId: manufacturerIds.first,
        orderId: orderId,
        takenCrates: 2,
        returnedCrates: forfeit ? 0 : 2,
        rateKobo: 120000,
        paidKobo: 240000,
        refundAsCash: !forfeit && rnd.nextBool(),
        performedBy: staffId,
      );
      counts[forfeit ? 'depositsForfeited' : 'depositsReleased'] =
          counts[forfeit ? 'depositsForfeited' : 'depositsReleased']! + 1;
    }

    // ── Van trip: open one on the 1st and 15th, sell on the road, close 5d later
    if (openVanTripId == null && (day.day == 1 || day.day == 15)) {
      final lines = [
        for (final i in [0, 1, 2, 3])
          VanLoadLine(
            productId: productIds[i],
            quantity: 120,
            loadPriceKobo: sellKobo[i],
          ),
      ];
      final result = await db.vanTripsDao.dispatchLoad(
        vanStoreId: vanStoreId,
        driverUserId: driverId,
        sourceStoreId: warehouseId,
        lines: lines,
        performedBy: staffId,
        dispatchEventId: UuidV7.generate(),
        dispatchedAt: stampOf(day, 7),
      );
      for (final i in [0, 1, 2, 3]) {
        stockOnHand[productIds[i]] = stockOnHand[productIds[i]]! - 120;
      }
      openVanTripId = result.tripId;
      vanOpenedOn = day;
    }
    if (openVanTripId != null) {
      for (var v = 0; v < 6; v++) {
        final i = rnd.nextInt(4);
        final qty = 1 + rnd.nextInt(4);
        await orders.addOrder(
          customerId: null,
          cart: [
            {
              'id': productIds[i],
              'qty': qty,
              'unitPriceKobo': sellKobo[i],
              'buyingPriceKobo': 0,
              'name': 'Product ${i + 1}',
            },
          ],
          totalAmountKobo: qty * sellKobo[i],
          amountPaidKobo: qty * sellKobo[i],
          paymentType: 'Cash',
          staffId: driverId,
          storeId: vanStoreId,
        );
        counts['vanSales'] = counts['vanSales']! + 1;
      }
      if (day.difference(vanOpenedOn!).inDays >= 5) {
        final tripId = openVanTripId;
        openVanTripId = null;
        try {
          await db.vanTripsDao.closeTrip(
            tripId: tripId,
            performedBy: staffId,
            closedAt: stampOf(day, 18),
          );
        } on Object {
          // A trip that cannot close cleanly (unremitted cash) just stays
          // open in the data — still realistic, and not what we measure.
        }
      }
    }

    // ── Cancels due today (returns of earlier sales)
    final dueToday = cancelQueue.where((c) => !c.$2.isAfter(day)).toList();
    for (final c in dueToday) {
      cancelQueue.remove(c);
      await db.ordersDao.markCancelled(c.$1, 'Customer returned it', staffId);
      counts['cancelled'] = counts['cancelled']! + 1;
      await db.customStatement(
        'UPDATE orders SET cancelled_at = ? WHERE id = ?',
        [stampOf(day, 16).toUtc().millisecondsSinceEpoch ~/ 1000, c.$1],
      );
    }

    await restamp(marks, day);
    counts['days'] = counts['days']! + 1;
  }

  return HistoryShop(
    db: db,
    businessId: businessId,
    storeId: storeId,
    vanStoreId: vanStoreId,
    staffId: staffId,
    productIds: productIds,
    customerIds: customerIds,
    manufacturerIds: manufacturerIds,
    start: start,
    end: end,
    counts: counts,
  );
}
