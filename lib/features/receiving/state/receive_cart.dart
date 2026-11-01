import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/shared/utils/quantity.dart';

class ReceiveCartLine {
  final String productId;
  final String productName;
  final String? unit;
  /// Units arriving, in quarter steps (#630). Whole unless [allowParts].
  final double qty;
  final int buyingPriceKobo;
  final int retailKobo;
  final int wholesaleKobo;
  final String? manufacturerId;
  final bool trackEmpties;

  /// The product's parts switch (`allow_fractional_sales`): off means this
  /// line takes whole numbers only (#630).
  final bool allowParts;

  /// The product's category, for the receive cart's tile colour and icon
  /// (#394). Display only; in memory only (the receive cart is never saved).
  final String? categoryId;

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
    this.allowParts = false,
    this.categoryId,
  });

  ReceiveCartLine copyWith({
    String? productId,
    String? productName,
    String? unit,
    double? qty,
    int? buyingPriceKobo,
    int? retailKobo,
    int? wholesaleKobo,
    String? manufacturerId,
    bool? trackEmpties,
    bool? allowParts,
    String? categoryId,
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
      allowParts: allowParts ?? this.allowParts,
      categoryId: categoryId ?? this.categoryId,
    );
  }

  /// A line arriving with no recorded buying price is **Uncosted** (CONTEXT.md
  /// §Inventory & Costing): it adds nothing to the supplier invoice and its
  /// Cost Batch lands uncosted, so those units later sell at 0 COGS until a
  /// cost is recorded. Accepted, never blocked — only disclosed (#199).
  bool get isUncosted => buyingPriceKobo == 0;

  /// What this line adds to the supplier invoice, in whole kobo (half up).
  int get totalKobo => lineTotalKobo(buyingPriceKobo, qty);

  /// The line can carry crates on this receipt: a bottle that tracks empties
  /// AND has a manufacturer (the crate-debt owner). The one gate shared by the
  /// crate inputs, the commit, and the "supplier required" rule — a receipt
  /// with any such line needs a supplier to hold the crate debt.
  bool get movesCrates => trackEmpties && manufacturerId != null;
}

class ReceiveCartNotifier extends Notifier<List<ReceiveCartLine>> {
  @override
  List<ReceiveCartLine> build() => [];

  void addOrIncrement(ProductData product, {double amount = 1}) {
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
          allowParts: product.allowFractionalSales,
          categoryId: product.categoryId,
        ),
      ];
    }
  }

  void setQty(String productId, double qty) {
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

  void setProductQty(ProductData product, double qty) {
    if (qty <= 0) {
      remove(product.id);
      return;
    }
    final existingIndex = state.indexWhere((l) => l.productId == product.id);
    if (existingIndex >= 0) {
      final updated = List<ReceiveCartLine>.from(state);
      updated[existingIndex] = updated[existingIndex].copyWith(qty: qty);
      state = updated;
    } else {
      state = [
        ...state,
        ReceiveCartLine(
          productId: product.id,
          productName: product.name,
          unit: product.unit,
          qty: qty,
          buyingPriceKobo: product.buyingPriceKobo,
          retailKobo: product.retailerPriceKobo,
          wholesaleKobo: product.wholesalerPriceKobo,
          manufacturerId: product.manufacturerId,
          trackEmpties: product.trackEmpties,
          allowParts: product.allowFractionalSales,
          categoryId: product.categoryId,
        ),
      ];
    }
  }

  void setBuyingPrice(String productId, int priceKobo) {
    if (priceKobo < 0) return;
    final existingIndex = state.indexWhere((l) => l.productId == productId);
    if (existingIndex >= 0) {
      final updated = List<ReceiveCartLine>.from(state);
      updated[existingIndex] = updated[existingIndex].copyWith(
        buyingPriceKobo: priceKobo,
      );
      state = updated;
    }
  }

  void setRetailPrice(String productId, int priceKobo) {
    if (priceKobo < 0) return;
    final existingIndex = state.indexWhere((l) => l.productId == productId);
    if (existingIndex >= 0) {
      final updated = List<ReceiveCartLine>.from(state);
      updated[existingIndex] = updated[existingIndex].copyWith(
        retailKobo: priceKobo,
      );
      state = updated;
    }
  }

  void setWholesalePrice(String productId, int priceKobo) {
    if (priceKobo < 0) return;
    final existingIndex = state.indexWhere((l) => l.productId == productId);
    if (existingIndex >= 0) {
      final updated = List<ReceiveCartLine>.from(state);
      updated[existingIndex] = updated[existingIndex].copyWith(
        wholesaleKobo: priceKobo,
      );
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
  double get totalUnits => state.fold(0.0, (sum, line) => sum + line.qty);
  int get invoiceTotalKobo =>
      state.fold(0, (sum, line) => sum + line.totalKobo);

  /// Lines that would arrive with no recorded buying price (#199 / PRD #155
  /// US 37). Drives the checkout's Uncosted disclosure; it never blocks the
  /// commit.
  int get uncostedLineCount => state.where((line) => line.isUncosted).length;

  /// Units carried by those lines — the quantity that would arrive at no cost.
  double get uncostedUnits =>
      state.fold(0.0, (sum, line) => sum + (line.isUncosted ? line.qty : 0));
}

final receiveCartProvider =
    NotifierProvider<ReceiveCartNotifier, List<ReceiveCartLine>>(() {
      return ReceiveCartNotifier();
    });
