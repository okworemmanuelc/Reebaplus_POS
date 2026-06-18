import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/pos/controllers/pos_controller.dart';
import 'package:reebaplus_pos/features/pos/widgets/edit_item_modal.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';

class ProductGrid extends StatelessWidget {
  final List<ProductDataWithStock> products;
  final Function(ProductDataWithStock) onProductTap;
  final Color cardCol;
  final Color textCol;
  final Color subtextCol;
  final Color borderCol;
  final PosController controller;
  final bool isListView;
  final int gridColumns;

  const ProductGrid({
    super.key,
    required this.products,
    required this.onProductTap,
    required this.cardCol,
    required this.textCol,
    required this.subtextCol,
    required this.borderCol,
    required this.controller,
    this.isListView = false,
    this.gridColumns = 3,
  });

  @override
  Widget build(BuildContext context) {
    if (products.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              FontAwesomeIcons.magnifyingGlass.data,
              size: context.getRSize(48),
              color: subtextCol.withValues(alpha: 0.3),
            ),
            SizedBox(height: context.getRSize(16)),
            Text(
              'No products found',
              style: TextStyle(
                fontSize: context.getRFontSize(16),
                color: subtextCol,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    if (isListView) {
      return ListView.separated(
        padding: EdgeInsets.all(context.getRSize(16)),
        itemCount: products.length,
        separatorBuilder: (_, __) => SizedBox(height: context.getRSize(16)),
        itemBuilder: (context, index) {
          final item = products[index];
          return _ProductCard(
            item: item,
            onTap: () => onProductTap(item),
            cardCol: cardCol,
            textCol: textCol,
            subtextCol: subtextCol,
            borderCol: borderCol,
            controller: controller,
            isListView: true,
          );
        },
      );
    }

    final screenWidth = MediaQuery.of(context).size.width;
    int effectiveColumns = gridColumns;

    if (screenWidth < 380) {
      // Small phone: maximum 2 columns
      if (effectiveColumns > 2) effectiveColumns = 2;
    } else if (screenWidth > 600) {
      // Tablet: dynamically increase contents per row
      final dynamicColumns = (screenWidth / 180).floor();
      effectiveColumns = max(effectiveColumns, dynamicColumns);
    }

    // Calculate aspect ratio dynamically to guarantee a minimum height and avoid overflow
    final totalPadding = context.getRSize(32); // 16 padding on each side
    final totalSpacing = context.getRSize(16) * (effectiveColumns - 1);
    final cellWidth = (screenWidth - totalPadding - totalSpacing) / effectiveColumns;
    // We need roughly 250px (scaled) of height for the image, name, price, stock
    final aspect = cellWidth / context.getRSize(250);

    return GridView.builder(
      padding: EdgeInsets.all(context.getRSize(16)),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: effectiveColumns,
        childAspectRatio: aspect,
        crossAxisSpacing: context.getRSize(16),
        mainAxisSpacing: context.getRSize(16),
      ),
      itemCount: products.length,
      itemBuilder: (context, index) {
        final item = products[index];
        return _ProductCard(
          item: item,
          onTap: () => onProductTap(item),
          cardCol: cardCol,
          textCol: textCol,
          subtextCol: subtextCol,
          borderCol: borderCol,
          controller: controller,
          isListView: false,
        );
      },
    );
  }
}

class _ProductCard extends ConsumerStatefulWidget {
  final ProductDataWithStock item;
  final VoidCallback onTap;
  final Color cardCol;
  final Color textCol;
  final Color subtextCol;
  final Color borderCol;
  final PosController controller;
  final bool isListView;

  const _ProductCard({
    required this.item,
    required this.onTap,
    required this.cardCol,
    required this.textCol,
    required this.subtextCol,
    required this.borderCol,
    required this.controller,
    this.isListView = false,
  });

  @override
  ConsumerState<_ProductCard> createState() => _ProductCardState();
}

class _ProductCardState extends ConsumerState<_ProductCard>
    with TickerProviderStateMixin {
  AnimationController? _flingCtrl;
  OverlayEntry? _overlayEntry;

  @override
  void dispose() {
    _flingCtrl?.dispose();
    _overlayEntry?.remove();
    _overlayEntry = null;
    super.dispose();
  }

  /// Long-press opens the qty + discount sheet (the same editor used for cart
  /// lines), letting the user add the product with a chosen quantity/discount.
  Future<void> _openAddModal() async {
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
    // Then launch fling particle
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final source = renderBox.localToGlobal(
      Offset(renderBox.size.width / 2, renderBox.size.height / 3),
    );
    _launchFling(source);
  }

  void _launchFling(Offset source) {
    // Clean up any previous animation
    _flingCtrl?.stop();
    _overlayEntry?.remove();
    _overlayEntry = null;
    _flingCtrl?.dispose();

    final screenSize = MediaQuery.of(context).size;
    // Cart icon is the 5th (last) item in the 5-item bottom nav bar.
    final target = Offset(screenSize.width * 0.9, screenSize.height - 28.0);

    _flingCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 620),
    );

