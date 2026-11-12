// driver_old_account_screen_test.dart
//
// #783 — what a manager sees after bringing in an old customer account:
//   · the driver's Sales tab lists the old account's sale, tagged;
//   · the Ledger tab lists the old account's payment (tagged) and the moved
//     debt (labelled), and the balance card shows the driver ledger ONLY;
//   · the page has no "Bring in old customer account" button (#804);
//   · the customer's own page says "Now a van driver: <name>";
//   · a linked customer is absent from the sale customer list feed.

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/van_sales/van_sales_switch.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/customers/screens/customer_detail_screen.dart';
import 'package:reebaplus_pos/features/van_sales/screens/driver_profile_screen.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const grants = {'van.manage', 'sales.make', 'reports.see_sales'};

  late ScreenTestEnvironment env;
  late String driverId;
  late String linkedCustomerId;
  late String freeCustomerId;

  Future<void> settleFrames(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  setUp(() async {
    debugOverrideVanSalesEnabled(true);
    debugOverrideDriverScreensEnabled(true);
    env = await setupScreenTestEnvironment(businessType: 'drinks');
    final db = env.db;
    final b = env.businessId;

    driverId = UuidV7.generate();
    linkedCustomerId = UuidV7.generate();
    freeCustomerId = UuidV7.generate();

    await db
        .into(db.vanDrivers)
        .insert(
          VanDriversCompanion.insert(
            id: Value(driverId),
            businessId: b,
            name: 'Johnson Kim',
          ),
        );
    final vanStoreId = UuidV7.generate();
    await db
        .into(db.stores)
        .insert(
          StoresCompanion.insert(
            id: Value(vanStoreId),
            businessId: b,
            name: 'Beer Vsm',
            kind: const Value('van'),
            vanDriverId: Value(driverId),
          ),
        );

    for (final (id, name) in [
      (linkedCustomerId, 'Johnson Kim (Beer Van Driver)'),
      (freeCustomerId, 'Walk Up Customer'),
    ]) {
      await db
          .into(db.customers)
          .insert(
            CustomersCompanion.insert(id: Value(id), businessId: b, name: name),
          );
    }
    final walletId = UuidV7.generate();
    await db
        .into(db.customerWallets)
        .insert(
          CustomerWalletsCompanion.insert(
            id: Value(walletId),
            businessId: b,
            customerId: linkedCustomerId,
          ),
        );
    final at = DateTime.now().subtract(const Duration(minutes: 5));
    final oid = UuidV7.generate();
    await db
        .into(db.orders)
        .insert(
          OrdersCompanion.insert(
            id: Value(oid),
            businessId: b,
            orderNumber: 'ORD-OLD-1',
            customerId: Value(linkedCustomerId),
            totalAmountKobo: 100000,
            netAmountKobo: 100000,
            amountPaidKobo: const Value(40000),
            paymentType: 'mixed',
            status: 'completed',
            createdAt: Value(at),
            lastUpdatedAt: Value(at),
          ),
        );
    await db
        .into(db.walletTransactions)
        .insert(
          WalletTransactionsCompanion.insert(
            businessId: b,
            walletId: walletId,
            customerId: linkedCustomerId,
            type: 'debit',
            amountKobo: 60000,
            signedAmountKobo: -60000,
            referenceType: 'order_payment',
            orderId: Value(oid),
            createdAt: Value(at),
            lastUpdatedAt: Value(at),
          ),
        );
    final topUpId = UuidV7.generate();
    await db
        .into(db.walletTransactions)
        .insert(
          WalletTransactionsCompanion.insert(
            id: Value(topUpId),
            businessId: b,
            walletId: walletId,
            customerId: linkedCustomerId,
            type: 'credit',
            amountKobo: 10000,
            signedAmountKobo: 10000,
            referenceType: 'topup_cash',
            createdAt: Value(at),
            lastUpdatedAt: Value(at),
          ),
        );
  });

  tearDown(() async {
    debugOverrideVanSalesEnabled(null);
    debugOverrideDriverScreensEnabled(null);
    await env.dispose();
  });

  testWidgets('unlinked driver: no bring-in button; old sales are not shown', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      env: env,
      size: pixel7Portrait,
      screen: DriverProfileScreen(vanDriverId: driverId, initialTab: 'sales'),
      grantedKeys: grants,
      settle: false,
    );
    await settleFrames(tester);
    expect(find.byKey(const Key('driver-bring-in-old-account')), findsNothing);
    expect(find.text('Bring in old customer account'), findsNothing);
    expect(find.text('ORD-OLD-1'), findsNothing);
    await disposeScreen(tester);
  });

  testWidgets(
    'linked driver: Sales tab lists the old sale, tagged; no action',
    (tester) async {
      await tester.runAsync(
        () => env.db.vanDriversDao.linkOldCustomerAccount(
          vanDriverId: driverId,
          customerId: linkedCustomerId,
        ),
      );
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        screen: DriverProfileScreen(vanDriverId: driverId, initialTab: 'sales'),
        grantedKeys: grants,
        settle: false,
      );
      await settleFrames(tester);
      expect(find.text('ORD-OLD-1'), findsOneWidget);
      expect(find.textContaining('Old customer account'), findsWidgets);
      expect(
        find.byKey(const Key('driver-bring-in-old-account')),
        findsNothing,
      );
      await disposeScreen(tester);
    },
  );

  testWidgets('linked driver: Ledger tab lists the old payment and the moved '
      'debt, balance is the driver ledger only', (tester) async {
    // Owes 60,000 - 10,000 = 50,000 on the old account.
    final moved = await tester.runAsync(
      () => env.db.vanDriversDao.linkOldCustomerAccount(
        vanDriverId: driverId,
        customerId: linkedCustomerId,
      ),
    );
    expect(moved, 50000);
    await pumpScreen(
      tester,
      env: env,
      // Tall, so every row of the short ledger is built.
      size: const Size(412, 2000),
      screen: DriverProfileScreen(vanDriverId: driverId, initialTab: 'ledger'),
      grantedKeys: grants,
      settle: false,
    );
    await settleFrames(tester);
    expect(find.text('Payment received (Cash)'), findsOneWidget);
    // The move also shows on the old account's side, as an adjustment.
    expect(find.text('Account adjustment'), findsOneWidget);
    expect(find.textContaining('Old customer account'), findsWidgets);
    expect(find.text('Moved from the old customer account'), findsOneWidget);
    // The balance is the driver ledger alone: 50,000 once, not 100,000.
    expect(
      await tester.runAsync(
        () => env.db.driverLedgerDao.getBalanceKobo(driverId),
      ),
      -50000,
    );
    await disposeScreen(tester);
  });

  testWidgets('the customer page says it is now a van driver', (tester) async {
    await tester.runAsync(
      () => env.db.vanDriversDao.linkOldCustomerAccount(
        vanDriverId: driverId,
        customerId: linkedCustomerId,
      ),
    );
    final data = (await tester.runAsync(
      () => (env.db.select(
        env.db.customers,
      )..where((c) => c.id.equals(linkedCustomerId))).getSingle(),
    ))!;
    await pumpScreen(
      tester,
      env: env,
      size: pixel7Portrait,
      screen: CustomerDetailScreen(customer: Customer.fromDb(data)),
      grantedKeys: grants,
      settle: false,
    );
    await settleFrames(tester);
    expect(find.text('Now a van driver: Johnson Kim'), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('a linked customer is absent from the sale customer feed', (
    tester,
  ) async {
    await tester.runAsync(
      () => env.db.vanDriversDao.linkOldCustomerAccount(
        vanDriverId: driverId,
        customerId: linkedCustomerId,
      ),
    );
    late BuildContext ctx;
    await pumpScreen(
      tester,
      env: env,
      size: pixel7Portrait,
      screen: Builder(
        builder: (c) {
          ctx = c;
          return const SizedBox();
        },
      ),
      grantedKeys: grants,
      settle: false,
    );
    final container = ProviderScope.containerOf(ctx);
    final ids = await tester.runAsync(
      () => container.read(linkedCustomerIdsProvider.future),
    );
    expect(ids, contains(linkedCustomerId));
    expect(ids, isNot(contains(freeCustomerId)));
    await disposeScreen(tester);
  });
}
