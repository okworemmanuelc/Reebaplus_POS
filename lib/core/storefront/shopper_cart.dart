import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/listings/listing_content.dart';
import 'package:reebaplus_pos/core/storefront/storefront_models.dart';

/// "The store can't supply that many" — never the count (PRD #421 decision 10).
const String kStoreCannotSupplyMessage = "The store can't supply that many";

/// One cart line (#426): a product at one store, with what the Shopper saw
/// when adding it. Identity is `(storeId, productId)`. Prices here are only
/// an estimate: Place order re-prices every line in the cloud.
class ShopperCartLine {
  const ShopperCartLine({
    required this.storeId,
    required this.productId,
    required this.name,
    required this.priceKobo,
    required this.currency,
    required this.businessName,
    required this.quantity,
    this.storeLga,
    this.unit,
    this.unitsPerPack,
    this.imageUrl,
    this.minOrderQty = 1,
    this.orderStep = 1,
    this.maxOrderQty,
    this.onlyLeft,
    this.ageRestricted = false,
  });

  factory ShopperCartLine.fromCard(StorefrontCard card, int quantity) =>
      ShopperCartLine(
        storeId: card.storeId,
        productId: card.productId,
        name: card.name,
        priceKobo: card.priceKobo,
        currency: card.currency,
        businessName: card.businessName,
        storeLga: card.storeLga,
        unit: card.unit,
        unitsPerPack: card.unitsPerPack,
        imageUrl: card.imageUrl,
        minOrderQty: card.minOrderQty,
        orderStep: card.orderStep,
        maxOrderQty: card.maxOrderQty,
        onlyLeft: card.onlyLeft,
        ageRestricted: card.ageRestricted,
        quantity: quantity,
      );

  final String storeId;
  final String productId;
  final String name;
  final int priceKobo;
  final String currency;
  final String businessName;
  final String? storeLga;
  final String? unit;
  final int? unitsPerPack;
  final String? imageUrl;
  final int minOrderQty;
  final int orderStep;
  final int? maxOrderQty;

  /// 1–3 when the store showed "Only N left" — the one count the Shopper
  /// already saw, so the cart may cap at it. The real cap is server-side.
  final int? onlyLeft;

  /// An 18+ product (#479): Place order syncs the age confirmation first.
  final bool ageRestricted;
  final int quantity;

  OrderQuantityRule get rule =>
      OrderQuantityRule(min: minOrderQty, step: orderStep, max: maxOrderQty);

  int get lineTotalKobo => priceKobo * quantity;

  String get sellerLabel {
    final lga = storeLga?.trim();
    return lga == null || lga.isEmpty ? businessName : '$businessName · $lga';
  }

  /// "Order at least 2, in steps of 2, up to 20" — null for the default rule.
  String? get ruleText {
    final parts = <String>[
      if (minOrderQty > 1) 'at least $minOrderQty',
      if (orderStep > 1) 'in steps of $orderStep',
      if (maxOrderQty != null) 'up to $maxOrderQty',
    ];
    return parts.isEmpty ? null : 'Order ${parts.join(', ')}';
  }

  /// Why [qty] cannot be ordered, or null when it can (#473 min/step/max).
  String? problemWith(int qty) {
    if (!rule.allows(qty)) return ruleText ?? 'Order at least 1';
    final left = onlyLeft;
    if (left != null && qty > left) return kStoreCannotSupplyMessage;
    return null;
  }

  ShopperCartLine withQuantity(int qty) => ShopperCartLine(
    storeId: storeId,
    productId: productId,
    name: name,
    priceKobo: priceKobo,
    currency: currency,
    businessName: businessName,
    storeLga: storeLga,
    unit: unit,
    unitsPerPack: unitsPerPack,
    imageUrl: imageUrl,
    minOrderQty: minOrderQty,
    orderStep: orderStep,
    maxOrderQty: maxOrderQty,
    onlyLeft: onlyLeft,
    ageRestricted: ageRestricted,
    quantity: qty,
  );

  Map<String, Object?> toJson() => {
    'storeId': storeId,
    'productId': productId,
    'name': name,
    'priceKobo': priceKobo,
    'currency': currency,
    'businessName': businessName,
    'storeLga': storeLga,
    'unit': unit,
    'unitsPerPack': unitsPerPack,
    'imageUrl': imageUrl,
    'minOrderQty': minOrderQty,
    'orderStep': orderStep,
    'maxOrderQty': maxOrderQty,
    'onlyLeft': onlyLeft,
    'ageRestricted': ageRestricted,
    'quantity': quantity,
  };

