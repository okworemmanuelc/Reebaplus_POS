// Listing quality (#475): which of the four things a shopper-ready online
// listing needs a product is still missing. Derived from data the app
// already holds; nothing is stored.

/// One thing a product needs before shoppers see it at its best.
enum ListingGap { photo, marketplaceCategory, description, onlineStock }

bool _filled(String? s) => (s ?? '').trim().isNotEmpty;

/// The gaps of one product, in checklist order. [inStockOnline] means some
/// store whose online ordering is on holds at least one unit.
List<ListingGap> listingGaps({
  required bool hasPhoto,
  required String? marketplaceCategory,
  required String? onlineDescription,
  required bool inStockOnline,
}) => [
  if (!hasPhoto) ListingGap.photo,
  if (!_filled(marketplaceCategory)) ListingGap.marketplaceCategory,
  if (!_filled(onlineDescription)) ListingGap.description,
  if (!inStockOnline) ListingGap.onlineStock,
];

/// What the store summary needs to know about one product held at the store.
class ListingFacts {
  const ListingFacts({
    required this.productId,
    required this.hasPhoto,
    required this.hasMarketplaceCategory,
    required this.hasDescription,
  });

  final String productId;
  final bool hasPhoto;
  final bool hasMarketplaceCategory;
  final bool hasDescription;

  bool get complete => hasPhoto && hasMarketplaceCategory && hasDescription;
}

/// The per-store count summary. The stock gap does not appear: every product
/// counted here is in stock at the store by definition.
class StoreListingGaps {
  const StoreListingGaps({
    this.missingPhoto = 0,
    this.missingCategory = 0,
    this.missingDescription = 0,
    this.withGaps = 0,
    this.firstProductId,
  });

  final int missingPhoto;
  final int missingCategory;
  final int missingDescription;

  /// Products missing at least one of the three.
  final int withGaps;

  /// The first product (list order) with any gap, for the tap.
  final String? firstProductId;

  bool get isClear => withGaps == 0;

  /// One line per kind of gap, e.g. "12 products missing a photo".
  List<String> get lines => [
    if (missingPhoto > 0) _line(missingPhoto, 'a photo'),
    if (missingCategory > 0) _line(missingCategory, 'a marketplace category'),
    if (missingDescription > 0) _line(missingDescription, 'an online description'),
  ];

  static String _line(int n, String what) =>
      '$n ${n == 1 ? 'product' : 'products'} missing $what';
}

StoreListingGaps summariseStoreGaps(Iterable<ListingFacts> facts) {
  var photo = 0, category = 0, description = 0, any = 0;
  String? first;
  for (final f in facts) {
    if (f.complete) continue;
    any++;
    first ??= f.productId;
    if (!f.hasPhoto) photo++;
    if (!f.hasMarketplaceCategory) category++;
    if (!f.hasDescription) description++;
  }
  return StoreListingGaps(
    missingPhoto: photo,
    missingCategory: category,
    missingDescription: description,
    withGaps: any,
    firstProductId: first,
  );
}
