import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';

/// §3.13 — records empty-crate activity against a SUPPLIER. The supplier-side
/// mirror of the customer crate flow (`CrateLedgerDao.recordCrateReturnByCustomer`),
/// wrapped with Activity-Log writes. A *receipt* means full crates arrived from
/// the supplier (we now owe them N empties); a *return* means we handed empties
/// back (reduces what we owe). Each appends one append-only
/// [SupplierCrateLedger] row and upserts the [SupplierCrateBalances] cache via
/// [SupplierCrateLedgerDao]; this layer adds the audit trail.
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
}