    _overlayEntry = OverlayEntry(
      builder: (_) => AnimatedBuilder(
        animation: _flingCtrl!,
        builder: (_, __) {
          final raw = _flingCtrl!.value;
          final t = Curves.easeIn.transform(raw);

          // X: linear from source to target
          final x = lerpDouble(source.dx, target.dx, t)!;
          // Y: parabolic arc (goes up first, then drops to target)
          final yBase = lerpDouble(source.dy, target.dy, t)!;
          final arc = -110.0 * sin(pi * raw); // upward arc
          final y = yBase + arc;

          final scale = lerpDouble(1.0, 0.35, t)!;
          final opacity = raw > 0.82
              ? ((1.0 - raw) / 0.18).clamp(0.0, 1.0)
              : 1.0;

          return Positioned(
            left: x - 15,
            top: y - 15,
            child: IgnorePointer(
              child: Opacity(
                opacity: opacity,
                child: Transform.scale(
                  scale: scale,
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.55),
                          blurRadius: 10,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.shopping_cart_rounded,
                      color: Colors.white,
                      size: 15,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );

    Overlay.of(context).insert(_overlayEntry!);
    _flingCtrl!.forward().then((_) {
      if (mounted) {
        _overlayEntry?.remove();
        _overlayEntry = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final product = widget.item.product;
    final bool isOutOfStock = widget.item.totalStock <= 0;
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
    final bool isLowStock = !isOutOfStock && widget.item.totalStock <= 5;

    return ValueListenableBuilder<List<Map<String, dynamic>>>(
      valueListenable: ref.watch(cartProvider),
      builder: (context, cartItems, _) {
        final double cartQty = cartItems
            .where((i) => i['id'] == product.id)
            .fold(0.0, (s, i) => s + (i['qty'] as num).toDouble());
        final bool inCart = cartQty > 0;
        final bool atStockLimit =
            !isOutOfStock && cartQty >= widget.item.totalStock;
        final String badgeText = cartQty == cartQty.roundToDouble()
            ? cartQty.toInt().toString()
            : cartQty.toStringAsFixed(1);

        return Stack(
          clipBehavior: Clip.none,
          children: [
            Opacity(
              opacity: isOutOfStock ? 0.45 : 1.0,
              child: GestureDetector(
                onLongPress: isOutOfStock ? null : _openAddModal,
                child: InkWell(
                  onTap: isOutOfStock
                      ? null
                      : (atStockLimit
                            ? () => AppNotification.showError(
                                context,
                                'Stock limit reached for ${product.name}',
                              )
                            : _handleTap),
                  borderRadius: BorderRadius.circular(16),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    decoration: BoxDecoration(
                      color: widget.cardCol,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: inCart && !isOutOfStock 
                            ? Theme.of(context).colorScheme.primary 
                            : Colors.transparent, // Toned down outline
                        width: inCart && !isOutOfStock ? 2.0 : 1.0,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: inCart && !isOutOfStock
                              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15)
                              : Colors.black.withValues(alpha: 0.02),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: widget.isListView
                        ? _buildListLayout(context, product, price, isOutOfStock, isLowStock, inCart)
                        : _buildGridLayout(context, product, price, isOutOfStock, isLowStock, inCart),
                  ),
                ),
              ),
            ),
            // Cart quantity badge
            Positioned(
              top: -8,
              right: -8,
              child: AnimatedScale(
                scale: inCart ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 250),
                curve: Curves.elasticOut,
                child: Container(
                  width: context.getRSize(30),
                  height: context.getRSize(30),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.45),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Center(
                    child: Text(
                      badgeText,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: context.getRFontSize(11),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildGridLayout(BuildContext context, dynamic product, double price, bool isOutOfStock, bool isLowStock, bool inCart) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Stack(
            children: [
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.05),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                ),
                child: Center(
                  child: product.imagePath != null
                      ? Image.file(
                          File(product.imagePath!),
                          width: double.infinity,
                          height: double.infinity,
                          fit: BoxFit.cover,
                          errorBuilder: (ctx, _, __) => Icon(
                            FontAwesomeIcons.beerMugEmpty.data,
                            size: context.getRSize(32),
                            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4),
                          ),
                        )
                      : Icon(
                          FontAwesomeIcons.beerMugEmpty.data,
                          size: context.getRSize(32),
                          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4),
                        ),
                ),
              ),
              if (isOutOfStock)
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.35),
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                    ),
                    child: Center(
                      child: Text(
                        'Out of\nStock',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: context.getRFontSize(10),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.all(context.getRSize(12)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                product.name,
                style: TextStyle(
                  fontSize: context.getRFontSize(14),
                  fontWeight: FontWeight.w800,
                  color: widget.textCol,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              SizedBox(height: context.getRSize(2)),
              Text(
                '${product.size != null && product.size.toString() != 'null' ? '${product.size} ' : ''}${product.unit ?? ''}'.trim(),
                style: TextStyle(
                  fontSize: context.getRFontSize(11),
                  color: widget.subtextCol,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              SizedBox(height: context.getRSize(6)),
              Text(
                formatCurrency(price),
                style: TextStyle(
                  fontSize: context.getRFontSize(14),
                  fontWeight: FontWeight.w900,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              SizedBox(height: context.getRSize(8)),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    isOutOfStock
                        ? 'No stock'
                        : 'Stock: ${widget.item.totalStock}',
                    style: TextStyle(
                      fontSize: context.getRFontSize(11),
                      color: isOutOfStock
                          ? danger
                          : (isLowStock ? danger : widget.subtextCol),
                      fontWeight: (isOutOfStock || isLowStock)
                          ? FontWeight.bold
                          : FontWeight.w500,
                    ),
                  ),
                  if (isLowStock)
                    Icon(
                      FontAwesomeIcons.triangleExclamation.data,
                      size: context.getRSize(12),
                      color: Theme.of(context).colorScheme.error,
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildListLayout(BuildContext context, dynamic product, double price, bool isOutOfStock, bool isLowStock, bool inCart) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: context.getRSize(100),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.05),
              borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)),
            ),
            child: Stack(
              children: [
                Center(
                  child: product.imagePath != null
                      ? ClipRRect(
                          borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)),
                          child: Image.file(
                            File(product.imagePath!),
                            width: double.infinity,
                            height: double.infinity,
                            fit: BoxFit.cover,
                            errorBuilder: (ctx, _, __) => Icon(
                              FontAwesomeIcons.beerMugEmpty.data,
                              size: context.getRSize(24),
                              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4),
                            ),
                          ),
                        )
                      : Icon(
                          FontAwesomeIcons.beerMugEmpty.data,
                          size: context.getRSize(24),
                          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4),
                        ),
                ),
                if (isOutOfStock)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.35),
                        borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)),
                      ),
                      child: Center(
                        child: Text(
                          'Out of\nStock',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: context.getRFontSize(10),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.all(context.getRSize(16)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    product.name,
                    style: TextStyle(
                      fontSize: context.getRFontSize(16),
                      fontWeight: FontWeight.w800,
                      color: widget.textCol,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  SizedBox(height: context.getRSize(4)),
                  Text(
                    '${product.size != null && product.size.toString() != 'null' ? '${product.size} ' : ''}${product.unit ?? ''}'.trim(),
                    style: TextStyle(
                      fontSize: context.getRFontSize(13),
                      color: widget.subtextCol,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  SizedBox(height: context.getRSize(12)),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        formatCurrency(price),
                        style: TextStyle(
                          fontSize: context.getRFontSize(16),
                          fontWeight: FontWeight.w900,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      Row(
                        children: [
                          if (isLowStock) ...[
                            Icon(
                              FontAwesomeIcons.triangleExclamation.data,
                              size: context.getRSize(12),
                              color: Theme.of(context).colorScheme.error,
                            ),
                            SizedBox(width: context.getRSize(4)),
                          ],
                          Text(
                            isOutOfStock
                                ? 'No stock'
                                : 'Stock: ${widget.item.totalStock}',
                            style: TextStyle(
                              fontSize: context.getRFontSize(12),
                              color: isOutOfStock
                                  ? danger
                                  : (isLowStock ? danger : widget.subtextCol),
                              fontWeight: (isOutOfStock || isLowStock)
                                  ? FontWeight.bold
                                  : FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
