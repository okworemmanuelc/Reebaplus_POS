import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';

class CreditLedgerService {
  final AppDatabase _db;

  CreditLedgerService(this._db);

  WalletTransactionsDao get _walletTxDao => _db.walletTransactionsDao;
  CustomerWalletsDao get _customerWalletsDao => _db.customerWalletsDao;

  /// Add credit to a customer's credit balance (§18 Add Credit).
  ///
  /// Creates a WalletTransaction (credit) and a corresponding PaymentTransaction
  /// (wallet_topup), atomically in one transaction.
  Future<void> topup({
    required String customerId,
    required int amountKobo,
    required String method, // 'cash' or 'transfer'
    required String staffId,
  }) async {
    final businessId = _walletTxDao.requireBusinessId();
    final wallet = await _customerWalletsDao.getByCustomerId(customerId);

    if (wallet == null) {
      throw StateError('Customer $customerId has no credits balance');
    }

    final flagValue = await _db.systemConfigDao.get(
      'feature.domain_rpcs_v2.wallet_topup',
    );
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
        await _db.syncDao.enqueue(
          'domain:pos_wallet_topup',
          jsonEncode(payload),
        );
      } else {
        await _db.syncDao.enqueueUpsert('wallet_transactions', walletComp);
        await _db.syncDao.enqueueUpsert('payment_transactions', paymentComp);
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
    final originalDebit =
        await (_db.select(_db.walletTransactions)
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

  /// §18.3 Refund (CEO / Manager only — the UI gates on
  /// `customers.wallet.withdraw`). Pays the customer back money the business
  /// HOLDS for them: their held crate deposit and/or positive spendable credit
  /// balance. [amountKobo] is drawn from the held deposit FIRST, then from
  /// spendable credit, capped at what's available (a debt is never "refundable").
  ///
  /// **Destination is decided by the credit balance's debt status (user, 2026-06-05):**
  ///   • Credit balance IN DEBT (spendable < 0) → the held deposit is refunded TO THE
  ///     CREDITS BALANCE (a `crate_refund` spendable credit) so it REDUCES the debt — no
  ///     cash leaves. (Spendable credit is 0 when in debt, so the deposit is the
  ///     only thing refunded.) [method] is ignored on this path.
  ///   • Credit balance NOT in debt → paid out as CASH: a `payment_transactions` refund
  ///     row per portion via [method].
  /// Both paths post a `crate_deposit_refunded` debit for the deposit portion,
  /// which clears "held". The credit portion (only > 0 when not in debt) is a
  /// `refund` debit + cash row. Payment rows link via wallet_txn_id (the
  /// PaymentTransactions exactly-one-reference rule).
  ///
  /// Also writes an `activity_logs` entry and fires a notification (§24 money
  /// movement / §26.4 refund issued). Returns the amount actually refunded
  /// (after capping) so the caller can confirm or report "nothing to refund".
  Future<int> refundCash({
    required String customerId,
    required int amountKobo,
    required String method, // 'cash' | 'transfer' | 'pos' | 'other'
    required String staffId,
    String? note,
  }) async {
    if (amountKobo <= 0) return 0;
    final businessId = _walletTxDao.requireBusinessId();
    final wallet = await _customerWalletsDao.getByCustomerId(customerId);
    if (wallet == null) {
      throw StateError('Customer $customerId has no credits balance');
    }

    // Available = held deposit + positive spendable credit. A debt contributes 0.
    final heldKobo = await _walletTxDao.getDepositsHeldKobo(customerId);
    final spendableKobo = await _walletTxDao.getBalanceKobo(customerId);
    final inDebt = spendableKobo < 0;
    final depositAvailable = heldKobo > 0 ? heldKobo : 0;
    final creditAvailable = spendableKobo > 0 ? spendableKobo : 0;
    final available = depositAvailable + creditAvailable;
    if (available <= 0) return 0;

    final refundKobo = amountKobo > available ? available : amountKobo;
    // Drain the held deposit first, then spendable credit.
    final depositPortion = refundKobo > depositAvailable
        ? depositAvailable
        : refundKobo;
    final creditPortion = refundKobo - depositPortion;

    await _db.transaction(() async {
      final now = DateTime.now();

      Future<String> postWalletLeg(int signed, String refType) async {
        final id = UuidV7.generate();
        final comp = WalletTransactionsCompanion.insert(
          id: Value(id),
          businessId: businessId,
          walletId: wallet.id,
          customerId: customerId,
          type: signed >= 0 ? 'credit' : 'debit',
          amountKobo: signed.abs(),
          signedAmountKobo: signed,
          referenceType: refType,
          performedBy: Value(staffId),
          createdAt: Value(now),
          lastUpdatedAt: Value(now),
        );
        await _db.into(_db.walletTransactions).insert(comp);
        await _db.syncDao.enqueueUpsert('wallet_transactions', comp);
        return id;
      }

      Future<void> postCashRow(int portion, String walletTxnId) async {
        final payComp = PaymentTransactionsCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: businessId,
          amountKobo: portion,
          method: method,
          type: 'refund',
          walletTxnId: Value(walletTxnId),
          performedBy: Value(staffId),
          lastUpdatedAt: Value(now),
        );
        await _db.into(_db.paymentTransactions).insert(payComp);
        await _db.syncDao.enqueueUpsert('payment_transactions', payComp);
      }

      // Deposit portion always drops "held" via a crate_deposit_refunded debit.
      if (depositPortion > 0) {
        final refundedId = await postWalletLeg(
          -depositPortion,
          'crate_deposit_refunded',
        );
        if (inDebt) {
          // To credit balance: a spendable crate_refund credit reduces the debt. No cash.
          await postWalletLeg(depositPortion, 'crate_refund');
        } else {
          // Cash out.
          await postCashRow(depositPortion, refundedId);
        }
      }

      // Credit portion (only > 0 when NOT in debt) → cash out via a refund debit.
      if (creditPortion > 0) {
        final refundId = await postWalletLeg(-creditPortion, 'refund');
        await postCashRow(creditPortion, refundId);
      }

      // §24 money movement / §26.4 refund issued — audit + notify CEO/Manager.
      final dest = inDebt ? 'to credit balance (reduces debt)' : 'cash';
      final parts = <String>[
        if (depositPortion > 0)
          'deposit ${formatCurrency(depositPortion / 100)}',
        if (creditPortion > 0) 'credit ${formatCurrency(creditPortion / 100)}',
      ];
      await _db.activityLogDao.logActivity(
        action: 'customer.wallet.refund',
        description:
            'Refunded ${formatCurrency(refundKobo / 100)} $dest from credit balance'
            '${parts.isNotEmpty ? ' (${parts.join(', ')})' : ''}'
            '${note != null && note.trim().isNotEmpty ? ' — ${note.trim()}' : ''}',
        staffId: staffId,
        entityType: 'customer',
        entityId: customerId,
      );
      await _db.notificationsDao.fireNotification(
        type: 'wallet_refund',
        message:
            'Refund of ${formatCurrency(refundKobo / 100)} ($dest) issued from a '
            'customer credit balance',
        severity: 'info',
        linkedRecordId: customerId,
      );
    });

    return refundKobo;
  }

  /// Calculates the current balance for a customer.
  Future<int> getBalanceKobo(String customerId) =>
      _walletTxDao.getBalanceKobo(customerId);

  /// Watches the current balance for a customer.
  Stream<int> watchBalanceKobo(String customerId) =>
      _walletTxDao.watchBalanceKobo(customerId);

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

  /// §18 / PRD #155 (#173) — voids a customer credit TOP-UP by [walletTxnId]
  /// (the top-up's `wallet_transactions` credit row). A mistyped Add-Credit
  /// entry is corrected without fabricating an offsetting sale. In ONE
  /// transaction it:
  ///   1. marks the original credit voided and appends a compensating wallet
  ///      DEBIT (referenceType `void`) — the same append-only pattern as
  ///      [WalletTransactionsDao.voidTransaction], so the derived balance drops
  ///      the credit; and
  ///   2. reverses the paired `wallet_topup` payment row through the #169 seam
  ///      ([PaymentTransactionsDao.postReversalPayment]) with a NEGATIVE amount,
  ///      so the reconciliation cash card's "Debts collected (cash)"
  ///      (`cashDebtsCollectedKobo`: cash-method `type == 'wallet_topup'` rows)
  ///      nets this collection to zero — the voided amount drops out.
  ///
  /// Only genuine top-ups (referenceType `topup_cash` / `topup_transfer`) are
  /// voidable here; anything else is a no-op. Idempotent — an already-voided
  /// top-up returns false. The UI entry point (customer screen) is gated on
  /// `customers.wallet.withdraw` (Gates.refundCustomerWallet). Returns whether a
  /// void was posted.
  Future<bool> voidTopup({
    required String walletTxnId,
    required String staffId,
    String? reason,
  }) async {
    const topupRefs = {'topup_cash', 'topup_transfer'};
    final businessId = _walletTxDao.requireBusinessId();

    return _db.transaction(() async {
      final original =
          await (_db.select(_db.walletTransactions)
                ..where(
                  (t) =>
                      t.businessId.equals(businessId) &
                      t.id.equals(walletTxnId),
                )
                ..limit(1))
              .getSingleOrNull();
      if (original == null) return false;
      if (original.voidedAt != null) return false; // already voided
      if (!topupRefs.contains(original.referenceType)) return false;

      final now = DateTime.now();

      // 1a. Mark the original credit voided in place (retained metadata, as
      //     WalletTransactionsDao.voidTransaction does).
      await (_db.update(
        _db.walletTransactions,
      )..where((t) => t.id.equals(walletTxnId))).write(
        WalletTransactionsCompanion(
          voidedAt: Value(now),
          voidedBy: Value(staffId),
          voidReason: Value(reason),
          lastUpdatedAt: Value(now),
        ),
      );

      // 1b. Append the compensating wallet debit (opposite sign) so the derived
      //     balance drops the credit.
      final compId = UuidV7.generate();
      final compComp = WalletTransactionsCompanion.insert(
        id: Value(compId),
        businessId: businessId,
        walletId: original.walletId,
        customerId: original.customerId,
        type: original.type == 'credit' ? 'debit' : 'credit',
        amountKobo: original.amountKobo,
        signedAmountKobo: -original.signedAmountKobo,
        referenceType: 'void',
        orderId: Value(original.orderId),
        performedBy: Value(staffId),
        createdAt: Value(now),
        lastUpdatedAt: Value(now),
      );
      await _db.into(_db.walletTransactions).insert(compComp);

      final updatedOrig =
          await (_db.select(_db.walletTransactions)
                ..where((t) => t.id.equals(walletTxnId))
                ..limit(1))
              .getSingle();
      await _db.syncDao.enqueueUpsert('wallet_transactions', updatedOrig);
      await _db.syncDao.enqueueUpsert('wallet_transactions', compComp);

      // 2. Reverse the paired payment row (#169 seam), negative so the cash
      //    card nets the collection to zero. Legacy top-ups with no payment row
      //    (e.g. pre-ledger data) simply skip this leg.
      final payment =
          await (_db.select(_db.paymentTransactions)
                ..where(
                  (p) =>
                      p.businessId.equals(businessId) &
                      p.walletTxnId.equals(walletTxnId) &
                      p.type.equals('wallet_topup'),
                )
                ..limit(1))
              .getSingleOrNull();
      if (payment != null) {
        await _db.paymentTransactionsDao.postReversalPayment(
          original: payment,
          reversalType: 'wallet_topup',
          performedBy: staffId,
          amountKobo: -payment.amountKobo,
          reason: reason,
          at: now,
        );
      }

      // 3. Audit + notify (§24 money movement).
      await _db.activityLogDao.logActivity(
        action: 'customer.wallet.topup_voided',
        description:
            'Voided credit top-up of '
            '${formatCurrency(original.amountKobo / 100)}'
            '${reason != null && reason.trim().isNotEmpty ? ' — ${reason.trim()}' : ''}',
        staffId: staffId,
        entityType: 'customer',
        entityId: original.customerId,
      );
      await _db.notificationsDao.fireNotification(
        type: 'wallet_topup_voided',
        message:
            'A credit top-up of '
            '${formatCurrency(original.amountKobo / 100)} was voided',
        severity: 'info',
        linkedRecordId: original.customerId,
      );
      return true;
    });
  }
}
