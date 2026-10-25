import 'package:reebaplus_pos/core/database/app_database.dart';

/// Longest online description a shop may write (#473). Mirrors the Drift
/// column CHECK and cloud 0201.
const int kOnlineDescriptionMaxLength = 2000;

/// Longest brand name (#473). Mirrors the Drift column CHECK and cloud 0201.
const int kBrandMaxLength = 60;

/// How many of a product a shopper may order online (#473).
///
/// A quantity is allowed when it is at least [min], a whole multiple of [step]
/// (12 = whole crates only) and, when [max] is set, no more than [max]. The
/// storefront cart (#426) and the place-order RPC enforce the same rule; the
/// cloud twin is `public.order_quantity_allowed` (0201).
class OrderQuantityRule {
  const OrderQuantityRule({this.min = 1, this.step = 1, this.max});

  factory OrderQuantityRule.of(ProductData product) => OrderQuantityRule(
    min: product.minOrderQty,
    step: product.orderStep,
    max: product.maxOrderQty,
  );

  final int min;
  final int step;
  final int? max;

  bool allows(int quantity) =>
      quantity >= 1 &&
      quantity >= min &&
      quantity % step == 0 &&
      (max == null || quantity <= max!);

  /// The smallest quantity a shopper can order, or null when [max] leaves no
  /// allowed quantity (the edit form refuses to save that).
  int? get smallestAllowed {
    final first = ((min + step - 1) ~/ step) * step;
    return (max == null || first <= max!) ? first : null;
  }

  /// The next allowed quantity at or above [quantity], or null when none is.
  int? allowedAtOrAbove(int quantity) {
    final floor = quantity < min ? min : quantity;
    final next = ((floor + step - 1) ~/ step) * step;
    return (max == null || next <= max!) ? next : null;
  }

  /// True when the product carries no ordering limits.
  bool get isDefault => min == 1 && step == 1 && max == null;
}

/// Which listing box a validation error points at.
enum ListingField { description, brand, minOrder, orderStep, maxOrder }

/// The shop's own online words and order limits for one product (#473). There
/// is no separate listing record: these are columns on `products`.
class ListingContent {
  const ListingContent({
    this.onlineDescription,
    this.brand,
    this.minOrderQty = 1,
    this.orderStep = 1,
    this.maxOrderQty,
  });

  factory ListingContent.of(ProductData product) => ListingContent(
    onlineDescription: product.onlineDescription,
    brand: product.brand,
    minOrderQty: product.minOrderQty,
    orderStep: product.orderStep,
    maxOrderQty: product.maxOrderQty,
  );

  final String? onlineDescription;
  final String? brand;
  final int minOrderQty;
  final int orderStep;
  final int? maxOrderQty;

  OrderQuantityRule get rule =>
      OrderQuantityRule(min: minOrderQty, step: orderStep, max: maxOrderQty);

  @override
  bool operator ==(Object other) =>
      other is ListingContent &&
      other.onlineDescription == onlineDescription &&
      other.brand == brand &&
      other.minOrderQty == minOrderQty &&
      other.orderStep == orderStep &&
      other.maxOrderQty == maxOrderQty;

  @override
  int get hashCode =>
      Object.hash(onlineDescription, brand, minOrderQty, orderStep, maxOrderQty);
}

/// Result of [parseListingContent]: either [content] or an error on [field].
class ListingParse {
  const ListingParse.ok(ListingContent this.content)
    : field = null,
      message = null;
  const ListingParse.invalid(ListingField this.field, String this.message)
    : content = null;

  final ListingContent? content;
  final ListingField? field;
  final String? message;

  bool get isValid => content != null;
}

/// Shapes the raw text of the listing boxes. Blank description/brand save as
/// null; blank minimum and step mean 1; blank maximum means no limit.
ListingParse parseListingContent({
  required String description,
  required String brand,
  required String minOrder,
  required String orderStep,
  required String maxOrder,
}) {
  final d = description.trim();
  if (d.length > kOnlineDescriptionMaxLength) {
    return const ListingParse.invalid(
      ListingField.description,
      'Keep the online description to $kOnlineDescriptionMaxLength characters.',
    );
  }
  final b = brand.trim();
  if (b.length > kBrandMaxLength) {
    return const ListingParse.invalid(
      ListingField.brand,
      'Keep the brand to $kBrandMaxLength characters.',
    );
  }
  int? whole(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    return int.tryParse(t) ?? -1;
  }

  final min = whole(minOrder) ?? 1;
  if (min < 1) {
    return const ListingParse.invalid(
      ListingField.minOrder,
      'The smallest order must be a whole number, 1 or more.',
    );
  }
  final step = whole(orderStep) ?? 1;
  if (step < 1) {
    return const ListingParse.invalid(
      ListingField.orderStep,
      'Order in steps of a whole number, 1 or more.',
    );
  }
  final max = whole(maxOrder);
  if (max != null && max < min) {
    return const ListingParse.invalid(
      ListingField.maxOrder,
      'The largest order cannot be smaller than the smallest order.',
    );
  }
  final rule = OrderQuantityRule(min: min, step: step, max: max);
  if (rule.smallestAllowed == null) {
    return ListingParse.invalid(
      ListingField.maxOrder,
      'With steps of $step, no order fits under the largest order of $max.',
    );
  }
  return ListingParse.ok(
    ListingContent(
      onlineDescription: d.isEmpty ? null : d,
      brand: b.isEmpty ? null : b,
      minOrderQty: min,
      orderStep: step,
      maxOrderQty: max,
    ),
  );
}
