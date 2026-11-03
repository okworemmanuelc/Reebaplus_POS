/// Display labels for the reversal rows a cancelled sale writes (#709).
///
/// Pure: every history (crate, stock, customer statement) maps through here so
/// the wording and the order number sit in one place.
library;

import 'package:reebaplus_pos/core/crates/crate_exchange.dart'
    show kOrderCancelledReason, kOrderPartReturnedReason;

/// "Sale cancelled — ORD-…"; just "Sale cancelled" when the number is unknown.
String saleCancelledLabel(String? orderNumber) =>
    (orderNumber == null || orderNumber.isEmpty)
    ? 'Sale cancelled'
    : 'Sale cancelled — $orderNumber';

/// "Returned — ORD-…" (#712): the row belongs to a sale ADJUSTMENT, a part
/// return. [orderNumber] is the adjustment's own number.
String saleReturnedLabel(String? orderNumber) =>
    (orderNumber == null || orderNumber.isEmpty)
    ? 'Returned'
    : 'Returned — $orderNumber';

/// The reversal wording for a row stamped with [orderNumber]: a part return
/// ([isAdjustment]) reads "Returned — ORD-…", a cancel "Sale cancelled — ORD-…".
String reversalLabelFor(String? orderNumber, {bool isAdjustment = false}) =>
    isAdjustment ? saleReturnedLabel(orderNumber) : saleCancelledLabel(orderNumber);

/// The crate-history label for a cancel's reversal row, or null when the row is
/// not one. New rows carry [kOrderCancelledReason]; rows written before #709
/// are a customer `adjusted` row with no reason against an order that is now
/// cancelled.
String? crateReversalLabel({
  required String movementType,
  required String? reason,
  required String? customerId,
  required String? referenceOrderId,
  required String? orderNumber,
  required String? orderStatus,
  String? orderKind,
}) {
  if (movementType != 'adjusted') return null;
  if (reason == kOrderPartReturnedReason || orderKind == 'adjustment') {
    return saleReturnedLabel(orderNumber);
  }
  final isNew = reason == kOrderCancelledReason;
  final isOld =
      (reason == null || reason.isEmpty) &&
      customerId != null &&
      referenceOrderId != null &&
      orderStatus == 'cancelled';
  return (isNew || isOld) ? saleCancelledLabel(orderNumber) : null;
}

/// The customer-statement label for a cancel's `refund` / `void` wallet leg, or
/// null. A wallet refund paid out to the customer carries no order id, so an
/// order id is what marks a reversal.
String? walletReversalLabel({
  required String referenceType,
  required String? orderId,
  required String? orderNumber,
  bool isAdjustment = false,
}) {
  if (orderId == null) return null;
  if (referenceType != 'refund' && referenceType != 'void') return null;
  return reversalLabelFor(orderNumber, isAdjustment: isAdjustment);
}
