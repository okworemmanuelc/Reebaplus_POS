/// Pure old-to-new value mappings. Old ledgers count "owes" as positive; the new
/// ones count it as negative, so money crossing over has its sign flipped.
library;

import 'quantity.dart';

/// A ledger row's direction. Zero carries no direction and passes either way.
String ledgerType(int signedKobo) => signedKobo < 0 ? 'debit' : 'credit';

class WalletLeg {
  final String type;
  final int amountKobo;
  final int signedKobo;
  final String referenceType;

  /// A real cash receipt, so it also needs a `wallet_topup` payment row.
  final bool isCashIn;

  const WalletLeg({
    required this.type,
    required this.amountKobo,
    required this.signedKobo,
    required this.referenceType,
    required this.isCashIn,
  });
}

/// [oldType] is `SALE_CREDIT`, `PAYMENT` or `ADJUSTMENT`. A negative SALE_CREDIT
/// is an overpaid sale leaving the customer in credit, which the app posts as a
/// top-up leg rather than an order charge.
WalletLeg walletLegFor({required String oldType, required int oldAmountKobo}) {
  final signed = -oldAmountKobo;
  final referenceType = switch (oldType) {
    'SALE_CREDIT' => signed > 0 ? 'topup_cash' : 'order_payment',
    'PAYMENT' => 'topup_cash',
    'ADJUSTMENT' => 'adjustment',
    _ => throw ArgumentError.value(oldType, 'oldType', 'unknown ledger type'),
  };
  return WalletLeg(
    type: ledgerType(signed),
    amountKobo: signed.abs(),
    signedKobo: signed,
    referenceType: referenceType,
    isCashIn: oldType == 'PAYMENT' && signed > 0,
  );
}

class SupplierLeg {
  final String type;
  final int amountKobo;
  final int signedKobo;
  final String referenceType;
  final String? paymentMethod;

  const SupplierLeg({
    required this.type,
    required this.amountKobo,
    required this.signedKobo,
    required this.referenceType,
    required this.paymentMethod,
  });
}

final RegExp _transferNote = RegExp(
  r'\b(opay|moniepoint|transfer)\b',
  caseSensitive: false,
);

/// [oldType] is `DELIVERY_CREDIT`, `PAYMENT` or `ADJUSTMENT`. The old app never
/// recorded a method, so a payment is cash unless its note names a transfer.
SupplierLeg supplierLegFor({
  required String oldType,
  required int oldAmountKobo,
  required String? note,
}) {
  final signed = -oldAmountKobo;
  final isTransfer = note != null && _transferNote.hasMatch(note);
  final (referenceType, method) = switch (oldType) {
    'DELIVERY_CREDIT' => ('invoice', null),
    'PAYMENT' when isTransfer => ('payment_transfer', 'transfer'),
    'PAYMENT' => ('payment_cash', 'cash'),
    'ADJUSTMENT' => ('void', null),
    _ => throw ArgumentError.value(oldType, 'oldType', 'unknown ledger type'),
  };
  return SupplierLeg(
    type: ledgerType(signed),
    amountKobo: signed.abs(),
    signedKobo: signed,
    referenceType: referenceType,
    paymentMethod: method,
  );
}

/// `OLD-<last 8 of old id>`, so old notes such as "Sale #xxxxxxxx cancelled"
/// still match the order.
String orderNumberFor(String oldSaleId) {
  final start = oldSaleId.length < 8 ? 0 : oldSaleId.length - 8;
  return 'OLD-${oldSaleId.substring(start)}';
}

/// `orders.payment_type`, by the app's own rule (`resolveOrderPaymentType`). It
/// reads the amounts rather than the old status, which can be stale after an
/// edit. Past sales are all cash: the old app never recorded a method.
String orderPaymentType({required int paidKobo, required int totalKobo}) {
  if (paidKobo <= 0 && totalKobo > 0) return 'credit';
  if (paidKobo < totalKobo) return 'mixed';
  return 'cash';
}

