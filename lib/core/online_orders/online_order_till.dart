/// Send to till (#431, PRD #421): an ACCEPTED Online Order becomes an ordinary
/// till sale. These plain types carry what the Cart needs from Drift.
library;

import 'package:reebaplus_pos/core/database/app_database.dart';

/// One accepted line (accepted_qty > 0) with its live product and the stock of
/// the order's store.
class OnlineOrderTillLine {
  const OnlineOrderTillLine({
    required this.line,
    required this.product,
    required this.stock,
  });

  final OnlineOrderLineData line;
  final ProductData product;
  final int stock;

  /// The quantity the shop agreed to send.
  int get quantity => line.acceptedQty ?? line.requestedQty;
}

/// Everything the Cart needs to take an accepted order to Checkout.
class OnlineOrderTillLoad {
  const OnlineOrderTillLoad({
    required this.order,
    required this.lines,
    required this.customer,
    required this.missing,
  });

  final OnlineOrderData order;
  final List<OnlineOrderTillLine> lines;

  /// The linked shop Customer (null only if it was deleted).
  final CustomerData? customer;

  /// Names of accepted lines whose product is no longer in the catalogue.
  final List<String> missing;
}
