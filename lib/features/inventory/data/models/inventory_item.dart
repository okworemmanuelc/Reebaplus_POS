// InventoryItem model
// TODO: define InventoryItem class
import 'package:flutter/material.dart';

class InventoryItem {
  final String id;
  String productName;
  String subtitle;
  String? supplierId;
  String? crateGroupName;
  bool needsEmptyCrate;
  IconData icon;
  Color color;
  Map<String, double> storeStock; // storeId -> quantity
  double lowStockThreshold;

  // Pricing fields (schema v18: buying / retailer / wholesaler — master plan §16.5)
  double? buyingPrice;
  double? retailerPrice;
  double? wholesalerPrice;

  String? category;
  String? pairedCrateItemId;
  String? imagePath;
  String? manufacturer;
  String? size; // 'big' | 'medium' | 'small'
  String? unit;

  InventoryItem({
    required this.id,
    required this.productName,
    required this.subtitle,
    this.supplierId,
    this.crateGroupName,
    this.needsEmptyCrate = false,
    required this.icon,
    required this.color,
    this.storeStock = const {},
    this.lowStockThreshold = 5,
    this.buyingPrice,
    this.retailerPrice,
    this.wholesalerPrice,
    this.category,
    this.pairedCrateItemId,
    this.imagePath,
    this.manufacturer,
    this.size,
    this.unit,
  });

  double get totalStock =>
      storeStock.values.fold(0.0, (sum, val) => sum + val);

  // Helper to get stock for a specific store
  double getStockForStore(String storeId) =>
      storeStock[storeId] ?? 0.0;

  InventoryItem copyWith({
    String? id,
    String? productName,
    String? subtitle,
    String? supplierId,
    String? crateGroupName,
    bool? needsEmptyCrate,
    IconData? icon,
    Color? color,
    Map<String, double>? storeStock,
    double? lowStockThreshold,
    double? buyingPrice,
    double? retailerPrice,
    double? wholesalerPrice,
    String? category,
    String? pairedCrateItemId,
    String? imagePath,
    String? manufacturer,
    String? size,
    String? unit,
  }) {
    return InventoryItem(
      id: id ?? this.id,
      productName: productName ?? this.productName,
      subtitle: subtitle ?? this.subtitle,
      supplierId: supplierId ?? this.supplierId,
      crateGroupName: crateGroupName ?? this.crateGroupName,
      needsEmptyCrate: needsEmptyCrate ?? this.needsEmptyCrate,
      icon: icon ?? this.icon,
      color: color ?? this.color,
      storeStock: storeStock ?? this.storeStock,
      lowStockThreshold: lowStockThreshold ?? this.lowStockThreshold,
      buyingPrice: buyingPrice ?? this.buyingPrice,
      retailerPrice: retailerPrice ?? this.retailerPrice,
      wholesalerPrice: wholesalerPrice ?? this.wholesalerPrice,
      category: category ?? this.category,
      pairedCrateItemId: pairedCrateItemId ?? this.pairedCrateItemId,
      imagePath: imagePath ?? this.imagePath,
      manufacturer: manufacturer ?? this.manufacturer,
      size: size ?? this.size,
      unit: unit ?? this.unit,
    );
  }
}
