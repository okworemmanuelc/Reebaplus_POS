/// The past-line cost rule from PRD #619. The old app never saved a cost per
/// sale line, so the delivery price stands in for it.
library;

/// One supplier delivery line, as far as costing cares.
class DeliveryPrice {
  final String productId;
  final DateTime deliveredAt;
  final int unitKobo;
  final bool isCancelled;

  const DeliveryPrice({
    required this.productId,
    required this.deliveredAt,
    required this.unitKobo,
    this.isCancelled = false,
  });
}

enum CostGroup {
  /// Most recent non-zero delivery on or before the sale.
  a,

  /// Sold before the product's first delivery: that first delivery's price.
  b,

  /// Never delivered: cost = sale unit price, so zero profit.
  c,
}

class LineCost {
  final int unitKobo;
  final CostGroup group;

  const LineCost({required this.unitKobo, required this.group});
}

/// Resolves a line's cost. A blank cost counts as full profit in net profit
/// (`recon_data.dart` `uncostedTakingsKobo`), so every line resolves to a value.
class CostRule {
  final Map<String, List<DeliveryPrice>> _byProduct = {};

  /// Cancelled deliveries never happened and ₦0 lines are free goods, so
  /// neither can set a price.
  CostRule(Iterable<DeliveryPrice> deliveries) {
    for (final delivery in deliveries) {
      if (delivery.isCancelled || delivery.unitKobo <= 0) continue;
      _byProduct.putIfAbsent(delivery.productId, () => []).add(delivery);
    }
    for (final prices in _byProduct.values) {
      prices.sort((x, y) => x.deliveredAt.compareTo(y.deliveredAt));
    }
  }

  LineCost costFor({
    required String productId,
    required DateTime soldAt,
    required int saleUnitKobo,
  }) {
    final prices = _byProduct[productId];
    if (prices == null) {
      return LineCost(unitKobo: saleUnitKobo, group: CostGroup.c);
    }
    DeliveryPrice? latest;
    for (final price in prices) {
      if (price.deliveredAt.isAfter(soldAt)) break;
      latest = price;
    }
    if (latest != null) {
      return LineCost(unitKobo: latest.unitKobo, group: CostGroup.a);
    }
    return LineCost(unitKobo: prices.first.unitKobo, group: CostGroup.b);
  }
}
