// Sample data and pump helpers for the Orders restyle tests and goldens
// (#393 PR 2). Sample data only: Stallion Global, Abuja HQ, made-up people.
//
// Time-proof: every order hangs off `seedAnchorToday()` (noon today), so the
// cards always read "Today · 11:55" etc. and the default "Today" period always
// includes them; crate returns carry a fixed submitted time.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';

import '../helpers/screen_harness.dart';

/// CEO-level grants for the Orders tab (Refund + Confirm + cash refund).
const ordersCeoGrants = {
  'sales.make',
  'sales.view',
  'sales.cancel',
  'sales.confirm',
  'orders.view',
  'reports.profit',
  'customers.wallet.withdraw',
};

/// A cashier: may confirm, may not refund, sees no money.
const ordersCashierGrants = {
  'sales.make',
  'sales.view',
  'sales.confirm',
  'orders.view',
};

const kOrdersCustomerId = 'cust-chinedu';
const kOrdersOtherCustomerId = 'cust-ngozi';
const kOrdersStaffId = 'staff-amaka';
const kPendingCrateOrderId = 'order-pending-crates';

/// Seeds products, people, orders on all three tabs and two crate returns.
/// Returns the environment with refreshed product rows.
Future<void> seedOrdersSample(ScreenTestEnvironment env) async {
  final db = env.db;
  await (db.update(db.stores)..where((t) => t.id.equals(env.storeId))).write(
    const StoresCompanion(name: Value('Abuja HQ')),
  );
  final mfrId = env.manufacturers.first.id;
  await (db.update(db.manufacturers)..where((t) => t.id.equals(mfrId))).write(
    const ManufacturersCompanion(
      name: Value('Nigerian Breweries'),
      depositAmountKobo: Value(100000),
    ),
  );
  const names = ['Star Lager', 'Hero Lager', 'Eva Water'];
  for (var i = 0; i < 3; i++) {
    await (db.update(
      db.products,
    )..where((t) => t.id.equals(env.products[i].id))).write(
      ProductsCompanion(
        name: Value(names[i]),
        unit: Value(i < 2 ? 'Bottle' : 'Pack'),
        trackEmpties: Value(i < 2),
        manufacturerId: Value(i < 2 ? mfrId : null),
      ),
    );
  }
  await db
      .into(db.users)
      .insert(
        UsersCompanion.insert(
          id: const Value(kOrdersStaffId),
          businessId: env.businessId,
          name: 'Amaka Eze',
          pin: '0000',
        ),
      );
  for (final (id, name, address) in [
    (kOrdersCustomerId, 'Chinedu Okafor', '12 Ademola Street, Wuse'),
    (kOrdersOtherCustomerId, 'Ngozi Bello', 'N/A'),
  ]) {
    await db
        .into(db.customers)
        .insert(
          CustomersCompanion.insert(
            id: Value(id),
            businessId: env.businessId,
            name: name,
            address: Value(address),
            storeId: Value(env.storeId),
          ),
        );
  }

  final noon = seedAnchorToday();
  var n = 0;
  Future<void> order({
    String? id,
    required String status,
    String? customerId,
    required String paymentType,
    required List<(int product, int qty, int priceKobo)> lines,
    int discountKobo = 0,
    int? paidKobo,
    String? reason,
    int depositPaidKobo = 0,
  }) async {
    n++;
    final orderId = id ?? 'order-$status-$n';
    final total = lines.fold<int>(0, (s, l) => s + l.$2 * l.$3);
    final net = total - discountKobo;
    final at = noon.subtract(Duration(minutes: n * 7));
    await db
        .into(db.orders)
        .insert(
          OrdersCompanion.insert(
            id: Value(orderId),
            businessId: env.businessId,
            orderNumber: 'ORD-0001${n.toString().padLeft(2, '0')}-A1B2C3',
            customerId: Value(customerId),
            totalAmountKobo: total,
            netAmountKobo: net,
            discountKobo: Value(discountKobo),
            amountPaidKobo: Value(paidKobo ?? net),
            crateDepositPaidKobo: Value(depositPaidKobo),
            paymentType: paymentType,
            status: status,
            staffId: const Value(kOrdersStaffId),
            storeId: Value(env.storeId),
            cancellationReason: Value(reason),
            createdAt: Value(at),
            completedAt: Value(status == 'completed' ? at : null),
            cancelledAt: Value(status == 'cancelled' ? at : null),
          ),
        );
    for (final (p, qty, price) in lines) {
      await db
          .into(db.orderItems)
          .insert(
            OrderItemsCompanion.insert(
              businessId: env.businessId,
              storeId: env.storeId,
              orderId: orderId,
              productId: Value(env.products[p].id),
              quantity: qty,
              unitPriceKobo: price,
              totalKobo: qty * price,
            ),
          );
    }
  }

  // Pending: a named crate order with a part deposit, a walk-in, a credit sale.
  await order(
    id: kPendingCrateOrderId,
    status: 'pending',
    customerId: kOrdersCustomerId,
    paymentType: 'mixed',
    lines: [(0, 2, 960000), (1, 1, 840000), (2, 2, 270000)],
    discountKobo: 50000,
    paidKobo: 2000000,
    depositPaidKobo: 150000,
  );
  await db
      .into(db.orderCrateLines)
      .insert(
        OrderCrateLinesCompanion.insert(
          id: const Value('ocl-1'),
          businessId: env.businessId,
          orderId: kPendingCrateOrderId,
          manufacturerId: mfrId,
          cratesTaken: 3,
          depositRateKobo: const Value(100000),
          depositPaidKobo: const Value(150000),
        ),
      );
  await order(status: 'pending', paymentType: 'cash', lines: [(2, 4, 270000)]);
  await order(
    status: 'pending',
    customerId: kOrdersOtherCustomerId,
    paymentType: 'credit',
    lines: [(1, 3, 840000)],
    paidKobo: 0,
  );
  // Completed.
  await order(
    status: 'completed',
    customerId: kOrdersCustomerId,
    paymentType: 'transfer',
    lines: [(0, 1, 960000), (2, 1, 270000)],
  );
  await order(
    status: 'completed',
    paymentType: 'cash',
    lines: [(1, 2, 840000)],
  );
  // Cancelled, with a reason.
  await order(
    status: 'cancelled',
    customerId: kOrdersOtherCustomerId,
    paymentType: 'cash',
    lines: [(0, 1, 960000)],
    reason: 'Customer changed their mind',
  );

  // Two crate returns awaiting approval (fixed submitted time).
  for (final (id, qty) in [('ret-1', 2), ('ret-2', 1)]) {
    await db
        .into(db.pendingCrateReturns)
        .insert(
          PendingCrateReturnsCompanion.insert(
            id: Value(id),
            businessId: env.businessId,
            orderId: const Value(kPendingCrateOrderId),
            customerId: kOrdersCustomerId,
            manufacturerId: mfrId,
            quantity: qty,
            submittedBy: kOrdersStaffId,
            submittedAt: Value(DateTime(2026, 10, 11, 10, 30)),
          ),
        );
  }
}

