import 'package:reebaplus_pos/core/listings/listing_content.dart';
import 'package:reebaplus_pos/core/storefront/shopper_models.dart';
import 'package:reebaplus_pos/core/storefront/storefront_models.dart';
import 'package:reebaplus_pos/core/storefront/storefront_service.dart';

/// One past line, found again today at today's price and stock label.
class OrderAgainItem {
  const OrderAgainItem(this.card, this.quantity);
  final StorefrontCard card;
  final int quantity;
}

/// What "Order again" (#436) can put back in the cart, and how many past lines
/// are no longer available.
class OrderAgainPlan {
  const OrderAgainPlan({required this.items, required this.skipped});
  final List<OrderAgainItem> items;
  final int skipped;
}

/// The nearest quantity to [wanted] that today's order rules allow (min, step,
/// max and a shown "Only N left"), or null when none is allowed.
int? clampOrderAgainQuantity(StorefrontCard card, int wanted) {
  final rule = OrderQuantityRule(
    min: card.minOrderQty,
    step: card.orderStep,
    max: card.maxOrderQty,
  );
  final smallest = rule.smallestAllowed;
  if (smallest == null) return null;
  var cap = wanted;
  final max = card.maxOrderQty;
  if (max != null && max < cap) cap = max;
  final left = card.onlyLeft;
  if (left != null && left < cap) cap = left;
  var q = (cap ~/ card.orderStep) * card.orderStep;
  if (q < smallest) q = smallest;
  if (max != null && q > max) return null;
  if (left != null && q > left) return null;
  return q;
}

/// Looks every line of [order] up again through `storefront_store_products`
/// (the existing RPC; there is no by-id one) and keeps only what is listed,
/// in stock and orderable now. Hidden, removed and sold-out lines count as
/// skipped.
Future<OrderAgainPlan> planOrderAgain(
  StorefrontService storefront,
  ShopperOrder order,
) async {
  const maxPages = 5;
  final found = await Future.wait([
    for (final line in order.lines)
      _find(storefront, order.storeId, line, maxPages),
  ]);
  final items = <OrderAgainItem>[];
  var skipped = 0;
  for (var i = 0; i < order.lines.length; i++) {
    final card = found[i];
    final qty = card == null || !card.orderable
        ? null
        : clampOrderAgainQuantity(card, order.lines[i].requestedQty);
    if (card == null || qty == null) {
      skipped++;
    } else {
      items.add(OrderAgainItem(card, qty));
    }
  }
  return OrderAgainPlan(items: items, skipped: skipped);
}

Future<StorefrontCard?> _find(
  StorefrontService storefront,
  String storeId,
  ShopperOrderLine line,
  int maxPages,
) async {
  String? after;
  for (var page = 0; page < maxPages; page++) {
    final result = await storefront.storeProducts(
      storeId: storeId,
      query: line.name,
      after: after,
    );
    for (final c in result.cards) {
      if (c.productId == line.productId) return c;
    }
    after = result.nextCursor;
    if (after == null) return null;
  }
  return null;
}

/// "2 items are no longer available and were skipped".
String orderAgainSkippedNote(int skipped) => skipped == 1
    ? '1 item is no longer available and was skipped'
    : '$skipped items are no longer available and were skipped';
