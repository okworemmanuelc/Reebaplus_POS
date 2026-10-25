import 'package:reebaplus_pos/core/data/area_selection.dart';

/// The Shopper's browsing area (#425). A null [state] is "All of [country]";
/// a null [lga] with a [state] is the whole state. Stored on the phone only
/// (device key-value storage), never in Drift or the outbox.
class ShopperArea {
  const ShopperArea({this.country = kShopperDefaultCountry, this.state, this.lga});

  /// "All of Nigeria".
  const ShopperArea.allNigeria() : this();

  factory ShopperArea.fromSelection(AreaSelection selection) => ShopperArea(
    country: selection.country,
    state: selection.state,
    lga: selection.lga,
  );

  final String country;
  final String? state;
  final String? lga;

  bool get isWholeCountry => state == null;

  /// "Keffi, Nasarawa" · "All of Nasarawa" · "All of Nigeria".
  String get label {
    if (state == null) return 'All of $country';
    if (lga == null) return 'All of $state';
    return '$lga, $state';
  }

  Map<String, Object?> toJson() => {
    'country': country,
    'state': state,
    'lga': lga,
  };

  /// Null for anything that is not a saved area (corrupt or missing value).
  static ShopperArea? fromJson(Object? json) {
    if (json is! Map) return null;
    final country = json['country'];
    final state = json['state'];
    final lga = json['lga'];
    if (country is! String || country.trim().isEmpty) return null;
    if (state != null && state is! String) return null;
    if (lga != null && lga is! String) return null;
    final cleanState = (state as String?)?.trim();
    final cleanLga = (lga as String?)?.trim();
    final hasState = cleanState != null && cleanState.isNotEmpty;
    return ShopperArea(
      country: country.trim(),
      state: hasState ? cleanState : null,
      lga: hasState && cleanLga != null && cleanLga.isNotEmpty ? cleanLga : null,
    );
  }

  /// Parameters every area-aware storefront RPC takes.
  Map<String, Object?> toRpcParams() => {
    'p_country': country,
    'p_state': state,
    'p_lga': lga,
  };

  @override
  bool operator ==(Object other) =>
      other is ShopperArea &&
      other.country == country &&
      other.state == state &&
      other.lga == lga;

  @override
  int get hashCode => Object.hash(country, state, lga);
}

const String kShopperDefaultCountry = 'Nigeria';

/// The server-computed stock label (#425). Never a raw count.
enum StorefrontStock {
  inStock('in_stock'),
  lowStock('low_stock'),
  onlyFewLeft('only_few_left'),
  outOfStock('out_of_stock');

  const StorefrontStock(this.wire);
  final String wire;

  static StorefrontStock fromWire(Object? value) => StorefrontStock.values
      .firstWhere((s) => s.wire == value, orElse: () => StorefrontStock.outOfStock);
}

/// One product card from the storefront RPCs: public listing fields only.
class StorefrontCard {
  const StorefrontCard({
    required this.productId,
    required this.storeId,
    required this.name,
    required this.priceKobo,
    required this.currency,
    required this.stock,
    required this.businessName,
    required this.cursor,
    this.imageUrl,
    this.unit,
    this.unitsPerPack,
    this.category = 'other',
    this.crateDepositKobo,
    this.onlyLeft,
    this.ageRestricted = false,
    this.stockMayBeStale = false,
    this.storeLga,
    this.onlineDescription,
    this.brand,
    this.minOrderQty = 1,
    this.orderStep = 1,
    this.maxOrderQty,
    this.sponsored = false,
  });

  final String productId;
  final String storeId;
  final String name;
  final String? imageUrl;
  final String? unit;
  final int? unitsPerPack;

  /// Reebaplus category slug (#472); unmapped products are 'other'.
  final String category;
  final int priceKobo;

  /// ISO-4217 code of the store's currency, e.g. 'NGN'.
  final String currency;

  /// Deposit per crate for crate-tracked bottle products, else null.
  final int? crateDepositKobo;
  final StorefrontStock stock;

  /// 1–3 when [stock] is [StorefrontStock.onlyFewLeft], else null.
  final int? onlyLeft;
  final bool ageRestricted;
  final bool stockMayBeStale;
  final String businessName;
  final String? storeLga;

  /// Listing content (#473): the shop's online description and brand.
  final String? onlineDescription;
  final String? brand;