/// Pumps [screen] with the Orders overrides: a crate business, the debt of
/// Chinedu Okafor (₦12,500) on the credit ledger, and the given role.
Future<void> pumpOrders(
  WidgetTester tester, {
  required ScreenTestEnvironment env,
  required Widget screen,
  Size size = const Size(390, 844),
  EdgeInsets padding = const EdgeInsets.only(top: 24, bottom: 48),
  EdgeInsets viewInsets = EdgeInsets.zero,
  TextScaler? textScaler,
  Brightness brightness = Brightness.light,
  bool cashier = false,
  double? bottomNavHeight,
}) async {
  await pumpScreen(
    tester,
    env: env,
    size: size,
    padding: padding,
    viewInsets: viewInsets,
    textScaler: textScaler,
    screen: screen,
    bottomNavHeight: bottomNavHeight ?? kBottomNavBodyHeight,
    theme: brightness == Brightness.light ? AppTheme.light() : AppTheme.dark(),
    grantedKeys: cashier ? ordersCashierGrants : ordersCeoGrants,
    roleSlug: cashier ? 'cashier' : 'ceo',
    roleName: cashier ? 'Cashier' : 'CEO',
    roleRank: cashier ? 2 : 0,
    overrides: [
      firstRunSurfaceStateProvider.overrideWithValue(
        FirstRunSurfaceState.hasContent,
      ),
      creditBalancesKoboProvider.overrideWith(
        (ref) => Stream.value({kOrdersCustomerId: -1250000}),
      ),
    ],
    settle: false,
  );
  await settleOrders(tester);
}

Future<void> settleOrders(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 250));
  }
}
