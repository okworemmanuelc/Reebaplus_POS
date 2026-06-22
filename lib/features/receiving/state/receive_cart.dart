import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';

class ReceiveCartLine {
  final String productId;
  final String productName;
  final String? unit;
  final int qty;
  final int buyingPriceKobo;
  final int retailKobo;
  final int wholesaleKobo;
  final String? manufacturerId;
  final bool trackEmpties;

  const ReceiveCartLine({
    required this.productId,
    required this.productName,
    this.unit,
    required this.qty,
    required this.buyingPriceKobo,
    required this.retailKobo,
    required this.wholesaleKobo,
    this.manufacturerId,
    required this.trackEmpties,
  });

  ReceiveCartLine copyWith({
    String? productId,
    String? productName,
    String? unit,
    int? qty,
    int? buyingPriceKobo,
    int? retailKobo,
    int? wholesaleKobo,
    String? manufacturerId,
    bool? trackEmpties,
  }) {
    return ReceiveCartLine(
      productId: productId ?? this.productId,
      productName: productName ?? this.productName,
      unit: unit ?? this.unit,
      qty: qty ?? this.qty,
      buyingPriceKobo: buyingPriceKobo ?? this.buyingPriceKobo,
      retailKobo: retailKobo ?? this.retailKobo,
      wholesaleKobo: wholesaleKobo ?? this.wholesaleKobo,
      manufacturerId: manufacturerId ?? this.manufacturerId,
      trackEmpties: trackEmpties ?? this.trackEmpties,
    );
  }
}

class ReceiveCartNotifier extends Notifier<List<ReceiveCartLine>> {
  @override
  List<ReceiveCartLine> build() => [];

  void addOrIncrement(ProductData product, {int amount = 1}) {
    final existingIndex = state.indexWhere((l) => l.productId == product.id);
    if (existingIndex >= 0) {
      final updated = List<ReceiveCartLine>.from(state);
      updated[existingIndex] = updated[existingIndex].copyWith(
        qty: updated[existingIndex].qty + amount,
      );
      state = updated;
    } else {
      state = [
        ...state,
        ReceiveCartLine(
          productId: product.id,
          productName: product.name,
          unit: product.unit,
          qty: amount,
          buyingPriceKobo: product.buyingPriceKobo,
          retailKobo: product.retailerPriceKobo,
          wholesaleKobo: product.wholesalerPriceKobo,
          manufacturerId: product.manufacturerId,
          trackEmpties: product.trackEmpties,
        )
      ];
    }
  }

  void setQty(String productId, int qty) {
    if (qty <= 0) {
      remove(productId);
      return;
    }
    final existingIndex = state.indexWhere((l) => l.productId == productId);
    if (existingIndex >= 0) {
      final updated = List<ReceiveCartLine>.from(state);
      updated[existingIndex] = updated[existingIndex].copyWith(qty: qty);
      state = updated;
    }
  }

  void setBuyingPrice(String productId, int priceKobo) {
    if (priceKobo < 0) return;
    final existingIndex = state.indexWhere((l) => l.productId == productId);
    if (existingIndex >= 0) {
      final updated = List<ReceiveCartLine>.from(state);
      updated[existingIndex] = updated[existingIndex].copyWith(buyingPriceKobo: priceKobo);
      state = updated;
    }
  }

  void setRetailPrice(String productId, int priceKobo) {
    if (priceKobo < 0) return;
    final existingIndex = state.indexWhere((l) => l.productId == productId);
    if (existingIndex >= 0) {
      final updated = List<ReceiveCartLine>.from(state);
      updated[existingIndex] = updated[existingIndex].copyWith(retailKobo: priceKobo);
      state = updated;
    }
  }

  void setWholesalePrice(String productId, int priceKobo) {
    if (priceKobo < 0) return;
    final existingIndex = state.indexWhere((l) => l.productId == productId);
    if (existingIndex >= 0) {
      final updated = List<ReceiveCartLine>.from(state);
      updated[existingIndex] = updated[existingIndex].copyWith(wholesaleKobo: priceKobo);
      state = updated;
    }
  }

  void remove(String productId) {
    state = state.where((l) => l.productId != productId).toList();
  }

  void clear() {
    state = [];
  }

  int get lineCount => state.length;
  int get totalUnits => state.fold(0, (sum, line) => sum + line.qty);
  int get invoiceTotalKobo => state.fold(0, (sum, line) => sum + (line.buyingPriceKobo * line.qty));
}

final receiveCartProvider = NotifierProvider<ReceiveCartNotifier, List<ReceiveCartLine>>(() {
  return ReceiveCartNotifier();
});
