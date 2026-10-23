import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/pos/controllers/pos_controller.dart';
import 'package:reebaplus_pos/features/pos/widgets/edit_item_modal.dart';
import 'package:reebaplus_pos/features/pos/widgets/pos_header_parts.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/category_visual.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/fly_to_cart.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/product_tile.dart';
import 'package:reebaplus_pos/core/utils/product_unit.dart';

/// Key prefix on every product tile, so a test can find the *complete* tiles
/// the cashier can actually reach (issue #259 / PRD #239). The two-assertion
/// invariant needs a per-row handle: an overflow-only assertion passes a grid
/// that has been starved to zero height, because a scroll view given no room
/// throws nothing.
const String kPosProductTileKeyPrefix = 'pos-product-tile-';

/// The key carried by the tile for [productId].
ValueKey<String> posProductTileKey(String productId) =>
    ValueKey<String>('$kPosProductTileKeyPrefix$productId');

/// At or under this many in stock a tile's stock pill turns amber (the POS
/// rule since before the redesign; unchanged by #384).
const int kPosLowStockAt = 5;

/// The narrowest a grid column gets on a tablet or wide screen before the grid
/// drops a column (#384: 4 columns at 800dp upright beside the rail, and 4
/// beside the fixed cart panel at 1280dp, as the mockups draw).
const double kPosTileMinWidth = 170;

/// The height of one grid tile: padding, a fixed art area and room for a
/// two-line name, the size · pack line and the price row, all grown with the
/// text scale so a large system font never squeezes the text (ui-context
/// "Responsive Grid & Card Layouts").
double posTileExtent(BuildContext context) {
  final scaler = MediaQuery.textScalerOf(context);
  double line(double base) => scaler.scale(context.getRFontSize(base)) * 1.35;
  return context.getRSize(10) * 2 + // tile padding
      // art: smaller on a short screen, so a full row fits under the band
      context.getRSize(posShortHeight(context) ? 20 : 60) +
      context.getRSize(10) + // art → name
      line(15) * 2 + // name, up to two lines
      line(12) + // size · pack
      context.getRSize(8) +
      max(line(16), line(12) + context.getRSize(6)) + // price / stock pill
      4; // the in-cart border
}

/// "60cl · Crate": the product's description (its subtitle), its size and
/// its unit, the blanks skipped, joined with the mockup's " · " (#384). The
/// tile showed size + unit before; the description leads now, as on Request
/// Stock's tiles (#380), and the size word stays so nothing is lost.
String? posTileSubtitle(ProductData product) {
  final parts = [product.subtitle, product.size, unitLabel(product.unit)]
      .where((s) => s != null && s.trim().isNotEmpty && s != 'null')
      .map((s) => s!.trim())
      .toList();
  return parts.isEmpty ? null : parts.join(' · ');
}

/// The cart-badge text for [qty]: whole numbers bare, fractions to one place.
String posCartQtyLabel(double qty) => qty == qty.roundToDouble()
    ? qty.toInt().toString()
    : qty.toStringAsFixed(1);

/// The POS product grid, expressed as a **sliver** rather than a box.
///
/// ### Why this is a sliver (issue #259 / PRD #239)
///
/// POS used to build this inside an `Expanded` under a non-scrolling `Column`
/// of fixed chrome — the price-tier row, the search field and the category
/// chips. On the shortest supported landscape phone that chrome consumed the
/// whole viewport and the grid was laid out at **0.0dp of 463dp**: it rendered
/// nothing, reported no error, and a cashier could not start a sale. A grid
/// handed zero height throws nothing, which is why an overflow-only test
/// passed that screen for months.
///
/// As a sliver it no longer depends on a supplied height. It is content inside
/// POS's one scroll view, so a short viewport costs the cashier a scroll rather
/// than costing them the grid.
///
/// ### Tiles (#384)
///
/// Each grid cell is the shared [ProductTile]; the list view (the view
/// selector's "List View") is a flat row card built from the same data.
class ProductGrid extends StatelessWidget {
  final List<ProductDataWithStock> products;
  final Function(ProductDataWithStock) onProductTap;
  final PosController controller;
  final bool isListView;
  final int gridColumns;

