import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/inventory/data/models/inventory_item.dart';
import 'package:reebaplus_pos/features/inventory/screens/product_detail_screen.dart';
import 'package:reebaplus_pos/shared/utils/product_icon_helper.dart';
import 'package:reebaplus_pos/shared/widgets/slide_route.dart';

/// Opens [product]'s Product Details screen (#487). The one way in, shared by
/// the Inventory list and Add Product's name match, so both hand the detail
/// screen the same [InventoryItem].
///
/// [manufacturerName] and [totalStock] seed the screen until its own load and
/// stream catch up. [storeId] is the store whose stock it shows (null = All
/// Stores). [onUpdateStock] runs when the screen changes the stock.
Future<void> openProductDetails(
  BuildContext context,
  ProductData product, {
  String? manufacturerName,
  double totalStock = 0,
  String? storeId,
  VoidCallback? onUpdateStock,
}) {
  // The detail screen's hero still reads the product's own colour.
  final accent = product.colorHex != null
      ? Color(int.parse(product.colorHex!.replaceFirst('#', '0xFF')))
      : Theme.of(context).colorScheme.primary;
  final item = InventoryItem(
    id: product.id.toString(),
    productName: product.name,
    subtitle: product.subtitle ?? '',
    icon: productIconFromCodePoint(product.iconCodePoint),
    color: accent,
    storeStock: {'w1': totalStock},
    lowStockThreshold: product.lowStockThreshold.toDouble(),
    retailerPrice: product.retailerPriceKobo / 100.0,
    wholesalerPrice: product.wholesalerPriceKobo / 100.0,
    buyingPrice: product.buyingPriceKobo / 100.0,
    category: product.categoryId?.toString(),
    manufacturer: manufacturerName,
    size: product.size,
    unit: product.unit,
  );
  return Navigator.push(
    context,
    slideDownRoute<void>(
      ProductDetailScreen(
        item: item,
        onUpdateStock: onUpdateStock ?? () {},
        selectedStoreId: storeId,
      ),
    ),
  );
}
