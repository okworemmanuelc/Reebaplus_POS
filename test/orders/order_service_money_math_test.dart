// order_service_money_math_test.dart
//
// Ring 0 #3 — money-math consistency regression net (PIVOT_PLAN §8.0 line 554).
//
// OrderService.addOrder is the production cart entry point and had ZERO test
// coverage. These tests lock in:
//   • _resolvePaymentType classification: cash / mixed / credit / wallet
//   • the full wallet ledger (§14.3, rule #4): every registered sale posts a
//     debit for the order total + a credit for the amount paid, netting to
//     paid − total (0 when fully paid, negative = the customer owes)
//   • the Funds Register credit (hard rule #5): a paid sale credits the named
//     account by the cash portion; wallet/credit sales credit nothing
//   • getBalanceFor == SUM(signed_amount_kobo) after layering opening + sale
//   • refund (markCancelled) reverses BOTH wallet legs and dates the Funds
//     void-debit to the refund day, not the original sale day (§19.7/§23.5)
//
// Asserted through addOrder (not the private methods) so the real persisted
// rows — orders.payment_type, payment_transactions, wallet_transactions,
// fund_transactions — are the source of truth. No SupabaseSyncService is wired,
// so addOrder runs fully offline on the v1 (flag-OFF) local-mirror path.

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/shared/services/order_service.dart';

import '../helpers/dispatch_test_utils.dart';

class _Seed {
  final String businessId;
  final String storeId;
  final String staffId;
  final String productId;
  final String customerId;
  final String tillId;
  _Seed({
    required this.businessId,
    required this.storeId,
    required this.staffId,
    required this.productId,
    required this.customerId,
    required this.tillId,
  });
}