  const ProductGrid({
    super.key,
    required this.products,
    required this.onProductTap,
    required this.controller,
    this.isListView = false,
    this.gridColumns = 2,
  });

  /// Column count for [availableWidth] (the grid's own width: the screen minus
  /// the side rail and a fixed cart panel). Under 380dp a phone is capped at 2;
  /// from 380 to 600 the view selector's preference governs; over 600 the
  /// width wins when it fits more [kPosTileMinWidth] columns than the
  /// preference, never fewer.
  static int columnsFor(double availableWidth, int gridColumns) {
    int effectiveColumns = gridColumns;
    if (availableWidth < 380) {
      // Small phone: maximum 2 columns
      if (effectiveColumns > 2) effectiveColumns = 2;
    } else if (availableWidth > 600) {
      // Tablet/Desktop: dynamically increase contents per row
      final dynamicColumns = (availableWidth / kPosTileMinWidth).floor();
      effectiveColumns = max(effectiveColumns, dynamicColumns);
    }
    return effectiveColumns;
  }

  @override
  Widget build(BuildContext context) {
    final muted =
        Theme.of(context).textTheme.bodySmall?.color ??
        Theme.of(context).colorScheme.onSurface;
    if (products.isEmpty) {
      // `hasScrollBody: false` sizes this to the LARGER of the remaining
      // viewport and its own natural height, so the "no products found" copy
      // still centres on a roomy phone and scrolls — rather than overflowing —
      // once the chrome above it has eaten the screen.
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                AppIcons.search,
                size: context.getRSize(48),
                color: muted.withValues(alpha: 0.3),
              ),
              SizedBox(height: context.getRSize(16)),
              Consumer(
                builder: (context, ref, _) => Text(
                  'No ${ref.watch(industryLexiconProvider).itemPluralLower} found',
                  style: context.semiBoldStyle(16).copyWith(color: muted),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Category id → name, for each tile's tint, icon and the chip dot colour.
    final categoryNames = {for (final c in controller.categories) c.id: c.name};
    final gutter = context.getRSize(16);
    final gap = context.getRSize(12);

    if (isListView) {
      return SliverPadding(
        padding: EdgeInsets.fromLTRB(
          gutter,
          context.getRSize(8),
          gutter,
          gutter,
        ),
        sliver: SliverList.separated(
          itemCount: products.length,
          separatorBuilder: (_, __) => SizedBox(height: gap),
          itemBuilder: (context, index) {
            final item = products[index];
            return _ProductCard(
              key: posProductTileKey(item.product.id),
              item: item,
              categoryName: categoryNames[item.product.categoryId],
              onTap: () => onProductTap(item),
              controller: controller,
              isListView: true,
            );
          },
        ),
      );
    }

    // The grid's real width: the screen minus whatever the app frame puts
    // beside it (the side rail, the fixed cart panel — #352).
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(gutter, context.getRSize(8), gutter, gutter),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final effectiveColumns = columnsFor(
            constraints.crossAxisExtent + gutter * 2,
            gridColumns,
          );
          return SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: effectiveColumns,
              mainAxisExtent: posTileExtent(context),
              crossAxisSpacing: gap,
              mainAxisSpacing: gap,
            ),
            itemCount: products.length,
            itemBuilder: (context, index) {
              final item = products[index];
              return _ProductCard(
                key: posProductTileKey(item.product.id),
                item: item,
                categoryName: categoryNames[item.product.categoryId],
                onTap: () => onProductTap(item),
                controller: controller,
                isListView: false,
              );
            },
          );
        },
      ),
    );
  }
}

class _ProductCard extends ConsumerStatefulWidget {
  final ProductDataWithStock item;
  final String? categoryName;
  final VoidCallback onTap;
  final PosController controller;
  final bool isListView;

  const _ProductCard({
    super.key,
    required this.item,
    required this.categoryName,
    required this.onTap,
    required this.controller,
    this.isListView = false,
  });

