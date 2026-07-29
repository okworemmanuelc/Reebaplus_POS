// staff_activity_metrics_test.dart
//
// #205 — the five figures on the Staff detail screen are tenant reads, so every
// one of them must be business-scoped (architecture.md invariant #5: no code
// path may read a row outside the caller's business_id).
//
// The screen used to compute them with four raw `customSelect`s keyed ONLY on
// the member's user id, with no `business_id` predicate. A device legitimately
// holds more than one business's rows (offline-first shared till, a staff
// account re-onboarded into a second business), so those aggregates summed
// BOTH businesses into one business's screen.
//
// These tests pin the four business-scoped DAO seams the screen now reads. Each
// seeds the SAME user id acting in two businesses, binds the session to the
// first, and asserts the second business's rows are invisible.

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

class _Biz {
  final String id;
  final String storeId;
  final String productId;

  _Biz({required this.id, required this.storeId, required this.productId});
}

Future<_Biz> _seedBusiness(AppDatabase db, String name) async {
  final id = UuidV7.generate();
  await db
      .into(db.businesses)
      .insert(BusinessesCompanion.insert(id: Value(id), name: name));

  final storeId = UuidV7.generate();
  await db.into(db.stores).insert(
        StoresCompanion.insert(
          id: Value(storeId),
          businessId: id,
          name: '$name store',
        ),
      );

  final productId = UuidV7.generate();
  await db.into(db.products).insert(
        ProductsCompanion.insert(
          id: Value(productId),
          businessId: id,
          name: '$name product',
          retailerPriceKobo: const Value(500),
        ),
      );

  return _Biz(id: id, storeId: storeId, productId: productId);
}

/// One users row, living in [home]. The second business's rows reference this
/// same id — exactly the shape of the leak: the id is what the four aggregates
/// keyed on, and nothing about it says which business the row belongs to.
Future<String> _seedStaff(AppDatabase db, _Biz home) async {
  final userId = UuidV7.generate();
  await db.into(db.users).insert(
        UsersCompanion.insert(
          id: Value(userId),
          businessId: home.id,
          name: 'Chidi',
          pin: '__HASHED__',
        ),
      );
  return userId;
}

/// One order plus its single item line. [netKobo] is the line's GROSS goods
/// value (qty 1 × unit price), which is what the staff sales total is summed
/// from since #195 — the order header's `net_amount_kobo` is seeded the way
/// production writes it (goods − discount + deposit) precisely so a test can
/// tell the two bases apart.
Future<String> _insertOrder(
  AppDatabase db,
  _Biz biz, {
  required String staffId,
  required int netKobo,
  required String status,
  int discountKobo = 0,
  int crateDepositPaidKobo = 0,
}) async {
  final id = UuidV7.generate();
  final headerKobo = netKobo - discountKobo + crateDepositPaidKobo;
  await db.into(db.orders).insert(
        OrdersCompanion.insert(
          id: Value(id),
          businessId: biz.id,
          // UUIDv7 is time-ordered, so its PREFIX repeats within a millisecond
          // — the random tail is what keeps `(business_id, order_number)` unique.
          orderNumber: 'ORD-${id.substring(id.length - 6)}-AAAAAA',
          totalAmountKobo: headerKobo,
          discountKobo: Value(discountKobo),
          netAmountKobo: headerKobo,
          paymentType: 'cash',
          status: status,
          staffId: Value(staffId),
          storeId: Value(biz.storeId),
          crateDepositPaidKobo: Value(crateDepositPaidKobo),
        ),
      );
  await db.into(db.orderItems).insert(
        OrderItemsCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: biz.id,
          orderId: id,
          productId: Value(biz.productId),
          storeId: biz.storeId,
          quantity: 1,
          unitPriceKobo: netKobo,
          totalKobo: netKobo,
        ),
      );
  return id;
}

Future<void> _insertStockTransaction(
  AppDatabase db,
  _Biz biz, {
  required String performedBy,
  required String orderId,
}) async {
  await db.into(db.stockTransactions).insert(
        StockTransactionsCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: biz.id,
          productId: biz.productId,
          locationId: biz.storeId,
          quantityDelta: -1,
          movementType: 'sale',
          orderId: Value(orderId),
          performedBy: Value(performedBy),
        ),
      );
}