void main() {
  late AppDatabase db;
  late OrderService service;
  late _Seed s;
  const date = '2026-06-01';

  // Each beer is ₦1,000 = 100,000 kobo. A 2-unit cart totals 200,000 kobo.
  const unitPriceKobo = 100000;

  Future<_Seed> seed() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    final businessId = boot.businessId;

    final storeId = UuidV7.generate();
    await db.into(db.stores).insert(
          StoresCompanion.insert(
            id: Value(storeId),
            businessId: businessId,
            name: 'Main',
          ),
        );

    final staffId = UuidV7.generate();
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: Value(staffId),
            businessId: businessId,
            name: 'Cashier',
            pin: '0000',
          ),
        );

    final productId = UuidV7.generate();
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: Value(productId),
            businessId: businessId,
            name: 'Test Beer',
            retailerPriceKobo: const Value(unitPriceKobo),
          ),
        );
    await db.into(db.inventory).insert(
          InventoryCompanion.insert(
            businessId: businessId,
            productId: productId,
            storeId: storeId,
            quantity: const Value(50),
          ),
        );

    final customerId = await db.customersDao.addCustomer(
      CustomersCompanion.insert(businessId: businessId, name: 'Buyer'),
    );

    final till = await db.fundsAccountsDao.ensureCashTill(storeId);

    return _Seed(
      businessId: businessId,
      storeId: storeId,
      staffId: staffId,
      productId: productId,
      customerId: customerId,
      tillId: till.id,
    );
  }

  // A 2-unit cart for [s.productId] at unitPriceKobo → total 200,000 kobo.
  List<Map<String, dynamic>> twoUnitCart() => [
        {
          'id': s.productId,
          'name': 'Test Beer',
          'qty': 2,
          'unitPriceKobo': unitPriceKobo,
          'buyingPriceKobo': 60000,
        },
      ];

  Future<OrderData> onlyOrder() => db.select(db.orders).getSingle();
  Future<List<PaymentTransactionData>> payments() =>
      db.select(db.paymentTransactions).get();
  Future<List<WalletTransactionData>> walletTxns() =>
      db.select(db.walletTransactions).get();
  Future<List<FundTransactionData>> fundTxns() =>
      db.select(db.fundTransactions).get();

  setUp(() async {
    s = await seed();
    service = OrderService(db); // no sync service → offline v1 path
  });

  tearDown(() => db.close());

  group('OrderService.addOrder — payment classification + money math', () {
    test(
        'fully-paid registered cash sale: paymentType "cash", ZERO wallet rows, '
        'funds credit == total (net-zero wallet)', () async {
      await service.addOrder(
        customerId: s.customerId,
        cart: twoUnitCart(),
        totalAmountKobo: 200000,
        amountPaidKobo: 200000,
        paymentType: 'cash',
        paymentSubType: 'cash',
        staffId: s.staffId,
        storeId: s.storeId,
        fundsAccountId: s.tillId,
        businessDate: date,
      );

      final order = await onlyOrder();
      expect(order.paymentType, 'cash');

      // §14.3 full ledger: a fully-paid sale runs through the wallet as two
      // legs — debit the order total, credit the amount paid — netting to zero.
      final wallet = await walletTxns();
      expect(wallet, hasLength(2), reason: 'debit total + credit paid');
      expect(
        wallet.where((w) => w.type == 'debit').single.signedAmountKobo,
        -200000,
      );
      expect(
        wallet.where((w) => w.type == 'credit').single.signedAmountKobo,
        200000,
      );
      expect(
        wallet.fold<int>(0, (sum, w) => sum + w.signedAmountKobo),
        0,
        reason: 'fully paid → net-zero wallet effect',
      );

      final pays = await payments();
      expect(pays, hasLength(1));
      expect(pays.first.amountKobo, 200000);
      expect(pays.first.method, 'cash');

      // The whole ₦2,000 lands in the Cash Till.
      final funds = await fundTxns();
      expect(funds.where((f) => f.referenceType == 'sale'), hasLength(1));
      expect(
        await db.fundTransactionsDao.getBalanceFor(s.tillId, date),
        200000,
      );
    });

    test(
        'partial payment: paymentType "mixed", wallet debit == total − paid, '
        'funds credit == paid', () async {
      await service.addOrder(
        customerId: s.customerId,
        cart: twoUnitCart(),
        totalAmountKobo: 200000,
        amountPaidKobo: 120000, // ₦1,200 of ₦2,000
        paymentType: 'cash',
        paymentSubType: 'cash',
        staffId: s.staffId,
        storeId: s.storeId,
        fundsAccountId: s.tillId,
        businessDate: date,
      );

      final order = await onlyOrder();
      expect(order.paymentType, 'mixed');

      // §14.3 full ledger: debit the order total, credit the cash paid. The net
      // is −(total − paid) = the residual the customer now owes on the wallet.
      final wallet = await walletTxns();
      expect(wallet, hasLength(2));
      expect(
        wallet.where((w) => w.type == 'debit').single.signedAmountKobo,
        -200000,
      );
      expect(
        wallet.where((w) => w.type == 'credit').single.signedAmountKobo,
        120000,
      );
      expect(
        wallet.fold<int>(0, (sum, w) => sum + w.signedAmountKobo),
        -80000,
        reason: 'net wallet == −(total − paid) == −80000',
      );
      expect(wallet.first.customerId, s.customerId);

      // Only the cash portion hits the Funds Register.
      final pays = await payments();
      expect(pays, hasLength(1));
      expect(pays.first.amountKobo, 120000);
      expect(
        await db.fundTransactionsDao.getBalanceFor(s.tillId, date),
        120000,
      );
    });

    test(
        '§14.3 ordering (bug #3): the payment credit shows BEFORE the order '
        'debit in wallet history', () async {
      await service.addOrder(
        customerId: s.customerId,
        cart: twoUnitCart(),
        totalAmountKobo: 200000,
        amountPaidKobo: 120000, // partial → both legs present
        paymentType: 'cash',
        paymentSubType: 'cash',
        staffId: s.staffId,
        storeId: s.storeId,
        fundsAccountId: s.tillId,
        businessDate: date,
      );

      // watchHistory drives the customer-wallet display order — newest activity
      // first. The order charge (debit) is the last step of the sale, so it
      // sits at the TOP, with the payment (credit) below it.
      final hist =
          await db.walletTransactionsDao.watchHistory(s.customerId).first;
      expect(hist, hasLength(2));
      expect(
        hist.first.type,
        'debit',
        reason: 'the order charge (debit) is the most-recent activity and must '
            'sit at the top of the newest-first wallet history — §14.3',
      );
      final debitIdx = hist.indexWhere((w) => w.type == 'debit');
      final creditIdx = hist.indexWhere((w) => w.type == 'credit');
      expect(debitIdx, lessThan(creditIdx));
    });

    test(
        'credit sale (paid 0, subType cash): paymentType "credit", '
        'wallet debit == total, NO payment row, NO funds credit', () async {
      await service.addOrder(
        customerId: s.customerId,
        cart: twoUnitCart(),
        totalAmountKobo: 200000,
        amountPaidKobo: 0,
        paymentType: 'credit',
        paymentSubType: 'cash',
        staffId: s.staffId,
        storeId: s.storeId,
        // No fundsAccountId / businessDate — nothing is paid, so none required.
      );

      final order = await onlyOrder();
      expect(order.paymentType, 'credit');

      final wallet = await walletTxns();
      expect(wallet, hasLength(1));
      expect(wallet.first.signedAmountKobo, -200000,
          reason: 'the full total goes on account');

      expect(await payments(), isEmpty, reason: 'no money arrived');
      expect(await fundTxns(), isEmpty, reason: 'no funds credit on a credit sale');
    });

    test(
        'wallet sale (subType wallet, paid 0): paymentType "wallet", '
        'wallet debit == total, NO payment row', () async {
      // A wallet sale draws the full total from the customer's existing wallet
      // balance — the money was banked at top-up time, so the sale itself
      // credits no Funds account now.
      await service.addOrder(
        customerId: s.customerId,
        cart: twoUnitCart(),
        totalAmountKobo: 200000,
        amountPaidKobo: 0,
        paymentType: 'wallet',
        paymentSubType: 'wallet',
        staffId: s.staffId,
        storeId: s.storeId,
      );

      final order = await onlyOrder();
      expect(order.paymentType, 'wallet');

      final wallet = await walletTxns();
      expect(wallet, hasLength(1));
      expect(wallet.first.type, 'debit');
      expect(wallet.first.signedAmountKobo, -200000);

      expect(await payments(), isEmpty);
      expect(await fundTxns(), isEmpty);
    });
  });

  group('OrderService.addOrder — money-invariant guards (hard rule #5/#14)', () {
    test('a paid sale with no funds account throws (money must land somewhere)',
        () async {
      expect(
        () => service.addOrder(
          customerId: s.customerId,
          cart: twoUnitCart(),
          totalAmountKobo: 200000,
          amountPaidKobo: 200000,
          paymentType: 'cash',
          paymentSubType: 'cash',
          staffId: s.staffId,
          storeId: s.storeId,
          businessDate: date,
          // fundsAccountId omitted
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a paid sale with no businessDate throws (credit would be unbucketed)',
        () async {
      expect(
        () => service.addOrder(
          customerId: s.customerId,
          cart: twoUnitCart(),
          totalAmountKobo: 200000,
          amountPaidKobo: 200000,
          paymentType: 'cash',
          paymentSubType: 'cash',
          staffId: s.staffId,
          storeId: s.storeId,
          fundsAccountId: s.tillId,
          // businessDate omitted
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a wallet/credit/partial sale with no customer throws', () async {
      // walletDebit > 0 but customerId is null → can't debt a walk-in (#14).
      expect(
        () => service.addOrder(
          customerId: null,
          cart: twoUnitCart(),
          totalAmountKobo: 200000,
          amountPaidKobo: 0,
          paymentType: 'credit',
          paymentSubType: 'cash',
          staffId: s.staffId,
          storeId: s.storeId,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('Funds Register — expected balance == SUM(signed_amount_kobo)', () {
    test('opening credit + sale credit layer into getBalanceFor', () async {
      // 1. Open the day with ₦5,000 opening cash in the till.
      await db.fundDaysDao.openDay(
        storeId: s.storeId,
        businessDate: date,
        perAccountOpeningKobo: {s.tillId: 500000},
        performedBy: s.staffId,
      );
      expect(
        await db.fundTransactionsDao.getBalanceFor(s.tillId, date),
        500000,
        reason: 'just the opening credit so far',
      );

      // 2. A fully-paid ₦2,000 cash sale credits the till.
      await service.addOrder(
        customerId: s.customerId,
        cart: twoUnitCart(),
        totalAmountKobo: 200000,
        amountPaidKobo: 200000,
        paymentType: 'cash',
        paymentSubType: 'cash',
        staffId: s.staffId,
        storeId: s.storeId,
        fundsAccountId: s.tillId,
        businessDate: date,
      );

      // 3. getBalanceFor == opening + sale == 700,000, and it must equal the
      //    raw SUM(signed_amount_kobo) over the same account/day — the ledger
      //    sum is the single source of truth for the expected balance.
      final balance =
          await db.fundTransactionsDao.getBalanceFor(s.tillId, date);
      expect(balance, 700000);

      final rawSum = (await fundTxns())
          .where((t) => t.fundsAccountId == s.tillId && t.businessDate == date)
          .fold<int>(0, (sum, t) => sum + t.signedAmountKobo);
      expect(balance, rawSum,
          reason: 'getBalanceFor must equal SUM(signed_amount_kobo)');
    });
  });

  group('Cancel/Refund reverses the Funds Register credit (§19.7 / Ring 0 #5)',
      () {
    test('a void debit returns the account to its pre-sale balance', () async {
      await service.addOrder(
        customerId: s.customerId,
        cart: twoUnitCart(),
        totalAmountKobo: 200000,
        amountPaidKobo: 200000,
        paymentType: 'cash',
        paymentSubType: 'cash',
        staffId: s.staffId,
        storeId: s.storeId,
        fundsAccountId: s.tillId,
        businessDate: date,
      );
      final order = await onlyOrder();
      expect(await db.fundTransactionsDao.getBalanceFor(s.tillId, date), 200000);

      await service.markAsCancelled(order.id, 'customer refund', s.staffId,
          businessDate: date);

      // A compensating 'void' debit was appended (ledger is append-only) and
      // the account balance is back to pre-sale.
      final voids =
          (await fundTxns()).where((f) => f.referenceType == 'void').toList();
      expect(voids, hasLength(1));
      expect(voids.first.type, 'debit');
      expect(voids.first.signedAmountKobo, -200000);
      expect(await db.fundTransactionsDao.getBalanceFor(s.tillId, date), 0);

      expect((await onlyOrder()).status, 'cancelled');
    });

    test('partial sale: wallet refunded AND the funds credit reversed',
        () async {
      await service.addOrder(
        customerId: s.customerId,
        cart: twoUnitCart(),
        totalAmountKobo: 200000,
        amountPaidKobo: 120000, // cash portion → funds; ₦800 residual → wallet
        paymentType: 'cash',
        paymentSubType: 'cash',
        staffId: s.staffId,
        storeId: s.storeId,
        fundsAccountId: s.tillId,
        businessDate: date,
      );
      final order = await onlyOrder();
      expect(await db.fundTransactionsDao.getBalanceFor(s.tillId, date), 120000);

      await service.markAsCancelled(order.id, 'refund', s.staffId,
          businessDate: date);

      // Funds credit reversed to 0.
      expect(await db.fundTransactionsDao.getBalanceFor(s.tillId, date), 0);

      // Both wallet legs are reversed (§14.3): the order-total debit becomes a
      // 'refund' credit (+200000); the payment credit becomes a 'void' debit
      // (−120000). Net = +80000, undoing the sale's −80000 → wallet back to its
      // pre-sale balance.
      final wallet = await walletTxns();
      expect(
        wallet.where((w) => w.referenceType == 'refund').single.signedAmountKobo,
        200000,
      );
      expect(
        wallet.where((w) => w.referenceType == 'void').single.signedAmountKobo,
        -120000,
      );
      expect(
        wallet.fold<int>(0, (sum, w) => sum + w.signedAmountKobo),
        0,
        reason: 'customer wallet returns to its pre-sale balance',
      );
    });

    test('credit/wallet sale (no funds credit): nothing to void', () async {
      await service.addOrder(
        customerId: s.customerId,
        cart: twoUnitCart(),
        totalAmountKobo: 200000,
        amountPaidKobo: 0,
        paymentType: 'credit',
        paymentSubType: 'cash',
        staffId: s.staffId,
        storeId: s.storeId,
      );
      final order = await onlyOrder();

      await service.markAsCancelled(order.id, 'refund', s.staffId,
          businessDate: date);

      // No 'sale' funds credit existed, so no 'void' debit is appended.
      expect(
        (await fundTxns()).where((f) => f.referenceType == 'void'),
        isEmpty,
      );
      // The wallet's order-total debit is reversed by a 'refund' credit, so the
      // customer's wallet returns to its pre-sale balance.
      final wallet = await walletTxns();
      expect(
        wallet.where((w) => w.referenceType == 'refund').single.signedAmountKobo,
        200000,
      );
      expect(wallet.fold<int>(0, (sum, w) => sum + w.signedAmountKobo), 0);
    });

    test(
        'the void debit is dated to the refund day, not the sale day '
        '(§19.7 / §23.5)', () async {
      await service.addOrder(
        customerId: s.customerId,
        cart: twoUnitCart(),
        totalAmountKobo: 200000,
        amountPaidKobo: 200000,
        paymentType: 'cash',
        paymentSubType: 'cash',
        staffId: s.staffId,
        storeId: s.storeId,
        fundsAccountId: s.tillId,
        businessDate: date, // sale day
      );
      final order = await onlyOrder();

      const refundDay = '2026-06-02'; // a later day — the cash leaves "today"
      await service.markAsCancelled(order.id, 'next-day refund', s.staffId,
          businessDate: refundDay);

      // The void lands on the refund day, carrying the −200000 cash-out there.
      final voids =
          (await fundTxns()).where((f) => f.referenceType == 'void').toList();
      expect(voids, hasLength(1));
      expect(voids.first.businessDate, refundDay);
      expect(voids.first.signedAmountKobo, -200000);

      // The sale day still shows the full credit (its close is never reopened);
      // the refund day carries the cash-out.
      expect(await db.fundTransactionsDao.getBalanceFor(s.tillId, date), 200000);
      expect(
        await db.fundTransactionsDao.getBalanceFor(s.tillId, refundDay),
        -200000,
      );
    });
  });

  group('Lifecycle — checkout creates Pending; Confirm completes (§19.5)', () {
    test(
        'a completed checkout lands the order in Pending, completedAt null',
        () async {
      await service.addOrder(
        customerId: s.customerId,
        cart: twoUnitCart(),
        totalAmountKobo: 200000,
        amountPaidKobo: 200000,
        paymentType: 'cash',
        paymentSubType: 'cash',
        staffId: s.staffId,
        storeId: s.storeId,
        fundsAccountId: s.tillId,
        businessDate: date,
      );

      final order = await onlyOrder();
      expect(order.status, 'pending',
          reason: 'checkout creates a Pending order; Confirm completes it');
      expect(order.completedAt, isNull,
          reason: 'completedAt is stamped at Confirm, not checkout');

      // Revenue/money is booked at checkout regardless of status.
      expect(await db.fundTransactionsDao.getBalanceFor(s.tillId, date), 200000);
    });

    test(
        'Confirm (markAsCompleted) flips Pending → Completed and stamps '
        'completedAt', () async {
      await service.addOrder(
        customerId: s.customerId,
        cart: twoUnitCart(),
        totalAmountKobo: 200000,
        amountPaidKobo: 200000,
        paymentType: 'cash',
        paymentSubType: 'cash',
        staffId: s.staffId,
        storeId: s.storeId,
        fundsAccountId: s.tillId,
        businessDate: date,
      );

      final pending = await onlyOrder();
      await service.markAsCompleted(pending.id, s.staffId);

      final completed = await onlyOrder();
      expect(completed.status, 'completed');
      expect(completed.completedAt, isNotNull);
    });
  });
}
