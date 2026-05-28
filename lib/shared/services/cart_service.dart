import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';

class CartService extends ValueNotifier<List<Map<String, dynamic>>> {
  final AuthService _auth;
  final ValueNotifier<Customer?> activeCustomer = ValueNotifier<Customer?>(
    null,
  );

  // Per-user cart storage: userId → cart items
  final Map<String, List<Map<String, dynamic>>> _userCarts = {};
  // Per-user active customer: userId → customer
  final Map<String, Customer?> _userCustomers = {};

  CartService(this._auth) : super([]) {
    // Swap to the new user's cart whenever login/logout happens
    _auth.addListener(_onUserChanged);
  }

  /// Track the previous user so we can clean up their cart on logout.
  String? _previousUid;

  void _onUserChanged() {
    final newUid = _uid;

    // If the previous user logged out (current user is null / anonymous),
    // clean up their stored cart to prevent unbounded memory growth.
    if (_previousUid != null &&
        _previousUid!.isNotEmpty &&
        _auth.currentUser == null) {
      _userCarts.remove(_previousUid);
      _userCustomers.remove(_previousUid);
    }
    _previousUid = newUid;

    value = List.from(_userCarts[newUid] ?? []);
    activeCustomer.value = _userCustomers[newUid];
  }

  /// The current user's ID. Empty string when nobody is logged in.
  String get _uid => _auth.currentUser?.id ?? '';

  void setActiveCustomer(Customer? customer) {
    _userCustomers[_uid] = customer;
    activeCustomer.value = customer;
  }

  /// Adds a product to the cart, clamping the total quantity to [maxStock]
  /// (the available stock for the locked store). Returns true if the
  /// full requested [qty] was accepted, false if it was clamped or rejected.
  ///
  /// Pass [maxStock] as a very large number (or omit) for legacy Map products
  /// (Quick Sale), which have no inventory tracking.
  bool addItem(dynamic product, {double qty = 1.0, int? maxStock}) {
    // Handling both legacy Map (Quick Sale) and new ProductData class
    final String name = product is ProductData ? product.name : product['name'];
    final String? id = product is ProductData ? product.id : null;

    final current = List<Map<String, dynamic>>.from(_userCarts[_uid] ?? []);
    final index = current.indexWhere(
      (item) => item['id'] == id && item['name'] == name,
    );

    // Determine the existing qty (0 if not yet in cart) and clamp.
    final double existingQty = index != -1
        ? (current[index]['qty'] as num).toDouble()
        : 0.0;
    final int cap = maxStock ?? 1 << 30; // effectively no cap
    final double allowed = (cap - existingQty).clamp(0.0, qty);
    final bool fullyAccepted = allowed >= qty;

    if (allowed <= 0) {
      // Already at limit — nothing to add.
      return false;
    }

    if (index != -1) {
      current[index]['qty'] = existingQty + allowed;
      // Refresh maxStock in case it changed since the item was first added.
      if (maxStock != null) current[index]['maxStock'] = maxStock;
    } else {
      final int unitPriceKobo = product is ProductData
          ? (product.sellingPriceKobo > 0
                ? product.sellingPriceKobo
                : product.retailPriceKobo)
          : (((product['price'] as num).toDouble() * 100).round());
      current.add({
        'id': id,
        'name': name,
        'subtitle': product is ProductData
            ? product.subtitle
            : product['subtitle'],
        'price': unitPriceKobo / 100.0,
        'unitPriceKobo': unitPriceKobo,
        'version': product is ProductData ? product.version : null,
        'qty': allowed,
        'icon': product is ProductData
            ? (product.iconCodePoint ?? FontAwesomeIcons.box.codePoint)
            : product['icon'],
        'color': product is ProductData ? product.colorHex : product['color'],
        'category': product is ProductData
            ? product.categoryId
            : product['category'],
        'crateSizeGroupId': product is ProductData
            ? product.crateSizeGroupId
            : product['crateSizeGroupId'],
        'crateGroupName': product is ProductData
            ? null
            : product['crateGroupName'],
        'emptyCrateValueKobo': product is ProductData
            ? product.emptyCrateValueKobo
            : (product['emptyCrateValueKobo'] ?? 0),
        'manufacturerId': product is ProductData
            ? product.manufacturerId
            : product['manufacturerId'],
        'buyingPriceKobo': product is ProductData
            ? product.buyingPriceKobo
            : (product['buyingPriceKobo'] ?? 0),
        'size': product is ProductData ? product.size : product['size'],
        'unit': product is ProductData
            ? product.unit
            : (product['unit'] ?? 'Bottle'),
        'trackEmpties': product is ProductData
            ? product.trackEmpties
            : (product['trackEmpties'] ?? false),
        'maxStock': maxStock ?? (1 << 30),
      });
    }

    _userCarts[_uid] = current;
    value = List.from(current);
    return fullyAccepted;
  }

