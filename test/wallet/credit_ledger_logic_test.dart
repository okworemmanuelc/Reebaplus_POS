import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/shared/services/credit_ledger_service.dart';

void main() {
  late AppDatabase db;
  late CreditLedgerService creditLedgerService;
  late String businessId;
  late String customerId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    creditLedgerService = CreditLedgerService(db);
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
    await creditLedgerService.topup(
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
    await creditLedgerService.topup(
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
    await creditLedgerService.topup(
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
    await creditLedgerService.voidTransaction(
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

  // §18.3 Refund Cash — pay the customer back, in cash, money the business holds
  // for them (held crate deposit and/or positive spendable credit).
  group('refundCash (§18.3 credit balance cash refund)', () {
    // Posts a raw wallet row (to set up held deposit / debt without a full sale).
    Future<void> postRaw(int signed, String type, String refType) async {
      final wallet = await db.customerWalletsDao.getByCustomerId(customerId);
      await db.into(db.walletTransactions).insert(
            WalletTransactionsCompanion.insert(
              businessId: businessId,
              walletId: wallet!.id,
              customerId: customerId,
              type: type,
              amountKobo: signed.abs(),
              signedAmountKobo: signed,
              referenceType: refType,
            ),
          );
    }

    Future<int> paymentRowCount() async =>
        (await db.select(db.paymentTransactions).get()).length;

    test('refunds a HELD deposit → held nets to 0, spendable unchanged', () async {
      await postRaw(250000, 'credit', 'crate_deposit'); // held 250000
      expect(await db.walletTransactionsDao.getDepositsHeldKobo(customerId),
          250000);

      final refunded = await creditLedgerService.refundCash(
        customerId: customerId,
        amountKobo: 250000,
        method: 'cash',
        staffId: 'staff1',
      );

      expect(refunded, 250000);
      expect(await db.walletTransactionsDao.getDepositsHeldKobo(customerId), 0,
          reason: 'crate_deposit_refunded debit clears held');
      expect(await db.walletTransactionsDao.getBalanceKobo(customerId), 0,
          reason: 'deposit refund never touches spendable');
      expect(await paymentRowCount(), 1, reason: 'one cash refund payment row');
      final pay = await db.select(db.paymentTransactions).getSingle();
      expect(pay.type, 'refund');
      expect(pay.method, 'cash');
      expect(pay.amountKobo, 250000);
    });

    test('refunds spendable CREDIT → spendable drops, held unchanged', () async {
      await creditLedgerService.topup(
        customerId: customerId,
        amountKobo: 5000,
        method: 'cash',
        staffId: 'staff1',
      );

      final refunded = await creditLedgerService.refundCash(
        customerId: customerId,
        amountKobo: 5000,
        method: 'transfer',
        staffId: 'staff1',
      );

      expect(refunded, 5000);
      expect(await db.walletTransactionsDao.getBalanceKobo(customerId), 0,
          reason: 'refund debit reduces spendable to 0');
      expect(await db.walletTransactionsDao.getDepositsHeldKobo(customerId), 0);
      final history =
          await db.walletTransactionsDao.watchHistory(customerId).first;
      expect(history.any((t) => t.referenceType == 'refund' && t.type == 'debit'),
          isTrue);
    });

    test('combined held + credit, full refund → both legs, both net to 0',
        () async {
      await postRaw(250000, 'credit', 'crate_deposit'); // held 250000
      await creditLedgerService.topup(
        customerId: customerId,
        amountKobo: 5000,
        method: 'cash',
        staffId: 'staff1',
      ); // spendable 5000

      final refunded = await creditLedgerService.refundCash(
        customerId: customerId,
        amountKobo: 255000,
        method: 'cash',
        staffId: 'staff1',
      );

      expect(refunded, 255000);
      expect(await db.walletTransactionsDao.getDepositsHeldKobo(customerId), 0);
      expect(await db.walletTransactionsDao.getBalanceKobo(customerId), 0);
      expect(await paymentRowCount(), 3,
          reason: '1 topup + 2 refund payment rows (deposit + credit)');
    });

    test('White Pages case: in debt → held deposit refunded TO CREDIT BALANCE (reduces '
        'debt), no cash', () async {
      await postRaw(-3010000, 'debit', 'order_payment'); // spendable -30,100.00
      await postRaw(1200000, 'credit', 'crate_deposit'); // held 12,000.00
      expect(await db.walletTransactionsDao.getBalanceKobo(customerId), -3010000);

      // Ask for far more than is available — caps at the held deposit, and
      // because the wallet is in debt it goes to the wallet (no cash option).
      final refunded = await creditLedgerService.refundCash(
        customerId: customerId,
        amountKobo: 99999999,
        method: 'cash', // ignored on the to-wallet path
        staffId: 'staff1',
      );

      expect(refunded, 1200000, reason: 'only the held deposit is refundable');
      expect(await db.walletTransactionsDao.getDepositsHeldKobo(customerId), 0,
          reason: 'held deposit released');
      // -30,100.00 + 12,000.00 = -18,100.00 — exactly the reconciled balance.
      expect(await db.walletTransactionsDao.getBalanceKobo(customerId), -1810000,
          reason: 'deposit credited to wallet reduces the debt');
      expect(await paymentRowCount(), 0,
          reason: 'in debt → refunded to wallet, no cash payment row');
      final history =
          await db.walletTransactionsDao.watchHistory(customerId).first;
      expect(
          history.any((t) => t.referenceType == 'crate_refund' && t.type == 'credit'),
          isTrue,
          reason: 'crate_refund credit is the to-wallet leg');
    });

    test('nothing to refund (pure debt) → returns 0, no rows written', () async {
      await postRaw(-5000, 'debit', 'order_payment');

      final refunded = await creditLedgerService.refundCash(
        customerId: customerId,
        amountKobo: 5000,
        method: 'cash',
        staffId: 'staff1',
      );

      expect(refunded, 0);
      expect(await paymentRowCount(), 0);
      expect(await db.walletTransactionsDao.getBalanceKobo(customerId), -5000);
    });
  });
}
