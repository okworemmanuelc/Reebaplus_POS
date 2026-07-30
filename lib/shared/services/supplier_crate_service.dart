import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';

/// §3.13 — records empty-crate activity against a SUPPLIER. The supplier-side
/// mirror of the customer crate flow (`CratePoolDao.recordCrateReturnByCustomer`),
/// wrapped with Activity-Log writes. A *receipt* means full crates arrived from
/// the supplier (we now owe them N empties); a *return* means we handed empties
/// back (reduces what we owe). Each appends one append-only
/// [SupplierCrateLedger] row and upserts the [SupplierCrateBalances] cache via
/// the Crate Pool seam ([CratePoolDao]); this layer adds the audit trail.
class SupplierCrateService {
  final AppDatabase _db;

  SupplierCrateService(this._db);

  SupplierCrateLedgerDao get _ledgerDao => _db.supplierCrateLedgerDao;

  /// Record full crates RECEIVED from a supplier (we now owe N empties), with
  /// an optional refundable [depositPaidKobo] paid on the receipt.
  Future<void> recordReceipt({
    required String supplierId,
    required String supplierName,
    required String manufacturerId,
    required String manufacturerName,
    required int quantity,
    required String staffId,
    String? storeId,
    int depositPaidKobo = 0,
    String? note,
  }) async {
    if (quantity <= 0) {
      throw ArgumentError('Crate quantity must be greater than zero');
    }
    await _db.transaction(() async {
      await _ledgerDao.recordCrateReceiptFromSupplier(
        supplierId: supplierId,
        manufacturerId: manufacturerId,
        quantity: quantity,
        performedBy: staffId,
        storeId: storeId,
        depositPaidKobo: depositPaidKobo,
        note: note,
      );
      final depositSuffix = depositPaidKobo > 0
          ? ' — deposit ${formatCurrency(depositPaidKobo / 100)}'
          : '';
      await _db.activityLogDao.logActivity(
        action: 'supplier.crate_received',
        description:
            'Received $quantity $manufacturerName crate${quantity == 1 ? '' : 's'} '
            'from $supplierName$depositSuffix',
        staffId: staffId,
        storeId: storeId,
        entityType: 'supplier',
        entityId: supplierId,
      );
    });
  }

  /// Record empties RETURNED to a supplier (reduces what we owe them), with an
  /// optional [depositRefundedKobo] refunded back to us on the return.
  Future<void> recordReturn({
    required String supplierId,
    required String supplierName,
    required String manufacturerId,
    required String manufacturerName,
    required int quantity,
    required String staffId,
    String? storeId,
    int depositRefundedKobo = 0,
    String? note,
  }) async {
    if (quantity <= 0) {
      throw ArgumentError('Crate quantity must be greater than zero');
    }
    await _db.transaction(() async {
      await _ledgerDao.recordCrateReturnToSupplier(
        supplierId: supplierId,
        manufacturerId: manufacturerId,
        quantity: quantity,
        performedBy: staffId,
        storeId: storeId,
        depositRefundedKobo: depositRefundedKobo,
        note: note,
      );
      final depositSuffix = depositRefundedKobo > 0
          ? ' — deposit refund ${formatCurrency(depositRefundedKobo / 100)}'
          : '';
      await _db.activityLogDao.logActivity(
        action: 'supplier.crate_returned',
        description:
            'Returned $quantity $manufacturerName crate${quantity == 1 ? '' : 's'} '
            'to $supplierName$depositSuffix',
        staffId: staffId,
        storeId: storeId,
        entityType: 'supplier',
        entityId: supplierId,
      );
    });
  }

  /// **A settlement run** (#213, PRD #203 / ADR 0023) — a trip that delivered
  /// nothing, carrying empties home, or a pure money settlement with no crates
  /// on it at all. The counterpart of [recordReturn] for a brand whose Crate
  /// Money Arrangement is `per_delivery`, where the refund is real money and
  /// waits for a money-permitted role rather than being typed into the legacy
  /// deposit column.
  ///
  /// [refundAmountKobo] is what the supplier ACTUALLY handed back, when the
  /// person on the trip already knows. Null means "ask for the crates' worth"
  /// and lets the approver record the real figure. Either way the money leg is
  /// a pending request, not a movement: nothing is on the books until someone
  /// who may move money says the money moved.
  ///
  /// [storeId] is required. The approval queue scopes approvers by store, so a
  /// settlement raised under "All Stores" would have no one to route to.
  Future<void> recordSettlement({
    required String supplierId,
    required String supplierName,
    required String manufacturerId,
    required String manufacturerName,
    required int crateCount,
    required String staffId,
    required String storeId,
    int? refundAmountKobo,
    String? note,
  }) async {
    if (crateCount < 0) {
      throw ArgumentError('Crate count cannot be negative');
    }
    if (crateCount == 0 && (refundAmountKobo ?? 0) <= 0) {
      throw ArgumentError(
        'A settlement with no crates needs the refund amount',
      );
    }
    await _db.transaction(() async {
      await _db.cratePoolDao.recordCrateSettlement(
        supplierId: supplierId,
        manufacturerId: manufacturerId,
        storeId: storeId,
        crateCount: crateCount,
        performedBy: staffId,
        refundAmountKobo: refundAmountKobo,
        note: note,
      );
      final crateClause = crateCount == 0
          ? 'no crates'
          : '$crateCount $manufacturerName crate'
                '${crateCount == 1 ? '' : 's'}';
      final refundClause = refundAmountKobo == null
          ? ' — refund awaiting confirmation'
          : ' — refund of ${formatCurrency(refundAmountKobo / 100)} '
                'awaiting confirmation';
      await _db.activityLogDao.logActivity(
        action: 'supplier.crate_settled',
        description:
            'Settled crate deposit with $supplierName: $crateClause returned'
            '$refundClause',
        staffId: staffId,
        storeId: storeId,
        entityType: 'supplier',
        entityId: supplierId,
      );
    });
  }
}