  /// Updates the quantity of a cart line. The new qty is clamped to the
  /// item's stored `maxStock`. Returns true if the requested [newQty] was
  /// applied as-is, false if it was clamped (or the item wasn't found).
  bool updateQty(String productName, double newQty) {
    final current = List<Map<String, dynamic>>.from(_userCarts[_uid] ?? []);
    final index = current.indexWhere((item) => item['name'] == productName);
    if (index == -1) return false;

    if (newQty <= 0) {
      current.removeAt(index);
      _userCarts[_uid] = current;
      value = List.from(current);
      return true;
    }

    final int cap = (current[index]['maxStock'] as int?) ?? (1 << 30);
    final double clamped = newQty > cap ? cap.toDouble() : newQty;
    current[index]['qty'] = clamped;
    _userCarts[_uid] = current;
    value = List.from(current);
    return clamped >= newQty;
  }

  void removeItem(String productName) {
    final current = List<Map<String, dynamic>>.from(
      _userCarts[_uid] ?? [],
    ).where((item) => item['name'] != productName).toList();
    _userCarts[_uid] = current;
    value = List.from(current);
  }

  void clear() {
    _userCarts[_uid] = [];
    _userCustomers[_uid] = null;
    value = [];
    activeCustomer.value = null;
  }

  /// Refreshes product fields (name, price, emptyCrateValueKobo) across ALL
  /// user carts for the given product ID. Does not touch qty.
  /// Call this immediately after saving a product update to the DB.
  void refreshProduct({
    required String productId,
    required String name,
    required double price,
    required int emptyCrateValueKobo,
    int? unitPriceKobo,
    int? version,
  }) {
    bool anyChanged = false;
    for (final uid in _userCarts.keys) {
      final cart = _userCarts[uid]!;
      for (int i = 0; i < cart.length; i++) {
        if (cart[i]['id'] == productId) {
          cart[i] = Map<String, dynamic>.from(cart[i])
            ..['name'] = name
            ..['price'] = price
            ..['emptyCrateValueKobo'] = emptyCrateValueKobo;
          if (unitPriceKobo != null) cart[i]['unitPriceKobo'] = unitPriceKobo;
          if (version != null) cart[i]['version'] = version;
          anyChanged = true;
        }
      }
    }
    if (anyChanged) {
      value = List.from(_userCarts[_uid] ?? []);
    }
  }

  /// Accept fresh price/version for the current user's cart after a checkout
  /// staleness prompt. Maps `productId → (unitPriceKobo, version)`.
  void acceptStaleness(
    Map<String, ({int unitPriceKobo, int version})> updates,
  ) {
    final cart = List<Map<String, dynamic>>.from(_userCarts[_uid] ?? []);
    bool anyChanged = false;
    for (int i = 0; i < cart.length; i++) {
      final id = cart[i]['id'] as String?;
      if (id == null) continue;
      final fresh = updates[id];
      if (fresh == null) continue;
      cart[i] = Map<String, dynamic>.from(cart[i])
        ..['unitPriceKobo'] = fresh.unitPriceKobo
        ..['price'] = fresh.unitPriceKobo / 100.0
        ..['version'] = fresh.version;
      anyChanged = true;
    }
    if (anyChanged) {
      _userCarts[_uid] = cart;
      value = List.from(cart);
    }
  }

  void loadCart(List<Map<String, dynamic>> items, Customer? customer) {
    _userCustomers[_uid] = customer;
    _userCarts[_uid] = List.from(items);
    activeCustomer.value = customer;
    value = List.from(items);
  }

  double get totalItems =>
      value.fold(0, (sum, item) => sum + (item['qty'] as double));

  int get itemCount => value.length;

  double get subtotal => value.fold(
    0,
    (sum, item) =>
        sum +
        ((item['price'] as num).toDouble() * (item['qty'] as num).toDouble()),
  );
}
