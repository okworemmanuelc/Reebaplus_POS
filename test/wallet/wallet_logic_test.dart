import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/shared/services/wallet_service.dart';

void main() {
  late AppDatabase db;
  late WalletService walletService;
  late String businessId;
  late String customerId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    walletService = WalletService(db);
    businessId = UuidV7.generate();
    db.businessIdResolver = () => businessId;

    await db.into(db.businesses).insert(BusinessesCompanion.insert(
          id: Value(businessId),
          name: 'Test Biz',
        ));

    // Create a staff user to satisfy FK constraints on performed_by/voided_by
    await db.into(db.users).insert(UsersCompanion.insert(
          id: const Value('staff1'),
          businessId: businessId,
          name: 'Staff One',
          role: 'ceo',
          pin: '1234',
        ));

    customerId = await db.customersDao.addCustomer(
      CustomersCompanion.insert(businessId: businessId, name: 'Alice'),
    );
  });

  tearDown(() => db.close());

  test('Balance with no transactions is 0', () async {
    final balance = await db.walletTransactionsDao.getBalanceKobo(customerId);
    expect(balance, equals(0));
  });

  test('Topup increases balance by amount', () async {
    await walletService.topup(
      customerId: customerId,
      amountKobo: 5000,
      method: 'cash',
      staffId: 'staff1',
    );

    final balance = await db.walletTransactionsDao.getBalanceKobo(customerId);
    expect(balance, equals(5000));

    // Verify payment transaction was created
    final payment = await db.select(db.paymentTransactions).getSingle();
    expect(payment.amountKobo, equals(5000));
    expect(payment.type, equals('wallet_topup'));
    expect(payment.walletTxnId, isNotNull);
  });

  test('Wallet debit on order creation decreases balance', () async {
    // 1. Topup first
    await walletService.topup(
      customerId: customerId,
      amountKobo: 10000,
      method: 'cash',
      staffId: 'staff1',
    );

    // 2. Create order with wallet debit
    final orderId = UuidV7.generate();
    await db.ordersDao.createOrder(
      order: OrdersCompanion.insert(
        id: Value(orderId),
        businessId: businessId,
        orderNumber: 'ORD-001',
        totalAmountKobo: 4000,
        netAmountKobo: 4000,
        paymentType: 'wallet',
        status: 'completed',
      ),
      items: [],
      customerId: customerId,
      amountPaidKobo: 0,
      totalAmountKobo: 4000,
      staffId: 'staff1',
      walletDebitKobo: 4000,
    );

    final balance = await db.walletTransactionsDao.getBalanceKobo(customerId);
    expect(balance, equals(6000));
  });

  test('Refund increases balance by amount', () async {
    // 1. Order with wallet debit
    final orderId = UuidV7.generate();
    await db.ordersDao.createOrder(
      order: OrdersCompanion.insert(
        id: Value(orderId),
        businessId: businessId,
        orderNumber: 'ORD-001',
        totalAmountKobo: 3000,
        netAmountKobo: 3000,
        paymentType: 'wallet',
        status: 'completed',
      ),
      items: [],
      customerId: customerId,
      amountPaidKobo: 0,
      totalAmountKobo: 3000,
      staffId: 'staff1',
      walletDebitKobo: 3000,
    );

    expect(await db.walletTransactionsDao.getBalanceKobo(customerId),
        equals(-3000));

    // 2. Cancel order which triggers refund
    await db.ordersDao.markCancelled(orderId, 'Customer changed mind', 'staff1');

    expect(await db.walletTransactionsDao.getBalanceKobo(customerId), equals(0));

    // Verify refund entry
    final history =
        await db.walletTransactionsDao.watchHistory(customerId).first;
    expect(history.any((t) => t.referenceType == 'refund'), isTrue);
  });

  test(
      'Voiding a transaction (via compensating entry) returns balance to pre-transaction state',
      () async {
    await walletService.topup(
      customerId: customerId,
      amountKobo: 5000,
      method: 'cash',
      staffId: 'staff1',
    );

    final history =
        await db.walletTransactionsDao.watchHistory(customerId).first;
    final topupTxId = history.first.id;

    expect(await db.walletTransactionsDao.getBalanceKobo(customerId),
        equals(5000));

    // Void it
    await walletService.voidTransaction(
      transactionId: topupTxId,
      voidedBy: 'staff1',
      reason: 'mistake',
    );

    // Balance should be back to 0
    expect(await db.walletTransactionsDao.getBalanceKobo(customerId), equals(0));

    // Check history
    final newHistory =
        await db.walletTransactionsDao.watchHistory(customerId).first;
    expect(newHistory.length, equals(2)); // Original + Compensating
    expect(newHistory.any((t) => t.referenceType == 'void'), isTrue);
    expect(newHistory.any((t) => t.voidedAt != null), isTrue);
  });

  test(
      'Balance ignores other businesses rows even with same customer (multi-tenant isolation)',
      () async {
    final businessId2 = UuidV7.generate();
    await db.into(db.businesses).insert(BusinessesCompanion.insert(
          id: Value(businessId2),
          name: 'Other Biz',
        ));

    // Get Alice's wallet ID from business 1 (but we'll just use a mock or create one for biz 2)
    final wallet = await db.customerWalletsDao.getByCustomerId(customerId);

    // Insert a transaction for the SAME customer ID but different business ID
    await db.into(db.walletTransactions).insert(
          WalletTransactionsCompanion.insert(
            businessId: businessId2,
            walletId: wallet!.id,
            customerId: customerId,
            type: 'credit',
            amountKobo: 100000,
            signedAmountKobo: 100000,
            referenceType: 'topup_cash',
          ),
        );

    // Current business balance should still be 0
    final balance = await db.walletTransactionsDao.getBalanceKobo(customerId);
    expect(balance, equals(0));
  });
}
