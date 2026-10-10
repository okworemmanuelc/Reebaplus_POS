import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';

/// One product on a stock request being built (#380), with how many units
/// the requester wants.
class StockRequestItem {
  const StockRequestItem({required this.product, required this.quantity});

  final ProductData product;

  /// Always at least 1: a line that would drop to 0 is removed instead.
  final int quantity;

  StockRequestItem withQuantity(int quantity) =>
      StockRequestItem(product: product, quantity: quantity);
}

/// The list of products a Request Stock screen is about to ask for (#380),
/// in the order they were added. Lives only while the screen is open
/// (auto-dispose): leaving the screen drops an unsent list.
///
/// Rules: a product appears once; every quantity is at least 1 (stepping
/// down from 1 removes the line, setting 0 or less removes it).
class StockRequestListNotifier
    extends AutoDisposeNotifier<List<StockRequestItem>> {
  @override
  List<StockRequestItem> build() => const [];

  /// Adds one unit of [product] (a tap on its tile).
  void add(ProductData product) {
    final i = _indexOf(product.id);
    if (i < 0) {
      state = [...state, StockRequestItem(product: product, quantity: 1)];
    } else {
      _replace(i, state[i].quantity + 1);
    }
  }

  /// Sets [product]'s quantity (tap and hold), adding the line if needed.
  /// Zero or less removes it.
  void setQuantity(ProductData product, int quantity) {
    if (quantity <= 0) {
      remove(product.id);
      return;
    }
    final i = _indexOf(product.id);
    if (i < 0) {
      state = [
        ...state,
        StockRequestItem(product: product, quantity: quantity),
      ];
    } else {
      _replace(i, quantity);
    }
  }

  /// The stepper's +.
  void increment(String productId) {
    final i = _indexOf(productId);
    if (i >= 0) _replace(i, state[i].quantity + 1);
  }

  /// The stepper's −: never below 1 — at 1 the line is removed instead.
  void decrement(String productId) {
    final i = _indexOf(productId);
    if (i < 0) return;
    if (state[i].quantity <= 1) {
      remove(productId);
    } else {
      _replace(i, state[i].quantity - 1);
    }
  }

  void remove(String productId) {
    state = [
      for (final item in state)
        if (item.product.id != productId) item,
    ];
  }

  void clear() => state = const [];

  int _indexOf(String productId) =>
      state.indexWhere((item) => item.product.id == productId);

  void _replace(int index, int quantity) {
    state = [
      for (var i = 0; i < state.length; i++)
        i == index ? state[i].withQuantity(quantity) : state[i],
    ];
  }
}

/// The open Request Stock screen's list (#380).
final stockRequestListProvider =
    NotifierProvider.autoDispose<
      StockRequestListNotifier,
      List<StockRequestItem>
    >(StockRequestListNotifier.new);

/// How many units of [productId] are on [items] (0 when absent).
int quantityOnRequest(List<StockRequestItem> items, String productId) {
  for (final item in items) {
    if (item.product.id == productId) return item.quantity;
  }
  return 0;
}

/// Total units across [items].
int totalRequestedUnits(List<StockRequestItem> items) =>
    items.fold(0, (sum, item) => sum + item.quantity);
