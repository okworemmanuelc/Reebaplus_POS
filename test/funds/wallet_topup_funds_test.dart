import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/shared/services/wallet_service.dart';

import '../helpers/dispatch_test_utils.dart';

/// §18 Add Funds → Funds Register. A wallet top-up credits the chosen funds
/// account (coding rule 5) atomically with the wallet + payment ledger rows,
/// and the new 'topup' fund_transactions.reference_type (schema v23) is
/// accepted by the CHECK constraint on a fresh onCreate DB.
void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId;
  late String userId;
  late String customerId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    storeId = UuidV7.generate();
    await db.into(db.stores).insert(
          StoresCompanion.insert(
            id: Value(storeId),
            businessId: businessId,
            name: 'Main Store',
          ),
        );
    userId = UuidV7.generate();
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: Value(userId),
            businessId: businessId,
            name: 'Tester',
            pin: '0000',
          ),
        );
    customerId = await db.customersDao.addCustomer(
      CustomersCompanion.insert(
        businessId: businessId,
        name: 'Alice',
        storeId: Value(storeId),
      ),
    );
  });

  tearDown(() => db.close());

  test('cash top-up credits the Cash Till + appends a topup fund_transaction',
      () async {
    final till = await db.fundsAccountsDao.ensureCashTill(storeId);
    const date = '2026-05-30';

    await WalletService(db).topup(
      customerId: customerId,
      amountKobo: 500000,
      method: 'cash',
      staffId: userId,
      fundsAccountId: till.id,
      storeId: storeId,
      businessDate: date,
    );

    // Wallet credited.
    expect(await db.walletTransactionsDao.getBalanceKobo(customerId), 500000);
    // Funds Register: the chosen Cash Till reflects the cash that came in.
    expect(await db.fundTransactionsDao.getBalanceFor(till.id, date), 500000);
    // The fund row is a 'topup' credit (proves schema v23 accepts it) and the
    // actor is recorded.
    final topup = (await db.select(db.fundTransactions).get())
        .singleWhere((t) => t.referenceType == 'topup');
    expect(topup.type, 'credit');
    expect(topup.fundsAccountId, till.id);
    expect(topup.performedBy, userId);
    // A wallet_topup payment row was written.
    final payments = await db.select(db.paymentTransactions).get();
    expect(payments.where((p) => p.type == 'wallet_topup'), hasLength(1));
  });

  test('transfer top-up to a bank account credits that account only', () async {
    final till = await db.fundsAccountsDao.ensureCashTill(storeId);
    final bankId = await db.fundsAccountsDao.createAccount(
      storeId: storeId,
      accountType: 'bank',
      name: 'GTB Main',
    );
    const date = '2026-05-30';

    await WalletService(db).topup(
      customerId: customerId,
      amountKobo: 250000,
      method: 'transfer',
      staffId: userId,
      fundsAccountId: bankId,
      storeId: storeId,
      businessDate: date,
    );

    expect(await db.fundTransactionsDao.getBalanceFor(bankId, date), 250000);
    // Cash Till untouched — money landed in the chosen account only.
    expect(await db.fundTransactionsDao.getBalanceFor(till.id, date), 0);
  });

  test('top-up without a funds account still writes wallet + payment', () async {
    await WalletService(db).topup(
      customerId: customerId,
      amountKobo: 100000,
      method: 'cash',
      staffId: userId,
    );
    expect(await db.walletTransactionsDao.getBalanceKobo(customerId), 100000);
    final funds = await db.select(db.fundTransactions).get();
    expect(funds, isEmpty);
  });
}