Future<void> _insertQuickSaleRequest(
  AppDatabase db,
  _Biz biz, {
  required String requestedBy,
}) async {
  await db.into(db.quickSaleRequests).insert(
        QuickSaleRequestsCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: biz.id,
          storeId: biz.storeId,
          itemName: 'Sachet water',
          quantity: 1,
          unitPriceKobo: 5000,
          summary: '1 × Sachet water @ ₦50 = ₦50',
          requestedBy: Value(requestedBy),
        ),
      );
}

Future<void> _insertExpense(
  AppDatabase db,
  _Biz biz, {
  required String recordedBy,
  required int amountKobo,
  bool isDeleted = false,
}) async {
  await db.into(db.expenses).insert(
        ExpensesCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: biz.id,
          amountKobo: amountKobo,
          description: 'Diesel',
          recordedBy: Value(recordedBy),
          isDeleted: Value(isDeleted),
        ),
      );
}

void main() {
  late AppDatabase db;
  late _Biz mine; // the business the session is bound to
  late _Biz other; // a second business whose rows sit on the same device
  late String staffId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    mine = await _seedBusiness(db, 'Mama Put Bar');
    other = await _seedBusiness(db, 'Second Business');
    staffId = await _seedStaff(db, mine);
    db.businessIdResolver = () => mine.id;
  });

  tearDown(() => db.close());

  test('staff sales totals count only the bound business (#205)', () async {
    await _insertOrder(db, mine, staffId: staffId, netKobo: 30000, status: 'pending');
    await _insertOrder(
      db,
      mine,
      staffId: staffId,
      netKobo: 20000,
      status: 'completed',
    );
    // The other business's sale by the same person must not be summed in.
    await _insertOrder(
      db,
      other,
      staffId: staffId,
      netKobo: 90000,
      status: 'completed',
    );

    final totals = await db.ordersDao.getSalesTotalsForStaff(staffId);

    expect(totals.totalKobo, 50000);
    expect(totals.orderCount, 2);
  });

  test('a reversed sale counts for neither figure (revenue recognition)',
      () async {
    await _insertOrder(db, mine, staffId: staffId, netKobo: 30000, status: 'pending');
    await _insertOrder(
      db,
      mine,
      staffId: staffId,
      netKobo: 70000,
      status: 'cancelled',
    );
    await _insertOrder(
      db,
      mine,
      staffId: staffId,
      netKobo: 70000,
      status: 'refunded',
    );

    final totals = await db.ordersDao.getSalesTotalsForStaff(staffId);

    // `orderRevenueStatuses` (pending + completed), not a hand-written list.
    expect(totals.totalKobo, 30000);
    expect(totals.orderCount, 1);
  });

  test('another staff member\'s sales are not attributed to this one', () async {
    final otherStaff = await _seedStaff(db, mine);
    await _insertOrder(db, mine, staffId: staffId, netKobo: 30000, status: 'pending');
    await _insertOrder(
      db,
      mine,
      staffId: otherStaff,
      netKobo: 80000,
      status: 'pending',
    );

    final totals = await db.ordersDao.getSalesTotalsForStaff(staffId);

    expect(totals.totalKobo, 30000);
    expect(totals.orderCount, 1);
  });

  test('no sales at all reads as zero, not null', () async {
    final totals = await db.ordersDao.getSalesTotalsForStaff(staffId);

    expect(totals.totalKobo, 0);
    expect(totals.orderCount, 0);
  });

  // #195 (PRD #155 US 28) — the staff figure is the ONE Total Sales definition:
  // item lines minus discounts, DEPOSIT-EXCLUSIVE. It used to read the order
  // header's `net_amount_kobo`, which bundles the refundable crate deposit
  // (contra US 5), so a cashier in a crate shop showed a bigger "Total sales"
  // than the same sales reported anywhere else in the app.
  test('the total is item lines minus discounts, never the deposit (#195)',
      () async {
    await _insertOrder(
      db,
      mine,
      staffId: staffId,
      netKobo: 100000, // ₦1,000 of goods
      discountKobo: 15000, // − ₦150 given away
      crateDepositPaidKobo: 200000, // ₦2,000 held, never earned
      status: 'pending',
    );

    final totals = await db.ordersDao.getSalesTotalsForStaff(staffId);

    expect(totals.totalKobo, 85000);
    expect(totals.orderCount, 1);
  });

  test('one order\'s discount is subtracted ONCE however many lines it has',
      () async {
    // The two-query shape exists for this: joining the lines to the header
    // repeats `discount_kobo` per line, which would over-subtract it.
    final orderId = await _insertOrder(
      db,
      mine,
      staffId: staffId,
      netKobo: 60000,
      discountKobo: 10000,
      status: 'pending',
    );
    for (final unitPriceKobo in [40000, 25000]) {
      await db.into(db.orderItems).insert(
            OrderItemsCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: mine.id,
              orderId: orderId,
              productId: Value(mine.productId),
              storeId: mine.storeId,
              quantity: 1,
              unitPriceKobo: unitPriceKobo,
              totalKobo: unitPriceKobo,
            ),
          );
    }

    final totals = await db.ordersDao.getSalesTotalsForStaff(staffId);

    // (600 + 400 + 250) − 100, not − 300.
    expect(totals.totalKobo, 115000);
    expect(totals.orderCount, 1);
  });

  test('stock-movement count is scoped to the bound business (#205)', () async {
    final mineOrder = await _insertOrder(
      db,
      mine,
      staffId: staffId,
      netKobo: 1000,
      status: 'pending',
    );
    final otherOrder = await _insertOrder(
      db,
      other,
      staffId: staffId,
      netKobo: 1000,
      status: 'pending',
    );
    await _insertStockTransaction(db, mine,
        performedBy: staffId, orderId: mineOrder);
    await _insertStockTransaction(db, mine,
        performedBy: staffId, orderId: mineOrder);
    await _insertStockTransaction(db, other,
        performedBy: staffId, orderId: otherOrder);

    expect(await db.stockLedgerDao.countPerformedByStaff(staffId), 2);
  });

  test('quick-sale request count is scoped to the bound business (#205)',
      () async {
    await _insertQuickSaleRequest(db, mine, requestedBy: staffId);
    await _insertQuickSaleRequest(db, other, requestedBy: staffId);
    await _insertQuickSaleRequest(db, other, requestedBy: staffId);

    expect(await db.quickSaleRequestsDao.countRequestedByStaff(staffId), 1);
  });

  test('recorded-expense total is scoped to the bound business (#205)',
      () async {
    await _insertExpense(db, mine, recordedBy: staffId, amountKobo: 15000);
    await _insertExpense(db, other, recordedBy: staffId, amountKobo: 99000);

    expect(await db.expensesDao.getTotalRecordedByStaff(staffId), 15000);
  });

  test('a deleted expense drops out of the recorded total', () async {
    await _insertExpense(db, mine, recordedBy: staffId, amountKobo: 15000);
    await _insertExpense(
      db,
      mine,
      recordedBy: staffId,
      amountKobo: 40000,
      isDeleted: true,
    );

    expect(await db.expensesDao.getTotalRecordedByStaff(staffId), 15000);
  });

  test('every seam refuses to read with no bound session', () async {
    db.businessIdResolver = () => null;

    // requireBusinessId() makes a cross-tenant read a loud failure rather than
    // silent data bleed — the whole point of the DAO seam.
    await expectLater(db.ordersDao.getSalesTotalsForStaff(staffId),
        throwsA(isA<StateError>()));
    await expectLater(db.stockLedgerDao.countPerformedByStaff(staffId),
        throwsA(isA<StateError>()));
    await expectLater(db.quickSaleRequestsDao.countRequestedByStaff(staffId),
        throwsA(isA<StateError>()));
    await expectLater(db.expensesDao.getTotalRecordedByStaff(staffId),
        throwsA(isA<StateError>()));
  });
}