  @override
  ConsumerState<_ProductCard> createState() => _ProductCardState();
}

class _ProductCardState extends ConsumerState<_ProductCard> {
  /// This tile's flight to the cart, if one is in the air (#352 PR 3).
  FlyToCartFlight? _flight;

  @override
  void dispose() {
    _flight?.cancel();
    super.dispose();
  }

  /// Long-press opens the qty + discount sheet (the same editor used for cart
  /// lines), letting the user add the product with a chosen quantity/discount.
  Future<void> _openAddModal() async {
    HapticFeedback.mediumImpact();
    final accepted = await EditItemModal.showForProduct(
      context,
      product: widget.item.product,
      maxStock: widget.item.totalStock,
      tier: widget.controller.selectedGroup,
    );
    if (!mounted || accepted == null) return;
    if (accepted) {
      AppNotification.showSuccess(
        context,
        '${widget.item.product.name} added to cart',
      );
    } else {
      AppNotification.showError(
        context,
        'Stock limit reached for ${widget.item.product.name}',
      );
    }
  }

  void _handleTap() {
    // Fire product logic immediately
    widget.onTap();
    // Then fly a particle to whichever cart target is showing — the bottom-bar
    // Cart, the rail Cart, or the open cart panel's header (#352 PR 3). A
    // tile tapped again replaces its own flight, as before.
    _flight?.cancel();
    _flight = flyToTarget(context, target: FlyTargetId.cart);
  }

  @override
  Widget build(BuildContext context) {
    final product = widget.item.product;
    final stock = widget.item.totalStock;
    final bool isOutOfStock = stock <= 0;
    final int priceKobo = ref
        .read(databaseProvider)
        .catalogDao
        .getPriceForTier(
          product,
          widget.controller.selectedGroup == PriceTier.retailer
              ? 'retail'
              : 'wholesaler',
        );
    final price = priceKobo / 100.0;
    final bool isLowStock = !isOutOfStock && stock <= kPosLowStockAt;
    final level = isOutOfStock
        ? StockLevel.out
        : (isLowStock ? StockLevel.low : StockLevel.ok);

    return ValueListenableBuilder<List<Map<String, dynamic>>>(
      valueListenable: ref.watch(cartProvider),
      builder: (context, cartItems, _) {
        final double cartQty = cartItems
            .where((i) => i['id'] == product.id)
            .fold(0.0, (s, i) => s + (i['qty'] as num).toDouble());
        final bool atStockLimit = !isOutOfStock && cartQty >= stock;
        final VoidCallback? onTap = isOutOfStock
            ? null
            : (atStockLimit
                  ? () => AppNotification.showError(
                      context,
                      'Stock limit reached for ${product.name}',
                    )
                  : _handleTap);
        final VoidCallback? onLongPress = isOutOfStock ? null : _openAddModal;
        // A fraction still counts as "in the cart" (border + badge).
        final inCartQty = cartQty > 0 ? cartQty.ceil() : 0;

        if (widget.isListView) {
          return _PosProductListRow(
            name: product.name,
            subtitle: posTileSubtitle(product),
            priceLabel: formatCurrency(price),
            stockLabel: '$stock',
            stockLevel: level,
            categoryName: widget.categoryName,
            photoPath: product.imagePath,
            inCartLabel: inCartQty > 0 ? posCartQtyLabel(cartQty) : null,
            onTap: onTap,
            onLongPress: onLongPress,
          );
        }
        return ProductTile(
          name: product.name,
          subtitle: posTileSubtitle(product),
          priceLabel: formatCurrency(price),
          stockLabel: '$stock',
          stockLevel: level,
          categoryName: widget.categoryName,
          photoPath: product.imagePath,
          inCartQty: inCartQty,
          inCartLabel: posCartQtyLabel(cartQty),
          onTap: onTap,
          onLongPress: onLongPress,
        );
      },
    );
  }
}

