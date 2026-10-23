import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/inventory/screens/add_product_screen.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/features/receiving/widgets/new_product_card.dart';
import 'package:reebaplus_pos/features/receiving/widgets/receive_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/fly_to_cart.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/product_tile.dart';
import 'package:reebaplus_pos/core/utils/product_unit.dart';

/// The key on Receive Stock's tile for [productId] (#394).
ValueKey<String> receiveProductTileKey(String productId) =>
    ValueKey<String>('receive-product-tile-$productId');

/// The narrowest a tile column gets before the grid drops a column (POS's and
/// Request Stock's 170).
const double kReceiveTileMinWidth = 170;

/// Columns for a grid [width] dp wide (gutters included): as many
/// [kReceiveTileMinWidth] columns as fit, at least 2 (a phone) and at most 6
/// (#394).
int receiveGridColumns(double width) =>
    (width / kReceiveTileMinWidth).floor().clamp(2, 6);

/// A tile's height: its text at the current text scale plus the art, which
/// shrinks on a short sideways phone ([receiveShortHeight]) so a full row of
/// tiles shows on first view.
double receiveTileExtent(BuildContext context) {
  final scaler = MediaQuery.textScalerOf(context);
  double line(double base) => scaler.scale(context.getRFontSize(base)) * 1.35;
  return context.getRSize(10) * 2 + // tile padding
      context.getRSize(receiveShortHeight(context) ? 28 : 90) + // art
      context.getRSize(10) + // art → name
      line(15) * 2 + // name, up to two lines
      line(12) + // size · unit
      context.getRSize(8) +
      line(12) +
      context.getRSize(6) + // stock pill
      4; // the in-cart border
}

/// "60cl · Bottle": the product's size and unit, blanks skipped — the same
/// two values the receive card showed before (#394). [crates] is
/// `businessTracksCrates` for the active business (see [unitLabel]).
String? receiveTileSubtitle(ProductData product, {required bool crates}) {
  final parts = [
    product.size,
    unitLabel(product.unit, crates: crates),
  ].where((s) => s != null && s.trim().isNotEmpty).map((s) => s!.trim());
  return parts.isEmpty ? null : parts.join(' · ');
}

/// Receive Stock's product grid (#394), as a sliver inside the screen's one
/// scroll view (PRD #239: the chrome scrolls away rather than starving the
/// grid). The first cell is the New Product card when the user may add
/// products (`Gates.addProduct`); stock keepers without it still tap existing
/// products to receive quantity. Each product is the shared [ProductTile]:
/// "Current: N" (or "No stock") in the pill, the quantity on the receipt as
/// the badge, no price. Out of stock stays fully tappable — restocking an
/// empty product is the point.
class ReceiveProductGrid extends ConsumerWidget {
  const ReceiveProductGrid({
    super.key,
    required this.products,
    this.categoryNames = const {},
  });

  final List<ProductDataWithStock> products;

  /// Category id → name, for the tile's category colour and icon.
  final Map<String, String> categoryNames;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canAddProduct = Gates.addProduct.allows(ref);
    final gutter = context.getRSize(16);
    final gap = context.getRSize(12);
    // Columns from the grid's whole width, gutters included (POS's
    // `columnsFor` reads the same width): 4 beside the rail at 800dp.
    return SliverLayoutBuilder(
      builder: (context, constraints) => SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: gutter),
        sliver: SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: receiveGridColumns(constraints.crossAxisExtent),
            mainAxisExtent: receiveTileExtent(context),
            crossAxisSpacing: gap,
            mainAxisSpacing: gap,
          ),
          itemCount: products.length + (canAddProduct ? 1 : 0),
          itemBuilder: (context, index) {
            if (canAddProduct && index == 0) {
              return NewProductCard(
                key: ReceiveKeys.newProduct,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (ctx) => AddProductScreen(
                        receiveMode: true,
                        onProductAdded: (product) {
                          // Cart addition is handled inside AddProductScreen
                        },
                      ),
                    ),
                  );
                },
              );
            }
            final item = products[canAddProduct ? index - 1 : index];
            return _ReceiveProductTile(
              key: receiveProductTileKey(item.product.id),
              item: item,
              categoryName: categoryNames[item.product.categoryId],
            );
          },
        ),
      ),
    );
  }
}

class _ReceiveProductTile extends ConsumerStatefulWidget {
  const _ReceiveProductTile({
    super.key,
    required this.item,
    required this.categoryName,
  });

  final ProductDataWithStock item;
  final String? categoryName;

  @override
  ConsumerState<_ReceiveProductTile> createState() =>
      _ReceiveProductTileState();
}

class _ReceiveProductTileState extends ConsumerState<_ReceiveProductTile> {
  /// This tile's flight to the "Review Items" bar, if one is in the air (as
  /// POS's and Request Stock's tiles).
  FlyToCartFlight? _flight;

  @override
  void dispose() {
    _flight?.cancel();
    super.dispose();
  }

  void _add() {
    // The add happens first and never waits on the animation.
    ref.read(receiveCartProvider.notifier).addOrIncrement(widget.item.product);
    // A tile tapped again replaces its own flight.
    _flight?.cancel();
    _flight = null;
    // Launched after the next frame: on the first add the "Review Items" bar
    // (the target) only appears in that frame, and a flight resolves its
    // target at launch. No target, reduced motion or an unmounted tile → no
    // flight, silently.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _flight?.cancel();
      _flight = flyToTarget(context, target: FlyTargetId.receiveCart);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) {
    final product = widget.item.product;
    final totalStock = widget.item.totalStock;
    final cartQty = ref.watch(
      receiveCartProvider.select(
        (lines) =>
            lines.where((l) => l.productId == product.id).firstOrNull?.qty ?? 0,
      ),
    );
    final isOutOfStock = totalStock <= 0;
    return ProductTile(
      name: product.name,
      subtitle: receiveTileSubtitle(
        product,
        crates: businessTracksCrates(ref.watch(currentBusinessProvider)),
      ),
      stockLabel: isOutOfStock ? 'No stock' : 'Current: $totalStock',
      stockLevel: isOutOfStock ? StockLevel.out : StockLevel.ok,
      categoryName: widget.categoryName,
      photoPath: product.imagePath,
      inCartQty: cartQty,
      tappableWhenOut: true,
      onTap: _add,
    );
  }
}
