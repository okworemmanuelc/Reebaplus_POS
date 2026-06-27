import 'package:drift/drift.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';

/// §21.10 — records activity on a supplier's ledger. Mirrors [CreditLedgerService]
/// but inverted: an Invoice Total is a debit (we owe the supplier, red/negative),
/// a Payment is a credit (we paid them). Both append one append-only ledger row,
/// enqueue it for sync, and write an activity-log entry. Payments also fire a
/// §26 "supplier payment recorded" notification (a cash outflow).
class SupplierAccountService {
  final AppDatabase _db;

  SupplierAccountService(this._db);

  SupplierLedgerDao get _ledgerDao => _db.supplierLedgerDao;

  /// Record an Invoice Total — goods received (a debit, shown red/negative).
  /// [storeId] is the store this activity is recorded against (§21.11).
  Future<void> recordInvoice({
    required String supplierId,
    required int amountKobo,
    required DateTime dateReceived,
    required String staffId,
    String? storeId,
    String? note,
  }) async {
    if (amountKobo <= 0) {
      throw ArgumentError('Invoice amount must be greater than zero');
    }
    final businessId = _ledgerDao.requireBusinessId();
    final now = DateTime.now();

    await _db.transaction(() async {
      final comp = SupplierLedgerEntriesCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: businessId,
        supplierId: supplierId,
        storeId: Value(storeId),
        type: 'debit',
        amountKobo: amountKobo,
        signedAmountKobo: -amountKobo,
        referenceType: 'invoice',
        activityDate: dateReceived,
        referenceNote: Value(_clean(note)),
        performedBy: Value(staffId),
        createdAt: Value(now),
        lastUpdatedAt: Value(now),
      );
      await _db.into(_db.supplierLedgerEntries).insert(comp);
      await _db.syncDao.enqueueUpsert('supplier_ledger_entries', comp);

      await _db.activityLogDao.logActivity(
        action: 'supplier.invoice',
        description:
            'Recorded invoice of ${formatCurrency(amountKobo / 100)} (goods received)'
            '${_clean(note) != null ? ' — ${_clean(note)}' : ''}',
        staffId: staffId,
        entityType: 'supplier',
        entityId: supplierId,
      );
    });
  }

  /// Record a Payment — money paid to the supplier (a credit). Proof is
  /// REQUIRED: a [receiptPath] (local file) OR a non-empty [referenceNote]
  /// (bank-transfer reference, cheque number, or written explanation). The UI
  /// validates first; this guard is defense-in-depth.
  Future<void> recordPayment({
    required String supplierId,
    required int amountKobo,
    required String method, // 'cash' | 'transfer' | 'pos' | 'other'
    required DateTime paidOn,
    required String staffId,
    String? storeId,
    String? receiptPath,
    String? referenceNote,
  }) async {
    if (amountKobo <= 0) {
      throw ArgumentError('Payment amount must be greater than zero');
    }
    final cleanReceipt = _clean(receiptPath);
    final cleanNote = _clean(referenceNote);
    if (cleanReceipt == null && cleanNote == null) {
      throw ArgumentError('Payment requires a receipt or a reference note');
    }
    final businessId = _ledgerDao.requireBusinessId();
    final now = DateTime.now();
    final referenceType = 'payment_$method';

    await _db.transaction(() async {
      final comp = SupplierLedgerEntriesCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: businessId,
        supplierId: supplierId,
        storeId: Value(storeId),
        type: 'credit',
        amountKobo: amountKobo,
        signedAmountKobo: amountKobo,
        referenceType: referenceType,
        paymentMethod: Value(method),
        receiptPath: Value(cleanReceipt),
        referenceNote: Value(cleanNote),
        activityDate: paidOn,
        performedBy: Value(staffId),
        createdAt: Value(now),
        lastUpdatedAt: Value(now),
      );
      await _db.into(_db.supplierLedgerEntries).insert(comp);
      await _db.syncDao.enqueueUpsert('supplier_ledger_entries', comp);

      await _db.activityLogDao.logActivity(
        action: 'supplier.payment',
        description:
            'Paid ${formatCurrency(amountKobo / 100)} via $method'
            '${cleanNote != null ? ' — $cleanNote' : ''}',
        staffId: staffId,
        entityType: 'supplier',
        entityId: supplierId,
      );
      await _db.notificationsDao.fireNotification(
        type: 'supplier_payment',
        message:
            'Supplier payment of ${formatCurrency(amountKobo / 100)} ($method) recorded',
        severity: 'info',
        linkedRecordId: supplierId,
      );
    });
  }

  /// Current balance (kobo). Negative = we owe the supplier.
  Future<int> getBalanceKobo(String supplierId) =>
      _ledgerDao.getBalanceKobo(supplierId);

  /// Void a ledger entry (CEO only — gated at the UI; §21.7). Appends an
  /// opposite-sign compensating row (never deletes), then writes an Activity Log
  /// entry recording who voided what (§21.7 / Section 10.12). A double-void is a
  /// no-op and logs nothing.
  Future<bool> voidEntry({
    required String entryId,
    required String supplierId,
    required String voidedBy,
    required String reason,
  }) async {
    final didVoid = await _ledgerDao.voidEntry(
      entryId: entryId,
      voidedBy: voidedBy,
      reason: reason,
    );
    if (didVoid) {
      await _db.activityLogDao.logActivity(
        action: 'supplier.void',
        description: 'Voided a supplier ledger entry — $reason',
        staffId: voidedBy,
        entityType: 'supplier',
        entityId: supplierId,
      );
    }
    return didVoid;
  }

  static String? _clean(String? s) {
    final t = s?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }
}