/// One product in the POS list view (the view selector's "List View"): the
/// [ProductTile]'s content laid out as a row card — art square, name, size ·
/// pack, price in primary and the stock pill. In the cart = primary border and
/// the count badge; out of stock = dimmed, "Out of stock", no taps.
///
/// Shared-part candidate (a list density of `ProductTile`), local to POS until
/// a second screen needs it.
class _PosProductListRow extends StatelessWidget {
  const _PosProductListRow({
    required this.name,
    required this.subtitle,
    required this.priceLabel,
    required this.stockLabel,
    required this.stockLevel,
    required this.categoryName,
    required this.photoPath,
    required this.inCartLabel,
    required this.onTap,
    required this.onLongPress,
  });

  final String name;
  final String? subtitle;
  final String priceLabel;
  final String stockLabel;
  final StockLevel stockLevel;
  final String? categoryName;
  final String? photoPath;

  /// Null when the product is not in the cart.
  final String? inCartLabel;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final visual = categoryVisual(categoryName, f);
    final out = stockLevel == StockLevel.out;
    final inCart = inCartLabel != null;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    final art = context.getRSize(64);

    final (Color pillFill, Color pillDot) = switch (stockLevel) {
      StockLevel.ok => (f.greenTint, f.greenDot),
      StockLevel.low => (f.warningTint, f.warning),
      StockLevel.out => (f.dangerTint, f.danger),
    };

    final fallback = Center(
      child: AppIcon(
        visual.icon,
        filled: true,
        size: art * 0.5,
        color: visual.iconColor,
      ),
    );

    final card = Container(
      decoration: AppDecorations.card(context).copyWith(
        border: Border.all(
          color: inCart ? t.colorScheme.primary : t.dividerColor,
          width: inCart ? 2 : 1,
        ),
      ),
      padding: EdgeInsets.all(context.getRSize(10)),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
            child: SizedBox.square(
              dimension: art,
              child: ColoredBox(
                color: visual.tint,
                child: photoPath == null
                    ? fallback
                    : Image.file(
                        File(photoPath!),
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => fallback,
                      ),
              ),
            ),
          ),
          SizedBox(width: context.getRSize(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context
                      .boldStyle(15)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.regularStyle(12).copyWith(color: muted),
                  ),
                SizedBox(height: context.getRSize(6)),
                Row(
                  children: [
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          priceLabel,
                          maxLines: 1,
                          style: context
                              .boldStyle(16)
                              .copyWith(color: t.colorScheme.primary),
                        ),
                      ),
                    ),
                    SizedBox(width: context.getRSize(6)),
                    if (out)
                      Text(
                        'Out of stock',
                        style: context.boldStyle(12).copyWith(color: f.danger),
                      )
                    else
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: context.getRSize(8),
                          vertical: context.getRSize(3),
                        ),
                        decoration: ShapeDecoration(
                          color: pillFill,
                          shape: const StadiumBorder(),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: context.getRSize(7),
                              height: context.getRSize(7),
                              decoration: BoxDecoration(
                                color: pillDot,
                                shape: BoxShape.circle,
                              ),
                            ),
                            SizedBox(width: context.getRSize(4)),
                            Text(
                              stockLabel,
                              maxLines: 1,
                              softWrap: false,
                              style: context
                                  .boldStyle(12)
                                  .copyWith(color: t.colorScheme.onSurface),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return Semantics(
      button: true,
      enabled: !out,
      label: name,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: radius,
              onTap: onTap,
              onLongPress: onLongPress,
              child: Opacity(opacity: out ? 0.5 : 1, child: card),
            ),
          ),
          if (inCart)
            Positioned(
              top: -context.getRSize(6),
              right: -context.getRSize(6),
              child: Container(
                constraints: BoxConstraints(
                  minWidth: context.getRSize(26),
                  minHeight: context.getRSize(26),
                ),
                padding: EdgeInsets.symmetric(horizontal: context.getRSize(6)),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: t.colorScheme.primary,
                  shape: BoxShape.circle,
                  border: Border.all(color: t.colorScheme.surface, width: 2),
                ),
                child: Text(
                  inCartLabel!,
                  style: context
                      .boldStyle(12)
                      .copyWith(color: t.colorScheme.onPrimary),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
