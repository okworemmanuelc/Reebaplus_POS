part of 'daos.dart';

/// Owns the compensating-reversal seam for the append-only
/// `payment_transactions` ledger (#169 / PRD #155).
///
/// The payment ledger becomes append-only *in practice*: every money
/// correction (cancelling a sale, rejecting/deleting an expense, voiding a
/// customer top-up) posts a NEW dated reversal row through
/// [postReversalPayment] instead of mutating the original row's in-place void
/// columns. The legacy `voided_at` / `voided_by` / `void_reason` columns are
/// retained read-only for rows written before this discipline landed. Because
/// cash-flow reporting counts every payment row on its own `created_at` day,
/// a later-day correction lands its cash movement on the correction day and
/// never rewrites a day the owner already reviewed and banked against.
///
/// This is the single seam every correction path shares; the paths themselves
/// (OrdersDao cancel, ExpensesDao reject/delete, CreditLedgerService top-up
/// void) are wired to call it in later slices — this prefactor only introduces
/// the verb, behavior-preservingly.
@DriftAccessor(tables: [PaymentTransactions])
class PaymentTransactionsDao extends DatabaseAccessor<AppDatabase>
    with _$PaymentTransactionsDaoMixin, BusinessScopedDao<AppDatabase> {
  PaymentTransactionsDao(super.db);

  /// Posts a DATED compensating reversal of [original] into the append-only
  /// payment ledger, enqueues it for sync, and returns the stored row.
  ///
  /// Invariants this holds:
  /// - The [original] row is left **untouched** — no in-place void, no edit.
  /// - The reversal lands on its **own** `created_at` day ([at], defaults to
  ///   now), so the original day's cash figures never change retroactively.
  /// - It copies [original]'s single typed reference (order / shipment /
  ///   expense / wallet_txn / delivery) so the exactly-one-reference CHECK
  ///   holds; the reversal therefore links back to the same source record.
  /// - It is stamped with a [storeId] (defaults to the original's store —
  ///   nullable, so a legacy store-less original yields a store-less reversal
  ///   that reports business-wide, exactly as today).
  ///
  /// [reversalType] is the payment `type` of the compensating row (a valid
  /// `payment_transactions.type`, e.g. `'refund'` for a cancelled sale).
  /// [amountKobo] defaults to the original's amount. [reason] is recorded in
  /// the reversal's `void_reason` free-text column as the correction reason
  /// (this row is not itself voided — the column is reused as the only audit
  /// note field on the table).
  Future<PaymentTransactionData> postReversalPayment({
    required PaymentTransactionData original,
    required String reversalType,
    required String performedBy,
    int? amountKobo,
    String? storeId,
    String? reason,
    DateTime? at,
  }) async {
    final now = at ?? DateTime.now();
    final reversalId = UuidV7.generate();
    final comp = PaymentTransactionsCompanion.insert(
      id: Value(reversalId),
      businessId: original.businessId,
      storeId: Value(storeId ?? original.storeId),
      amountKobo: amountKobo ?? original.amountKobo,
      method: original.method,
      type: reversalType,
      orderId: Value(original.orderId),
      shipmentId: Value(original.shipmentId),
      expenseId: Value(original.expenseId),
      walletTxnId: Value(original.walletTxnId),
      deliveryId: Value(original.deliveryId),
      performedBy: Value(performedBy),
      voidReason: Value(reason),
      createdAt: Value(now),
      lastUpdatedAt: Value(now),
    );
    await into(paymentTransactions).insert(comp);
    await db.syncDao.enqueueUpsert('payment_transactions', comp);
    return (select(paymentTransactions)
          ..where((p) => p.id.equals(reversalId)))
        .getSingle();
  }
}
