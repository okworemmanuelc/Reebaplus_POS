import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/fly_to_cart.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/product_tile.dart';
import 'package:reebaplus_pos/core/utils/product_unit.dart';

/// The key on Request Stock's tile for [productId] (#380).
ValueKey<String> requestProductTileKey(String productId) =>
    ValueKey<String>('request-product-tile-$productId');

/// The narrowest a tile column gets before the grid drops a column.
const double kRequestTileMinWidth = 170;

/// Columns for a grid [width] dp wide: as many [kRequestTileMinWidth] columns
/// as fit, at least 2 (a 360dp phone) and at most 6.
int requestGridColumns(double width) =>
    (width / kRequestTileMinWidth).floor().clamp(2, 6);

/// Request Stock's product grid (#380), as a sliver inside the screen's one
/// scroll view (so a short or keyboard-shrunk window costs a scroll, never the
/// grid — PRD #239). Draws the shared [ProductTile]: the source store's stock
/// in the pill, the requested quantity as the badge, no price. Tap adds one
/// and flies to the "Review request" bar; tap and hold asks for a quantity.
class RequestProductGrid extends StatelessWidget {
  const RequestProductGrid({
    super.key,
    required this.products,
    required this.categoryNames,
    required this.quantityOf,
    required this.onAdd,
    required this.onChooseQuantity,
  });

  /// The source store's in-stock products, already filtered by the search.
  final List<ProductDataWithStock> products;

  /// Category id → name, for the tile's category colour and icon.
  final Map<String, String> categoryNames;

  /// How many of a product are on the request (0 = none).
  final int Function(String productId) quantityOf;
  final ValueChanged<ProductDataWithStock> onAdd;
  final ValueChanged<ProductDataWithStock> onChooseQuantity;

  @override
  Widget build(BuildContext context) {
    final gutter = context.getRSize(16);
    final gap = context.getRSize(12);
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: gutter),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) => SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: requestGridColumns(constraints.crossAxisExtent),
            mainAxisExtent: context.getRSize(220),
            crossAxisSpacing: gap,
            mainAxisSpacing: gap,
          ),
          itemCount: products.length,
          itemBuilder: (context, index) {
            final item = products[index];
            final product = item.product;
            return _RequestProductTile(
              key: requestProductTileKey(product.id),
              item: item,
              categoryName: categoryNames[product.categoryId],
              quantity: quantityOf(product.id),
              onAdd: () => onAdd(item),
              onChooseQuantity: () => onChooseQuantity(item),
            );
          },
        ),
      ),
    );
  }
}

class _RequestProductTile extends ConsumerStatefulWidget {
  const _RequestProductTile({
    super.key,
    required this.item,
    required this.categoryName,
    required this.quantity,
    required this.onAdd,
    required this.onChooseQuantity,
  });

  final ProductDataWithStock item;
  final String? categoryName;
  final int quantity;
  final VoidCallback onAdd;
  final VoidCallback onChooseQuantity;

  @override
  ConsumerState<_RequestProductTile> createState() =>
      _RequestProductTileState();
}

class _RequestProductTileState extends ConsumerState<_RequestProductTile> {
  /// This tile's flight to the bar, if one is in the air (as POS's tiles).
  FlyToCartFlight? _flight;

  @override
  void dispose() {
    _flight?.cancel();
    super.dispose();
  }

  void _add() {
    widget.onAdd();
    _flight?.cancel();
    _flight = flyToTarget(context, target: FlyTargetId.stockRequest);
  }

  @override
  Widget build(BuildContext context) {
    final product = widget.item.product;
    final stock = widget.item.totalStock;
    // "60cl · Bottle": the product's own subtitle, then its unit.
    final subtitle = [
      product.subtitle,
      unitLabel(
        product.unit,
        crates: businessTracksCrates(ref.watch(currentBusinessProvider)),
      ),
    ].where((s) => s != null && s.trim().isNotEmpty).join(' · ');
    return ProductTile(
      name: product.name,
      subtitle: subtitle.isEmpty ? null : subtitle,
      stockLabel: '$stock in stock',
      stockLevel: stock <= product.lowStockThreshold
          ? StockLevel.low
          : StockLevel.ok,
      categoryName: widget.categoryName,
      photoPath: product.imagePath,
      inCartQty: widget.quantity,
      onTap: _add,
      onLongPress: widget.onChooseQuantity,
    );
  }
}
