import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/customers/screens/customer_detail_screen.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

/// Issue #767 — leaving Customer Details while its history load is still
/// running must not throw `Cannot use "ref" after the widget was disposed`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;
  late CustomerData customerData;

  setUp(() async {
    env = await setupScreenTestEnvironment();
    final db = env.db;
    final b = env.businessId;
    final cId = UuidV7.generate();
    await db.into(db.customers).insert(
          CustomersCompanion.insert(
            id: Value(cId),
            businessId: b,
            name: 'John Doe',
            phone: const Value('08012345678'),
            priceTier: const Value('retailer'),
          ),
        );
    customerData = await (db.select(db.customers)..where((t) => t.id.equals(cId)))
        .getSingle();
    final walletId = UuidV7.generate();
    await db.into(db.customerWallets).insert(
          CustomerWalletsCompanion.insert(
            id: Value(walletId),
            businessId: b,
            customerId: cId,
          ),
        );
    final orderId = UuidV7.generate();
    await db.into(db.orders).insert(
          OrdersCompanion.insert(
            id: Value(orderId),
            businessId: b,
            orderNumber: 'ORD-000001',
            customerId: Value(cId),
            totalAmountKobo: 50000,
            netAmountKobo: 50000,
            amountPaidKobo: const Value(50000),
            paymentType: 'cash',
            status: 'completed',
            storeId: Value(env.storeId),
          ),
        );
    // A refund row makes the history listener start _loadReversalOrderNumbers.
    await db.into(db.walletTransactions).insert(
          WalletTransactionsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: b,
            walletId: walletId,
            customerId: cId,
            type: 'debit',
            amountKobo: 50000,
            signedAmountKobo: -50000,
            referenceType: 'refund',
            orderId: Value(orderId),
          ),
        );
  });

  tearDown(() async {
    await env.dispose();
  });

  testWidgets('closing the screen mid-load throws nothing', (tester) async {
    await pumpScreen(
      tester,
      env: env,
      size: pixel7Portrait,
      screen: CustomerDetailScreen(customer: Customer.fromDb(customerData)),
      grantedKeys: const {'customers.update'},
      roleRank: GateTier.ceo,
      settle: false,
    );

    // Let the post-frame _loadData subscribe and the first history event land
    // (the reversal lookup is now awaiting), then close the screen at once.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
    await disposeScreen(tester);

    // Let the in-flight queries finish after disposal.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump(const Duration(milliseconds: 250));

    expect(tester.takeException(), isNull);
  });
}
