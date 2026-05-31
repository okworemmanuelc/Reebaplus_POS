import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

class WalletService {
  final AppDatabase _db;

  WalletService(this._db);

  WalletTransactionsDao get _walletTxDao => _db.walletTransactionsDao;
  CustomerWalletsDao get _customerWalletsDao => _db.customerWalletsDao;

  /// Top up a customer's wallet.
  ///
  /// Creates a WalletTransaction (credit) and a corresponding PaymentTransaction
  /// (wallet_topup). When [fundsAccountId] + [storeId] + [businessDate] are
  /// supplied, the cash/transfer also lands in that Funds Register account
  /// (§18 Add Funds / coding rule 5) — atomically, in the same transaction.
  Future<void> topup({
    required String customerId,
    required int amountKobo,
    required String method, // 'cash' or 'transfer'
    required String staffId,
    String? fundsAccountId,
    String? storeId,
    String? businessDate,
  }) async {
    final businessId = _walletTxDao.requireBusinessId();
    final wallet = await _customerWalletsDao.getByCustomerId(customerId);

    if (wallet == null) {
      throw StateError('Customer $customerId has no wallet');
    }

    final flagValue =
        await _db.systemConfigDao.get('feature.domain_rpcs_v2.wallet_topup');
    final useDomainRpc = flagValue == 'true' || flagValue == '"true"';

    final referenceType = method == 'cash' ? 'topup_cash' : 'topup_transfer';

    await _db.transaction(() async {
      final walletTxnId = UuidV7.generate();
      final paymentTxnId = UuidV7.generate();

      final walletComp = WalletTransactionsCompanion.insert(
        id: Value(walletTxnId),
        businessId: businessId,
        walletId: wallet.id,
        customerId: customerId,
        type: 'credit',
        amountKobo: amountKobo,
        signedAmountKobo: amountKobo,
        referenceType: referenceType,
        performedBy: Value(staffId),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await _db.into(_db.walletTransactions).insert(walletComp);

      final paymentComp = PaymentTransactionsCompanion.insert(
        id: Value(paymentTxnId),
        businessId: businessId,
        amountKobo: amountKobo,
        method: method,
        type: 'wallet_topup',
        walletTxnId: Value(walletTxnId),
        performedBy: Value(staffId),
        lastUpdatedAt: Value(DateTime.now()),
      );
      await _db.into(_db.paymentTransactions).insert(paymentComp);

      if (useDomainRpc) {
        // V2 path: the server's pos_wallet_topup RPC must mint the
        // fund_transactions credit itself (same R2 caveat as pos_record_sale_v2
        // — see OrdersDao.createOrder). The flag defaults false in Phase 1.
        final payload = <String, dynamic>{
          'p_business_id': businessId,
          'p_actor_id': staffId,
          'p_wallet_txn_id': walletTxnId,
          'p_payment_id': paymentTxnId,
          'p_customer_id': customerId,
          'p_amount_kobo': amountKobo,
          'p_method': method,
          'p_reference_type': referenceType,
        };
        await _db.syncDao
            .enqueue('domain:pos_wallet_topup', jsonEncode(payload));
      } else {
        await _db.syncDao.enqueueUpsert('wallet_transactions', walletComp);
        await _db.syncDao.enqueueUpsert('payment_transactions', paymentComp);

        // The money physically entered a Funds Register account — credit it so
        // the daily expected balance stays accurate (§23 / coding rule 5).
        if (fundsAccountId != null &&
            storeId != null &&
            businessDate != null) {
          await _db.fundTransactionsDao.creditTopup(
            fundsAccountId: fundsAccountId,
            storeId: storeId,
            businessDate: businessDate,
            amountKobo: amountKobo,
            paymentId: paymentTxnId,
            performedBy: staffId,
          );
        }
      }
    });
  }

  /// Refunds any wallet debit associated with an order.
  /// 
  /// Appends a new credit transaction. The original debit remains untouched.
  Future<void> refundOrderWalletDebit({
    required String orderId,
    required String staffId,
  }) async {
    final businessId = _walletTxDao.requireBusinessId();

    // Find the original wallet debit for this order
    final originalDebit = await (_db.select(_db.walletTransactions)
          ..where(
            (t) =>
                t.businessId.equals(businessId) &
                t.orderId.equals(orderId) &
                t.type.equals('debit'),
          )
          ..limit(1))
        .getSingleOrNull();

    if (originalDebit == null) return;

    final refundId = UuidV7.generate();
    final refundComp = WalletTransactionsCompanion.insert(
      id: Value(refundId),
      businessId: businessId,
      walletId: originalDebit.walletId,
      customerId: originalDebit.customerId,
      type: 'credit',
      amountKobo: originalDebit.amountKobo,
      signedAmountKobo: originalDebit.amountKobo,
      referenceType: 'refund',
      orderId: Value(orderId),
      performedBy: Value(staffId),
      lastUpdatedAt: Value(DateTime.now()),
    );
    await _db.into(_db.walletTransactions).insert(refundComp);
    await _db.syncDao.enqueueUpsert('wallet_transactions', refundComp);
  }

  /// Calculates the current balance for a customer.
  Future<int> getBalanceKobo(String customerId) => _walletTxDao.getBalanceKobo(customerId);

  /// Watches the current balance for a customer.
  Stream<int> watchBalanceKobo(String customerId) => _walletTxDao.watchBalanceKobo(customerId);

  /// Voids a wallet transaction using a compensating entry.
  Future<void> voidTransaction({
    required String transactionId,
    required String voidedBy,
    required String reason,
  }) => _walletTxDao.voidTransaction(
    transactionId: transactionId,
    voidedBy: voidedBy,
    reason: reason,
  );
}
