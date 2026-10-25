import 'package:reebaplus_pos/core/storefront/storefront_models.dart';

/// One saved Shopper phone (#426). Cloud-only, via the shopper_* RPCs.
class ShopperPhone {
  const ShopperPhone({
    required this.id,
    required this.phone,
    this.isDefault = false,
  });

  final String id;
  final String phone;
  final bool isDefault;

  static ShopperPhone fromRow(Map<String, Object?> row) => ShopperPhone(
    id: '${row['id']}',
    phone: '${row['phone'] ?? ''}',
    isDefault: row['is_default'] == true,
  );
}

/// A delivery address: a saved one (with [id]) or one typed for an order.
class ShopperAddress {
  const ShopperAddress({
    this.id,
    this.country = kShopperDefaultCountry,
    required this.state,
    required this.lga,
    required this.street,
    this.isDefault = false,
  });

  final String? id;
  final String country;
  final String state;
  final String lga;
  final String street;
  final bool isDefault;

  /// "1 Road, Keffi, Nasarawa".
  String get label => '$street, $lga, $state';

  /// The browsing-area twin, used to ask a store whether it delivers here.
  ShopperArea get area => ShopperArea(country: country, state: state, lga: lga);

  Map<String, Object?> toRpc() => {
    'country': country,
    'state': state,
    'lga': lga,
    'street': street,
  };

  static ShopperAddress fromRow(Map<String, Object?> row) => ShopperAddress(
    id: row['id']?.toString(),
    country: (row['country'] as String?) ?? kShopperDefaultCountry,
    state: '${row['state'] ?? ''}',
    lga: '${row['lga'] ?? ''}',
    street: '${row['street'] ?? ''}',
    isDefault: row['is_default'] == true,
  );

  @override
  bool operator ==(Object other) =>
      other is ShopperAddress &&
      other.country == country &&
      other.state == state &&
      other.lga == lga &&
      other.street == street;

  @override
  int get hashCode => Object.hash(country, state, lga, street);
}

/// The Shopper's details: name plus saved phones and addresses. Shared with
/// the shops they order from (the details screen says so).
class ShopperProfile {
  const ShopperProfile({
    required this.name,
    this.phones = const [],
    this.addresses = const [],
  });

  final String name;
  final List<ShopperPhone> phones;
  final List<ShopperAddress> addresses;

  ShopperPhone? get defaultPhone {
    for (final p in phones) {
      if (p.isDefault) return p;
    }
    return phones.isEmpty ? null : phones.first;
  }

  ShopperAddress? get defaultAddress {
    for (final a in addresses) {
      if (a.isDefault) return a;
    }
    return addresses.isEmpty ? null : addresses.first;
  }

  static ShopperProfile fromJson(Map<String, Object?> json) => ShopperProfile(
    name: '${json['name'] ?? ''}',
    phones: [
      for (final r in (json['phones'] as List?) ?? const [])
        if (r is Map) ShopperPhone.fromRow(r.cast<String, Object?>()),
    ],
    addresses: [
      for (final r in (json['addresses'] as List?) ?? const [])
        if (r is Map) ShopperAddress.fromRow(r.cast<String, Object?>()),
    ],
  );
}

/// Online Order status, in the Shopper's plain words (#426, story 32).
enum OnlineOrderStatus {
  placed('new'),
  accepted('accepted'),
  declined('declined'),
  cancelled('cancelled_by_customer'),
  cancelledByShop('cancelled_by_shop'),
  sentOut('fulfilled'),
  expired('expired');

  const OnlineOrderStatus(this.wire);
  final String wire;

  static OnlineOrderStatus fromWire(Object? value) =>
      OnlineOrderStatus.values.firstWhere(
        (s) => s.wire == value,
        orElse: () => OnlineOrderStatus.placed,
      );
}

/// One line of a Shopper's order, as placed.
class ShopperOrderLine {
  const ShopperOrderLine({
    required this.productId,
    required this.name,
    required this.unitPriceKobo,
    required this.requestedQty,
    this.unit,
    this.acceptedQty,
  });

  final String productId;
  final String name;
  final String? unit;
  final int unitPriceKobo;
  final int requestedQty;
  final int? acceptedQty;

  /// The shop lowered or removed this line when accepting.
  bool get isChanged => acceptedQty != null && acceptedQty! < requestedQty;

  static ShopperOrderLine fromRow(Map<String, Object?> row) => ShopperOrderLine(
    productId: '${row['product_id']}',
    name: '${row['name'] ?? ''}',
    unit: row['unit'] as String?,
    unitPriceKobo: _int(row['unit_price_kobo']) ?? 0,
    requestedQty: _int(row['requested_qty']) ?? 0,
    acceptedQty: _int(row['accepted_qty']),
  );
}

/// One of the Shopper's Online Orders (My Orders).
class ShopperOrder {
  const ShopperOrder({
    required this.id,
    required this.storeId,
    required this.businessName,
    required this.reference,
    required this.status,
    required this.currency,
    required this.totalKobo,
    required this.placedAt,
    this.storeLga,
    this.storePhone,
    this.declineReason,
    this.cancelReason,
    this.lines = const [],
  });

  final String id;
  final String storeId;
  final String businessName;
  final String? storeLga;