/// How much of a sale's cash is goods, and how much is an overpayment.
({int goodsKobo, int overpaidKobo}) splitTender({
  required int paidKobo,
  required int totalKobo,
}) {
  final goods = paidKobo < totalKobo ? paidKobo : totalKobo;
  return (goodsKobo: goods, overpaidKobo: paidKobo - goods);
}

/// Customer name, keeping the trading name the old app held separately.
String customerDisplayName({
  required String name,
  required String? businessName,
}) {
  final trading = businessName?.trim() ?? '';
  final person = name.trim();
  if (trading.isEmpty || trading.toLowerCase() == person.toLowerCase()) {
    return person;
  }
  return '$person ($trading)';
}

final RegExp _petName = RegExp(r'\bpet\b', caseSensitive: false);
final RegExp _canName = RegExp(r'\bcans?\b', caseSensitive: false);

/// `products.unit`. Returnable glass is a Bottle (1 unit = 1 crate, as in the
/// old app); that is the unit crate tracking keys on.
String productUnit({required bool isReturnable, required String name}) {
  if (isReturnable) return 'Bottle';
  if (_petName.hasMatch(name)) return 'Pack';
  if (_canName.hasMatch(name)) return 'Carton';
  return 'Piece';
}

class SupplierInput {
  final String id;
  final String name;
  final String storeId;
  final DateTime createdAt;

  const SupplierInput({
    required this.id,
    required this.name,
    required this.storeId,
    required this.createdAt,
  });
}

String _supplierKey(String name) =>
    name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// Suppliers are business-wide here but were per-branch there, so same-name
/// suppliers merge. Returns each old id's surviving old id: the main store's
/// copy, else the earliest.
Map<String, String> mergeSuppliers({
  required Iterable<SupplierInput> suppliers,
  required String mainStoreId,
}) {
  final groups = <String, List<SupplierInput>>{};
  for (final supplier in suppliers) {
    groups.putIfAbsent(_supplierKey(supplier.name), () => []).add(supplier);
  }
  final survivors = <String, String>{};
  for (final group in groups.values) {
    group.sort((x, y) {
      final xMain = x.storeId == mainStoreId ? 0 : 1;
      final yMain = y.storeId == mainStoreId ? 0 : 1;
      if (xMain != yMain) return xMain - yMain;
      final byTime = x.createdAt.compareTo(y.createdAt);
      return byTime != 0 ? byTime : x.id.compareTo(y.id);
    });
    for (final supplier in group) {
      survivors[supplier.id] = group.first.id;
    }
  }
  return survivors;
}

/// A stock movement's quantity, for [reconcileOffGridMovements].
class MovementQty {
  final String id;
  final String groupKey;
  final DateTime createdAt;
  final double qty;

  const MovementQty({
    required this.id,
    required this.groupKey,
    required this.createdAt,
    required this.qty,
  });
}

class OffGridResult {
  /// Movement id → the quantity it now carries.
  final Map<String, double> replacedQty;

  /// Movements folded into another one, or left with nothing to carry.
  final Set<String> dropped;

  /// Groups whose sum stays off the grid, so they could not be kept.
  final List<MovementQty> unresolved;

  const OffGridResult({
    required this.replacedQty,
    required this.dropped,
    required this.unresolved,
  });
}

/// The target CHECK allows only multiples of 0.25, but an old sale edit can
/// leave split movements such as -0.7 and -0.3. Off-grid movements of the same
/// group fold into the earliest one when their sum lands on the grid, which
/// keeps the stock history's total exact. [groupKey] should identify one store,
/// product and sale.
OffGridResult reconcileOffGridMovements(Iterable<MovementQty> movements) {
  final groups = <String, List<MovementQty>>{};
  for (final movement in movements) {
    if (isQuarterStep(movement.qty)) continue;
    groups.putIfAbsent(movement.groupKey, () => []).add(movement);
  }
  final replaced = <String, double>{};
  final dropped = <String>{};
  final unresolved = <MovementQty>[];
  for (final group in groups.values) {
    group.sort((x, y) => x.createdAt.compareTo(y.createdAt));
    final sum = group.fold<double>(0, (total, m) => total + m.qty);
    if (!isQuarterStep(sum)) {
      unresolved.addAll(group);
      dropped.addAll(group.map((m) => m.id));
      continue;
    }
    final snapped = snapToQuarter(sum);
    if (snapped == 0) {
      dropped.addAll(group.map((m) => m.id));
      continue;
    }
    replaced[group.first.id] = snapped;
    dropped.addAll(group.skip(1).map((m) => m.id));
  }
  return OffGridResult(
    replacedQty: replaced,
    dropped: dropped,
    unresolved: unresolved,
  );
}