  /// Order quantity rule (#473) for the #426 cart: at least [minOrderQty],
  /// in multiples of [orderStep], at most [maxOrderQty] (null = no limit).
  final int minOrderQty;
  final int orderStep;
  final int? maxOrderQty;

  /// Filled by #461; always false until then.
  final bool sponsored;

  /// Opaque keyset position; pass the last card's back to get the next page.
  final String cursor;

  bool get orderable => stock != StorefrontStock.outOfStock;

  /// "Stallion Global · Nasarawa" (just the business when no LGA is known).
  String get sellerLabel {
    final lga = storeLga?.trim();
    return lga == null || lga.isEmpty ? businessName : '$businessName · $lga';
  }

  /// "Order at least 2, in steps of 2, up to 20" — null for the default 1/1/none.
  String? get orderRuleText {
    final parts = <String>[
      if (minOrderQty > 1) 'at least $minOrderQty',
      if (orderStep > 1) 'in steps of $orderStep',
      if (maxOrderQty != null) 'up to $maxOrderQty',
    ];
    if (parts.isEmpty) return null;
    return 'Order ${parts.join(', ')}';
  }

  /// Display words for the stock pill.
  String get stockText => switch (stock) {
    StorefrontStock.inStock => 'In stock',
    StorefrontStock.lowStock => 'Low stock',
    StorefrontStock.onlyFewLeft => 'Only ${onlyLeft ?? 1} left',
    StorefrontStock.outOfStock => 'Out of stock',
  };

  static StorefrontCard fromRow(Map<String, Object?> row) => StorefrontCard(
    productId: _string(row['product_id']),
    storeId: _string(row['store_id']),
    name: _string(row['name']),
    imageUrl: _optString(row['image_url']),
    unit: _optString(row['unit']),
    unitsPerPack: _optInt(row['units_per_pack']),
    category: _optString(row['category']) ?? 'other',
    priceKobo: _optInt(row['price_kobo']) ?? 0,
    currency: _optString(row['currency']) ?? 'NGN',
    crateDepositKobo: _optInt(row['crate_deposit_kobo']),
    stock: StorefrontStock.fromWire(row['stock_label']),
    onlyLeft: _optInt(row['only_left']),
    ageRestricted: row['age_restricted'] == true,
    stockMayBeStale: row['stock_may_be_stale'] == true,
    businessName: _string(row['business_name']),
    storeLga: _optString(row['store_lga']),
    onlineDescription: _optString(row['online_description']),
    brand: _optString(row['brand']),
    minOrderQty: _optInt(row['min_order_qty']) ?? 1,
    orderStep: _optInt(row['order_step']) ?? 1,
    maxOrderQty: _optInt(row['max_order_qty']),
    sponsored: row['sponsored'] == true,
    cursor: _string(row['cursor']),
  );
}

/// A store page header.
class StorefrontStore {
  const StorefrontStore({
    required this.storeId,
    required this.businessName,
    required this.currency,
    required this.deliversToArea,
    this.logoUrl,
    this.state,
    this.lga,
    this.onlineNote,
    this.stockMayBeStale = false,
  });

  final String storeId;
  final String businessName;
  final String? logoUrl;
  final String? state;
  final String? lga;
  final String? onlineNote;
  final String currency;
  final bool deliversToArea;
  final bool stockMayBeStale;

  String get sellerLabel {
    final area = lga?.trim();
    return area == null || area.isEmpty ? businessName : '$businessName · $area';
  }

  static StorefrontStore fromRow(Map<String, Object?> row) => StorefrontStore(
    storeId: _string(row['store_id']),
    businessName: _string(row['business_name']),
    logoUrl: _optString(row['logo_url']),
    state: _optString(row['store_state']),
    lga: _optString(row['store_lga']),
    onlineNote: _optString(row['online_note']),
    currency: _optString(row['currency']) ?? 'NGN',
    deliversToArea: row['delivers_to_area'] == true,
    stockMayBeStale: row['stock_may_be_stale'] == true,
  );
}

/// One page of cards. [nextCursor] null = no more pages.
class StorefrontPage {
  const StorefrontPage({required this.cards, this.nextCursor});

  static const empty = StorefrontPage(cards: []);

  final List<StorefrontCard> cards;
  final String? nextCursor;
}

String _string(Object? value) => value is String ? value : '${value ?? ''}';

String? _optString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? _optInt(Object? value) => switch (value) {
  final int v => v,
  final num v => v.toInt(),
  final String v => int.tryParse(v),
  _ => null,
};