  /// Null for a corrupt saved line (it is dropped, never crashes the cart).
  static ShopperCartLine? fromJson(Object? json) {
    if (json is! Map) return null;
    final storeId = json['storeId'];
    final productId = json['productId'];
    final name = json['name'];
    final price = json['priceKobo'];
    final quantity = json['quantity'];
    if (storeId is! String || productId is! String || name is! String) {
      return null;
    }
    if (price is! int || quantity is! int || quantity < 1) return null;
    int? optInt(Object? v) => v is int ? v : null;
    String? optString(Object? v) => v is String ? v : null;
    return ShopperCartLine(
      storeId: storeId,
      productId: productId,
      name: name,
      priceKobo: price,
      currency: optString(json['currency']) ?? 'NGN',
      businessName: optString(json['businessName']) ?? '',
      storeLga: optString(json['storeLga']),
      unit: optString(json['unit']),
      unitsPerPack: optInt(json['unitsPerPack']),
      imageUrl: optString(json['imageUrl']),
      minOrderQty: optInt(json['minOrderQty']) ?? 1,
      orderStep: optInt(json['orderStep']) ?? 1,
      maxOrderQty: optInt(json['maxOrderQty']),
      onlyLeft: optInt(json['onlyLeft']),
      ageRestricted: json['ageRestricted'] == true,
      quantity: quantity,
    );
  }
}

/// One shop's part of the cart, with its own subtotal. There is never a grand
/// total across shops (shops may use different currencies).
class ShopperCartGroup {
  const ShopperCartGroup({required this.storeId, required this.lines});

  final String storeId;
  final List<ShopperCartLine> lines;

  String get sellerLabel => lines.first.sellerLabel;
  String get businessName => lines.first.businessName;
  String get currency => lines.first.currency;
  int get subtotalKobo => lines.fold(0, (sum, l) => sum + l.lineTotalKobo);
}

/// The Shopper's one cart across shops, in insertion order.
class ShopperCart {
  const ShopperCart([this.lines = const []]);

  final List<ShopperCartLine> lines;

  bool get isEmpty => lines.isEmpty;

  /// Count of lines (shown on the cart badge).
  int get lineCount => lines.length;

  ShopperCartLine? lineFor(String storeId, String productId) {
    for (final l in lines) {
      if (l.storeId == storeId && l.productId == productId) return l;
    }
    return null;
  }

  /// Lines grouped by shop, shops in the order they were first added.
  List<ShopperCartGroup> get groups {
    final byStore = <String, List<ShopperCartLine>>{};
    for (final l in lines) {
      byStore.putIfAbsent(l.storeId, () => []).add(l);
    }
    return [
      for (final e in byStore.entries)
        ShopperCartGroup(storeId: e.key, lines: e.value),
    ];
  }
}

/// The cart in device key-value storage (#426, ADR 0031): never Drift, never
/// the outbox. It survives browsing, restarts and sign-in, and is re-checked
/// in the cloud at Place order.
class ShopperCartNotifier extends AsyncNotifier<ShopperCart> {
  static const prefKey = 'storefront_cart_v1';

  @override
  Future<ShopperCart> build() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefKey);
      if (raw == null) return const ShopperCart();
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const ShopperCart();
      return ShopperCart([
        for (final item in decoded)
          if (ShopperCartLine.fromJson(item) case final line?) line,
      ]);
    } catch (_) {
      // A corrupt or unreadable cart starts empty rather than crashing Browse.
      return const ShopperCart();
    }
  }

  ShopperCart get _cart => state.valueOrNull ?? const ShopperCart();

  /// Adds [quantity] of [card] (on top of what is already in the cart).
  /// Returns why it cannot, or null when added.
  Future<String?> add(StorefrontCard card, int quantity) async {
    await future;
    if (!card.orderable) return 'Out of stock';
    final existing = _cart.lineFor(card.storeId, card.productId);
    final line = ShopperCartLine.fromCard(
      card,
      (existing?.quantity ?? 0) + quantity,
    );
    final problem = line.problemWith(line.quantity);
    if (problem != null) return problem;
    await _save([
      for (final l in _cart.lines)
        if (l.storeId == card.storeId && l.productId == card.productId)
          line
        else
          l,
      if (existing == null) line,
    ]);
    return null;
  }

  /// Sets one line's quantity. Returns why it cannot, or null when set.
  Future<String?> setQuantity(String storeId, String productId, int qty) async {
    await future;
    final line = _cart.lineFor(storeId, productId);
    if (line == null) return null;
    final problem = line.problemWith(qty);
    if (problem != null) return problem;
    await _save([
      for (final l in _cart.lines)
        if (l.storeId == storeId && l.productId == productId)
          l.withQuantity(qty)
        else
          l,
    ]);
    return null;
  }

  Future<void> remove(String storeId, String productId) async {
    await future;
    await _save([
      for (final l in _cart.lines)
        if (!(l.storeId == storeId && l.productId == productId)) l,
    ]);
  }

  /// Drops every line of the shops whose orders were placed.
  Future<void> removeStores(Set<String> storeIds) async {
    await future;
    await _save([
      for (final l in _cart.lines)
        if (!storeIds.contains(l.storeId)) l,
    ]);
  }

  /// Empties the cart (#438, account deleted).
  Future<void> clear() async {
    await future;
    await _save(const []);
  }

  Future<void> _save(List<ShopperCartLine> lines) async {
    state = AsyncData(ShopperCart(List.unmodifiable(lines)));
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        prefKey,
        jsonEncode([for (final l in lines) l.toJson()]),
      );
    } catch (_) {
      // Keeping the cart across restarts is best effort; this run still has it.
    }
  }
}

final shopperCartProvider =
    AsyncNotifierProvider<ShopperCartNotifier, ShopperCart>(
      ShopperCartNotifier.new,
    );