  /// The store's public phone (#428), so a Shopper can call about an accepted
  /// order. Null when the cloud has none.
  final String? storePhone;
  final String reference;
  final OnlineOrderStatus status;
  final String currency;
  final int totalKobo;
  final DateTime placedAt;
  final String? declineReason;
  final String? cancelReason;
  final List<ShopperOrderLine> lines;

  /// "Stallion Global · Nasarawa".
  String get sellerLabel {
    final lga = storeLga?.trim();
    return lga == null || lga.isEmpty ? businessName : '$businessName · $lga';
  }

  /// Only an order the shop has not answered can be cancelled (story 33).
  bool get canCancel => status == OnlineOrderStatus.placed;

  /// What the shop will actually supply: the accepted quantities once it has
  /// answered (lowered or removed lines count less), else the estimate.
  int get displayTotalKobo {
    if (status != OnlineOrderStatus.accepted &&
        status != OnlineOrderStatus.sentOut) {
      return totalKobo;
    }
    if (lines.isEmpty || lines.every((l) => l.acceptedQty == null)) {
      return totalKobo;
    }
    return lines.fold<int>(
      0,
      (sum, l) => sum + l.unitPriceKobo * (l.acceptedQty ?? l.requestedQty),
    );
  }

  /// Plain-word status (story 32). An accepted order with lowered or removed
  /// lines reads "Changed".
  String get statusText => switch (status) {
    OnlineOrderStatus.placed => 'Placed',
    OnlineOrderStatus.accepted =>
      lines.any((l) => l.isChanged) ? 'Changed' : 'Accepted',
    OnlineOrderStatus.declined => 'Declined',
    OnlineOrderStatus.cancelled => 'Cancelled',
    OnlineOrderStatus.cancelledByShop => 'Cancelled by the shop',
    OnlineOrderStatus.sentOut => 'Sent out',
    OnlineOrderStatus.expired => "The shop didn't respond",
  };

  static ShopperOrder fromRow(Map<String, Object?> row) => ShopperOrder(
    id: '${row['id']}',
    storeId: '${row['store_id']}',
    businessName: '${row['business_name'] ?? ''}',
    storeLga: row['store_lga'] as String?,
    storePhone: row['store_phone'] as String?,
    reference: '${row['reference'] ?? ''}',
    status: OnlineOrderStatus.fromWire(row['status']),
    currency: (row['currency'] as String?) ?? 'NGN',
    totalKobo: _int(row['total_kobo']) ?? 0,
    placedAt:
        DateTime.tryParse('${row['placed_at']}')?.toLocal() ?? DateTime.now(),
    declineReason: row['decline_reason'] as String?,
    cancelReason: row['cancel_reason'] as String?,
    lines: [
      for (final r in (row['lines'] as List?) ?? const [])
        if (r is Map) ShopperOrderLine.fromRow(r.cast<String, Object?>()),
    ],
  );
}

/// Why one shop's order was not placed (server code from
/// `shopper_place_orders`).
enum PlaceOrderFailure {
  rateLimited('rate_limited'),
  storeUnavailable('store_unavailable'),
  outOfArea('out_of_area'),
  ownBusiness('own_business'),
  productUnavailable('product_unavailable'),
  quantityRule('quantity_rule'),
  notEnoughStock('not_enough_stock'),
  ageConfirmationRequired('age_confirmation_required'),
  invalid('invalid');

  const PlaceOrderFailure(this.wire);
  final String wire;

  static PlaceOrderFailure fromWire(Object? value) =>
      PlaceOrderFailure.values.firstWhere(
        (f) => f.wire == value,
        orElse: () => PlaceOrderFailure.invalid,
      );
}

/// The outcome for one shop after Place order.
class PlaceOrderResult {
  const PlaceOrderResult.placed({
    required this.orderId,
    required this.storeId,
    required String this.reference,
    required int this.totalKobo,
    required String this.currency,
  }) : failure = null,
       productId = null;

  const PlaceOrderResult.failed({
    required this.orderId,
    required this.storeId,
    required PlaceOrderFailure this.failure,
    this.productId,
  }) : reference = null,
       totalKobo = null,
       currency = null;

  final String orderId;
  final String storeId;
  final String? reference;
  final int? totalKobo;
  final String? currency;
  final PlaceOrderFailure? failure;

  /// The product a line-level failure points at.
  final String? productId;

  bool get isPlaced => failure == null;

  static PlaceOrderResult fromRow(Map<String, Object?> row) => row['ok'] == true
      ? PlaceOrderResult.placed(
          orderId: '${row['id']}',
          storeId: '${row['store_id']}',
          reference: '${row['reference'] ?? ''}',
          totalKobo: _int(row['total_kobo']) ?? 0,
          currency: (row['currency'] as String?) ?? 'NGN',
        )
      : PlaceOrderResult.failed(
          orderId: '${row['id']}',
          storeId: '${row['store_id']}',
          failure: PlaceOrderFailure.fromWire(row['code']),
          productId: row['product_id'] as String?,
        );
}

int? _int(Object? value) => switch (value) {
  final int v => v,
  final num v => v.toInt(),
  final String v => int.tryParse(v),
  _ => null,
};