/// The calendar day a timestamp falls on in the shop's zone (Africa/Lagos,
/// always UTC+1), matching `AT TIME ZONE 'Africa/Lagos'` in the checks.
String lagosDay(DateTime at) =>
    at.toUtc().add(const Duration(hours: 1)).toIso8601String().substring(0, 10);

/// A held crate deposit's wallet leg. Old and new both count money held for the
/// customer as positive, so unlike the ledgers this does NOT flip.
WalletLeg depositLegFor({required String oldType, required int oldAmountKobo}) {
  final referenceType = switch (oldType) {
    'DEPOSITED' || 'ADJUSTMENT' => 'crate_deposit',
    'REFUNDED' => 'crate_deposit_refunded',
    'FORFEITED' => 'crate_deposit_forfeited',
    _ => throw ArgumentError.value(oldType, 'oldType', 'unknown deposit type'),
  };
  return WalletLeg(
    type: ledgerType(oldAmountKobo),
    amountKobo: oldAmountKobo.abs(),
    signedKobo: oldAmountKobo,
    referenceType: referenceType,
    isCashIn: false,
  );
}

/// What a `stock_transactions` row hangs off (exactly one, per its CHECK).
enum MovementLink { order, transfer, adjustment }

class MovementPlan {
  final String movementType;
  final MovementLink link;

  /// The `stock_adjustments.reason`, for an [MovementLink.adjustment].
  final String? reason;

  const MovementPlan({
    required this.movementType,
    required this.link,
    this.reason,
  });
}

/// Old stock movement → new shape. Receipts use the app's own reason, which the
/// recon's receipt classifier keys on; a cancelled delivery's reversal must NOT
/// read like a receipt. [vanLabel] is set for movements of a van trip.
MovementPlan movementPlanFor({
  required String oldType,
  required double qty,
  required bool hasSale,
  required bool hasDelivery,
  required String? note,
  required String? vanLabel,
}) {
  MovementPlan adjustment(String reason) => MovementPlan(
    movementType: 'adjustment',
    link: MovementLink.adjustment,
    reason: reason,
  );

  // Cancels and edits were ADJUSTMENT rows pointing at the sale; the app writes
  // those as `return` / `sale` rows on the order.
  if (oldType == 'SALE' || (oldType == 'ADJUSTMENT' && hasSale)) {
    return MovementPlan(
      movementType: qty > 0 ? 'return' : 'sale',
      link: MovementLink.order,
    );
  }
  return switch (oldType) {
    'TRANSFER_OUT' => const MovementPlan(
      movementType: 'transfer_out',
      link: MovementLink.transfer,
    ),
    'TRANSFER_IN' => const MovementPlan(
      movementType: 'transfer_in',
      link: MovementLink.transfer,
    ),
    'RESTOCK' => adjustment('Stock received'),
    'VAN_LOAD_OUT' => adjustment('Van load-out – $vanLabel'),
    'VAN_RETURN' => adjustment('Van return – $vanLabel'),
    'ADJUSTMENT' when hasDelivery => adjustment('Cancelled delivery'),
    'ADJUSTMENT' when vanLabel != null => adjustment(
      note ?? 'Van adjustment – $vanLabel',
    ),
    _ => adjustment(note ?? 'Adjustment (old app)'),
  };
}
