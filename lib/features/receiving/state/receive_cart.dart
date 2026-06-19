import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';

class ReceiveCartLine {
  final String productId;
  final String productName;
  final String? unit;
  final int qty;
  final int buyingPriceKobo;
  final String? manufacturerId;
  final bool trackEmpties;

  const ReceiveCartLine({
    required this.productId,
    required this.productName,
    this.unit,
    required this.qty,
    required this.buyingPriceKobo,
    this.manufacturerId,
    required this.trackEmpties,
  });

  ReceiveCartLine copyWith({
    String? productId,
    String? productName,
    String? unit,
    int? qty,
    int? buyingPriceKobo,
    String? manufacturerId,
    bool? trackEmpties,
  }) {
    return ReceiveCartLine(
      productId: productId ?? this.productId,
      productName: productName ?? this.productName,
      unit: unit ?? this.unit,
      qty: qty ?? this.qty,
      buyingPriceKobo: buyingPriceKobo ?? this.buyingPriceKobo,
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
