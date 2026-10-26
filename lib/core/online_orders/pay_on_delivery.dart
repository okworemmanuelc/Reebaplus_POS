/// Pay on delivery (#432, PRD #421). A Cart sent to the till from an accepted
/// Online Order may be checked out with nothing paid now: under the hood it is
/// the existing credit sale (no new payment type), but it is labelled
/// "Pay on delivery · ₦X to collect" everywhere, never "credit". Whether an
/// order is Pay on delivery is DERIVED: it is a `credit` order that an Online
/// Order is linked to (`online_orders.linked_order_id`).
///
/// **Mark as paid** posts exactly the rows Record Payment posts (a
/// `topup_cash` / `topup_transfer` wallet credit + its `wallet_topup` payment
/// row), the wallet row carrying the order id. The amount collected is the sum
/// of those live (not voided) credits, so the order shows Paid once they cover
/// what was due.
library;

import 'package:reebaplus_pos/core/utils/number_format.dart';

/// The wallet reference types a Mark as paid (and Record Payment) writes.
const List<String> kPayOnDeliveryCollectionRefs = [
  'topup_cash',
  'topup_transfer',
];

/// The label for a Pay on delivery sale with [toCollectKobo] still to collect.
String payOnDeliveryLabel(int toCollectKobo) =>
    'Pay on delivery · ${formatCurrency(toCollectKobo / 100.0)} to collect';

/// The label once the money has been collected.
const String kPayOnDeliveryPaidLabel = 'Pay on delivery · Paid';

/// One Pay on delivery order, as the Orders screen, the receipt and Daily
/// Reconciliation see it.
class PayOnDeliveryOrder {
  const PayOnDeliveryOrder({
    required this.orderId,
    required this.onlineOrderId,
    required this.storeId,
    required this.customerId,
    required this.status,
    required this.dueKobo,
    required this.collectedKobo,
  });

  final String orderId;
  final String onlineOrderId;
  final String? storeId;
  final String? customerId;

  /// The order's status (`pending` / `completed` / `cancelled`).
  final String status;

  /// What the customer owes for this order (net − paid at Checkout).
  final int dueKobo;

  /// What Mark as paid has collected so far (live wallet credits).
  final int collectedKobo;

  /// What is still to collect; never negative.
  int get outstandingKobo {
    final left = dueKobo - collectedKobo;
    return left > 0 ? left : 0;
  }

  bool get isPaid => outstandingKobo == 0;

  /// A cancelled sale is reversed: nothing is left to collect for it.
  bool get isLive => status == 'pending' || status == 'completed';

  /// "Pay on delivery · ₦X to collect", or "Pay on delivery · Paid".
  String get label =>
      isPaid ? kPayOnDeliveryPaidLabel : payOnDeliveryLabel(outstandingKobo);
}

/// Daily Reconciliation's "Pay on delivery not yet collected" (report-only,
/// point-in-time): what live Pay on delivery orders still have to collect.
int payOnDeliveryUncollectedKobo(Iterable<PayOnDeliveryOrder> orders) =>
    orders
        .where((o) => o.isLive)
        .fold<int>(0, (sum, o) => sum + o.outstandingKobo);
